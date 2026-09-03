#ifndef FPGA_RX_SPI_STM32_H
#define FPGA_RX_SPI_STM32_H

#include "fpga_rx_spi.h"
#include "stm32g4xx_hal.h"

typedef struct {
    SPI_TypeDef *instance;
    GPIO_TypeDef *nss_port;
    uint16_t nss_pin;
    uint32_t input_clock_hz;
    uint32_t sck_hz;
} fpga_rx_spi_stm32_t;

fpga_rx_spi_result_t fpga_rx_spi_stm32_init(
    fpga_rx_spi_t *device,
    fpga_rx_spi_stm32_t *context,
    uint32_t timeout_ms);

#endif
