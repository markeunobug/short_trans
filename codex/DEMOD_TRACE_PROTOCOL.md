# Demodulation Trace V1

Date: 2026-09-24. Scope: the production receiver under code/cyclone10/rx_cyclone10,
code/stm32/rx_stm32 and flutter. The separate cyclone10_ASK/stm32_ASK trees are
not modified. No hardware was programmed or measured during implementation.

## Operator workflow

1. Program the matching receiver FPGA (FW_VERSION 0x14) and RX ARM builds.
   The TX firmware does not need a trace-specific update. Preserve a known-good
   firmware set before bench programming. The supplied SOF is a configuration
   image, not a persistent-flash JIC image.
2. Run short_trans_host.exe with its adjacent DLLs and data directory. Connect
   RX at the existing 115200 / 8N1 settings. STATUS should show ver=20.
3. Select the desired modulation in the existing modulation/threshold page,
   then open the monitor-heart toolbar button (demodulation observation).
4. For an initial test select manual trigger and 128 ms post-trigger, start
   capture, allow at least 384 ms for history, then press the lightning icon.
   The host waits for freeze and automatically downloads the record.
5. Inspect energy, active thresholds, soft decision, confidence (FSK), hard
   decisions, lock, physical symbol samples and frame events on one time axis.
   Hover/touch moves a common cursor; the range slider selects the time window.
6. Save exports both CSV and the original .dtr file under exports/traces in the
   application's working directory. The folder button opens a .dtr by path.
7. Adjust OOK thresholds in the existing settings page between captures, check
   the applied readback, then capture again. V1 does not add an online FSK
   tuning transaction; it records the existing active FSK tuning parameters.

For CRC failures select the CRC trigger and 0 or 64 ms post-trigger. This keeps
most of the buffer for preceding history. At 100 bit/s a whole frame can exceed
this buffer: do not interpret a missing preamble as a preamble detection failure
unless the capture actually includes it. Export intermediate captures before
starting a new capture; V1 holds one frozen capture at a time.

## Implemented limits

- 512 records, one metric every 48 accepted ADC samples at nominal 48 kSPS.
  This is approximately 512 ms of history (511 ms between first and last point).
- 48 bytes per record; a 64-byte header precedes the records. Maximum 24640 bytes.
- Configurable post-trigger count 0..511. UI presets: 0, 64, 128, 256, 511 ms.
- Pre-trigger storage wraps normally. The first trigger wins. Post-trigger
  capture freezes without waiting for ARM/SPI/RS485 and never stalls demodulation.
- STOP, ADC-chain reset, sweep ownership or a change to captured configuration
  freezes the preceding records and marks the capture interrupted. A command
  issued with unavailable ADC/sweep ownership cannot arm the capture.
- Host wait timeout: 30 seconds, then STOP and retrieve the interrupted history.
  Each block gets at most three attempts. Repeated reads do not consume records.
- This release is triggered capture, not continuous full-rate streaming, a live
  statistics dashboard, an amplitude histogram, or the raw ADC snapshot viewer.
  Those are separate follow-ups. The old raw ADC snapshot SPI port is preserved.

## Timing and signal semantics

The sample counter increments on each accepted demodulator ADC sample. The
counter value at metric_valid is recorded, not the Windows receipt time. Both
production correlators finish well before the next normal ADC sample. Counter
wrap is handled modulo 2^32. The host rejects non-48-sample record spacing.

At metric_valid the observer latches energy, noise, threshold, soft metric,
confidence, noise-ready, energy-above-threshold and confidence-ok. In particular,
FSK threshold/flags are sampled BEFORE that metric updates the noise estimator.
This is the threshold actually consumed by symbol synchronization.

The record is written 64 FPGA clocks later (about 2.13 us at 30 MHz), allowing
symbol synchronization and the parser to settle. Hard bit, lock, phase, timing
adjustment and final output bit are taken then. Pulsed events and bit-valid
counts accumulate since the preceding record write. Events are consequently
localized to a metric interval, not measured with sub-millisecond precision.
The trigger marker denotes the record containing the trigger, not an exact
asynchronous event timestamp.

OOK replays its detected 16-bit sync word to the parser at system-clock rate.
The observer records the bit-valid count; count > 1 is marked REPLAY and is not
plotted as a physical symbol sample. Individual replayed bits are not exported;
the final bit value and total count are retained. FSK confidence does not apply
to fixed-threshold OOK, so that curve is hidden in OOK mode.

Carrier flag/trigger: FSK uses confirmed carrier_active; OOK uses tone-on
(energy-ready and the hysteretic hard bit). OOK tone-off between zero symbols
does NOT mean frame lock was lost. Lock is a separate flag/trigger.

## SPI extension

All old addresses remain in place. The independent peripheral is multiplexed
at the top level; it does not write the packet FIFO or demodulator state.
All multi-byte values below are little-endian, including trace samples.

| Address | Meaning |
| --- | --- |
| 0x32 R | Capability signature 0xD1 |
| 0x33 W | Control: bit0 ARM, bit1 manual TRIGGER, bit2 STOP; use separately |
| 0x34 RW | Trigger mask (captured on ARM) |
| 0x35..36 RW | Post-trigger record count (captured on ARM) |
| 0x37 R | Status: bit0 armed, bit1 triggered, bit2 frozen/ready, bit3 interrupted/invalid |
| 0x38..39 R | Frozen record count; zero while not ready |
| 0x3A..3B RW | Absolute byte offset in header+records; seek before each block |
| 0x3C..3D R | Capture ID, incremented on each ARM; wraps modulo 65536 |
| 0x3E..3F R | Trigger index in chronological records, or 0xFFFF if absent |
| 0x42 R | Byte stream; SPI address remains 0x42 across a burst |

The offset increments after each completed byte. Reading before ready or past
the end returns zero. Frozen RAM/header remain unchanged until a new ARM/reset.
RAM reads are synchronous and settle before the next byte at the supported
approximately 1 MHz SPI SCK. ARM verifies firmware 0x13 or 0x14 and signature
0xD1 before issuing commands; unknown layouts are rejected.

Trigger mask bits: 0 manual, 1 carrier rising, 2 lock rising, 3 lock-lost pulse,
4 CRC-error pulse, 5 good-frame pulse, 6 sync-found pulse. Bit7 is reserved.
Combinations are supported by the protocol; the UI chooses one trigger at a time.

## Capture header (64 bytes)

| Offset | Size | Meaning |
| --- | --- | --- |
| 0 | 4 | ASCII DTR1 |
| 4 | 1 | Layout version 1 |
| 5 | 1 | FPGA firmware 0x14 |
| 6 | 1 | Applied mode: 1 FSK / 2 OOK |
| 7 | 1 | Applied sample right shift |
| 8 | 1 | Applied FSK noise multiplier, unsigned Q4.4 |
| 9 | 1 | Applied FSK confidence threshold |
| 10 | 2 | Applied FSK coarse offset units; multiply by 256 for energy counts |
| 12 | 4 | Applied OOK LOW threshold |
| 16 | 4 | Applied OOK HIGH threshold |
| 20 | 4 | Nominal sample rate, 48000 |
| 24 | 2 | Samples per metric, 48 |
| 26 | 2 | Record bytes, 48 |
| 28 | 2 | Frozen record count |
| 30 | 2 | Trigger index, or 0xFFFF |
| 32 | 2 | Capture ID |
| 34 | 1 | Armed trigger mask |
| 35 | 1 | Reserved zero |
| 36 | 2 | Armed post-trigger count |
| 38 | 1 | Frozen status |
| 39 | 1 | Reserved zero |
| 40 / 42 / 44 | 2 each | FSK f0=1700 / f1=1900 / OOK=1800 Hz |
| 46 | 2 | Correlator window samples, FSK=480 / OOK=80 |
| 48 | 16 | Reserved zero |

Mode, shift, margin, confidence, coarse offset units and OOK thresholds are captured on ARM. Offset energy-count contribution is offset_units * 256.
A change aborts capture rather than mixing configurations. A configuration
commit pulse aborts capture even when the committed values are unchanged.

## Metric record (48 bytes)

| Offset | Size | Meaning |
| --- | --- | --- |
| 0 | 4 | Accepted sample counter at metric_valid |
| 4 | 4 | FSK E0, or OOK energy |
| 8 | 4 | FSK E1, or zero in OOK |
| 12 | 8 | Unsigned zero-extended 33-bit noise estimate; zero in OOK |
| 20 | 8 | Unsigned zero-extended 33-bit carrier threshold; HIGH in OOK |
| 28 | 8 | Signed sign-extended 33-bit soft metric |
| 36 | 4 | Flags below |
| 40 | 1 | Confidence, 0..255; zero/unused in OOK |
| 41 | 1 | Selected symbol phase, 0..9 |
| 42 | 1 | Low two bits: signed timing adjustment; decode 2 as -2, 3 as -1 |
| 43 | 1 | Bit-valid event count, saturating at 255 |
| 44 | 1 | Applied confidence threshold |
| 45 | 1 | Applied noise multiplier Q4.4 |
| 46 | 1 | Applied sample shift |
| 47 | 1 | Applied mode |

Soft metric: FSK E1-E0; OOK energy-floor((LOW+HIGH)/2). These are FPGA numeric
energy units, not volts, watts or dBm. For OOK, energy is the saturated unsigned
((I*I+Q*Q)>>28) from the 80-sample Q7 correlator. FSK uses the production 480-sample
correlator's scaled energy, with CORRELATOR_SHIFT=20 and ENERGY_SHIFT=16.
The plot's optional log scale is log10(1+energy), not calibrated decibels.

Flag bits: 0 hard bit, 1 carrier/tone-on, 2 symbol lock, 3 any bit-valid event,
4 final output bit, 5 preamble, 6 lock-lost, 7 sync-found, 8 good-frame,
9 CRC error, 10 header error, 11 length error, 12 frame timeout,
13 search timeout, 14 ADC-near-full-scale or processing clip event,
15 noise-ready (OOK: energy-ready), 16 energy-above-threshold,
17 multiple bits / sync replay, 18 FSK confidence-ok. Other bits are zero.

## RS485 transport

Commands are ASCII lines: TRACE ARM <mask> <post>, TRACE TRIGGER, TRACE STOP,
TRACE STATUS, TRACE READ <capture_id> <offset> <length>. Length is 1..192 bytes.
Control replies are OK TRACE ACK or ERR TRACE <reason>. Status is:

    OK TRACE status=6 id=1 count=512 trigger=383 depth=512

Successful READ replies are binary, framed as zero + COBS(packet) + zero.
The packet before COBS encoding is:

    DTB1 (4 bytes) | id u16 | offset u16 | length u16 | payload | CRC u16

CRC is CRC-16/CCITT-FALSE (poly 0x1021, init 0xFFFF, no reflection, xorout 0),
stored little-endian and covering header plus payload. The CRC protects the
ARM-to-PC transport, not ADC correctness or SPI wiring integrity. Frozen-data
reads can be repeated at the same offset after truncation/CRC error. The host
checks ID, offset, length, header version, record configuration, time continuity
and final status before publishing a capture. It does not display partial blocks.

The existing ASCII status/packet commands remain compatible. Host navigation
to conflicting controls is disabled during capture/download, and commands are
serialized. The MCU handles one short block per request, returning to the normal
receive service between requests; it does not allocate a full trace in SRAM.

The .dtr file is the raw capture header+records, without transport block headers
or an additional archive CRC. Keep the CSV and .dtr together. Imported traces
are labeled offline; simulation fixtures are not board measurements.

## Verification and residual risk

- tools/test_demod_trace.ps1: wire-level SPI, ring wrap, all trigger types,
  pre/post history, retry/seek, early trigger, config/ADC/STOP interruption,
  33-bit data, sign extension and production FSK/OOK metric alignment.
- Production-alignment simulation checks >1000 metrics per mode, 512-record
  timestamp continuity and the OOK 16-bit replay marker. Its stimulus is the
  existing OOK waveform; it is not an end-to-end 2FSK over-air validation.
- tools/test_trace_host.ps1: native C SPI mock, bounds, firmware rejection,
  CRC/COBS, repeated reads, immediate-trigger acknowledgement and UART fixture.
- Flutter tests parse RTL -> native C -> UART bytes end-to-end, including bytewise
  fragmentation; test controller retries, capture ID checks, signed values,
  rollover, malformed layouts, and render FSK/OOK at 1360/390 px widths.
- Existing ARM SPI tests, SPI RTL/OOK configuration and OOK lifecycle regressions
  were also run. See DEMOD_TRACE_VALIDATION.md for build-specific results.
- Bench validation is still required: flashing, link throughput, repeated
  captures, capture during normal frames, disconnect/reconnect and comparison
  with SignalTap. No automatic threshold tuning is implemented.
