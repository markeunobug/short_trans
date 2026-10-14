import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'trace_controller.dart';
import 'trace_data.dart';

class TraceView extends StatefulWidget {
  const TraceView({
    super.key,
    required this.controller,
    required this.connected,
  });
  final TraceController controller;
  final bool connected;
  @override
  State<TraceView> createState() => _TraceViewState();
}

class _TraceViewState extends State<TraceView> {
  int _trigger = 1, _post = 128, _cursor = 0;
  RangeValues _range = const RangeValues(0, 1);
  bool _logEnergy = false;
  static const triggers = {
    1: '手动',
    2: '载波出现',
    4: '锁定',
    8: '失锁',
    16: 'CRC 错误',
    32: '正确帧',
    64: '同步字',
  };
  void message(String text) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
    }
  }

  Future<void> export() async {
    final capture = widget.controller.capture;
    if (capture == null) return;
    try {
      final directory = Directory('exports/traces');
      await directory.create(recursive: true);
      final stem =
          '${directory.absolute.path}/trace_${DateTime.now().millisecondsSinceEpoch}';
      await File('$stem.dtr').writeAsBytes(capture.raw, flush: true);
      await File('$stem.csv').writeAsString(capture.toCsv(), flush: true);
      message('已导出 $stem.dtr / .csv');
    } catch (e) {
      message('导出失败：$e');
    }
  }

  Future<void> import() async {
    final path = TextEditingController();
    final selected = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('打开采集文件'),
        content: SizedBox(
          width: 520,
          child: TextField(
            controller: path,
            autofocus: true,
            decoration: const InputDecoration(labelText: '.dtr 文件路径'),
            onSubmitted: (v) => Navigator.pop(context, v),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, path.text),
            child: const Text('打开'),
          ),
        ],
      ),
    );
    // The dialog's exit animation may still reference its controller.
    Future<void>.delayed(const Duration(seconds: 1), path.dispose);
    if (selected == null || selected.trim().isEmpty) return;
    try {
      final file = File(selected.trim());
      if (await file.length() > 24640) throw const FormatException('文件过大');
      final capture = TraceCapture.parse(await file.readAsBytes());
      if (!mounted) return;
      _range = const RangeValues(0, 1);
      _cursor = 0;
      widget.controller.capture = capture;
      widget.controller.update(
        '离线记录：${file.path}${capture.interrupted ? '（中断）' : ''}',
      );
    } catch (e) {
      message('打开失败：$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final ctl = widget.controller;
    final capture = ctl.capture;
    final records = capture?.records ?? <TraceRecord>[];
    final first = records.isEmpty
        ? 0
        : (_range.start * (records.length - 1)).round();
    final last = records.isEmpty
        ? 0
        : (_range.end * (records.length - 1)).round();
    final cursor = _cursor.clamp(first, last);
    final selected = records.isEmpty ? null : records[cursor];
    final ook = capture?.mode == 2;
    Widget chart(
      String title,
      List<TraceSeries> series, {
      double height = 170,
      bool log = false,
    }) => Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(title, style: Theme.of(context).textTheme.titleSmall),
        Wrap(
          spacing: 16,
          runSpacing: 4,
          children: [
            for (final s in series)
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(width: 10, height: 10, color: s.color),
                  const SizedBox(width: 5),
                  Text(s.name),
                ],
              ),
          ],
        ),
        SizedBox(
          height: height,
          child: LayoutBuilder(
            builder: (context, constraints) {
              void select(double x) {
                final t = ((x - 70) / (constraints.maxWidth - 90)).clamp(
                  0.0,
                  1.0,
                );
                setState(() => _cursor = first + (t * (last - first)).round());
              }

              return MouseRegion(
                onHover: (e) => select(e.localPosition.dx),
                child: GestureDetector(
                  onTapDown: (e) => select(e.localPosition.dx),
                  onPanUpdate: (e) => select(e.localPosition.dx),
                  child: CustomPaint(
                    painter: TracePlot(
                      capture!,
                      series,
                      first,
                      last,
                      cursor,
                      log,
                    ),
                  ),
                ),
              );
            },
          ),
        ),
        const SizedBox(height: 12),
      ],
    );
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Wrap(
          spacing: 12,
          runSpacing: 12,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            SizedBox(
              width: 170,
              child: DropdownButtonFormField<int>(
                initialValue: _trigger,
                decoration: const InputDecoration(labelText: '触发条件'),
                items: [
                  for (final t in triggers.entries)
                    DropdownMenuItem(value: t.key, child: Text(t.value)),
                ],
                onChanged: ctl.running
                    ? null
                    : (v) => setState(() => _trigger = v!),
              ),
            ),
            SizedBox(
              width: 170,
              child: DropdownButtonFormField<int>(
                initialValue: _post,
                decoration: const InputDecoration(labelText: '触发后 / ms'),
                items: [
                  for (final n in [0, 64, 128, 256, 511])
                    DropdownMenuItem(value: n, child: Text('$n')),
                ],
                onChanged: ctl.running
                    ? null
                    : (v) => setState(() => _post = v!),
              ),
            ),
            FilledButton.icon(
              onPressed: !widget.connected || ctl.running
                  ? null
                  : () {
                      _range = const RangeValues(0, 1);
                      _cursor = 0;
                      ctl.start(_trigger, _post);
                    },
              icon: const Icon(Icons.fiber_manual_record),
              label: const Text('开始采集'),
            ),
            IconButton(
              onPressed: ctl.waiting && _trigger == 1
                  ? () {
                      ctl.manualRequested = true;
                    }
                  : null,
              icon: const Icon(Icons.bolt),
              tooltip: '手动触发',
            ),
            IconButton(
              onPressed: ctl.running
                  ? () {
                      ctl.stopRequested = true;
                    }
                  : null,
              icon: const Icon(Icons.stop),
              tooltip: '停止',
            ),
            IconButton(
              onPressed: capture == null || ctl.running ? null : export,
              icon: const Icon(Icons.save_alt),
              tooltip: '导出 CSV 与原始记录',
            ),
            IconButton(
              onPressed: ctl.running ? null : import,
              icon: const Icon(Icons.folder_open),
              tooltip: '打开原始记录',
            ),
          ],
        ),
        const SizedBox(height: 12),
        Text(
          ctl.status,
          style: TextStyle(
            color: ctl.status.contains('失败') ? Colors.red.shade800 : null,
          ),
        ),
        if (!widget.connected)
          const Text('RX 未连接', style: TextStyle(color: Colors.red)),
        if (ctl.running)
          LinearProgressIndicator(value: ctl.waiting ? null : ctl.progress),
        const SizedBox(height: 12),
        if (capture != null) ...[
          Text(
            '${ook ? 'OOK · 1800 Hz' : '2FSK · 1700 / 1900 Hz'}  |  FPGA 0x13  |  Capture ${capture.id}  |  ${records.length} 点',
          ),
          Text(
            'Shift ${capture.header.getUint8(7)}  |  Margin Q4.4 ${capture.header.getUint8(8)}  |  Confidence ${capture.header.getUint8(9)}${ook ? '  |  LOW ${capture.low} / HIGH ${capture.high}' : ''}',
          ),
        ],
        if (records.isEmpty)
          const SizedBox(
            height: 260,
            child: Center(
              child: Icon(
                Icons.monitor_heart_outlined,
                size: 64,
                color: Colors.grey,
              ),
            ),
          ),
        if (records.isNotEmpty) ...[
          SwitchListTile.adaptive(
            contentPadding: EdgeInsets.zero,
            title: const Text('能量对数坐标 log10(1+E)'),
            value: _logEnergy,
            onChanged: (v) => setState(() => _logEnergy = v),
          ),
          RangeSlider(
            values: _range,
            onChanged: (v) {
              if (v.end - v.start >= 1 / math.max(1, records.length - 1)) {
                setState(() => _range = v);
              }
            },
          ),
          Text(
            't = ${capture!.timeMs(selected!).toStringAsFixed(3)} ms  |  Sample ${selected.sample}  |  Phase ${selected.phase}  |  ${selected.events}',
          ),
          Text(
            'E0 ${selected.energy0}  E1 ${selected.energy1}  Soft ${selected.soft}  Confidence ${selected.confidence}  Bits ${selected.bitCount}',
          ),
          const SizedBox(height: 12),
          chart(
            '能量 / 判决门限',
            [
              TraceSeries(
                ook ? '能量' : 'E0 · 1700 Hz',
                Colors.teal,
                (r) => r.energy0.toDouble(),
              ),
              if (!ook)
                TraceSeries(
                  'E1 · 1900 Hz',
                  Colors.deepOrange,
                  (r) => r.energy1.toDouble(),
                ),
              if (!ook)
                TraceSeries(
                  '总能量',
                  Colors.blue,
                  (r) => (r.energy0 + r.energy1).toDouble(),
                ),
              if (!ook)
                TraceSeries('噪声估计', Colors.grey, (r) => r.noise.toDouble()),
              TraceSeries(
                ook ? 'HIGH' : '载波门限',
                Colors.red,
                (r) => r.threshold.toDouble(),
              ),
              if (ook)
                TraceSeries(
                  'LOW',
                  Colors.amber.shade800,
                  (r) => capture.low.toDouble(),
                ),
            ],
            height: 220,
            log: _logEnergy,
          ),
          chart(ook ? '能量减门限中点' : '软判决 E1 - E0', [
            TraceSeries('Soft', Colors.teal, (r) => r.soft.toDouble()),
            TraceSeries('零线', Colors.grey, (r) => 0),
          ]),
          if (!ook)
            chart('置信度', [
              TraceSeries(
                'Confidence',
                Colors.blue,
                (r) => r.confidence.toDouble(),
              ),
              TraceSeries(
                '生效门限',
                Colors.red,
                (r) => r.confidenceThreshold.toDouble(),
              ),
            ], height: 140),
          chart('判决 / 锁定 / 采样', [
            TraceSeries(
              '硬判决',
              Colors.teal,
              (r) => r.flag(0) ? 1 : 0,
              step: true,
            ),
            TraceSeries(
              '锁定 (+2)',
              Colors.blue,
              (r) => r.flag(2) ? 3 : 2,
              step: true,
            ),
            TraceSeries(
              '符号采样 (+4)',
              Colors.deepOrange,
              (r) =>
                  r.flag(3) && !r.flag(17) ? (r.flag(4) ? 5 : 4) : double.nan,
              dots: true,
            ),
            TraceSeries(
              '重放 (+6)',
              Colors.purple,
              (r) => r.flag(17) ? 6 : double.nan,
              dots: true,
            ),
          ], height: 170),
          Text('事件', style: Theme.of(context).textTheme.titleSmall),
          for (var i = first; i <= last; i++)
            if (records[i].events.isNotEmpty)
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: Icon(
                  records[i].flag(9)
                      ? Icons.error_outline
                      : Icons.flag_outlined,
                  color: records[i].flag(9) ? Colors.red : Colors.teal,
                ),
                title: Text(records[i].events),
                subtitle: Text(
                  '${capture.timeMs(records[i]).toStringAsFixed(3)} ms',
                ),
                onTap: () => setState(() => _cursor = i),
              ),
        ],
      ],
    );
  }
}

class TraceSeries {
  TraceSeries(
    this.name,
    this.color,
    this.value, {
    this.step = false,
    this.dots = false,
  });
  final String name;
  final Color color;
  final double Function(TraceRecord) value;
  final bool step, dots;
}

class TracePlot extends CustomPainter {
  TracePlot(
    this.capture,
    this.series,
    this.first,
    this.last,
    this.cursor,
    this.log,
  );
  final TraceCapture capture;
  final List<TraceSeries> series;
  final int first, last, cursor;
  final bool log;
  double value(double v) => log ? math.log(1 + math.max(0, v)) / math.ln10 : v;
  @override
  void paint(Canvas canvas, Size size) {
    final box = Rect.fromLTRB(70, 12, size.width - 20, size.height - 26);
    if (box.width <= 0) return;
    var lo = double.infinity, hi = double.negativeInfinity;
    for (final s in series) {
      for (var i = first; i <= last; i++) {
        final y = value(s.value(capture.records[i]));
        if (y.isFinite) {
          lo = math.min(lo, y);
          hi = math.max(hi, y);
        }
      }
    }
    if (!lo.isFinite) {
      lo = 0;
      hi = 1;
    }
    if (hi == lo) {
      hi += 1;
      lo -= 1;
    }
    final padding = (hi - lo) * 0.07;
    lo -= padding;
    hi += padding;
    double x(int i) =>
        box.left + (i - first) / math.max(1, last - first) * box.width;
    double y(double v) => box.bottom - (value(v) - lo) / (hi - lo) * box.height;
    void text(String v, Offset p) {
      final t = TextPainter(
        text: TextSpan(
          text: v,
          style: const TextStyle(fontSize: 11, color: Colors.black54),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      t.paint(canvas, p);
    }

    final grid = Paint()
      ..color = const Color(0xffdddddd)
      ..strokeWidth = 1;
    for (var i = 0; i < 5; i++) {
      final yy = box.top + box.height * i / 4;
      canvas.drawLine(Offset(box.left, yy), Offset(box.right, yy), grid);
      final v = hi - (hi - lo) * i / 4;
      text(
        log
            ? v.toStringAsFixed(2)
            : (v.abs() >= 10000
                  ? v.toStringAsExponential(1)
                  : v.toStringAsFixed(1)),
        Offset(0, yy - 6),
      );
    }
    for (var i = 0; i < 3; i++) {
      final n = first + ((last - first) * i / 2).round();
      text(
        '${capture.timeMs(capture.records[n]).toStringAsFixed(1)} ms',
        Offset((x(n) - 20).clamp(box.left, box.right - 56), box.bottom + 6),
      );
    }
    canvas.save();
    canvas.clipRect(box);
    for (final s in series) {
      final paint = Paint()
        ..color = s.color
        ..strokeWidth = 1.5
        ..style = PaintingStyle.stroke;
      final path = Path();
      double? previousY;
      for (var i = first; i <= last; i++) {
        final v = s.value(capture.records[i]);
        if (!v.isFinite) {
          previousY = null;
          continue;
        }
        final xx = x(i), yy = y(v);
        if (s.dots) {
          canvas.drawCircle(Offset(xx, yy), 3, Paint()..color = s.color);
          continue;
        }
        if (previousY == null) {
          path.moveTo(xx, yy);
        } else {
          if (s.step) path.lineTo(xx, previousY);
          path.lineTo(xx, yy);
        }
        previousY = yy;
      }
      canvas.drawPath(path, paint);
    }
    if (capture.triggerIndex >= first && capture.triggerIndex <= last) {
      canvas.drawLine(
        Offset(x(capture.triggerIndex), box.top),
        Offset(x(capture.triggerIndex), box.bottom),
        Paint()
          ..color = Colors.red
          ..strokeWidth = 1,
      );
    }
    canvas.drawLine(
      Offset(x(cursor), box.top),
      Offset(x(cursor), box.bottom),
      Paint()
        ..color = Colors.black38
        ..strokeWidth = 1,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant TracePlot oldDelegate) => true;
}
