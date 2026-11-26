#!/usr/bin/env python3
"""Stop-and-wait FSK BER trial with separate TX and RX serial ports.

Every byte/command and trial transition is journalled before progressing. SEND
is never retried. A timeout poisons a serial session (uncorrelated late replies
cannot be associated safely); best-effort STOP then aborts the trial.
"""
from __future__ import annotations

import argparse
import datetime as dt
import json
import os
from pathlib import Path
import re
import math
import time

import serial

from ber_protocol import Ledger, parse_health, parse_hex_reply, parse_record, parse_status, payload_for

CONTROL_BYTE_GAP = 0.002
PARTIAL_LINE_ERASE_BYTES = 160


class TrialError(RuntimeError):
    pass


class Journal:
    def __init__(self, path: Path):
        self.file = path.open("x", encoding="utf-8")

    def log(self, kind: str, **fields):
        self.file.write(json.dumps({"utc": dt.datetime.now(dt.timezone.utc).isoformat(),
                                   "monotonic_s": time.monotonic(), "kind": kind, **fields}) + "\n")
        self.file.flush()
        os.fsync(self.file.fileno())


class Device:
    def __init__(self, name, port, journal, clock=time.monotonic, sleep=None):
        self.name, self.port, self.journal, self.clock = name, port, journal, clock
        self.sleep = sleep or time.sleep
        self.pending = bytearray()
        self.poisoned = False

    def write_paced(self, packet):
        # Preserve UART baud but separate bytes beyond the measured O0 DMA
        # masking interval. A partial/ambiguous write is never retried.
        for index, byte in enumerate(packet):
            value = bytes([byte])
            if self.port.write(value) != 1:
                raise TrialError("partial serial write")
            self.journal.log("serial_tx", device=self.name, tx_hex=value.hex())
            if index + 1 < len(packet):
                self.sleep(CONTROL_BYTE_GAP)

    def command(self, text: str, timeout=2.0) -> str:
        if self.poisoned:
            raise TrialError(f"{self.name}: serial session has an unresolved reply")
        packet = (text + "\n").encode("ascii")
        self.journal.log("command", device=self.name, command=text, tx_hex=packet.hex())
        try:
            self.write_paced(packet)
            deadline = self.clock() + timeout
            while self.clock() < deadline:
                chunk = self.port.read(max(1, self.port.in_waiting))
                if chunk:
                    self.journal.log("serial_rx", device=self.name, rx_hex=chunk.hex())
                    self.pending.extend(chunk)
                if len(self.pending) > 4096:
                    raise TrialError("oversize serial response")
                if b"\n" in self.pending:
                    raw, _, rest = self.pending.partition(b"\n")
                    self.pending = bytearray(rest)
                    if rest.strip():
                        raise TrialError("unsolicited extra serial reply")
                    line = raw.decode("ascii").strip("\r")
                    self.journal.log("reply", device=self.name, command=text, line=line)
                    if not line.startswith(("OK", "ERR")):
                        raise TrialError("unrecognized serial response")
                    return line
            raise TrialError(f"{self.name} timeout for {text!r}")
        except BaseException:
            self.poisoned = True
            raise

    def expect(self, text, prefix="OK", **kwargs):
        line = self.command(text, **kwargs)
        if not (line == prefix or line.startswith(prefix + " ")):
            raise TrialError(f"{self.name} {text}: {line}")
        return line

    def emergency_stop(self, text):
        # No retry of a data command, no attempt to interpret a stale ACK.
        if text not in ("STOP", "BER STOP"):
            raise TrialError("Only STOP may be sent on an unresolved session")
        self.journal.log("cleanup_stop", device=self.name, command=text)
        # Clear the bounded firmware input BEFORE newline. A bare delimiter
        # might execute an incomplete SEND; appending STOP can form STATUSSTOP.
        self.write_paced(b"\x08" * PARTIAL_LINE_ERASE_BYTES + b"\n")
        self.sleep(.1)
        self.write_paced((text + "\n").encode("ascii"))


def fields(line):
    return dict(re.findall(r"([A-Za-z0-9_]+)=([^\s]+)", line))


def tx_status(tx):
    values = fields(tx.expect("STATUS"))
    for key in ("run", "fs", "err", "dmaerr", "hde", "hae", "mode", "time_base_pending", "time_valid", "base_s", "len"):
        if key not in values:
            raise TrialError(f"TX STATUS missing {key}")
        values[key] = int(values[key], 0)
    if values.get("mod") != "FSK" or values["fs"] != 48000:
        raise TrialError("TX must report FSK at 48000 samples/s")
    if any(values[k] for k in ("err", "dmaerr", "hde", "hae")):
        raise TrialError(f"TX DMA/HAL error: {values}")
    if values["run"] not in (0, 1) or values["time_base_pending"] not in (0, 1):
        raise TrialError("invalid TX STATUS state")
    return values


def transmit(tx, body_bytes, clock=time.monotonic, sleep=time.sleep):
    before = tx_status(tx)
    if before["run"]:
        raise TrialError("TX was already running before SEND")
    if body_bytes == 41 and (before["time_base_pending"] or before["len"] != 32 or not before["time_valid"]):
        raise TrialError("TX DATA payload/time-base setup changed before SEND")
    if body_bytes == 10 and not before["time_base_pending"]:
        raise TrialError("TX TIME_BASE request was not pending before SEND")
    started = clock()
    tx.expect("SEND")  # accepted != physically complete
    # Rendering can lead DAC output by two DMA halves (20 ms). Wait beyond
    # the complete waveform (preamble/sync + body + 2x100 ms silence) + guard.
    duration = (32 + body_bytes * 8) / 100 + 0.2
    seen_running = False
    while clock() - started < duration + 3.0:
        state = tx_status(tx)
        if state["run"] and state["mode"] != 5:
            raise TrialError("TX is running a waveform other than PACKET")
        elapsed = clock() - started
        seen_running |= bool(state["run"])
        if not state["run"]:
            if not seen_running or elapsed < duration - 0.10:
                raise TrialError("TX completion cannot be established (never ran or ended early)")
            sleep(max(0.0, duration + 0.10 - elapsed))
            final = tx_status(tx)
            if final["run"] or final["time_base_pending"]:
                raise TrialError("TX completion/status changed unexpectedly")
            return clock() - started
        sleep(0.15)
    raise TrialError("TX still running beyond its expected waveform")


def ber_data(rx, command, prefix, size, ledger, retries=3):
    # Retry only complete, CRC-protected responses. Timeouts poison Device and
    # abort; no new command is sent while an old reply could still arrive.
    for _ in range(retries):
        line = rx.command(command)
        if line == "OK BER EMPTY":
            return None
        if line == "ERR BER SPI":
            ledger.transport_errors += 1
            ledger.spi_read_errors += 1
            continue
        try:
            return parse_hex_reply(line, prefix, size)
        except ValueError:
            ledger.transport_errors += 1
            ledger.serial_crc_or_format_errors += 1
    raise TrialError(f"{command}: no valid response after {retries} safe reads")


def ber_status(rx, ledger):
    data = ber_data(rx, "BER STATUS", "OK BER STATUS ", 32, ledger)
    if data is None:
        raise TrialError("BER STATUS returned EMPTY")
    state = parse_status(data)
    ledger.capture_drops = state["dropped"]
    ledger.missed_sync = state["missed_sync"]
    ledger.protocol_errors = state["protocol_errors"]
    return state


def health(rx, ledger, journal):
    data = ber_data(rx, "BER HEALTH", "OK BER HEALTH ", 20, ledger)
    values = parse_health(data)
    journal.log("fpga_health", **values)
    return values


def tx_uart_diagnostics(tx, ledger, journal):
    line = tx.command("UART DIAG")
    if not line.startswith("OK UART DIAG "):
        journal.log("tx_uart_diag_unavailable", line=line)
        return None
    values = dict(re.findall(r"(\w+)=([^\s]*)", line))
    required = ("rxerr", "rxovf", "lineovf", "cmderr", "badlen", "badhex",
                "rendermax", "uartbudget", "renderlate", "renders", "dwt")
    if any(key not in values for key in required):
        raise TrialError(f"malformed TX UART DIAG: {line}")
    for key in required:
        if key != "badhex" and not values[key].isdigit():
            raise TrialError(f"malformed TX UART DIAG field {key}")
    if (not re.fullmatch(r"(?:[0-9A-Fa-f]{2})*", values["badhex"]) or
        len(values["badhex"]) > min(32, int(values["badlen"])) * 2):
        raise TrialError("malformed TX UART DIAG badhex")
    ledger.tx_uart_diagnostics = values
    journal.log("tx_uart_diag", **values)
    return values


def rx_status(rx):
    values = fields(rx.expect("STATUS"))
    for key in ("fpga", "uart_err", "rx_restart", "tx_err", "overflow"):
        if key not in values or not values[key].isdigit():
            raise TrialError(f"RX STATUS missing/invalid {key}")
    if values["fpga"] != "1":
        raise TrialError("RX FPGA disconnected")
    return values


def ensure_rx_fsk(rx, journal, clock=time.monotonic, sleep=time.sleep):
    """Wait for deferred mode application; don't resubmit an existing commit."""
    deadline = clock() + 5.0
    submitted = False
    while True:
        line = rx.expect("ASK STATUS", "OK ASK STATUS")
        status = fields(line)
        if status.get("mode") not in ("FSK", "OOK") or status.get("pending") not in ("0", "1") or status.get("error") not in ("0", "1"):
            raise TrialError(f"RX invalid configuration status: {line}")
        if status["error"] != "0":
            raise TrialError(f"RX configuration rejected: {line}")
        if status["pending"] == "0" and status["mode"] == "FSK":
            return
        if clock() >= deadline:
            tuning = rx.command("FSK STATUS")
            raise TrialError(f"RX FSK configuration still pending/wrong after 5s, no test SEND: {line}; {tuning}")
        if status["pending"] == "0" and not submitted:
            rx.expect("MOD FSK", "OK MOD FSK")
            submitted = True
        else:
            journal.log("rx_config_wait", fields=status)
            sleep(.1)


def drain(rx, ledger, journal):
    line = rx.expect("READ", "OK DATA")
    match = re.fullmatch(r"OK DATA ([0-9A-Fa-f]*) time_valid=[01] timestamp_ms=\d+", line)
    if not match:
        raise TrialError("malformed normal READ")
    payload = bytes.fromhex(match[1])
    journal.log("normal_read", payload_hex=payload.hex(), new=ledger.note_delivery(payload))
    for _ in range(16):
        state = ber_status(rx, ledger)
        if not state["count"]:
            return state
        data = ber_data(rx, "BER READ", "OK BER RECORD ", 64, ledger)
        if data is None:
            raise TrialError("BER queue unexpectedly became empty")
        capture = parse_record(data)
        journal.log("diagnostic_raw", record_hex=data.hex(), capture_id=capture.capture_id)
        journal.log("diagnostic_alignment", capture_id=capture.capture_id,
                    matched=ledger.note_capture(capture))
        # Persist raw record before destructive acknowledgment. Verify progress
        # using popped (queue count can grow concurrently). SPI error may mean
        # the POP happened; resolve from the counter before considering retry.
        reply = rx.command(f"BER POP {capture.capture_id}")
        after = ber_status(rx, ledger)
        if after["popped"] != state["popped"] + 1 or reply not in ("OK BER ACK", "ERR BER SPI"):
            raise TrialError(f"BER POP unresolved: {reply}")
        journal.log("diagnostic_pop", capture_id=capture.capture_id, popped=after["popped"])
    raise TrialError("unbounded diagnostic arrivals while draining")


def run(tx, rx, ledger, journal, count, amplitude, rx_wait, sleep=time.sleep, clock=time.monotonic):
    tx.expect("STOP")
    tx.expect("MOD FSK")
    tx.expect("MODE PACKET")
    tx.expect(f"AMP {amplitude}")
    tx_status(tx)
    tx_uart_diagnostics(tx, ledger, journal)
    journal.log("tx_uart_diag_before_trial", **ledger.tx_uart_diagnostics)
    rx.expect("PING", "OK PONG")
    ensure_rx_fsk(rx, journal, clock, sleep)
    rx.expect("BER STOP", "OK BER ACK")
    # Allow an in-flight diagnostic publish to finish before CLEAR.
    deadline = clock() + 2
    while ber_status(rx, ledger)["state"] & 2:
        if clock() >= deadline:
            raise TrialError("BER STOP did not finish")
        sleep(.05)
    rx.expect("BER CLEAR", "OK BER ACK")
    now = dt.datetime.now(dt.timezone(dt.timedelta(hours=8)))
    tx.expect(f"SET_TIME {now:%Y-%m-%d %H:%M:%S}")
    tx.expect("TIME_BASE")
    transmit(tx, 10, clock, sleep)
    base = str(tx_status(tx)["base_s"])
    deadline = clock() + rx_wait
    while True:
        state = fields(rx.expect("STATUS"))
        journal.log("rx_status", phase="time_base", fields=state)
        if state.get("fpga") != "1":
            raise TrialError("RX FPGA disconnected")
        if state.get("base_s") == base and state.get("type") == "1" and state.get("time_valid") == "1":
            break
        if clock() >= deadline:
            ledger.rx_status_final = state
            ledger.health_final = health(rx, ledger, journal)
            journal.log("time_base_unconfirmed", expected_base_s=base, rx_status=state,
                        fpga_health=ledger.health_final, data_sent=False)
            raise TrialError(f"RX did not confirm this TIME_BASE: expected base_s={base}; "
                             f"received base_s={state.get('base_s')} type={state.get('type')} "
                             f"time_valid={state.get('time_valid')}; no DATA sent")
        sleep(.1)
    rx.expect("BER START", "OK BER ACK")
    ledger.rx_status_baseline = rx_status(rx)
    ledger.health_baseline = health(rx, ledger, journal)
    measurement_start = clock()
    for sequence in range(count):
        payload = payload_for(ledger.batch, sequence)
        tx.expect(f"META 2 0 {sequence & 255}")
        tx.expect(f"PAYLOAD {payload.hex().upper()}")
        attempt = {"payload": payload, "tx": "pending", "elapsed_s": 0.0,
                   "rx_window_complete": False}
        ledger.attempts[sequence] = attempt
        journal.log("attempt", batch=ledger.batch, sequence=sequence, payload_hex=payload.hex(), tx="pending")
        start = clock()
        try:
            transmit(tx, 41, clock, sleep)
            attempt["tx"] = "complete"
            journal.log("tx_complete", sequence=sequence)
        except BaseException:
            attempt["tx"] = "unresolved"
            ledger.tx_unresolved += 1
            attempt["elapsed_s"] = clock() - start
            journal.log("tx_unresolved", sequence=sequence)
            raise
        try:
            end = clock() + rx_wait
            while True:
                drain(rx, ledger, journal)
                if clock() >= end:
                    attempt["rx_window_complete"] = True
                    break
                sleep(.1)
        finally:
            attempt["elapsed_s"] = clock() - start
            ledger.measurement_elapsed_s = clock() - measurement_start
        journal.log("trial", sequence=sequence, report=ledger.report())
        ledger.health_final = health(rx, ledger, journal)
    rx.expect("BER STOP", "OK BER ACK")
    deadline = clock() + 2
    while drain(rx, ledger, journal)["state"] & 2:
        if clock() >= deadline:
            raise TrialError("final diagnostic publish did not finish")
        sleep(.05)
    ledger.measurement_elapsed_s = clock() - measurement_start
    ledger.rx_status_final = rx_status(rx)
    ledger.health_final = health(rx, ledger, journal)
    journal.log("rx_status", phase="final", fields=ledger.rx_status_final)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--tx", required=True)
    parser.add_argument("--rx", required=True)
    parser.add_argument("--count", type=int, default=10)
    parser.add_argument("--batch", type=lambda x: int(x, 0), default=int.from_bytes(os.urandom(4), "big"))
    parser.add_argument("--amp", type=int, default=256)
    parser.add_argument("--rx-wait", type=float, default=1.0)
    parser.add_argument("--output", type=Path, default=Path("_codex/ber_20261102") / ("trial_" + dt.datetime.now().strftime("%Y%m%d_%H%M%S")))
    args = parser.parse_args()
    if args.tx.casefold() == args.rx.casefold() or not 1 <= args.count <= 0xFFFFFFFF or not 0 <= args.batch <= 0xFFFFFFFF or not 0 <= args.amp <= 2047 or not math.isfinite(args.rx_wait) or args.rx_wait < 0:
        parser.error("two distinct ports, count>0, uint32 batch, amplitude 0..2047 and nonnegative wait required")
    args.output.mkdir(parents=True, exist_ok=False)
    journal = Journal(args.output / "raw.jsonl")
    journal.log("configuration", tx=args.tx, rx=args.rx, batch=args.batch, count=args.count, amplitude=args.amp, rx_wait=args.rx_wait,
                control_byte_gap_us=round(CONTROL_BYTE_GAP * 1_000_000))
    ledger = Ledger(args.batch)
    devices = []
    result, error = "aborted", None
    try:
        for name, port in (("TX", args.tx), ("RX", args.rx)):
            conn = serial.Serial(port, 115200, timeout=.05, write_timeout=1, rtscts=False, dsrdtr=False, xonxoff=False)
            devices.append(Device(name, conn, journal))
        run(*devices, ledger, journal, args.count, args.amp, args.rx_wait)
        result = "complete"
    except (Exception, KeyboardInterrupt) as exc:
        error = f"{type(exc).__name__}: {exc}"
        journal.log("abort", error=error)
    finally:
        for device in devices:
            try:
                stop = "STOP" if device.name == "TX" else "BER STOP"
                if device.poisoned:
                    device.emergency_stop(stop)
                else:
                    journal.log("cleanup_stop", device=device.name, command=stop)
                    device.expect(stop, "OK" if device.name == "TX" else "OK BER ACK")
                    if device.name == "TX":
                        tx_uart_diagnostics(device, ledger, journal)
            except Exception as exc:
                journal.log("cleanup_error", device=device.name, error=str(exc))
            try:
                device.port.close()
            except Exception as exc:
                journal.log("cleanup_error", device=device.name, error=str(exc))
        report = {"state": result, "error": error, **json.loads(ledger.audit())}
        (args.output / "report.json").write_text(json.dumps(report, indent=2), encoding="utf-8")
        journal.log("report", **report)
        journal.file.close()
    print(json.dumps(report, indent=2))
    return 0 if result == "complete" else 1


if __name__ == "__main__":
    raise SystemExit(main())
