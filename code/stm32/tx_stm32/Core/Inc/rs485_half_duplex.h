#ifndef RS485_HALF_DUPLEX_H
#define RS485_HALF_DUPLEX_H

#ifdef __cplusplus
extern "C" {
#endif

#include "stm32g4xx_hal.h"

#include <stdint.h>

typedef struct
{
    UART_HandleTypeDef *uart;
    GPIO_TypeDef *enable_port;
    uint16_t enable_pin;
} rs485_half_duplex_t;

HAL_StatusTypeDef rs485_half_duplex_init(rs485_half_duplex_t *bus,
                                         UART_HandleTypeDef *uart,
                                         GPIO_TypeDef *enable_port,
                                         uint16_t enable_pin);
void rs485_half_duplex_set_receive(rs485_half_duplex_t *bus);
HAL_StatusTypeDef rs485_half_duplex_transmit(rs485_half_duplex_t *bus,
                                             const uint8_t *data,
                                             uint16_t length,
                                             uint32_t timeout_ms);
HAL_StatusTypeDef rs485_half_duplex_receive(rs485_half_duplex_t *bus,
                                            uint8_t *data,
                                            uint16_t length,
                                            uint32_t timeout_ms);

#ifdef __cplusplus
}
#endif

#endif /* RS485_HALF_DUPLEX_H */
