#!/usr/bin/env python3
"""Standalone read-only UART probe. No SEND, STOP or target resets.

Close Flutter/serial monitors first. A timeout ends requests on that port; late
bytes are only recorded, never associated with a subsequent command. Opening a
port can change adapter control lines even when DTR/RTS are set before open.
No buffers are explicitly cleared by this script; pyserial 3.5 on Windows
purges buffers as part of opening a port. Pre-open traffic is not preserved.
"""
from __future__ import annotations

import argparse
from contextlib import ExitStack
import datetime as dt
import json
from pathlib import Path
import re
import time
import uuid

import serial
from serial.tools import list_ports
from win32_serial_diagnostics import WindowsCommObserver

ROOT = Path(__file__).resolve().parents[2]
ARTIFACTS = ROOT / "_codex/ber_20261102"


class Journal:
    def __init__(self, path):
        self.file = path.open("x", encoding="utf-8")

    def log(self, kind, **fields):
        event = {"utc": dt.datetime.now(dt.timezone.utc).isoformat(),
                 "monotonic_s": time.monotonic(), "kind": kind, **fields}
        self.file.write(json.dumps(event, ensure_ascii=True) + "\n")
        self.file.flush()
        if kind in {"tx", "reply", "failure", "open", "close", "windows_comm_error"}:
            print(json.dumps(event, ensure_ascii=True), flush=True)


class ProbeFailure(Exception):
    def __init__(self, reason, **details):
        super().__init__(reason)
        self.reason, self.details = reason, details


class Probe:
    def __init__(self, port, role, journal, clock=time.monotonic, observer=None):
        self.port, self.role, self.journal, self.clock = port, role, journal, clock
        self.poisoned = False
        self.observer = observer

    def ensure_driver_clean(self):
        if self.observer is not None and self.observer.flag_observations:
            summary = self.observer.summary()
            raise ProbeFailure("windows_comm_error", flags=summary["combined_flags"],
                               names=summary["names"])

    def receive(self, phase):
        if self.observer is not None:
            self.observer.phase = phase
        chunk = self.port.read(min(4096, max(1, self.port.in_waiting)))
        if chunk:
            self.journal.log("rx", device=self.role, phase=phase,
                             rx_hex=chunk.hex().upper(), rx_repr=repr(chunk))
        return chunk

    def observe(self, seconds, phase):
        end, captured = self.clock() + seconds, bytearray()
        while self.clock() < end:
            chunk = self.receive(phase)
            captured.extend(chunk)
            if len(captured) > 65536:
                self.poisoned = True
                raise ProbeFailure("unsolicited_receive_limit", phase=phase)
        return bytes(captured)

    def request(self, command, timeout, eol):
        # An allowlist, not a general firmware command console.
        if command not in ("STATUS", "UART DIAG"):
            raise ValueError("Only STATUS and UART DIAG are permitted")
        if self.poisoned:
            raise ProbeFailure("session_unresolved")
        packet = command.encode("ascii") + eol
        received = bytearray()
        started = self.clock()
        try:
            if self.observer is not None:
                self.observer.phase = "before_command"
            # Never silently discard a stale response or a partial old line.
            if self.port.in_waiting:
                self.receive("before_command")
                raise ProbeFailure("unsolicited_before_command")
            self.ensure_driver_clean()
            self.journal.log("tx", device=self.role, command=command,
                             tx_hex=packet.hex().upper())
            if self.observer is not None:
                self.observer.phase = "write"
            written = self.port.write(packet)
            self.journal.log("write_result", device=self.role, written=written,
                             requested=len(packet))
            if written != len(packet):
                raise ProbeFailure("partial_write", written=written)
            # No flush(): some serial backends can block there without a bound.
            while self.clock() - started < timeout:
                received.extend(self.receive("response"))
                if len(received) > 4096:
                    raise ProbeFailure("response_too_long")
                if b"\n" not in received:
                    continue
                raw, _, rest = received.partition(b"\n")
                if rest.strip(b"\r\n"):
                    raise ProbeFailure("multiple_or_trailing_response_bytes")
                try:
                    line = raw.removesuffix(b"\r").decode("ascii")
                except UnicodeDecodeError as exc:
                    raise ProbeFailure("non_ascii_response") from exc
                self.journal.log("reply", device=self.role, command=command,
                                 line=line, elapsed_ms=round((self.clock()-started)*1000, 3))
                if line == "ERR" or line.startswith("ERR "):
                    raise ProbeFailure("device_rejected_command", line=line)
                if not line.startswith("OK "):
                    raise ProbeFailure("unrecognized_response", line=line)
                fields = dict(re.findall(r"([a-zA-Z0-9_]+)=([^\s]*)", line))
                required = (("run", "mode", "fs", "err", "dmaerr", "hde", "hae")
                            if self.role == "TX" else ("fpga", "ver", "result"))
                if command == "UART DIAG":
                    required = ("schema", "ore", "rxovf", "rearmfail", "cmderr")
                    if not line.startswith("OK UART DIAG "):
                        raise ProbeFailure("wrong_diagnostic_response", line=line)
                missing = [key for key in required if key not in fields]
                if missing:
                    raise ProbeFailure("wrong_device_or_missing_fields", missing=missing, line=line)
                for key in required:
                    try:
                        if int(fields[key], 10) < 0:
                            raise ValueError()
                    except ValueError as exc:
                        raise ProbeFailure("invalid_numeric_field", field=key, line=line) from exc
                self.ensure_driver_clean()
                return {"command": command, "line": line, "fields": fields,
                        "elapsed_ms": round((self.clock()-started)*1000, 3)}
            self.ensure_driver_clean()
            raise ProbeFailure("timeout_no_bytes" if not received else "timeout_partial_line")
        except (ProbeFailure, serial.SerialException, OSError):
            self.poisoned = True
            self.journal.log("failure", device=self.role, command=command,
                             partial_rx_hex=received.hex().upper(),
                             elapsed_ms=round((self.clock()-started)*1000, 3))
            raise


def check_port(role, name, args, journal, factory=serial.Serial, clock=time.monotonic,
               observer_factory=WindowsCommObserver):
    result = {"device": role, "port": name, "passed": False, "responses": []}
    port = probe = None
    observer = None
    stack = ExitStack()
    try:
        port = factory(port=None, baudrate=115200, bytesize=serial.EIGHTBITS,
                       parity=serial.PARITY_NONE, stopbits=serial.STOPBITS_ONE,
                       timeout=0.02, write_timeout=args.timeout,
                       xonxoff=False, rtscts=False, dsrdtr=False)
        # Explicit settings, captured for reproduction; no DTR/RTS pulsing.
        port.dtr = args.dtr == "on"
        port.rts = args.rts == "on"
        port.port = name
        observer = stack.enter_context(observer_factory(port, role, journal))
        port.open()
        journal.log("open", device=role, port=name, baudrate=115200,
                    dtr=port.dtr, rts=port.rts, settings=port.get_settings())
        probe = Probe(port, role, journal, clock, observer)
        if probe.observe(args.settle, "open_settle"):
            raise ProbeFailure("unsolicited_on_open_no_command_sent")
        probe.ensure_driver_clean()
        commands = ["STATUS"] * args.rounds
        if role == "TX" and args.uart_diag:
            commands.append("UART DIAG")
        for index, command in enumerate(commands):
            if index and probe.observe(args.interval, "between_commands"):
                raise ProbeFailure("unsolicited_between_commands")
            result["responses"].append(probe.request(command, args.timeout,
                {"lf": b"\n", "crlf": b"\r\n", "cr": b"\r"}[args.eol]))
        if probe.observe(args.late_wait, "after_last_reply"):
            raise ProbeFailure("unsolicited_after_last_reply")
        probe.ensure_driver_clean()
        result["passed"] = True
    except ProbeFailure as exc:
        result.update(reason=exc.reason, **exc.details)
        journal.log("failure", device=role, reason=exc.reason, **exc.details)
        if probe is not None:
            try:
                # Only observe. No STOP, retry, or new diagnostic command.
                late = probe.observe(args.late_wait, "late_after_failure")
                result["late_rx_hex"] = late.hex().upper()
            except (ProbeFailure, serial.SerialException, OSError) as late_exc:
                result["late_read_error"] = str(late_exc)
    except (serial.SerialException, OSError) as exc:
        result.update(reason="serial_open_or_io_error", error=str(exc))
        journal.log("failure", device=role, reason=result["reason"], error=str(exc))
    except KeyboardInterrupt:
        result.update(reason="interrupted")
        journal.log("failure", device=role, reason="interrupted")
    finally:
        if port is not None and port.is_open:
            try:
                port.close()
                journal.log("close", device=role)
            except (serial.SerialException, OSError) as exc:
                result.update(passed=False, close_error=str(exc))
        stack.close()
        if observer is not None:
            result["windows_driver"] = observer.summary()
        journal.log("device_result", **result)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--list", action="store_true", help="List ports without opening them")
    parser.add_argument("--tx", help="TX port, for example COM6")
    parser.add_argument("--rx", help="RX port, for example COM29; checked independently")
    parser.add_argument("--rounds", type=int, default=1, help="STATUS rounds; only after a valid prior reply")
    parser.add_argument("--uart-diag", action="store_true", help="TX UART DIAG only after STATUS succeeds")
    parser.add_argument("--timeout", type=float, default=2.0)
    parser.add_argument("--settle", type=float, default=0.3)
    parser.add_argument("--interval", type=float, default=0.2)
    parser.add_argument("--late-wait", type=float, default=0.5)
    parser.add_argument("--eol", choices=("lf", "crlf", "cr"), default="lf")
    parser.add_argument("--dtr", choices=("off", "on"), default="off")
    parser.add_argument("--rts", choices=("off", "on"), default="off")
    parser.add_argument("--output", type=Path, default=ARTIFACTS)
    args = parser.parse_args()
    if args.list:
        ports = list(list_ports.comports())
        for port in ports:
            print(json.dumps({"port": port.device, "description": port.description,
                              "hwid": port.hwid}, ensure_ascii=True))
        if not ports:
            print("No serial ports detected; no port was opened.")
        return 0
    if not args.tx and not args.rx:
        parser.error("Specify --tx and/or --rx, or --list")
    if args.tx and args.rx and args.tx.casefold() == args.rx.casefold():
        parser.error("TX and RX must be distinct ports")
    import math
    if not 1 <= args.rounds <= 100 or any(not math.isfinite(v) for v in
            (args.timeout, args.settle, args.interval, args.late_wait)) or not (
            0.1 <= args.timeout <= 30 and 0 <= args.settle <= 10 and
            0 <= args.interval <= 10 and 0 <= args.late_wait <= 10):
        parser.error("Invalid rounds or durations")
    if not args.output.resolve().is_relative_to(ARTIFACTS.resolve()):
        parser.error("Output must be inside _codex/ber_20261102")
    out = args.output / ("serial_check_" + dt.datetime.now().strftime("%Y%m%d_%H%M%S_") + uuid.uuid4().hex[:6])
    out.mkdir(parents=True, exist_ok=False)
    journal = Journal(out / "raw.jsonl")
    report = {"operation": "read_only_serial_check", "configuration": {
        key: str(value) if isinstance(value, Path) else value for key, value in vars(args).items()},
        "results": [], "flashed": False, "sends_allowed": False}
    print("Audit directory:", out, flush=True)
    try:
        journal.log("configuration", **report["configuration"])
        for role, name in (("TX", args.tx), ("RX", args.rx)):
            if name:
                result = check_port(role, name, args, journal)
                report["results"].append(result)
                if result.get("reason") == "interrupted":
                    report["interrupted"] = True
                    break
    except KeyboardInterrupt:
        report["interrupted"] = True
    finally:
        with (out / "report.json").open("x", encoding="utf-8") as handle:
            json.dump(report, handle, indent=2, ensure_ascii=True)
        journal.file.close()
    for result in report["results"]:
        print(result["device"], result["port"], "PASS" if result["passed"] else "FAIL",
              result.get("reason", ""), result.get("error", ""))
    return 0 if not report.get("interrupted") and all(r["passed"] for r in report["results"]) else 1


if __name__ == "__main__":
    raise SystemExit(main())
