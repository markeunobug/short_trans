# Mode 2 OOK 1800 Hz implementation plan and contract
Date: 2026-09-23. Status: implemented and software/RTL/build checks complete; hardware validation remains.

## Ownership and baseline
Primary agent plans/reviews/integrates. User requested lower-cost code agents: gpt-5.6-luna.
Active projects: code/stm32/{tx_stm32,rx_stm32}, code/cyclone10/rx_cyclone10, flutter.
Existing uncommitted changes must be preserved. Old *_ASK directories are read-only references, not deployment targets.
Do not flash hardware. Keep ADC, I2S, SPI pin transport, CRC/frame format and sweep behavior intact.
Business register extensions are authorized for host-controlled thresholds.

## Air and DSP contract
System Mode 1=2FSK; Mode 2=OOK; Mode 3=existing sweep workflow.
Do not confuse system modes with legacy TX MODE waveform enum (SILENCE/TONE/ALT/PRBS/PACKET).
OOK carrier1800Hz, sample48000Hz, bitrate100bps, 480 samples per bit.
TX exact LUT: 80 samples spanning 3 cycles, bit1 carrier, bit0/silence DAC2048.
Same AAAA/06B7, MSB-first, DATA/TIME_BASE, CRC8/CRC16 as current main project.
RX: dedicated 1800Hz quadrature sliding correlation, squared magnitude after 80-sample integration (no additional energy low-pass filter),
fixed hysteresis thresholds, phase/symbol acquisition, existing frame parser/FIFO.
No noise-adaptive or preamble-adaptive threshold changes. Zero symbols never imply loss of frame.
Threshold defaults are uncalibrated software starting values LOW=400 HIGH=600, in DSP output energy units.
Define and document exact correlator shifts/widths; use saturation rather than overflow.
Use fixed-threshold bit histories to acquire AAAA+06B7 over candidate phases. Replay received sync bits
without duplicating or losing header bits. Preserve parser TIME_BASE state between frames and successful drain.
Defer configuration changes while candidate/frame/drain/sweep active. Reinitialize demod history on apply;
apply must not flush committed FIFO entries or reset saved timebase. Frame watchdog ensures release.

## RX SPI extension (all 32-bit integers little endian)
0x65 RX_MODE_SHADOW RW:1 FSK(default),2 OOK; sweep uses existing commands.
0x66..69 ASK_LOW_SHADOW RW(default400)
0x6A..6D ASK_HIGH_SHADOW RW(default600)
0x6E ASK_CONFIG_CONTROL W:bit0 COMMIT; bit1 clear config error.
COMMIT validates low<high and mode1/2; snapshots all shadow fields into pending transaction.
Reject a second commit while pending; do not overwrite pending. Shadow edits never change pending data.
0x6F ASK_CONFIG_STATUS R:bit0 pending,bit1 invalid/rejected sticky,bit2 rx busy,bit3 sweep active.
0x70..73 ASK_LOW_ACTIVE R
0x74..77 ASK_HIGH_ACTIVE R
0x78..7B ASK_ENERGY R:read0x78 preloads one 32bit sample for coherent low and upper bytes.
An internal bus_read_preload strobe extends spi1_slave/register-bank wiring; external SPI timing,
pins and transaction format are unchanged.
0x7C RX_MODE_ACTIVE R:1/2
0x7D ASK_FLAGS R:bit0 hardbit,bit1 symbol lock,bit2 energy valid/ready.
0x7E CONFIG_GENERATION R:increments on successful apply; use read-before/read-after for coherent config snapshot.
FW_VERSION increments 0x11->0x12. Old addresses/semantics unchanged.
Safe apply when !rx_busy&&!sweep_active, resets inactive/active modulation history for clean restart.
No mode3 register value; SWEEP START temporarily suspends selected receiver and STOP restores it.

## Serial commands (additive)
TX `MOD FSK` / `MOD OOK`: change when stopped/no queued packet else ERR busy.
TX `STATUS` appends mod=FSK/OOK. OOK carrier diagnostic via MODE CARRIER.
RX `MOD FSK` / `MOD OOK`: stage current thresholds with desired mode and commit.
RX `ASK THRESH <low> <high>`: uint32 decimal, low<high; stage desired thresholds with current desired mode and commit.
RX `ASK STATUS`: returns one line:
OK ASK STATUS mode=FSK|OOK low=<active> high=<active> energy=<u32> pending=0|1 error=0|1 generation=<u8> bit=0|1 locked=0|1 ready=0|1
Setter response `OK MOD OOK pending=0|1` or `OK ASK THRESH low=<requested> high=<requested> pending=0|1`.
Never report pending as applied. Reject unsupported old FPGA FW<0x12 with explicit error.
Firmware checks commit success/error; expose active config by readback. No persistence to flash in V1.

## Host UI
Add FSK/OOK choice separately from waveform mode, send MOD to TX and RX with response checks.
Add RX low/high energy fields, apply/readback, active mode/threshold/energy/pending display.
Use low/high directly in V1 to avoid center/half-width conversion ambiguity.
Show firmware errors and partial endpoint configuration; do not claim synchronized mode before both confirm.
Retain sweep workflow and old frame/status parsing. Do not apply mod commands during a sweep run.

## Work packages
A: TX modulation/commands/tests (agent owns TX subtree).
B: FPGA fixed OOK chain/registers/top/QSF/tests (agent owns main FPGA subtree).
C: RX driver/serial commands/tests (agent owns RX subtree).
Primary: Flutter UI, protocol documentation, cross-interface review and joint tests.

## Verification gates
Actual TX C waveform under HAL mock: bit0 midpoint, bit1 1800Hz 80point period, FSK/sweep unchanged.
FPGA directed simulation: thresholds bounds/equality, atomic staging/commit, pending writes/rejection,
1800Hz sample->bits->real parser, long zeros/ones, max payload, CRC recovery, TIME_BASE, phase offsets,
FSK/sweep regression. Meaningful failure cases, not source-token-only checks.
RX mock bus: correct endian/addresses, stale firmware, failed SPI, pending/error and active readback.
Flutter analyzer/tests: command formatting, uint32 limits, readback parsing, pending/partial failure semantics.
Available complete firmware/Quartus builds; distinguish unavailable tool, compile-only, STA and board test.
Record exact outcomes in MODE2_OOK_VALIDATION.md. No hardware-success claims without measured evidence.

## 中文执行摘要
- 主代理负责规划、接口及验收；低成本 Luna 调用遇到服务端限流，实际代码分派给 Terra。
- 在当前主工程增加模式2，保留已有FSK、扫频、时间戳及用户未提交修改。
- OOK固定1.8kHz/100bit/s；门限固定默认值并支持上位机修改，关闭自动门限标定。
- 修改范围包括发送波形、接收FPGA、RX业务SPI寄存器/串口命令、Flutter设置页。
- 提交门限必须完整、原子、空闲时生效；配置切换不能丢弃已接收FIFO内容。
- 子任务并行执行，但使用同一份地址/命令合同；主代理负责读回、错误和时序边界审查。
- 最终报告明确区分模型、主机C测试、RTL仿真、固件构建、Quartus时序和硬件联调。
