import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'power_scan_controller.dart';

class PowerScanView extends StatefulWidget {
  const PowerScanView({
    super.key,
    required this.controller,
    required this.canStart,
    required this.connections,
  });
  final PowerScanController controller;
  final bool canStart;
  final Widget connections;
  @override
  State<PowerScanView> createState() => _PowerScanViewState();
}

class _PowerScanViewState extends State<PowerScanView> {
  final fields = <String, TextEditingController>{
    for (final entry in {
      '起始幅度': '64',
      '结束幅度': '576',
      '粗扫步进': '64',
      '细扫步进': '16',
      '每档包数': '5',
      '复测包数': '30',
      '准备幅度': '256',
      '工作余量（幅度码）': '64',
      '接收等待（秒）': '2',
      '目标收包率（%）': '95',
      'BER上限（%）': '0.1',
    }.entries)
      entry.key: TextEditingController(text: entry.value),
  };
  String? error;
  PowerScanController get c => widget.controller;
  bool get busy => c.running || c.applying || c.ber.running;
  @override
  void dispose() {
    for (final f in fields.values) {
      f.dispose();
    }
    super.dispose();
  }

  PowerScanConfig parse() {
    int integer(String key) {
      final n = int.tryParse(fields[key]!.text.trim());
      if (n == null) throw FormatException('$key 须为整数');
      return n;
    }

    double number(String key) {
      final n = double.tryParse(fields[key]!.text.trim());
      if (n == null || !n.isFinite) throw FormatException('$key 须为有限数值');
      return n;
    }

    final wait = number('接收等待（秒）');
    if (wait < 0.1 || wait > 60) throw const FormatException('接收等待范围0.1..60秒');
    final cfg = PowerScanConfig(
      start: integer('起始幅度'),
      end: integer('结束幅度'),
      step: integer('粗扫步进'),
      fineStep: integer('细扫步进'),
      count: integer('每档包数'),
      retestCount: integer('复测包数'),
      preparationAmplitude: integer('准备幅度'),
      margin: integer('工作余量（幅度码）'),
      receiveWait: Duration(milliseconds: (wait * 1000).round()),
      targetDelivery: number('目标收包率（%）') / 100,
      maxBer: number('BER上限（%）') / 100,
    );
    cfg.validate();
    return cfg;
  }

  void start() {
    try {
      final cfg = parse();
      setState(() => error = null);
      c.start(cfg);
    } catch (e) {
      setState(() => error = '$e');
    }
  }

  String percent(double? v) =>
      v == null ? '—' : '${(v * 100).toStringAsFixed(2)}%';
  Widget card(Widget child) => Card(
    child: Padding(padding: const EdgeInsets.all(16), child: child),
  );
  Widget value(String label, String text) => SizedBox(
    width: 230,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label),
        Text(text, style: Theme.of(context).textTheme.titleLarge),
      ],
    ),
  );
  @override
  Widget build(BuildContext context) {
    String estimate = '';
    try {
      final cfg = parse();
      estimate =
          '${cfg.coarseAmplitudes.length} 个粗扫档位；粗扫发送与接收等待至少约 '
          '${(cfg.coarseLowerBoundSeconds / 60).toStringAsFixed(1)} 分钟。'
          '细扫、复测、准备及串口诊断另计。';
    } catch (_) {}
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        card(
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('最佳发射幅度测试', style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 8),
              const Text(
                '固定FSK接收配置，逐档发包测试；先粗扫、再细扫，候选工作档位独立复测。幅度为DAC码值（0..2047），未经W/dBm标定。',
              ),
              const SizedBox(height: 12),
              widget.connections,
            ],
          ),
        ),
        card(
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('扫描设置', style: TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 12),
              Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  for (final entry in fields.entries)
                    SizedBox(
                      width: 210,
                      child: TextField(
                        controller: entry.value,
                        enabled: !busy,
                        onChanged: (_) => setState(() {}),
                        decoration: InputDecoration(
                          labelText: entry.key,
                          border: const OutlineInputBorder(),
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 12),
              const Text(
                '准备幅度须大于0，且是扫描范围内已验证可通信的档位，仅用于建立一次TIME_BASE。'
                '工作余量是相对最低实测达标点增加的幅度码；推荐值必须是实际测过且复测达标的档位。',
              ),
              if (estimate.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(estimate),
                ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 12,
                runSpacing: 8,
                children: [
                  FilledButton.icon(
                    onPressed:
                        widget.canStart && !busy && !c.ber.requiresReconnect
                        ? start
                        : null,
                    icon: const Icon(Icons.play_arrow),
                    label: const Text('开始功率扫描'),
                  ),
                  OutlinedButton.icon(
                    onPressed: c.running && !c.stopRequested ? c.stop : null,
                    icon: const Icon(Icons.stop),
                    label: const Text('停止扫描'),
                  ),
                  OutlinedButton.icon(
                    onPressed:
                        widget.canStart &&
                            !busy &&
                            !c.ber.requiresReconnect &&
                            c.recommendedAmplitude != null
                        ? c.applyRecommended
                        : null,
                    icon: const Icon(Icons.check),
                    label: const Text('应用推荐幅度'),
                  ),
                ],
              ),
              if (!widget.canStart && !busy)
                const Text('请连接两个不同的TX/RX串口，并结束其他测量操作。'),
              if (c.ber.requiresReconnect)
                const Text(
                  '串口响应未决，请断开并重新连接TX与RX。',
                  style: TextStyle(color: Colors.red),
                ),
              if (error != null)
                Text(error!, style: const TextStyle(color: Colors.red)),
            ],
          ),
        ),
        card(
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                c.message,
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
              if (c.running) ...[
                const SizedBox(height: 12),
                const LinearProgressIndicator(),
                const SizedBox(height: 8),
                Text(
                  '当前幅度 ${c.currentAmplitude ?? '—'} · 本档 ${c.ber.progress}/${c.ber.target} 包 · 已保存 ${c.points.length} 档测量',
                ),
                Text(c.ber.message),
              ],
              if (c.error != null)
                Text(c.error!, style: const TextStyle(color: Colors.red)),
              const SizedBox(height: 12),
              Wrap(
                spacing: 16,
                runSpacing: 12,
                children: [
                  value('最低实测达标幅度', '${c.minimumAmplitude ?? '—'}'),
                  value('复测后的推荐幅度', '${c.recommendedAmplitude ?? '—'}'),
                  value('已应用幅度', '${c.appliedAmplitude ?? '—'}'),
                ],
              ),
              if (c.lowerBoundaryReached)
                const Text('起始档位已达标：更低幅度未测，尚未定位真实下边界。'),
              const Text(
                '达标要求：收包率和诊断覆盖率均达到目标，Payload BER不超过上限，且未观察到削顶或测量故障。'
                '小样本结果用于选档，不代表长期可靠性验收；结果仅适用于本次环境和接收设置。',
              ),
            ],
          ),
        ),
        card(
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                '幅度—收包率',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              if (c.points.isEmpty)
                const Text('扫描后显示测量曲线与逐档结果。')
              else ...[
                SizedBox(
                  height: 220,
                  width: double.infinity,
                  child: CustomPaint(
                    painter: PowerScanChart(
                      List.of(c.points),
                      c.config!,
                      c.recommendedAmplitude,
                      Theme.of(context).colorScheme.primary,
                      fontFamily: Theme.of(
                        context,
                      ).textTheme.bodySmall?.fontFamily,
                    ),
                  ),
                ),
                const Text(
                  '蓝色：粗扫/细扫；橙色：复测；红色：无效或削顶；绿色横线：目标收包率；绿色圈：推荐档位。详细数值见下表。',
                ),
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: DataTable(
                    columns: [
                      for (final title in [
                        '阶段',
                        '幅度',
                        '发完/交付',
                        '收包率',
                        'Payload BER',
                        '覆盖率',
                        '削顶窗口',
                        '结论',
                      ])
                        DataColumn(label: Text(title)),
                    ],
                    rows: [
                      for (final p in c.points)
                        DataRow(
                          cells: [
                            DataCell(
                              Text(
                                p.stage == 'coarse'
                                    ? '粗扫'
                                    : p.stage == 'fine'
                                    ? '细扫'
                                    : '复测',
                              ),
                            ),
                            DataCell(Text('${p.amplitude}')),
                            DataCell(
                              Text(
                                '${p.report['tx_completed'] ?? 0}/${p.report['delivered_unique'] ?? 0}',
                              ),
                            ),
                            DataCell(Text(percent(p.delivery))),
                            DataCell(Text(percent(p.ber))),
                            DataCell(Text(percent(p.coverage))),
                            DataCell(Text('${p.clippedWindows}')),
                            DataCell(Text(p.verdict(c.config!))),
                          ],
                        ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
        card(
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('扫描报告', style: TextStyle(fontWeight: FontWeight.bold)),
              SelectableText(
                c.exportPath ?? '开始后自动保存到 exports/power_scan/power_scan_<时间戳>',
              ),
              const Text(
                '总报告 report.json、逐档 points.csv、扫描日志 raw.jsonl；'
                '各档BER原始记录目录写入总报告。停止或异常也保留已测结果。',
              ),
              Wrap(
                spacing: 12,
                children: [
                  TextButton.icon(
                    onPressed: c.exportPath == null
                        ? null
                        : () async {
                            try {
                              await Process.start('explorer.exe', [
                                c.exportPath!,
                              ]);
                            } catch (e) {
                              if (mounted) setState(() => error = '打开目录失败：$e');
                            }
                          },
                    icon: const Icon(Icons.folder_open),
                    label: const Text('打开报告目录'),
                  ),
                  TextButton.icon(
                    onPressed: c.exportPath == null
                        ? null
                        : () => Clipboard.setData(
                            ClipboardData(text: c.exportPath!),
                          ),
                    icon: const Icon(Icons.copy),
                    label: const Text('复制路径'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class PowerScanChart extends CustomPainter {
  PowerScanChart(
    this.points,
    this.config,
    this.recommended,
    this.color, {
    this.fontFamily,
  });
  final List<PowerPointResult> points;
  final PowerScanConfig config;
  final int? recommended;
  final Color color;
  final String? fontFamily;
  void label(Canvas canvas, String text, Offset position) {
    final painter = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          fontSize: 11,
          color: Colors.grey,
          fontFamily: fontFamily,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    painter.paint(canvas, position);
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width < 100) return;
    final rect = Rect.fromLTRB(42, 12, size.width - 20, size.height - 32);
    final paint = Paint()
      ..color = Colors.grey
      ..strokeWidth = 1;
    for (var i = 0; i <= 4; i++) {
      final y = rect.bottom - rect.height * i / 4;
      canvas.drawLine(Offset(rect.left, y), Offset(rect.right, y), paint);
      label(canvas, '${i * 25}%', Offset(0, y - 6));
    }
    label(canvas, '${config.start}', Offset(rect.left, rect.bottom + 8));
    label(canvas, '${config.end}', Offset(rect.right - 28, rect.bottom + 8));
    label(canvas, '发射幅度码', Offset(rect.center.dx - 30, rect.bottom + 8));
    final targetY = rect.bottom - rect.height * config.targetDelivery;
    canvas.drawLine(
      Offset(rect.left, targetY),
      Offset(rect.right, targetY),
      Paint()
        ..color = Colors.green
        ..strokeWidth = 1.5,
    );
    final sorted =
        points
            .where((p) => p.stage != 'retest' && p.valid && p.delivery != null)
            .toList()
          ..sort((a, b) => a.amplitude.compareTo(b.amplitude));
    Offset position(PowerPointResult p) => Offset(
      config.end == config.start
          ? rect.center.dx
          : rect.left +
                (p.amplitude - config.start) /
                    (config.end - config.start) *
                    rect.width,
      rect.bottom - (p.delivery ?? 0) * rect.height,
    );
    for (var i = 1; i < sorted.length; i++) {
      canvas.drawLine(
        position(sorted[i - 1]),
        position(sorted[i]),
        Paint()
          ..color = color.withValues(alpha: 0.5)
          ..strokeWidth = 2,
      );
    }
    for (final p in points) {
      if (p.delivery == null) continue;
      final at = position(p);
      canvas.drawCircle(
        at,
        4,
        Paint()
          ..color = !p.valid || p.clippedWindows > 0
              ? Colors.red
              : p.stage == 'retest'
              ? Colors.orange
              : color,
      );
      if (p.amplitude == recommended) {
        canvas.drawCircle(
          at,
          7,
          Paint()
            ..color = Colors.green
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2,
        );
      }
    }
  }

  @override
  bool shouldRepaint(covariant PowerScanChart old) => true;
}
