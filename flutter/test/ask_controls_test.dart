import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:short_trans_host/ask_controls.dart';

String status({
  String mode = 'OOK',
  int low = 400,
  int high = 600,
  int pending = 0,
  int error = 0,
}) =>
    'OK ASK STATUS mode=$mode low=$low '
    'high=$high energy=4294967295 pending=$pending error=$error generation=255 '
    'bit=1 locked=0 ready=1';

void main() {
  test('configuration waits ignore unrelated status replies', () {
    expect(askReplyMatches('MOD OOK', 'OK run=0 mode=5'), isFalse);
    expect(askReplyMatches('ASK STATUS', 'OK MOD OOK pending=0'), isFalse);
    expect(askReplyMatches('ASK STATUS', status()), isTrue);
    expect(askReplyMatches('FSK STATUS', 'OK FSK STATUS margin=32'), isTrue);
    expect(askReplyMatches('FSK THRESH 32 200', 'ERR busy'), isTrue);
    expect(askReplyMatches('ASK THRESH 400 600', 'ERR busy'), isTrue);
  });

  test(
    'threshold command accepts full uint32 and rejects malformed/range/order',
    () {
      expect(
        AskThresholds.parse('0', '4294967295').command,
        'ASK THRESH 0 4294967295',
      );
      for (final values in [
        ['-1', '600'],
        ['400', '400'],
        ['600', '400'],
        ['0', '4294967296'],
        ['1.0', '600'],
        ['0x10', '600'],
        ['', '600'],
      ]) {
        expect(
          () => AskThresholds.parse(values[0], values[1]),
          throwsFormatException,
        );
      }
    },
  );
  test('FSK carrier settings validate raw Q4.4 and coarse offset units', () {
    final value = FskCarrierConfig.parse('32', '200');
    expect(value.command, 'FSK THRESH 32 200');
    expect(value.multiplier, 2.0);
    for (final values in [
      ['0', '1'],
      ['256', '1'],
      ['16', '65536'],
      ['1.0', '20'],
      ['16', '-1'],
    ]) {
      expect(
        () => FskCarrierConfig.parse(values[0], values[1]),
        throwsFormatException,
      );
    }
  });
  test('FSK status and apply verify the active readback', () async {
    const fskStatus = 'OK FSK STATUS margin=32 offset=200 pending=0 error=0 '
        'busy=0 sweep=0 mode=1 generation=4';
    final commands = <String>[];
    final controller = AskController((tx, command) async {
      expect(tx, isFalse);
      commands.add(command);
      return command == 'FSK STATUS'
          ? fskStatus
          : 'OK FSK THRESH margin=32 offset=200 pending=0';
    });
    final result = await controller.setFskCarrier(
      FskCarrierConfig.parse('32', '200'),
    );
    expect(result, contains('已生效'));
    expect(controller.fskStatus!.generation, 4);
    expect(commands, ['FSK THRESH 32 200', 'FSK STATUS']);
  });
  testWidgets('FSK status remains visible when TX is disconnected and parent rebuilds', (tester) async {
    late StateSetter rebuildParent;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: StatefulBuilder(builder: (context, setState) {
          rebuildParent = setState;
          return AskControls(
            txConnected: false,
            rxConnected: true,
            sweepRunning: false,
            command: (tx, command) async =>
                'OK FSK STATUS margin=32 offset=200 pending=0 error=0 '
                'busy=0 sweep=0 mode=1 generation=4',
            onBusy: (_) => rebuildParent(() {}),
          );
        }),
      ),
    ));

    await tester.tap(find.text('读取 FSK 参数'));
    await tester.pumpAndSettle();
    expect(find.textContaining('FSK：2.00x'), findsOneWidget);
  });
  test('pending FSK carrier settings are not reported as active', () async {
    final controller = AskController((tx, command) async => command == 'FSK STATUS'
        ? 'OK FSK STATUS margin=32 offset=200 pending=1 error=0 '
              'busy=1 sweep=0 mode=1 generation=4'
        : 'OK FSK THRESH margin=48 offset=300 pending=1');
    final result = await controller.setFskCarrier(
      FskCarrierConfig.parse('48', '300'),
    );
    expect(result, contains('等待接收空闲'));
    expect(controller.fskStatus!.marginQ4_4, 32);
  });
  test('status parsing validates actual mode, flags and full-width energy', () {
    final parsed = AskStatus.parse(status(pending: 1));
    expect(parsed.energy, 0xffffffff);
    expect(parsed.pending, isTrue);
    expect(parsed.generation, 255);
    expect(() => AskStatus.parse(status(mode: '3')), throwsFormatException);
    expect(() => AskStatus.parse(status(pending: 2)), throwsFormatException);
    expect(() => AskStatus.parse('ERR UNSUPPORTED'), throwsFormatException);
  });
  test(
    'mode selection verifies RX actual state after both endpoint commands',
    () async {
      final commands = <String>[];
      final controller = AskController((tx, command) async {
        commands.add('${tx ? 'TX' : 'RX'} $command');
        return command == 'ASK STATUS'
            ? status()
            : 'OK MOD OOK${tx ? '' : ' pending=0'}';
      });
      expect(await controller.setMode('OOK'), contains('已确认'));
      expect(commands, ['TX MOD OOK', 'RX MOD OOK', 'RX ASK STATUS']);
    },
  );
  test('pending RX mode is not reported as applied', () async {
    final controller = AskController(
      (tx, command) async => command == 'ASK STATUS'
          ? status(mode: 'FSK', pending: 1)
          : 'OK MOD OOK${tx ? '' : ' pending=1'}',
    );
    expect(await controller.setMode('OOK'), contains('等待空闲'));
    expect(controller.status!.mode, 'FSK');
  });
  test(
    'TX failure prevents RX writes; RX failure reports partial application',
    () async {
      var count = 0;
      final failedTx = AskController((tx, command) async {
        count++;
        return 'ERR busy';
      });
      await expectLater(failedTx.setMode('OOK'), throwsStateError);
      expect(count, 1);
      final failedRx = AskController(
        (tx, command) async => tx ? 'OK MOD OOK' : 'ERR unsupported',
      );
      await expectLater(
        failedRx.setMode('OOK'),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'partial failure',
            contains('TX 已切换'),
          ),
        ),
      );
    },
  );
  test(
    'threshold readback mismatch and device error cannot report success',
    () async {
      final controller = AskController(
        (tx, command) async => command == 'ASK STATUS'
            ? status(low: 401)
            : 'OK ASK THRESH low=400 high=600 pending=0',
      );
      await expectLater(
        controller.setThresholds(const AskThresholds(400, 600)),
        throwsStateError,
      );
      final errorController = AskController(
        (tx, command) async => command == 'ASK STATUS'
            ? status(error: 1)
            : 'OK ASK THRESH low=400 high=600 pending=0',
      );
      await expectLater(
        errorController.setThresholds(const AskThresholds(400, 600)),
        throwsStateError,
      );
    },
  );
}
