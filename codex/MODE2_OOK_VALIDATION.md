# Mode 2 OOK verification record

Date: 2026-09-23. Status: implementation and software/RTL/build validation complete; no hardware programming or board test performed.

## Scope and parallel work
The primary agent froze the plan/interfaces and reviewed changes. Requested low-cost Luna agents
failed with provider HTTP502 rate_limit_error before implementation. Terra fallback agents implemented
TX, RX firmware, and FPGA separately; the primary agent implemented/reviewed Flutter integration.
The workspace already had uncommitted changes. During this task additional external FSK changes
from 1.6/2.0 kHz to 1.7/1.9 kHz appeared across TX/FPGA/UI. The OOK agents did not originate
those edits and preserved them; FSK regression must use the resulting current source baseline.

## Completed verification
- Flutter `flutter analyze --no-pub`: no issues.
- Flutter `flutter test --no-pub`: 15 tests passed, including actual/pending readback distinction,
  partial TX/RX mode failures, uint32 validation, reply filtering, and narrow-window layout.
- Flutter `flutter build windows --no-pub`: PASS.
  Output: `flutter/build/windows/x64/runner/Release/short_trans_host.exe`.
- TX agent: `python Tests/test_fsk_tx_model.py` and `Tests/run_fsk_tx_hal_mock.ps1`: PASS.
  Actual C rendering covers OOK PACKET/ALT/PRBS, midpoint zero/silence, exact1800Hz LUT,
  busy changes, explicit tone/carrier/sweep diagnostics, STATUS/HELP complete lines.
- RX agent: `Tests/fpga_rx_spi_build_test.ps1` and `python Tests/test_stm32_integration.py`: PASS.
  Host mock verifies register endian/layout, firmware gate, pending/error rejection, coherent generation,
  invalid active config, SPI failure. Compiled command-text tests cover uint32 max/overflow/separators.
- Legacy STM32 build scripts pass but complete linking uses SOFT float; hard-float syntax check alone
  is not a hard-float firmware build. Separate primary-agent build below addresses this distinction.
- `tools/build_ook_firmware.ps1 -Target rx_stm32`: full HARD-float compile/link, HEX/BIN output PASS.
  ELF: `code/stm32/rx_stm32/Tests/build_ook_hardfloat_20260923_181209/rx_stm32_ook.elf`
  SHA256: `28BCCE0795D2632E89C623F912A4C45664CA30574923AB199A64E50888A596BE`.
  text/data/bss=16768/24/2488 bytes.
- `tools/build_ook_firmware.ps1 -Target tx_stm32`: full HARD-float compile/link, HEX/BIN output PASS.
  ELF: `code/stm32/tx_stm32/Tests/build_ook_hardfloat_20260923_181246/tx_stm32_ook.elf`
  SHA256: `12F81F16686CA493AB5409D3749C4DF4A4E3ACC1467823BA7E8F69D2103F7BE3`.
  text/data/bss=21552/20/4820 bytes.
- Actual TX C fixture: `code/stm32/tx_stm32/Tests/fixtures/ook_1800_timebase_then_data.mem`.
  139200 unsigned12bit DAC samples; TIME_BASE then DATA01234567; metadata alongside file.
  Any DAC->ADC mapping in RTL simulation is synthetic, not measured channel gain.

## FPGA checks completed so far
- Primary lifecycle bench: threshold equality/hysteresis/u32 maximum, AAAA candidate stalled-metric
  release, fast 16-clock sync replay, 64 zero symbols without false unlock, and single dropout release PASS.
  Runner: `code/cyclone10/rx_cyclone10/simulation/run_ook_lifecycle.ps1`.
- Wire-level SPI (production slave + register bank): config snapshot isolation, busy/sweep deferred apply,
  invalid mode/threshold rejection, error clearing, generation, and energy change at preload-edge PASS.
  Runner: `code/cyclone10/rx_cyclone10/simulation/run_ook_spi_config.ps1`.
  Retained log: `code/cyclone10/rx_cyclone10/_codex/ook_spi/82627d575f0d46b6940e23496325a0e4/ook_spi_config.log`.
- Read-only reset review: parser TIME_BASE and committed FIFO entries survive mode configuration;
  partial parser state is released via lock_lost. This is review evidence, not a top-level hardware test.
- Existing SPI regression PASS reported by RX agent.
- Intermediate full Quartus 17.1 compile (18:26, before final symbol-phase selection review) PASS:
  20,934/24,624 LEs (85%), 92/132 9-bit multipliers, 158,208 memory bits.
  Reported setup worst +7.129ns, hold worst +0.142ns. Final-source build still required.
- Current firmware C hashes rechecked unchanged from the hard-float builds above.

## Final functional RTL evidence
- 24 sample-vector scenarios PASS with exact frame metadata, timestamp/valid flags, every payload
  byte and expected CRC-error count: max64-byte zero/FF, random, badCRC then good, TIME_BASE then DATA,
  carrier rotations, and ten 48-sample phase offsets covering a full480-sample symbol.
  Logs: `code/cyclone10/rx_cyclone10/_codex/ook_vectors_20260923_184816/`.
- Actual TX C fixture PASS with TIME_BASE1790121600 (2026-09-23 00:00:00 UTC encoding), DATA elapsed0,
  payload01234567, metadata flags and no parser errors. Earlier test expected an incorrect epoch;
  the scoreboard was corrected from the documented fixture date, with no production-code change.
  Log: `code/cyclone10/rx_cyclone10/_codex/ook_vectors_20260923_185159/tx_fixture.log`.
- Updated lifecycle PASS includes disjoint viable intervals, last candidate inclusion, modulo10 wrap,
  and midpoint selection. Log: `simulation/.ook_lifecycle_20260923_184836/simulation.log` under FPGA project.
- Final relevant legacy regressions PASS: FSK symbol sync, CRC, both frame parser benches and SPI Task7.
  Logs: `code/cyclone10/rx_cyclone10/_codex/ook_legacy_20260923_185118/`.
- Sample-chain simulations use accelerated sample cadence; metric-gap watchdog is tested separately.
  They do not simulate physical I2S or analog channel noise/frequency offset.

## Implemented DSP definition
1800Hz noncoherent I/Q correlation uses an 80-entry Q7 reference spanning three carrier cycles.
It integrates the latest 80 samples and emits one metric per 48 samples (1ms at48kHz).
Energy is saturating uint32 `(I*I + Q*Q) >> 28`; four pipeline clock stages shorten the timing path.
The integration window supplies temporal averaging; no separate post-energy low-pass filter is added.
Hysteresis: energy>=HIGH gives1; energy<=LOW gives0; between thresholds retains previous hard bit.
There is no carrier phase lock requirement and no automatic threshold calibration.
Independent vector calculation with sine peak amplitude80 at the correlator's signed20 input gives
energy616 for all80 discrete carrier rotations. This does NOT specify a voltage at the ADC pins:
the analog gain and upstream digital shift must be accounted for during bench tuning.

## Final frozen-source build
- Command: `python tools/build_ook_fpga.py`; full Quartus17.1 synthesis, fit, assembler and STA PASS.
- Snapshot: `_codex/ook/release_20260923_184919/source/`; SHA256 manifest beside it.
  Final live-source drift check: no changed design inputs.
- SOF: `_codex/ook/release_20260923_184919/source/output_files_ook_v1/rx_cyclone10.sof`.
  SHA256: `17cc17f1fb77f325dfa14eec5f7930f7b13fd1b69ecff549f256d74f39906d84`.
- Fit: 20,998/24,624 LEs(85%), 10,863 registers, 158,208 memory bits,
  92/132 embedded9-bit multipliers(70%).
- Worst constrained setup +6.566ns; hold +0.094ns; all reported slack categories nonnegative.
  There are no unconstrained clocks. Unconstrained ports are JTAG reserved TDI/TMS/TDO only.
  Existing SDC async groups, SPI synchronizer false paths and I/O max/min delays were preserved.
- Build is not warning-free: bounded counter/phase width truncation, unused debug mask,
  reset-loop integer k warning, RAM read-during-write and existing board I/O warnings remain.
  Full logs and `timing_review.json` are retained; this is not blanket board-level timing sign-off.
- The FPGA subagent's service later failed with INSUFFICIENT_BALANCE; primary completed phase-window
  correction, exact vector scoreboards, final regressions and frozen-source compile.

## Hardware validation still required
No calibrated threshold, receive sensitivity/noise/frequency-offset limit or hardware success is claimed.
