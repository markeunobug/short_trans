#!/usr/bin/env python3
"""Send ASCII commands to the half-duplex RS485 firmware and log raw bytes."""

from __future__ import annotations

import argparse
import time

import serial
from serial.rs485 import RS485Settings


LINE_ENDINGS = {
    "cr": b"\r",
    "lf": b"\n",
    "crlf": b"\r\n",
}


def printable(data: bytes) -> str:
    return data.decode("ascii", errors="backslashreplace").replace("\r", "\\r").replace(
        "\n", "\\n"
    )


def read_response(port: serial.Serial, timeout_s: float, quiet_s: float) -> bytes:
    response = bytearray()
    deadline = time.monotonic() + timeout_s
    last_byte_time: float | None = None

    while time.monotonic() < deadline:
        waiting = port.in_waiting
        if waiting:
            response.extend(port.read(waiting))
            last_byte_time = time.monotonic()
            continue

        if last_byte_time is not None and time.monotonic() - last_byte_time >= quiet_s:
            break
        time.sleep(0.001)

    return bytes(response)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("commands", nargs="*", default=["HELP", "STATUS"])
    parser.add_argument("--port", default="COM40")
    parser.add_argument("--baud", type=int, default=115200)
    parser.add_argument("--ending", choices=LINE_ENDINGS, default="lf")
    parser.add_argument("--timeout", type=float, default=1.0)
    parser.add_argument("--quiet", type=float, default=0.05)
    parser.add_argument("--open-delay", type=float, default=0.1)
    parser.add_argument("--rts-tx", action="store_true")
    parser.add_argument("--dtr-tx", action="store_true")
    parser.add_argument("--active-low", action="store_true")
    parser.add_argument("--listen-only", action="store_true")
    parser.add_argument("--rs485-mode", action="store_true")
    args = parser.parse_args()
    if args.rs485_mode and args.active_low:
        parser.error("Windows pyserial RS485 mode only supports active-high RTS")

    with serial.Serial(
        port=args.port,
        baudrate=args.baud,
        bytesize=serial.EIGHTBITS,
        parity=serial.PARITY_NONE,
        stopbits=serial.STOPBITS_ONE,
        timeout=0,
        write_timeout=1.0,
        rtscts=False,
        dsrdtr=False,
        xonxoff=False,
    ) as port:
        receive_level = args.active_low
        transmit_level = not receive_level
        if args.rs485_mode:
            port.rs485_mode = RS485Settings(
                rts_level_for_tx=transmit_level,
                rts_level_for_rx=receive_level,
                loopback=False,
            )
        port.dtr = receive_level if args.dtr_tx else False
        port.rts = receive_level if args.rts_tx else False
        time.sleep(args.open_delay)
        port.reset_input_buffer()
        port.reset_output_buffer()

        print(f"OPEN {port.port} {port.baudrate}-8-N-1 ending={args.ending}")
        if args.listen_only:
            response = read_response(port, args.timeout, args.quiet)
            if response:
                print(f"RX {printable(response)}")
                print(f"RX_HEX {response.hex(' ').upper()}")
            else:
                print("RX <timeout>")
            return 0

        for command in args.commands:
            packet = command.encode("ascii") + LINE_ENDINGS[args.ending]
            if args.rts_tx:
                port.rts = transmit_level
            if args.dtr_tx:
                port.dtr = transmit_level
            if args.rts_tx or args.dtr_tx:
                time.sleep(0.001)
            port.write(packet)
            port.flush()
            if args.rts_tx or args.dtr_tx:
                time.sleep((len(packet) * 10.0 / args.baud) + 0.001)
            if args.rts_tx:
                port.rts = receive_level
            if args.dtr_tx:
                port.dtr = receive_level
            print(f"TX {printable(packet)}")
            print(f"TX_HEX {packet.hex(' ').upper()}")

            response = read_response(port, args.timeout, args.quiet)
            if response:
                print(f"RX {printable(response)}")
                print(f"RX_HEX {response.hex(' ').upper()}")
            else:
                print("RX <timeout>")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
