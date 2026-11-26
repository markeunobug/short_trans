# FSK BER implementation plan — 2026-11-02

## Scope and invariants
- Scope updates: the user subsequently authorized Flutter BER UI integration,
  then TX UART/DMA diagnostics on 2026-11-05 after repeated live ERR COMMAND.
  The original restrictions below describe the initial implementation, not the
  later authorized diagnostics scope. IRQ priorities and sample-generation logic
  remain unchanged; no downloading/programming hardware is performed by tools.
- Existing authorized FSK trees only: code/cyclone10/rx_cyclone10 and code/stm32/{tx_stm32,rx_stm32}.
- No change to TX Core, demodulation, symbol timing, normal frame parser/CRC rejection, packet FIFO, trace recorder, or Flutter UI. Existing uncommitted edits preserved.
- Baseline hashes and copies of integration files: _codex/ber_20261102/baseline.json and baseline/.
- Add passive diagnostics, default OFF after reset. Diagnostic full/error cannot backpressure or reset the production receiver.
- First version: one PC, two independent 115200-8-N-1 serial ports; Python CLI (existing pyserial). No programming hardware automatically.

## Test frame and measurement boundary
- Normal V2 DATA packet, 32-byte application payload: batch u32 BE + sequence u32 BE + identity CRC32 BE (Python zlib CRC32 of first 8 bytes) + 20 deterministic xorshift32 bytes. Header byte sequence = test sequence mod 256. Identity CRC32 was added during review: a damaged batch/sequence must not be matched by timing or similarity. This is error detection, not proof against every CRC collision.
- Capture starts at existing parser sync_found and collects exactly 41 bytes (4 header + 3 time + 32 application + 2 CRC), independent of received length and normal parser errors.
- Reuse accepted sync event; this measures sync-conditioned Payload BER, not preamble/sync BER or uncaptured bits. Hardware lock loss can prevent full capture. An already busy sidecar does not restart on spurious sync.
- Record partial byte count, actual bit count and termination reason. First version compares only complete 328-bit captures with trustworthy IDs. No nearest-pattern matching, no guessed bit errors for loss.
- Raw diagnostic records are observations, NOT normal application delivery. Delivery is established using existing READ, de-duplicated by batch/32-bit ID because READ exposes the latest cached frame.

## FPGA additions and SPI contract (no existing addresses moved)
- New rtl/debug/ber_capture.v; fixed depth 8, fixed record size 64, byte-wide synchronous RAM with private capture staging and bounded publishing. Saturating u32 counters.
- 0x49 ID=0xB1; 0x4A CONTROL bits START=1 STOP=2 CLEAR=4 POP=8; 0x4B STATUS; 0x4C queue count; 0x4D seek offset; 0x4E non-destructive seekable stream; 0x4F schema=1.
- Offset 0..63 reads frozen queue head. Offset 0x80..0x9F reads a coherently latched 32-byte status snapshot (latched on seek 0x80).
- START only when disabled, idle, empty and FSK available; resets session counters. CLEAR only disabled/idle; POP guarded by capture ID in MCU command; STOP finalizes partial capture. Invalid controls count errors; never touch normal path.
- Record: BR01 magic[0:4], capture_id LE32[4:8], bit_count LE16[8:10], flags[10], byte_count[11], sample_index LE32[12:16], raw[16:57], zero padding[57:64].
- Flags: complete=1, timeout=2, lock_lost/unavailable=4, stopped=8, header_crc_ok=16, frame_crc_ok=32, expected_DATA_header=64.
- Status snapshot: BS01[0:4], state[4], count[5], depth[6], record_size[7], started LE32[8:12], dropped LE32[12:16], committed LE32[16:20], protocol_errors LE32[20:24], popped LE32[24:28], missed_sync LE32[28:32]. State: enabled=1, busy=2, ready=4, full=8, available=16. missed_sync counts accepted parser sync events while capturing/publishing; these do not restart capture. Records count only after 64-cycle publication. STOP ACK means disabled; wait until busy=0 before CLEAR/final drain.
- Top-level adds module and read mux at 0x49..0x4F. SPI slave and C driver add 0x4E as a stream address. Old bank/FW_VERSION remains 0x14; feature detected by new ID/schema, not ambiguous firmware number. Trace gating unchanged.

## RX STM32 additions
- New rx_ber.h/.c; reuse generic fpga_rx_spi API. Dispatch BER prefix before existing handlers; no existing READ response changes.
- Commands: BER STATUS; BER HEALTH (read-only 20-byte BH01 production register sample); BER START; BER STOP; BER CLEAR; BER READ; BER POP <capture_id>.
- BER READ is non-destructive and retryable; returns exact 64-byte hex plus CRC16 over those 64 bytes to reject serial/transport corruption. POP explicitly acknowledges head identity. Re-read checks on errors.
- No automatic background diagnostic drain; PC polls bounded command responses. Existing 384-byte response buffer is sufficient.

## Host tools
- New tools/ber/ber_protocol.py: deterministic patterns, strict record/status/transport validation, header+CRC recomputation, bit comparison, de-duplication, metrics and JSON report.
- New tools/ber/ber_test.py: two-port controller, durable JSONL per-command and ledger, conservative stop-and-wait (one outstanding test packet), drain normal READ and diagnostic queue, explicit POP acknowledgments.
- SET_TIME/TIME_BASE setup occurs before enabling diagnostics; TIME_BASE is not a test packet. Confirm FSK, fs=48000, run=0, no TX errors; existing PACKET SEND emits one frame.
- SEND accepted is NOT completed. Confirm run=0 after expected airtime and no DMA/HAL errors; allow existing pre/post silence and guard, then drain RX through configurable wait. Unknown completion aborts session; do not silently count as lost/success or resend.
- Match only exact batch/ID plus valid head CRC and header sequence consistency; corrupt identity remains unaligned. Complete records with ID corruption are excluded (explicit selection bias), bad data bits with intact ID counted.
- Separate normal delivered IDs, raw matched IDs and failed/uncertain attempts. PER denominator completed TX only. BER denominator unique matched complete Payloads only. Compare coverage and diagnostic drop/transport health reported. No retransmission.
- Never reset serial input buffers per command, no concurrent requests on one port. Never retry SEND. Read retry is safe; ambiguous POP acknowledged via STATUS/head checks. Interrupt/error finally STOP TX/RX and preserve partial report; partial != completed trial.
- Review changes: a response timeout poisons that serial session and aborts; no read retry while a late uncorrelated ASCII reply could arrive. Only fully received, CRC-failed diagnostic replies or explicit SPI-read errors are safely retried. POP is not resent: a complete ERR BER SPI reply can be resolved only if popped increments exactly once. A timeout aborts. TX must be observed running in PACKET mode, then stopped after the expected duration, with an additional 100 ms guard and final error-free status. Actual analog output completion remains a hardware acceptance item.
- Invalid header/length captures may extend beyond a physical frame. Retain them as raw observations and exclude them from aligned BER. BER denominator is all 256 Payload bits in each unique, identity-validated complete capture, including the identity bytes that necessarily passed validation; selection bias and comparison coverage must accompany the number. No loss-to-bit-error imputation.

## Ordered implementation and gates
1. Freeze baseline and plan (this document).
2. Add sidecar + bit-level/SPI/normal-parser differential tests; integrate with minimal top/slave/QSF edits.
3. Add STM32 BER command module + host mocked bus tests, existing RX/TX tests and target compile/link.
4. Add host protocol/controller + mock dual-device tests, integrity, failed TX, duplicate/partial/drop/zero-denominator cases.
5. Run regressions, verify protected hashes and scoped diff; create reproducible test runner and validation report.
6. FPGA synthesis/timing if resources/time allow; otherwise explicitly pending. No claim of board validation from static/simulation evidence.
7. Hardware acceptance later: default-off equivalence, injected CRC error rejected normally but retained in sidecar, known Payload flips counted exactly, full diagnostic queue leaves normal receiver working, then wired/underwater trials.

## Acceptance and reporting
- Must prove disabled behavior unchanged and no production files changed beyond documented attachment points.
- Test good/bad CRC, bad header/length, partial bits, timeout, loss, stop, disabled sync, simultaneous queue pop/publish, seek retry, full queue overflow, rearm policy and transport CRC rejection.
- Report completed vs interrupted state; success != no GOOD in a short trace. Do not equate diagnostic CRC pass with full-system delivery.
- Build artifacts/logs confined to _codex/ber_20261102; no commit/reset or flashing.
