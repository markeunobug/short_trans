import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'trace_data.dart';

class TraceStatus {
  TraceStatus(this.flags, this.id, this.count);
  final int flags, id, count;
  bool get ready => flags & 4 != 0;
  bool get armed => flags & 1 != 0;
  factory TraceStatus.parse(String line) {
    if (!line.startsWith('OK TRACE status=')) throw FormatException(line);
    final fields = <String, int>{};
    for (final m in RegExp(r'(\w+)=(\d+)').allMatches(line)) {
      fields[m[1]!] = int.parse(m[2]!);
    }
    final flags = fields['status'], id = fields['id'], count = fields['count'];
    if (flags == null ||
        id == null ||
        count == null ||
        flags > 15 ||
        id > 65535 ||
        count > 512 ||
        fields['depth'] != 512) {
      throw const FormatException('Invalid TRACE status');
    }
    return TraceStatus(flags, id, count);
  }
}

class TraceController {
  TraceController({
    required this.command,
    required this.readBlock,
    required this.changed,
  });
  final Future<String> Function(String) command;
  final Future<Uint8List> Function(int, int, int) readBlock;
  final void Function() changed;
  TraceCapture? capture;
  int triggerMask = 1;
  int postTriggerMs = 128;
  bool running = false, waiting = false;
  bool manualRequested = false, stopRequested = false;
  double progress = 0;
  String status = '尚未采集';
  void update(String value) {
    status = value;
    changed();
  }

  Future<String> checked(String cmd) async {
    final line = await command(cmd);
    if (line.startsWith('ERR')) throw StateError(line);
    return line;
  }

  Future<void> start(int triggerMask, int post) async {
    if (running) return;
    running = true;
    waiting = true;
    manualRequested = false;
    stopRequested = false;
    progress = 0;
    capture = null;
    update('准备采集');
    var didArm = false;
    try {
      await checked('TRACE ARM $triggerMask $post');
      didArm = true;
      final deadline = DateTime.now().add(const Duration(seconds: 30));
      TraceStatus s;
      while (true) {
        if (stopRequested || DateTime.now().isAfter(deadline)) {
          await checked('TRACE STOP');
        } else if (manualRequested) {
          manualRequested = false;
          await checked('TRACE TRIGGER');
        }
        s = TraceStatus.parse(await checked('TRACE STATUS'));
        if (s.ready) break;
        if (!s.armed) throw StateError('采集未启动：检查 ADC、扫频状态及固件');
        update((s.flags & 2) != 0 ? '已触发，记录后续数据' : '等待触发');
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      waiting = false;
      stopRequested = false;
      final total = 64 + s.count * 48;
      final data = BytesBuilder(copy: false);
      for (var offset = 0; offset < total;) {
        if (stopRequested) throw StateError('已取消下载；板端记录仍保留');
        final length = math.min(192, total - offset);
        Uint8List? bytes;
        for (var attempt = 0; attempt < 3; attempt++) {
          try {
            bytes = await readBlock(s.id, offset, length);
            if (bytes.length != length) {
              throw const FormatException('Wrong block length');
            }
            break;
          } catch (_) {
            if (attempt == 2) rethrow;
          }
        }
        data.add(bytes!);
        offset += length;
        progress = offset / total;
        update('读取记录 ${(progress * 100).round()}%');
      }
      final finalStatus = TraceStatus.parse(await checked('TRACE STATUS'));
      if (!finalStatus.ready ||
          finalStatus.id != s.id ||
          finalStatus.count != s.count) {
        throw StateError('采集编号变化，已拒绝混合数据');
      }
      final parsed = TraceCapture.parse(data.takeBytes());
      if (parsed.id != s.id) throw StateError('采集头编号不匹配');
      capture = parsed;
      update(parsed.interrupted ? '采集中断：仅显示中断前记录' : '采集完成');
    } catch (e) {
      if (didArm && waiting) {
        try {
          await command('TRACE STOP');
        } catch (_) {
          /* original error retained */
        }
      }
      update('采集失败：$e');
    } finally {
      running = false;
      waiting = false;
      changed();
    }
  }
}
