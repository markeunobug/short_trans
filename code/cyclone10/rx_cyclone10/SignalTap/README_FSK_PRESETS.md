# 2FSK SignalTap 单实例预设

Quartus Prime Lite 22.1 在这个工程中同时启用两个或更多 SignalTap 实例时，会在自动调试 Hub 处报错 265075/265011/12154。工程因此改为四个单实例预设；每次选择一个预设、完整编译并下载对应的新 SOF。

| 预设 | 文件 | 用途 |
|---|---|---|
| samples | FSK_1_SAMPLES_20BIT.stp | 32位FIFO输入、20位解调样本、削顶和ADC链路状态 |
| metrics | FSK_2_DEMOD_METRICS.stp | F0/F1能量、软判决、置信度、噪声和载波门限 |
| symbols | FSK_3_SYMBOLS.stp | bit_valid/bit_value、码元质量、相位和时序调整 |
| frames | FSK_4_FRAME_RESULT.stp | CRC通过结果、负载字节、帧元数据和错误脉冲 |

当前工程已选择 samples，且已使用 Quartus Prime Lite 22.1 完整编译成功。

## 如果 SignalTap 中变量显示红色

红色节点名表示该节点在当前 SignalTap 数据采集硬件中没有有效绑定，通常是综合优化掉了内部网线，或 SignalTap 窗口连接的 SOF 与当前 STP 不匹配；它不是“负数”、也不是 ADC 的符号位。之前报告曾出现 `Partially connected ... missing sources or connections`，因此红色节点的波形不能作为有效数据使用。

本工程已对 samples 预设的20位数据链路和状态节点加入 `keep` 保留属性，并重新完整编译；当前 map 报告不再出现 partially connected 警告。

修复后必须按以下顺序操作：

1. 下载最新 `output_files/rx_cyclone10.sof`。
2. 关闭旧的 SignalTap 采集窗口或重新打开 `FSK_1_SAMPLES_20BIT.stp`，不要继续使用旧 SOF 对应的旧采集日志。
3. 连接同一个 USB-Blaster，确认 JTAG 设备匹配。
4. 点击 Run Analysis；发送2FSK测试信号后再看 `demod_sample_data[19..0]`。

如果重新下载后仍显示红色，先停止采集并重新打开 STP，再核对工程与 STP 的活动文件；不能只更换 STP 而不重新下载 SOF。

## 推荐切换方法

在 PowerShell 中执行：

```powershell
cd C:\learning\short_trans\code\cyclone10\rx_cyclone10
.\SignalTap\use_fsk_preset.ps1 -Preset samples -Compile
.\SignalTap\use_fsk_preset.ps1 -Preset metrics -Compile
.\SignalTap\use_fsk_preset.ps1 -Preset symbols -Compile
.\SignalTap\use_fsk_preset.ps1 -Preset frames -Compile
```

每次只执行其中一条。`-Compile` 会先清理 Quartus 生成文件，再完整编译。编译成功后下载 `output_files/rx_cyclone10.sof`，然后打开刚选择的同名 `.stp` 运行采集。

切换预设但不重新编译时，FPGA 内仍是上一次 SOF 的探针，不能用新预设采集。四份 STP 的波形也不是同一次接收事件，不能按采样序号直接对齐。

## 当前验证状态

- 四个单实例预设均已用 Quartus Prime Lite 22.1 通过 Analysis & Synthesis，0错误。
- samples 预设已完成 Full Compilation，0错误，时序通过，并生成新 SOF。
- metrics、symbols、frames 尚未逐个完成布局布线；切换到它们时仍需执行各自的完整编译。
- FSK_CHAIN_DEBUG.stp 是四实例分析文件，在当前 Lite 22.1 工程中不要将它设为活动文件。

## Symbols 预设的稳定快照

`FSK_3_SYMBOLS.stp` 使用 `signaltap_symbol_valid` 作为触发和存储限定信号。它比解调器原始 `bit_valid` 延迟一个 FPGA_CLK，用于保证以下字段已经锁存稳定：

- bit_value
- symbol_energy
- symbol_confidence
- selected_phase
- timing_adjust
- symbol_locked
- carrier_active
- frame_parser_busy

这些字段由 `signaltap_symbol_debug[50:0]` 的 `noprune` 寄存器提供。2026-09-23 的 Quartus 22.1 完整编译报告确认全部调试位和有效信号均为 connected，且不再出现 `Partially connected` 警告。
