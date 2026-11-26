"""Wire-format validation and conservative BER/PER accounting."""
from __future__ import annotations

from dataclasses import dataclass, field
import json
import struct
import zlib

RECORD_SIZE = 64
RAW_SIZE = 41
FLAG_COMPLETE = 0x01
FLAG_TIMEOUT = 0x02
FLAG_LOCK_LOST = 0x04
FLAG_STOPPED = 0x08
FLAG_HEADER_CRC_OK = 0x10
FLAG_FRAME_CRC_OK = 0x20
FLAG_EXPECTED_DATA = 0x40


def crc16(data: bytes) -> int:
    crc = 0xFFFF
    for byte in data:
        crc ^= byte << 8
        for _ in range(8):
            crc = ((crc << 1) ^ 0x1021) & 0xFFFF if crc & 0x8000 else (crc << 1) & 0xFFFF
    return crc


def crc8(data: bytes) -> int:
    crc = 0
    for byte in data:
        crc ^= byte
        for _ in range(8):
            crc = ((crc << 1) ^ 0x07) & 0xFF if crc & 0x80 else (crc << 1) & 0xFF
    return crc


def payload_for(batch: int, sequence: int) -> bytes:
    if not 0 <= batch <= 0xFFFFFFFF or not 0 <= sequence <= 0xFFFFFFFF:
        raise ValueError("batch and sequence must be uint32")
    state = (batch ^ sequence ^ 0x9E3779B9) & 0xFFFFFFFF
    tail = bytearray()
    prefix = struct.pack(">II", batch, sequence)
    for _ in range(20):
        state ^= (state << 13) & 0xFFFFFFFF
        state ^= state >> 17
        state ^= (state << 5) & 0xFFFFFFFF
        state &= 0xFFFFFFFF
        tail.append(state & 0xFF)
    return prefix + struct.pack(">I", zlib.crc32(prefix)) + bytes(tail)


@dataclass(frozen=True)
class Capture:
    capture_id: int
    bit_count: int
    flags: int
    byte_count: int
    sample_index: int
    raw: bytes

    @property
    def complete(self) -> bool:
        return self.bit_count == 328 and self.byte_count == RAW_SIZE and bool(self.flags & FLAG_COMPLETE)

    @property
    def identity(self) -> tuple[int, int] | None:
        if not self.complete or not self.flags & FLAG_HEADER_CRC_OK or not self.flags & FLAG_EXPECTED_DATA:
            return None
        if len(self.raw) != RAW_SIZE or self.raw[0] != 0x20 or self.raw[2] != 32:
            return None
        if crc8(self.raw[:3]) != self.raw[3]:
            return None
        prefix = self.raw[7:15]
        if zlib.crc32(prefix) != struct.unpack(">I", self.raw[15:19])[0]:
            return None
        batch, sequence = struct.unpack(">II", prefix)
        if self.raw[1] != (sequence & 0xFF):
            return None
        return batch, sequence

    def bit_errors(self, expected: bytes) -> int:
        if self.identity is None or len(expected) != 32:
            raise ValueError("capture identity/alignment is not trustworthy")
        return sum((a ^ b).bit_count() for a, b in zip(expected, self.raw[7:39]))


def parse_record(data: bytes) -> Capture:
    if len(data) != RECORD_SIZE or data[:4] != b"BR01":
        raise ValueError("invalid BER record length or signature")
    capture_id, bit_count = struct.unpack_from("<IH", data, 4)
    flags, count = data[10:12]
    if not capture_id or bit_count > 328 or count != (bit_count + 7) // 8 or flags & 0x80:
        raise ValueError("invalid BER record fields")
    if bool(flags & FLAG_COMPLETE) != (bit_count == 328) or flags & 0x0E not in (0, 2, 4, 8):
        raise ValueError("inconsistent BER record termination")
    if not flags & 1 and not flags & 0x0E or flags & 1 and flags & 0x0E:
        raise ValueError("missing or conflicting BER termination")
    if any(data[16 + count:]) or (bit_count % 8 and data[16 + count - 1] & ((1 << (8 - bit_count % 8)) - 1)):
        raise ValueError("nonzero BER padding")
    raw = data[16:57]
    if bool(flags & FLAG_HEADER_CRC_OK) != (bit_count >= 32 and crc8(raw[:3]) == raw[3]):
        raise ValueError("BER CRC8 flag mismatch")
    if bool(flags & FLAG_FRAME_CRC_OK) != (bit_count == 328 and crc16(raw[:39]) == int.from_bytes(raw[39:], "big")):
        raise ValueError("BER CRC16 flag mismatch")
    if bool(flags & FLAG_EXPECTED_DATA) != (bit_count == 328 and raw[0] == 0x20 and raw[2] == 32):
        raise ValueError("BER header type/length flag mismatch")
    return Capture(capture_id, bit_count, data[10], data[11],
                   struct.unpack_from("<I", data, 12)[0], raw)


def parse_status(data: bytes) -> dict[str, int]:
    if len(data) != 32 or data[:4] != b"BS01" or data[6:8] != b"\x08\x40" or data[5] > 8 or data[4] & 0xE0:
        raise ValueError("invalid BER status")
    state, count = data[4:6]
    if bool(state & 4) != bool(count) or bool(state & 8) != (count == 8):
        raise ValueError("inconsistent BER status")
    names = ("started", "dropped", "committed", "protocol_errors", "popped", "missed_sync")
    return {"state": state, "count": count, **dict(zip(names, struct.unpack_from("<6I", data, 8)))}


def parse_health(data: bytes) -> dict[str, int]:
    if len(data) != 20 or data[:4] != b"BH01" or data[4] != 0xA7 or any(data[18:]):
        raise ValueError("invalid BER health snapshot")
    regs = data[4:18]
    return {"device_id": regs[0], "firmware": regs[1], "status0": regs[2],
            "error_flags": regs[3], "frame_count": regs[4],
            "fifo_bytes": regs[8] | ((regs[9] & 1) << 8),
            "good_count": int.from_bytes(regs[10:12], "little"),
            "crc_error_count": int.from_bytes(regs[12:14], "little")}


def parse_hex_reply(line: str, prefix: str, expected_bytes: int) -> bytes:
    parts = line.strip().split(" crc=")
    if len(parts) != 2 or not parts[0].startswith(prefix):
        raise ValueError("malformed BER transport reply")
    try:
        encoded = parts[0][len(prefix):]
        if len(encoded) != expected_bytes * 2 or len(parts[1]) != 4:
            raise ValueError("noncanonical BER transport encoding")
        data = bytes.fromhex(encoded)
        received_crc = int(parts[1], 16)
    except ValueError as exc:
        raise ValueError("invalid BER transport hex") from exc
    if len(data) != expected_bytes or crc16(data) != received_crc:
        raise ValueError("BER transport CRC or length mismatch")
    return data


@dataclass
class Ledger:
    batch: int
    attempts: dict[int, dict] = field(default_factory=dict)
    delivered: set[int] = field(default_factory=set)
    captures: dict[int, Capture] = field(default_factory=dict)
    duplicate_deliveries: int = 0
    duplicate_captures: int = 0
    unaligned_records: int = 0
    transport_errors: int = 0
    tx_unresolved: int = 0
    capture_drops: int = 0
    missed_sync: int = 0
    partial_records: int = 0
    capture_conflicts: int = 0
    seen_capture_ids: dict[int, Capture] = field(default_factory=dict)
    normal_invalid_observations: int = 0
    protocol_errors: int = 0
    rx_status_baseline: dict = field(default_factory=dict)
    rx_status_final: dict = field(default_factory=dict)
    measurement_elapsed_s: float = 0.0
    health_baseline: dict = field(default_factory=dict)
    health_final: dict = field(default_factory=dict)
    tx_uart_diagnostics: dict = field(default_factory=dict)
    spi_read_errors: int = 0
    serial_crc_or_format_errors: int = 0
    capture_terminations: dict[str, int] = field(default_factory=dict)
    bad_header_crc_records: int = 0
    bad_frame_crc_records: int = 0

    def note_delivery(self, payload: bytes) -> bool:
        if len(payload) != 32 or struct.unpack(">I", payload[:4])[0] != self.batch:
            return False
        sequence = struct.unpack(">I", payload[4:8])[0]
        if sequence not in self.attempts or payload != self.attempts[sequence]["payload"]:
            self.normal_invalid_observations += 1
            return False
        if sequence in self.delivered:
            self.duplicate_deliveries += 1
            return False
        self.delivered.add(sequence)
        return True

    def note_capture(self, capture: Capture) -> bool:
        if capture.capture_id in self.seen_capture_ids:
            if self.seen_capture_ids[capture.capture_id] != capture:
                self.capture_conflicts += 1
                raise ValueError("same capture ID returned different data")
            self.duplicate_captures += 1
            return False
        self.seen_capture_ids[capture.capture_id] = capture
        termination = "complete" if capture.complete else "timeout" if capture.flags & 2 else "lock_lost_or_unavailable" if capture.flags & 4 else "stopped"
        self.capture_terminations[termination] = self.capture_terminations.get(termination, 0) + 1
        if capture.bit_count >= 32 and not capture.flags & 16:
            self.bad_header_crc_records += 1
        if capture.complete and not capture.flags & 32:
            self.bad_frame_crc_records += 1
        if not capture.complete:
            self.partial_records += 1
        identity = capture.identity
        if identity is None:
            self.unaligned_records += 1
            return False
        batch, sequence = identity
        if batch != self.batch or sequence not in self.attempts:
            self.unaligned_records += 1
            return False
        if sequence in self.captures:
            self.duplicate_captures += 1
            return False
        self.captures[sequence] = capture
        return True

    def report(self) -> dict:
        completed = {s for s, a in self.attempts.items() if a.get("tx") == "complete"}
        comparable = sorted(s for s in self.captures if s in completed)
        errors = sum(self.captures[s].bit_errors(self.attempts[s]["payload"]) for s in comparable)
        bits = len(comparable) * 256
        delivered = len(self.delivered & completed)
        pending_rx = {s for s in completed if not self.attempts[s].get("rx_window_complete", False)}
        elapsed = self.measurement_elapsed_s or sum(a.get("elapsed_s", 0.0) for a in self.attempts.values())
        serial_deltas = {}
        for key in ("uart_err", "rx_restart", "tx_err", "overflow"):
            if key in self.rx_status_baseline and key in self.rx_status_final:
                old, new = int(self.rx_status_baseline[key]), int(self.rx_status_final[key])
                serial_deltas[key] = new - old if new >= old else None
        initial_flags = self.health_baseline.get("error_flags")
        final_flags = self.health_final.get("error_flags")
        return {
            "batch": self.batch, "tx_attempted": len(self.attempts),
            "tx_completed": len(completed), "tx_unresolved": self.tx_unresolved,
            "delivered_unique": delivered,
            "per": (len(completed) - delivered) / len(completed) if completed and not pending_rx else None,
            "rx_windows_unfinished": len(pending_rx),
            "completed_not_observed_delivered": len(completed) - delivered,
            "matched_unique": len(comparable), "payload_bit_errors": errors,
            "ber": errors / bits if bits else None,
            "coverage": len(comparable) / len(completed) if completed else None,
            "compared_payload_bits": bits,
            "duplicate_deliveries": self.duplicate_deliveries,
            "duplicate_captures": self.duplicate_captures,
            "unaligned_records": self.unaligned_records,
            "transport_errors": self.transport_errors, "capture_drops": self.capture_drops,
            "missed_sync": self.missed_sync, "partial_records": self.partial_records,
            "capture_conflicts": self.capture_conflicts,
            "normal_invalid_observations": self.normal_invalid_observations,
            "diagnostic_protocol_errors": self.protocol_errors,
            "measurement_elapsed_s": elapsed,
            "rx_status_baseline": self.rx_status_baseline,
            "rx_status_final": self.rx_status_final,
            "fpga_health_baseline": self.health_baseline,
            "fpga_health_final": self.health_final,
            "tx_uart_diagnostics": self.tx_uart_diagnostics,
            "capture_terminations": self.capture_terminations,
            "bad_header_crc_records": self.bad_header_crc_records,
            "bad_frame_crc_records": self.bad_frame_crc_records,
            "spi_read_errors": self.spi_read_errors,
            "serial_crc_or_format_errors": self.serial_crc_or_format_errors,
            "rx_serial_counter_deltas": serial_deltas,
            "normal_fifo_overflow_initial": bool(initial_flags & 16) if initial_flags is not None else None,
            "normal_fifo_overflow_final": bool(final_flags & 16) if final_flags is not None else None,
            "normal_fifo_overflow_exact_count": None,
            "completed_without_aligned_capture": len(completed - self.captures.keys()),
            "delivery_without_capture": len((self.delivered & completed) - self.captures.keys()),
            "capture_without_delivery": len((self.captures.keys() & completed) - self.delivered),
            "effective_throughput_bps": delivered * 256 / elapsed if elapsed else None,
            "statistic_scope": "sync-conditioned 32-byte Payload BER, identity-validated complete captures only; excluded identity errors create selection bias",
        }

    def audit(self) -> str:
        attempts = {str(k): {**v, "payload": v["payload"].hex()} for k, v in self.attempts.items()}
        return json.dumps({"report": self.report(), "attempts": attempts}, sort_keys=True)
