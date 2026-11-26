"""Compare every generated DAC code before/after diagnostic instrumentation.

Uses actual C implementations and the same HAL mock, independent build/output
directories. Never claims to compare interrupt timing or physical DAC output.
"""
import argparse
import hashlib
from pathlib import Path
import subprocess
import uuid

PROJECT = Path(__file__).resolve().parents[1]
ROOT = PROJECT.parents[2]

DRIVER = r'''
#include "fsk_tx.h"
#include <assert.h>
#include <stdio.h>
extern const uint32_t *mock_dac_dma_data;
void HAL_DAC_ConvHalfCpltCallbackCh1(DAC_HandleTypeDef *h);
void HAL_DAC_ConvCpltCallbackCh1(DAC_HandleTypeDef *h);
static void cmd(const char *s) {
    char reply[320]; assert(FskTx_HandleUartCommand(s, reply, sizeof reply)==FSK_TX_OK);
}
static void render(DAC_HandleTypeDef *dac, FILE *f, unsigned n) {
    for(unsigned i=0;i<n;i++) {
        HAL_DAC_ConvHalfCpltCallbackCh1(dac);
        HAL_DAC_ConvCpltCallbackCh1(dac);
        assert(fwrite(mock_dac_dma_data, sizeof(uint16_t), FSK_TX_DMA_SAMPLES, f)==FSK_TX_DMA_SAMPLES);
    }
}
int main(int argc,char **argv) {
    DMA_Channel_TypeDef channel={0}; DMA_HandleTypeDef dma={.Instance=&channel};
    DAC_HandleTypeDef dac={.Instance=DAC1,.DMA_Handle1=&dma}; TIM_HandleTypeDef tim={.Instance=TIM4};
    assert(argc==2); FILE *f=fopen(argv[1],"wb"); assert(f);
    assert(FskTx_Init(&dac,&tim)==FSK_TX_OK);
    const char *mods[]={"MOD FSK","MOD OOK"};
    const char *modes[]={"MODE SILENCE","MODE TONE1700","MODE TONE1900","MODE ALT","MODE PRBS","MODE CARRIER"};
    const char *amps[]={"AMP 0","AMP 10","AMP 256","AMP 2047"};
    for(unsigned a=0;a<4;a++) {
        cmd(amps[a]);
        for(unsigned m=0;m<2;m++) {
            cmd("STOP");cmd(mods[m]);
            for(unsigned v=0;v<6;v++) {
                cmd("STOP");cmd(modes[v]);cmd("SEND");render(&dac,f,20);
            }
            cmd("STOP");cmd("MODE PACKET");cmd("SET_TIME 2026-11-05 15:22:23");
            cmd("PAYLOAD 000102030405060708090A0B0C0D0E0F101112131415161718191A1B1C1D1E1F");
            cmd("TIME_BASE");cmd("SEND");render(&dac,f,150);
            cmd("META 2 0 255");cmd("SEND");render(&dac,f,250);cmd("STOP");
        }
        cmd("MOD FSK");cmd("SWEEP TONE 7 1800 256");render(&dac,f,30);cmd("SWEEP OFF");
    }
    assert(fclose(f)==0);return 0;
}
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=ROOT / "_codex/ber_20261102/tx_uart_diag_20261105")
    args = parser.parse_args()
    build = args.output / ("waveform_compare_" + uuid.uuid4().hex[:8]); build.mkdir(parents=True)
    harness = build / "compare.c"; harness.write_text(DRIVER)
    baseline = args.output / "baseline/code/stm32/tx_stm32"
    outputs = []
    for label, source, inc in (("before", baseline / "Core/Src/fsk_tx.c", baseline / "Core/Inc"),
                               ("after", PROJECT / "Core/Src/fsk_tx.c", PROJECT / "Core/Inc")):
        exe = build / (label + ".exe"); data = build / (label + ".dac_u16le")
        subprocess.run(["gcc", "-std=c11", "-Wall", "-Wextra", "-Werror", "-I" + str(PROJECT / "Tests/hal_mock"),
            "-I" + str(inc), "-I" + str(PROJECT / "Core/Inc"), str(harness), str(source),
            str(PROJECT / "Tests/hal_mock/hal_mock.c"), "-o", str(exe)], check=True)
        subprocess.run([str(exe), str(data)], check=True)
        outputs.append(data.read_bytes())
    assert outputs[0] == outputs[1], "Diagnostic instrumentation changed DAC sample stream"
    text = f"PASS byte-exact baseline/new DAC stream: {len(outputs[0]) // 2} samples, SHA256 {hashlib.sha256(outputs[0]).hexdigest()}\n"
    (build / "result.log").write_text(text); print(text, end=""); print("ARTIFACTS", build)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
