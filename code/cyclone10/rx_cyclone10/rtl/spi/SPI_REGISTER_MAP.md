# RX FPGA SPI1 Register Map

This file freezes the Task 7 software-visible map. No addresses were moved from
the task plan.

## Transaction format

- SPI Mode 0, 8-bit words, MSB first, active-low NSS.
- Target SCK is approximately 1 MHz.
- Command byte: bit 7 is `1` for read and `0` for write; bits 6:0 are address.
- Normal registers auto-increment after each data byte.
- `0x40 RX_DATA` and `0x41 SNAPSHOT_DATA` remain selected for every byte in a
  transaction.
- MISO is high impedance whenever the raw NSS pin is high.

`spi1_slave` synchronizes SCK, NSS and MOSI into the 30 MHz `clk_sys` domain and
does byte shifting there. This is the SPI CDC boundary; no multi-bit register or
FIFO bus crosses between unrelated clocks. The implementation requires
`clk_sys >= 12 * SPI_SCK`; V1.0 uses 30 MHz and approximately 1 MHz.

## Registers

Firmware 0x13 additionally reserves 0x32..0x3F and streaming read port
0x42 for the independent passive trace peripheral. The stream address stays
selected across a burst, like 0x40/0x41. The complete capture, record and
transport contract is in codex/DEMOD_TRACE_PROTOCOL.md at the repository root.

| Address | Name | Access | Definition |
|---:|---|---|---|
| `0x00` | `DEVICE_ID` | R | `0xA7` |
| `0x01` | `FW_VERSION` | R | `0x13` with passive demodulation trace capture |
| `0x02` | `STATUS0` | R | Status bits below |
| `0x03` | `ERROR_FLAGS` | R | Sticky/live error bits below |
| `0x04` | `FRAME_COUNT` | R | Number of committed descriptors, 0..8 |
| `0x05` | `HEAD_VERSION_TYPE` | R | Queue-head Header Byte0 |
| `0x06` | `HEAD_SEQUENCE` | R | Queue-head Header Byte1 |
| `0x07` | `HEAD_LENGTH` | R | Queue-head Payload length, 0..64 |
| `0x08` | `RX_FIFO_LEVEL_L` | R | Queued Payload bytes bits 7:0 |
| `0x09` | `RX_FIFO_LEVEL_H` | R | Queued Payload byte bit 8 in bit 0 |
| `0x0A` | `GOOD_COUNT_L` | R | Accepted frame counter bits 7:0 |
| `0x0B` | `GOOD_COUNT_H` | R | Accepted frame counter bits 15:8 |
| `0x0C` | `CRC_ERROR_L` | R | Decoder CRC error counter bits 7:0 |
| `0x0D` | `CRC_ERROR_H` | R | Decoder CRC error counter bits 15:8 |
| `0x10` | `CONTROL` | W | One-shot controls below |
| `0x11` | `SAMPLE_SHIFT` | R/W | Right shift in bits 4:0; reset value 12 |
| `0x12` | `ENERGY_MARGIN` | R/W | Noise multiplier in unsigned Q4.4; reset `0x20` = 2.0x |
| `0x13` | `CONF_THRESHOLD` | R/W | Confidence threshold; reset value `0x20` |
| `0x14` | `NOISE_OFFSET_L` | R/W | Fixed noise-floor offset low byte; reset value 200 |
| `0x15` | `NOISE_OFFSET_H` | R/W | Fixed noise-floor offset high byte; reset value 0 |
| `0x16` | `HEAD_TIME_FLAGS` | R | Bit 0 timestamp valid; bit 1 TIME_BASE descriptor; bits 7:2 zero |
| `0x17` | `HEAD_TIMESTAMP_B3` | R | Queue-head timestamp bits 31:24 |
| `0x18` | `HEAD_TIMESTAMP_B2` | R | Queue-head timestamp bits 23:16 |
| `0x19` | `HEAD_TIMESTAMP_B1` | R | Queue-head timestamp bits 15:8 |
| `0x1A` | `HEAD_TIMESTAMP_B0` | R | Queue-head timestamp bits 7:0 |
| `0x20` | `LAST_SOFT_L` | R | Soft metric bits 7:0 |
| `0x21` | `LAST_SOFT_H` | R | Soft metric bits 15:8 |
| `0x22` | `LAST_ENERGY_0` | R | Compressed 1.7 kHz energy |
| `0x23` | `LAST_ENERGY_1` | R | Compressed 1.9 kHz energy |
| `0x24` | `LAST_CONFIDENCE` | R | Most recent confidence |
| `0x25..0x28` | `SWEEP_PHASE` | R/W | 32-bit little-endian NCO phase increment |
| `0x29..0x2A` | `SWEEP_SETTLE` | R/W | Settle sample count, little-endian |
| `0x2B..0x2C` | `SWEEP_WINDOW` | R/W | Samples in one energy window, little-endian |
| `0x2D` | `SWEEP_AVERAGE` | R/W | Number of energy windows, 1..255 |
| `0x2E` | `SWEEP_CONTROL` | W | Bit 0 START; bit 1 ABORT |
| `0x2F` | `SWEEP_STATUS` | R | Bit 0 active; bit 1 busy; bit 2 done; bit 3 error |
| `0x30` | `SNAPSHOT_COUNT_L` | R | Unread snapshot words bits 7:0 |
| `0x31` | `SNAPSHOT_COUNT_H` | R | Unread snapshot words bits 10:8 |
| `0x40` | `RX_DATA` | R | Destructive queue-head Payload byte port |
| `0x41` | `SNAPSHOT_DATA` | R | Destructive raw sample byte stream |
| `0x65` | `RX_MODE_SHADOW` | R/W | Full-byte staged receiver mode: 1 FSK, 2 OOK |
| `0x66..0x69` | `ASK_LOW_SHADOW` | R/W | Staged OOK low threshold, uint32 little-endian |
| `0x6A..0x6D` | `ASK_HIGH_SHADOW` | R/W | Staged OOK high threshold, uint32 little-endian |
| `0x6E` | `ASK_CONFIG_CONTROL` | W | bit0 COMMIT, bit1 clear invalid/rejected sticky |
| `0x6F` | `ASK_CONFIG_STATUS` | R | bit0 pending, bit1 rejected, bit2 RX busy, bit3 sweep active |
| `0x70..0x73` | `ASK_LOW_ACTIVE` | R | Active low threshold, uint32 little-endian |
| `0x74..0x77` | `ASK_HIGH_ACTIVE` | R | Active high threshold, uint32 little-endian |
| `0x78..0x7B` | `ASK_ENERGY` | R | Current OOK energy; read `0x78` before upper bytes for a coherent latch |
| `0x7C` | `RX_MODE_ACTIVE` | R | Applied receiver mode: 1 FSK, 2 OOK |
| `0x7D` | `ASK_FLAGS` | R | bit0 hard bit, bit1 symbol lock, bit2 energy ready |
| `0x7E` | `CONFIG_GENERATION` | R | Incremented after each successful deferred apply |
| `0x50..0x57` | `SWEEP_ENERGY_SUM` | R | Sum of window energies, unsigned 64-bit little-endian |
| `0x58..0x5B` | `SWEEP_ENERGY_MIN` | R | Minimum window energy, unsigned 32-bit little-endian |
| `0x5C..0x5F` | `SWEEP_ENERGY_MAX` | R | Maximum window energy, unsigned 32-bit little-endian |
| `0x60..0x63` | `SWEEP_CLIP_COUNT` | R | Near-full-scale/processing clip count, little-endian |
| `0x64` | `SWEEP_WINDOW_COUNT` | R | Completed window count |

### STATUS0 (`0x02`)

| Bit | Meaning |
|---:|---|
| 7 | ADC initialization complete |
| 6 | ADC initialization error |
| 5 | Carrier detected |
| 4 | Symbol timing locked |
| 3 | At least one committed frame is readable |
| 2 | Snapshot words remain available, including prefetched words |
| 1 | Snapshot capture busy |
| 0 | A frame is currently entering the packet FIFO |

### ERROR_FLAGS (`0x03`)

| Bit | Meaning |
|---:|---|
| 7 | I2C error input is active |
| 6 | I2S error input is active |
| 5 | CDC error input is active |
| 4 | Packet FIFO overflow; the new frame was discarded |
| 3 | Decoder or packet protocol error (does not include normal symbol-search timeout while idle) |
| 2 | Incomplete SPI byte/transaction error |
| 1 | Snapshot data read while no byte was available |
| 0 | Reserved, reads zero |

### CONTROL (`0x10`)

Writing a one generates a one-cycle pulse. Bits may be combined except that
software should not assert `POP_FRAME` and `DROP_FRAME` together.

| Bit | Name | Effect |
|---:|---|---|
| 0 | `CLEAR_ERRORS` | Clear Task 7 sticky errors and pulse upstream clear |
| 1 | `ADC_REINIT` | Request the fixed ADC initialization sequence again |
| 2 | `SNAPSHOT_START` | Trigger a 1024-word raw sample capture |
| 3 | `POP_FRAME` | Pop descriptor only when all Payload bytes were read |
| 4 | `DROP_FRAME` | Discard unread Payload bytes and pop the descriptor |
| 7:5 | Reserved | Ignored |

## Frame FIFO behavior

- Payload storage is 256 bytes and descriptor storage is 8 entries.
- `frame_valid` starts an ingress frame and supplies the three metadata bytes.
- V2 descriptors also retain the decoded timestamp and validity. TIME_BASE uses
  a 32-bit seconds value; DATA uses a zero-extended 24-bit 10 ms elapsed value.
  Both are exposed most-significant byte first at `0x17..0x1A`.
- A nonzero Payload follows through `frame_payload_valid`; the last byte asserts
  `frame_payload_last`.
- A descriptor is committed only when the exact declared number of bytes has
  arrived. Zero-length frames commit on `frame_valid`.
- Capacity is checked before accepting a frame. If either FIFO lacks room, the
  entire new frame is drained and discarded; unread old frames are unchanged.
- Reading `RX_DATA` advances only the queue-head Payload pointer. Reads may be
  split across transactions. Metadata remains fixed until POP or DROP.
- Early POP, empty RX_DATA reads, malformed ingress length and empty DROP set
  the protocol error flag.

## Snapshot behavior

`adc_snapshot` has a synchronous 32-bit read port. The register bank keeps a
two-word prefetch queue so a continuous 1 MHz SPI burst never waits for RAM.
Each sample is sent most-significant byte first. `SNAPSHOT_COUNT` includes both
words still owned by `adc_snapshot` and words already prefetched by SPI logic.

## Sweep behavior

- Sweep measurement uses a dedicated configurable single-tone I/Q correlator.
- `SWEEP_PHASE = round(frequency_hz * 2^32 / 48000)`.
- A START clears prior results, discards `SWEEP_SETTLE` accepted samples, then
  computes `E = I^2 + Q^2` for each non-overlapping `SWEEP_WINDOW` block.
- Results remain stable while `done=1`. Software computes the reported mean as
  `SWEEP_ENERGY_SUM / SWEEP_WINDOW_COUNT`.
- While sweep is active, the normal 2FSK demodulator and frame parser are held
  in reset. ABORT releases them and clears the sweep active state.

## Mode-2 OOK configuration

`COMMIT` snapshots all three shadow fields only when no prior transaction is pending. It rejects mode values other than 1/2 and `LOW >= HIGH`; shadow writes never alter a pending transaction. A valid pending transaction applies only after candidate/frame processing and sweep are inactive. Applying resets the selected demodulator history but does not clear the packet FIFO or parser TIME_BASE state.

The fixed OOK decision is `energy >= HIGH` => one, `energy <= LOW` => zero, with the prior bit retained strictly inside the hysteresis band. The energy metric is the saturated `((I*I + Q*Q) >> 28)` from an 80-sample, 1800 Hz Q7 I/Q sliding correlator; 400/600 are provisional software defaults.
