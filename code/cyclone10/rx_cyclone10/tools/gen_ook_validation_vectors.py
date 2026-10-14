#!/usr/bin/env python3
"""Generate deterministic independent OOK-1800 RTL validation vectors.

The vectors model a zero-centred ADC input to rtl/demod/ook_iq_correlator.v,
not STM32 DAC codes.  They intentionally use the fixed 80-sample Q7 I/Q
reference and energy shift implemented in that RTL, but are produced without
calling RTL or the STM32 transmitter.
"""
from __future__ import annotations

import hashlib
import json
import math
from pathlib import Path

FS = 48_000
BIT_RATE = 100
SPS = FS // BIT_RATE
GAP = FS // 10
PREAMBLE = 0xAAAA
SYNC = 0x06B7
LOW = 400
HIGH = 600
ENERGY_SHIFT = 28
AMPLITUDE = 80
LUT_N = 80
CYCLES = 3
Q7 = tuple(int(round(127 * math.cos(2 * math.pi * CYCLES * n / LUT_N))) for n in range(LUT_N))
Q7Q = tuple(int(round(127 * math.sin(2 * math.pi * CYCLES * n / LUT_N))) for n in range(LUT_N))


def crc8(data: bytes) -> int:
    value = 0
    for byte in data:
        value ^= byte
        for _ in range(8):
            value = ((value << 1) ^ 0x07) & 0xFF if value & 0x80 else (value << 1) & 0xFF
    return value


def crc16(data: bytes) -> int:
    value = 0xFFFF
    for byte in data:
        value ^= byte << 8
        for _ in range(8):
            value = ((value << 1) ^ 0x1021) & 0xFFFF if value & 0x8000 else (value << 1) & 0xFFFF
    return value


def bits(data: bytes) -> list[int]:
    return [(byte >> bit) & 1 for byte in data for bit in range(7, -1, -1)]


def frame(frame_type: int, sequence: int, timestamp: int, payload: bytes, corrupt_crc: bool = False) -> bytes:
    if frame_type == 1:
        payload = b""
        stamp = timestamp.to_bytes(4, "big")
    else:
        stamp = timestamp.to_bytes(3, "big")
    head3 = bytes(((2 << 4) | frame_type, sequence, len(payload)))
    body = head3 + bytes((crc8(head3),)) + stamp + payload
    check = crc16(body)
    if corrupt_crc:
        check ^= 0x0001
    return PREAMBLE.to_bytes(2, "big") + SYNC.to_bytes(2, "big") + body + check.to_bytes(2, "big")


def samples_for_frame(raw: bytes, carrier_phase: int, start_offset: int) -> list[int]:
    # `start_offset` is a sample delay after the 100 ms gap.  It advances both
    # the correlator phase and the zero-input interval before the first symbol.
    values = [0] * (GAP + start_offset)
    phase = carrier_phase % LUT_N
    for bit in bits(raw):
        if bit:
            values.extend(int(round(AMPLITUDE * math.sin(2 * math.pi * CYCLES * (phase + n) / LUT_N))) for n in range(SPS))
            phase = (phase + SPS) % LUT_N
        else:
            values.extend([0] * SPS)
    return values


def energy_window(samples: list[int]) -> list[int]:
    # Same signed accumulation and `(I*I + Q*Q) >> 28` result as the RTL.
    result = []
    for start in range(0, len(samples) - LUT_N + 1, 48):
        i_acc = sum(samples[start + n] * Q7[(start + n) % LUT_N] for n in range(LUT_N))
        q_acc = sum(samples[start + n] * Q7Q[(start + n) % LUT_N] for n in range(LUT_N))
        result.append((i_acc * i_acc + q_acc * q_acc) >> ENERGY_SHIFT)
    return result


def write_mem(path: Path, values: list[int]) -> str:
    path.write_text("".join(f"{value & 0xFFFFF:05X}\n" for value in values), encoding="ascii", newline="\n")
    return hashlib.sha256(path.read_bytes()).hexdigest()


def scenario(name: str, frames: list[tuple[bytes, int, int]], expected: list[dict]) -> dict:
    samples: list[int] = []
    frame_meta = []
    for raw, phase, offset in frames:
        begin = len(samples)
        one = samples_for_frame(raw, phase, offset)
        samples.extend(one)
        frame_meta.append({"offset_samples": begin, "length_samples": len(one), "carrier_phase_samples": phase, "start_offset_samples": offset, "frame_hex": raw.hex().upper()})
    samples += [0] * GAP
    metrics = energy_window(samples)
    return {"name": name, "samples": samples, "metrics": metrics, "frames": frame_meta, "expected": expected}


def validate_scenarios(items: list[dict]) -> None:
    """Independent protocol/vector checks before any files are emitted."""
    names = {item["name"] for item in items}
    required = {"payload_64_zero", "payload_64_ff", "payload_random",
                "bad_crc_followed_by_good", "time_base_then_data"}
    if not required.issubset(names):
        raise AssertionError("required OOK validation scenarios are missing")
    offsets = {item["frames"][0]["start_offset_samples"]
               for item in items if item["name"].startswith("phase_")}
    if offsets != set(range(0, 120, 12)):
        raise AssertionError("ten requested metric-phase start offsets are incomplete")
    for item in items:
        for frame_info, expected in zip(item["frames"], item["expected"]):
            raw = bytes.fromhex(frame_info["frame_hex"])
            if raw[:4] != b"\xAA\xAA\x06\xB7":
                raise AssertionError(f"{item['name']}: preamble/sync mismatch")
            body, received_crc = raw[4:-2], int.from_bytes(raw[-2:], "big")
            crc_ok = crc16(body) == received_crc
            if crc_ok != expected["valid"]:
                raise AssertionError(f"{item['name']}: CRC expectation mismatch")
            if expected["valid"]:
                if body[0] != ((2 << 4) | (1 if expected["type"] == "TIME_BASE" else 0)):
                    raise AssertionError(f"{item['name']}: V2 frame type mismatch")
                if body[1] != expected["sequence"] or body[2] != len(bytes.fromhex(expected["payload_hex"])):
                    raise AssertionError(f"{item['name']}: header metadata mismatch")
        if len(item["samples"]) < GAP:
            raise AssertionError(f"{item['name']}: required 100 ms trailing gap missing")


def main() -> None:
    root = Path(__file__).resolve().parents[1]
    out = root / "tb" / "ook_validation_vectors"
    out.mkdir(parents=True, exist_ok=True)
    payload_random = bytes((0x9D, 0x02, 0xF0, 0x4C, 0xB1, 0x77, 0x3A, 0xE6))
    scenarios = []
    base = [
        ("payload_64_zero", bytes(64)),
        ("payload_64_ff", bytes([0xFF]) * 64),
        ("payload_random", payload_random),
    ]
    for index, (name, payload) in enumerate(base):
        raw = frame(0, index, 0x000000, payload)
        scenarios.append(scenario(name, [(raw, (index * 20) % 80, index * 12)], [{"valid": True, "sequence": index, "type": "DATA", "timestamp": 0, "payload_hex": payload.hex().upper()}]))

    bad = frame(0, 0x40, 0, b"BAD!", corrupt_crc=True)
    good = frame(0, 0x41, 0, b"GOOD")
    scenarios.append(scenario("bad_crc_followed_by_good", [(bad, 60, 36), (good, 0, 48)], [{"valid": False, "reason": "CRC16", "sequence": 0x40}, {"valid": True, "sequence": 0x41, "type": "DATA", "timestamp": 0, "payload_hex": "474F4F44"}]))

    time_base = frame(1, 0x50, 1_790_006_400, b"")
    data = frame(0, 0x51, 1234, b"\x01\x23\x45\x67")
    scenarios.append(scenario("time_base_then_data", [(time_base, 20, 60), (data, 40, 72)], [{"valid": True, "sequence": 0x50, "type": "TIME_BASE", "timestamp": 1_790_006_400, "payload_hex": ""}, {"valid": True, "sequence": 0x51, "type": "DATA", "timestamp": 1234, "payload_hex": "01234567"}]))

    # Ten selected pairs cover metric start offsets 0,12,...108.  Carrier phase
    # rotates 0/90/180/270 degrees without taking a 10x4 Cartesian product.
    for index, offset in enumerate(range(0, 120, 12)):
        phase = (0, 20, 40, 60)[index % 4]
        payload = bytes((0xA0 + index,))
        raw = frame(0, 0x60 + index, index, payload)
        scenarios.append(scenario(f"phase_{phase:02d}_offset_{offset:03d}", [(raw, phase, offset)], [{"valid": True, "sequence": 0x60 + index, "type": "DATA", "timestamp": index, "payload_hex": payload.hex().upper()}]))

    validate_scenarios(scenarios)

    manifest = {
        "schema_version": 1,
        "generator": "tools/gen_ook_validation_vectors.py",
        "parameters": {"sample_rate_hz": FS, "bit_rate_bps": BIT_RATE, "samples_per_symbol": SPS, "carrier_hz": 1800, "carrier_lut_samples": LUT_N, "carrier_lut_cycles": CYCLES, "adc_amplitude": AMPLITUDE, "gap_samples": GAP, "low_threshold": LOW, "high_threshold": HIGH, "energy_expression": "(I*I+Q*Q)>>28", "iq_coefficients": "Q7 round(127*cos/sin(2*pi*3*n/80))"},
        "sample_format": "signed 20-bit two's-complement; one five-hex-digit word per line",
        "scenarios": [],
    }
    for item in scenarios:
        path = out / f"{item['name']}.samples_i20.mem"
        digest = write_mem(path, item["samples"])
        nonzero = [x for x in item["metrics"] if x]
        manifest["scenarios"].append({"name": item["name"], "files": {"samples_i20_mem": path.name}, "sha256": digest, "sample_count": len(item["samples"]), "metric_energy_min_nonzero": min(nonzero) if nonzero else 0, "metric_energy_max": max(item["metrics"]) if item["metrics"] else 0, "frames": item["frames"], "expected_frames": item["expected"]})
    # Metrics straddling an OOK edge deliberately contain part carrier and
    # part zero, so they can be below HIGH.  Check every phase of a fully
    # populated 80-sample carrier window instead.
    steady = []
    for phase in range(LUT_N):
        tone = [int(round(AMPLITUDE * math.sin(2 * math.pi * CYCLES * (phase + n) / LUT_N))) for n in range(LUT_N)]
        steady.append(energy_window(tone)[0])
    if min(steady) < HIGH:
        raise AssertionError(f"steady carrier energy {min(steady)} is below HIGH={HIGH}")
    if max(steady) >= (1 << 32):
        raise AssertionError("energy overflow")
    manifest["parameters"]["steady_carrier_energy_min"] = min(steady)
    manifest["parameters"]["steady_carrier_energy_max"] = max(steady)
    (out / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="ascii", newline="\n")
    print(f"PASS: wrote {len(scenarios)} scenarios; steady energy={min(steady)}..{max(steady)}, amplitude={AMPLITUDE}")


if __name__ == "__main__":
    main()
