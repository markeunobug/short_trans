import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:short_trans_host/ber_command_writer.dart';

class UartLineMock {
  Duration time = Duration.zero;
  Duration? previousByte;
  final writes = <(Duration, String)>[];
  final commands = <String>[];
  final line = <int>[];
  bool injectLostTerminator = false;
  int? failAt;

  Future<void> sleep(Duration duration) async => time += duration;
  Future<bool> write(String chunk) async {
    writes.add((time, chunk));
    if (writes.length == failAt) return false;
    for (final byte in chunk.codeUnits) {
      // Reproduce the observed retained STATUS prefix when its newline lands
      // in an injected 370us UART-service blackout. This is a line model,
      // not a Cortex-M latency simulation.
      final drop =
          injectLostTerminator &&
          byte == 10 &&
          previousByte != null &&
          time - previousByte! < const Duration(microseconds: 370);
      previousByte = time;
      if (drop) {
        injectLostTerminator = false;
      } else if (byte == 8) {
        if (line.isNotEmpty) line.removeLast();
      } else if (byte == 10) {
        if (line.isNotEmpty) commands.add(ascii.decode(line));
        line.clear();
      } else {
        line.add(byte);
      }
    }
    return true;
  }
}

void main() {
  test(
    'reproduces STATUSSTOP then avoids injected terminator loss with pacing',
    () async {
      final legacy = UartLineMock()..injectLostTerminator = true;
      await legacy.write('STATUS\n');
      await legacy.sleep(const Duration(seconds: 2));
      await legacy.write('STOP\n');
      expect(legacy.commands, ['STATUSSTOP']);

      final uart = UartLineMock()..injectLostTerminator = true;
      final submitted = <int>[];
      await writeBerCommand(
        'STATUS',
        write: uart.write,
        sleep: uart.sleep,
        submitted: submitted.addAll,
      );
      expect(uart.commands, ['STATUS']);
      expect(ascii.decode(submitted), 'STATUS\n');
      for (var i = 1; i < uart.writes.length; i++) {
        expect(
          uart.writes[i].$1 - uart.writes[i - 1].$1,
          greaterThanOrEqualTo(berCommandByteGap),
        );
      }
    },
  );

  test(
    'emergency STOP cancels partial STATUS and partial SEND before delimiter',
    () async {
      for (final partial in ['STATUS', 'SEND', 'PAYLOAD 1234', 'X' * 159]) {
        final uart = UartLineMock();
        uart.line.addAll(ascii.encode(partial));
        await writeBerCommand(
          'STOP',
          write: uart.write,
          sleep: uart.sleep,
          cancelPartialLine: true,
        );
        expect(uart.commands, ['STOP'], reason: partial);
        expect(uart.writes.take(160).every((w) => w.$2 == '\b'), isTrue);
      }
    },
  );

  test('RX emergency uses the same bounded erasure and one BER STOP', () async {
    final uart = UartLineMock()..line.addAll(ascii.encode('BER RE'));
    await writeBerCommand(
      'BER STOP',
      write: uart.write,
      sleep: uart.sleep,
      cancelPartialLine: true,
    );
    expect(uart.commands, ['BER STOP']);
  });

  test(
    'failed byte is not retried and no remainder of SEND is submitted',
    () async {
      final uart = UartLineMock()..failAt = 3;
      await expectLater(
        writeBerCommand('SEND', write: uart.write, sleep: uart.sleep),
        throwsStateError,
      );
      expect(uart.writes.map((w) => w.$2).join(), 'SEN');
      expect(uart.commands, isEmpty);
    },
  );

  test(
    'failed cancellation never submits STOP or executes partial SEND',
    () async {
      final uart = UartLineMock()..failAt = 2;
      uart.line.addAll(ascii.encode('SEND'));
      await expectLater(
        writeBerCommand(
          'STOP',
          write: uart.write,
          sleep: uart.sleep,
          cancelPartialLine: true,
        ),
        throwsStateError,
      );
      expect(uart.commands, isEmpty);
      expect(uart.writes.every((w) => w.$2 == '\b'), isTrue);
    },
  );

  test(
    'multiline commands and non-STOP emergency writes are rejected before IO',
    () async {
      final uart = UartLineMock();
      await expectLater(
        writeBerCommand('STATUS\nSEND', write: uart.write),
        throwsFormatException,
      );
      await expectLater(
        writeBerCommand('SEND', write: uart.write, cancelPartialLine: true),
        throwsArgumentError,
      );
      expect(uart.writes, isEmpty);
    },
  );
}
