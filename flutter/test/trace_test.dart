import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:short_trans_host/trace_data.dart';
import 'package:short_trans_host/trace_controller.dart';
import 'package:short_trans_host/trace_view.dart';

Uint8List fixture({int mode = 1, int count = 512, bool wrap = false}) {
  final b = Uint8List(64 + 48 * count);
  b.setAll(0, ascii.encode('DTR1'));
  final d = ByteData.sublistView(b);
  b[4] = 1;
  b[5] = 19;
  b[6] = mode;
  b[7] = 12;
  b[8] = 64;
  b[9] = 32;
  d.setUint16(10, 200, Endian.little);
  d.setUint32(12, 400, Endian.little);
  d.setUint32(16, 600, Endian.little);
  d.setUint32(20, 48000, Endian.little);
  d.setUint16(24, 48, Endian.little);
  d.setUint16(26, 48, Endian.little);
  d.setUint16(28, count, Endian.little);
  d.setUint16(30, count - 1, Endian.little);
  d.setUint16(32, 1, Endian.little);
  b[34] = 16;
  b[38] = 6;
  for (var i = 0; i < count; i++) {
    final at = 64 + i * 48;
    final high = (i ~/ 10).isOdd;
    final e0 = mode == 2
        ? (high ? 1200 : 100)
        : (high ? 150 : 900) + (60 * math.sin(i / 2)).round();
    final e1 = mode == 2 ? 0 : (high ? 900 : 150) + (30 * math.cos(i)).round();
    d.setUint32(at, (wrap ? 0xfffffff0 : 0) + i * 48, Endian.little);
    d.setUint32(at + 4, e0, Endian.little);
    d.setUint32(at + 8, e1, Endian.little);
    d.setUint64(at + 12, 50, Endian.little);
    d.setUint64(at + 20, mode == 2 ? 600 : 400, Endian.little);
    d.setInt64(at + 28, mode == 2 ? e0 - 500 : e1 - e0, Endian.little);
    d.setUint32(
      at + 36,
      (high ? 17 : 0) | 4 | (i % 10 == 5 ? 8 : 0) | (i == count - 1 ? 512 : 0),
      Endian.little,
    );
    b[at + 40] = high ? 160 : 150;
    b[at + 41] = 5;
    b[at + 43] = i % 10 == 5 ? 1 : 0;
    b[at + 44] = 32;
    b[at + 45] = 64;
    b[at + 46] = 12;
    b[at + 47] = mode;
  }
  return b;
}

void main() {
  test('CRC known vector, signed 33-bit domain and sample rollover', () {
    expect(traceCrc16(ascii.encode('123456789')), 0x29b1);
    final b = fixture(count: 2, wrap: true);
    ByteData.sublistView(b).setUint64(64 + 12, 0x1ffffffff, Endian.little);
    ByteData.sublistView(b).setInt64(64 + 28, -4294967295, Endian.little);
    final c = TraceCapture.parse(b);
    expect(c.records.first.noise, 8589934591);
    expect(c.records.first.soft, -4294967295);
    expect(c.timeMs(c.records.first), -1);
    expect(c.toCsv(), contains('-4294967295'));
  });
  test(
    'reject incompatible, truncated, mixed configuration and discontinuous records',
    () {
      for (final edit in <void Function(Uint8List)>[
        (b) => b[4] = 2,
        (b) => b[5] = 18,
        (b) => b[6] = 3,
        (b) => b[26] = 32,
        (b) => b[64 + 47] = 2,
        (b) => b[64 + 48] = 1,
        (b) => b[30] = 255,
      ]) {
        final b = fixture(count: 2);
        edit(b);
        expect(() => TraceCapture.parse(b), throwsFormatException);
      }
      expect(
        () => TraceCapture.parse(fixture(count: 2).sublist(0, 100)),
        throwsFormatException,
      );
      expect(() => decodeCobs([5, 1]), throwsFormatException);
      expect(() => TraceBlock.parse(Uint8List(12)), throwsFormatException);
    },
  );
  final wireFile = File('../_codex/trace/uart_capture.bin');
  test(
    'RTL SPI capture -> native ARM framing -> fragmented Dart serial parser',
    () {
      final lines = <String>[], blocks = <TraceBlock>[];
      final decoder = TraceSerialDecoder(
        onLine: lines.add,
        onBlock: (b) => blocks.add(TraceBlock.parse(b)),
      );
      final wire = wireFile.readAsBytesSync();
      decoder.add(ascii.encode('OK PONG\r\n'));
      for (final b in wire) {
        decoder.add([b]);
      }
      decoder.add(ascii.encode('OK TRACE ACK\r\n'));
      expect(lines, ['OK PONG', 'OK TRACE ACK']);
      expect(blocks.length, 3);
      final bytes = BytesBuilder();
      var offset = 0;
      for (final block in blocks) {
        expect(block.id, 1);
        expect(block.offset, offset);
        bytes.add(block.payload);
        offset += block.payload.length;
      }
      final capture = TraceCapture.parse(bytes.takeBytes());
      expect(capture.records.map((r) => r.energy0), [
        7,
        8,
        9,
        10,
        11,
        12,
        13,
        14,
      ]);
      expect(capture.triggerIndex, 5);
      expect(capture.records.first.noise, 4294967297);
      expect(capture.records.first.soft, -7);
      expect(capture.timeMs(capture.records.first), -5);
    },
    skip: !wireFile.existsSync(),
  );
  test('controller retries individual blocks and verifies final id', () async {
    final raw = fixture(count: 2);
    var reads = 0;
    final ctl = TraceController(
      command: (cmd) async => cmd == 'TRACE STATUS'
          ? 'OK TRACE status=6 id=1 count=2 trigger=1 depth=512'
          : 'OK TRACE ACK',
      readBlock: (id, offset, length) async {
        if (++reads == 1) throw const FormatException('CRC');
        return raw.sublist(offset, offset + length);
      },
      changed: () {},
    );
    await ctl.start(16, 128);
    expect(ctl.capture?.records.length, 2);
    expect(reads, 2);
    expect(ctl.running, false);
    var statuses = 0;
    final changed = TraceController(
      command: (cmd) async => cmd == 'TRACE STATUS'
          ? 'OK TRACE status=6 id=${++statuses == 1 ? '1' : '2'} count=2 trigger=1 depth=512'
          : 'OK TRACE ACK',
      readBlock: (id, offset, length) async =>
          raw.sublist(offset, offset + length),
      changed: () {},
    );
    await changed.start(16, 128);
    expect(changed.capture, isNull);
    expect(changed.status, contains('编号变化'));
  });
  for (final mode in [1, 2]) {
    for (final width in [1360.0, 390.0]) {
      testWidgets('trace layout mode=$mode width=$width', (tester) async {
        tester.view.physicalSize = Size(width, 1000);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final font = File('C:/Windows/Fonts/msyh.ttc');
        if (font.existsSync()) {
          final loader = FontLoader('TraceTest')
            ..addFont(
              Future.value(ByteData.sublistView(font.readAsBytesSync())),
            );
          await loader.load();
        }
        final ctl = TraceController(
          command: (_) async => 'OK TRACE ACK',
          readBlock: (_, _, _) async => Uint8List(0),
          changed: () {},
        );
        ctl.capture = TraceCapture.parse(fixture(mode: mode));
        ctl.status = '仿真测试数据（非板上实测）';
        final key = GlobalKey();
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData(fontFamily: 'TraceTest', useMaterial3: true),
            home: RepaintBoundary(
              key: key,
              child: Scaffold(
                appBar: AppBar(title: const Text('解调观测')),
                body: TraceView(controller: ctl, connected: true),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tester.runAsync(() async {
          final boundary =
              key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
          final image = await boundary.toImage(pixelRatio: 1);
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          final path = '../_codex/trace/ui_mode${mode}_${width.round()}.png';
          await File(path).writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
        await tester.drag(find.byType(ListView).first, const Offset(0, -750));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tester.runAsync(() async {
          final boundary =
              key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
          final image = await boundary.toImage(pixelRatio: 1);
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          await File(
            '../_codex/trace/ui_lower_${mode}_${width.round()}.png',
          ).writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
      });
    }
  }
}
