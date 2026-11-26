"""Observe flags pyserial's existing ClearCommError calls otherwise discard.

No extra native calls, driver-setting changes or retries are made. The hook is
process-local, temporary and filtered to one port handle. Intended only for the
standalone, sequential serial_check CLI; do not install in a GUI/worker pool.
"""
from __future__ import annotations

import ctypes
import os


ERROR_FLAGS = {
    0x0001: "CE_RXOVER", 0x0002: "CE_OVERRUN", 0x0004: "CE_RXPARITY",
    0x0008: "CE_FRAME", 0x0010: "CE_BREAK", 0x0100: "CE_TXFULL",
    0x0200: "CE_PTO", 0x0400: "CE_IOE", 0x0800: "CE_DNS", 0x1000: "CE_OOP",
    0x8000: "CE_MODE",
}


def decode_error_flags(value):
    names = [name for bit, name in ERROR_FLAGS.items() if value & bit]
    unknown = value & ~sum(ERROR_FLAGS)
    if unknown:
        names.append(f"UNKNOWN_0x{unknown:08X}")
    return names


def handle_value(handle):
    return getattr(handle, "value", handle)


class WindowsCommObserver:
    def __init__(self, port, device, journal, api=None):
        self.port, self.device, self.journal = port, device, journal
        if api is None and os.name == "nt":
            from serial import win32
            api = win32
        self.api = api
        self.flag_observations = 0
        self.combined_flags = 0
        self.original = self.hook = None
        self.phase = "open"

    def __enter__(self):
        if self.api is None:
            return self
        self.original = self.api.ClearCommError

        def observed(handle, errors, status):
            result = self.original(handle, errors, status)
            expected = handle_value(getattr(self.port, "_port_handle", None))
            if not result or expected is None or handle_value(handle) != expected or not errors:
                return result
            # DWORD is always 32 bits, including on 64-bit Windows/Python.
            flags = ctypes.cast(errors, ctypes.POINTER(ctypes.c_uint32)).contents.value
            if flags:
                self.flag_observations += 1
                self.combined_flags |= flags
                fields = {"device": self.device, "phase": self.phase,
                          "flags": flags, "flags_hex": f"0x{flags:08X}",
                          "names": decode_error_flags(flags)}
                if status:
                    stat = ctypes.cast(status, ctypes.POINTER(self.api.COMSTAT)).contents
                    fields.update(input_queue_bytes=stat.cbInQue, output_queue_bytes=stat.cbOutQue)
                self.journal.log("windows_comm_error", **fields)
            return result

        self.hook = observed
        self.api.ClearCommError = observed
        return self

    def __exit__(self, *exc):
        if self.api is not None and self.api.ClearCommError is self.hook:
            self.api.ClearCommError = self.original

    def summary(self):
        return {"available": self.api is not None,
                "flag_observations": self.flag_observations,
                "combined_flags": self.combined_flags,
                "names": decode_error_flags(self.combined_flags),
                "scope": "PC driver flags; observations are not counts of lost bytes or MCU ORE"}
