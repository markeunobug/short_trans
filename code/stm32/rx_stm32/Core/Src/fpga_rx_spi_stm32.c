#include "fpga_rx_spi_stm32.h"

#include "main.h"

#define FPGA_RX_SPI_TARGET_HZ 1000000UL
#define FPGA_RX_SPI_MAX_HZ    2500000UL

static uint32_t fpga_rx_spi_stm32_select_br(
    uint32_t input_clock_hz,
    uint32_t *sck_hz)
{
    static const uint16_t dividers[] = {2U, 4U, 8U, 16U, 32U, 64U, 128U, 256U};
    uint32_t selected = 7U;
    uint32_t best_error = UINT32_MAX;
    uint32_t index;

    for (index = 0U; index < (sizeof(dividers) / sizeof(dividers[0])); ++index) {
        uint32_t candidate = input_clock_hz / dividers[index];
        uint32_t error;

        if (candidate > FPGA_RX_SPI_MAX_HZ) {
            continue;
        }
        error = (candidate > FPGA_RX_SPI_TARGET_HZ)
                    ? (candidate - FPGA_RX_SPI_TARGET_HZ)
                    : (FPGA_RX_SPI_TARGET_HZ - candidate);
        if (error < best_error) {
            selected = index;
            best_error = error;
        }
    }

    *sck_hz = input_clock_hz / dividers[selected];
    return selected << SPI_CR1_BR_Pos;
}

static bool fpga_rx_spi_stm32_wait_flag(
    uint32_t mask,
    bool set,
    uint32_t timeout_ms)
{
    uint32_t start = HAL_GetTick();

    for (;;) {
        if (((SPI1->SR & mask) != 0U) == set) {
            return true;
        }
        if ((timeout_ms != HAL_MAX_DELAY) &&
            ((HAL_GetTick() - start) >= timeout_ms)) {
            return false;
        }
    }
}

static fpga_rx_spi_result_t fpga_rx_spi_stm32_transfer(
    void *opaque,
    const uint8_t *tx_data,
    uint8_t *rx_data,
    size_t length,
    uint32_t timeout_ms)
{
    fpga_rx_spi_stm32_t *context = (fpga_rx_spi_stm32_t *)opaque;
    size_t index;

    if ((context == NULL) || (context->instance != SPI1) ||
        (tx_data == NULL) || (rx_data == NULL)) {
        return FPGA_RX_SPI_INVALID_ARGUMENT;
    }

    for (index = 0U; index < length; ++index) {
        if (!fpga_rx_spi_stm32_wait_flag(SPI_SR_TXE, true, timeout_ms)) {
            return FPGA_RX_SPI_IO_ERROR;
        }
        *(__IO uint8_t *)&context->instance->DR = tx_data[index];
        if (!fpga_rx_spi_stm32_wait_flag(SPI_SR_RXNE, true, timeout_ms)) {
            return FPGA_RX_SPI_IO_ERROR;
        }
        rx_data[index] = *(__IO uint8_t *)&context->instance->DR;
    }

    if (!fpga_rx_spi_stm32_wait_flag(SPI_SR_TXE, true, timeout_ms) ||
        !fpga_rx_spi_stm32_wait_flag(SPI_SR_BSY, false, timeout_ms)) {
        return FPGA_RX_SPI_IO_ERROR;
    }
    if ((context->instance->SR & (SPI_SR_OVR | SPI_SR_MODF)) != 0U) {
        volatile uint32_t clear = context->instance->DR;
        clear = context->instance->SR;
        (void)clear;
        return FPGA_RX_SPI_IO_ERROR;
    }

    return FPGA_RX_SPI_OK;
}

static void fpga_rx_spi_stm32_chip_select(void *opaque, bool selected)
{
    fpga_rx_spi_stm32_t *context = (fpga_rx_spi_stm32_t *)opaque;

    if (context != NULL) {
        HAL_GPIO_WritePin(
            context->nss_port,
            context->nss_pin,
            selected ? GPIO_PIN_RESET : GPIO_PIN_SET);
    }
}

fpga_rx_spi_result_t fpga_rx_spi_stm32_init(
    fpga_rx_spi_t *device,
    fpga_rx_spi_stm32_t *context,
    uint32_t timeout_ms)
{
    GPIO_InitTypeDef gpio = {0};
    fpga_rx_spi_bus_t bus;
    uint32_t br_bits;

    if ((device == NULL) || (context == NULL)) {
        return FPGA_RX_SPI_INVALID_ARGUMENT;
    }

    __HAL_RCC_GPIOA_CLK_ENABLE();
    __HAL_RCC_GPIOB_CLK_ENABLE();
    __HAL_RCC_SPI1_CLK_ENABLE();

    HAL_GPIO_WritePin(FPGA_NSS_GPIO_Port, FPGA_NSS_Pin, GPIO_PIN_SET);
    gpio.Pin = FPGA_NSS_Pin;
    gpio.Mode = GPIO_MODE_OUTPUT_PP;
    gpio.Pull = GPIO_NOPULL;
    gpio.Speed = GPIO_SPEED_FREQ_VERY_HIGH;
    HAL_GPIO_Init(FPGA_NSS_GPIO_Port, &gpio);

    gpio.Pin = GPIO_PIN_3 | GPIO_PIN_4 | GPIO_PIN_5;
    gpio.Mode = GPIO_MODE_AF_PP;
    gpio.Pull = GPIO_NOPULL;
    gpio.Speed = GPIO_SPEED_FREQ_VERY_HIGH;
    gpio.Alternate = GPIO_AF5_SPI1;
    HAL_GPIO_Init(GPIOB, &gpio);

    context->instance = SPI1;
    context->nss_port = FPGA_NSS_GPIO_Port;
    context->nss_pin = FPGA_NSS_Pin;
    context->input_clock_hz = HAL_RCC_GetPCLK2Freq();
    br_bits = fpga_rx_spi_stm32_select_br(
        context->input_clock_hz, &context->sck_hz);

    __HAL_RCC_SPI1_FORCE_RESET();
    __HAL_RCC_SPI1_RELEASE_RESET();
    context->instance->CR1 = 0U;
    context->instance->CR2 = (7U << SPI_CR2_DS_Pos) | SPI_CR2_FRXTH;
    context->instance->CR1 = SPI_CR1_MSTR | SPI_CR1_SSM | SPI_CR1_SSI | br_bits;
    context->instance->CR1 |= SPI_CR1_SPE;

    bus.transfer = fpga_rx_spi_stm32_transfer;
    bus.chip_select = fpga_rx_spi_stm32_chip_select;
    bus.context = context;
    bus.timeout_ms = timeout_ms;
    return fpga_rx_spi_init(device, &bus);
}
