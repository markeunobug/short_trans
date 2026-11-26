import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:short_trans_host/main.dart';

void main() {
  testWidgets(
    'connection cards fit unresolved status and selected COM at narrow widths',
    (tester) async {
      tester.view.physicalSize = const Size(1000, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      for (final width in [280.0, 350.0, 700.0]) {
        for (final status in ['已连接', '响应未决，请重连']) {
          await tester.pumpWidget(
            MaterialApp(
              home: Scaffold(
                body: Align(
                  alignment: Alignment.topLeft,
                  child: SizedBox(
                    width: width,
                    child: ConnectionCard(
                      ports: const ['COM6', 'COM29'],
                      selectedPort: 'COM29',
                      connected: status == '已连接',
                      status: status,
                      onPortChanged: (_) {},
                      onToggle: () {},
                    ),
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull, reason: '$width / $status');
          expect(find.text(status), findsOneWidget);
        }
      }
    },
  );
  test('parses RX status fields and readable meanings', () {
    final status = RxDeviceStatus(
      parseFields(
        'fpga=1 ver=16 result=0 len=4 seq=7 type=0 '
        'time_valid=1 timestamp_ms=1788480001230 uart_err=0 overflow=0',
      ),
    );
    expect(status.fpgaConnected, isTrue);
    expect(status.frameTypeText, '数据帧');
    expect(status.resultText, '操作成功');
    expect(status.payloadLength, 4);
  });

  test('formats a READ record as spaced hex', () {
    final record = RxDataRecord(
      receivedAt: DateTime(2026),
      payloadHex: '010203A5',
      timeValid: true,
      timestampMs: 0,
      sequence: 7,
      frameType: 0,
    );
    expect(record.spacedHex, '01 02 03 A5');
    expect(record.byteLength, 4);
  });

  test('auto-scales a shallow sweep response instead of flattening it', () {
    final scale = SweepChartScale.fromValues([148439194, 147350056]);
    expect(scale.maximumDb, 0);
    expect(scale.minimumDb, closeTo(-0.04, 0.001));
    expect(scale.gridStepDb, 0.01);
  });

  test('marks sweep samples with any clipping as invalid', () {
    const point = SweepPoint(
      frequencyHz: 1500,
      windowCount: 3,
      meanEnergy: 1,
      minEnergy: 1,
      maxEnergy: 1,
      clipCount: 1,
    );
    expect(point.isClipped, isTrue);
  });

  testWidgets('shows TX and RX panels', (tester) async {
    tester.view.physicalSize = const Size(1200, 1100);
    tester.view.devicePixelRatio = 1;
    await tester.pumpWidget(const ShortTransApp());
    expect(find.text('TX 发送端'), findsOneWidget);
    expect(find.text('RX 接收端'), findsOneWidget);
    expect(find.text('短距离通信上位机'), findsOneWidget);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
  });

  testWidgets('BER workspace fits a narrow window', (tester) async {
    tester.view.physicalSize = const Size(640, 800);
    tester.view.devicePixelRatio = 1;
    await tester.pumpWidget(const ShortTransApp());
    await tester.tap(find.byTooltip('BER 误码率'));
    await tester.pumpAndSettle();
    expect(find.text('FSK 误码率调试'), findsWidgets);
    expect(find.text('测试包数'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('可对齐 Payload BER'),
      240,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    expect(find.text('可对齐 Payload BER'), findsOneWidget);
    expect(tester.takeException(), isNull);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
  });

  testWidgets('OOK controls fit a narrow window and require connections', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(640, 800);
    tester.view.devicePixelRatio = 1;
    await tester.pumpWidget(const ShortTransApp());
    await tester.tap(find.byTooltip('调制与门限'));
    await tester.pumpAndSettle();
    expect(find.text('下门限（能量值）'), findsOneWidget);
    expect(find.text('上门限（能量值）'), findsOneWidget);
    final apply = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, '应用到 TX / RX'),
    );
    expect(apply.onPressed, isNull);
    expect(tester.takeException(), isNull);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
  });

  testWidgets('switches from sweep response to the baseline interface', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    await tester.pumpWidget(const ShortTransApp());

    await tester.tap(find.byTooltip('扫频'));
    await tester.pumpAndSettle();
    expect(find.text('幅频响应扫描'), findsOneWidget);
    expect(find.text('开始扫描'), findsOneWidget);
    expect(find.text('1500–2100 Hz'), findsOneWidget);

    await tester.tap(find.text('测量底噪'));
    await tester.pumpAndSettle();
    expect(find.text('开始底噪测量'), findsOneWidget);
    expect(find.text('返回幅频响应'), findsOneWidget);
    expect(tester.takeException(), isNull);

    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
  });

  testWidgets('sweep workspace fits a narrow desktop window', (tester) async {
    tester.view.physicalSize = const Size(640, 800);
    tester.view.devicePixelRatio = 1;
    await tester.pumpWidget(const ShortTransApp());
    await tester.tap(find.byTooltip('扫频'));
    await tester.pumpAndSettle();

    expect(find.text('TX'), findsOneWidget);
    expect(find.text('RX'), findsOneWidget);
    expect(find.text('开始扫描'), findsOneWidget);
    expect(tester.takeException(), isNull);

    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
  });
}
