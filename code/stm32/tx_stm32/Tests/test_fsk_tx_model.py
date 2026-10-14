#!/usr/bin/env python3
"""Protocol and timing checks for the STM32 2FSK test transmitter."""

from __future__ import annotations

import math
import re
from datetime import datetime, timezone
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
HEADER = ROOT / "Core" / "Inc" / "fsk_tx.h"
SOURCE = ROOT / "Core" / "Src" / "fsk_tx.c"
MAIN = ROOT / "Core" / "Src" / "main.c"
MSP = ROOT / "Core" / "Src" / "stm32g4xx_hal_msp.c"
IRQ = ROOT / "Core" / "Src" / "stm32g4xx_it.c"
RS485 = ROOT / "Core" / "Src" / "rs485_half_duplex.c"
IOC = ROOT / "tx_stm32.ioc"


def crc8_atm(data: bytes) -> int:
    crc = 0
    for value in data:
        crc ^= value
        for _ in range(8):
            crc = ((crc << 1) ^ 0x07) & 0xFF if crc & 0x80 else (crc << 1) & 0xFF
    return crc


def crc16_ccitt_false(data: bytes) -> int:
    crc = 0xFFFF
    for value in data:
        crc ^= value << 8
        for _ in range(8):
            crc = ((crc << 1) ^ 0x1021) & 0xFFFF if crc & 0x8000 else (crc << 1) & 0xFFFF
    return crc


def main() -> None:
    assert 48_000 // 100 == 480
    assert 48_000 * 3 // 80 == 1_800
    assert 48_000 * 3 % 80 == 0
    assert 150_000_000 // ((4 + 1) * (624 + 1)) == 48_000

    # Check the actual compiled LUTs against independent sinusoidal references.
    tables = (ROOT / "Core/Inc/fsk_tone_tables.h").read_text()
    for bit, frequency in enumerate((1700, 1900)):
        body = re.search(r"s_sine_bit" + str(bit) + r"\[.*?\] = \{(.*?)\};",
                         tables, re.S)[1]
        samples = [int(value) for value in re.findall(r"-?\d+", body)]
        assert len(samples) == 480
        assert frequency * len(samples) % 48_000 == 0
        for i, sample in enumerate(samples):
            expected = 32767 * math.sin(2 * math.pi * frequency * i / 48_000)
            assert abs(sample - expected) <= 0.501
        assert samples[0] == 0
        for other in (1700, 1900):
            energy = abs(sum(sample * complex(math.cos(2*math.pi*other*i/48000),
                                               math.sin(2*math.pi*other*i/48000))
                             for i, sample in enumerate(samples)))
            assert energy > 7_000_000 if other == frequency else energy < 100

    sweep_frequencies = list(range(1_500, 2_101, 20))
    assert len(sweep_frequencies) == 31
    for frequency in sweep_frequencies:
        phase_increment = round(frequency * (1 << 32) / 48_000)
        actual_frequency = phase_increment * 48_000 / (1 << 32)
        assert abs(actual_frequency - frequency) < 0.001
        assert frequency * 0.1 == int(frequency * 0.1)

    assert crc8_atm(b"123456789") == 0xF4
    assert crc16_ccitt_false(b"123456789") == 0x29B1

    header = bytes((0x10, 0x00, 0x00))
    header_with_crc = header + bytes((crc8_atm(header),))
    assert len(header_with_crc) == 4
    assert crc16_ccitt_false(header_with_crc) == 0x0ACF

    payload = bytes(range(16))
    header = bytes((0x10, 0x35, len(payload)))
    header_with_crc = header + bytes((crc8_atm(header),))
    assert header_with_crc == bytes.fromhex("10 35 10 6A")
    frame_crc = crc16_ccitt_false(header_with_crc + payload)
    assert frame_crc == 0x1A1C
    air_frame = bytes.fromhex("AA AA 06 B7") + header_with_crc + payload + frame_crc.to_bytes(2, "big")
    assert air_frame.hex(" ").upper().endswith("0E 0F 1A 1C")

    # V2 keeps the four-byte header and inserts a type-specific timestamp
    # before application payload. All multibyte values are big-endian.
    base_time_s = int(datetime(2026, 9, 3, 20, 30, 0,
                               tzinfo=timezone.utc).timestamp())
    time_base_header = bytes((0x21, 0x00, 0x00))
    time_base_header += bytes((crc8_atm(time_base_header),))
    time_base_body = time_base_header + base_time_s.to_bytes(4, "big")
    time_base_body += crc16_ccitt_false(time_base_body).to_bytes(2, "big")
    assert time_base_body[4:8] == bytes.fromhex("6A 99 D8 C8")

    elapsed_ms = 86_399_999
    elapsed_10ms = elapsed_ms // 10
    assert elapsed_10ms == 8_639_999
    data_header = bytes((0x20, 0x35, len(payload)))
    data_header += bytes((crc8_atm(data_header),))
    data_body = data_header + elapsed_10ms.to_bytes(3, "big") + payload
    data_body += crc16_ccitt_false(data_body).to_bytes(2, "big")
    assert data_body[4:7] == bytes.fromhex("83 D5 FF")
    assert (86_400_000 // 10) < (1 << 24)

    header_text = HEADER.read_text(encoding="ascii")
    source_text = SOURCE.read_text(encoding="ascii")
    main_text = MAIN.read_text(encoding="ascii")
    msp_text = MSP.read_text(encoding="ascii")
    irq_text = IRQ.read_text(encoding="ascii")
    rs485_text = RS485.read_text(encoding="ascii")
    ioc_text = IOC.read_text(encoding="ascii")
    assert "#define FSK_TX_SYNC_WORD               0x06B7U" in header_text
    assert "#define FSK_TX_SYNC_WORD_IS_FROZEN     1U" in header_text
    assert "FSK_TX_ERROR_SYNC_WORD_UNAVAILABLE" in source_text
    assert "DMA_CIRCULAR" in source_text
    assert "FSK_TX_DMA_HALF_SAMPLES" in source_text
    assert "DMA_PDATAALIGN_WORD" in source_text
    assert '" dmaerr="' in source_text
    assert "HAL_DMA_GetError" in source_text
    assert "HAL_DAC_GetError" in source_text
    assert "(uint8_t)(crc16 >> 8U);" in source_text
    assert "(uint8_t)crc16;" in source_text
    assert "#define FSK_TX_PROTOCOL_VERSION_TIME   2U" in header_text
    assert "#define FSK_TX_FRAME_TYPE_TIME_BASE    1U" in header_text
    assert "FskTx_WriteBe24" in source_text
    assert "FskTx_WriteBe32" in source_text
    assert "(now_ms - s_tx.base_tick_ms) /" in source_text
    assert 'FskTx_TokenEquals(line, "SET_TIME")' in source_text
    assert 'FskTx_TokenEquals(line, "TIME_BASE")' in source_text
    assert 'FskTx_TokenEquals(line, "SWEEP")' in source_text
    assert 'FskTx_TokenEquals(sweep_command, "TONE")' in source_text
    assert 'FskTx_ArgumentEquals(sweep_command, "OFF")' in source_text
    assert "FSK_TX_MODE_SWEEP_TONE" in source_text
    assert "FSK_TX_MODULATION_OOK" in header_text
    assert "FSK_TX_OOK_LUT_SAMPLES          80U" in header_text
    assert "FSK_TX_OOK_LUT_CYCLES           3U" in header_text
    assert "s_sine_1800_80" in source_text
    assert "FskTx_CommandModulation" in source_text
    assert "FskTx_ArgumentEquals(argument, \"CARRIER\")" in source_text
    assert "FSK_TX_MODE_ALTERNATING_01" in source_text
    assert "FSK_TX_MODE_PRBS" in source_text
    assert "ERR busy" in source_text
    assert "mod=\"" in source_text
    assert "s_tx.sweep_phase_accumulator += s_tx.sweep_phase_increment" in source_text
    assert '" time_valid="' in source_text
    assert "htim4.Init.Prescaler = 4;" in main_text
    assert "htim4.Init.Period = 624;" in main_text
    assert "UART_ADVFEATURE_SWAP_ENABLE" in main_text
    assert "HAL_UART_Receive_IT(&huart1, &fsk_uart_irq_byte, 1U)" in main_text
    assert "FskUart_Service();" in main_text
    assert "rs485_half_duplex_transmit(" in main_text
    assert "2FSK TX ready" not in main_text
    assert "hdma_dac1_ch1.Init.PeriphDataAlignment = DMA_PDATAALIGN_WORD;" in msp_text
    assert "hdma_dac1_ch1.Init.Mode = DMA_CIRCULAR;" in msp_text
    assert "HAL_NVIC_EnableIRQ(USART1_IRQn);" in msp_text
    assert "void USART1_IRQHandler(void)" in irq_text
    assert "HAL_UART_IRQHandler(&huart1);" in irq_text
    assert "GPIO_PIN_SET" in rs485_text
    assert rs485_text.count("GPIO_PIN_RESET") >= 2
    assert "Dma.DAC1_CH1.0.PeriphDataAlignment=DMA_PDATAALIGN_WORD" in ioc_text
    assert "Dma.DAC1_CH1.0.Mode=DMA_CIRCULAR" in ioc_text
    assert "PA7.GPIO_Label=RS485A_EN" in ioc_text
    assert "PC4.GPIO_Label=RS485A_RX" in ioc_text
    assert "PC5.GPIO_Label=RS485A_TX" in ioc_text
    assert "USART1.SwapParam-Asynchronous=ADVFEATURE_SWAP_ENABLE" in ioc_text

    maximum_symbols = 16 + 16 + 32 + 64 * 8 + 16
    assert maximum_symbols == 592
    assert maximum_symbols / 100 == 5.92
    print("PASS: FSK/OOK waveform, protocol and RS485A half-duplex control are integrated")


if __name__ == "__main__":
    main()
