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

| Address | Name | Access | Definition |
|---:|---|---|---|
| `0x00` | `DEVICE_ID` | R | `0xA7` |
| `0x01` | `FW_VERSION` | R | `0x10` for protocol V1.0 |
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
| `0x12` | `ENERGY_MARGIN` | R/W | Noise multiplier in unsigned Q4.4; reset `0x40` = 4.0x |
| `0x13` | `CONF_THRESHOLD` | R/W | Confidence threshold; reset value `0x20` |
| `0x14` | `NOISE_OFFSET_L` | R/W | Fixed noise-floor offset low byte; reset value 200 |
| `0x15` | `NOISE_OFFSET_H` | R/W | Fixed noise-floor offset high byte; reset value 0 |
| `0x20` | `LAST_SOFT_L` | R | Soft metric bits 7:0 |
| `0x21` | `LAST_SOFT_H` | R | Soft metric bits 15:8 |
| `0x22` | `LAST_ENERGY_0` | R | Compressed 1.6 kHz energy |
| `0x23` | `LAST_ENERGY_1` | R | Compressed 2.0 kHz energy |
| `0x24` | `LAST_CONFIDENCE` | R | Most recent confidence |
| `0x30` | `SNAPSHOT_COUNT_L` | R | Unread snapshot words bits 7:0 |
| `0x31` | `SNAPSHOT_COUNT_H` | R | Unread snapshot words bits 10:8 |
| `0x40` | `RX_DATA` | R | Destructive queue-head Payload byte port |
| `0x41` | `SNAPSHOT_DATA` | R | Destructive raw sample byte stream |

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
| 3 | Decoder or packet protocol error |
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
