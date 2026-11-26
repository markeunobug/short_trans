"""No hardware tests: wire vectors, accounting, and dual-device controller."""
import dataclasses
import contextlib
import io
import json
from pathlib import Path
import struct
import unittest
from unittest.mock import patch
import uuid

import ber_test

from ber_protocol import (Capture, Ledger, crc8, crc16, parse_hex_reply,
                          parse_record, parse_status, payload_for)
from ber_test import Device, TrialError, ber_data, drain, run, transmit


def record(payload, cid=1, sequence=None, flips=(), bits=328, reason=2):
    if sequence is None:
        sequence = int.from_bytes(payload[4:8], "big")
    header = bytes((0x20, sequence & 255, 32))
    body = header + bytes([crc8(header)]) + b"\x00\x12\x34" + payload
    raw = bytearray(body + crc16(body).to_bytes(2, "big"))
    for byte, mask in flips:
        raw[byte] ^= mask
    count = (bits + 7) // 8
    if bits % 8:
        raw[count - 1] &= 0xFF << (8 - bits % 8)
    raw[count:] = bytes(41 - count)
    flags = (1 if bits == 328 else reason)
    if bits >= 32 and crc8(raw[:3]) == raw[3]:
        flags |= 16
    if bits == 328:
        flags |= 64
        if crc16(raw[:39]) == int.from_bytes(raw[39:], "big"):
            flags |= 32
    return b"BR01" + struct.pack("<IHBBI", cid, bits, flags, count, 1234) + raw + bytes(7)


def hex_reply(prefix, data):
    return prefix + data.hex().upper() + f" crc={crc16(data):04X}"


class Clock:
    def __init__(self):
        self.now = 0.0

    def __call__(self):
        return self.now

    def sleep(self, duration):
        self.now += duration


class Log:
    def __init__(self):
        self.events = []

    def log(self, kind, **kw):
        self.events.append((kind, kw))


class Link:
    def __init__(self, clock, outcomes=("good",)):
        self.clock = clock
        self.outcomes = outcomes
        self.queue = []
        self.payload = b""
        self.latest = b""
        self.base_pending = False
        self.base_done = False
        self.running_until = 0
        self.sends = 0
        self.enabled = False
        self.started = self.committed = self.popped = self.dropped = 0
        self.bad_transport_once = False
        self.pop_spi_error = False
        self.tx_fault = None
        self.command_errors = 0
        self.last_bad_hex = ""
        self.rx_mode = "FSK"
        self.config_pending_reads = 0
        self.pending_after_mod = 0
        self.mode_commits = 0
        self.config_stuck = False
        self.config_error = False
        self.stale_base = False

    def status(self):
        count = len(self.queue)
        state = 16 | int(self.enabled) | (4 if count else 0) | (8 if count == 8 else 0)
        return b"BS01" + bytes((state, count, 8, 64)) + struct.pack("<6I", self.started, self.dropped, self.committed, 0, self.popped, 0)

    def tx(self, command):
        if command == "STATUS":
            running = int(self.clock() < self.running_until)
            if self.tx_fault == "never":
                running = 0
            if self.tx_fault == "stuck" and self.sends:
                running = 1
            dma = int(self.tx_fault == "dma" and self.sends > 0)
            if self.tx_fault == "command_error" and self.sends > 1 and self.clock() < self.running_until:
                self.command_errors += 1
                self.last_bad_hex = "5441545553"
                return "ERR COMMAND"
            return f"OK run={running} mode={5 if running else 0} mod=FSK fs=48000 err=0 dmaerr={dma} hde=0 hae=0 time_base_pending={int(self.base_pending)} time_valid=1 len={len(self.payload)} base_s=123"
        if command == "UART DIAG":
            return f"OK UART DIAG rxerr=0 rxovf=0 lineovf=0 cmderr={self.command_errors} badlen={len(self.last_bad_hex)//2} badhex={self.last_bad_hex} rendermax=1200 uartbudget=13021 renderlate=0 renders=4 dwt=1"
        if command.startswith("SET_TIME") or command == "TIME_BASE":
            self.base_pending = True
        if command.startswith("PAYLOAD "):
            self.payload = bytes.fromhex(command.split()[1])
        if command == "SEND":
            self.sends += 1
            if self.base_pending:
                self.base_done = True
                self.base_pending = False
                body_bytes = 10
            else:
                body_bytes = 41
                sequence = int.from_bytes(self.payload[4:8], "big")
                outcome = self.outcomes[sequence % len(self.outcomes)]
                if outcome == "interrupt":
                    raise KeyboardInterrupt()
                if outcome == "good":
                    self.latest = self.payload
                if self.enabled and outcome != "lost":
                    flips = ((22, 0x15),) if outcome == "bad_crc" else ((8, 1),) if outcome == "identity" else ()
                    self.started += 1
                    self.queue.append(record(self.payload, self.started, flips=flips))
                    self.committed += 1
            self.running_until = self.clock() + (32 + body_bytes * 8) / 100 + .2
        return "OK MOD FSK" if command == "MOD FSK" else "OK"

    def rx(self, command):
        if command == "PING":
            return "OK PONG"
        if command == "ASK STATUS":
            pending = self.config_stuck or self.config_pending_reads > 0
            self.config_pending_reads = max(0, self.config_pending_reads - 1)
            if self.mode_commits and not pending:
                self.rx_mode = "FSK"
            return f"OK ASK STATUS mode={self.rx_mode} low=400 high=600 energy=0 pending={int(pending)} error={int(self.config_error)} generation=0 bit=0 locked=0 ready=0"
        if command == "STATUS":
            return f"OK fpga=1 type={int(self.base_done and not self.latest)} time_valid=1 base_s={122 if self.stale_base else 123} fpga_errors=0 uart_err=0 rx_restart=0 tx_err=0 overflow=0"
        if command == "MOD FSK":
            self.mode_commits += 1
            self.config_pending_reads = self.pending_after_mod
            return "OK MOD FSK pending=1"
        if command == "FSK STATUS":
            return "OK FSK STATUS mode=1 pending=1 error=0 busy=1 sweep=0"
        if command == "READ":
            return f"OK DATA {self.latest.hex().upper()} time_valid=1 timestamp_ms=123000"
        if command == "BER STATUS":
            return hex_reply("OK BER STATUS ", self.status())
        if command == "BER HEALTH":
            return hex_reply("OK BER HEALTH ", b"BH01\xA7\x14" + bytes(14))
        if command == "BER READ":
            if not self.queue:
                return "OK BER EMPTY"
            text = hex_reply("OK BER RECORD ", self.queue[0])
            if self.bad_transport_once:
                self.bad_transport_once = False
                return text[:-4] + "0000"
            return text
        if command.startswith("BER POP "):
            cid = int(command[8:])
            if not self.queue or int.from_bytes(self.queue[0][4:8], "little") != cid:
                return "ERR BER ID"
            self.queue.pop(0)
            self.popped += 1
            return "ERR BER SPI" if self.pop_spi_error else "OK BER ACK"
        if command == "BER START":
            self.enabled = True
        if command == "BER STOP":
            self.enabled = False
        return "OK BER ACK"


class Port:
    def __init__(self, handler, clock, fragment=7):
        self.handler, self.clock, self.fragment = handler, clock, fragment
        self.buf = bytearray()
        self.commands = []
        self.line = bytearray()
        self.writes = []

    @property
    def in_waiting(self):
        return min(self.fragment, len(self.buf))

    def write(self, packet):
        self.writes.append((self.clock(), bytes(packet)))
        for byte in packet:
            if byte in (8, 127):
                if self.line:
                    self.line.pop()
            elif byte in (10, 13):
                if self.line:
                    command = self.line.decode()
                    self.line.clear()
                    self.commands.append(command)
                    answer = self.handler(command)
                    if answer is not None:
                        self.buf.extend((answer + "\r\n").encode())
            else:
                self.line.append(byte)
        return len(packet)

    def read(self, n):
        self.clock.sleep(.001)
        value = bytes(self.buf[:n])
        del self.buf[:n]
        return value

    def flush(self):
        pass

    def close(self):
        pass


class ProtocolTests(unittest.TestCase):
    def test_reference_crc_and_payload(self):
        self.assertEqual(crc16(b"123456789"), 0x29B1)
        self.assertEqual(crc8(b"123456789"), 0xF4)
        self.assertEqual(len(payload_for(123, 456)), 32)
        self.assertEqual(payload_for(123, 456), payload_for(123, 456))
        self.assertNotEqual(payload_for(123, 456), payload_for(123, 457))

    def test_exact_flips_bad_crc(self):
        expected = payload_for(25, 257)
        capture = parse_record(record(expected, flips=((21, 0x85), (38, 1))))
        self.assertEqual(capture.identity, (25, 257))
        self.assertEqual(capture.bit_errors(expected), 4)
        self.assertFalse(capture.flags & 32)

    def test_identity_corruption_no_guess(self):
        for byte in (7, 8, 14, 15, 18):
            self.assertIsNone(parse_record(record(payload_for(25, 257), flips=((byte, 1),))).identity)
        self.assertIsNone(parse_record(record(payload_for(25, 257), sequence=258)).identity)

    def test_partial_padding_and_termination(self):
        for reason in (2, 4, 8):
            for bits in (0, 1, 3, 31, 32, 47, 327):
                capture = parse_record(record(payload_for(25, 257), bits=bits, reason=reason))
                self.assertFalse(capture.complete)
                self.assertIsNone(capture.identity)
        bad = bytearray(record(payload_for(25, 257), bits=3))
        bad[16] |= 1
        with self.assertRaises(ValueError):
            parse_record(bytes(bad))

    def test_transport_rejects_damage(self):
        data = record(payload_for(1, 1))
        reply = hex_reply("OK BER RECORD ", data)
        self.assertEqual(parse_hex_reply(reply, "OK BER RECORD ", 64), data)
        for damaged in (reply[:-1], reply[:-4] + "0000", reply.replace("OK BER", "OK BAD"), reply[:14] + "FF" + reply[16:]):
            if damaged != reply:
                with self.assertRaises(ValueError):
                    parse_hex_reply(damaged, "OK BER RECORD ", 64)

    def test_ledger_zero_duplicates_partial_and_unresolved(self):
        ledger = Ledger(25)
        self.assertIsNone(ledger.report()["per"])
        self.assertIsNone(ledger.report()["ber"])
        for sequence in range(4):
            ledger.attempts[sequence] = {"payload": payload_for(25, sequence), "tx": "complete" if sequence < 3 else "unresolved", "elapsed_s": 4, "rx_window_complete": True}
        self.assertTrue(ledger.note_delivery(payload_for(25, 0)))
        self.assertFalse(ledger.note_delivery(payload_for(25, 0)))
        capture = parse_record(record(payload_for(25, 0)))
        ledger.note_capture(capture)
        ledger.note_capture(capture)
        ledger.note_capture(parse_record(record(payload_for(25, 1), cid=2, flips=((25, 3),))))
        ledger.note_capture(parse_record(record(payload_for(25, 2), cid=3, bits=100)))
        ledger.note_capture(parse_record(record(payload_for(25, 3), cid=4)))
        report = ledger.report()
        self.assertEqual(report["per"], 2 / 3)
        self.assertEqual(report["ber"], 2 / 512)
        self.assertEqual(report["coverage"], 2 / 3)
        self.assertEqual(report["partial_records"], 1)
        self.assertEqual(report["duplicate_captures"], 1)
        self.assertEqual(report["duplicate_deliveries"], 1)
        with self.assertRaises(ValueError):
            ledger.note_capture(dataclasses.replace(capture, flags=0))


class ControllerTests(unittest.TestCase):
    def devices(self, outcomes=("good",)):
        clock, log = Clock(), Log()
        link = Link(clock, outcomes)
        tx = Device("TX", Port(link.tx, clock), log, clock, sleep=clock.sleep)
        rx = Device("RX", Port(link.rx, clock), log, clock, sleep=clock.sleep)
        return clock, log, link, tx, rx

    def test_dual_port_full_trial(self):
        clock, log, link, tx, rx = self.devices(("good", "bad_crc", "identity", "lost"))
        ledger = Ledger(12345)
        link.bad_transport_once = True
        link.pop_spi_error = True
        run(tx, rx, ledger, log, 4, 256, .2, clock.sleep, clock)
        report = ledger.report()
        self.assertEqual(link.sends, 5)  # one TIME_BASE + four DATA, no retransmit
        self.assertEqual(report["tx_completed"], 4)
        self.assertEqual(report["per"], .75)
        self.assertEqual(report["coverage"], .5)
        self.assertEqual(report["payload_bit_errors"], 3)
        self.assertEqual(report["transport_errors"], 1)
        self.assertEqual(link.popped, 3)
        kinds = [kind for kind, _ in log.events]
        self.assertLess(kinds.index("diagnostic_raw"), kinds.index("diagnostic_pop"))

    def test_no_resend_when_completion_unproven(self):
        for fault in ("never", "stuck", "dma"):
            clock, log, link, tx, rx = self.devices()
            link.payload = payload_for(1, 0)
            link.tx_fault = fault
            with self.assertRaises(TrialError):
                transmit(tx, 41, clock, clock.sleep)
            self.assertEqual(tx.port.commands.count("SEND"), 1)

    def test_complete_err_command_is_saved_and_uart_diag_follows_safe_stop(self):
        clock, log, link, tx, rx = self.devices()
        link.tx_fault = "command_error"
        ledger = Ledger(5)
        with self.assertRaisesRegex(TrialError, "STATUS: ERR COMMAND"):
            run(tx, rx, ledger, log, 1, 256, .2, clock.sleep, clock)
        self.assertEqual(ledger.attempts[0]["tx"], "unresolved")
        self.assertEqual(ledger.tx_unresolved, 1)
        tx.expect("STOP")
        from ber_test import tx_uart_diagnostics
        diag = tx_uart_diagnostics(tx, ledger, log)
        self.assertEqual(diag["cmderr"], "1")
        self.assertLess(tx.port.commands.index("STOP"), tx.port.commands.index("UART DIAG"))
        self.assertEqual(link.sends, 2)

    def test_configuration_already_fsk_skips_mod(self):
        clock, log, link, tx, rx = self.devices()
        run(tx, rx, Ledger(12345), log, 1, 256, .2, clock.sleep, clock)
        self.assertEqual(link.mode_commits, 0)
        self.assertEqual(link.sends, 2)

    def test_stale_timebase_not_used_as_new_delivery_or_ber(self):
        clock, log, link, tx, rx = self.devices()
        link.stale_base = True
        ledger = Ledger(123)
        with self.assertRaisesRegex(TrialError, "expected base_s=123.*received base_s=122.*no DATA"):
            run(tx, rx, ledger, log, 1, 100, .2, clock.sleep, clock)
        self.assertEqual(link.sends, 1)
        self.assertEqual(ledger.attempts, {})
        self.assertIsNone(ledger.report()["ber"])
        self.assertEqual(ledger.rx_status_final["base_s"], "122")
        self.assertEqual(len([event for event in log.events if event[0] == "time_base_unconfirmed"]), 1)

    def test_configuration_live_pending_then_settles(self):
        clock, log, link, tx, rx = self.devices()
        link.config_pending_reads = 3
        run(tx, rx, Ledger(12345), log, 1, 256, .2, clock.sleep, clock)
        self.assertEqual(rx.port.commands.count("ASK STATUS"), 4)
        self.assertEqual(link.mode_commits, 0)
        self.assertEqual(link.sends, 2)

    def test_configuration_ook_deferred_commit_once(self):
        clock, log, link, tx, rx = self.devices()
        link.rx_mode = "OOK"
        link.pending_after_mod = 3
        run(tx, rx, Ledger(12345), log, 1, 256, .2, clock.sleep, clock)
        self.assertEqual(link.mode_commits, 1)
        self.assertEqual(link.rx_mode, "FSK")
        self.assertEqual(link.sends, 2)

    def test_configuration_pending_timeout_never_sends(self):
        clock, log, link, tx, rx = self.devices()
        link.config_stuck = True
        ledger = Ledger(12345)
        with self.assertRaisesRegex(TrialError, "after 5s.*pending=1.*busy=1"):
            run(tx, rx, ledger, log, 1, 256, .2, clock.sleep, clock)
        self.assertEqual(link.sends, 0)
        self.assertEqual(link.mode_commits, 0)
        self.assertEqual(ledger.attempts, {})
        self.assertNotIn("BER CLEAR", rx.port.commands)

    def test_configuration_error_does_not_wait_or_send(self):
        clock, log, link, tx, rx = self.devices()
        link.config_error = True
        with self.assertRaisesRegex(TrialError, "configuration rejected.*error=1"):
            run(tx, rx, Ledger(12345), log, 1, 256, .2, clock.sleep, clock)
        self.assertLess(clock(), 1)
        self.assertEqual(link.sends, 0)
        self.assertEqual(link.mode_commits, 0)

    def test_timeout_poisoned_no_next_command(self):
        clock, log = Clock(), Log()
        port = Port(lambda command: None, clock)
        device = Device("TX", port, log, clock, sleep=clock.sleep)
        with self.assertRaises(TrialError):
            device.expect("SEND", timeout=.1)
        with self.assertRaises(TrialError):
            device.expect("STATUS")
        self.assertEqual(port.commands, ["SEND"])

    def test_status_bytes_are_spaced_beyond_observed_uart_blackout(self):
        clock, log, link, tx, rx = self.devices()
        tx.expect("STATUS")
        self.assertEqual(b"".join(packet for _, packet in tx.port.writes), b"STATUS\n")
        times = [when for when, _ in tx.port.writes]
        self.assertTrue(all(b-a >= .00199 for a,b in zip(times, times[1:])))
        self.assertTrue(all(len(packet) == 1 for _, packet in tx.port.writes))

    def test_emergency_stop_erases_partial_send_without_executing_it(self):
        for prefix in (b"STATUS", b"SEND", b"PAYLOAD 1234", b"X" * 159):
            clock, log, link, tx, rx = self.devices()
            tx.poisoned = True
            tx.port.line.extend(prefix)
            tx.emergency_stop("STOP")
            self.assertEqual(tx.port.commands, ["STOP"])
            self.assertEqual(link.sends, 0)
            self.assertTrue(tx.poisoned)

    def test_emergency_stop_does_not_admit_other_commands(self):
        clock, log, link, tx, rx = self.devices()
        with self.assertRaises(TrialError):
            tx.emergency_stop("SEND")
        self.assertEqual(tx.port.writes, [])

    def test_partial_byte_write_poisoned_without_retry_or_terminator(self):
        clock, log, link, tx, rx = self.devices()
        original = tx.port.write
        calls = []
        def write(packet):
            calls.append(packet)
            return 0 if len(calls) == 3 else original(packet)
        tx.port.write = write
        with self.assertRaisesRegex(TrialError, "partial serial write"):
            tx.expect("SEND")
        self.assertTrue(tx.poisoned)
        self.assertEqual(calls, [b"S", b"E", b"N"])
        self.assertEqual(link.sends, 0)

    def test_interrupt_retains_unresolved_attempt(self):
        clock, log, link, tx, rx = self.devices(("interrupt",))
        ledger = Ledger(5)
        with self.assertRaises(KeyboardInterrupt):
            run(tx, rx, ledger, log, 1, 256, .2, clock.sleep, clock)
        self.assertEqual(ledger.attempts[0]["tx"], "unresolved")
        self.assertIsNone(ledger.report()["per"])
        self.assertEqual(ledger.tx_unresolved, 1)
        self.assertEqual(link.sends, 2)

    def test_status_schema_and_overflows(self):
        clock, log, link, tx, rx = self.devices()
        link.dropped = 7
        state = parse_status(link.status())
        self.assertEqual(state["dropped"], 7)
        bad = bytearray(link.status()); bad[5] = 9
        with self.assertRaises(ValueError):
            parse_status(bytes(bad))
        ledger = Ledger(1)
        drain(rx, ledger, log)
        self.assertEqual(ledger.capture_drops, 7)

    def test_interrupt_during_receive_is_not_final_packet_loss(self):
        ledger = Ledger(5)
        ledger.attempts[0] = {"payload": payload_for(5, 0), "tx": "complete",
                              "rx_window_complete": False}
        self.assertIsNone(ledger.report()["per"])
        self.assertEqual(ledger.report()["rx_windows_unfinished"], 1)

    def test_cli_persists_success_and_interrupt_ledgers(self):
        # Real Journal/fsync/report/cleanup, simulated serial ports only. Keep
        # the audit evidence in a new private artifact directory; delete none.
        for outcome, expected in (("good", "complete"), ("interrupt", "aborted")):
            clock, log, link, tx, rx = self.devices((outcome,))
            output = Path(__file__).resolve().parents[2] / "_codex/ber_20261102/tests" / ("mock_cli_" + outcome + "_" + uuid.uuid4().hex[:8])
            original_run = ber_test.run

            def fake_clock_run(*args):
                return original_run(*args, clock=clock, sleep=clock.sleep)

            argv = ["ber_test.py", "--tx", "MOCK_TX", "--rx", "MOCK_RX", "--count", "1",
                    "--batch", "12345", "--rx-wait", "0", "--output", str(output)]
            with patch("sys.argv", argv), patch("ber_test.serial.Serial", side_effect=[tx.port, rx.port]), patch("ber_test.run", side_effect=fake_clock_run), patch("ber_test.time.sleep", clock.sleep), contextlib.redirect_stdout(io.StringIO()):
                code = ber_test.main()
            report = json.loads((output / "report.json").read_text())
            events = [json.loads(line) for line in (output / "raw.jsonl").read_text().splitlines()]
            self.assertEqual(report["state"], expected)
            self.assertEqual(code, int(expected == "aborted"))
            self.assertEqual(events[-1]["kind"], "report")
            self.assertEqual(len([e for e in events if e["kind"] == "cleanup_stop"]), 2)
            if expected == "aborted":
                self.assertEqual(report["attempts"]["0"]["tx"], "unresolved")
                self.assertIsNone(report["report"]["per"])
            else:
                self.assertEqual(report["report"]["per"], 0)


if __name__ == "__main__":
    unittest.main()
