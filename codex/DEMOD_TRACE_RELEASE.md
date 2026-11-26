# 解调观测 Release 2026-09-24

本发布包沿用已验证的 V1 二进制，新增 FPGA Flash 持久化文件。没有重新编译或修改解调算法。

## FIX1 修正

2026-09-24 的 FIX1 FPGA 版本修正了 FSK 噪声基线尚未建立时的载波误判：
复位后必须先完成 noise_ready，energy_above_threshold 才允许置位。这样启动
阶段的正噪声不会把符号同步器保持在锁定状态。FIX1 重新生成了 SOF 和 JIC；
ARM 固件及上位机协议没有变化。

## 文件

- host/short_trans_host.exe：Windows Release 上位机，必须保留同目录 DLL 和 data。
- receiver_arm.hex：接收端 STM32 固件；另附 BIN 和 ELF。
- receiver_fpga.sof：接收端 FPGA 临时配置。
- receiver_fpga_epcq16a.jic：接收端配置 Flash 文件，用于断电保持。
- receiver_fpga_epcq16a_fix1.jic：FIX1 修正版配置 Flash 文件，用于断电保持。
- manifest.json：所有交付文件的 SHA256 清单。

## 持久化烧录

1. 保留原可用固件。核对实物配置 Flash 为 EPCQ16ASI8N，FPGA 为 10CL025Y 系列。本 JIC 仅针对该组合生成，其他硬件不要直接使用。
2. 用 STM32 烧录工具将 receiver_arm.hex 写入接收端。
3. Quartus Programmer 选择正确接收端的 USB-Blaster，使用 JTAG 模式，加载 receiver_fpga_epcq16a.jic，确认链中的 FPGA 和配置 Flash 与实物一致。
4. 对配置 Flash 选择 Program/Configure 和 Verify 后开始。该操作会覆盖原 Flash 配置。
5. 烧录校验成功后重新上电，连接上位机 RX 串口，STATUS 中应看到 ver=20。再运行一次手动解调观测采集。

仅下载 SOF 不会更新 Flash，断电后可能恢复旧版本。完整操作说明见 DEMOD_TRACE_QUICKSTART.md。

## 生成与验证边界

JIC 使用 Quartus Prime Lite 17.1 从包内 SOF 转换：

    quartus_cpf -c -d EPCQ16A -s 10CL025Y -m ASx1 receiver_fpga.sof receiver_fpga_epcq16a.jic

转换结果为 0 errors、0 warnings。器件依据是工程 codex/hardware_overview.md 中记录的 EPCQ16ASI8N 和 FPGA 编译目标，不代表本次已核对实物。
本次未连接、烧录或测试硬件，尚未验证 Flash 启动。原 FPGA 编译的时序覆盖、警告和资源余量限制仍然适用，详见 DEMOD_TRACE_VALIDATION.md。
