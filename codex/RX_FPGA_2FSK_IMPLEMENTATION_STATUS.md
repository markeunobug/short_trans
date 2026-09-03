# RX FPGA 2FSK 实施状态

日期：2026-07-15  
目标器件：Cyclone 10 LP `10CL025YE144I7G`

## 当前结论

V1.0 数字链路已经从独立任务进入统一工程：ADC 初始化、I2S、CDC、2FSK 解调、符号同步、帧协议、SPI/FIFO、STM32 TX 和 STM32 RX 均已有实现与自动测试。FPGA 已生成最新 SOF，但尚未完成真实 ADC、模拟链路和水下信道验收。

固定空中参数：

- 非相干 2FSK：bit 0 = 1.6 kHz，bit 1 = 2.0 kHz。
- 100 bit/s，MSB first。
- Preamble `0xAAAA` 16 bit，Sync `0x06B7` 16 bit。
- 物理 Payload 0..64 byte，CRC-8/ATM + CRC-16/CCITT-FALSE。

帧时间：`0 byte = 0.80 s`，`16 byte = 2.08 s`，`64 byte = 5.92 s`，另加不少于 100 ms 帧间静默。

## Task 状态

| Task | 状态 | 说明 |
|---:|---|---|
| 0 顶层集成 | RTL完成 | 顶层、QSF、SDC、全编译和时序闭环完成 |
| 1 复位/CDC | 仿真完成 | reset、pulse CDC、async FIFO 全通过 |
| 2 ADC 初始化 | 仿真完成 | 固定 ROM、回读、3 次重试、重初始化；待实芯片确认 |
| 3 I2S/快照 | 仿真完成 | CH1 32-bit I2S、1024 点快照通过 |
| 4 I/Q 相关器 | 仿真完成 | 480 点滑窗、48 点步长、分周期置信度计算通过 |
| 5 载波/符号同步 | 仿真完成 | 10 相位搜索改为 10 拍评估，时序闭环 |
| 6 帧协议 | 仿真完成 | Sync、CRC、0/1/64/65 byte 和错误路径通过 |
| 7 SPI/FIFO | 仿真完成 | Mode0、寄存器、POP/DROP、快照和溢出通过 |
| 8 STM32 TX | 构建完成 | PA4 DAC + TIM4 + DMA；待示波器确认 |
| 9 STM32 RX | 构建完成 | SPI1、分段读取、POP/DROP、快照和解调参数成组读写已接入 |
| 10 系统验收 | 数字阶段完成 | 20-bit sample 到 Payload 真实链路通过；BER/FER 与水下测试待做 |

## 自动验证

FPGA ModelSim：

```powershell
cd code\cyclone10\rx_cyclone10
.\simulation\run_rtl_regression.ps1 -Group all
```

结果：`PASS=18 FAIL=0 SKIP=0`。端到端 nominal 帧统计为 109622 点、2274 个 metric、1 个正确 16-byte Payload 帧。

Quartus 22.1 全编译：

- 0 errors，setup/hold fully constrained。
- 慢速 1200 mV、100 C：`FPGA_CLK setup +10.005 ns`，TNS 0；hold `+0.317 ns`。
- 7570 / 24624 LE（31%）。
- 104960 / 608256 RAM bits（17%）。
- 52 / 132 个 9-bit multiplier elements（39%）。
- 输出：[rx_cyclone10.sof](../code/cyclone10/rx_cyclone10/output_files/rx_cyclone10.sof)。

STM32：

- TX：26 个 C 源文件链接通过，ELF 19148 bytes。
- RX：23 个 C 源文件链接通过，ELF 10856 bytes。

## 下一步上板顺序

1. 下载 SOF，SPI 读取 `DEVICE_ID=0xA7`、`FW_VERSION=0x10`。
2. 确认 ADC I2C 地址 `0x4E`，检查 init done/error 和回读失败项。
3. 示波器确认 MCLK 24.576 MHz、BCLK 3.072 MHz、FSYNC 48 kHz。
4. 触发 1024 点快照，先输入单音，核对字节序、符号和 `SAMPLE_SHIFT=12`。
5. TX 输出固定 1.6 kHz / 2.0 kHz，再测交替码和 16-byte packet。
6. 逻辑分析仪确认 SPI Mode0、约 1.172 MHz，以及 RX_DATA/POP/DROP。
7. 分别联调 0、16、32、64 byte 帧。
8. 扫描幅度、频偏和 SNR，输出 BER/FER 曲线，再冻结能量倍率、噪声底线和置信度门限。

## 尚未完成

- FPGA 发射端与 DAC8830 驱动。
- 1024-byte 逻辑消息分片重组。
- FEC、白化、200/400 bit/s。
- 真实模拟前端、换能器、水池和水下链路验收。
