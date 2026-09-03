# FPGA RX SPI1 CubeMX Integration

The checked-in `rx_stm32.ioc` enables SPI1 on PB3/PB4/PB5 with PA4 as a
software-controlled active-low NSS. The current project uses the small
register-level adapter in `Core/Src/fpga_rx_spi_stm32.c`, because this checkout
does not contain the STM32 HAL SPI source/header files. It keeps the generic
driver transport-neutral and allows the complete firmware to build now.

## CubeMX settings

Configure SPI1 as follows:

| Setting | Value |
|---|---|
| Mode | Full-Duplex Master |
| SCK | PB3, SPI1_SCK, AF5 |
| MISO | PB4, SPI1_MISO, AF5 |
| MOSI | PB5, SPI1_MOSI, AF5 |
| NSS | Software-managed GPIO output on PA4 |
| Clock polarity | Low |
| Clock phase | First edge |
| Data size | 8 bit |
| First bit | MSB first |
| CRC | Disabled |
| NSS pulse | Disabled |
| Target baud rate | Approximately 1 MHz |

The current 150 MHz APB2/SPI kernel clock cannot produce exactly 1 MHz with a
power-of-two SPI prescaler. Use `/128` for about 1.172 MHz if the SPI kernel is
150 MHz, or select a kernel clock/prescaler combination close to 1 MHz. Keep
SPI SCK at or below 2.5 MHz because the FPGA implementation requires its
30 MHz system clock to be at least 12 times SCK.

Set PA4 high before enabling normal traffic. PA4 is the active-low FPGA chip
select; it is intentionally a GPIO because every register or stream chunk is a
separate transaction. Use high or very-high GPIO speed for PA4 and the SPI
pins. Internal pulls are normally unnecessary on the point-to-point board
nets; a weak pull-up on PA4 is acceptable if board startup requires it.

The current adapter initializes these settings directly after `MX_GPIO_Init()`.
If CubeMX is regenerated later and the SPI HAL files are added, the optional
`FPGA_RX_SPI_ENABLE_STM32_HAL` adapter may replace it.

After switching to the HAL adapter:

1. Confirm `HAL_SPI_MODULE_ENABLED` and `stm32g4xx_hal_spi.c/.h` exist.
2. Add `FPGA_RX_SPI_ENABLE_STM32_HAL` to the project preprocessor symbols.
3. Add `#include "fpga_rx_spi.h"` inside `USER CODE BEGIN Includes`.
4. Create the driver objects inside a USER CODE variable block.
5. Call the HAL adapter only after `MX_SPI1_Init()` and `MX_GPIO_Init()`.

Example for a future USER CODE block:

```c
#if defined(FPGA_RX_SPI_ENABLE_STM32_HAL)
static fpga_rx_spi_t fpga_rx;
static fpga_rx_spi_hal_context_t fpga_rx_hal;

/* Run after MX_GPIO_Init() and MX_SPI1_Init(). */
if (fpga_rx_spi_init_hal(&fpga_rx, &fpga_rx_hal, &hspi1,
                         GPIOA, GPIO_PIN_4, 100U) != FPGA_RX_SPI_OK) {
    Error_Handler();
}
#endif
```

Do not initialize both adapters in the same firmware image.

## Typical receive flow

```c
fpga_rx_spi_frame_meta_t meta;
uint8_t payload[FPGA_RX_SPI_MAX_PAYLOAD];
size_t received = 0U;
size_t chunk;

if (fpga_rx_spi_begin_frame(&fpga_rx, &meta) == FPGA_RX_SPI_OK) {
    while (received < meta.payload_length) {
        size_t request = meta.payload_length - received;
        if (request > 16U) {
            request = 16U;
        }
        if (fpga_rx_spi_read_payload(&fpga_rx, &payload[received], request,
                                     &chunk) != FPGA_RX_SPI_OK) {
            (void)fpga_rx_spi_drop_frame(&fpga_rx);
            break;
        }
        received += chunk;
    }
    if (received == meta.payload_length) {
        (void)fpga_rx_spi_pop_frame(&fpga_rx);
    }
}
```

`POP_FRAME` is rejected locally until the declared Payload length has been
read. `DROP_FRAME` discards the unread remainder. A zero-length frame can be
popped immediately after `fpga_rx_spi_begin_frame()`.

For a snapshot, call `fpga_rx_spi_snapshot_start()`, poll
`fpga_rx_spi_snapshot_ready()`, then call `fpga_rx_spi_snapshot_read_all()`.
The output is 1024 signed `int32_t` samples. The driver performs 64-byte stream
transactions internally and reconstructs each FPGA MSB-first sample.
