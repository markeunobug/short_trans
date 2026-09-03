# 水下通信系统项目资料

本目录存放 Codex 生成的项目资料，不在 `sch` 中修改原始原理图，也不预先创建固件工程。

- [hardware_overview.md](hardware_overview.md)：收发板硬件架构、引脚定义、接口和待确认问题
- [RX_FPGA_2FSK_TASK_PLAN.md](RX_FPGA_2FSK_TASK_PLAN.md)：RX FPGA 2FSK冻结方案、模块接口、子agent任务和验收标准
- [RX_FPGA_2FSK_IMPLEMENTATION_STATUS.md](RX_FPGA_2FSK_IMPLEMENTATION_STATUS.md)：当前实现、自动验证结果和上板联调清单
- [SYSTEM_INTEGRATION_CHECKLIST.md](SYSTEM_INTEGRATION_CHECKLIST.md)：系统联调完成项、阻塞项、分阶段待办和验收标准
- [datasheets/README.md](datasheets/README.md)：器件手册索引及本地 PDF 状态
- `datasheets/*.pdf`：已成功获取并校验为 PDF 的厂商资料

当前依据：

- `../sch/SCH_trans_2026-07-15.pdf`，5 页，发射板 Board3，V1.0
- `../sch/SCH_receive_2026-07-15.pdf`，6 页，接收板 Board2，V1.0
