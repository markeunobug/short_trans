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

The default matrix covers fixed 1.6/2.0 kHz tones, alternating bits, random
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
the downstream frame FIFO/SPI path, and the current FPGA top level does not
instantiate this RX chain.
