import 'dart:async';

import 'ask_controls.dart';
import 'trace_data.dart';
import 'trace_controller.dart';
import 'trace_view.dart';
import 'ber_controller.dart';
import 'ber_view.dart';
import 'power_scan_controller.dart';
import 'power_scan_view.dart';
import 'ber_command_writer.dart';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:serial_port_win32/serial_port_win32.dart';

void main() => runApp(const ShortTransApp());

class ShortTransApp extends StatelessWidget {
  const ShortTransApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: '短距离通信上位机',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(colorSchemeSeed: Colors.indigo, useMaterial3: true),
    home: const HostPage(),
  );
}

class CommandLog {
  final DateTime time;
  final String direction;
  final String text;
  const CommandLog(this.time, this.direction, this.text);
}

class SweepPoint {
  final int frequencyHz;
  final int windowCount;
  final int meanEnergy;
  final int minEnergy;
  final int maxEnergy;
  final int clipCount;

  const SweepPoint({
    required this.frequencyHz,
    required this.windowCount,
    required this.meanEnergy,
    required this.minEnergy,
    required this.maxEnergy,
    required this.clipCount,
  });

  factory SweepPoint.fromLine(String line) {
    final fields = parseFields(line);
    int requiredInt(String key) {
      final value = int.tryParse(fields[key] ?? '');
      if (value == null) throw FormatException('缺少扫频字段 $key');
      return value;
    }

    return SweepPoint(
      frequencyHz: requiredInt('freq'),
      windowCount: requiredInt('n'),
      meanEnergy: requiredInt('mean'),
      minEnergy: requiredInt('min'),
      maxEnergy: requiredInt('max'),
      clipCount: requiredInt('clip'),
    );
  }

  bool get isClipped => clipCount != 0;
}

class SweepChartScale {
  const SweepChartScale({
    required this.minimumDb,
    required this.maximumDb,
    required this.gridStepDb,
  });

  final double minimumDb;
  final double maximumDb;
  final double gridStepDb;

  static double relativeDb(int value, int reference) {
    final safeValue = math.max(1, value);
    final safeReference = math.max(1, reference);
    return 10 * math.log(safeValue / safeReference) / math.ln10;
  }

  factory SweepChartScale.fromValues(List<int> values) {
    final maximum = values.fold<int>(1, math.max);
    final minimumDb = values
        .map((value) => relativeDb(value, maximum))
        .reduce(math.min);
    final span = -minimumDb;
    final paddedSpan = math.max(0.01, span * 1.2);
    final targetStep = paddedSpan / 4;
    const steps = [
      0.001,
      0.002,
      0.005,
      0.01,
      0.02,
      0.05,
      0.1,
      0.2,
      0.5,
      1.0,
      2.0,
      5.0,
      10.0,
    ];
    final step = steps.firstWhere(
      (candidate) => candidate >= targetStep,
      orElse: () => steps.last,
    );
    final lower = (-(paddedSpan / step).ceil() * step).clamp(-80.0, -step);
    return SweepChartScale(minimumDb: lower, maximumDb: 0, gridStepDb: step);
  }

  String formatLabel(double value) {
    final decimals = gridStepDb < 0.01
        ? 3
        : gridStepDb < 1
        ? 2
        : 0;
    return value.toStringAsFixed(decimals);
  }
}

Map<String, String> parseFields(String line) {
  final result = <String, String>{};
  for (final token in line.trim().split(RegExp(r'\s+'))) {
    final i = token.indexOf('=');
    if (i > 0) result[token.substring(0, i)] = token.substring(i + 1);
  }
  return result;
}

class TxParsedStatus {
  final Map<String, String> fields;
  const TxParsedStatus(this.fields);
  bool? _bool(String key) => fields[key] == null ? null : fields[key] == '1';
  bool? get running => _bool('run');
  bool? get timeValid => _bool('time_valid');
  bool? get timeBasePending => _bool('time_base_pending');
  int? get mode => int.tryParse(fields['mode'] ?? '');
  int? get amplitude => int.tryParse(fields['amp'] ?? '');
  int? get payloadLength => int.tryParse(fields['len'] ?? '');
  int? get baseSeconds => int.tryParse(fields['base_s'] ?? '');
  int? get lastError => int.tryParse(fields['err'] ?? '');
  int? get dmaErrors => int.tryParse(fields['dmaerr'] ?? '');
  String get modeText =>
      const [
        '静默',
        '1700 Hz',
        '1900 Hz',
        '交替测试',
        'PRBS 测试',
        '数据包',
      ].elementAtOrNull(mode ?? -1) ??
      '未知';
  String get summary => fields.isEmpty
      ? '等待 STATUS 响应'
      : '模式：$modeText  幅度：${amplitude ?? '未知'}  Payload：${payloadLength ?? '未知'} 字节';
}

extension<T> on List<T> {
  T? elementAtOrNull(int index) =>
      index >= 0 && index < length ? this[index] : null;
}

class TxHistoryRecord {
  final DateTime time;
  final String type;
  final String payload;
  final String result;
  const TxHistoryRecord(this.time, this.type, this.payload, this.result);
}

class RxDeviceStatus {
  final Map<String, String> fields;
  const RxDeviceStatus(this.fields);

  bool? get fpgaConnected => _boolField('fpga');
  bool? get timeValid => _boolField('time_valid');
  int? get firmwareVersion => int.tryParse(fields['ver'] ?? '');
  int? get resultCode => int.tryParse(fields['result'] ?? '');
  int? get payloadLength => int.tryParse(fields['len'] ?? '');
  int? get sequence => int.tryParse(fields['seq'] ?? '');
  int? get frameType => int.tryParse(fields['type'] ?? '');
  int get uartErrors => int.tryParse(fields['uart_err'] ?? '') ?? 0;
  int get overflows => int.tryParse(fields['overflow'] ?? '') ?? 0;
  int? get timestampMs => int.tryParse(fields['timestamp_ms'] ?? '');
  int? get baseSeconds => int.tryParse(fields['base_s'] ?? '');
  int? get elapsed10ms => int.tryParse(fields['elapsed10ms'] ?? '');
  int? get fpgaStatus0 => _intField('fpga_status0');
  int? get fpgaErrors => _intField('fpga_errors');
  int? get fpgaFrames => _intField('fpga_frames');
  int? get fpgaFifoBytes => _intField('fpga_fifo_bytes');
  int? get fpgaGood => _intField('fpga_good');
  int? get fpgaCrcErrors => _intField('fpga_crc_errors');

  String? get fpgaStatus0Raw => fields['fpga_status0'];
  String? get fpgaErrorsRaw => fields['fpga_errors'];

  int? _intField(String key) {
    final value = fields[key];
    if (value == null) return null;
    return int.tryParse(value) ??
        (value.toLowerCase().startsWith('0x')
            ? int.tryParse(value.substring(2), radix: 16)
            : null);
  }

  bool? _boolField(String key) {
    if (fields[key] == '1') return true;
    if (fields[key] == '0') return false;
    return null;
  }

  String get resultText {
    const labels = [
      '操作成功',
      '当前没有新帧',
      '参数错误',
      'SPI 通信错误',
      'FPGA 设备异常',
      '设备状态异常',
      '协议解析错误',
      '接收缓冲区过小',
    ];
    final code = resultCode;
    return code != null && code >= 0 && code < labels.length
        ? labels[code]
        : code == null
        ? '尚未查询'
        : '未知错误（$code）';
  }

  String get frameTypeText => frameType == 0
      ? '数据帧'
      : frameType == 1
      ? '时间基准帧'
      : '未知';
}

class RxDataRecord {
  final DateTime receivedAt;
  final String payloadHex;
  final bool timeValid;
  final int? timestampMs;
  final int? sequence;
  final int? frameType;

  const RxDataRecord({
    required this.receivedAt,
    required this.payloadHex,
    required this.timeValid,
    required this.timestampMs,
    required this.sequence,
    required this.frameType,
  });

  int get byteLength => payloadHex.length ~/ 2;
  // TIME_BASE is the only zero-length frame.  Do not rely on the last STATUS
  // response here: READ can return a newer DATA frame than that snapshot.
  bool get isTimeBase => frameType == 1 && payloadHex.isEmpty;
  String get spacedHex => payloadHex.isEmpty
      ? '—'
      : RegExp(
          r'.{1,2}',
        ).allMatches(payloadHex).map((m) => m.group(0)).join(' ');
  String get identity => '$timestampMs|$sequence|$frameType|$payloadHex';
}

String formatDeviceTimestamp(int? timestampMs) {
  if (timestampMs == null) return '未知';
  // Firmware stores calendar fields as seconds since 1970 without a timezone.
  final value = DateTime.fromMillisecondsSinceEpoch(timestampMs, isUtc: true);
  String p(int v, [int width = 2]) => v.toString().padLeft(width, '0');
  return '${value.year}-${p(value.month)}-${p(value.day)} '
      '${p(value.hour)}:${p(value.minute)}:${p(value.second)}.${p(value.millisecond, 3)}';
}

class SerialChannel {
  SerialChannel({
    required this.onLine,
    this.onBlock,
    this.onBytes,
    this.onSubmit,
  }) {
    _decoder = TraceSerialDecoder(
      onLine: onLine,
      onBlock: (bytes) => onBlock?.call(bytes),
    );
  }
  final void Function(String) onLine;
  final void Function(Uint8List)? onBlock;
  final void Function(Uint8List)? onBytes;
  final void Function(List<int>)? onSubmit;
  late final TraceSerialDecoder _decoder;
  void resetFraming() => _decoder.clear();
  SerialPort? _port;
  Timer? _poller;
  bool _reading = false;

  Future<void> open(String name) async {
    await close();
    final port = SerialPort(name, BaudRate: 115200, openNow: false);
    await port.open();
    _port = port;
    _poller = Timer.periodic(
      const Duration(milliseconds: 20),
      (_) => _readAvailable(),
    );
  }

  Future<void> _readAvailable() async {
    final port = _port;
    if (_reading || port == null) return;
    _reading = true;
    try {
      final bytes = await port.readBytes(
        512,
        timeout: const Duration(milliseconds: 5),
      );
      onBytes?.call(bytes);
      _decoder.add(bytes);
    } catch (_) {
      // Short non-blocking reads can time out while no bytes are available.
    } finally {
      _reading = false;
    }
  }

  Future<void> writeLine(
    String line, {
    bool berPaced = false,
    bool cancelPartialLine = false,
  }) async {
    final port = _port;
    if (port == null || !port.isOpened) throw StateError('串口未打开');
    if (berPaced) {
      await writeBerCommand(
        line,
        write: (chunk) =>
            port.writeBytesFromString(chunk, includeZeroTerminator: false),
        submitted: onSubmit,
        cancelPartialLine: cancelPartialLine,
      );
      return;
    }
    if (cancelPartialLine) throw StateError('清除未完成行必须使用BER逐字节发送');
    final completed = await port.writeBytesFromString(
      '$line\n',
      includeZeroTerminator: false,
    );
    if (!completed) {
      throw StateError('串口写入未确认完成；不会自动重发：$line');
    }
  }

  Future<void> close() async {
    _poller?.cancel();
    _poller = null;
    _port?.close();
    _port = null;
    _decoder.clear();
  }
}

class HostPage extends StatefulWidget {
  const HostPage({super.key});
  @override
  State<HostPage> createState() => _HostPageState();
}

class _HostPageState extends State<HostPage> {
  final _txLogs = <CommandLog>[];
  final _rxLogs = <CommandLog>[];
  late final SerialChannel _tx;
  late final SerialChannel _rx;
  late final TraceController _trace;
  late final BerController _ber;
  late final PowerScanController _power;
  bool get _testBusy => _ber.running || _power.running || _power.applying;
  bool get _canStartMeasurement =>
      _txOpen &&
      _rxOpen &&
      _txPort != _rxPort &&
      !_sweepRunning &&
      !_trace.running &&
      !_askConfigBusy &&
      !_testBusy &&
      _txReply == null &&
      _rxReply == null;
  List<String> _ports = [];
  String? _txPort;
  String? _rxPort;
  bool _txOpen = false;
  bool _rxOpen = false;
  String _txStatus = '未连接';
  String _rxStatus = '未连接';
  TxParsedStatus _txParsed = const TxParsedStatus({});
  final _txHistory = <TxHistoryRecord>[];
  String _txPayloadHex = '';
  bool _txTimeBasePending = false;
  String _txLastResult = '等待操作';
  RxDeviceStatus _rxDeviceStatus = const RxDeviceStatus({});
  final _rxRecords = <RxDataRecord>[];
  String? _lastRxRecordIdentity;
  Completer<String>? _txReply;
  Completer<String>? _rxReply;
  bool Function(String)? _txReplyMatcher;
  bool Function(String)? _rxReplyMatcher;
  int _pageIndex = 0;
  bool _baselineView = false;
  bool _sweepRunning = false;
  bool _askConfigBusy = false;
  bool _sweepCancelRequested = false;
  bool _subtractBaseline = true;
  int _sweepProgress = 0;
  int _sweepSequence = 0;
  int _sweepAmplitude = 256;
  String _sweepStatus = '等待开始';
  final _signalSweep = <SweepPoint>[];
  final _baselineSweep = <SweepPoint>[];

  @override
  void initState() {
    super.initState();
    _tx = SerialChannel(
      onBytes: (bytes) => _ber.raw(true, bytes),
      onSubmit: (bytes) => _ber.rawTransmit(true, bytes),
      onLine: (line) {
        _addLog(_txLogs, 'RX', line);
        _parseTxResponse(line);
      },
    );
    _rx = SerialChannel(
      onBytes: (bytes) => _ber.raw(false, bytes),
      onSubmit: (bytes) => _ber.rawTransmit(false, bytes),
      onBlock: (bytes) {
        try {
          final block = TraceBlock.parse(bytes);
          _completeReply(
            false,
            'TRACE_BLOCK ${[block.id, block.offset, base64Encode(block.payload)].join(' ')}',
          );
        } on FormatException {
          /* CRC failures are retried by the controller. */
        }
      },
      onLine: (line) {
        _addLog(_rxLogs, 'RX', line);
        _parseRxResponse(line);
      },
    );
    _trace = TraceController(
      command: (cmd) => _request(
        false,
        cmd,
        matcher: (line) =>
            line.startsWith('ERR') ||
            (cmd == 'TRACE STATUS'
                ? line.startsWith('OK TRACE status=')
                : line == 'OK TRACE ACK'),
      ),
      readBlock: (id, offset, length) async {
        _rx.resetFraming();
        final prefix = 'TRACE_BLOCK $id $offset ';
        final reply = await _request(
          false,
          'TRACE READ $id $offset $length',
          matcher: (line) => line.startsWith(prefix) || line.startsWith('ERR'),
          timeout: const Duration(seconds: 1),
        );
        if (reply.startsWith('ERR')) throw StateError(reply);
        return base64Decode(reply.substring(prefix.length));
      },
      changed: () {
        if (mounted) setState(() {});
      },
    );
    final berClock = Stopwatch()..start();
    _ber = BerController(
      command: (isTx, cmd) => _request(
        isTx,
        cmd,
        matcher: (line) => line.startsWith('OK') || line.startsWith('ERR'),
        timeout: const Duration(seconds: 2),
        strictWrite: true,
      ),
      emergencyStop: (isTx, cmd) => (isTx ? _tx : _rx).writeLine(
        cmd,
        berPaced: true,
        cancelPartialLine: true,
      ),
      invalidateConnections: () async {
        await _tx.close();
        await _rx.close();
        if (mounted) {
          setState(() {
            _txOpen = false;
            _rxOpen = false;
            _txStatus = '响应未决，请重连';
            _rxStatus = '响应未决，请重连';
          });
        }
      },
      auditFactory: () => BerFileAudit(Directory('exports/ber')),
      now: () => berClock.elapsed,
      changed: () {
        if (mounted) setState(() {});
      },
    );
    _power = PowerScanController(
      ber: _ber,
      changed: () {
        if (mounted) setState(() {});
      },
    );
    _refreshPorts();
  }

  void _parseTxResponse(String line) {
    _completeReply(true, line);
    if (line.startsWith('OK')) {
      final fields = parseFields(line.substring(2));
      setState(() {
        if (fields.containsKey('run') || fields.containsKey('mode')) {
          _txParsed = TxParsedStatus(fields);
        }
        _txLastResult = '设备已接受命令';
      });
    } else if (line.startsWith('ERR')) {
      setState(() => _txLastResult = line);
    }
  }

  void _parseRxResponse(String line) {
    _completeReply(false, line);
    if (!line.startsWith('OK')) return;
    final body = line.substring(2).trim();
    if (body == 'DATA' || body.startsWith('DATA ')) {
      // READ formats an empty TIME_BASE as "DATA  time_valid=...". Extract
      // the payload before the first field instead of treating time_valid as
      // a payload token when the payload is empty.
      final fieldsStart = body.indexOf(' time_valid=');
      final payloadText = fieldsStart >= 0
          ? body.substring(4, fieldsStart).trim()
          : body.substring(4).trim();
      final payload = payloadText.toUpperCase();
      if (payload != '-' &&
          (!RegExp(r'^[0-9A-F]*$').hasMatch(payload) ||
              payload.length.isOdd ||
              payload.length > 128)) {
        return;
      }
      final readFields = parseFields(body);
      final timestampMs = int.tryParse(readFields['timestamp_ms'] ?? '');
      final record = RxDataRecord(
        receivedAt: DateTime.now(),
        payloadHex: payload == '-' ? '' : payload,
        timeValid: readFields['time_valid'] == '1',
        timestampMs: timestampMs,
        sequence: _rxDeviceStatus.sequence,
        // The current firmware's READ response does not repeat seq/type.
        // A non-empty payload is necessarily an ordinary DATA frame, so do
        // not let a previous STATUS(type=1) relabel it as TIME_BASE.
        frameType: payload.isNotEmpty ? 0 : _rxDeviceStatus.frameType,
      );
      if (record.identity != _lastRxRecordIdentity) {
        setState(() {
          _lastRxRecordIdentity = record.identity;
          _rxRecords.insert(0, record);
          if (_rxRecords.length > 500) _rxRecords.removeLast();
        });
      }
      return;
    }
    final fields = parseFields(body);
    if (fields.containsKey('fpga') || fields.containsKey('result')) {
      setState(() => _rxDeviceStatus = RxDeviceStatus(fields));
    }
  }

  void _completeReply(bool isTx, String line) {
    final completer = isTx ? _txReply : _rxReply;
    final matcher = isTx ? _txReplyMatcher : _rxReplyMatcher;
    if (completer != null &&
        !completer.isCompleted &&
        matcher?.call(line) == true) {
      completer.complete(line);
    }
  }

  Future<String> _request(
    bool isTx,
    String command, {
    required bool Function(String) matcher,
    Duration timeout = const Duration(seconds: 3),
    bool strictWrite = false,
  }) async {
    if (isTx ? _txReply != null : _rxReply != null) {
      throw StateError('${isTx ? 'TX' : 'RX'} 正在等待上一条命令');
    }
    final completer = Completer<String>();
    if (isTx) {
      _txReply = completer;
      _txReplyMatcher = matcher;
    } else {
      _rxReply = completer;
      _rxReplyMatcher = matcher;
    }
    try {
      await _send(isTx, command, strictWrite: strictWrite);
      return await completer.future.timeout(timeout);
    } finally {
      if (isTx && identical(_txReply, completer)) {
        _txReply = null;
        _txReplyMatcher = null;
      } else if (!isTx && identical(_rxReply, completer)) {
        _rxReply = null;
        _rxReplyMatcher = null;
      }
    }
  }

  void _refreshPorts() {
    final ports =
        SerialPort.getAvailablePorts()
            .where((e) => e.isNotEmpty)
            .toSet()
            .toList()
          ..sort();
    setState(() => _ports = ports);
  }

  void _addLog(List<CommandLog> target, String direction, String text) {
    if (mounted) {
      setState(() {
        target.insert(0, CommandLog(DateTime.now(), direction, text));
        if (_testBusy && target.length > 2000) target.removeLast();
      });
    }
  }

  Future<void> _toggle(bool isTx) async {
    if (_testBusy) return;
    final name = isTx ? _txPort : _rxPort;
    if (name == null) return;
    final channel = isTx ? _tx : _rx;
    try {
      if (isTx ? _txOpen : _rxOpen) {
        await channel.close();
        setState(() {
          if (isTx) {
            _txOpen = false;
            _txStatus = '未连接';
          } else {
            _rxOpen = false;
            _rxStatus = '未连接';
          }
        });
      } else {
        await channel.open(name);
        if (isTx) {
          setState(() {
            _txOpen = true;
            _txStatus = '已连接';
          });
        } else {
          setState(() => _rxStatus = '正在握手');
          await Future<void>.delayed(const Duration(milliseconds: 50));
          await _request(
            false,
            'PING',
            matcher: (line) => line.trim() == 'OK PONG',
            timeout: const Duration(milliseconds: 1500),
            strictWrite: true,
          );
          await _request(
            false,
            'STATUS',
            matcher: (line) => line.startsWith('OK ') && line.contains('fpga='),
            timeout: const Duration(seconds: 2),
            strictWrite: true,
          );
          setState(() {
            _rxOpen = true;
            _rxStatus = '已连接';
          });
        }
        _ber.connectionOpened(isTx);
      }
    } catch (e) {
      await channel.close();
      setState(() {
        if (isTx) {
          _txOpen = false;
          _txStatus = '打开失败';
        } else {
          _rxOpen = false;
          _rxStatus = '握手失败';
        }
      });
      _showError('$name：$e');
    }
  }

  Future<void> _send(
    bool isTx,
    String command, {
    bool strictWrite = false,
  }) async {
    if (!strictWrite && (_testBusy || _ber.requiresReconnect)) {
      _showError('测量正在运行或串口响应未决，请先停止/重连');
      return;
    }
    final logs = isTx ? _txLogs : _rxLogs;
    _addLog(logs, 'TX', command);
    try {
      await (isTx ? _tx : _rx).writeLine(
        command,
        berPaced: strictWrite && _testBusy,
      );
      if (isTx) {
        final payloadMatch = RegExp(r'^PAYLOAD\s+(.+)$').firstMatch(command);
        if (payloadMatch != null) {
          final value = payloadMatch.group(1)!.trim().toUpperCase();
          _txPayloadHex = value == '-' ? '' : value;
        } else if (command.startsWith('SET_TIME')) {
          _txTimeBasePending = true;
        } else if (command == 'TIME_BASE') {
          _txTimeBasePending = true;
        }
      }
      if (isTx && command == 'SEND') {
        final isTimeBase =
            _txTimeBasePending || _txParsed.timeBasePending == true;
        setState(
          () => _txHistory.insert(
            0,
            TxHistoryRecord(
              DateTime.now(),
              isTimeBase ? 'TIME_BASE' : 'DATA',
              isTimeBase ? '' : _txPayloadHex,
              '已发送至 TX',
            ),
          ),
        );
        if (isTimeBase) _txTimeBasePending = false;
      }
    } catch (e) {
      if (strictWrite) {
        rethrow;
      }
      _showError(e.toString());
    }
  }

  Future<void> _runSweep({
    required bool baseline,
    required int amplitude,
  }) async {
    if (_sweepRunning ||
        _askConfigBusy ||
        _testBusy ||
        _ber.requiresReconnect) {
      return;
    }
    if (!_txOpen || !_rxOpen) {
      _showError('扫频需要同时连接 TX 和 RX');
      return;
    }

    setState(() {
      _pageIndex = 1;
      _baselineView = baseline;
      _sweepRunning = true;
      _sweepCancelRequested = false;
      _sweepProgress = 0;
      _sweepAmplitude = amplitude;
      _sweepStatus = baseline ? '正在准备底噪测量' : '正在准备幅频扫描';
      (baseline ? _baselineSweep : _signalSweep).clear();
    });

    try {
      if (baseline) {
        final off = await _request(
          true,
          'SWEEP OFF',
          matcher: (line) =>
              line.startsWith('OK SWEEP OFF') || line.startsWith('ERR'),
        );
        if (!off.startsWith('OK')) throw StateError(off);
      }

      for (var frequency = 1500; frequency <= 2100; frequency += 20) {
        if (_sweepCancelRequested) break;
        _sweepSequence = (_sweepSequence + 1) & 0xffff;
        final sequence = _sweepSequence;

        if (!baseline) {
          setState(() => _sweepStatus = '设置发射频率 $frequency Hz');
          final tone = await _request(
            true,
            'SWEEP TONE $sequence $frequency $amplitude',
            matcher: (line) =>
                line.startsWith('ERR') ||
                (line.startsWith('OK SWEEP TONE') &&
                    parseFields(line)['seq'] == sequence.toString()),
          );
          if (!tone.startsWith('OK')) throw StateError(tone);
        }

        setState(
          () => _sweepStatus = baseline
              ? '测量底噪 $frequency Hz'
              : '测量响应 $frequency Hz',
        );
        final resultLine = await _request(
          false,
          'SWEEP MEASURE $sequence $frequency 20 100 3',
          matcher: (line) =>
              line.startsWith('ERR') ||
              (line.startsWith('OK SWEEP RESULT') &&
                  parseFields(line)['seq'] == sequence.toString()),
          timeout: const Duration(seconds: 2),
        );
        if (!resultLine.startsWith('OK')) throw StateError(resultLine);
        final point = SweepPoint.fromLine(resultLine);
        if (!mounted) return;
        setState(() {
          (baseline ? _baselineSweep : _signalSweep).add(point);
          _sweepProgress = baseline
              ? _baselineSweep.length
              : _signalSweep.length;
        });
      }

      if (!mounted) return;
      setState(() {
        _sweepStatus = _sweepCancelRequested
            ? '扫描已停止'
            : baseline
            ? '底噪测量完成'
            : '幅频扫描完成';
      });
    } on TimeoutException {
      if (mounted) setState(() => _sweepStatus = '设备响应超时');
      _showError('扫频命令等待设备响应超时');
    } catch (error) {
      if (mounted) setState(() => _sweepStatus = '扫描失败');
      _showError(error.toString());
    } finally {
      try {
        if (_txOpen) {
          await _request(
            true,
            'SWEEP OFF',
            matcher: (line) =>
                line.startsWith('OK SWEEP OFF') || line.startsWith('ERR'),
          );
        }
      } catch (_) {}
      try {
        if (_rxOpen) {
          await _request(
            false,
            'SWEEP STOP',
            matcher: (line) =>
                line.startsWith('OK SWEEP STOP') || line.startsWith('ERR'),
          );
        }
      } catch (_) {}
      if (mounted) setState(() => _sweepRunning = false);
    }
  }

  Future<void> _stopSweep() async {
    setState(() {
      _sweepCancelRequested = true;
      _sweepStatus = '正在停止';
    });
  }

  int _correctedEnergy(SweepPoint point) {
    if (!_subtractBaseline) return point.meanEnergy;
    SweepPoint? baseline;
    for (final item in _baselineSweep) {
      if (item.frequencyHz == point.frequencyHz) {
        baseline = item;
        break;
      }
    }
    return math.max(0, point.meanEnergy - (baseline?.meanEnergy ?? 0));
  }

  Future<void> _exportSweepCsv() async {
    if (_signalSweep.isEmpty && _baselineSweep.isEmpty) return;
    final baselineByFrequency = {
      for (final point in _baselineSweep) point.frequencyHz: point,
    };
    final rows = <String>[
      'frequency_hz,amplitude,signal_mean,noise_mean,corrected_mean,signal_min,signal_max,clip_count,window_count',
    ];
    for (final point in _signalSweep) {
      final noise = baselineByFrequency[point.frequencyHz];
      final corrected = math.max(
        0,
        point.meanEnergy - (noise?.meanEnergy ?? 0),
      );
      rows.add(
        '${point.frequencyHz},$_sweepAmplitude,${point.meanEnergy},${noise?.meanEnergy ?? ''},$corrected,${point.minEnergy},${point.maxEnergy},${point.clipCount},${point.windowCount}',
      );
    }
    if (_signalSweep.isEmpty) {
      for (final point in _baselineSweep) {
        rows.add(
          '${point.frequencyHz},0,,${point.meanEnergy},,${point.minEnergy},${point.maxEnergy},${point.clipCount},${point.windowCount}',
        );
      }
    }

    final now = DateTime.now();
    String p(int value) => value.toString().padLeft(2, '0');
    final directory = Directory(
      '${Directory.current.path}${Platform.pathSeparator}exports',
    );
    await directory.create(recursive: true);
    final file = File(
      '${directory.path}${Platform.pathSeparator}sweep_${now.year}${p(now.month)}${p(now.day)}_${p(now.hour)}${p(now.minute)}${p(now.second)}.csv',
    );
    await file.writeAsString('${rows.join('\r\n')}\r\n');
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('已导出 ${file.path}')));
    }
  }

  void _showError(String message) => ScaffoldMessenger.of(
    context,
  ).showSnackBar(SnackBar(content: Text(message)));

  @override
  void dispose() {
    _power.stop();
    _ber.stopRequested = true;
    if (_testBusy) {
      unawaited(_tx.writeLine('STOP').catchError((Object _) {}));
      unawaited(_rx.writeLine('BER STOP').catchError((Object _) {}));
    }
    _trace.stopRequested = true;
    _tx.close();
    _rx.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(
        _pageIndex == 0
            ? '短距离通信上位机'
            : _pageIndex == 1
            ? '幅频响应扫描'
            : _pageIndex == 2
            ? '调制与门限设置'
            : _pageIndex == 3
            ? '解调观测'
            : _pageIndex == 4
            ? 'FSK 误码率调试'
            : '最佳发射幅度测试',
      ),
      actions: [
        IconButton(
          onPressed:
              _askConfigBusy || _sweepRunning || _trace.running || _testBusy
              ? null
              : () => setState(() => _pageIndex = 0),
          icon: Icon(
            Icons.swap_horiz,
            color: _pageIndex == 0
                ? Theme.of(context).colorScheme.primary
                : null,
          ),
          tooltip: '通信',
        ),
        IconButton(
          onPressed:
              _askConfigBusy || _sweepRunning || _trace.running || _testBusy
              ? null
              : () => setState(() => _pageIndex = 1),
          icon: Icon(
            Icons.show_chart,
            color: _pageIndex == 1
                ? Theme.of(context).colorScheme.primary
                : null,
          ),
          tooltip: '扫频',
        ),
        IconButton(
          onPressed:
              _askConfigBusy || _sweepRunning || _trace.running || _testBusy
              ? null
              : () => setState(() => _pageIndex = 2),
          icon: const Icon(Icons.tune),
          tooltip: '调制与门限',
        ),
        IconButton(
          onPressed:
              _askConfigBusy || _sweepRunning || _trace.running || _testBusy
              ? null
              : () => setState(() => _pageIndex = 3),
          icon: const Icon(Icons.monitor_heart_outlined),
          tooltip: '解调观测',
        ),
        IconButton(
          onPressed:
              _askConfigBusy || _sweepRunning || _trace.running || _testBusy
              ? null
              : () => setState(() => _pageIndex = 4),
          icon: Icon(
            Icons.fact_check_outlined,
            color: _pageIndex == 4
                ? Theme.of(context).colorScheme.primary
                : null,
          ),
          tooltip: 'BER 误码率',
        ),
        IconButton(
          onPressed:
              _askConfigBusy || _sweepRunning || _trace.running || _testBusy
              ? null
              : () => setState(() => _pageIndex = 5),
          icon: Icon(
            Icons.bolt,
            color: _pageIndex == 5
                ? Theme.of(context).colorScheme.primary
                : null,
          ),
          tooltip: '功率扫描',
        ),
        IconButton(
          onPressed: _testBusy ? null : _refreshPorts,
          icon: const Icon(Icons.refresh),
          tooltip: '刷新串口',
        ),
      ],
    ),
    body: _pageIndex == 0
        ? _buildCommunicationPage()
        : _pageIndex == 1
        ? _buildSweepPage()
        : _pageIndex == 3
        ? TraceView(
            controller: _trace,
            connected: _rxOpen && !_sweepRunning && !_askConfigBusy,
          )
        : _pageIndex == 5
        ? PowerScanView(
            controller: _power,
            canStart: _canStartMeasurement,
            connections: _buildTestConnections(),
          )
        : _pageIndex == 4
        ? BerView(
            controller: _ber,
            connected: _txOpen && _rxOpen && _txPort != _rxPort,
            canStart:
                _txOpen &&
                _rxOpen &&
                _txPort != _rxPort &&
                !_sweepRunning &&
                !_trace.running &&
                !_askConfigBusy &&
                _txReply == null &&
                _rxReply == null,
            rxConnected:
                _rxOpen &&
                !_testBusy &&
                !_ber.requiresReconnect &&
                _rxReply == null,
            connections: _buildTestConnections(),
          )
        : ListView(
            padding: const EdgeInsets.all(12),
            children: [
              AskControls(
                txConnected: _txOpen,
                rxConnected: _rxOpen,
                sweepRunning: _sweepRunning,
                command: (isTx, command) => _request(
                  isTx,
                  command,
                  matcher: (line) => askReplyMatches(command, line),
                ),
                onBusy: (busy) {
                  if (mounted) setState(() => _askConfigBusy = busy);
                },
              ),
            ],
          ),
  );

  Widget _buildTestConnections() => LayoutBuilder(
    builder: (context, constraints) {
      final cardWidth = constraints.maxWidth < 720
          ? constraints.maxWidth
          : 350.0;
      return Wrap(
        spacing: 12,
        runSpacing: 12,
        children: [
          SizedBox(
            width: cardWidth,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('TX 发送端'),
                AbsorbPointer(
                  absorbing: _testBusy,
                  child: ConnectionCard(
                    ports: _ports,
                    selectedPort: _txPort,
                    connected: _txOpen,
                    status: _txStatus,
                    onPortChanged: (v) => setState(() => _txPort = v),
                    onToggle: () => _toggle(true),
                  ),
                ),
              ],
            ),
          ),
          SizedBox(
            width: cardWidth,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('RX 接收端'),
                AbsorbPointer(
                  absorbing: _testBusy,
                  child: ConnectionCard(
                    ports: _ports,
                    selectedPort: _rxPort,
                    connected: _rxOpen,
                    status: _rxStatus,
                    onPortChanged: (v) => setState(() => _rxPort = v),
                    onToggle: () => _toggle(false),
                  ),
                ),
              ],
            ),
          ),
        ],
      );
    },
  );

  Widget _buildCommunicationPage() => LayoutBuilder(
    builder: (context, constraints) {
      final tx = TxPanel(
        ports: _ports,
        selectedPort: _txPort,
        connected: _txOpen,
        status: _txStatus,
        logs: _txLogs,
        onPortChanged: (v) => setState(() => _txPort = v),
        onToggle: () => _toggle(true),
        onSend: (v) => _send(true, v),
        onClear: () => setState(_txLogs.clear),
        parsed: _txParsed,
        lastResult: _txLastResult,
        history: _txHistory,
        onClearHistory: () => setState(_txHistory.clear),
      );
      final rx = RxPanel(
        ports: _ports,
        selectedPort: _rxPort,
        connected: _rxOpen && !_testBusy && !_ber.requiresReconnect,
        status: _rxStatus,
        logs: _rxLogs,
        onPortChanged: (v) => setState(() => _rxPort = v),
        onToggle: () => _toggle(false),
        onSend: (v) => _send(false, v),
        onClear: () => setState(_rxLogs.clear),
        deviceStatus: _rxDeviceStatus,
        berRunning: _testBusy || _ber.requiresReconnect,
        records: _rxRecords,
        onClearRecords: () => setState(() {
          _rxRecords.clear();
          _lastRxRecordIdentity = null;
        }),
      );
      return Padding(
        padding: const EdgeInsets.all(12),
        child: constraints.maxWidth >= 900
            ? Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(child: tx),
                  const SizedBox(width: 12),
                  Expanded(child: rx),
                ],
              )
            : ListView(
                children: [
                  SizedBox(height: 820, child: tx),
                  const SizedBox(height: 12),
                  SizedBox(height: 760, child: rx),
                ],
              ),
      );
    },
  );

  Widget _buildSweepPage() => SweepWorkspace(
    ports: _ports,
    txPort: _txPort,
    rxPort: _rxPort,
    txConnected: _txOpen,
    rxConnected: _rxOpen,
    txStatus: _txStatus,
    rxStatus: _rxStatus,
    baselineView: _baselineView,
    running: _sweepRunning,
    progress: _sweepProgress,
    status: _sweepStatus,
    amplitude: _sweepAmplitude,
    subtractBaseline: _subtractBaseline,
    signal: _signalSweep,
    baseline: _baselineSweep,
    onTxPortChanged: (value) => setState(() => _txPort = value),
    onRxPortChanged: (value) => setState(() => _rxPort = value),
    onToggleTx: () => _toggle(true),
    onToggleRx: () => _toggle(false),
    onShowBaseline: () => setState(() => _baselineView = true),
    onShowSignal: () => setState(() => _baselineView = false),
    onStartSignal: (amplitude) =>
        _runSweep(baseline: false, amplitude: amplitude),
    onStartBaseline: () =>
        _runSweep(baseline: true, amplitude: _sweepAmplitude),
    onStop: _stopSweep,
    onExport: _exportSweepCsv,
    onSubtractBaselineChanged: (value) =>
        setState(() => _subtractBaseline = value),
    correctedEnergy: _correctedEnergy,
  );
}

class TxPanel extends StatefulWidget {
  const TxPanel({
    super.key,
    required this.ports,
    required this.selectedPort,
    required this.connected,
    required this.status,
    required this.logs,
    required this.onPortChanged,
    required this.onToggle,
    required this.onSend,
    required this.onClear,
    required this.parsed,
    required this.lastResult,
    required this.history,
    required this.onClearHistory,
  });
  final List<String> ports;
  final String? selectedPort;
  final bool connected;
  final String status;
  final List<CommandLog> logs;
  final ValueChanged<String?> onPortChanged;
  final VoidCallback onToggle;
  final Future<void> Function(String) onSend;
  final VoidCallback onClear;
  final TxParsedStatus parsed;
  final String lastResult;
  final List<TxHistoryRecord> history;
  final VoidCallback onClearHistory;
  @override
  State<TxPanel> createState() => _TxPanelState();
}

class _TxPanelState extends State<TxPanel> {
  String _mode = 'PACKET';
  bool _sendingTimeBase = false;
  final _payload = TextEditingController(text: '01020304');
  final _amplitude = TextEditingController(text: '256');
  double _amplitudeValue = 256;
  String? _amplitudeError;
  String? _payloadError;

  Future<void> _applyAmplitude() async {
    final n = int.tryParse(_amplitude.text.trim());
    if (n == null || n < 0 || n > 2047) {
      setState(() => _amplitudeError = '请输入 0..2047 的整数');
      return;
    }
    setState(() {
      _amplitudeError = null;
      _amplitudeValue = n.toDouble();
      _amplitude.text = n.toString();
    });
    await widget.onSend('AMP $n');
  }

  Future<void> _applyPayload() async {
    final s = _payload.text.replaceAll(RegExp(r'\s+'), '').toUpperCase();
    String? error;
    if (s != '-' && !RegExp(r'^[0-9A-F]*$').hasMatch(s)) {
      error = '只能输入 HEX 字符 0..9、A..F';
    } else if (s != '-' && s.length.isOdd) {
      error = 'HEX 数据长度必须为偶数，每两个字符表示一个字节';
    } else if (s != '-' && s.length > 128) {
      error = '数据最多 64 字节（128 个 HEX 字符）';
    }
    if (error != null) {
      setState(() => _payloadError = error);
      return;
    }
    setState(() {
      _payloadError = null;
      _payload.text = s;
    });
    await widget.onSend('PAYLOAD ${s.isEmpty ? '-' : s}');
  }

  @override
  void dispose() {
    _payload.dispose();
    _amplitude.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Panel(
    title: 'TX 发送端',
    color: Colors.indigo,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ConnectionCard(
          ports: widget.ports,
          selectedPort: widget.selectedPort,
          connected: widget.connected,
          status: widget.status,
          onPortChanged: widget.onPortChanged,
          onToggle: widget.onToggle,
        ),
        const SizedBox(height: 10),
        TxStatusCard(status: widget.parsed, lastResult: widget.lastResult),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          children: ['HELP', 'STATUS', 'STOP']
              .map(
                (x) => OutlinedButton(
                  onPressed: () => widget.onSend(x),
                  child: Text(x),
                ),
              )
              .toList(),
        ),
        CommandRow(
          label: '模式',
          child: DropdownButtonFormField<String>(
            key: ValueKey(_mode),
            initialValue: _mode,
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              isDense: true,
            ),
            items: [
              'SILENCE',
              'TONE1700',
              'TONE1900',
              'CARRIER',
              'ALT',
              'PRBS',
              'PACKET',
            ].map((x) => DropdownMenuItem(value: x, child: Text(x))).toList(),
            onChanged: (v) {
              if (v != null) {
                setState(() => _mode = v);
                widget.onSend('MODE $v');
              }
            },
          ),
        ),
        CommandRow(
          label: '功率',
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _amplitude,
                  keyboardType: TextInputType.number,
                  textInputAction: TextInputAction.done,
                  onChanged: (_) {
                    if (_amplitudeError != null) {
                      setState(() => _amplitudeError = null);
                    }
                  },
                  onSubmitted: (_) => _applyAmplitude(),
                  decoration: InputDecoration(
                    border: const OutlineInputBorder(),
                    isDense: true,
                    suffixText: '0..2047',
                    errorText: _amplitudeError,
                  ),
                ),
              ),
              Expanded(
                child: Slider(
                  value: _amplitudeValue,
                  min: 0,
                  max: 2047,
                  divisions: 2047,
                  label: _amplitudeValue.round().toString(),
                  onChanged: (v) {
                    setState(() {
                      _amplitudeValue = v;
                      _amplitude.text = v.round().toString();
                      _amplitudeError = null;
                    });
                  },
                  onChangeEnd: (_) => _applyAmplitude(),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton.tonal(
                onPressed: _applyAmplitude,
                child: const Text('应用'),
              ),
            ],
          ),
        ),
        CommandRow(
          label: '数据',
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _payload,
                  textInputAction: TextInputAction.done,
                  onChanged: (_) {
                    if (_payloadError != null) {
                      setState(() => _payloadError = null);
                    }
                  },
                  onSubmitted: (_) => _applyPayload(),
                  decoration: InputDecoration(
                    border: const OutlineInputBorder(),
                    isDense: true,
                    hintText: 'HEX，最多64字节',
                    errorText: _payloadError,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton.tonal(
                onPressed: _applyPayload,
                child: const Text('设置'),
              ),
            ],
          ),
        ),
        CommandRow(
          label: '时间',
          child: FilledButton.tonal(
            onPressed: !widget.connected || _sendingTimeBase
                ? null
                : _setTimeAndSend,
            child: Text(_sendingTimeBase ? '正在下发…' : '设置当前时间并下发 RX'),
          ),
        ),
        Wrap(
          spacing: 8,
          children: [
            FilledButton(
              onPressed: () => widget.onSend('TIME_BASE'),
              child: const Text('TIME_BASE'),
            ),
            FilledButton(
              onPressed: () => widget.onSend('SEND'),
              child: const Text('SEND'),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Expanded(
          child: TxHistoryList(
            history: widget.history,
            onClear: widget.onClearHistory,
          ),
        ),
        ExpansionTile(
          tilePadding: EdgeInsets.zero,
          title: const Text('高级调试日志'),
          children: [
            SizedBox(
              height: 160,
              child: LogView(logs: widget.logs, onClear: widget.onClear),
            ),
          ],
        ),
      ],
    ),
  );

  String formatNow() {
    final n = DateTime.now();
    String p(int v) => v.toString().padLeft(2, '0');
    return '${n.year}-${p(n.month)}-${p(n.day)} ${p(n.hour)}:${p(n.minute)}:${p(n.second)}';
  }

  Future<void> _setTimeAndSend() async {
    setState(() {
      _sendingTimeBase = true;
      _mode = 'PACKET';
    });
    try {
      // SET_TIME makes the next PACKET transmission a TIME_BASE frame.
      await widget.onSend('SET_TIME ${formatNow()}');
      await Future<void>.delayed(const Duration(milliseconds: 80));
      await widget.onSend('MODE PACKET');
      await Future<void>.delayed(const Duration(milliseconds: 80));
      await widget.onSend('SEND');
    } finally {
      if (mounted) {
        setState(() => _sendingTimeBase = false);
      }
    }
  }
}

class TxStatusCard extends StatelessWidget {
  const TxStatusCard({
    super.key,
    required this.status,
    required this.lastResult,
  });
  final TxParsedStatus status;
  final String lastResult;
  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 6,
            runSpacing: 4,
            children: [
              Chip(
                avatar: Icon(
                  Icons.circle,
                  size: 12,
                  color: status.running == true ? Colors.blue : Colors.green,
                ),
                label: Text(status.running == true ? '正在发射' : '发射空闲'),
              ),
              Chip(label: Text('模式：${status.modeText}')),
              Chip(label: Text('幅度：${status.amplitude ?? '待查询'}')),
              Chip(label: Text('Payload：${status.payloadLength ?? '待查询'} 字节')),
            ],
          ),
          Text(
            '时间基准：${status.timeValid == true
                ? '已建立'
                : status.timeValid == false
                ? '未建立'
                : '待查询'}    下一帧：${status.timeBasePending == true ? 'TIME_BASE' : 'DATA'}',
          ),
          Text('最近操作：$lastResult'),
        ],
      ),
    ),
  );
}

class TxHistoryList extends StatelessWidget {
  const TxHistoryList({
    super.key,
    required this.history,
    required this.onClear,
  });
  final List<TxHistoryRecord> history;
  final VoidCallback onClear;
  @override
  Widget build(BuildContext context) => Card(
    child: Column(
      children: [
        Row(
          children: [
            Padding(
              padding: const EdgeInsets.all(10),
              child: Text(
                '发送历史（${history.length} 条）',
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
            ),
            const Spacer(),
            IconButton(
              onPressed: history.isEmpty ? null : onClear,
              icon: const Icon(Icons.delete_sweep_outlined),
              tooltip: '清空发送历史',
            ),
          ],
        ),
        const Divider(height: 1),
        Expanded(
          child: history.isEmpty
              ? const Center(child: Text('暂无发送记录'))
              : ListView.builder(
                  itemCount: history.length,
                  itemBuilder: (_, i) {
                    final x = history[i];
                    return ListTile(
                      dense: true,
                      leading: Icon(
                        x.type == 'TIME_BASE' ? Icons.schedule : Icons.send,
                      ),
                      title: Text(
                        x.type == 'DATA'
                            ? '${x.time.toString().substring(11, 19)}  DATA  ${x.payload.isEmpty ? '（空 Payload）' : x.payload.replaceAllMapped(RegExp(r'.{1,2}'), (m) => '${m.group(0)} ').trim()}'
                            : '${x.time.toString().substring(11, 19)}  TIME_BASE',
                        style: const TextStyle(fontFamily: 'monospace'),
                      ),
                      subtitle: Text(
                        x.type == 'DATA'
                            ? '${x.payload.length ~/ 2} 字节 · ${x.result}'
                            : x.result,
                      ),
                    );
                  },
                ),
        ),
      ],
    ),
  );
}

class RxPanel extends StatefulWidget {
  const RxPanel({
    super.key,
    required this.ports,
    required this.selectedPort,
    required this.connected,
    required this.status,
    required this.logs,
    required this.onPortChanged,
    required this.onToggle,
    required this.onSend,
    required this.onClear,
    required this.deviceStatus,
    required this.berRunning,
    required this.records,
    required this.onClearRecords,
  });
  final List<String> ports;
  final String? selectedPort;
  final bool connected;
  final String status;
  final List<CommandLog> logs;
  final ValueChanged<String?> onPortChanged;
  final VoidCallback onToggle;
  final Future<void> Function(String) onSend;
  final VoidCallback onClear;
  final RxDeviceStatus deviceStatus;
  final bool berRunning;
  final List<RxDataRecord> records;
  final VoidCallback onClearRecords;

  @override
  State<RxPanel> createState() => _RxPanelState();
}

class _RxPanelState extends State<RxPanel> {
  Timer? _autoReadTimer;
  bool _autoReading = false;
  bool _cycleBusy = false;
  int _pollIntervalMs = 500;

  @override
  void dispose() {
    _autoReadTimer?.cancel();
    super.dispose();
  }

  Future<void> _readCycle() async {
    if (_cycleBusy || !widget.connected || widget.berRunning) return;
    _cycleBusy = true;
    try {
      await widget.onSend('READ');
    } finally {
      _cycleBusy = false;
    }
  }

  void _startAutoRead() {
    if (!widget.connected || widget.berRunning) return;
    _autoReadTimer?.cancel();
    setState(() => _autoReading = true);
    _readCycle();
    _autoReadTimer = Timer.periodic(
      Duration(milliseconds: _pollIntervalMs),
      (_) => _readCycle(),
    );
  }

  void _stopAutoRead() {
    _autoReadTimer?.cancel();
    _autoReadTimer = null;
    if (mounted) setState(() => _autoReading = false);
  }

  @override
  Widget build(BuildContext context) => Panel(
    title: 'RX 接收端',
    color: Colors.teal,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ConnectionCard(
          ports: widget.ports,
          selectedPort: widget.selectedPort,
          connected: widget.connected,
          status: widget.status,
          onPortChanged: widget.onPortChanged,
          onToggle: widget.onToggle,
        ),
        const SizedBox(height: 8),
        RxStatusCard(status: widget.deviceStatus),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            FilledButton.tonal(
              onPressed: widget.connected ? _readCycle : null,
              child: const Text('读取一次'),
            ),
            FilledButton(
              onPressed: widget.connected && !_autoReading
                  ? _startAutoRead
                  : null,
              child: const Text('连续接收'),
            ),
            OutlinedButton(
              onPressed: _autoReading ? _stopAutoRead : null,
              child: const Text('停止接收'),
            ),
            OutlinedButton(
              onPressed: widget.connected
                  ? () => widget.onSend('STATUS')
                  : null,
              child: const Text('刷新状态'),
            ),
            DropdownButton<int>(
              value: _pollIntervalMs,
              items: const [
                DropdownMenuItem(value: 500, child: Text('500 ms')),
                DropdownMenuItem(value: 1000, child: Text('1 s')),
              ],
              onChanged: _autoReading
                  ? null
                  : (value) {
                      if (value != null) {
                        setState(() => _pollIntervalMs = value);
                      }
                    },
            ),
            if (_autoReading)
              const Chip(
                avatar: Icon(Icons.sync, size: 16),
                label: Text('自动接收中'),
              ),
          ],
        ),
        const SizedBox(height: 8),
        Expanded(
          child: RxRecordList(
            records: widget.records,
            onClear: widget.onClearRecords,
          ),
        ),
        ExpansionTile(
          tilePadding: EdgeInsets.zero,
          title: const Text('高级调试日志'),
          children: [
            SizedBox(
              height: 180,
              child: LogView(logs: widget.logs, onClear: widget.onClear),
            ),
          ],
        ),
      ],
    ),
  );
}

class RxStatusCard extends StatelessWidget {
  const RxStatusCard({super.key, required this.status});
  final RxDeviceStatus status;

  @override
  Widget build(BuildContext context) {
    Widget item(String label, String value, Color color) => Chip(
      avatar: Icon(Icons.circle, size: 12, color: color),
      label: Text('$label：$value'),
    );
    final fpga = status.fpgaConnected;
    final time = status.timeValid;
    final healthy =
        status.uartErrors == 0 &&
        status.overflows == 0 &&
        (status.fpgaErrors ?? 0) == 0 &&
        (status.fpgaCrcErrors ?? 0) == 0;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 6,
              runSpacing: 4,
              children: [
                item(
                  'FPGA',
                  fpga == true
                      ? '已连接'
                      : fpga == false
                      ? '未连接'
                      : '待查询',
                  fpga == true
                      ? Colors.green
                      : fpga == false
                      ? Colors.red
                      : Colors.grey,
                ),
                item(
                  '时间基准',
                  time == true
                      ? '已同步'
                      : time == false
                      ? '未同步'
                      : '待查询',
                  time == true
                      ? Colors.green
                      : time == false
                      ? Colors.orange
                      : Colors.grey,
                ),
                item(
                  '链路',
                  healthy ? '正常' : '存在错误',
                  healthy ? Colors.green : Colors.red,
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              'FPGA 固件：${status.firmwareVersion?.toString() ?? '未知'}    最近操作：${status.resultText}',
            ),
            Text(
              '当前帧：${status.frameTypeText}    序号：${status.sequence?.toString() ?? '未知'}    长度：${status.payloadLength?.toString() ?? '未知'} 字节',
            ),
            Text(
              '设备时间：${status.timeValid == true ? formatDeviceTimestamp(status.timestampMs) : '无效，尚未收到 TIME_BASE'}',
            ),
            Text(
              'UART 错误：${status.uartErrors}    缓冲区溢出：${status.overflows}',
              style: TextStyle(
                color: healthy ? null : Colors.red,
                fontWeight: healthy ? null : FontWeight.bold,
              ),
            ),
            Text(
              'FPGA 诊断：状态 ${status.fpgaStatus0Raw ?? '未知'}    错误 ${status.fpgaErrorsRaw ?? '未知'}',
              style: TextStyle(
                color: (status.fpgaErrors ?? 0) == 0 ? null : Colors.red,
                fontWeight: (status.fpgaErrors ?? 0) == 0
                    ? null
                    : FontWeight.bold,
              ),
            ),
            Text(
              'FPGA 计数：帧 ${status.fpgaFrames?.toString() ?? '未知'}    FIFO ${status.fpgaFifoBytes?.toString() ?? '未知'} 字节    好帧 ${status.fpgaGood?.toString() ?? '未知'}    CRC 错误 ${status.fpgaCrcErrors?.toString() ?? '未知'}',
              style: TextStyle(
                color: (status.fpgaCrcErrors ?? 0) == 0 ? null : Colors.red,
                fontWeight: (status.fpgaCrcErrors ?? 0) == 0
                    ? null
                    : FontWeight.bold,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class RxRecordList extends StatelessWidget {
  const RxRecordList({super.key, required this.records, required this.onClear});
  final List<RxDataRecord> records;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) => Card(
    child: Column(
      children: [
        Row(
          children: [
            Padding(
              padding: const EdgeInsets.all(10),
              child: Text(
                '接收数据（${records.length} 条）',
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
            ),
            const Spacer(),
            IconButton(
              onPressed: records.isEmpty ? null : onClear,
              icon: const Icon(Icons.delete_sweep_outlined),
              tooltip: '清空接收数据',
            ),
          ],
        ),
        const Divider(height: 1),
        Expanded(
          child: records.isEmpty
              ? const Center(
                  child: Text(
                    '暂无接收数据\n点击“读取一次”或开启“连续接收”',
                    textAlign: TextAlign.center,
                  ),
                )
              : ListView.separated(
                  itemCount: records.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (context, index) {
                    final record = records[index];
                    final isTimeBase = record.isTimeBase;
                    final timeText = record.timeValid
                        ? formatDeviceTimestamp(record.timestampMs)
                        : '时间无效';
                    return ListTile(
                      leading: Icon(
                        isTimeBase ? Icons.schedule : Icons.data_array,
                        color: isTimeBase
                            ? Colors.blue
                            : record.timeValid
                            ? Colors.teal
                            : Colors.orange,
                      ),
                      title: Text(
                        isTimeBase
                            ? '[$timeText] 时间基准已同步'
                            : '[$timeText]  ${record.spacedHex}',
                        style: const TextStyle(fontFamily: 'monospace'),
                      ),
                      subtitle: Text(
                        isTimeBase
                            ? 'TIME_BASE'
                            : '${record.byteLength} 字节 · 序号 ${record.sequence?.toString() ?? '未知'} · 电脑接收 ${record.receivedAt.toString().substring(11, 23)}',
                      ),
                      trailing: isTimeBase
                          ? null
                          : IconButton(
                              icon: const Icon(Icons.copy),
                              tooltip: '复制 HEX',
                              onPressed: () {
                                Clipboard.setData(
                                  ClipboardData(text: record.payloadHex),
                                );
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(content: Text('Payload 已复制')),
                                );
                              },
                            ),
                    );
                  },
                ),
        ),
      ],
    ),
  );
}

class SweepWorkspace extends StatefulWidget {
  const SweepWorkspace({
    super.key,
    required this.ports,
    required this.txPort,
    required this.rxPort,
    required this.txConnected,
    required this.rxConnected,
    required this.txStatus,
    required this.rxStatus,
    required this.baselineView,
    required this.running,
    required this.progress,
    required this.status,
    required this.amplitude,
    required this.subtractBaseline,
    required this.signal,
    required this.baseline,
    required this.onTxPortChanged,
    required this.onRxPortChanged,
    required this.onToggleTx,
    required this.onToggleRx,
    required this.onShowBaseline,
    required this.onShowSignal,
    required this.onStartSignal,
    required this.onStartBaseline,
    required this.onStop,
    required this.onExport,
    required this.onSubtractBaselineChanged,
    required this.correctedEnergy,
  });

  final List<String> ports;
  final String? txPort;
  final String? rxPort;
  final bool txConnected;
  final bool rxConnected;
  final String txStatus;
  final String rxStatus;
  final bool baselineView;
  final bool running;
  final int progress;
  final String status;
  final int amplitude;
  final bool subtractBaseline;
  final List<SweepPoint> signal;
  final List<SweepPoint> baseline;
  final ValueChanged<String?> onTxPortChanged;
  final ValueChanged<String?> onRxPortChanged;
  final VoidCallback onToggleTx;
  final VoidCallback onToggleRx;
  final VoidCallback onShowBaseline;
  final VoidCallback onShowSignal;
  final ValueChanged<int> onStartSignal;
  final VoidCallback onStartBaseline;
  final VoidCallback onStop;
  final VoidCallback onExport;
  final ValueChanged<bool> onSubtractBaselineChanged;
  final int Function(SweepPoint) correctedEnergy;

  @override
  State<SweepWorkspace> createState() => _SweepWorkspaceState();
}

class _SweepWorkspaceState extends State<SweepWorkspace> {
  late final TextEditingController _amplitude;
  String? _amplitudeError;

  @override
  void initState() {
    super.initState();
    _amplitude = TextEditingController(text: widget.amplitude.toString());
  }

  @override
  void didUpdateWidget(covariant SweepWorkspace oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.running && oldWidget.amplitude != widget.amplitude) {
      _amplitude.text = widget.amplitude.toString();
    }
  }

  @override
  void dispose() {
    _amplitude.dispose();
    super.dispose();
  }

  void _startSignal() {
    final value = int.tryParse(_amplitude.text.trim());
    if (value == null || value < 0 || value > 2047) {
      setState(() => _amplitudeError = '请输入 0..2047 的整数');
      return;
    }
    setState(() => _amplitudeError = null);
    widget.onStartSignal(value);
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final displayedPoints = widget.baselineView
          ? widget.baseline
          : widget.signal;
      final clippedPointCount = displayedPoints
          .where((point) => point.isClipped)
          .length;
      final txConnection = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('TX', style: TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 4),
          ConnectionCard(
            ports: widget.ports,
            selectedPort: widget.txPort,
            connected: widget.txConnected,
            status: widget.txStatus,
            onPortChanged: widget.onTxPortChanged,
            onToggle: widget.onToggleTx,
          ),
        ],
      );
      final rxConnection = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('RX', style: TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 4),
          ConnectionCard(
            ports: widget.ports,
            selectedPort: widget.rxPort,
            connected: widget.rxConnected,
            status: widget.rxStatus,
            onPortChanged: widget.onRxPortChanged,
            onToggle: widget.onToggleRx,
          ),
        ],
      );

      return ListView(
        padding: const EdgeInsets.all(12),
        children: [
          if (constraints.maxWidth >= 760)
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(child: txConnection),
                const SizedBox(width: 12),
                Expanded(child: rxConnection),
              ],
            )
          else ...[
            txConnection,
            const SizedBox(height: 8),
            rxConnection,
          ],
          const SizedBox(height: 12),
          Row(
            children: [
              SegmentedButton<bool>(
                segments: const [
                  ButtonSegment(
                    value: false,
                    icon: Icon(Icons.show_chart),
                    label: Text('幅频响应'),
                  ),
                  ButtonSegment(
                    value: true,
                    icon: Icon(Icons.graphic_eq),
                    label: Text('底噪'),
                  ),
                ],
                selected: {widget.baselineView},
                onSelectionChanged: widget.running
                    ? null
                    : (selection) => selection.first
                          ? widget.onShowBaseline()
                          : widget.onShowSignal(),
              ),
              const Spacer(),
              Chip(
                avatar: Icon(
                  widget.running ? Icons.sync : Icons.circle,
                  size: 16,
                  color: widget.running ? Colors.blue : Colors.green,
                ),
                label: Text(widget.status),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Wrap(
                spacing: 10,
                runSpacing: 10,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  const Chip(label: Text('1500–2100 Hz')),
                  const Chip(label: Text('步进 20 Hz')),
                  const Chip(label: Text('20 ms + 3 × 100 ms')),
                  if (!widget.baselineView)
                    SizedBox(
                      width: 180,
                      child: TextField(
                        controller: _amplitude,
                        enabled: !widget.running,
                        keyboardType: TextInputType.number,
                        decoration: InputDecoration(
                          labelText: '发射幅度',
                          suffixText: '0..2047',
                          border: const OutlineInputBorder(),
                          isDense: true,
                          errorText: _amplitudeError,
                        ),
                      ),
                    ),
                  if (!widget.baselineView)
                    FilledButton.icon(
                      onPressed: widget.running ? null : _startSignal,
                      icon: const Icon(Icons.play_arrow),
                      label: const Text('开始扫描'),
                    ),
                  if (!widget.baselineView)
                    OutlinedButton.icon(
                      onPressed: widget.running ? null : widget.onShowBaseline,
                      icon: const Icon(Icons.graphic_eq),
                      label: const Text('测量底噪'),
                    ),
                  if (widget.baselineView)
                    FilledButton.icon(
                      onPressed: widget.running ? null : widget.onStartBaseline,
                      icon: const Icon(Icons.play_arrow),
                      label: const Text('开始底噪测量'),
                    ),
                  if (widget.baselineView)
                    OutlinedButton.icon(
                      onPressed: widget.running ? null : widget.onShowSignal,
                      icon: const Icon(Icons.arrow_back),
                      label: const Text('返回幅频响应'),
                    ),
                  OutlinedButton.icon(
                    onPressed: widget.running ? widget.onStop : null,
                    icon: const Icon(Icons.stop),
                    label: const Text('停止'),
                  ),
                  IconButton(
                    onPressed: widget.signal.isEmpty && widget.baseline.isEmpty
                        ? null
                        : widget.onExport,
                    icon: const Icon(Icons.download),
                    tooltip: '导出 CSV',
                  ),
                  if (!widget.baselineView)
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Switch(
                          value: widget.subtractBaseline,
                          onChanged: widget.baseline.isEmpty
                              ? null
                              : widget.onSubtractBaselineChanged,
                        ),
                        const Text('扣除底噪'),
                      ],
                    ),
                ],
              ),
            ),
          ),
          if (widget.running || widget.progress != 0) ...[
            const SizedBox(height: 8),
            LinearProgressIndicator(value: widget.progress / 31),
          ],
          const SizedBox(height: 12),
          if (clippedPointCount != 0) ...[
            Align(
              alignment: Alignment.centerRight,
              child: Chip(
                avatar: const Icon(
                  Icons.warning_amber_rounded,
                  color: Colors.red,
                ),
                label: Text(
                  '削顶 $clippedPointCount/${displayedPoints.length}，结果不可信',
                ),
                side: BorderSide(color: Colors.red.withValues(alpha: 0.45)),
              ),
            ),
            const SizedBox(height: 8),
          ],
          SizedBox(
            height: 340,
            child: Card(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 12, 12, 6),
                child: CustomPaint(
                  painter: SweepChartPainter(
                    points: widget.baselineView
                        ? widget.baseline
                        : widget.signal,
                    baselinePoints: widget.baseline,
                    baselineView: widget.baselineView,
                    correctedEnergy: widget.correctedEnergy,
                  ),
                  child: const SizedBox.expand(),
                ),
              ),
            ),
          ),
          const SizedBox(height: 12),
          SweepDataTable(
            points: widget.baselineView ? widget.baseline : widget.signal,
            correctedEnergy: widget.baselineView
                ? null
                : widget.correctedEnergy,
          ),
        ],
      );
    },
  );
}

class SweepChartPainter extends CustomPainter {
  const SweepChartPainter({
    required this.points,
    required this.baselinePoints,
    required this.baselineView,
    required this.correctedEnergy,
  });

  final List<SweepPoint> points;
  final List<SweepPoint> baselinePoints;
  final bool baselineView;
  final int Function(SweepPoint) correctedEnergy;

  @override
  void paint(Canvas canvas, Size size) {
    const left = 52.0;
    const right = 16.0;
    const top = 12.0;
    const bottom = 34.0;
    final plot = Rect.fromLTRB(
      left,
      top,
      size.width - right,
      size.height - bottom,
    );
    final axis = Paint()
      ..color = Colors.grey.shade500
      ..strokeWidth = 1;
    final grid = Paint()
      ..color = Colors.grey.withValues(alpha: 0.2)
      ..strokeWidth = 1;
    for (var frequency = 1500; frequency <= 2100; frequency += 100) {
      final x = plot.left + ((frequency - 1500) / 600) * plot.width;
      canvas.drawLine(Offset(x, plot.top), Offset(x, plot.bottom), grid);
      _label(canvas, '$frequency', Offset(x - 18, plot.bottom + 8));
    }
    canvas.drawLine(plot.bottomLeft, plot.topLeft, axis);
    canvas.drawLine(plot.bottomLeft, plot.bottomRight, axis);

    if (points.isEmpty) {
      _label(canvas, '暂无测量数据', Offset(plot.center.dx - 42, plot.center.dy - 8));
      return;
    }

    final values = points
        .map(
          (point) => baselineView ? point.meanEnergy : correctedEnergy(point),
        )
        .toList();
    final maximum = values.fold<int>(1, (a, b) => math.max(a, b));
    final scale = SweepChartScale.fromValues(values);
    double yForDb(double db) =>
        plot.top +
        ((scale.maximumDb - db) / (scale.maximumDb - scale.minimumDb)) *
            plot.height;

    for (
      var db = scale.maximumDb;
      db >= scale.minimumDb - (scale.gridStepDb / 100);
      db -= scale.gridStepDb
    ) {
      final y = yForDb(db);
      canvas.drawLine(Offset(plot.left, y), Offset(plot.right, y), grid);
      _label(canvas, scale.formatLabel(db), Offset(4, y - 7));
    }

    final hasClipping = points.any((point) => point.isClipped);
    final path = Path();
    for (var index = 0; index < points.length; ++index) {
      final point = points[index];
      final db = SweepChartScale.relativeDb(values[index], maximum);
      final x = plot.left + ((point.frequencyHz - 1500) / 600) * plot.width;
      final y = yForDb(db);
      if (index == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    final line = Paint()
      ..color = hasClipping
          ? Colors.red.shade600
          : baselineView
          ? Colors.orange.shade700
          : Colors.teal.shade600
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke;
    canvas.drawPath(path, line);
    for (var index = 0; index < points.length; ++index) {
      final point = points[index];
      final db = SweepChartScale.relativeDb(values[index], maximum);
      final x = plot.left + ((point.frequencyHz - 1500) / 600) * plot.width;
      final y = yForDb(db);
      canvas.drawCircle(
        Offset(x, y),
        3,
        Paint()..color = point.isClipped ? Colors.red.shade700 : line.color,
      );
    }
  }

  void _label(Canvas canvas, String text, Offset offset) {
    final painter = TextPainter(
      text: TextSpan(
        text: text,
        style: const TextStyle(fontSize: 11, color: Colors.grey),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    painter.paint(canvas, offset);
  }

  @override
  bool shouldRepaint(covariant SweepChartPainter oldDelegate) => true;
}

class SweepDataTable extends StatelessWidget {
  const SweepDataTable({
    super.key,
    required this.points,
    required this.correctedEnergy,
  });

  final List<SweepPoint> points;
  final int Function(SweepPoint)? correctedEnergy;

  @override
  Widget build(BuildContext context) => Card(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.all(12),
          child: Text(
            '测量数据（${points.length}/31）',
            style: const TextStyle(fontWeight: FontWeight.bold),
          ),
        ),
        const Divider(height: 1),
        if (points.isEmpty)
          const SizedBox(height: 100, child: Center(child: Text('暂无测量数据')))
        else
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: DataTable(
              columns: [
                const DataColumn(label: Text('频率/Hz')),
                const DataColumn(label: Text('平均能量'), numeric: true),
                if (correctedEnergy != null)
                  const DataColumn(label: Text('校正能量'), numeric: true),
                const DataColumn(label: Text('最小值'), numeric: true),
                const DataColumn(label: Text('最大值'), numeric: true),
                const DataColumn(label: Text('削顶'), numeric: true),
              ],
              rows: points
                  .map(
                    (point) => DataRow(
                      color: point.clipCount == 0
                          ? null
                          : WidgetStatePropertyAll(
                              Colors.red.withValues(alpha: 0.08),
                            ),
                      cells: [
                        DataCell(Text(point.frequencyHz.toString())),
                        DataCell(Text(point.meanEnergy.toString())),
                        if (correctedEnergy != null)
                          DataCell(Text(correctedEnergy!(point).toString())),
                        DataCell(Text(point.minEnergy.toString())),
                        DataCell(Text(point.maxEnergy.toString())),
                        DataCell(Text(point.clipCount.toString())),
                      ],
                    ),
                  )
                  .toList(),
            ),
          ),
      ],
    ),
  );
}

class ConnectionCard extends StatelessWidget {
  const ConnectionCard({
    super.key,
    required this.ports,
    required this.selectedPort,
    required this.connected,
    required this.status,
    required this.onPortChanged,
    required this.onToggle,
  });
  final List<String> ports;
  final String? selectedPort;
  final bool connected;
  final String status;
  final ValueChanged<String?> onPortChanged;
  final VoidCallback onToggle;
  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(12),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final selector = DropdownButtonFormField<String>(
            isExpanded: true,
            initialValue: ports.contains(selectedPort) ? selectedPort : null,
            decoration: const InputDecoration(
              labelText: '串口',
              border: OutlineInputBorder(),
              isDense: true,
            ),
            items: ports
                .map(
                  (p) => DropdownMenuItem(
                    value: p,
                    child: Text(
                      p,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                )
                .toList(),
            onChanged: connected ? null : onPortChanged,
          );
          final controls = Column(
            children: [
              Text(
                '115200-8-N-1',
                style: Theme.of(context).textTheme.labelSmall,
              ),
              FilledButton(
                onPressed: selectedPort == null ? null : onToggle,
                child: Text(connected ? '关闭' : '打开'),
              ),
            ],
          );
          final indicator = Chip(
            avatar: Icon(
              Icons.circle,
              size: 12,
              color: connected ? Colors.green : Colors.grey,
            ),
            label: Text(status, maxLines: 1, overflow: TextOverflow.ellipsis),
          );
          if (constraints.maxWidth < 520) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(child: selector),
                    const SizedBox(width: 12),
                    controls,
                  ],
                ),
                const SizedBox(height: 6),
                Align(alignment: Alignment.centerLeft, child: indicator),
              ],
            );
          }
          return Row(
            children: [
              Expanded(child: selector),
              const SizedBox(width: 8),
              controls,
              const SizedBox(width: 8),
              indicator,
            ],
          );
        },
      ),
    ),
  );
}

class Panel extends StatelessWidget {
  const Panel({
    super.key,
    required this.title,
    required this.color,
    required this.child,
  });
  final String title;
  final Color color;
  final Widget child;
  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            title,
            style: Theme.of(context).textTheme.headlineSmall?.copyWith(
              color: color,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 8),
          Expanded(child: child),
        ],
      ),
    ),
  );
}

class CommandRow extends StatelessWidget {
  const CommandRow({super.key, required this.label, required this.child});
  final String label;
  final Widget child;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 6),
    child: Row(
      children: [
        SizedBox(width: 48, child: Text(label)),
        Expanded(child: child),
      ],
    ),
  );
}

class LogView extends StatelessWidget {
  const LogView({super.key, required this.logs, required this.onClear});
  final List<CommandLog> logs;
  final VoidCallback onClear;
  @override
  Widget build(BuildContext context) => Card(
    child: Column(
      children: [
        Row(
          children: [
            const Padding(padding: EdgeInsets.all(10), child: Text('命令日志')),
            const Spacer(),
            IconButton(
              onPressed: onClear,
              icon: const Icon(Icons.delete_outline),
              tooltip: '清空',
            ),
          ],
        ),
        const Divider(height: 1),
        Expanded(
          child: logs.isEmpty
              ? const Center(child: Text('暂无日志'))
              : ListView.builder(
                  itemCount: logs.length,
                  itemBuilder: (_, i) {
                    final x = logs[i];
                    return ListTile(
                      dense: true,
                      title: Text('${x.direction}  ${x.text}'),
                      subtitle: Text(x.time.toString().substring(11, 19)),
                    );
                  },
                ),
        ),
      ],
    ),
  );
}
