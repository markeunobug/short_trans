"""Offline probe tests. Never open a real serial port."""
from types import SimpleNamespace
import ctypes
import contextlib
import io
import json
from pathlib import Path
import runpy
import unittest
from unittest.mock import patch
import uuid

import serial_check as sc
from win32_serial_diagnostics import WindowsCommObserver, decode_error_flags


TX = b"OK run=0 mode=0 fs=48000 err=0 dmaerr=0 hde=0 hae=0\r\n"
RX = b"OK fpga=1 ver=20 result=0\r\n"


class Clock:
    now = 0.0

    def __call__(self):
        return self.now


class Log:
    def __init__(self):
        self.events = []

    def log(self, kind, **fields):
        self.events.append((kind, fields))


class Port:
    def __init__(self, clock, chunks=()):
        self.clock, self.chunks = clock, list(chunks)
        self.queue, self.writes = [], []
        self.is_open = False

    @property
    def in_waiting(self):
        return len(self.queue[0]) if self.queue else 0

    def write(self, packet):
        self.writes.append(packet)
        self.queue.extend(self.chunks)
        return len(packet)

    def read(self, size):
        self.clock.now += 0.02
        return self.queue.pop(0) if self.queue else b""

    def close(self):
        self.is_open = False

    def open(self):
        self.is_open = True

    def get_settings(self):
        return {"baudrate": 115200}


class ProbeTests(unittest.TestCase):
    def make(self, chunks=(), role="TX"):
        clock, log = Clock(), Log()
        port = Port(clock, chunks)
        return sc.Probe(port, role, log, clock), port, log

    def test_partial_reads_reassembled_exactly(self):
        probe, port, log = self.make([TX[:3], TX[3:-1], TX[-1:]])
        self.assertEqual(probe.request("STATUS", .2, b"\n")["fields"]["fs"], "48000")
        self.assertEqual(port.writes, [b"STATUS\n"])
        self.assertEqual(b"".join(bytes.fromhex(f["rx_hex"]) for k, f in log.events if k == "rx"), TX)

    def test_rx_identity(self):
        probe, _, _ = self.make([RX], "RX")
        self.assertEqual(probe.request("STATUS", .2, b"\r\n")["fields"]["fpga"], "1")

    def test_no_byte_timeout_no_retry(self):
        probe, port, _ = self.make()
        with self.assertRaisesRegex(sc.ProbeFailure, "timeout_no_bytes"):
            probe.request("STATUS", .1, b"\n")
        with self.assertRaisesRegex(sc.ProbeFailure, "session_unresolved"):
            probe.request("STATUS", .1, b"\n")
        self.assertEqual(port.writes, [b"STATUS\n"])

    def test_partial_timeout(self):
        probe, _, _ = self.make([b"OK run=0"])
        with self.assertRaisesRegex(sc.ProbeFailure, "timeout_partial_line"):
            probe.request("STATUS", .1, b"\n")

    def test_late_bytes_observed_without_new_command(self):
        probe, port, log = self.make()
        with self.assertRaises(sc.ProbeFailure):
            probe.request("STATUS", .1, b"\n")
        port.queue.append(TX)
        self.assertEqual(probe.observe(.1, "late_after_failure"), TX)
        self.assertEqual(port.writes, [b"STATUS\n"])
        self.assertTrue(any(f.get("phase") == "late_after_failure" for _, f in log.events))

    def test_bad_responses(self):
        for response, reason in [(b"ERR COMMAND\r\n", "device_rejected_command"),
                (RX, "wrong_device_or_missing_fields"), (b"OK\xff\r\n", "non_ascii_response"),
                (TX + b"OK\n", "multiple_or_trailing_response_bytes"),
                (TX.replace(b"fs=48000", b"fs=bad"), "invalid_numeric_field")]:
            with self.subTest(reason=reason):
                probe, _, _ = self.make([response])
                with self.assertRaisesRegex(sc.ProbeFailure, reason):
                    probe.request("STATUS", .2, b"\n")

    def test_stale_data_not_flushed_or_associated(self):
        probe, port, _ = self.make()
        port.queue.append(TX)
        with self.assertRaisesRegex(sc.ProbeFailure, "unsolicited_before_command"):
            probe.request("STATUS", .2, b"\n")
        self.assertEqual(port.writes, [])

    def test_command_allowlist(self):
        probe, port, _ = self.make()
        for command in ("SEND", "STOP", "SET_TIME 1", "STATUS\nSEND"):
            with self.assertRaises(ValueError):
                probe.request(command, .1, b"\n")
        self.assertEqual(port.writes, [])

    def test_partial_write(self):
        probe, port, _ = self.make()
        port.write = lambda packet: 2
        with self.assertRaisesRegex(sc.ProbeFailure, "partial_write"):
            probe.request("STATUS", .1, b"\n")
        self.assertTrue(probe.poisoned)

    def test_diag_only_allowed_with_expected_schema(self):
        reply = b"OK UART DIAG schema=1 ore=0 rxovf=0 rearmfail=0 cmderr=1 badhex=\r\n"
        probe, port, _ = self.make([reply])
        self.assertEqual(probe.request("UART DIAG", .2, b"\n")["fields"]["badhex"], "")
        self.assertEqual(port.writes, [b"UART DIAG\n"])

    def check(self, port, clock, **options):
        args = SimpleNamespace(timeout=.1, dtr="off", rts="off", settle=.04,
                               rounds=1, uart_diag=True, interval=.04, eol="lf", late_wait=.04)
        for key, value in options.items():
            setattr(args, key, value)
        settings = {}
        def factory(**kwargs):
            settings.update(kwargs)
            return port
        result = sc.check_port("TX", "COM6", args, Log(), factory, clock)
        self.assertEqual(settings["baudrate"], 115200)
        self.assertFalse(settings["rtscts"])
        self.assertFalse(port.dtr)
        self.assertFalse(port.rts)
        self.assertFalse(port.is_open)
        return result

    def test_driver_errors_block_followup_even_with_complete_reply(self):
        clock, log = Clock(), Log()
        port = Port(clock, [TX])
        observer = WindowsCommObserver(port, "TX", log)
        probe = sc.Probe(port, "TX", log, clock, observer)
        old_read = port.read
        def read(size):
            chunk = old_read(size)
            if chunk:
                observer.flag_observations += 1
                observer.combined_flags |= 2
            return chunk
        port.read = read
        with self.assertRaisesRegex(sc.ProbeFailure, "windows_comm_error"):
            probe.request("STATUS", .2, b"\n")
        with self.assertRaisesRegex(sc.ProbeFailure, "session_unresolved"):
            probe.request("UART DIAG", .2, b"\n")
        self.assertEqual(port.writes, [b"STATUS\n"])
        self.assertTrue(any(kind == "reply" for kind, _ in log.events))

    def test_driver_errors_before_command_prevent_write(self):
        probe, port, log = self.make()
        observer = WindowsCommObserver(port, "TX", log)
        observer.flag_observations, observer.combined_flags = 1, 2
        probe.observer = observer
        with self.assertRaisesRegex(sc.ProbeFailure, "windows_comm_error"):
            probe.request("STATUS", .2, b"\n")
        self.assertEqual(port.writes, [])

    def test_driver_error_does_not_become_plain_no_byte_timeout(self):
        probe, port, log = self.make()
        observer = WindowsCommObserver(port, "TX", log)
        probe.observer = observer
        old_read = port.read
        def read(size):
            observer.flag_observations += 1
            observer.combined_flags |= 2
            return old_read(size)
        port.read = read
        with self.assertRaisesRegex(sc.ProbeFailure, "windows_comm_error"):
            probe.request("STATUS", .1, b"\n")
        self.assertEqual(observer.summary()["names"], ["CE_OVERRUN"])

    def test_timeout_suppresses_all_further_requests_and_closes_port(self):
        clock = Clock()
        port = Port(clock)
        result = self.check(port, clock, rounds=3)
        self.assertEqual(result["reason"], "timeout_no_bytes")
        self.assertEqual(port.writes, [b"STATUS\n"])

    def test_open_unsolicited_bytes_preserved_no_request_sent(self):
        clock = Clock()
        port = Port(clock)
        port.queue.append(TX)
        result = self.check(port, clock)
        self.assertEqual(result["reason"], "unsolicited_on_open_no_command_sent")
        self.assertEqual(port.writes, [])

    def test_success_multiple_rounds_then_diagnostics(self):
        clock = Clock()
        port = Port(clock)
        diag = b"OK UART DIAG schema=1 ore=0 rxovf=0 rearmfail=0 cmderr=0\r\n"
        def write(packet):
            port.writes.append(packet)
            port.queue.append(diag if packet == b"UART DIAG\n" else TX)
            return len(packet)
        port.write = write
        result = self.check(port, clock, rounds=2)
        self.assertTrue(result["passed"])
        self.assertEqual(port.writes, [b"STATUS\n", b"STATUS\n", b"UART DIAG\n"])

    def test_interrupt_returns_auditable_result_and_closes(self):
        clock = Clock()
        port = Port(clock)
        def interrupted(size):
            raise KeyboardInterrupt()
        port.read = interrupted
        result = self.check(port, clock)
        self.assertEqual(result["reason"], "interrupted")
        self.assertEqual(port.writes, [])

    def test_open_error_does_not_attempt_command(self):
        def denied(**kwargs):
            raise sc.serial.SerialException("Access denied")
        result = sc.check_port("TX", "COM6", SimpleNamespace(timeout=.1), Log(), denied)
        self.assertEqual(result["reason"], "serial_open_or_io_error")
        self.assertFalse(result["passed"])


class DriverObserverTests(unittest.TestCase):
    def test_real_cli_entry_records_driver_failure_instead_of_uncaught_exception(self):
        clock, port = Clock(), None
        port = Port(clock)
        observer = WindowsCommObserver(port, "TX", Log(), api=SimpleNamespace())
        # Context is mocked; exercise the actual __main__ entry and its exception
        # class, without installing a native hook or opening a real COM port.
        observer.api = None
        old_read = port.read
        def read(size):
            observer.flag_observations += 1
            observer.combined_flags |= 2
            return old_read(size)
        port.read = read
        out = sc.ARTIFACTS / ("serial_cli_test_" + uuid.uuid4().hex[:8])
        with patch("sys.argv", ["serial_check.py", "--tx", "MOCK", "--settle", "0",
                   "--late-wait", "0", "--timeout", "0.1", "--output", str(out)]), \
             patch("serial.Serial", return_value=port), \
             patch("win32_serial_diagnostics.WindowsCommObserver", return_value=observer), \
             patch("time.monotonic", clock), contextlib.redirect_stdout(io.StringIO()):
            with self.assertRaises(SystemExit) as stopped:
                runpy.run_path(str(Path(sc.__file__)), run_name="__main__")
        self.assertEqual(stopped.exception.code, 1)
        result = json.loads(next(out.glob("serial_check_*/report.json")).read_text())["results"][0]
        self.assertEqual(result["reason"], "windows_comm_error")
        self.assertEqual(result["windows_driver"]["combined_flags"], 2)
        self.assertEqual(port.writes, [b"STATUS\n"])
        self.assertFalse(port.is_open)

    def test_error_hook_handle_filter_and_restore(self):
        class Stat(ctypes.Structure):
            _fields_ = [("cbInQue", ctypes.c_uint32), ("cbOutQue", ctypes.c_uint32)]
        calls = []
        def native(handle, errors, status):
            calls.append(handle)
            ctypes.cast(errors, ctypes.POINTER(ctypes.c_uint32)).contents.value = 2
            return 1
        api = SimpleNamespace(ClearCommError=native, COMSTAT=Stat)
        port, log = SimpleNamespace(_port_handle=ctypes.c_void_p(11)), Log()
        observer = WindowsCommObserver(port, "TX", log, api)
        flags, stat = ctypes.c_uint32(), Stat(0, 7)
        with observer:
            observer.phase = "response"
            self.assertEqual(api.ClearCommError(11, ctypes.byref(flags), ctypes.byref(stat)), 1)
            api.ClearCommError(12, ctypes.byref(flags), ctypes.byref(stat))
        self.assertIs(api.ClearCommError, native)
        self.assertEqual(calls, [11, 12])
        self.assertEqual(observer.flag_observations, 1)
        self.assertEqual(log.events[0][1]["input_queue_bytes"], 0)
        self.assertEqual(log.events[0][1]["output_queue_bytes"], 7)
        self.assertEqual(log.events[0][1]["names"], ["CE_OVERRUN"])

    def test_native_failure_not_reported_as_comm_error_and_exception_restores_hook(self):
        def native(*args):
            return 0
        api = SimpleNamespace(ClearCommError=native)
        observer = WindowsCommObserver(SimpleNamespace(_port_handle=11), "TX", Log(), api)
        with self.assertRaisesRegex(RuntimeError, "test"):
            with observer:
                flags = ctypes.c_uint32(2)
                self.assertEqual(api.ClearCommError(11, ctypes.byref(flags), None), 0)
                raise RuntimeError("test")
        self.assertIs(api.ClearCommError, native)
        self.assertEqual(observer.flag_observations, 0)

    def test_error_flags_are_not_conflated(self):
        self.assertEqual(decode_error_flags(1), ["CE_RXOVER"])
        self.assertEqual(decode_error_flags(2), ["CE_OVERRUN"])
        self.assertEqual(decode_error_flags(10), ["CE_OVERRUN", "CE_FRAME"])
        self.assertEqual(decode_error_flags(0x40000000), ["UNKNOWN_0x40000000"])


if __name__ == "__main__":
    unittest.main()
