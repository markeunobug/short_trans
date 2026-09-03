#ifndef FPGA_RX_SPI_TEST_STM32G4XX_HAL_H
#define FPGA_RX_SPI_TEST_STM32G4XX_HAL_H

#include <stdint.h>

typedef struct {
    uint32_t unused;
} SPI_HandleTypeDef;

typedef struct {
    uint32_t unused;
} GPIO_TypeDef;

typedef enum {
    HAL_OK = 0,
    HAL_ERROR = 1
} HAL_StatusTypeDef;

typedef enum {
    GPIO_PIN_RESET = 0,
    GPIO_PIN_SET = 1
} GPIO_PinState;

HAL_StatusTypeDef HAL_SPI_TransmitReceive(
    SPI_HandleTypeDef *hspi,
    uint8_t *tx_data,
    uint8_t *rx_data,
    uint16_t length,
    uint32_t timeout_ms);

void HAL_GPIO_WritePin(
    GPIO_TypeDef *gpio_port,
    uint16_t gpio_pin,
    GPIO_PinState pin_state);

#endif
