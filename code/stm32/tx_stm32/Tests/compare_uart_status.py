"""Compare original/current normal UART responses using actual main.c helpers.

Functional comparison only: MMIO, clock startup and real interrupt timing are
not simulated. The diagnostic-before snapshot is verified against its manifest.
"""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import uuid

from test_uart_diagnostics import PREAMBLE, PROJECT, ROOT, section


DRIVER = r'''
void HAL_DAC_ConvCpltCallbackCh1(DAC_HandleTypeDef *h);
static void line(const char *s) {
    const char *original = s;
    while (*s) {
        fsk_uart_irq_byte = (uint8_t)*s++;
        HAL_UART_RxCpltCallback(&huart1); FskUart_Service();
    }
    fsk_uart_irq_byte = '\n';
    HAL_UART_RxCpltCallback(&huart1); FskUart_Service();
    printf("TX %s\nRX %s", original, wire);
}
int main(void) {
    DMA_Channel_TypeDef channel = {0}; DMA_HandleTypeDef dma = { .Instance=&channel };
    DAC_HandleTypeDef dac = { .Instance=DAC1, .DMA_Handle1=&dma };
    TIM_HandleTypeDef tim = { .Instance=TIM4 };
    assert(FskTx_Init(&dac, &tim) == FSK_TX_OK);
    line("STATUS"); line("STOP"); line("MOD FSK"); line("MODE PACKET");
    line("AMP 256"); line("SET_TIME 2026-11-05 15:22:23");
    line("PAYLOAD 000102030405060708090A0B0C0D0E0F101112131415161718191A1B1C1D1E1F");
    line("TIME_BASE"); line("SEND"); line("STATUS");
    for (unsigned i=0; i<600; ++i) {
        HAL_DAC_ConvHalfCpltCallbackCh1(&dac); HAL_DAC_ConvCpltCallbackCh1(&dac);
    }
    line("STATUS"); line("META 2 0 0"); line("SEND"); line("STATUS");
    for (unsigned i=0; i<600; ++i) {
        HAL_DAC_ConvHalfCpltCallbackCh1(&dac); HAL_DAC_ConvCpltCallbackCh1(&dac);
    }
    line("STATUS"); line("STOP"); line("TATUS"); line("STATUS");
    return 0;
}
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=ROOT / "_codex/ber_20261102/tx_status_investigation_20261105")
    args = parser.parse_args()
    out = args.output.resolve() / ("status_compare_" + uuid.uuid4().hex[:8])
    out.mkdir(parents=True)
    snapshot = ROOT / "_codex/ber_20261102/tx_uart_diag_20261105"
    baseline = snapshot / "baseline/code/stm32/tx_stm32"
    hashes = json.loads((snapshot / "baseline_sha256.json").read_text())
    for name in ("Core/Src/main.c", "Core/Src/fsk_tx.c", "Core/Inc/fsk_tx.h"):
        assert hashlib.sha256((baseline / name).read_bytes()).hexdigest() == hashes[
            "code/stm32/tx_stm32/" + name].lower(), name
    outputs = []
    for label, project in (("before", baseline), ("after", PROJECT)):
        source = (project / "Core/Src/main.c").read_text()
        harness = out / (label + ".c")
        harness.write_text(PREAMBLE + section(source, "PD") + section(source, "PV") +
            section(source, "0") + section(source, "4") + DRIVER)
        command = ["gcc", "-std=c11", "-Wall", "-Wextra", "-Werror",
            "-I" + str(project / "Core/Inc"), "-I" + str(PROJECT / "Tests/hal_mock"),
            "-I" + str(PROJECT / "Core/Inc"), str(harness), str(project / "Core/Src/fsk_tx.c"),
            str(PROJECT / "Tests/hal_mock/hal_mock.c"), "-o", str(out / (label + ".exe"))]
        with (out / (label + "_compile.log")).open("w") as log:
            subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, check=True)
        result = subprocess.run([str(out / (label + ".exe"))], capture_output=True, check=True)
        (out / (label + "_serial.txt")).write_bytes(result.stdout)
        outputs.append(result.stdout)
    assert outputs[0] == outputs[1], "Normal UART response changed; inspect before/after_serial.txt"
    summary = {"passed": True, "responses": outputs[0].count(b"\nRX "),
        "sha256": hashlib.sha256(outputs[0]).hexdigest(), "hardware_startup_tested": False}
    (out / "result.json").write_text(json.dumps(summary, indent=2))
    print("PASS byte-exact original/current normal UART responses:", json.dumps(summary))
    print("ARTIFACTS", out)


if __name__ == "__main__":
    main()
