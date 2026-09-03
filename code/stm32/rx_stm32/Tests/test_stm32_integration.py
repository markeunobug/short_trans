#!/usr/bin/env python3
"""Static contract checks for the checked-in STM32 RX board integration."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def main() -> None:
    ioc = (ROOT / "rx_stm32.ioc").read_text(encoding="ascii")
    main_source = (ROOT / "Core" / "Src" / "main.c").read_text(encoding="ascii")
    main_header = (ROOT / "Core" / "Inc" / "main.h").read_text(encoding="ascii")
    adapter = (ROOT / "Core" / "Src" / "fpga_rx_spi_stm32.c").read_text(
        encoding="ascii"
    )
    rs485 = (ROOT / "Core" / "Src" / "rs485_half_duplex.c").read_text(
        encoding="ascii"
    )
    irq = (ROOT / "Core" / "Src" / "stm32g4xx_it.c").read_text(
        encoding="ascii"
    )

    assert "PA4.GPIO_Label=FPGA_NSS" in ioc
    assert "PA4.PinState=GPIO_PIN_SET" in ioc
    assert "PB3.Signal=SPI1_SCK" in ioc
    assert "PB4.Signal=SPI1_MISO" in ioc
    assert "PB5.Signal=SPI1_MOSI" in ioc
    assert "SPI1.BaudRatePrescaler=SPI_BAUDRATEPRESCALER_128" in ioc
    assert "PA7.GPIO_Label=RS485A_EN" in ioc
    assert "PC4.GPIO_Label=RS485A_RX" in ioc
    assert "PC5.GPIO_Label=RS485A_TX" in ioc
    assert "USART1.SwapParam-Asynchronous=ADVFEATURE_SWAP_ENABLE" in ioc
    assert "NVIC.USART1_IRQn=true" in ioc

    assert "SPI_CR1_MSTR | SPI_CR1_SSM | SPI_CR1_SSI" in adapter
    assert "SPI_CR2_FRXTH" in adapter
    assert "GPIO_AF5_SPI1" in adapter
    assert "FPGA_RX_SPI_TARGET_HZ 1000000UL" in adapter
    assert "fpga_rx_spi_stm32_init(" in main_source
    assert "fpga_rx_spi_drop_frame(&fpga_rx)" in main_source
    assert "fpga_rx_spi_pop_frame(&fpga_rx)" in main_source
    assert "UART_ADVFEATURE_SWAP_ENABLE" in main_source
    assert "rs485_half_duplex_init(&rs485a" in main_source
    assert "HAL_UART_Receive_IT(&huart1, &rs485a_irq_byte, 1U)" in main_source
    assert "Rs485A_Service();" in main_source
    assert 'strcmp(line, "PING")' in main_source
    assert 'strcmp(line, "STATUS")' in main_source
    assert 'strcmp(line, "READ")' in main_source
    assert "#define RS485A_RX_Pin GPIO_PIN_4" in main_header
    assert "#define RS485A_TX_Pin GPIO_PIN_5" in main_header
    assert "GPIO_PIN_SET" in rs485
    assert "HAL_UART_Transmit" in rs485
    assert rs485.count("GPIO_PIN_RESET") >= 2
    assert "void USART1_IRQHandler(void)" in irq
    assert "HAL_UART_IRQHandler(&huart1);" in irq

    assert 150_000_000 // 128 == 1_171_875
    assert 1_171_875 <= 2_500_000
    print("PASS: SPI1 RX service and RS485A half-duplex direction control are integrated")


if __name__ == "__main__":
    main()
