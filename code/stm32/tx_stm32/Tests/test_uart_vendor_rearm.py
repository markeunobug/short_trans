"""Exercise vendor one-byte RX/rearm functions with actual main.c callbacks.

Extracts unchanged HAL_UART_Receive_IT, UART_Start_Receive_IT and
UART_RxISR_8BIT from this project's vendor HAL. Only registers are host mocks.
The IRQ dispatcher is represented by its error-before-RxISR ordering; FIFO,
DMA UART reception, physical timing and the Cortex-M startup are NOT emulated.
"""
import argparse
import json
from pathlib import Path
import re
import subprocess
import uuid

from test_uart_diagnostics import PREAMBLE, PROJECT, ROOT, section


def function(source, name):
    match = re.search(r"^(?:static )?(?:void|HAL_StatusTypeDef) " + name +
                      r"\([^;]*?\)\s*\{", source, re.M)
    if match is None:
        raise ValueError(name)
    depth, index = 1, match.end()
    while depth:
        depth += (source[index] == "{") - (source[index] == "}")
        index += 1
    return source[match.start():index] + "\n"


UART_TYPES = r'''
typedef struct { uint32_t CR1, CR2, CR3, ISR, RDR; } UART_Registers;
typedef struct UART_HandleTypeDef UART_HandleTypeDef;
struct UART_HandleTypeDef {
    uint32_t ErrorCode, RxState, ReceptionType, FifoMode, NbRxDataToProcess;
    uint32_t RxEventType;
    uint16_t Mask, RxXferSize, RxXferCount;
    uint8_t *pRxBuffPtr;
    void (*RxISR)(UART_HandleTypeDef *);
    UART_Registers *Instance;
    struct { uint32_t WordLength, Parity; } Init;
};
#define HAL_BUSY ((HAL_StatusTypeDef)2)
#define HAL_UART_ERROR_NONE 0U
#define HAL_UART_STATE_READY 0x20U
#define HAL_UART_STATE_BUSY_RX 0x22U
#define HAL_UART_RECEPTION_STANDARD 0U
#define HAL_UART_RECEPTION_TOIDLE 1U
#define HAL_UART_RXEVENT_TC 0U
#define UART_FIFOMODE_ENABLE 1U
#define UART_WORDLENGTH_9B 9U
#define UART_PARITY_NONE 0U
#define USART_CR1_RXNEIE_RXFNEIE (1U << 5)
#define USART_CR1_PEIE (1U << 8)
#define USART_CR1_RTOIE (1U << 26)
#define USART_CR1_IDLEIE (1U << 4)
#define USART_CR2_RTOEN (1U << 23)
#define USART_CR3_EIE 1U
#define USART_CR3_RXFTIE (1U << 28)
#define UART_FLAG_IDLE (1U << 4)
#define UART_CLEAR_IDLEF UART_FLAG_IDLE
#define UART_RXDATA_FLUSH_REQUEST 8U
#define SET 1U
#define READ_REG(reg) (reg)
#define READ_BIT(reg, mask) ((reg) & (mask))
#define ATOMIC_SET_BIT(reg, mask) ((reg) |= (mask))
#define ATOMIC_CLEAR_BIT(reg, mask) ((reg) &= ~(mask))
#define IS_LPUART_INSTANCE(instance) (0)
#define UART_MASK_COMPUTATION(h) ((h)->Mask = 0xFFU)
#define __HAL_UART_GET_FLAG(h, mask) (((h)->Instance->ISR & (mask)) != 0)
#define __HAL_UART_CLEAR_FLAG(h, mask) ((h)->Instance->ISR &= ~(mask))
#define __HAL_UART_SEND_REQ(h, req) ((void)(h), (void)(req))
static void UART_RxISR_8BIT(UART_HandleTypeDef *h);
static void UART_RxISR_16BIT(UART_HandleTypeDef *h) { (void)h; assert(0); }
static void UART_RxISR_8BIT_FIFOEN(UART_HandleTypeDef *h) { (void)h; assert(0); }
static void UART_RxISR_16BIT_FIFOEN(UART_HandleTypeDef *h) { (void)h; assert(0); }
static void HAL_UARTEx_RxEventCallback(UART_HandleTypeDef *h, uint16_t n) { (void)h; (void)n; assert(0); }
HAL_StatusTypeDef UART_Start_Receive_IT(UART_HandleTypeDef *h, uint8_t *p, uint16_t n);
void HAL_UART_RxCpltCallback(UART_HandleTypeDef *h);
'''


CHECKS = r'''
static void irq_byte(uint8_t byte, uint32_t error) {
    /* Same error-before-RxISR order as the vendor HAL_UART_IRQHandler path.
       RXNE is represented by explicitly invoking the armed RxISR. */
    huart1.Instance->RDR = byte;
    huart1.ErrorCode |= error;
    assert(huart1.RxISR != NULL);
    huart1.RxISR(&huart1);
    /* HAL dispatcher samples ErrorCode AFTER RxISR returns. */
    if (huart1.ErrorCode != HAL_UART_ERROR_NONE) HAL_UART_ErrorCallback(&huart1);
    assert(huart1.RxState == HAL_UART_STATE_BUSY_RX && huart1.RxISR != NULL);
    assert(huart1.RxXferCount == 1);
}
static void line(const char *text) {
    while (*text) irq_byte((uint8_t)*text++, 0U);
    irq_byte('\n', 0U); FskUart_Service();
}
int main(void) {
    UART_Registers uart = {0};
    DMA_Channel_TypeDef channel = {0};
    DMA_HandleTypeDef dma = { .Instance=&channel };
    DAC_HandleTypeDef dac = { .Instance=DAC1, .DMA_Handle1=&dma };
    TIM_HandleTypeDef tim = { .Instance=TIM4 };
    (void)fail_rearm;
    huart1.Instance = &uart;
    huart1.RxState = HAL_UART_STATE_READY;
    assert(FskTx_Init(&dac, &tim) == FSK_TX_OK);
    assert(HAL_UART_Receive_IT(&huart1, &fsk_uart_irq_byte, 1) == HAL_OK);
    line("STATUS"); assert(strncmp(wire, "OK run=0 mode=0", 15) == 0);
    unsigned before = fsk_uart_ore_count;
    irq_byte('S', HAL_UART_ERROR_ORE);
    printf("OBSERVED one ORE+RXNE event: before=%u after=%lu aggregate=%lu rearmed=%u\n",
        before, (unsigned long)fsk_uart_ore_count, (unsigned long)fsk_uart_error_count,
        huart1.RxState == HAL_UART_STATE_BUSY_RX);
    fflush(stdout);
    if (fsk_uart_ore_count != before + 1) return 2;
    line("TATUS"); assert(strncmp(wire, "OK run=0 mode=0", 15) == 0);
    for (unsigned i=0; i<4; ++i) {
        uint32_t mask = 1U << i;
        irq_byte('X', mask); FskUart_Service();
        irq_byte('\b', 0); FskUart_Service();
    }
    assert(fsk_uart_ore_count == 2 && fsk_uart_fe_count == 1 &&
           fsk_uart_ne_count == 1 && fsk_uart_pe_count == 1);
    /* A separate error callback without RXNE must still count and rearm. */
    huart1.RxState = HAL_UART_STATE_READY;
    huart1.ErrorCode = HAL_UART_ERROR_ORE;
    HAL_UART_ErrorCallback(&huart1);
    assert(fsk_uart_ore_count == 3 && huart1.ErrorCode == 0);
    assert(fsk_uart_error_count == 6 && fsk_uart_rearm_fail_count == 0);
    line("UART DIAG"); assert(strstr(wire, "ore=3 fe=1 ne=1 pe=1"));
    line("STOP"); assert(strcmp(wire, "OK\r\n") == 0);
    line("STATUS"); assert(strncmp(wire, "OK run=0 mode=0", 15) == 0);
    puts("PASS actual vendor one-byte RX/rearm functions preserve diagnostics and normal STATUS");
    return 0;
}
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=ROOT / "_codex/ber_20261102/tx_status_investigation_20261105")
    args = parser.parse_args()
    out = args.output / ("vendor_uart_" + uuid.uuid4().hex[:8])
    out.mkdir(parents=True)
    source = (PROJECT / "Core/Src/main.c").read_text()
    vendor = (PROJECT / "Drivers/STM32G4xx_HAL_Driver/Src/stm32g4xx_hal_uart.c").read_text()
    preamble = PREAMBLE.replace("typedef struct { uint32_t ErrorCode; } UART_HandleTypeDef;", UART_TYPES)
    preamble = re.sub(r"static HAL_StatusTypeDef HAL_UART_Receive_IT\(.*?\n}",
        "HAL_StatusTypeDef HAL_UART_Receive_IT(UART_HandleTypeDef *, uint8_t *, uint16_t);",
        preamble, flags=re.S)
    functions = "".join(function(vendor, name) for name in
        ("UART_RxISR_8BIT", "UART_Start_Receive_IT", "HAL_UART_Receive_IT"))
    harness = out / "vendor_uart.c"
    harness.write_text(preamble + section(source, "PD") + section(source, "PV") +
        section(source, "0") + section(source, "4") + functions + CHECKS)
    command = ["gcc", "-std=c11", "-Wall", "-Wextra", "-Werror",
        "-I" + str(PROJECT / "Core/Inc"), "-I" + str(PROJECT / "Tests/hal_mock"),
        str(harness), str(PROJECT / "Core/Src/fsk_tx.c"),
        str(PROJECT / "Tests/hal_mock/hal_mock.c"), "-o", str(out / "vendor_uart.exe")]
    with (out / "compile.log").open("w") as log:
        subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, check=True)
    result = subprocess.run([str(out / "vendor_uart.exe")], capture_output=True, text=True)
    (out / "test.log").write_text(result.stdout + result.stderr)
    (out / "result.json").write_text(json.dumps({"returncode": result.returncode,
        "vendor_functions": ["UART_RxISR_8BIT", "UART_Start_Receive_IT", "HAL_UART_Receive_IT"],
        "hardware_timing_emulated": False}, indent=2))
    print(result.stdout + result.stderr, end="")
    print("ARTIFACTS", out)
    return result.returncode


if __name__ == "__main__":
    raise SystemExit(main())
