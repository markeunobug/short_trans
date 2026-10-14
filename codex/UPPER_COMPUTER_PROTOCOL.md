# 短距离 2FSK 通信协议（当前实现）

版本：当前代码实现 V2 时间扩展  
适用工程：`short_trans`  2FSK 100 bit/s 链路、STM32 TX/RX、Cyclone 10 LP RX FPGA

## 1. 链路概览

```text
上位机 -- USART1/RS485 ASCII命令 --> TX STM32 -- PA4 DAC 2FSK --> RX FPGA
上位机 <-- USART1/RS485 ASCII响应 -- RX STM32 <-- SPI1 ------------+
```

### 无线/声学物理参数

| 项目 | 当前值 |
|---|---:|
| 调制 | 非相干 2FSK |
| bit 0 | 1.7 kHz |
| bit 1 | 1.9 kHz |
| bit 率 | 100 bit/s |
| 符号周期 | 10 ms |
| 采样率 | 48 kSPS |
| bit 顺序 | MSB first |
| 前导码 | `0xAAAA`，16 bit |
| 同步字 | `0x06B7`，16 bit |
| 帧间静默 | 不少于 100 ms |
| 应用 Payload | 0..64 byte |

### 字节序

所有多字节整数均使用大端序（Big Endian，MSB first）。

## 2. 无线物理帧

```text
Preamble(2B) | Sync(2B) | Header(4B) | Time Prefix(3B/4B) |
Application Payload(0..64B) | CRC16(2B)
```

前导码和同步字不参与 CRC。Header 和后续时间前缀、应用 Payload 参与 CRC16。

### 2.1 Header

| 字节 | 字段 | 定义 |
|---:|---|---|
| 0 | `version_type` | 高 4 bit：协议版本；低 4 bit：帧类型 |
| 1 | `sequence` | 当前实现保留的 8 bit 序号；本轮时间功能不做序号统计 |
| 2 | `payload_length` | 应用 Payload 长度，0..64；不包含时间前缀 |
| 3 | `header_crc8` | CRC-8/ATM，覆盖 Header 字节 0..2 |

当前时间协议常量：

```text
version = 2
frame_type DATA      = 0
frame_type TIME_BASE = 1
```

`version_type = (version << 4) | frame_type`。

### 2.2 TIME_BASE 帧

```text
Header | base_time_s(4B, BE) | CRC16(2B)
```

- `payload_length` 必须为 0。
- `base_time_s`：32 bit，单位为秒。
- 该值在 TX 开始发送该 TIME_BASE 物理帧前导码时锁存。
- 每次发送 TIME_BASE 都可以形成新的时间基准；接收端收到 CRC 正确的 TIME_BASE 后立即切换。
- TIME_BASE 不向应用 Payload FIFO 输出数据，但作为一个零长度描述符保留其时间元数据。

### 2.3 DATA 帧

```text
Header | elapsed_10ms(3B, BE) | Application Payload | CRC16(2B)
```

- `elapsed_10ms`：24 bit，从最近一次 TIME_BASE 开始计算的完整经过时间。
- 计算规则：`elapsed_10ms = floor(elapsed_ms / 10)`。
- 时间在 DATA 帧前导码开始发送时锁存。
- 该字段不是相对上一帧的增量；丢包不影响后续包独立还原时间。
- 未建立时间基准时，TX 仍允许发送 DATA，当前实现写入 `elapsed_10ms=0`；RX 保留该帧但标记绝对时间无效。

接收端恢复绝对时间：

```text
absolute_timestamp_ms = base_time_s * 1000 + elapsed_10ms * 10
```

### 2.4 CRC

CRC8：

```text
CRC-8/ATM
poly=0x07, init=0x00, refin=false, refout=false, xorout=0x00
```

CRC16：

```text
CRC-16/CCITT-FALSE
poly=0x1021, init=0xFFFF, refin=false, refout=false, xorout=0x0000
```

CRC16 发送顺序为高字节在前，覆盖范围为：

```text
Header[0..3] + Time Prefix + Application Payload
```

CRC 错误帧不会进入正常应用 Payload FIFO。

## 3. TX STM32 上位机命令（USART1/RS485）

串口参数：`115200-8-N-1`。命令以 ASCII 文本发送，以 `CR` 或 `LF` 结束。RS485 发送期间方向控制脚 PA7 为高，发送完成后回到接收状态。

### 命令表

| 命令 | 作用 | 典型响应 |
|---|---|---|
| `HELP` | 显示命令帮助 | `OK ...` |
| `AMP n` | 设置 DAC 发射幅度 | `OK` 或 `ERR COMMAND` |
| `PAYLOAD hex` | 设置应用 Payload；`-` 表示空 Payload | `OK` 或错误 |
| `SET_TIME YYYY-MM-DD HH:MM:SS` | 设置 TX 时间基准 | `OK` 或错误 |
| `TIME_BASE` | 请求下一次 PACKET 使用 TIME_BASE 帧 | `OK` |
| `META v t seq` | 设置 Header 版本/类型/序号（高级调试） | `OK` 或错误 |
| `MODE SILENCE` | 静默 |
| `MODE TONE1700` | 连续 1.7 kHz |
| `MODE TONE1900` | 连续 1.9 kHz |
| `MODE ALT` | 交替 2FSK 测试 |
| `MODE PRBS` | PRBS 测试 |
| `MODE PACKET` | 物理帧发送模式 |
| `SEND` | 启动当前模式/当前 Payload 发送 | `OK` 或错误 |
| `STOP` | 停止发送 | `OK` |
| `STATUS` | 查询 TX 状态 | `OK key=value ...` |

推荐的时间设置流程：

```text
SET_TIME 2026-09-03 20:30:00
TIME_BASE
MODE PACKET
PAYLOAD 01020304
SEND
```

`SET_TIME` 成功后会使时间基准有效，并标记下一次 PACKET 发送为 TIME_BASE；也可以单独使用 `TIME_BASE` 请求新的时间基准。TIME_BASE 之后再发送普通 DATA 包。

### TX STATUS 重点字段

```text
time_valid=0/1
time_base_pending=0/1
base_s=<秒>
elapsed10=<10ms单位经过时间>
```

当前实现尚未自动调度 24 小时 rollover；需要上位机再次发送 `SET_TIME`/`TIME_BASE` 开启新的时间段。

## 4. RX STM32 上位机命令（USART1/RS485）

串口参数同为 `115200-8-N-1`。

| 命令 | 作用 |
|---|---|
| `PING` | 连通性测试，返回 `OK PONG` |
| `HELP` | 显示 RX 命令帮助 |
| `STATUS` | 查询 FPGA、帧和时间状态 |
| `READ` | 读取当前队首应用 Payload 及时间信息 |

### RX STATUS 示例字段

```text
fpga=1 ver=16 result=0 len=4 seq=7 type=0
time_valid=1 base_s=... elapsed10ms=123 timestamp_ms=...
uart_err=0 overflow=0
```

`timestamp_ms` 只有在 `time_valid=1` 时才可作为绝对时间使用。未收到 TIME_BASE 的 DATA 仍可读取，但 `time_valid=0`。

### RX READ 语义

```text
OK DATA <payload_hex> time_valid=<0|1> timestamp_ms=<uint64>
```

FPGA 端保留帧描述符直到 STM32 完成 Payload 读取并执行 POP。应用层读取流程应先查询/读取队首帧，再完成读取后执行 POP；放弃当前帧时执行 DROP。

## 5. FPGA SPI1 软件接口摘要

SPI：Mode 0、8 bit、MSB first、约 1 MHz、NSS 低有效。命令字节 bit7=1 表示读，bit7=0 表示写，bit6..0 为寄存器地址。

### 时间相关寄存器

| 地址 | 名称 | 含义 |
|---:|---|---|
| `0x16` | `HEAD_TIME_FLAGS` | bit0：时间有效；bit1：TIME_BASE 描述符 |
| `0x17` | `HEAD_TIMESTAMP_B3` | 时间字段 bit31..24 |
| `0x18` | `HEAD_TIMESTAMP_B2` | 时间字段 bit23..16 |
| `0x19` | `HEAD_TIMESTAMP_B1` | 时间字段 bit15..8 |
| `0x1A` | `HEAD_TIMESTAMP_B0` | 时间字段 bit7..0 |

对 `TIME_BASE`，`0x17..0x1A` 是 `base_time_s`。  
对 `DATA`，FPGA 将 24 bit `elapsed_10ms` 零扩展到 32 bit 放入上述寄存器。

### 常用帧寄存器

| 地址 | 名称 | 含义 |
|---:|---|---|
| `0x04` | `FRAME_COUNT` | 可读帧数量 |
| `0x05` | `HEAD_VERSION_TYPE` | 队首 Header Byte0 |
| `0x06` | `HEAD_SEQUENCE` | 队首序号 |
| `0x07` | `HEAD_LENGTH` | 应用 Payload 长度 |
| `0x40` | `RX_DATA` | 队首 Payload 数据端口，读取会前进 |
| `0x10` | `CONTROL` | bit3 POP_FRAME；bit4 DROP_FRAME |

## 6. 时间与丢包语义

- 当前协议允许 DATA 在没有 TIME_BASE 时发送/接收，但其绝对时间无效。
- 收到新的有效 TIME_BASE 后，后续 DATA 使用最近一次收到的 TIME_BASE。
- `elapsed_10ms` 为完整相对时间值，不依赖前一个 DATA 包。
- 本轮不实现序号丢包统计；`sequence` 字段保留给后续功能。
- 本轮不实现 ACK/NACK、重传、FEC、时钟漂移校准、Flash 保存和时区处理。
- 24 bit、10 ms 的相对时间范围约为 46.6 小时；接近上限时重新发送 TIME_BASE 并重新开始计时。

## 7. 上位机开发建议

1. TX 端先发送 `SET_TIME`，检查 `OK`。
2. 发送 `TIME_BASE`，确认 RX `STATUS` 中 `type=1`、`time_valid=1`。
3. 再发送 DATA，读取 `timestamp_ms` 验证时间换算。
4. 解析所有十六进制 Payload 时按大端解析时间字段。
5. 不要把 `HEAD_LENGTH` 当成“含时间前缀的线长”；它表示应用 Payload 长度。
6. 发现 `time_valid=0` 时，可以保留 Payload，但不要将 `timestamp_ms` 作为可信绝对时间。

## 8. 模式三扫频协议

扫频诊断不经过 2FSK 空中数据帧，电脑分别控制 TX 和 RX 的 RS485
串口。默认参数为 1500..2100 Hz、20 Hz 步进、20 ms 稳定时间、
100 ms 能量窗口和 3 次窗口平均。

### TX 命令

```text
SWEEP INFO
SWEEP TONE <seq> <frequency_hz> <amplitude>
SWEEP OFF
```

正常响应示例：

```text
OK SWEEP TONE seq=23 freq=1520 amp=256
OK SWEEP OFF
```

TX 使用 32-bit NCO/DDS 生成连续单音。`amplitude` 取值 0..2047，同一条
幅频响应曲线应保持一致。

### RX 命令

```text
SWEEP INFO
SWEEP MEASURE <seq> <frequency_hz> <settle_ms> <window_ms> <average_count>
SWEEP STOP
```

默认测量命令示例：

```text
SWEEP MEASURE 23 1520 20 100 3
```

RX 等待测量完成后返回一条结果：

```text
OK SWEEP RESULT seq=23 freq=1520 n=3 mean=183420 min=179100 max=188210 clip=0
```

- 每个窗口先计算 `E = I^2 + Q^2`，然后对多个 E 求算术平均。
- `mean` 是 `energy_sum / n`，`min` 和 `max` 是单窗口能量范围。
- `clip` 是原始 ADC 接近满量程或 20-bit 预处理饱和的样本数量。
- `seq` 由上位机产生，用于匹配 TX 设置与 RX 结果。
- 扫频活动期间 FPGA 暂停并复位正常 2FSK 解调；`SWEEP STOP` 后恢复。

### 底噪测量

底噪测量使用同一组 RX 频点和参数，但 TX 必须先执行 `SWEEP OFF`。
上位机可以保存 `Enoise`，显示或导出：

```text
Ecorrected = max(Esignal - Enoise, 0)
relative_db = 10 * log10(Ecorrected / max(Ecorrected))
```

## Mode 2：OOK 1.8 kHz 与固定门限（固件扩展）

本节对应 `MODE2_OOK_IMPLEMENTATION_PLAN.md`。新功能需要 TX/RX 配套固件，
RX FPGA 寄存器版本至少为 `0x12`；软件编译/仿真通过不代表已经上板验证。

系统模式 1 是 2FSK，模式 2 是 1.8 kHz OOK，模式 3 继续使用原扫频命令。
`MOD` 选择通信调制，原 `MODE` 选择连续载波、ALT、PRBS、PACKET 等发送波形。
两者不是同一个枚举。扫频暂停当前接收链，结束后恢复所选通信调制。

### TX 命令

- `MOD FSK`：选择 2FSK（上电默认）。
- `MOD OOK`：选择 OOK，100 bit/s，1 为 1.8 kHz，0 为 DAC 中点静默。
- `MODE CARRIER`：OOK 1.8 kHz 连续载波诊断。
- `STATUS`：增加 `mod=FSK` 或 `mod=OOK`。

TX 正在发送或已有待发帧时不允许切换调制。应先停止发送，再切换。
示例成功回复：`OK MOD OOK`。原帧内容、CRC、时间戳和 DATA/TIME_BASE 规则保留。

### RX 命令

```text
MOD FSK
MOD OOK
ASK THRESH 400 600
ASK STATUS
```

`ASK THRESH` 参数按“下门限、上门限”顺序，十进制 uint32，要求下门限小于上门限。
数值属于 1.8 kHz 相关/平方和/平滑后的数字能量尺度，不是电压、dB 或 DAC 码值。
400/600 仅为尚未经过链路标定的软件起点，不代表实际设备最佳门限。
不自动跟踪噪声或利用前导码修改门限。上电恢复默认值，本版不写 Flash。

```text
OK MOD OOK pending=0
OK ASK THRESH low=400 high=600 pending=1
OK ASK STATUS mode=OOK low=400 high=600 energy=800 pending=0 error=0 generation=1 bit=1 locked=0 ready=1
```

- `low/high/mode` 在 STATUS 中始终表示实际生效值。
- `pending=1` 表示已提交，等待接收链/扫频空闲；不能当作已经生效。
- `generation` 每成功生效一次递增（8 位回绕）。
- `energy` 是完整 32 位能量读数；未就绪时注意 `ready=0`。
- `error=1` 或 ERR 回复表示配置失败，需检查参数、固件版本与传输状态。
- 暂存寄存器与待生效事务相互隔离；连续字节写入不会改变正在接收帧的门限。

上位机的“调制与门限”页面提供下门限/上门限输入、提交、实际读回和 TX/RX
联合调制设置。联合设置不是跨设备原子操作：若 TX 成功而 RX 失败，界面会明确报告
部分成功，必须检查后重新应用。只有两端回复及 RX 实际读回均符合请求才报告确认。

### 2026-09-23 2FSK 频点更新

当前 bit 0 = 1700 Hz，bit 1 = 1900 Hz；采样率 48 kSPS，码率 100 bit/s。
单音命令改为 `MODE TONE1700` / `MODE TONE1900`，旧频点命令不再接受。
TX STM32 固件与 RX FPGA 配置需配套重新编译、下载；OOK 1800 Hz 与扫频范围不变。
