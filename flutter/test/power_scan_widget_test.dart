import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:short_trans_host/main.dart';
import 'package:short_trans_host/power_scan_view.dart';
import 'power_scan_test.dart' show setup, quick;

void main() {
  testWidgets(
    'power scan workspace fits narrow window and requires two ports',
    (tester) async {
      tester.view.physicalSize = const Size(640, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      await tester.pumpWidget(const ShortTransApp());
      await tester.tap(find.byTooltip('功率扫描'));
      await tester.pumpAndSettle();
      expect(find.text('最佳发射幅度测试'), findsWidgets);
      expect(find.text('起始幅度'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.text('开始功率扫描'),
        250,
        scrollable: find.byType(Scrollable).first,
      );
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '开始功率扫描'))
            .onPressed,
        isNull,
      );
      expect(
        tester
            .widget<OutlinedButton>(
              find.widgetWithText(OutlinedButton, '应用推荐幅度'),
            )
            .onPressed,
        isNull,
      );
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'completed scan displays graph, verdicts and verified recommendation',
    (tester) async {
      tester.view.physicalSize = const Size(1180, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      final (c, _, _) = setup();
      await c.start(quick);
      final previewDirectory = Platform.environment['POWER_SCAN_SCREENSHOTS'];
      if (previewDirectory != null) {
        await tester.runAsync(() async {
          final loader = FontLoader('PowerScanPreview')
            ..addFont(
              Future.value(
                ByteData.sublistView(
                  File('C:/Windows/Fonts/msyh.ttc').readAsBytesSync(),
                ),
              ),
            );
          await loader.load();
        });
      }
      final key = GlobalKey();
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(
            fontFamily: previewDirectory == null ? null : 'PowerScanPreview',
          ),
          home: Scaffold(
            body: RepaintBoundary(
              key: key,
              child: PowerScanView(
                controller: c,
                canStart: true,
                connections: const Text('TX / RX 已连接（模拟）'),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('幅度—收包率'),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      expect(find.text('最低实测达标幅度'), findsOneWidget);
      expect(find.text('复测后的推荐幅度'), findsOneWidget);
      expect(find.byType(CustomPaint), findsWidgets);
      expect(find.text('达标'), findsWidgets);
      expect(tester.takeException(), isNull);
      final directory = Platform.environment['POWER_SCAN_SCREENSHOTS'];
      if (directory != null) {
        await tester.runAsync(() async {
          final boundary =
              key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
          final image = await boundary.toImage(pixelRatio: 1);
          final data = await image.toByteData(format: ui.ImageByteFormat.png);
          Directory(directory).createSync(recursive: true);
          File(
            '$directory/power_scan_results.png',
          ).writeAsBytesSync(data!.buffer.asUint8List());
          image.dispose();
        });
      }
    },
  );
}
