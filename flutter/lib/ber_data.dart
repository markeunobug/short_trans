import 'dart:convert';
import 'dart:typed_data';
import 'ber_evidence.dart';
export 'ber_evidence.dart';

int berCrc16(List<int> bytes) {
  var crc = 0xffff;
  for (final b in bytes) {
    crc ^= b << 8;
    for (var i = 0; i < 8; i++) {
      crc = ((crc & 0x8000) != 0 ? (crc << 1) ^ 0x1021 : crc << 1) & 0xffff;
    }
  }
  return crc;
}

int berCrc8(List<int> bytes) {
  var crc = 0;
  for (final b in bytes) {
    crc ^= b;
    for (var i = 0; i < 8; i++) {
      crc = ((crc & 128) != 0 ? (crc << 1) ^ 7 : crc << 1) & 255;
    }
  }
  return crc;
}

int berCrc32(List<int> bytes) {
  var crc = 0xffffffff;
  for (final b in bytes) {
    crc ^= b;
    for (var i = 0; i < 8; i++) {
      crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xedb88320 : crc >> 1;
    }
  }
  return (crc ^ 0xffffffff) & 0xffffffff;
}

String berHex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join().toUpperCase();
Uint8List berUnhex(String text) {
  if (text.length.isOdd || !RegExp(r'^[0-9a-fA-F]*$').hasMatch(text)) {
    throw const FormatException('HEX 长度或字符无效');
  }
  return Uint8List.fromList([
    for (var i = 0; i < text.length; i += 2)
      int.parse(text.substring(i, i + 2), radix: 16),
  ]);
}

Uint8List berPayload(int batch, int sequence) {
  if (batch < 0 ||
      batch > 0xffffffff ||
      sequence < 0 ||
      sequence > 0xffffffff) {
    throw const FormatException('批次号和包号必须为 uint32');
  }
  final bytes = Uint8List(32);
  final d = ByteData.sublistView(bytes);
  d.setUint32(0, batch, Endian.big);
  d.setUint32(4, sequence, Endian.big);
  d.setUint32(8, berCrc32(bytes.sublist(0, 8)), Endian.big);
  var state = (batch ^ sequence ^ 0x9e3779b9) & 0xffffffff;
  for (var i = 12; i < 32; i++) {
    state ^= (state << 13) & 0xffffffff;
    state ^= state >> 17;
    state ^= (state << 5) & 0xffffffff;
    state &= 0xffffffff;
    bytes[i] = state & 255;
  }
  return bytes;
}

Uint8List berTransport(String line, String name, int length) {
  final match = RegExp(
    '^OK BER $name ([0-9A-Fa-f]{${length * 2}}) crc=([0-9A-Fa-f]{4})\$',
  ).firstMatch(line);
  if (match == null) throw const FormatException('BER 响应格式错误');
  final bytes = berUnhex(match[1]!);
  if (berCrc16(bytes) != int.parse(match[2]!, radix: 16)) {
    throw const FormatException('BER 串口传输 CRC 错误');
  }
  return bytes;
}

Map<String, String> berFields(String line) => {
  for (final m in RegExp(r'(\w+)=([^\s]+)').allMatches(line)) m[1]!: m[2]!,
};

class BerCapture {
  BerCapture._(this.bytes);
  final Uint8List bytes;
  ByteData get d => ByteData.sublistView(bytes);
  int get id => d.getUint32(4, Endian.little);
  int get bits => d.getUint16(8, Endian.little);
  int get flags => bytes[10];
  bool get complete => bits == 328 && flags & 1 != 0;
  Uint8List get raw => bytes.sublist(16, 57);
  Uint8List get payload => bytes.sublist(23, 55);
  (int, int)? get identity {
    if (!complete || flags & 0x50 != 0x50) return null;
    final p = payload;
    final pd = ByteData.sublistView(p);
    final batch = pd.getUint32(0, Endian.big);
    final sequence = pd.getUint32(4, Endian.big);
    if (berCrc32(p.sublist(0, 8)) != pd.getUint32(8, Endian.big) ||
        raw[1] != (sequence & 255)) {
      return null;
    }
    return (batch, sequence);
  }

  factory BerCapture.parse(Uint8List source) {
    if (source.length != 64 ||
        ascii.decode(source.sublist(0, 4), allowInvalid: true) != 'BR01') {
      throw const FormatException('BER 记录签名错误');
    }
    final c = BerCapture._(Uint8List.fromList(source));
    final count = source[11];
    final term = c.flags & 15;
    if (c.id == 0 ||
        c.bits > 328 ||
        count != (c.bits + 7) ~/ 8 ||
        c.flags & 128 != 0 ||
        ![1, 2, 4, 8].contains(term) ||
        (term == 1) != (c.bits == 328)) {
      throw const FormatException('BER 位数/结束标志错误');
    }
    if (source.sublist(16 + count).any((v) => v != 0) ||
        (c.bits % 8 != 0 &&
            source[16 + count - 1] & ((1 << (8 - c.bits % 8)) - 1) != 0)) {
      throw const FormatException('BER 补零错误');
    }
    final raw = c.raw;
    if ((c.flags & 16 != 0) !=
            (c.bits >= 32 && berCrc8(raw.sublist(0, 3)) == raw[3]) ||
        (c.flags & 32 != 0) !=
            (c.complete &&
                berCrc16(raw.sublist(0, 39)) == (raw[39] << 8 | raw[40])) ||
        (c.flags & 64 != 0) != (c.complete && raw[0] == 0x20 && raw[2] == 32)) {
      throw const FormatException('BER 头/CRC 标志与数据不一致');
    }
    return c;
  }

  int errors(List<int> expected) {
    var total = 0;
    for (var i = 0; i < 32; i++) {
      var v = expected[i] ^ payload[i];
      while (v != 0) {
        v &= v - 1;
        total++;
      }
    }
    return total;
  }
}

Map<String, int> berStatus(Uint8List b) {
  if (b.length != 32 ||
      ascii.decode(b.sublist(0, 4), allowInvalid: true) != 'BS01' ||
      b[6] != 8 ||
      b[7] != 64 ||
      b[5] > 8 ||
      b[4] & 0xe0 != 0 ||
      (b[4] & 4 != 0) != (b[5] > 0) ||
      (b[4] & 8 != 0) != (b[5] == 8)) {
    throw const FormatException('BER 状态快照无效');
  }
  final d = ByteData.sublistView(b);
  return {
    'state': b[4],
    'count': b[5],
    for (final (i, name) in [
      'started',
      'dropped',
      'committed',
      'protocol_errors',
      'popped',
      'missed_sync',
    ].indexed)
      name: d.getUint32(8 + i * 4, Endian.little),
  };
}

Map<String, int> berHealth(Uint8List b) {
  if (b.length != 20 ||
      ascii.decode(b.sublist(0, 4), allowInvalid: true) != 'BH01' ||
      b[4] != 0xa7 ||
      b.sublist(18).any((v) => v != 0)) {
    throw const FormatException('BER 健康寄存器无效');
  }
  final d = ByteData.sublistView(b);
  return {
    'firmware': b[5],
    'status0': b[6],
    'error_flags': b[7],
    'frame_count': b[8],
    'fifo_bytes': b[12] | ((b[13] & 1) << 8),
    'good_count': d.getUint16(14, Endian.little),
    'crc_error_count': d.getUint16(16, Endian.little),
  };
}

class BerAttempt {
  BerAttempt(this.sequence, this.payload);
  final int sequence;
  final Uint8List payload;
  String tx = 'pending';
  bool windowComplete = false;
  double elapsed = 0;
  BerEvidence? evidence;
  String? evidenceError;
  Map<String, Object?>? stageDiagnosis;
  Map<String, Object?> toJson() => {
    'sequence': sequence,
    'payload': berHex(payload),
    'tx': tx,
    'rx_window_complete': windowComplete,
    'elapsed_s': elapsed,
    'stage_diagnosis': stageDiagnosis,
    'stage_evidence': evidence?.toJson(),
    'stage_evidence_error': evidenceError,
  };
}

class BerLedger {
  BerLedger(this.batch);
  final int batch;
  final attempts = <int, BerAttempt>{};
  final delivered = <int>{};
  final captures = <int, BerCapture>{};
  final seen = <int, String>{};
  int duplicateReads = 0, duplicateCaptures = 0, unaligned = 0, partial = 0;
  int transportErrors = 0,
      spiErrors = 0,
      crcTransportErrors = 0,
      invalidNormal = 0;
  Map<String, int> diagnostic = {}, healthInitial = {}, healthFinal = {};
  Map<String, String> rxInitial = {}, rxFinal = {};
  double elapsed = 0;

  bool delivery(Uint8List p) {
    if (p.length != 32) return false;
    final d = ByteData.sublistView(p);
    if (d.getUint32(0, Endian.big) != batch) return false;
    final seq = d.getUint32(4, Endian.big),
        a = attempts[d.getUint32(4, Endian.big)];
    if (a == null || berHex(p) != berHex(a.payload)) {
      invalidNormal++;
      return false;
    }
    if (!delivered.add(seq)) {
      duplicateReads++;
      return false;
    }
    return true;
  }

  bool capture(BerCapture c) {
    final encoded = berHex(c.bytes);
    if (seen.containsKey(c.id)) {
      if (seen[c.id] != encoded) throw StateError('相同 capture ID 的记录内容变化');
      duplicateCaptures++;
      return false;
    }
    seen[c.id] = encoded;
    if (!c.complete) partial++;
    final identity = c.identity;
    if (identity == null ||
        identity.$1 != batch ||
        !attempts.containsKey(identity.$2)) {
      unaligned++;
      return false;
    }
    if (captures.containsKey(identity.$2)) {
      duplicateCaptures++;
      return false;
    }
    captures[identity.$2] = c;
    return true;
  }

  Map<String, Object?> get report {
    final complete = attempts.values
        .where((a) => a.tx == 'complete')
        .map((a) => a.sequence)
        .toSet();
    final compared = complete.intersection(captures.keys.toSet());
    final good = complete.intersection(delivered).length;
    final unfinished = complete
        .where((s) => !attempts[s]!.windowComplete)
        .length;
    final errors = compared.fold(
      0,
      (sum, s) => sum + captures[s]!.errors(attempts[s]!.payload),
    );
    return {
      'batch': batch,
      'tx_attempted': attempts.length,
      'tx_completed': complete.length,
      'tx_unresolved': attempts.values
          .where((a) => a.tx == 'unresolved' || a.tx == 'pending')
          .length,
      'delivered_unique': good,
      'matched_unique': compared.length,
      'per': complete.isEmpty || unfinished > 0
          ? null
          : (complete.length - good) / complete.length,
      'ber': compared.isEmpty ? null : errors / (compared.length * 256),
      'coverage': complete.isEmpty ? null : compared.length / complete.length,
      'payload_bit_errors': errors,
      'compared_payload_bits': compared.length * 256,
      'effective_throughput_bps': elapsed > 0 ? good * 256 / elapsed : null,
      'measurement_elapsed_s': elapsed,
      'rx_windows_unfinished': unfinished,
      'duplicate_deliveries': duplicateReads,
      'duplicate_captures': duplicateCaptures,
      'unaligned_records': unaligned,
      'partial_records': partial,
      'normal_invalid_observations': invalidNormal,
      'transport_errors': transportErrors,
      'spi_read_errors': spiErrors,
      'serial_crc_or_format_errors': crcTransportErrors,
      'capture_drops': diagnostic['dropped'] ?? 0,
      'missed_sync': diagnostic['missed_sync'] ?? 0,
      'diagnostic_protocol_errors': diagnostic['protocol_errors'] ?? 0,
      'completed_without_aligned_capture': complete.difference(compared).length,
      'delivery_without_capture': complete
          .intersection(delivered)
          .difference(compared)
          .length,
      'capture_without_delivery': compared.difference(delivered).length,
      'fpga_health_baseline': healthInitial,
      'fpga_health_final': healthFinal,
      'rx_status_baseline': rxInitial,
      'rx_status_final': rxFinal,
      'normal_fifo_overflow_final': healthFinal.isEmpty
          ? null
          : healthFinal['error_flags']! & 16 != 0,
      'normal_fifo_overflow_exact_count': null,
      'statistic_scope': '同步后、身份校验通过的完整32字节Payload；身份错误被排除，有选择偏差，须同时查看coverage',
    };
  }

  Map<String, Object?> toJson() => {
    'failure_evidence': [
      for (final a in attempts.values)
        if (a.stageDiagnosis?['code'] != 'delivered') a.toJson(),
    ],
    'report': report,
    'attempts': {for (final a in attempts.values) '${a.sequence}': a.toJson()},
  };
}
