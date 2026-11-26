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
    assert "PC4.GPIO_PuPd=GPIO_PULLUP" in ioc
    assert "PC5.GPIO_PuPd=GPIO_PULLUP" in ioc
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
    assert "Rs485A_EnsureReceive();" in main_source
    assert "rs485a_tx_error_count" in main_source
    assert "fpga_rx_next_service_ms" in main_source
    assert "FPGA polling is background work" in main_source
    assert "Rs485A_Service();" in main_source
    assert 'strcmp(line, "PING")' in main_source
    assert 'strcmp(line, "STATUS")' in main_source
    assert 'strcmp(line, "READ")' in main_source
    assert 'strcmp(line, "MOD FSK")' in main_source
    assert 'strcmp(line, "MOD OOK")' in main_source
    assert 'strncmp(line, "ASK THRESH ", 11U)' in main_source
    assert 'strcmp(line, "ASK STATUS")' in main_source
    assert 'strncmp(line, "FSK THRESH ", 11U)' in main_source
    assert 'strcmp(line, "FSK STATUS")' in main_source
    assert 'fpga_rx_spi_fsk_apply_config(&fpga_rx, &config, &status)' in main_source
    assert 'strncmp(line, "FSK THRESH ", 11U)' in main_source
    assert 'strcmp(line, "FSK STATUS")' in main_source
    assert 'fpga_rx_spi_fsk_apply_config(&fpga_rx, &config, &status)' in main_source
    assert 'ERR ASK UNSUPPORTED' in main_source
    assert 'ERR MOD UNSUPPORTED' in main_source
    assert 'OK ASK STATUS mode=' in main_source
    assert '" pending="' in main_source
    assert 'rx_command_parse_u32_fields(arguments, fields, 2U)' in main_source
    assert '(fields[0] >= fields[1])' in main_source
    assert 'fpga_rx_spi_ask_apply_config(&fpga_rx, &config, &status)' in main_source
    assert 'ERR ASK BUSY' in main_source
    assert 'if (status.pending != 0U)' in main_source
    assert 'if (status.error != 0U)' in main_source
    assert 'status.active.low_threshold' in main_source
    assert 'status.active.high_threshold' in main_source
    assert 'FPGA_RX_SPI_ASK_MIN_FW_VERSION' in main_source
    assert '(fpga_rx_firmware_version != 0xFFU)' in main_source
    assert 'fpga_rx_spi_ask_clear_error(&fpga_rx)' in main_source
    assert 'FPGA_RX_REG_RX_MODE_SHADOW = 0x65U' in (
        ROOT / "Core" / "Inc" / "fpga_rx_spi.h"
    ).read_text(encoding="ascii")
    assert 'FPGA_RX_REG_CONFIG_GENERATION = 0x7EU' in (
        ROOT / "Core" / "Inc" / "fpga_rx_spi.h"
    ).read_text(encoding="ascii")
    assert 'fpga_rx_spi_ask_read_status' in (
        ROOT / "Core" / "Src" / "fpga_rx_spi.c"
    ).read_text(encoding="ascii")
    command_text = (ROOT / "Core" / "Src" / "rx_command_text.c").read_text(
        encoding="ascii"
    )
    assert 'UINT32_MAX' in command_text
    assert 'value > ((UINT32_MAX - digit) / 10U)' in command_text
    assert 'separator_seen' in command_text
    assert "#define RS485A_RX_Pin GPIO_PIN_4" in main_header
    assert "#define RS485A_TX_Pin GPIO_PIN_5" in main_header
    assert "GPIO_PIN_SET" in rs485
    assert "HAL_UART_Transmit" in rs485
    assert rs485.count("GPIO_PIN_RESET") >= 2
    assert "void USART1_IRQHandler(void)" in irq
    assert "HAL_UART_IRQHandler(&huart1);" in irq
    assert "GPIO_PULLUP" in (
        ROOT / "Core" / "Src" / "stm32g4xx_hal_msp.c"
    ).read_text(encoding="ascii")

    assert 150_000_000 // 128 == 1_171_875
    assert 1_171_875 <= 2_500_000
    print("PASS: SPI1 RX service and RS485A half-duplex direction control are integrated")


if __name__ == "__main__":
    main()
