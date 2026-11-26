"""Execute actual main.c command/ring/ISR helpers with host UART/DAC mocks.

Only generated harness and binaries go under _codex. Source snippets are read
at runtime, so tests cannot accidentally exercise a copied parser implementation.
This is functional evidence, not a model of Cortex-M interrupt latency.
"""
import argparse
from pathlib import Path
import subprocess
import uuid

PROJECT = Path(__file__).resolve().parents[1]
ROOT = PROJECT.parents[2]


def section(source, name):
    return source.split(f"/* USER CODE BEGIN {name} */", 1)[1].split(
        f"/* USER CODE END {name} */", 1)[0]


PREAMBLE = r'''
#include "fsk_tx.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>
#include <limits.h>
typedef struct { uint32_t ErrorCode; } UART_HandleTypeDef;
typedef struct { uint8_t unused; } rs485_half_duplex_t;
static char wire[1024];
static unsigned transmissions, clears;
static int fail_rearm, fail_tx;
#define HAL_UART_ERROR_NONE 0U
#define HAL_UART_ERROR_ORE 8U
#define HAL_UART_ERROR_FE 4U
#define HAL_UART_ERROR_NE 2U
#define HAL_UART_ERROR_PE 1U
#define __HAL_UART_CLEAR_OREFLAG(x) ((void)(x), ++clears)
static HAL_StatusTypeDef HAL_UART_Receive_IT(UART_HandleTypeDef *h, uint8_t *p, uint16_t n) {
    (void)h; (void)p; assert(n == 1);
    if (fail_rearm) return HAL_ERROR;
    h->ErrorCode = HAL_UART_ERROR_NONE;
    return HAL_OK;
}
static void HAL_Delay(uint32_t value) { (void)value; }
static HAL_StatusTypeDef rs485_half_duplex_transmit(rs485_half_duplex_t *bus,
    const uint8_t *p, uint16_t n, uint32_t timeout) {
    (void)bus; assert(timeout == 100); assert(n < sizeof wire);
    memcpy(wire, p, n); wire[n] = 0; ++transmissions;
    return fail_tx ? HAL_ERROR : HAL_OK;
}
DAC_HandleTypeDef hdac1;
DMA_HandleTypeDef hdma_dac1_ch1;
TIM_HandleTypeDef htim4;
UART_HandleTypeDef huart1;
void HAL_DAC_ConvHalfCpltCallbackCh1(DAC_HandleTypeDef *h);
'''

CHECKS = r'''
static void feed(uint8_t b) {
    fsk_uart_irq_byte = b;
    HAL_UART_RxCpltCallback(&huart1);
    FskUart_Service();
}
static void line(const char *s) {
    for (; *s; ++s) feed((uint8_t)*s);
    feed('\n');
    assert(wire[strlen(wire)-2] == '\r' && wire[strlen(wire)-1] == '\n');
}
int main(void) {
    DMA_Channel_TypeDef channel = {0};
    DMA_HandleTypeDef dma = { .Instance=&channel };
    DAC_HandleTypeDef dac = { .Instance=DAC1, .DMA_Handle1=&dma };
    TIM_HandleTypeDef tim = { .Instance=TIM4 };
    assert(FskTx_Init(&dac, &tim) == FSK_TX_OK);
    line("UART DIAG");
    assert(strstr(wire, "OK UART DIAG rxerr=0 rxovf=0 lineovf=0 cmderr=0"));
    assert(strstr(wire, "badlen=0 badcap=0 badhex= "));
    assert(strstr(wire, "uartbudget=13021") && strstr(wire, "dwt=0"));
    feed('\r'); feed('\n'); assert(transmissions == 1);
    line("STATUS"); assert(strncmp(wire, "OK run=", 7) == 0);
    line("TATUS"); assert(strcmp(wire, "ERR COMMAND\r\n") == 0);
    assert(fsk_uart_command_error_count == 1);
    line("STOP"); line("UART DIAG");
    assert(strstr(wire, "cmderr=1") && strstr(wire, "badlen=5 badcap=5 badhex=5441545553"));

    /* HAL error flags must be sampled before rearming can clear ErrorCode. */
    huart1.ErrorCode = HAL_UART_ERROR_ORE | HAL_UART_ERROR_NE;
    HAL_UART_ErrorCallback(&huart1);
    assert(fsk_uart_ore_count == 1 && fsk_uart_ne_count == 1 && clears == 1);
    assert(fsk_uart_error_count == 1 && fsk_uart_rearm_fail_count == 0);
    huart1.ErrorCode = HAL_UART_ERROR_FE | HAL_UART_ERROR_PE;
    fail_rearm = 1; HAL_UART_ErrorCallback(&huart1);
    assert(fsk_uart_fe_count == 1 && fsk_uart_pe_count == 1);
    assert(fsk_uart_rearm_fail_count == 1 && fsk_uart_error_count == 2);
    /* A separate, error-free byte with an injected rearm failure. */
    huart1.ErrorCode = HAL_UART_ERROR_NONE;
    feed('X'); assert(fsk_uart_rearm_fail_count == 2 && fsk_uart_error_count == 3);
    fail_rearm = 0; feed('\b'); feed('\n');
    line("UART DIAG"); assert(strstr(wire, "ore=1 fe=1 ne=1 pe=1 rearmfail=2"));

    /* Ring overrun is separate from hardware ORE. */
    fsk_uart_rx_head = 0; fsk_uart_rx_tail = 1;
    HAL_UART_RxCpltCallback(&huart1);
    assert(fsk_uart_overflow_count == 1);
    fsk_uart_rx_head = fsk_uart_rx_tail = 0;
    line("UART DIAG"); assert(strstr(wire, "rxovf=1"));

    for (unsigned i=0;i<200;i++) feed('A');
    feed('\n');
    assert(fsk_uart_line_overflow_count == 1 && fsk_uart_command_error_count == 2);
    line("UART DIAG");
    assert(strstr(wire, "badlen=200 badcap=32 badhex=41414141"));
    for (unsigned i=0;i<200;i++) feed('B');
    for (unsigned i=0;i<159;i++) feed('\b');
    feed('\n');
    line("UART DIAG");
    assert(strstr(wire, "lineovf=2") && strstr(wire, "badlen=200 badcap=0 badhex= "));
    for (unsigned i=0;i<66000;i++) feed('C');
    feed('\n'); line("UART DIAG"); assert(strstr(wire, "badlen=65535 badcap=32"));
    /* Legacy long-line parsing remains unchanged: retained STATUS prefix wins. */
    line("STATUS");
    for (const char *s="STATUS ";*s;s++) feed((uint8_t)*s);
    for (unsigned i=0;i<200;i++) feed('D');
    feed('\n'); assert(strncmp(wire, "OK run=", 7) == 0);

    line("MODE TONE1700"); line("SEND");
    for (unsigned i=0;i<100;i++) {
        HAL_DAC_ConvHalfCpltCallbackCh1(&dac);
        line("STATUS"); assert(strncmp(wire, "OK run=1", 8) == 0);
    }
    line("STOP"); fail_tx=1; line("STATUS"); fail_tx=0;
    line("UART DIAG"); assert(strstr(wire, "txerr=1"));
    /* Worst-width counters/HEX must fit and retain CRLF, without overwriting. */
    fsk_uart_error_count = fsk_uart_overflow_count = UINT32_MAX;
    fsk_uart_ore_count = fsk_uart_fe_count = fsk_uart_ne_count = fsk_uart_pe_count = UINT32_MAX;
    fsk_uart_rearm_fail_count = fsk_uart_tx_error_count = UINT32_MAX;
    fsk_uart_line_overflow_count = fsk_uart_command_error_count = UINT32_MAX;
    line("UART DIAG"); assert(strlen(wire)<512);
    assert(strstr(wire, "txerr=4294967295") && strstr(wire, " dwt=0 hclk=150000000 schema=1 opt=0\r\n"));
    /* Reproduce the observed lost terminator: cleanup STOP joins STATUS.
       Host-side bounded backspace cancellation must not execute a partial SEND. */
    for (const char *s="STATUSSTOP"; *s; ++s) feed((uint8_t)*s);
    feed('\n'); assert(strcmp(wire, "ERR COMMAND\r\n") == 0);
    for (const char *s="SEND"; *s; ++s) feed((uint8_t)*s);
    unsigned before_cancel = transmissions;
    for (unsigned i=0; i<160; ++i) feed('\b');
    feed('\n'); assert(transmissions == before_cancel);
    line("STOP"); assert(strcmp(wire, "OK\r\n") == 0);
    line("STATUS"); assert(strncmp(wire, "OK run=0", 8) == 0);
    puts("PASS actual main.c UART parser/ring/error callbacks, bad-line capture, STOP recovery, bounds, STATUS under render interleaving and partial-SEND cancellation");
    return 0;
}
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=ROOT / "_codex/ber_20261102/tx_uart_diag_20261105")
    args = parser.parse_args()
    build = args.output / ("uart_mock_" + uuid.uuid4().hex[:8])
    build.mkdir(parents=True)
    source = (PROJECT / "Core/Src/main.c").read_text()
    harness = build / "uart_main.c"
    harness.write_text(PREAMBLE + section(source, "PD") + section(source, "PV") +
                       section(source, "0") + section(source, "4") + CHECKS)
    command = ["gcc", "-std=c11", "-Wall", "-Wextra", "-Werror",
               "-I" + str(PROJECT / "Core/Inc"), "-I" + str(PROJECT / "Tests/hal_mock"),
               str(harness), str(PROJECT / "Core/Src/fsk_tx.c"),
               str(PROJECT / "Tests/hal_mock/hal_mock.c"), "-o", str(build / "uart_test.exe")]
    with (build / "compile.log").open("w") as log:
        subprocess.run(command, check=True, stdout=log, stderr=subprocess.STDOUT)
    result = subprocess.run([str(build / "uart_test.exe")], capture_output=True, text=True)
    (build / "test.log").write_text(result.stdout + result.stderr)
    print(result.stdout + result.stderr, end="")
    print("ARTIFACTS", build)
    return result.returncode


if __name__ == "__main__":
    raise SystemExit(main())
