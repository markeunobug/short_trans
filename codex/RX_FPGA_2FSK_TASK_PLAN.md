# RX FPGA 2FSK 实施任务书

版本：V1.0  
日期：2026-07-15  
目标平台：Intel Cyclone 10 LP `10CL025YE144I7G`  
工程目录：`code/cyclone10/rx_cyclone10`

## 1. 文档目的

本文档冻结接收端 FPGA 第一版 2FSK 方案，并把工作拆分为可以交给多个子 agent 独立完成的任务。所有实现、仿真和联调必须以本文档为共同接口，不得由单个任务私自修改空中协议、采样格式或跨模块信号含义。

第一阶段使用 STM32G431 的 `PA4/DAC1_OUT1` 产生测试 2FSK。最终发射端将迁移到 FPGA 驱动外部 DAC，但空中频率、bit 映射、帧结构和接收算法保持兼容。

## 2. 第一版范围

### 2.1 本版必须完成

- TLV320ADC6120 固定寄存器初始化和状态回读。
- 48 kSPS、I2S、32 bit slot 的 CH1 采样接收。
- 1.6 kHz / 2.0 kHz、100 bit/s 的非相干 2FSK 解调。
- 自动噪声门限、载波检测、前导码检测和符号同步。
- 0 至 64 byte 可变 Payload 的物理帧解析。
- CRC8 帧头校验和 CRC16 完整帧校验。
- 256 byte 正确帧缓存。
- STM32 主机与 FPGA 从机之间的 SPI1 寄存器和 FIFO 接口。
- 1024 点 CH1 原始采样快照。
- STM32 PA4 DAC 测试发射端。
- 模块级、链路级仿真和 Quartus 编译时序检查。

### 2.2 本版明确不完成

- FPGA 发射端和 DAC8830 驱动。
- 1024 byte 逻辑消息的分片与重组。
- 前向纠错 FEC。
- Payload 白化。
- CH1/CH2 平均或双通道投票。
- 运行时切换 100/200/400 bit/s。
- SPI3 通信。

## 3. 已冻结的系统参数

### 3.1 空中物理层

| 参数 | 固定值 |
|---|---:|
| 调制方式 | 非相干 2FSK |
| bit 0 | 1.6 kHz |
| bit 1 | 2.0 kHz |
| bit 率 | 100 bit/s |
| 符号周期 | 10 ms |
| bit 顺序 | MSB first |
| 帧间静默 | 不少于 100 ms |
| 单帧最大 Payload | 64 byte |

100 bit/s 时，每个符号持续 10 ms。以 48 kSPS 采样时，每符号包含 480 点，1.6 kHz 和 2.0 kHz 分别包含 16 和 20 个完整周期。

解调模块允许通过 Verilog 参数为后续 200/400 bit/s 扩展，但 V1.0 只允许编译和验收 100 bit/s 配置。

### 3.2 ADC 和时钟

| 参数 | 固定值 |
|---|---:|
| ADC | TLV320ADC6120 |
| I2C 7 bit 地址 | `0x4E` |
| ADC MCLK | 24.576 MHz |
| ADC ASI 角色 | 主机 |
| 输出采样率 | 48 kSPS |
| 音频格式 | I2S |
| slot 宽度 | 32 bit |
| BCLK/FSYNC | 64 |
| BCLK | 3.072 MHz |
| 启用通道 | 仅 CH1 |
| PGA | 0 dB |
| DRE | 关闭 |
| 数字高通 | 保留约 12 Hz 默认高通 |

ADC 初始化参数固定在 FPGA ROM 中，STM32 不下发 ADC 寄存器配置。SPI 控制寄存器只需提供“重新执行固定初始化”的能力。

### 3.3 FPGA 时钟域

| 时钟域 | 来源 | 用途 |
|---|---|---|
| `clk_sys` | `FPGA_CLK`, 30 MHz | 解调、协议、寄存器和控制主域 |
| `clk_mclk` | `ACLK_FPGA`, 24.576 MHz | ADC MCLK 监测和后续扩展 |
| `clk_i2s` | `ADC_BCLK`, 3.072 MHz | I2S 串行采样接收 |
| `clk_spi` | `SPI1_SCK`, 约 1 MHz | SPI 串行移位 |

所有跨域数据必须通过明确的同步器、握手或异步 FIFO。禁止直接在另一个时钟域采样多 bit 总线。

## 4. 顶层数据通路

```text
TLV320ADC6120
    |
    | I2S: FSYNC/BCLK/SDOUT
    v
i2s_rx_ch1
    |
    | 32 bit signed + sample_valid
    v
sample_cdc_fifo
    |
    v
sample_preprocess
    |
    | 20 bit signed
    +---------------------------> adc_snapshot_1024
    |
    v
fsk_iq_correlator
    |
    | metric_valid every 1 ms
    | hard_bit, soft_metric, total_energy, confidence
    v
carrier_symbol_sync
    |
    | bit_valid every 10 ms after lock
    v
fsk_frame_rx
    |
    | only CRC-correct frames
    v
rx_frame_fifo_256
    |
    v
spi1_register_bank <----------> STM32G431
```

## 5. ADC采样模块要求

### 5.1 固定初始化状态机

初始化状态机至少包含：

```text
POWER_WAIT
SOFTWARE_RESET
WAKE_UP
CONFIG_CLOCK
CONFIG_ASI
CONFIG_CH1
POWER_UP
READBACK
RUN
ERROR
```

实现要求：

- 上电后等待器件电源和内部寄存器稳定。
- I2C 使用 1.8 V 开漏输出，只能主动拉低 SDA/SCL。
- 配置 GPIO1 为 24.576 MHz MCLK 输入。
- 配置 ADC 为 ASI 主机、48 kSPS、I2S、32 bit、BCLK/FSYNC=64。
- 只打开模拟输入 CH1 和 CH1 ASI 输出。
- 设置 0 dB PGA、关闭 DRE、保留数字高通。
- 按数据手册要求完成上电顺序和等待时间。
- 回读关键寄存器和状态寄存器。
- 初始化失败最多自动重试 3 次。
- 第 3 次失败后进入锁存 `ERROR`，停止解调数据有效输出。
- SPI 可触发清错并重新执行同一套固定初始化。

寄存器序列必须从本地 `codex/datasheets/TLV320ADC6120.pdf` 推导，并在模块注释或配套文档中记录地址、写入值和依据。

### 5.2 I2S接收

- 在 `ADC_BCLK` 域采集 `ADC_SDOUT`。
- 识别标准 I2S 的 1 bit 延迟。
- 每个 FSYNC 帧包含两个 32 bit slot，只输出 CH1 slot。
- 输出定义为二进制补码有符号 32 bit。
- 每个采样只产生一个周期的 `sample_valid`。
- 检测 FSYNC 周期、BCLK 数量、slot 长度和丢帧异常。
- 通过异步 FIFO 送入 30 MHz 主域。

必须使用仿真已知字，例如 `0x12345678`、`0x80000000`、`0x7FFFFFFF`，证明不存在 1 bit 移位、左右声道混淆或符号扩展错误。

### 5.3 预处理和快照

- 32 bit CH1 采样经过可配置算术右移和饱和，转换为 20 bit signed。
- `SAMPLE_SHIFT` 属于 FPGA 解调参数，不属于 ADC 配置参数。
- 统计正负削顶次数、最小值、最大值和绝对值平均量。
- 1024 点快照保存原始 32 bit CH1 数据。
- 快照由 SPI 触发，采满后置 `snapshot_ready`，读取期间数据保持不变。
- 连续原始采样流不通过 SPI 实时传输。

## 6. 2FSK相关器

### 6.1 数学定义

对最近 480 个采样计算：

```text
I0 = sum(x[n] * cos(2*pi*1600*n/48000))
Q0 = sum(x[n] * sin(2*pi*1600*n/48000))
I1 = sum(x[n] * cos(2*pi*2000*n/48000))
Q1 = sum(x[n] * sin(2*pi*2000*n/48000))

E0 = I0^2 + Q0^2
E1 = I1^2 + Q1^2

hard_bit     = (E1 > E0)
soft_metric  = E1 - E0
total_energy = E1 + E0
confidence   = abs(E1-E0)/(E1+E0)
```

硬件中不要求直接实现除法。置信度门限可改写为交叉相乘比较，SPI 诊断值可使用缩放后的定点数。

### 6.2 固定实现方案

- 输入为 20 bit signed。
- 正弦/余弦系数为 16 bit Q1.15。
- 使用 120 点周期 ROM，同时覆盖 30 点周期的 1.6 kHz 和 24 点周期的 2.0 kHz。
- 四路 I/Q 乘法器并行。
- 保存最近 480 点的四路乘积。
- 每来一个采样执行“累加新乘积、减去 480 点前乘积”。
- 每 48 点，也就是每 1 ms 输出一次检测结果。
- 乘积约 36 bit，运行和累加器至少 45 bit。
- 计算平方前对 I/Q 进行统一舍入和缩放，具体截位由仿真和综合报告确定。
- 内部保留足够位宽，禁止因无说明截位导致能量翻转或溢出。

### 6.3 自适应噪声门限

- 未检测到载波且未锁定时，使用 EWMA 更新 `noise_energy`。
- 载波检测门限采用“噪声底乘倍率加固定底线”。
- 检测到载波后冻结噪声底更新，避免把信号学习成噪声。
- 连续 5 个 1 ms 检测点超过门限后进入前导码搜索。
- 倍率、固定底线和置信度门限允许通过 SPI 调整。
- 默认值必须通过仿真给出，并在水池测试后重新标定。

### 6.4 相关器输出接口

至少输出：

```text
metric_valid
hard_bit
soft_metric
total_energy
confidence
energy_f0
energy_f1
```

`energy_f0/energy_f1` 可只用于 SignalTap 和诊断寄存器，不要求逐点上传 STM32。

## 7. 载波检测与符号同步

### 7.1 前导码

- 前导码长度固定为 16 bit。
- 使用交替序列，默认定义为 `16'hAAAA`，MSB first。
- 允许最多 2 bit 错误，即至少 14/16 匹配。
- 除匹配数量外，还必须检查平均置信度和总能量。

### 7.2 10相位搜索

- 相关器每 1 ms 输出一次检测结果。
- 一个 10 ms 符号对应 10 个候选相位。
- 每个候选相位按 10 ms 间隔采样自己的 bit 序列。
- 对 10 个相位分别计算交替前导码匹配分数和平均置信度。
- 选择满足门限且得分最高的相位作为符号边界。
- 多个相位同分时选择平均置信度最高者。

### 7.3 帧内跟踪

- 锁定后每 10 ms 输出一个 `bit_valid`。
- 仅在相邻 bit 发生跳变时进行早迟校正。
- 比较计划采样点前后各 1 ms 的置信度，必要时调整下一个符号边界 1 ms。
- 单次只允许调整 1 ms，禁止跳跃多个相位。
- 连续 3 个符号总能量低于门限时立即失锁并放弃当前帧。
- 完成一帧或发生任何解析超时后返回载波搜索状态。

## 8. 空中帧协议

### 8.1 帧格式

```text
+----------------+---------------+---------------+----------------+---------------+
| Preamble 16bit | Sync Word 16b | Header 4 byte | Payload 0..64B | CRC16 2 byte  |
+----------------+---------------+---------------+----------------+---------------+
```

| 字段 | 长度 | 定义 |
|---|---:|---|
| Preamble | 16 bit | `0xAAAA`, MSB first |
| Sync Word | 16 bit | 由同步字搜索任务生成并冻结 |
| Header Byte0 | 1 byte | `[7:4] version`, `[3:0] frame_type` |
| Header Byte1 | 1 byte | `sequence` |
| Header Byte2 | 1 byte | `payload_length`, 0 至 64 |
| Header Byte3 | 1 byte | Header Byte0 至 Byte2 的 CRC8 |
| Payload | 0 至 64 byte | 应用数据 |
| CRC16 | 2 byte | Header Byte0 至 Byte3 加 Payload 的 CRC16 |

### 8.2 CRC参数

CRC8：

```text
名称：CRC-8/ATM
poly：0x07
init：0x00
refin/refout：false
xorout：0x00
```

CRC16：

```text
名称：CRC-16/CCITT-FALSE
poly：0x1021
init：0xFFFF
refin/refout：false
xorout：0x0000
发送顺序：高字节先发送
```

前导码和同步字不参与 CRC。CRC16 覆盖完整 4 byte 帧头和 Payload，包括 Header CRC8 字节。

### 8.3 同步字选择

不得直接人工指定最终同步字。`tools/find_sync_word.py` 必须遍历候选并根据以下指标排序：

- 与 `0xAAAA`、`0x5555` 的汉明距离。
- 非零循环移位时的自相关旁瓣。
- 与自身前后拼接后的滑动误匹配概率。
- 允许 1 bit 错误时的候选冲突数量。
- 0/1 数量平衡。

脚本输出候选排名和理由，项目负责人选择第一名或有记录地选择其他候选。TX、RX和测试向量必须引用同一个共享常量。

### 8.4 错误处理

- Header CRC8 失败：立即放弃本帧。
- Payload 长度大于 64：立即放弃本帧。
- 接收超时：立即放弃本帧。
- CRC16 失败：不写入正常 RX FIFO，只增加错误计数并保存诊断。
- 正确帧：写入描述符和 Payload FIFO，并增加 `good_frame_count`。
- V1.0 不做 FEC、不做白化、不做 1024 byte 重组。

## 9. STM32-FPGA SPI1接口

### 9.1 固定电气参数

| 参数 | 固定值 |
|---|---|
| 主机 | STM32G431 |
| 从机 | Cyclone 10 LP FPGA |
| 模式 | SPI Mode 0 |
| 字长 | 8 bit |
| bit 顺序 | MSB first |
| 第一版速率 | 约 1 MHz |
| 片选 | 低有效 |

`SPI1_NSS` 为高时，FPGA 的 `SPI1_MISO` 必须为高阻。SPI3 保持未实现和高阻。

### 9.2 事务格式

第一个字节定义为：

```text
bit7    : 1=read, 0=write
bit6..0 : 7 bit register address
```

- 读事务在命令字节之后返回数据。
- 写事务在命令字节之后接收数据。
- 普通寄存器支持地址自动递增。
- `RX_DATA` 和 `SNAPSHOT_DATA` 是特殊数据端口，不按普通寄存器递增处理。
- SPI移位域与30 MHz寄存器域之间必须使用CDC握手或异步FIFO。

### 9.3 建议寄存器映射

寄存器地址在实现任务开始前可做一次排版调整，但功能和软件可见行为不得删除。

| 地址 | 名称 | 权限 | 内容 |
|---:|---|---|---|
| `0x00` | `DEVICE_ID` | R | 固定设备标识 |
| `0x01` | `FW_VERSION` | R | FPGA协议版本 |
| `0x02` | `STATUS0` | R | ADC完成/错误、载波、锁定、帧可读、快照完成 |
| `0x03` | `ERROR_FLAGS` | R | I2C、I2S、CDC、FIFO和协议错误 |
| `0x04` | `FRAME_COUNT` | R | 待读取正确帧数量 |
| `0x05` | `HEAD_VERSION_TYPE` | R | 队首帧Header Byte0 |
| `0x06` | `HEAD_SEQUENCE` | R | 队首帧Header Byte1 |
| `0x07` | `HEAD_LENGTH` | R | 队首帧Payload长度 |
| `0x08` | `RX_FIFO_LEVEL_L` | R | Payload FIFO字节数低8位 |
| `0x09` | `RX_FIFO_LEVEL_H` | R | Payload FIFO字节数高位 |
| `0x0A` | `GOOD_COUNT_L` | R | 正确帧计数低字节 |
| `0x0B` | `GOOD_COUNT_H` | R | 正确帧计数高字节 |
| `0x0C` | `CRC_ERROR_L` | R | CRC错误计数低字节 |
| `0x0D` | `CRC_ERROR_H` | R | CRC错误计数高字节 |
| `0x10` | `CONTROL` | W | 清错、ADC重新初始化、开始快照、丢弃队首帧 |
| `0x11` | `SAMPLE_SHIFT` | R/W | 32 bit到20 bit预处理右移量 |
| `0x12` | `ENERGY_MARGIN` | R/W | 自适应门限倍率/偏置参数 |
| `0x13` | `CONF_THRESHOLD` | R/W | 置信度门限 |
| `0x20` | `LAST_SOFT_L` | R | 最近软判决缩放值 |
| `0x21` | `LAST_SOFT_H` | R | 最近软判决缩放值 |
| `0x22` | `LAST_ENERGY_0` | R | 最近1.6 kHz能量压缩值 |
| `0x23` | `LAST_ENERGY_1` | R | 最近2.0 kHz能量压缩值 |
| `0x24` | `LAST_CONFIDENCE` | R | 最近置信度 |
| `0x30` | `SNAPSHOT_COUNT_L` | R | 快照剩余点数低字节 |
| `0x31` | `SNAPSHOT_COUNT_H` | R | 快照剩余点数高字节 |
| `0x40` | `RX_DATA` | R | 队首帧Payload数据端口 |
| `0x41` | `SNAPSHOT_DATA` | R | 1024点原始采样字节流 |

### 9.4 帧读取语义

- FPGA使用256 byte Payload FIFO和独立帧描述符FIFO。
- STM32先读取 `FRAME_COUNT` 和队首帧元数据。
- STM32从 `RX_DATA` 读取 `HEAD_LENGTH` 个字节。
- 读取可分多次SPI事务继续进行。
- 读满Payload后，STM32通过 `CONTROL.POP_FRAME` 提交并弹出队首描述符。
- 如STM32决定放弃，`CONTROL.DROP_FRAME` 丢弃该帧剩余Payload并弹出描述符。
- Payload长度为0时，STM32读取元数据后直接执行 `POP_FRAME`。
- FIFO溢出时不得覆盖尚未读取的旧帧，应丢弃新帧并置错误标志。

## 10. STM32 PA4 DAC测试发射端

目标工程：`code/stm32/tx_stm32`

### 10.1 固定参数

| 参数 | 固定值 |
|---|---:|
| 输出引脚 | `PA4/DAC1_OUT1` |
| DAC采样率 | 48 kSPS |
| TIM4示例分频 | PSC=4, ARR=624，基于150 MHz定时器时钟 |
| 静默值 | 12 bit DAC中点 `2048` |
| 半缓冲长度 | 480 sample |
| DMA模式 | circular，两个480点半缓冲 |

必须从实际时钟树重新计算并验证48 kHz，不允许只复制示例PSC/ARR而不检查当前工程时钟。

### 10.2 波形调度

- DMA half/full callback 每10 ms准备下一个符号缓冲。
- 1.6 kHz使用30点周期表，2.0 kHz使用24点周期表。
- 每个480点符号包含整数个周期，符号切换不得产生相位和幅值突跳。
- 发射幅度通过UART命令配置，默认从低幅度开始。
- 帧前后输出DAC中点，并保证不少于100 ms帧间静默。
- 支持0至64 byte可变Payload。

### 10.3 测试模式

至少支持：

```text
TONE_1600
TONE_2000
ALTERNATING_01
PRBS
PACKET
SILENCE
```

UART命令格式可以由STM32任务单独定义，但必须能够设置幅度、Payload、发送模式和单次发送触发。

## 11. 推荐RTL文件结构

```text
code/cyclone10/rx_cyclone10/
  rx_cyclone10.v
  rx_cyclone10.qsf
  rx_cyclone10.sdc
  rtl/
    common/
      reset_sync.v
      cdc_pulse.v
      async_fifo.v
    adc/
      i2c_master.v
      tlv320_init_rom.v
      tlv320_init_ctrl.v
      i2s_rx_ch1.v
      adc_snapshot.v
    demod/
      fsk_tone_rom.v
      fsk_iq_correlator.v
      fsk_noise_tracker.v
    sync/
      fsk_symbol_sync.v
    protocol/
      crc8_atm.v
      crc16_ccitt.v
      fsk_frame_rx.v
    spi/
      spi1_slave.v
      rx_frame_fifo.v
      spi_register_bank.v
  tb/
  tools/
    find_sync_word.py
    gen_fsk_vectors.py
```

RTL使用Verilog-2001 `.v`。测试平台可使用SystemVerilog `.sv`。禁止把所有功能继续堆入顶层 `rx_cyclone10.v`。

## 12. 子agent任务拆分

### Task 0：接口守护与集成负责人

所有权：

- `rx_cyclone10.v`
- `rx_cyclone10.qsf`
- `rx_cyclone10.sdc`
- 共享接口定义和最终集成

交付：

- 建立目录和模块骨架。
- 冻结模块端口、位宽、时钟域和复位极性。
- 合并其他任务产物。
- 添加ADC BCLK、SPI SCK和CDC时序约束。
- 完成Quartus全量编译和时序报告。

限制：集成负责人不得在顶层重新实现子模块内部算法。

### Task 1：时钟、复位和CDC基础模块

所有权：`rtl/common/*`

交付：

- 各时钟域同步复位。
- 单bit同步、脉冲握手和异步FIFO。
- 独立testbench验证亚稳态防护结构和FIFO满空行为。

依赖：无。最先完成。

### Task 2：TLV320ADC6120固定初始化

所有权：

- `rtl/adc/i2c_master.v`
- `rtl/adc/tlv320_init_rom.v`
- `rtl/adc/tlv320_init_ctrl.v`

交付：

- 符合开漏规则的I2C主机。
- 固定ADC初始化ROM。
- 寄存器回读和3次重试。
- 完整I2C从机模型testbench。
- 一份寄存器配置表和数据手册依据。

依赖：Task 1。

### Task 3：I2S接收和原始采样快照

所有权：

- `rtl/adc/i2s_rx_ch1.v`
- `rtl/adc/adc_snapshot.v`

交付：

- 32 bit I2S CH1接收。
- I2S到30 MHz域的CDC连接接口。
- I2S格式异常检测。
- 1024点快照缓存。
- 已知采样字和FSYNC异常testbench。

依赖：Task 1。可与Task 2并行。

### Task 4：双频I/Q相关器

所有权：`rtl/demod/*`

交付：

- 120点Q1.15参考ROM。
- 四路并行乘法。
- 480点滑动积分和48点输出步长。
- E0/E1、硬判决、软判决、总能量和置信度。
- 自适应噪声跟踪和门限比较。
- 位宽说明、溢出分析和资源报告。

依赖：Task 1。算法testbench不依赖真实ADC，可较早并行开发。

### Task 5：载波检测和符号同步

所有权：`rtl/sync/fsk_symbol_sync.v`

交付：

- 连续5 ms载波检测。
- 10相位前导码搜索。
- 14/16前导码匹配。
- 帧内跳变早迟校正。
- 连续3符号低能量失锁。
- 随机起点、前导码bit错误和时钟偏差testbench。

依赖：Task 4输出接口冻结。

### Task 6：同步字、CRC和帧解析

所有权：

- `rtl/protocol/*`
- `tools/find_sync_word.py`

交付：

- 同步字搜索脚本和选择报告。
- CRC8/CRC16模块及标准测试向量。
- 16 bit同步字允许1 bit错误匹配。
- 0至64 byte可变Payload帧解析。
- 正确帧、Header CRC错误、长度错误、CRC16错误和超时testbench。

依赖：Task 5的`bit_valid/bit_value`接口。

### Task 7：SPI1从机、寄存器和帧FIFO

所有权：`rtl/spi/*`

交付：

- Mode 0、MSB first SPI从机。
- 寄存器映射、256 byte Payload FIFO和描述符FIFO。
- 原子化队首帧读取、POP和DROP行为。
- MISO未选中高阻。
- SPI CDC、FIFO溢出和分段读取testbench。

依赖：Task 1；可先按本文接口使用模拟帧开发，后接Task 6。

### Task 8：STM32 PA4 DAC测试发射端

所有权：

- 新建独立 `fsk_tx.c/.h` 和协议模块。
- 仅在CubeMX USER CODE区域调用，不破坏生成代码。

交付：

- 48 kSPS TIM4触发DAC DMA。
- 480点双半缓冲连续符号输出。
- 固定双音、交替码、PRBS和完整帧。
- UART幅度、Payload、模式和发送命令。
- 示波器确认的频率、幅度和10 ms符号边界记录。

依赖：空中协议冻结。可与FPGA任务并行。

### Task 9：STM32 RX SPI驱动

所有权：RX STM32中新建独立 `fpga_rx_spi.c/.h`。

交付：

- SPI1 Mode 0约1 MHz初始化集成建议。
- 状态轮询、帧元数据读取、Payload分段读取和POP/DROP。
- ADC重新初始化、快照触发和快照读取。
- 错误计数和诊断输出。

依赖：Task 7寄存器映射冻结。

### Task 10：链路仿真与系统验收

所有权：`tb/*`、`tools/gen_fsk_vectors.py`和测试报告。

交付：

- 生成可复现的FSK采样和完整帧测试向量。
- 从I2S输入到SPI读出的端到端仿真。
- 噪声和频偏扫描报告。
- Quartus资源、时序、CDC和警告审计。
- SignalTap观测节点清单。

依赖：全部RTL任务。

## 13. 仿真矩阵

至少覆盖：

| 类别 | 测试内容 |
|---|---|
| 理想频点 | 固定1.6 kHz、固定2.0 kHz、交替bit |
| 随机相位 | 每帧随机初始载波相位 |
| 随机起点 | 在任意采样点开始输入帧 |
| 幅度 | 多档幅度，从弱信号到接近满量程 |
| 直流偏置 | 正负偏置和缓慢漂移 |
| 噪声 | 多档AWGN，输出BER/FER曲线而非只测一个SNR |
| 频偏 | 0、±5、±10、±20 Hz |
| 时钟偏差 | TX/RX符号时钟轻微正负偏差 |
| 前导码 | 0、1、2、3 bit错误，确认门限边界 |
| 同步字 | 0、1、2 bit错误，确认门限边界 |
| 长度 | Payload 0、1、16、63、64 byte，以及非法65 byte |
| CRC | Header CRC8错误、Payload错误、CRC16错误 |
| 能量中断 | 帧中连续1、2、3个低能量符号 |
| SPI | 分段读取、暂停后续读、POP、DROP、FIFO满 |
| ADC | I2C NACK、回读错误、3次重试、重新初始化 |

噪声验收不预设未经实测的最低SNR数字。任务必须输出BER/FER随SNR变化的结果，最终门限由台架和水下测试确定。

## 14. 分阶段验收

### 阶段A：数字接口

- ADC I2C初始化成功，关键寄存器回读一致。
- 示波器测得FSYNC约48 kHz、BCLK约3.072 MHz。
- I2S已知数据仿真无bit偏移。
- SPI寄存器读写和MISO高阻正确。

### 阶段B：ADC真实采样

- 1024点快照可由STM32完整读取。
- 固定1.6/2.0 kHz输入可在快照中识别。
- 无削顶、无明显字节错位、直流偏置处于预期范围。

### 阶段C：解调

- 理想1.6/2.0 kHz硬判决100%正确。
- 随机载波相位不影响判决方向。
- ±20 Hz频偏完成扫描并记录性能。
- 自适应门限能区分静默和有效载波。

### 阶段D：同步和协议

- 随机采样起点下能够获取16 bit前导码。
- 前导码2 bit错误仍可进入同步，3 bit错误不应按正常门限通过。
- 同步字1 bit错误可通过，2 bit错误不通过。
- 0至64 byte帧均可正确解析。
- CRC错误帧不进入正常FIFO。

### 阶段E：整机链路

- STM32 PA4发送固定双音，RX正确报告频点。
- STM32发送交替序列，RX成功锁定符号边界。
- STM32发送4、16、32、64 byte数据包，RX经SPI读出一致Payload。
- 连续多帧和STM32延迟读取时，无旧帧被覆盖。
- Quartus全编译无错误，时序通过，所有跨域路径均有约束或CDC说明。

## 15. 资源与实现约束

- 目标器件总存储为608,256 bit，相关乘积缓存预计约69 kbit。
- 1024点32 bit快照约32 kbit。
- 256 byte Payload FIFO约2 kbit，另加描述符和CDC FIFO。
- 四路并行乘法和能量平方必须记录实际DSP资源占用。
- 初步目标为总memory低于200 kbit、总logic低于器件30%，但最终以功能正确和时序通过为第一优先级。
- 不允许用未说明的截位换取资源下降。
- 不允许依赖`initial`完成必须可复位的运行状态；ROM初始化除外。
- 每个时钟域的复位释放必须同步。

## 16. 子agent协作规则

- 每个子agent只修改自己任务中列出的文件。
- 顶层、QSF和SDC只由Task 0修改。
- 每个RTL任务必须同时提交testbench，不能只交模块源码。
- 修改共享端口前必须先更新本文档或接口清单，并由集成负责人确认。
- 不得更改频率、bit率、bit映射、CRC参数和帧格式。
- 不得把尚未完成的接口用常量0假装为成功状态。
- 每个任务交付时必须报告：修改文件、仿真命令、测试结果、已知限制和下一任务依赖。
- 子agent不得删除或覆盖其他任务生成的文件。

## 17. 推荐执行顺序

```text
Task 0 建立接口骨架
    |
    +--> Task 1 时钟/复位/CDC
            |
            +--> Task 2 ADC初始化
            +--> Task 3 I2S/快照
            +--> Task 7 SPI/FIFO骨架
    |
    +--> Task 4 I/Q相关器
            |
            +--> Task 5 符号同步
                    |
                    +--> Task 6 帧协议
                            |
                            +--> Task 7 完整接入

Task 8 STM32 TX 可并行
Task 9 STM32 RX 在SPI映射冻结后开始
Task 10 贯穿单元测试，最后执行端到端验收
```

## 18. 当前已知风险

1. 外部换能器、谐振电容和水下负载的实际Q值尚未冻结，1.6/2.0 kHz的实际幅频差需要扫频验证。
2. 模拟前端总增益较高，必须先从低DAC幅度开始，检查ADC削顶。
3. 16 bit前导码和同步字在真实多径条件下是否足够，需要用FER实测确认。
4. 100 bit/s下64 byte帧约需5.9秒，短控制命令应使用更短Payload。
5. 1024 byte逻辑消息在100 bit/s下需要约82秒纯Payload时间，本版只预留分片帧类型。
6. 自适应门限、置信度门限和早迟校正参数必须保留调试可见性，不能只在RTL中写死且不可观测。
7. ADC初始化的最终寄存器值必须以本地TI数据手册和真实示波器时钟为准。

## 19. 完成定义

只有同时满足以下条件，RX FPGA V1.0 才能标记完成：

- 所有模块均有可重复运行的testbench。
- 端到端仿真能够从I2S FSK采样恢复Payload并通过SPI读出。
- STM32 PA4真实发送的短帧可由接收板正确解调。
- 0至64 byte可变Payload通过实机测试。
- 错误帧不会进入正常应用FIFO。
- ADC快照和解调诊断可由STM32读取。
- Quartus编译、Fitter和时序分析全部通过。
- 资源报告、时序报告、测试向量和测试结果已归档。

