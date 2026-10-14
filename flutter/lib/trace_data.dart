import 'dart:convert';
import 'dart:typed_data';

int traceCrc16(List<int> bytes) {
  var crc = 0xffff;
  for (final b in bytes) {
    crc ^= b << 8;
    for (var j = 0; j < 8; j++) {
      crc = ((crc & 0x8000) != 0 ? (crc << 1) ^ 0x1021 : crc << 1) & 0xffff;
    }
  }
  return crc;
}

Uint8List decodeCobs(List<int> bytes) {
  final out = <int>[];
  var i = 0;
  while (i < bytes.length) {
    final code = bytes[i++];
    if (code == 0 || i + code - 1 > bytes.length) {
      throw const FormatException('Invalid COBS block');
    }
    out.addAll(bytes.sublist(i, i + code - 1));
    i += code - 1;
    if (code != 255 && i < bytes.length) out.add(0);
  }
  return Uint8List.fromList(out);
}

// Bounded text/zero-delimited binary demultiplexer; corrupt blocks time out
// and are retried using their explicit capture id and byte offset.
class TraceSerialDecoder {
  TraceSerialDecoder({required this.onLine, required this.onBlock});
  final void Function(String) onLine;
  final void Function(Uint8List) onBlock;
  final _text = <int>[];
  final _binary = <int>[];
  bool _inBinary = false;
  bool _discard = false;
  void clear() {
    _text.clear();
    _binary.clear();
    _inBinary = false;
    _discard = false;
  }

  void add(List<int> bytes) {
    for (final b in bytes) {
      if (b == 0) {
        if (_inBinary && _binary.isNotEmpty && !_discard) {
          try {
            onBlock(decodeCobs(_binary));
          } on FormatException {
            /* retry */
          }
        }
        _inBinary = !_inBinary;
        _binary.clear();
        _text.clear();
        _discard = false;
      } else if (_inBinary) {
        if (_binary.length < 1024) {
          _binary.add(b);
        } else {
          _discard = true;
        }
      } else if (b == 10 || b == 13) {
        if (_text.isNotEmpty && !_discard) onLine(ascii.decode(_text));
        _text.clear();
        _discard = false;
      } else if (b >= 32 && b < 127 && _text.length < 2048) {
        _text.add(b);
      } else {
        _discard = true;
      }
    }
  }
}

class TraceBlock {
  TraceBlock(this.id, this.offset, this.payload);
  final int id, offset;
  final Uint8List payload;
  factory TraceBlock.parse(Uint8List bytes) {
    if (bytes.length < 12 ||
        ascii.decode(bytes.sublist(0, 4), allowInvalid: true) != 'DTB1') {
      throw const FormatException('Invalid trace block');
    }
    final d = ByteData.sublistView(bytes);
    final n = d.getUint16(8, Endian.little);
    if (n < 1 ||
        n > 192 ||
        bytes.length != n + 12 ||
        traceCrc16(bytes.sublist(0, bytes.length - 2)) !=
            d.getUint16(bytes.length - 2, Endian.little)) {
      throw const FormatException('Trace length/CRC mismatch');
    }
    return TraceBlock(
      d.getUint16(4, Endian.little),
      d.getUint16(6, Endian.little),
      bytes.sublist(10, 10 + n),
    );
  }
}

class TraceRecord {
  TraceRecord(ByteData d, int at)
    : sample = d.getUint32(at, Endian.little),
      energy0 = d.getUint32(at + 4, Endian.little),
      energy1 = d.getUint32(at + 8, Endian.little),
      noise = d.getUint64(at + 12, Endian.little),
      threshold = d.getUint64(at + 20, Endian.little),
      soft = d.getInt64(at + 28, Endian.little),
      flags = d.getUint32(at + 36, Endian.little),
      confidence = d.getUint8(at + 40),
      phase = d.getUint8(at + 41),
      timing = d.getUint8(at + 42) >= 2
          ? d.getUint8(at + 42) - 4
          : d.getUint8(at + 42),
      bitCount = d.getUint8(at + 43),
      confidenceThreshold = d.getUint8(at + 44);
  final int sample, energy0, energy1, noise, threshold, soft, flags;
  final int confidence, phase, timing, bitCount, confidenceThreshold;
  bool flag(int bit) => (flags & (1 << bit)) != 0;
  String get events => [
    if (flag(5)) 'PREAMBLE',
    if (flag(6)) 'LOCK_LOST',
    if (flag(7)) 'SYNC',
    if (flag(8)) 'GOOD',
    if (flag(9)) 'CRC_ERROR',
    if (flag(10)) 'HEADER_ERROR',
    if (flag(11)) 'LENGTH_ERROR',
    if (flag(12)) 'TIMEOUT',
    if (flag(13)) 'SEARCH_TIMEOUT',
    if (flag(14)) 'CLIP',
    if (flag(17)) 'REPLAY',
  ].join(' | ');
}

class TraceCapture {
  TraceCapture._(this.raw, this.header, this.records);
  final Uint8List raw;
  final ByteData header;
  final List<TraceRecord> records;
  int get mode => header.getUint8(6);
  int get low => header.getUint32(12, Endian.little);
  int get high => header.getUint32(16, Endian.little);
  int get sampleRate => header.getUint32(20, Endian.little);
  int get triggerIndex => header.getUint16(30, Endian.little);
  int get id => header.getUint16(32, Endian.little);
  bool get interrupted => (header.getUint8(38) & 8) != 0;
  int get reference => triggerIndex < records.length
      ? records[triggerIndex].sample
      : records.isEmpty
      ? 0
      : records.first.sample;
  double timeMs(TraceRecord r) {
    var delta = (r.sample - reference) & 0xffffffff;
    if (delta >= 0x80000000) delta -= 0x100000000;
    return delta * 1000 / sampleRate;
  }

  factory TraceCapture.parse(Uint8List raw) {
    if (raw.length < 64 ||
        ascii.decode(raw.sublist(0, 4), allowInvalid: true) != 'DTR1') {
      throw const FormatException('Invalid capture header');
    }
    final d = ByteData.sublistView(raw);
    final count = d.getUint16(28, Endian.little);
    final trigger = d.getUint16(30, Endian.little);
    if (d.getUint8(4) != 1 ||
        d.getUint8(5) != 0x13 ||
        ![1, 2].contains(d.getUint8(6)) ||
        d.getUint32(20, Endian.little) != 48000 ||
        d.getUint16(24, Endian.little) != 48 ||
        d.getUint16(26, Endian.little) != 48 ||
        count > 512 ||
        raw.length != 64 + count * 48 ||
        (trigger != 65535 && trigger >= count) ||
        (d.getUint8(38) & 4) == 0) {
      throw const FormatException('Unsupported/incomplete capture');
    }
    final records = List.generate(count, (i) => TraceRecord(d, 64 + i * 48));
    for (var i = 0; i < count; i++) {
      final at = 64 + i * 48;
      if (d.getUint8(at + 47) != d.getUint8(6) ||
          d.getUint8(at + 46) != d.getUint8(7) ||
          d.getUint8(at + 45) != d.getUint8(8) ||
          d.getUint8(at + 44) != d.getUint8(9) ||
          (i > 0 &&
              ((records[i].sample - records[i - 1].sample) & 0xffffffff) !=
                  48)) {
        throw const FormatException(
          'Trace configuration/timestamp discontinuity',
        );
      }
    }
    return TraceCapture._(Uint8List.fromList(raw), d, records);
  }
  String toCsv() {
    final rows = <String>[
      '# format=1,fpga_fw=19,capture_id=$id,mode=$mode,rate=$sampleRate,low=$low,high=$high,interrupted=$interrupted',
      '# config_bytes=${raw.sublist(6, 20).join(' ')}',
      'sample,time_ms,energy0,energy1,noise,threshold,soft,confidence,confidence_threshold,hard_bit,locked,sampled_bit,bit_count,phase,timing,flags,events',
      for (final r in records)
        [
          r.sample,
          timeMs(r),
          r.energy0,
          r.energy1,
          r.noise,
          r.threshold,
          r.soft,
          r.confidence,
          r.confidenceThreshold,
          r.flag(0) ? 1 : 0,
          r.flag(2) ? 1 : 0,
          r.flag(3) ? (r.flag(4) ? 1 : 0) : '',
          r.bitCount,
          r.phase,
          r.timing,
          r.flags,
          r.events,
        ].join(','),
    ];
    return '${rows.join('\r\n')}\r\n';
  }
}
