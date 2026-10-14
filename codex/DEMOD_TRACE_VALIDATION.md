# Demod Trace V1 Validation

Date: 2026-09-24. Scope: main RX FPGA, RX STM32 and Flutter Windows host.
No device was programmed, no serial port was connected, and no board measurement was performed.
Independent cyclone10_ASK and stm32_ASK trees were not modified for this feature.

## Automated checks

### FIX1 additional check

- FSK noise tracker fix: before `noise_ready`, a positive correlator output is no longer reported as `energy_above_threshold`. The dedicated noise-tracker regression passed with this startup assertion, and the integration RX chain regression remained passing.

- RTL recorder regression: ring wrap, trigger masks, stream seek/retry, 33-bit and signed fields, configuration/ADC/STOP interruptions and invalid post count passed.
- Production observer alignment: 1299 OOK metrics and 1292 FSK metrics checked; one 16-bit OOK sync replay identified separately from physical samples. Full 512-record capture and 48-sample spacing checked. The FSK observer used an OOK waveform stimulus: this is NOT an over-air FSK frame validation.
- Native production ARM transport tests: strict GCC warnings-as-errors build, command bounds, retries, CRC/COBS, SPI failure handling and immediate-trigger ARM acknowledgement passed.
- Existing SPI RTL, FPGA SPI C driver, OOK SPI configuration and OOK lifecycle regression checks passed.
- Cross-layer fixture: RTL generated 448 bytes (8 records); production ARM code encoded the UART blocks; Flutter decoded fragmented bytes and verified records 7 through 14. Fixtures are in _codex/trace.
- Flutter suite: 23 tests passed. Static analysis: no issues found. Windows release build passed.
- Widget renders covered both modes at widths 1360 and 390; nonblank/color checks passed and no layout overflow exceptions occurred. The image viewing tool was unavailable, so there was no manual visual inspection. Rendered fixtures are simulation data, not measurements.
- Scoped git diff --check passed, with only working-copy line-ending notices.

## Final build artifacts

FPGA build: _codex/ook/release_20260924_112633

FIX1 replacement FPGA build: _codex/ook/release_20260924_125845

- Quartus compile: PASS. Snapshot/live source drift list: empty.
- Target: Cyclone 10 LP 10CL025YE144I7G.
- Logic elements: 22406 / 24624 (91%). Memory bits: 306688 / 608256 (50%).
- Embedded 9-bit multipliers: 96 / 132 (73%).
- Minimum reported constrained-path slack: 0.132 ns.
- SOF SHA256: a26ffb0c293166d6ad7e1febcefe63d8f05b1eedc1b96cf059d68de48b379199
- FIX1 SOF SHA256: 8b0b8e68baa518016179d6e3c74d483aef7479c41f4198c848c51b1bb2b01707
- FIX1 minimum reported constrained-path slack: 0.096 ns.

RX ARM build: code/stm32/rx_stm32/Tests/build_ook_hardfloat_20260924_112357

- Hard-float build passed with warnings as errors.
- ELF sections: text 20560, data 104, bss 2824 bytes.
- ELF SHA256: 09FE9329F301163A15BECEC7D32C3AFF54705FA7CD20A374500BC9D74A6596E4
- Build directory includes source_hashes.json; packaging checks recorded sources.

Host: flutter/build/windows/x64/runner/Release/short_trans_host.exe

The release package includes its required DLLs and data directory, matching receiver firmware, these documents and a SHA256 manifest.

## Residual risks and limits

- Positive reported slack is not complete timing sign-off. STA lists 2 unconstrained input ports (50 paths) and 1 unconstrained output port (1 path). Review timing constraints and physical interfaces before hardware qualification.
- Quartus still reports width truncations, an OOK correlator loop-variable latch inference, RAM read-during-write and incomplete I/O assignment warnings. The compile is not warning-free. Recorder field truncation/wrap behavior is covered by tests but does not replace full hardware qualification.
- Logic occupancy is high (91%); future extensions need a resource and timing review.
- Actual RS485 throughput, noise robustness, repeated acquisition and capture impact on live reception remain unmeasured.
- Capture is limited to 512 millisecond-spaced points; a long frame may not fit. Event positions have metric-interval granularity, not FPGA-clock precision.
- This version does not add continuous overview, raw ADC plotting, automatic threshold optimization or online FSK parameter editing. OOK refers to the main fixed dual-threshold OOK implementation, not arbitrary ASK variants.
- Preserve known-working firmware. First bench acceptance should check firmware version 0x13, manual capture, each modulation mode, CRC/loss triggers, configuration interruption and normal reception with diagnostics enabled/disabled.
