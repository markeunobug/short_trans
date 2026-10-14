#!/usr/bin/env python3
"""End-to-end TX(COM9) -> RX(COM6) lower-computer smoke test.

The script uses the ASCII diagnostic protocol from codex/UPPER_COMPUTER_PROTOCOL.md.
It verifies UART command responses first, then sends TIME_BASE and one DATA frame.
"""

from __future__ import annotations

import argparse
import datetime as dt
import re
import sys
import time
from dataclasses import dataclass

import serial


BAUD = 115200
HEX_RE = re.compile(r"^[0-9A-F]+$")


@dataclass
class Device:
    name: str
    port: serial.Serial

    def command(self, text: str, timeout: float = 1.0) -> str:
        self.port.reset_input_buffer()
        packet = (text + "\n").encode("ascii")
        self.port.write(packet)
        self.port.flush()
        deadline = time.monotonic() + timeout
        lines: list[str] = []
        while time.monotonic() < deadline:
            raw = self.port.readline()
            if raw:
                line = raw.decode("ascii", errors="replace").strip()
                if line:
                    lines.append(line)
                    # Firmware emits one response per command.
                    break
            else:
                time.sleep(0.005)
        response = lines[0] if lines else ""
        print(f"  {self.name} TX> {text}")
        print(f"  {self.name} RX< {response or '<timeout>'}")
        return response


def expect(device: Device, command: str, prefix: str = "OK") -> str:
    response = device.command(command)
    if not response.startswith(prefix):
        raise AssertionError(f"{device.name} {command!r}: expected {prefix}, got {response!r}")
    return response


def status_fields(response: str) -> dict[str, str]:
    return dict(re.findall(r"([A-Za-z0-9_]+)=([^\s]+)", response))


DIAGNOSTIC_FIELDS = (
    "fpga_status0",
    "fpga_errors",
    "fpga_frames",
    "fpga_fifo_bytes",
    "fpga_good",
    "fpga_crc_errors",
)


def numeric_field(fields: dict[str, str], key: str) -> int | None:
    value = fields.get(key)
    if value is None:
        return None
    try:
        return int(value, 16 if value.lower().startswith("0x") else 10)
    except ValueError:
        return None


def good_count(fields: dict[str, str]) -> int:
    return numeric_field(fields, "fpga_good") or 0


def print_diagnostics(label: str, fields: dict[str, str]) -> None:
    values = " ".join(
        f"{key}={fields[key]}" for key in DIAGNOSTIC_FIELDS if key in fields
    )
    print(f"  {label}: {values or '<firmware has no FPGA diagnostic fields>'}")


def try_clear_errors(rx: Device) -> bool:
    response = rx.command("CLEAR_ERRORS")
    if response.startswith("OK"):
        print("  RX diagnostics cleared")
        return True
    if response.startswith("ERR"):
        print(f"  RX CLEAR_ERRORS unsupported: {response}")
        return False
    print(f"  RX CLEAR_ERRORS response unavailable: {response or '<timeout>'}")
    return False


def diagnostic_delta(before: dict[str, str], after: dict[str, str]) -> str:
    parts = []
    for key in DIAGNOSTIC_FIELDS:
        old = numeric_field(before, key)
        new = numeric_field(after, key)
        if old is not None and new is not None:
            parts.append(f"{key} {old}->{new} (Δ{new - old:+d})")
    return " ".join(parts) or "<no numeric diagnostic fields>"


def read_payload(response: str) -> tuple[str, dict[str, str]] | None:
    match = re.match(r"^OK DATA(?:\s+(\S+))?\s+time_valid=(\d+)\s+timestamp_ms=(\d+)$", response)
    if not match:
        return None
    payload = (match.group(1) or "").upper()
    return payload, {
        "time_valid": match.group(2),
        "timestamp_ms": match.group(3),
    }


def wait_for_payload(rx: Device, expected: str, timeout: float) -> str:
    deadline = time.monotonic() + timeout
    last = ""
    while time.monotonic() < deadline:
        last = rx.command("READ", timeout=1.0)
        parsed = read_payload(last)
        if parsed is not None:
            payload, fields = parsed
            if payload == expected:
                print(f"  PASS RX DATA {payload} time_valid={fields['time_valid']}")
                return payload
        time.sleep(0.1)
    raise AssertionError(f"RX did not return {expected}; last response was {last!r}")


def wait_for_status(rx: Device, predicate, description: str, timeout: float) -> dict[str, str]:
    deadline = time.monotonic() + timeout
    last: dict[str, str] = {}
    while time.monotonic() < deadline:
        response = rx.command("STATUS", timeout=1.0)
        last = status_fields(response)
        if predicate(last):
            return last
        time.sleep(0.1)
    raise AssertionError(f"RX did not reach {description}; last STATUS was {last}")


def wait_for_device_status(device: Device, predicate, description: str, timeout: float) -> dict[str, str]:
    deadline = time.monotonic() + timeout
    last: dict[str, str] = {}
    while time.monotonic() < deadline:
        last = status_fields(device.command("STATUS", timeout=1.0))
        if predicate(last):
            return last
        time.sleep(0.1)
    raise AssertionError(f"{device.name} did not reach {description}; last STATUS was {last}")


def wait_for_tx_status(tx: Device, old_base: str | None, timeout: float) -> dict[str, str]:
    """Avoid sending STATUS while the TX UART is still transmitting a frame."""
    deadline = time.monotonic() + timeout
    time.sleep(1.0)
    last: dict[str, str] = {}
    while time.monotonic() < deadline:
        last = status_fields(tx.command("STATUS", timeout=1.0))
        if last.get("run") == "0" and last.get("time_base_pending") == "0" \
                and last.get("base_s") not in (None, old_base):
            return last
        time.sleep(1.0)
    raise AssertionError(f"TX did not finish TIME_BASE; last STATUS was {last}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--tx", default="COM9", help="TX serial port (default: COM9)")
    parser.add_argument("--rx", default="COM6", help="RX serial port (default: COM6)")
    parser.add_argument("--payload", default="0102030405", help="test DATA payload in HEX")
    parser.add_argument("--amp", type=int, default=512, help="TX amplitude 0..2047")
    parser.add_argument("--payloads", help="comma-separated payloads for repeated DATA frames")
    parser.add_argument("--wait", type=float, default=8.0, help="seconds to wait for each frame")
    parser.add_argument("--no-time-base", action="store_true", help="skip TIME_BASE and only test DATA")
    args = parser.parse_args()

    payload = args.payload.replace(" ", "").upper()
    if not payload or len(payload) % 2 or len(payload) > 128 or not HEX_RE.fullmatch(payload):
        parser.error("--payload must be an even-length HEX string of at most 64 bytes")
    if not 0 <= args.amp <= 2047:
        parser.error("--amp must be in range 0..2047")
    payloads = [item.replace(" ", "").upper() for item in args.payloads.split(",")] if args.payloads else [payload]
    for item in payloads:
        if not item or len(item) % 2 or len(item) > 128 or not HEX_RE.fullmatch(item):
            parser.error("every --payloads item must be an even-length HEX string of at most 64 bytes")

    tx_port: serial.Serial | None = None
    rx_port: serial.Serial | None = None
    try:
        tx_port = serial.Serial(args.tx, BAUD, timeout=0.2, write_timeout=1.0)
        rx_port = serial.Serial(args.rx, BAUD, timeout=0.2, write_timeout=1.0)
        tx = Device("TX", tx_port)
        rx = Device("RX", rx_port)
        print(f"OPEN TX={args.tx} RX={args.rx} 115200-8-N-1")

        print("[1/5] UART command checks")
        expect(tx, "HELP")
        expect(tx, "STATUS")
        expect(rx, "PING", "OK PONG")
        expect(rx, "HELP")
        rx_status = expect(rx, "STATUS")
        fields = status_fields(rx_status)
        if fields.get("fpga") != "1":
            raise AssertionError(f"RX FPGA is not connected: {rx_status}")
        print_diagnostics("RX diagnostic baseline before clear", fields)
        try_clear_errors(rx)
        rx_baseline = status_fields(expect(rx, "STATUS"))
        print_diagnostics("RX diagnostic baseline", rx_baseline)

        print("[2/5] Configure TX packet mode")
        expect(tx, "STOP")
        expect(tx, "MODE PACKET")
        expect(tx, f"AMP {args.amp}")

        if not args.no_time_base:
            print("[3/5] Send TIME_BASE")
            now = dt.datetime.now().replace(microsecond=0)
            old_tx_status = status_fields(expect(tx, "STATUS"))
            old_base = old_tx_status.get("base_s")
            expect(tx, f"SET_TIME {now:%Y-%m-%d %H:%M:%S}")
            expect(tx, "TIME_BASE")
            expect(tx, "SEND")
            # TX applies the new base when the TIME_BASE frame starts, so read
            # STATUS after SEND rather than while time_base_pending is set.
            tx_time_status = wait_for_tx_status(tx, old_base, 5.0)
            expected_base = tx_time_status.get("base_s")
            if expected_base is None:
                raise AssertionError(f"TX STATUS has no base_s: {tx_time_status}")
            wait_for_status(
                rx,
                lambda fields: fields.get("base_s") == expected_base
                and fields.get("type") == "1"
                and good_count(fields) > good_count(rx_baseline),
                f"TIME_BASE base_s={expected_base}",
                args.wait,
            )
            wait_for_payload(rx, "", 1.0)
        else:
            print("[3/5] TIME_BASE skipped")

        print(f"[4/5] Send {len(payloads)} DATA payload(s)")
        for index, data_payload in enumerate(payloads, start=1):
            expect(tx, f"PAYLOAD {data_payload}")
            expect(tx, "SEND")
            data_good_before = good_count(status_fields(expect(rx, "STATUS")))
            wait_for_status(
                rx,
                lambda fields, expected=len(data_payload) // 2, before=data_good_before:
                    fields.get("len") == str(expected)
                    and fields.get("type") == "0"
                    and good_count(fields) > before,
                f"DATA {index}/{len(payloads)} len={len(data_payload) // 2}",
                args.wait,
            )
            wait_for_payload(rx, data_payload, 1.0)

        print("[5/5] Final RX status")
        final_status = expect(rx, "STATUS")
        final_fields = status_fields(final_status)
        print(f"  PASS final RX STATUS: {final_status}")
        print(f"  RX diagnostic delta: {diagnostic_delta(rx_baseline, final_fields)}")
        print("RESULT: PASS")
        return 0
    except (AssertionError, serial.SerialException) as exc:
        if 'rx' in locals():
            try:
                print("DIAGNOSTIC RX STATUS")
                print(f"  {rx.command('STATUS')}")
            except (serial.SerialException, OSError):
                pass
        if 'tx' in locals():
            try:
                print("DIAGNOSTIC TX STATUS")
                print(f"  {tx.command('STATUS')}")
            except (serial.SerialException, OSError):
                pass
        print(f"RESULT: FAIL: {exc}", file=sys.stderr)
        return 1
    finally:
        if tx_port is not None:
            tx_port.close()
        if rx_port is not None:
            rx_port.close()


if __name__ == "__main__":
    raise SystemExit(main())
