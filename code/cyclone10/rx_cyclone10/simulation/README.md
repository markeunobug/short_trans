# RTL Simulation and Vector Regression

This directory contains the reproducible Task 10 vector and RTL-regression
framework.  The integration group includes a real sample-domain chain from
the signed 20-bit demodulator input through payload output.

## Requirements

- Python 3 (standard library only)
- ModelSim commands `vlib`, `vlog`, and `vsim` on `PATH`
- PowerShell 5.1 or newer

The validated local simulator is ModelSim 10.1c.

## Generate vectors

From `code/cyclone10/rx_cyclone10`:

```powershell
python tools\gen_fsk_vectors.py --self-test
python tools\gen_fsk_vectors.py --output simulation\generated
```

The generator reads `rtl/protocol/fsk_sync_word.vh`; it does not carry a
second hard-coded sync word.  The default seed is fixed.  Use `--seed 0x1234`
to create another reproducible data set and `--payload-hex` to change the
complete-frame payload (maximum 64 bytes).

`simulation/generated/manifest.json` records every seed, impairment, file,
sample count, and SHA-256 digest.  Each scenario includes:

- `*.samples_i20.mem`: signed 20-bit demodulator input.
- `*.samples_i32.mem`: the same value shifted left by 12 for a 32-bit ADC path.
- `*.bits.mem`: intended MSB-first symbol bits.
- `*.frame.hex`: complete physical-frame bytes when the scenario is a frame.

The default matrix covers fixed 1.7/1.9 kHz tones, alternating bits, random
initial phase, three amplitudes, positive/negative/drifting DC, AWGN at 30,
20, 10, and 0 dB, frequency offsets of 0, +/-5, +/-10, and +/-20 Hz, and a
complete CRC-protected packet with a random sample start offset.  Samples are
48 kSPS and symbols are 480 samples (100 bit/s).

## Run regression

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File simulation\run_rtl_regression.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File simulation\run_rtl_regression.ps1 -Group protocol
powershell -NoProfile -ExecutionPolicy Bypass -File simulation\run_rtl_regression.ps1 -ListOnly
```

Available groups are `common`, `adc`, `demod`, `sync`, `protocol`, `spi`,
`integration`, and `misc`.  Existing `tb/*.sv` files are collected at run
time, so later Task 2/5 benches are included without editing the script.

The script returns nonzero for tool, compile, simulator, explicit `FAIL`, or
missing-`PASS` failures.  This catches benches that print `FAIL` but finish
with simulator exit code zero.  Logs are written below
`simulation/.regression/logs`.

`integration_vector_contract_tb` validates generated-file shape only.
`integration_rx_chain_tb` drives the generated `complete_frame_nominal`
signed 20-bit samples through `fsk_demod_core`, `fsk_symbol_sync`, and
`fsk_frame_rx`.  It checks the recovered header and every payload byte against
the generated physical-frame file and requires one CRC-valid frame with no
protocol error pulses.  The default generated packet has a variable 16-byte
payload; use `gen_fsk_vectors.py --payload-hex ...` to exercise another length.

The integration bench deliberately begins at the documented 20-bit
demodulator sample interface.  It does not cover the board I2S capture/CDC or
the downstream frame FIFO/SPI path, and is distinct from a full top-level or board test. The current FPGA top level
selects the FSK/OOK chains and connects them to the frame parser/FIFO.


## Mode 2 OOK tests

Run from this FPGA project directory:

```powershell
python simulation/run_ook_vectors.py
powershell -ExecutionPolicy Bypass -File simulation/run_ook_lifecycle.ps1
powershell -ExecutionPolicy Bypass -File simulation/run_ook_spi_config.ps1
```

The vector runner checks 24 cases against CRC counts, frame metadata, timestamps and every payload
byte, then replays the real STM32 TX C fixture. It compiles into a separate retained `_codex` library.
`--fixture-only` runs just the TX fixture. Regenerate the sample vectors with
`python tools/gen_ook_validation_vectors.py`; regenerate the actual TX fixture using the STM32
`Tests/generate_ook_packet_fixture.ps1` script.

The two manifest-driven benches (`ook_validation_vectors_tb`, `ook_tx_fixture_chain_tb`) are
excluded from the generic regression scan because they need scenario-specific plusargs.
The lifecycle bench covers fixed hysteresis, phase-window midpoint selection, sync replay, long
zero runs and metric-dropout release. The SPI bench drives the production SPI slave to check
atomic commits, deferred apply and coherent energy readback.

The sample-chain runs accelerate sample cadence to one sample per simulation clock; they verify
digital math/protocol behavior. Lifecycle watchdog counts are checked separately. Physical I2S,
analog gain, noise, frequency mismatch and board timing require hardware validation.
