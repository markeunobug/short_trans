# FSK BER implementation and validation — 2026-11-02

## Live BER TIME_BASE timeout correction, 2026-11-16 afternoon

Evidence root: `_codex/ber_20261102/ber_timeout_20261116/`. Source snapshots and
three original user logs are preserved there before editing. The actual current
port mapping is TX COM29 / RX COM6; the earlier COM6 TX example is not current.

The failing `ber_1794814249819074` records three successful running TX STATUS
replies after TIME_BASE SEND and the next STATUS timeout. Initial diagnostics
report ore=0/cmderr=0; HOTPLUG RAM after abort has ore=1, rearmfail=1, cmderr=1
and last rejected line `STATUSSTOP`. The current board Flash's seven allocated
sections match the user's existing Debug ELF (outside-section alignment fill
excluded); symbols are taken from that ELF. This is new live MCU receive-error
evidence, distinct from the old November 5 PC CE_OVERRUN return-path incident.

The scoped host fix paces BER control bytes at 2 ms and clears an unresolved
partial input line with bounded backspaces before emergency STOP. It does not
retry SEND, remove run/physical-completion checks, raise timeouts or change
firmware/demodulation/FIFO. The stale TIME_BASE completion displayed during a
subsequent selfcheck is corrected as a separate presentation defect.

The paced Python counterpart was exercised on live ports once, count=1 amp=100
rx-wait=2, without flash/reset. All TX status requests completed, run=1 -> 0 was
observed, and ore/rearmfail/cmderr did not increase (1/1/1 before and after).
This control-transport check passed, but the full BER trial ABORTED: RX retained
base_s=1794843050 instead of the new 1794843995. There was one setup SEND and
ZERO DATA sends; PER/BER/coverage remain null. Saved TX TIME_BASE body
`210000286afb255b374b` has the new time value and valid CRC8/CRC16. This does
not prove physical acoustic output or locate why the new TIME_BASE was not
received. The guard remains and the error now reports expected/received values
and RX health. Do not call this an end-to-end BER pass or use the stale base.

`live_paced_trial_1/`, `read_after_trial/`, and `swd_initial/` retain evidence.
`analyze_failure.py` verifies it offline and emits `failure_analysis.json`.
New line mock reproduces the lost terminator/STATUSSTOP case, verifies paced
submission and cancellation of a partial SEND without executing it; the actual
TX parser harness also checks backspace cancellation. Mocks are not Cortex-M
interrupt timing or USB waveform simulations. Final GUI hardware use remains
pending the user launching the corrected host; the Python live check does not
stand in for that verification.

Validation: full Flutter suite 59 tests PASS in
`ber_timeout_20261116/flutter_tests_final.log`, followed by the 22 BER controller
tests after the final stale-selfcheck-state cleanup in `flutter_ber_final.log`.
Dart analyzer reports no issues; isolated Windows Debug build PASS in
`flutter_build_final.log`. Python 46 tests and 18 full host checks PASS in
`validation_20261116_155131_64f8d0/results.json`. Final package is
`ber_timeout_20261116/ready/host/short_trans_host.exe`; keep adjacent runtime/data.
`package_manifest.json` confirms staged Dart sources match the current workspace
and all three TX Core snapshot hashes are unchanged by this correction.
Protected baseline audit remains 19/19 unchanged, snapshot integrity true.
Task paths edited: Flutter main/controller/view plus new command writer and its
tests; Python BER CLI/tests and audit inventory; the TX host test harness only
(no target C edits); BER protocol/validation docs. All builds/evidence are under
the existing _codex artifact root. No Quartus or target recompilation is claimed
for this host-only correction.

## Continued STATUS investigation, 2026-11-16

Offline re-analysis of the later November 5 HOTPLUG captures supersedes the
early "no SWD access" observation below. Evidence is in
`_codex/ber_20261102/serial_followup_20261116/verified_saved_evidence.json`.
All seven actual allocated/loadable sections from the saved board Flash match
the existing `tx_stm32/Debug/tx_stm32.elf`; the eight alignment-fill bytes outside
sections at 0x080001D8 are excluded explicitly. The saved board image is not the
separately linked `ready/TX_DEBUG_O0.bin`; use the matched ELF for SRAM symbols.

For the isolated STATUS query on November 5, saved SRAM shows RX head/tail
97/97 -> 104/104, exactly seven new bytes `STATUS\n` in the ring, a regenerated
normal STATUS response (DMA remain 586 -> 922), tx_error_count=0, and increasing
SysTick. CFSR/HFSR were zero when sampled. Subsequent direction sampling observed
PA7 ODR/IDR high, PC5 IDR low and UART TC low while the PC got no bytes. GPIO
snapshots are not a logic-analyzer waveform or electrical timing signoff. Fifteen
Windows ClearCommError observations reported flags=2 (CE_OVERRUN) after a single
STATUS write, first at approximately 6.315 ms. These are PC driver observations,
not target ORE or a count of lost bytes. Together the evidence narrows that
failure to the return path; it does not uniquely distinguish RS485 electrical,
adapter, USB or driver causes. It does not establish the current board state.

On November 16, serial enumeration finds no ports; CubeProgrammer reports no
ST-LINK. These are saved in `serial_followup_20261116/current_devices.json`,
`serial_inventory.log`, and `stlink_inventory.log`. No port was opened, no target
reset/flashing performed, and no firmware/RTL/Flutter edits made in this follow-up.
Do not repeatedly SEND or reflash based solely on the old return-path evidence.
Reconnect the adapters and TX SWD to obtain fresh evidence. Then compare with a
known-working adapter/USB path one variable at a time, recording actual COM roles.

The standalone Python serial probe now captures Windows ClearCommError flags
that pyserial otherwise discards. Logs include the queue sizes, phase, flag
names and a report summary; no next command is sent on an errored connection.
Tests cover handle filtering, hook removal, native failure, error distinctions,
and suppression of requests on both zero-byte errors and valid-but-errored
responses. Python 41 tests PASS (including the CLI __main__ error path); full
host regression 18 checks PASS in
`validation_20261116_144645_ae45c0/results.json`. Earlier target O0/Os builds
remain the most recent target builds; they are not newly flashed or board-proven.

## STATUS outage investigation, 2026-11-05 evening

These are later observations, not a declaration that the board fault is fixed.
The independent Python serial probe reproduced a COM6 STATUS no-byte timeout
while COM29 returned valid RX STATUS in approximately 20 ms. Evidence is in
`_codex/ber_20261102/serial_check_20261105_192536_ea7ca5/`. This is not exclusively
a Flutter response-matcher failure, but does not prove the TX MCU received bytes.

A confirmed diagnostic defect was reproduced using the project's actual vendor
`UART_RxISR_8BIT`, `UART_Start_Receive_IT`, and `HAL_UART_Receive_IT`: an ORE set
before the one-byte receive callback was cleared by rearm, so the dispatcher
could skip ErrorCallback and the old diagnostic count stayed zero. The new
test failed before the change (`vendor_uart_a3c0980b`) and passes after it
(`vendor_uart_e39920bf`), under `tx_status_investigation_20261105/`. Main.c now
samples error flags in RxCpltCallback before the unchanged ring/rearm sequence;
the separate ErrorCallback remains for other paths. This fixes diagnostic
observability, NOT the demonstrated no-response condition by itself. The
previous `ready/` package is preserved as historical evidence and still has
the counter blind spot; no replacement firmware has been programmed.

New regression: `validation_20261105_194713_79bfe4/results.json`, 18 host checks
PASS, including Python 34 tests, actual main.c/vendor one-byte receive functions
and original/current normal UART response comparison. All 18 tested normal
responses (STATUS, setup, TIME_BASE/SEND completion model, DATA, STOP, rejected
TATUS and next STATUS) are byte-identical to the verified pre-diagnostic snapshot.
This is functional mock evidence; neither cold boot nor Cortex-M interrupt
latency is emulated. Full TX hard-float O0/Os builds PASS in
`tx_status_investigation_20261105/target_20261105_194354_247cb6/`, without flashing.
The builder also now resolves caller-relative --output before changing cwd.

Early in that November 5 investigation, CubeProgrammer reported no ST-LINK.
The probe subsequently became available, and HOTPLUG captures were collected;
see the November 16 re-analysis above for the stronger return-path evidence.
STOP still leaves the DAC DMA stream active in silence, as before this work;
it is not proof of an interrupt-free idle system.

## Authorized follow-up on 2026-11-05

This report's original results below are historical. Following explicit user
authorization, the existing Flutter UI was extended and the TX UART/DMA
diagnostic attachments were added. The initial claim of unchanged TX Core/UI
does not apply to these later edits. Three TX Core paths (fsk_tx.h, fsk_tx.c,
main.c) now change intentionally; the other 19 protected baseline paths are
still byte-identical. Separate pre-diagnostic snapshots are in
`_codex/ber_20261102/tx_uart_diag_20261105/baseline/`. No IRQ priorities, physical
frame/CRC rules, demodulation/sync, normal RX parser/FIFO, trace recorder or
hardware programming were changed/performed by the diagnostic follow-up.

Latest diagnostic evidence under `_codex/ber_20261102`:

| Check | Result | Artifact |
|---|---|---|
| Actual TX main.c line/ring/error callback tests | PASS, ORE/rearm/ring/overflow/badline/buffer cases | `tx_uart_diag_20261105/uart_mock_3f4f74c0/test.log` |
| Before/after DAC stream comparison | PASS, 4,108,800 samples byte-identical | `tx_uart_diag_20261105/waveform_compare_f40d4025/result.log` |
| Latest host regressions | 16 checks PASS including Python 19 tests, RX/TX C mocks and TX UART helper tests | `validation_20261105_162934_c1d8d0/results.json` |
| Latest Flutter suite | 51 tests PASS | `tx_uart_diag_20261105/flutter_tests_final51.log` |
| Analyzer on integrated/added Dart paths | No issues | `tx_uart_diag_20261105/dart_analyze_final51.log` |
| Complete TX target build | Debug O0 and optimized Os, hard-float, ELF/HEX/BIN | `tx_uart_diag_20261105/target_20261105_162800_d6ba6e/results.json` |
| Windows Debug host | PASS, isolated copy | `tx_uart_diag_20261105/flutter_build_latest.log` |

Root cause is not claimed as physically confirmed: live logs establish unknown
command replies from TX during transmission. The pre-diagnostic O0 assembly
contains at least 28,800 instructions in the tone-render loop including scale
calls. An optimistic one-cycle-per-instruction model at 150 MHz gives 192 us,
vs 86.806 us per UART character. This is static latency-risk evidence, not a
measured ISR duration or a capture of TX wire RX bytes. `UART DIAG` captures
hardware ORE separately from FE/NE/PE, ring overflow, receive rearm failure,
command rejection and recent rejected-line HEX, plus target CYCCNT render
timings. A user-performed diagnostic firmware run remains necessary to confirm
whether this risk caused these on-board failures. Generated HEX files were not
programmed. See `tx_uart_diag_20261105/DIAGNOSIS.md` for the reproduction steps.

## Result and scope

The passive FPGA observer, RX MCU commands, two-port Python CLI, protocol/statistics,
auditable JSONL/report outputs and non-destructive validation runner are implemented.
No hardware was downloaded or programmed. There was no change to TX Core,
production demodulation/synchronization, normal parser/CRC rejection/FIFO,
spi_register_bank, trace recorder, or Flutter UI by this BER work.

The workspace already contained user changes. Checks use the **pre-BER workspace
snapshot**, not Git HEAD. `baseline.json` has 28 hashes: 22 protected files remain
byte-identical; six explicit integration files contain the scoped BER attachments.
The audit is at repository path
`_codex/ber_20261102/final_audit/sha256_audit.json`.

Authoritative artifact root: `C:/learning/short_trans/_codex/ber_20261102`.
Read `codex/BER_PROTOCOL.md` for wire and statistical definitions. The planning
document has been corrected to describe the implemented identity CRC32, missed
sync counter, STOP publication boundary, safe retry policy and HEALTH command.

## Evidence

| Area | Result | Artifact under `_codex/ber_20261102` |
|---|---|---|
| Python protocol, accounting and simulated dual serial devices | 13 tests PASS | `tests/python_final.log` |
| Flutter BER Dart protocol/controller tests | 9 BER tests PASS; byte vectors match the Python reference | `flutter_ui_20261103/ber_tests_final.log` |
| Full existing Flutter test suite with BER workspace and 640px layout test | PASS (39 tests) | `flutter_ui_20261103/flutter_test_final.log` |
| Flutter analyzer | No errors; one pre-existing style info remains in `trace_data.dart` | `flutter_ui_20261103/analyze_final2.log` |
| Windows Flutter debug build | PASS in isolated project copy | `flutter_ui_20261103/build_windows_isolated.log` |
| CLI actual journal/fsync/report/cleanup paths | Success + interrupted-run mocks PASS; no hardware ports | `tests/mock_cli_good_*`, `tests/mock_cli_interrupt_*` |
| BER RTL including parser/FIFO cycle comparison | PASS at ~29.4 MHz clk_sys/~1.176 MHz SPI | `tests/ber_rtl_final.log`, `tests/ber_compile_final.log` |
| Existing broad RTL suite | 23/24 benches PASS, one existing sample-chain FAIL | `validation_20261102_204403_a78a63/results.json` |
| RX SPI, command parser, trace, BER C mocks; optional HAL; RX integration contract; TX model/HAL; sweep model | PASS | `validation_20261102_205458_86cd65/results.json` |
| RX and TX target compile/link | PASS, CubeIDE GCC 11.3.rel1, Cortex-M4 hard-float, original linker scripts | `validation_20261102_205458_86cd65/rx_target/`, `tx_target/` |
| Quartus complete synthesis/fitter/assembler/TimeQuest | PASS, 0 errors, 44 warnings | `validation_20261102_203543_854f10/quartus_full.log` |
| Protected baseline SHA256 and scoped integration diff | 22/22 protected unchanged; original integration snapshots verified | `final_audit/sha256_audit.json`, `ber_integration_vs_baseline.diff` |
| Existing sample-chain baseline reproduction | Same FAIL without BER module, protected core hashes unchanged | `final_audit/baseline_core_replay_20261102_205459/replay.json`, `step_2.log` |

The full build includes all C translation units in Core/Src and the HAL source
folder, startup assembly, and final linker resolution; it is not only syntax
checking. GCC uses `-mfpu=fpv4-sp-d16 -mfloat-abi=hard`, `-Os`, section garbage
collection and nano/nosys specs. No soft-ABI fallback was used.

| Firmware | text | data | bss |
|---|---:|---:|---:|
| RX | 23216 | 104 | 2824 |
| TX (unchanged sources) | 21528 | 20 | 4820 |

BER command local stack: 216 bytes from GCC `.su`; nested SPI streams use their
own temporary buffers. This is compile-time evidence, not runtime stack watermark.
The existing 384-byte response buffer and command line length accommodate the
new commands, 64-byte hex record and its CRC16. Tiny-capacity calls cannot execute
controls; mock tests cover this and argument overflow/trailing fields.

## BER-specific checks

- Reset/default OFF and disabled sync cause no diagnostic records while normal
  parser/FIFO accepts a good frame. Reset during enabled session returns OFF/empty.
- Good and bad CRC16 captures retain exact raw bytes; an injected known Payload
  bit flip remains in diagnostics while the unchanged normal parser rejects it.
- Registered sync with back-to-back next bit captures Header bit7 correctly.
- Bad header CRC, invalid length and unexpected type remain raw diagnostic
  observations; host alignment checks exclude them.
- Partial bytes are correctly left-aligned/zero-padded; timeout, lock loss,
  unavailable chain and STOP are distinguished. STOP wins over coincident bit.
- Full queue preserves unread head and drops the new record, while normal FIFO
  continues to deliver. Existing normal FIFO has no diagnostic backpressure.
- Simultaneous completion/POP, publish-commit/POP, capture/read, frozen status
  during live queue mutation, empty POP and invalid controls/offsets are checked.
- Actual spi1_slave burst with synchronous RAM produces correct bytes; partial
  SPI byte followed by seek/retry returns the same head without POP.
- MCU repeats head seek/read independently before READ/POP, catches mismatched
  SPI reads, retries after offset-advancing failures, checks explicit POP ID and
  verifies popped counter even when a new record commits concurrently.
- Host verifies transport CRC16, record flags and raw CRC consistency, full batch
  and uint32 sequence, identity CRC32 and Header low-byte sequence agreement.
- Stop-and-wait never retries SEND. Missing run transition, stuck run, DMA error,
  serial timeout or interruption retains unresolved attempt and aborts. A session
  with an ambiguous late ASCII reply is poisoned. Partial serial reads are assembled.
- Mock trial with one good, one CRC-bad Payload (3 known flipped bits), one
  damaged identity and one lost frame yields PER=3/4, coverage=2/4 and 3 errors
  over 512 compared Payload bits; it sends precisely four DATA and one setup
  TIME_BASE. Transport CRC failure is reread; uncertain POP after explicit SPI
  error is resolved by popped counter without issuing POP again.
- Zero denominators produce null. Interrupting a receive window does not turn
  incomplete observation into final PER. Duplicate records and latest-frame
  READ observations are deduplicated and separately counted.

## Existing regression that remains failed

`integration_rx_chain_tb` reports:

```text
metrics=2274 preambles=1 bits=100 sync=1 frames=0 payload=0 phase=6 errors=0
FAIL: expected one CRC-valid frame, observed 0
```

The same generated nominal FSK sample vector was replayed in an isolated work
library containing only the production correlator/noise/demod/sync/frame_rx and
the original integration bench; it contains **no BER module or integration**.
The failure reproduces. demod_core, noise_tracker, symbol_sync and frame_rx hash
identically to the pre-BER baseline. This establishes that this test failure is
not introduced by the BER observer. It does not establish a root cause, and no
demodulation/synchronization change was authorized or made to make it pass.

Thus the overall RTL regression is **not all green**. The standalone legacy
sample-chain/vector compatibility needs a separate investigation before any
full-system reliability claim. The two manifest-driven OOK vector/fixture benches
are outside this runner; existing OOK chain/lifecycle/config benches passed.

## FPGA synthesis and timing boundary

Quartus 22.1 Lite completed the copied original QSF/SDC/SignalTap project for
10CL025YE144I7G. No source QSF assignments or constraints were relaxed. The
diagnostic 512x8 RAM was inferred as M9K in the synthesis report.

- LE: 23763/24624 = 97%; memory bits: 310784/608256 = 51%; 9-bit multipliers:
  96/132 = 73%. Remaining LE margin is limited.
- Worst reported setup slack: **3.361 ns**; worst hold across corners:
  **0.099 ns**; TNS=0 in reported setup/hold/recovery/removal/min-pulse panels.
- No unconstrained clocks. Unconstrained ports are reserved JTAG `tdi`, `tms`,
  `tdo`, not ordinary design ports. Existing asynchronous SPI/I2C false paths
  and output min/max constraints remain as supplied; external board timing
  and electrical compliance are not established by this report.
- 44 warnings remain, including existing width truncations/unused debug or
  SPI3 pins, OOK combinational loop-variable latch inference, RAM collision
  modeling and I/O assignment/electrical warnings. One BER byte-count narrowing
  warning is bounded by fixed bit_count<=328 (ceil /8 <=41), verified by tests.
  No broad cleanup of these existing warnings was performed.

No bench verification, physical DAC-completion measurement, live two-port run,
underwater/wired BER measurement, power-cycle test, or hardware fault injection
was performed. The generated .sof/.elf files are compile artifacts only and
are not represented as deployment-approved releases.

## Task-modified paths

Only the following task source/documentation paths were created or changed;
the many other entries visible in `git status` are pre-existing user work.

| Path relative to repository | BER scope |
|---|---|
| `code/cyclone10/rx_cyclone10/rtl/debug/ber_capture.v` | New passive capture/CRC/queue/status peripheral |
| `code/cyclone10/rx_cyclone10/tb/ber_capture_tb.sv` | New self-checking BER/SPI/parser/FIFO differential bench |
| `code/cyclone10/rx_cyclone10/rx_cyclone10.v` | Observer inputs and 0x49..0x4F read mux only vs baseline |
| `code/cyclone10/rx_cyclone10/rx_cyclone10.qsf` | Add ber_capture.v source only vs baseline |
| `code/cyclone10/rx_cyclone10/rtl/spi/spi1_slave.v` | Add 0x4E fixed-address stream only |
| `code/cyclone10/rx_cyclone10/rtl/spi/SPI_REGISTER_MAP.md` | Add BER allocation/contract; preserve existing register text |
| `code/stm32/rx_stm32/Core/Inc/rx_ber.h` | New diagnostic command API |
| `code/stm32/rx_stm32/Core/Src/rx_ber.c` | New independent diagnostic commands and read-only health sampling |
| `code/stm32/rx_stm32/Core/Inc/fpga_rx_spi.h` | Add BER_DATA address only vs baseline |
| `code/stm32/rx_stm32/Core/Src/fpga_rx_spi.c` | Classify BER_DATA as a read-only stream only vs baseline |
| `code/stm32/rx_stm32/Core/Src/main.c` | BER include, command dispatch and HELP addition only vs baseline |
| `code/stm32/rx_stm32/Tests/rx_ber_test.c` | New host/mock BER API tests |
| `code/stm32/tx_stm32/Core/Inc/fsk_tx.h` | Add diagnostic render metrics to status struct |
| `code/stm32/tx_stm32/Core/Src/fsk_tx.c` | Add CYCCNT metrics around unchanged render; HELP lists UART DIAG |
| `code/stm32/tx_stm32/Core/Src/main.c` | UART DIAG, bad-line/counter observers; unchanged normal STATUS/waveform/IRQ priorities |
| `code/stm32/tx_stm32/Tests/test_fsk_tx_hal_mock.c` | Verify render metrics fallback and original waveforms |
| `code/stm32/tx_stm32/Tests/test_uart_diagnostics.py` | Execute actual UART/main helpers with injected HAL errors |
| `code/stm32/tx_stm32/Tests/build_uart_diagnostics.py` | Isolated hard-float O0/Os ELF/HEX/BIN builds, no flashing |
| `code/stm32/tx_stm32/Tests/compare_diagnostic_waveform.py` | Bytewise comparison with saved pre-diagnostic C implementation |
| `tools/ber/ber_protocol.py` | Payload/format/integrity/accounting |
| `tools/ber/ber_test.py` | Two-port stop-and-wait CLI and durable journals |
| `tools/ber/test_ber.py` | Unit and simulated-device/CLI tests |
| `tools/ber/validate.py` | Unique isolated host/RTL/target/Quartus runs, no deletes |
| `tools/ber/audit.py` | Hash/diff evidence and no-BER core replay |
| `flutter/lib/ber_data.dart` | Dart CRC, payload, record, health/status parser and BER ledger |
| `flutter/lib/ber_controller.dart` | Native dual-port stop-and-wait, timeout poisoning, audit journal and cancellation |
| `flutter/lib/ber_view.dart` | BER controls, health/statistics, attempts and audit access |
| `flutter/lib/main.dart` | BER navigation, shared serial channel integration and command mutual exclusion |
| `flutter/test/ber_test.dart` | Protocol reference vectors, dual-device, failure and audit-path tests |
| `flutter/test/widget_test.dart` | Narrow-window BER workspace layout check |
| `codex/BER_IMPLEMENTATION_PLAN.md` | Corrected implementation contract |
| `codex/BER_PROTOCOL.md` | New commands/records/pattern/statistics/retry documentation |
| `codex/BER_VALIDATION.md` | This validation/report/path inventory |
| `codex/UPPER_COMPUTER_PROTOCOL.md` | Add BER cross-reference/latest-cache clarification only |

All generated logs, models, binaries, mock ledgers, vectors, snapshots and audit
files are under `_codex/ber_20261102`; no existing simulation/.regression,
generated, build or user output directory was recursively deleted or cleaned.

## Reproduction and next acceptance gates

```powershell
python tools/ber/validate.py --host --rtl --target
python tools/ber/validate.py --quartus
python tools/ber/audit.py --tx-uart-diagnostics --output _codex/ber_20261102/tx_uart_diag_20261105/final_audit
```

The first command deliberately retains/report-fails the existing sample-chain
regression; inspect its log instead of treating a nonzero exit as a new BER bug.
Each validation invocation creates a fresh directory. Hardware acceptance still
requires an explicitly authorized programming/bench session, default-off normal
receive equivalence, CRC-bad observation with normal FIFO rejection, known-error
measurement, diagnostic-full isolation and live TX completion/error checks.

The Dart BER controller is protocol-tested against shared fixtures independently
generated by the Python reference implementation. Real serial hardware has not
been opened by Flutter for a trial. The existing receive-status endpoint does not
expose the normal FIFO overflow count; the UI reports the available sticky flag
and does not synthesize a count.
