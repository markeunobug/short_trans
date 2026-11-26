import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:short_trans_host/ber_data.dart';

(Uint8List, List<Uint8List>) evidenceFixture(
  int id, {
  Map<String, int> counters = const {},
  bool overflow = false,
}) {
  final b = Uint8List(96), d = ByteData.sublistView(b);
  b.setAll(0, ascii.encode('BO01'));
  d.setUint32(4, id, Endian.little);
  b[8] = overflow ? 14 : 6;
  b[9] = overflow ? 32 : 2;
  b[10] = overflow ? 3 : 2;
  b[11] = 32;
  d.setUint32(12, 30000000, Endian.little);
  for (var i = 0; i < berObserverCounterNames.length; i++) {
    d.setUint32(
      16 + i * 4,
      counters[berObserverCounterNames[i]] ?? 0,
      Endian.little,
    );
  }
  if (overflow) d.setUint32(80, 3, Endian.little);
  d.setUint64(84, 0x100000001, Endian.little);
  final pages = List.generate(overflow ? 16 : 1, (_) => Uint8List(64));
  final bytes = Uint8List(pages.length * 64), w = ByteData.sublistView(bytes);
  for (var i = 0; i < b[9]; i++) {
    final slot = overflow ? (3 + i) % 32 : i, at = slot * 32;
    w.setUint32(at, i * 100, Endian.little);
    w.setUint32(
      at + 4,
      i == b[9] - 1
          ? 1 << 17
          : i == 0 && !overflow
          ? 1 << 16
          : 1,
      Endian.little,
    );
    w.setUint64(at + 8, 0x100000001, Endian.little);
    w.setUint64(at + 16, 0x100000020, Endian.little);
    bytes[at + 28] = 99;
    bytes[at + 29] = 7;
    bytes[at + 30] = 3;
    bytes[at + 31] = 8;
  }
  for (var i = 0; i < pages.length; i++) {
    pages[i].setAll(0, bytes.sublist(i * 64, (i + 1) * 64));
  }
  return (b, pages);
}

void main() {
  final rtlPath = Platform.environment['BER_RTL_FIXTURES'];
  test(
    'decodes actual ModelSim BO01 and event RAM through production Dart parser',
    () {
      Uint8List readHex(String name) => Uint8List.fromList(
        File('$rtlPath/$name')
            .readAsLinesSync()
            .where((v) => v.trim().isNotEmpty)
            .map((v) => int.parse(v.trim(), radix: 16))
            .toList(),
      );
      final b = readHex('observer_summary.hex'),
          raw = readHex('observer_events.hex');
      final count = BerEvidence.eventCount(b);
      final pages = [
        for (var i = 0; i < (count + 1) ~/ 2; i++)
          Uint8List.fromList(raw.sublist(i * 64, (i + 1) * 64)),
      ];
      final e = BerEvidence.parse(b, pages, 2);
      expect(e.summary['header_errors'], 1);
      expect(e.summary['in_frame_lock_losses'], 1);
      expect(e.summary['good_frames'], 1);
      expect(e.maxEnergy, 0x100000012);
      expect(
        e.events.any((x) => (x['events'] as List).contains('帧头通过')),
        isTrue,
      );
      expect(
        e.events.any(
          (x) =>
              (x['events'] as List).contains('进入Payload') &&
              x['payload_bytes'] == 5,
        ),
        isTrue,
      );
      expect(
        e.events.any((x) => (x['events'] as List).contains('进入CRC')),
        isTrue,
      );
      expect(e.events.first['events'], contains('窗口开始'));
      expect(e.events.last['events'], contains('窗口结束'));
      expect(
        e.events.any((x) => (x['events'] as List).contains('帧头错误')),
        isTrue,
      );
      expect(e.events.any((x) => x['timing_adjust'] == -1), isTrue);
    },
    skip: rtlPath == null
        ? 'set BER_RTL_FIXTURES to the ModelSim output directory'
        : false,
  );

  String diagnose(
    Map<String, int> counters, {
    bool delivered = false,
    bool complete = true,
    bool aligned = false,
    int? errors,
  }) {
    final f = evidenceFixture(8, counters: counters);
    return BerEvidence.parse(f.$1, f.$2, 8).diagnose(
          delivered: delivered,
          complete: complete,
          aligned: aligned,
          payloadErrors: errors,
        )['code']
        as String;
  }

  test(
    'localizes no sync by earliest observed stages, with no packet identity claim',
    () {
      expect(diagnose({}), 'no_samples');
      expect(diagnose({'samples': 100}), 'no_metrics');
      expect(diagnose({'samples': 100, 'metrics': 10}), 'below_threshold');
      expect(
        diagnose({'samples': 100, 'metrics': 10, 'above_threshold_metrics': 2}),
        'energy_without_carrier',
      );
      expect(
        diagnose({'samples': 100, 'metrics': 10, 'carrier_rises': 1}),
        'carrier_without_lock',
      );
      expect(
        diagnose({'samples': 100, 'metrics': 10, 'lock_rises': 1}),
        'lock_without_sync',
      );
      expect(
        diagnose({'samples': 100, 'metrics': 10, 'syncs': 1}),
        'sync_without_delivery',
      );
    },
  );
  test(
    'normal tail lock loss does not invalidate a delivered aligned packet',
    () {
      expect(
        diagnose(
          {'samples': 100, 'metrics': 10, 'in_frame_lock_losses': 0},
          delivered: true,
          aligned: true,
          errors: 0,
        ),
        'delivered',
      );
      expect(
        diagnose({'samples': 100, 'metrics': 10, 'in_frame_lock_losses': 1}),
        'lock_lost_in_frame',
      );
      expect(
        diagnose({'samples': 100, 'metrics': 10, 'header_errors': 1}),
        'header_rejected',
      );
      expect(
        diagnose({'samples': 100, 'metrics': 10, 'crc_errors': 1}),
        'frame_bit_errors',
      );
      expect(
        diagnose({'samples': 100, 'metrics': 10, 'good_frames': 1}),
        'good_without_delivery',
      );
      expect(diagnose({'chain_unavailable_cycles': 1}), 'chain_interrupted');
      expect(diagnose({}, complete: false), 'incomplete_window');
    },
  );
  test('strict frozen identity/CRC envelope layout and exact 33bit energy', () {
    final f = evidenceFixture(7);
    final e = BerEvidence.parse(f.$1, f.$2, 7);
    expect(e.maxEnergy, 0x100000001);
    expect(e.events.first['energy'], 0x100000001);
    expect(e.events.first['timing_adjust'], -1);
    expect(() => BerEvidence.parse(f.$1, f.$2, 8), throwsFormatException);
    expect(() => BerEvidence.parse(f.$1, [], 7), throwsFormatException);
    for (final at in [0, 8, 9, 10, 11, 88, 95]) {
      final b = Uint8List.fromList(f.$1);
      b[at] ^= 128;
      expect(
        () => BerEvidence.parse(b, f.$2, 7),
        throwsFormatException,
        reason: 'offset $at',
      );
    }
    final corrupt = Uint8List.fromList(f.$2.first)..[6] = 0;
    expect(() => BerEvidence.parse(f.$1, [corrupt], 7), throwsFormatException);
  });
  test(
    'wrapped timeline stays chronological and explicitly marks overwritten evidence',
    () {
      final f = evidenceFixture(9, overflow: true);
      final e = BerEvidence.parse(f.$1, f.$2, 9);
      expect(e.truncated, true);
      expect(e.events.length, 32);
      expect(e.events.first['cycles'], 0);
      expect(e.events.last['cycles'], 3100);
    },
  );
}
