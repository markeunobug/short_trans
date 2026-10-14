# 2FSK 接收链路 SignalTap 观察文件

> 注意：本文件最初描述四实例合并配置。当前 Quartus Prime Lite 22.1 工程不能同时综合两个或更多 SignalTap 实例。实际使用请转到 `README_FSK_PRESETS.md`，并选择四个单实例预设之一。不要把 `FSK_CHAIN_DEBUG.stp` 设为活动编译文件。

文件：FSK_CHAIN_DEBUG.stp
对应工程：rx_cyclone10（不是 ASK 工程）。
全部实例使用 FPGA_CLK 上升沿采集；内部节点使用 pre-synthesis / classic taps。

## 配置总览

| 实例 | 用途 | 深度 | 存储条件 | 默认触发 |
|---|---|---:|---|---|
| auto_signaltap_0 / samples | 32位输入、20位解调样本、削顶和输入状态 | 1024 | demod_sample_valid=1 | demod_sample_valid 上升沿 |
| auto_signaltap_1 / metrics | 双音能量、软判决、置信度、噪声和门限 | 1024 | metric_valid=1 | metric_valid 上升沿 |
| auto_signaltap_2 / symbols | 同步后的比特及其质量 | 1024 | bit_valid=1 | bit_valid 上升沿 |
| auto_signaltap_3 / frames | CRC结果、帧信息、负载输出、错误脉冲 | 512 | 连续存储 | frame_valid 上升沿 |

默认触发位置为 center。分别选择并启动需要的实例；各实例独立触发，不能把同一列样本编号当作同一时刻。
按工程名义参数：样本48 kHz，1024点约21.33 ms；指标每1 ms一次，1024点约1.024 s；码元约10 ms一个，1024个有效码元约10.24 s有效数据时间，停收期间不写入；帧组30 MHz连续采集512点约17.07 us。
这些时间是按参数计算，不是板上测量值。合格存储会跳过无效时钟，横轴不能简单按照30 MHz换算；应结合存储条件解释。

## 打开、编译、下载

1. 在 Quartus 打开 rx_cyclone10.qpf，再打开此 .stp。
2. 将工程的 SignalTap 文件选为 SignalTap/FSK_CHAIN_DEBUG.stp，并启用 SignalTap。当前已有 stp1.stp 未被覆盖，工程 .qsf 未由本次修改。
3. 检查 Acquisition Clock 为 FPGA_CLK；前三组 Storage Qualifier 为对应 valid 信号，帧组关闭存储限定。默认只给表中指定信号设置 rising edge，其余触发节点为 Don't Care。
4. 执行 Analysis & Elaboration；如有未匹配的节点，在 Node Finder 使用 SignalTap: pre-synthesis 查找并替换为该工程实际名称。文件通过语法读取不等于所有节点已完成综合绑定。
5. 完整编译工程，检查资源和时序结果。选择本次生成的 output_files/rx_cyclone10.sof 下载，再运行采集。仅打开 .stp 或下载旧 .sof 不会加入这些探针。界面若未找到 SOF，请手动选择工程输出目录中的新文件。
6. 确认 sweep_active=0、adc_stream_valid=1、rst_fsk_n=1，再发送已知内容的2FSK测试帧。

四实例原始采样存储合计418816 bit；这不是实际M9K占用估算，实际还有块取整、逻辑、触发资源以及原有接收链路存储。如果 fitter 报资源不足，优先把 metrics 深度降到512，或在重新编译前禁用本次不需要的实例。仅停止运行某实例并不会释放已经编译进去的硬件资源。

## 第一组：从ADC数据到20位样本

- sample_fifo_rd_data[31..0]：I2S输入经过跨时钟FIFO后的32位数据字，位于系统时钟域。这个32位接口宽度不代表ADC具有32位有效精度。
- demod_sample_data[19..0]：送给解调器的有符号20位样本，范围-524288～524287；已设置为有符号曲线显示。
- sample_shift[4..0]：输入缩放配置。结合 sample_preprocess 的移位和饱和处理看20位结果。
- sample_clipped_positive / sample_clipped_negative：20位转换发生正/负饱和；频繁置位意味着输入缩放需要检查。
- adc_near_full_scale：原始字高位接近量程边缘的提示，和20位转换削顶是不同检测。
- adc_stream_valid、adc_config_valid、mclk_present、sweep_active、rst_fsk_n：链路前提条件。
- sample_overflow_sync_ff2、i2s_error_sync_ff2：同步到系统域的输入异常状态。

这组只在 demod_sample_valid=1 时记录。如果完全没有样本或ADC初始化失败，采集可能一直等待；排查时先关闭存储限定，使用立即触发/手动停止观察状态。限定采集中的状态只能代表已记录样本的时刻，不能证明期间没有短暂异常。

## 第二组：双音能量、判决与可信程度

- energy_f0[31..0] / energy_f1[31..0]：两路相关能量，直接观察完整32位值。
- soft_metric[32..0]：有符号 E1-E0；正值偏向1，负值偏向0。
- total_energy[32..0]：E0+E1。
- hard_bit：每个有效指标对应的即时判决，不能直接当作码元输出。
- confidence[7..0]：双音能量分离程度，约为 min(255, floor(256*abs(E1-E0)/(E0+E1)))；不是正确概率或SNR。
- confidence_threshold / confidence_ok：置信门限与比较结果。锁定之后低置信度不必然禁止比特输出，需要继续看码元和帧结果。
- noise_energy、carrier_threshold、energy_above_threshold：比较总能量与自适应门限。
- energy_margin：Q4.4噪声倍率；noise_offset：附加门限量。
- noise_ready：噪声估计已初始化，不表示已经收敛或稳定。
- carrier_active、symbol_locked、selected_phase：指标采样时刻的载波/同步状态。

当前相关器使用480样本窗口、48样本步进；在48 kHz下对应10 ms窗口、1 ms输出一次。窗口跨越码元边界时两路能量可能同时存在，confidence下降不必然是故障。

能量、门限等无符号总线默认用十六进制显示，便于精确读取；可在GUI改成 Unsigned Decimal 或无符号曲线。soft_metric 已设置有符号曲线。

## 第三组：最终码元结果

- bit_valid / bit_value：只在valid时接收一个解调比特；本实例按valid限定，因此每个记录点就是一个有效输出码元。
- symbol_energy / symbol_confidence：该码元采用的能量与置信度。
- selected_phase：当前所选采样相位。
- timing_adjust：有符号2位时序修正，需用有符号方式解释，不能把-1看作3。
- symbol_locked、carrier_active、frame_parser_busy：输出比特时的状态。

如果锁定后不再产生 bit_valid，这组不会继续填满并完成采集。可手动停止查看已有数据，或临时关闭存储限定诊断。不要通过这组证明“从未失锁”：失锁脉冲可能发生在无bit_valid的时刻。

## 第四组：帧通过校验、负载和错误

- frame_valid：帧已通过协议检查和CRC；good_frame在RTL中直接等于frame_valid，因此不重复采集。
- frame_version_type、frame_sequence、frame_payload_length：该帧元数据。
- frame_timestamp、frame_timestamp_valid、frame_is_time_base：时间字段及其有效性。
- frame_payload_valid / frame_payload_data / frame_payload_last：输出负载字节及末字节标志，只在payload_valid时读取data。
- header_error、length_error、crc_error、frame_timeout_error：错误原因脉冲。
- sync_found、preamble_detected、symbol_lock_lost、symbol_search_timeout：同步过程的事件触发入口。

本实现先收齐并校验CRC，再产生frame_valid，然后以系统时钟逐字节输出缓存负载。默认frame_valid触发适合观察这段短时输出；17 us记录窗无法容纳秒级整帧空口接收过程。

排查坏帧时，将frame_valid改成Don't Care，并把crc_error（或目标错误信号）设为rising edge；否则默认成功帧触发不会捕捉失败现场。观察前导检测、同步字命中或失锁同理：只保留目标事件触发，避免把两个互不同时出现的脉冲设成AND条件。

sync_found等已列出的信号只在记录窗覆盖它们时可见，不会自动保存此前历史。需要长时间研究同步状态机时，另用目标事件触发，或增加事件保持/事件日志逻辑；此文件没有改动RTL来增加这些逻辑。

## 如何判断可信

依次确认：输入未削顶/溢出 → 总能量超过合理噪声门限 → 双音能量差和码元置信度合理 → 锁定且输出比特稳定 → frame_valid且负载与已知发送内容相符。
CRC通过提供整帧校验依据，但不等于误码率为零；误码率需要与已知发送序列持续比对并统计。仅confidence高或仅carrier_active高都不能证明接收内容正确。

noise_update等处理后产生的单周期脉冲未放入metric_valid限定组：它们可能晚于限定周期，直接加入会造成漏观测。需要专门观察时，应使用连续采集并在该脉冲上触发。

## 本次验证范围

2026-09-23：已核对顶层节点名称和位宽、XML结构、数据索引和总线映射；使用本机 Quartus Prime Lite 17.1 的 quartus_stp 执行 open_session / close_session，成功打开并保存，最终0错误、0警告。
尚未对这个新增配置完成工程综合、布局布线、时序验证、下载或板上采集。最终节点可用性、资源和时序以工程编译为准。

generate_fsk_chain_stp.py 为可复用生成脚本，基于原有stp1.stp结构生成配置，不复制原文件中的历史采集日志。重新执行会覆盖本目录的FSK_CHAIN_DEBUG.stp，包括之后在GUI中修改的配置。
