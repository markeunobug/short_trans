#include "rs485_half_duplex.h"

HAL_StatusTypeDef rs485_half_duplex_init(rs485_half_duplex_t *bus,
                                         UART_HandleTypeDef *uart,
                                         GPIO_TypeDef *enable_port,
                                         uint16_t enable_pin)
{
    if ((bus == NULL) || (uart == NULL) ||
        (enable_port == NULL) || (enable_pin == 0U))
    {
        return HAL_ERROR;
    }

    bus->uart = uart;
    bus->enable_port = enable_port;
    bus->enable_pin = enable_pin;
    rs485_half_duplex_set_receive(bus);
    return HAL_OK;
}

void rs485_half_duplex_set_receive(rs485_half_duplex_t *bus)
{
    if ((bus != NULL) && (bus->enable_port != NULL))
    {
        HAL_GPIO_WritePin(bus->enable_port, bus->enable_pin, GPIO_PIN_RESET);
    }
}

HAL_StatusTypeDef rs485_half_duplex_transmit(rs485_half_duplex_t *bus,
                                             const uint8_t *data,
                                             uint16_t length,
                                             uint32_t timeout_ms)
{
    HAL_StatusTypeDef result;

    if ((bus == NULL) || (bus->uart == NULL) ||
        (bus->enable_port == NULL) || (data == NULL) || (length == 0U))
    {
        return HAL_ERROR;
    }

    HAL_GPIO_WritePin(bus->enable_port, bus->enable_pin, GPIO_PIN_SET);
    result = HAL_UART_Transmit(bus->uart, data, length, timeout_ms);
    HAL_GPIO_WritePin(bus->enable_port, bus->enable_pin, GPIO_PIN_RESET);
    return result;
}

HAL_StatusTypeDef rs485_half_duplex_receive(rs485_half_duplex_t *bus,
                                            uint8_t *data,
                                            uint16_t length,
                                            uint32_t timeout_ms)
{
    if ((bus == NULL) || (bus->uart == NULL) ||
        (bus->enable_port == NULL) || (data == NULL) || (length == 0U))
    {
        return HAL_ERROR;
    }

    rs485_half_duplex_set_receive(bus);
    return HAL_UART_Receive(bus->uart, data, length, timeout_ms);
}
