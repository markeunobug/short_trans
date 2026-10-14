# 2FSK 1700/1900 Hz 实施方案

日期：2026-09-23

## 目标与范围

- bit 0 = 1700 Hz，bit 1 = 1900 Hz，保留 48 kSPS、100 bit/s、480 点/码元。
- 保留现有帧格式、时间戳、SPI/RS485、OOK 1800 Hz 和扫频功能。
- 本次使用当前工作区源码，保留已有未提交修改；独立构建放入 `_codex/fsk_1700_1900`。

## 执行步骤与验收

1. 核对 TX 频率常量、波形 LUT、RX 480 项参考 ROM/9 位相位计数及上位机命令一致性。
2. 保存构建输入快照及 SHA-256。使用 STM32CubeIDE 的 ARM GCC，按 Cortex-M4/FPU hard-float、板级链接脚本生成 ELF/HEX/BIN；检查向量表与 Flash/RAM 占用。
3. 使用 Quartus 22.1 对当前 RX 顶层、实际器件、管脚、SDC 和 SignalTap 配置完成 Analysis/Synthesis、Fitter、Assembler、TimeQuest；检查 setup/hold/recovery/removal、资源及未约束路径。失败时按报告定位修改，不能仅凭综合通过宣布整板成功。
4. 对快照运行 TX 波形/协议检查和 FPGA 解调、同步、协议、SPI、完整链路回归。新增频点需要重点验证 ±20 Hz 偏移与 CRC 正确恢复。
5. 保存可下载文件、构建报告、源码/产物校验值。先识别板卡和下载器；只有识别明确且通信正常才能执行匹配的下载。
6. 硬件可用时，先小幅度单音/交替码，再进行完整帧与连续帧测试，记录成功次数、CRC 错误和失锁计数。板上测量与仿真结果分别记录，禁止把仿真等同于实测。

## 当前状态

- 上一轮已经完成频点源码修改、TX 模型/C HAL mock、5 项解调/集成仿真及解调模块单独综合。
- 本轮推进正式硬浮点固件、FPGA 整板实现及可复现交付。
- 初始硬件检查：USB-BlasterII 可枚举，但 JTAG 报告 `Unable to read device chain - JTAG chain broken`；COM4/COM6/COM9 可枚举，板卡身份与占用状态待检查。

最终执行结果和未完成项记录在构建目录的 `RESULTS.md`。

## 本轮执行结论

正式硬浮点固件与 RX SOF 已生成；通过 OOK 能量流水线修复使整板 setup 从 -3.970 ns 改善到 +6.574 ns，hold 最小 +0.138 ns。最终 RTL 20/20、±20 Hz 完整帧 2/2 通过。

交付目录：`_codex/fsk_1700_1900/release_20260923_182137/artifacts`。
完整结果：`_codex/fsk_1700_1900/RESULTS.md`。

硬件阶段未完成：JTAG chain broken、SWD No STM32 target found、COM6/COM9 被占用。没有烧录或模拟链路实测。
