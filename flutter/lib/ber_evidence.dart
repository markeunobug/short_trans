import 'dart:convert';
import 'dart:typed_data';

const berObserverCounterNames = [
  'samples',
  'metrics',
  'above_threshold_metrics',
  'carrier_rises',
  'preambles',
  'lock_rises',
  'syncs',
  'header_errors',
  'length_errors',
  'crc_errors',
  'good_frames',
  'in_frame_lock_losses',
  'frame_timeouts',
  'search_timeouts',
  'chain_unavailable_cycles',
  'bits',
  'event_overflows',
];
const berObserverEventNames = [
  '载波出现',
  '载波消失',
  '锁定',
  '解除锁定',
  '前导码',
  '同步字',
  '帧头错误',
  '长度错误',
  'CRC错误',
  'GOOD',
  '锁定/解析中断',
  '帧超时',
  '搜索超时',
  '接收链不可用',
  'I2S/CDC错误标志出现',
  '削顶开始',
  '窗口开始',
  '窗口结束',
  '帧头通过',
  '进入Payload',
  '进入CRC',
  '解析状态变化',
];

class BerEvidence {
  BerEvidence._(
    this.summary,
    this.events,
    this.windowId,
    this.cycles,
    this.maxEnergy,
    this.faultFlags,
    this.truncated,
  );
  final Map<String, int> summary;
  final List<Map<String, Object?>> events;
  final int windowId, cycles, maxEnergy, faultFlags;
  final bool truncated;
  static int eventCount(Uint8List b) {
    if (b.length != 96 ||
        ascii.decode(b.sublist(0, 4), allowInvalid: true) != 'BO01' ||
        b[8] & 3 != 2 ||
        b[8] & 0xf0 != 0 ||
        b[9] < 2 ||
        b[9] > 32 ||
        b[10] > 31 ||
        b[11] != 32 ||
        (b[9] < 32 && b[10] != b[9])) {
      throw const FormatException('观察窗口未冻结或BO01布局无效');
    }
    return b[9];
  }

  factory BerEvidence.parse(
    Uint8List b,
    List<Uint8List> pages,
    int expectedId,
  ) {
    final count = eventCount(b), d = ByteData.sublistView(b);
    if (d.getUint32(4, Endian.little) != expectedId ||
        pages.length != (count + 1) ~/ 2 ||
        pages.any((p) => p.length != 64)) {
      throw const FormatException('观察窗口ID或事件页数量不符');
    }
    final raw = Uint8List.fromList(pages.expand((p) => p).toList());
    final words = ByteData.sublistView(raw);
    final cycles = d.getUint32(12, Endian.little);
    final counters = <String, int>{
      for (var i = 0; i < berObserverCounterNames.length; i++)
        berObserverCounterNames[i]: d.getUint32(16 + i * 4, Endian.little),
    };
    final overflow = counters['event_overflows']!;
    if ((b[8] & 8 != 0) != (overflow != 0) ||
        d.getUint32(88, Endian.little) > 1 ||
        d.getUint32(92, Endian.little) >> 11 != 0) {
      throw const FormatException('观察摘要越界或截断标志不一致');
    }
    final events = <Map<String, Object?>>[];
    var previous = -1;
    for (var i = 0; i < count; i++) {
      final slot = count == 32 ? (b[10] + i) % 32 : i;
      final at = slot * 32;
      final t = words.getUint32(at, Endian.little);
      final mask = words.getUint32(at + 4, Endian.little);
      if (t < previous ||
          t > cycles ||
          mask == 0 ||
          mask >> 22 != 0 ||
          raw[at + 24] > 6 ||
          raw[at + 25] > 2 ||
          raw[at + 26] > 64 ||
          raw[at + 27] > 1 ||
          words.getUint32(at + 12, Endian.little) > 1 ||
          words.getUint32(at + 20, Endian.little) > 1 ||
          raw[at + 29] > 15 ||
          raw[at + 30] > 3) {
        throw const FormatException('观察事件时间/标志/字段无效');
      }
      previous = t;
      final adjust = raw[at + 30];
      events.add({
        'cycles': t,
        'time_ms': t / 30000.0,
        'event_mask': mask,
        'events': [
          for (var j = 0; j < 22; j++)
            if (mask & (1 << j) != 0) berObserverEventNames[j],
        ],
        'energy': words.getUint64(at + 8, Endian.little),
        'threshold': words.getUint64(at + 16, Endian.little),
        'parser_state': raw[at + 24],
        'symbol_state': raw[at + 25],
        'payload_bytes': raw[at + 26],
        'hard_bit': raw[at + 27],
        'confidence': raw[at + 28],
        'phase': raw[at + 29],
        'timing_adjust': adjust > 1 ? adjust - 4 : adjust,
        'state_flags': raw[at + 31],
      });
    }
    if ((events.last['event_mask'] as int) & (1 << 17) == 0 ||
        (overflow == 0 &&
            (events.first['event_mask'] as int) & (1 << 16) == 0)) {
      throw const FormatException('观察窗口开始/结束证据缺失');
    }
    return BerEvidence._(
      counters,
      events,
      expectedId,
      cycles,
      d.getUint64(84, Endian.little),
      d.getUint32(92, Endian.little),
      overflow != 0,
    );
  }
  Map<String, Object?> diagnose({
    required bool delivered,
    required bool complete,
    required bool aligned,
    required int? payloadErrors,
  }) {
    String code, label;
    if (!complete) {
      code = 'incomplete_window';
      label = '观察窗口或TX未完成，不能判定最终丢包';
    } else if (delivered && aligned && payloadErrors == 0) {
      code = 'delivered';
      label = '正常交付，已对齐Payload无误码';
    } else if (summary['chain_unavailable_cycles']! > 0) {
      code = 'chain_interrupted';
      label = '窗口内接收链曾不可用，检查复位/配置/扫频';
    } else if (summary['samples'] == 0) {
      code = 'no_samples';
      label = '窗口内无解调输入采样';
    } else if (summary['metrics'] == 0) {
      code = 'no_metrics';
      label = '有采样，但没有FSK判决指标';
    } else if (summary['good_frames']! > 0 && !delivered) {
      code = 'good_without_delivery';
      label = '窗口有GOOD，但本包未交付；核对身份及读出链';
    } else if (summary['header_errors']! > 0 || summary['length_errors']! > 0) {
      code = 'header_rejected';
      label = '窗口发生帧头/长度校验失败';
    } else if (summary['crc_errors']! > 0 || (payloadErrors ?? 0) > 0) {
      code = 'frame_bit_errors';
      label = '窗口CRC失败或已对齐Payload存在误码';
    } else if (summary['in_frame_lock_losses']! > 0) {
      code = 'lock_lost_in_frame';
      label = '窗口内帧解析期间锁定/解析被中断';
    } else if (summary['frame_timeouts']! > 0) {
      code = 'frame_timeout';
      label = '窗口内帧解析等待比特超时';
    } else if (summary['syncs']! > 0) {
      code = 'sync_without_delivery';
      label = '窗口识别过同步字，但无完整交付';
    } else if (summary['lock_rises']! > 0) {
      code = 'lock_without_sync';
      label = '窗口出现符号锁定，但未识别同步字';
    } else if (summary['carrier_rises']! > 0) {
      code = 'carrier_without_lock';
      label = '窗口检测到载波，但未形成符号锁定';
    } else if (summary['above_threshold_metrics']! > 0) {
      code = 'energy_without_carrier';
      label = '窗口有超门限能量，但未确认载波';
    } else {
      code = 'below_threshold';
      label = '窗口有采样/指标，但无超门限能量';
    }
    return {
      'code': code,
      'label': label,
      'window_id': windowId,
      'timeline_truncated': truncated,
      'scope': '发送观察窗口内的事件，不等同于已验证包身份；阶段范围不是物理根因',
    };
  }

  Map<String, Object?> toJson() => {
    'window_id': windowId,
    'clock_hz': 30000000,
    'elapsed_cycles': cycles,
    'max_energy': maxEnergy,
    'fault_flags': faultFlags,
    'timeline_truncated': truncated,
    'counters': summary,
    'events': events,
  };
}
