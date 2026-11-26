import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:short_trans_host/ber_controller.dart';
import 'package:short_trans_host/ber_data.dart';
import 'package:short_trans_host/ber_view.dart';
import 'ber_evidence_test.dart' show evidenceFixture;

void main() {
  testWidgets('failed windows are visible and expand their stage timeline', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 1100);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.runAsync(() async {
      final font = FontLoader('EvidenceChinese')
        ..addFont(
          Future.value(
            ByteData.sublistView(
              File('C:/Windows/Fonts/msyh.ttc').readAsBytesSync(),
            ),
          ),
        );
      await font.load();
    });
    final c = BerController(
      command: (tx, cmd) async => 'ERR test must not send',
      emergencyStop: (tx, cmd) async {},
      changed: () {},
      auditFactory: () =>
          throw StateError('widget test must not open serial audit'),
    );
    final ledger = BerLedger(123), a = BerAttempt(38, berPayload(123, 38));
    a.tx = 'complete';
    a.windowComplete = true;
    final f = evidenceFixture(
      39,
      counters: {
        'samples': 300000,
        'metrics': 6000,
        'carrier_rises': 1,
        'preambles': 1,
        'lock_rises': 1,
        'bits': 16,
      },
    );
    a.evidence = BerEvidence.parse(f.$1, f.$2, 39);
    a.stageDiagnosis = a.evidence!.diagnose(
      delivered: false,
      complete: true,
      aligned: false,
      payloadErrors: null,
    );
    ledger.attempts[38] = a;
    c.ledger = ledger;
    c.state = 'complete';
    c.progress = 50;
    c.target = 50;
    c.message = '测试完成：50/50包；证据已保存';
    final key = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(
        key: key,
        child: MaterialApp(
          theme: ThemeData(fontFamily: 'EvidenceChinese'),
          home: Scaffold(
            appBar: AppBar(title: const Text('FSK 误码率调试')),
            body: BerView(
              controller: c,
              connected: true,
              canStart: true,
              rxConnected: true,
              connections: const SizedBox(
                height: 20,
                child: Text('TX COM29 / RX COM6'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('逐包故障定位 / 自动证据'));
    await tester.pumpAndSettle();
    expect(find.textContaining('窗口出现符号锁定，但未识别同步字'), findsOneWidget);
    await tester.tap(find.textContaining('第39包 / seq=38'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.textContaining('0.000 ms'));
    await tester.pumpAndSettle();
    expect(find.textContaining('carrier_rises=1'), findsOneWidget);
    expect(tester.takeException(), isNull);
    final folder = Platform.environment['BER_UI_OUTPUT'];
    if (folder != null) {
      await tester.runAsync(() async {
        final image =
            await (key.currentContext!.findRenderObject()
                    as RenderRepaintBoundary)
                .toImage();
        final ByteData? bytes = await image.toByteData(
          format: ui.ImageByteFormat.png,
        );
        File(
          '$folder/evidence_panel.png',
        ).writeAsBytesSync(bytes!.buffer.asUint8List());
      });
    }
  });
}
