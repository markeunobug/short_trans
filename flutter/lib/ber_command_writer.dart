import 'dart:convert';

// The TX O0 renderer can mask its lower-priority UART for > one 115200-baud
// character. Pace BER control bytes; keep the line baud and normal UI unchanged.
const berCommandByteGap = Duration(milliseconds: 2);
const berPartialLineEraseBytes = 160;

Future<void> writeBerCommand(
  String command, {
  required Future<bool> Function(String) write,
  Future<void> Function(Duration)? sleep,
  void Function(List<int>)? submitted,
  bool cancelPartialLine = false,
}) async {
  if (command.isEmpty || command.codeUnits.any((b) => b < 0x20 || b > 0x7e)) {
    throw const FormatException('BER命令必须是单行ASCII文本');
  }
  if (cancelPartialLine && command != 'STOP' && command != 'BER STOP') {
    throw ArgumentError('仅停止命令允许清除未完成输入行');
  }
  final wait = sleep ?? Future<void>.delayed;
  Future<void> packet(List<int> bytes) async {
    for (var i = 0; i < bytes.length; i++) {
      final byte = bytes[i];
      if (!await write(String.fromCharCode(byte))) {
        throw StateError('串口字节写入未确认完成；不会重发命令：$command');
      }
      submitted?.call([byte]); // Driver submission, not proof of MCU reception.
      if (i + 1 < bytes.length) await wait(berCommandByteGap);
    }
  }

  if (cancelPartialLine) {
    // Both current firmware line buffers are <=160 bytes and accept backspace.
    // Erase BEFORE adding a delimiter: a bare newline could execute a partial
    // SEND left by a dropped terminator. An overflow may return one stale ERR.
    await packet([...List.filled(berPartialLineEraseBytes, 8), 10]);
    await wait(const Duration(milliseconds: 100));
  }
  await packet(ascii.encode('$command\n'));
}
