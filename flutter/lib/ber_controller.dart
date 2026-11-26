import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'ber_data.dart';
import 'ber_command_writer.dart';

Duration Function() _berClock() {
  final watch = Stopwatch()..start();
  return () => watch.elapsed;
}

abstract class BerAudit {
  String get path;
  void log(String kind, Map<String, Object?> fields);
  void finish(Map<String, Object?> report);
}

class BerFileAudit implements BerAudit {
  BerFileAudit(Directory root, {String prefix = 'ber'}) {
    final id = DateTime.now().microsecondsSinceEpoch;
    final directory = Directory('${root.path}/${prefix}_$id');
    directory.createSync(recursive: true);
    path = directory.absolute.path;
    _raw = File('$path/raw.jsonl').openSync(mode: FileMode.writeOnly);
  }
  @override
  late final String path;
  late final RandomAccessFile _raw;
  @override
  void log(String kind, Map<String, Object?> fields) {
    _raw.writeStringSync(
      '${jsonEncode({'utc': DateTime.now().toUtc().toIso8601String(), 'kind': kind, ...fields})}\n',
    );
    _raw.flushSync();
  }

  @override
  void finish(Map<String, Object?> report) {
    try {
      log('report', report);
      File('$path/failure_evidence.json').writeAsStringSync(
        const JsonEncoder.withIndent(
          '  ',
        ).convert(report['failure_evidence'] ?? []),
        flush: true,
      );
      File('$path/report.json').writeAsStringSync(
        const JsonEncoder.withIndent('  ').convert(report),
        flush: true,
      );
    } finally {
      _raw.closeSync();
    }
  }
}

class BerStopped implements Exception {
  @override
  String toString() => '用户停止；未确认完成的包保留为未决';
}

class BerCommandFailure implements Exception {
  BerCommandFailure(
    this.tx,
    this.command,
    this.phase,
    this.elapsed,
    this.cause,
  );
  final bool tx;
  final String command, phase;
  final Duration elapsed;
  final Object cause;
  Map<String, Object?> toJson() => {
    'device': tx ? 'TX' : 'RX',
    'command': command,
    'phase': phase,
    'elapsed_ms': elapsed.inMilliseconds,
    'cause': '$cause',
  };
  @override
  String toString() =>
      '${tx ? 'TX' : 'RX'}「$command」${cause is TimeoutException ? '响应超时' : '通信失败'}'
      '（阶段：$phase，等待${(elapsed.inMilliseconds / 1000).toStringAsFixed(2)}秒）；'
      '当前发送是否完成未获确认，不会重发SEND。原因：$cause';
}

class BerConfig {
  const BerConfig({
    required this.count,
    required this.batch,
    required this.amplitude,
    required this.receiveWait,
  });
  final int count, batch, amplitude;
  final Duration receiveWait;
  void validate() {
    if (count < 1 ||
        count > 100000 ||
        batch < 0 ||
        batch > 0xffffffff ||
        amplitude < 0 ||
        amplitude > 2047 ||
        receiveWait.isNegative ||
        receiveWait > const Duration(seconds: 60)) {
      throw const FormatException('包数1..100000，批次uint32，幅度0..2047，接收等待0..60秒');
    }
  }
}

/// Host-only options used by the amplitude scanner. A reused base is checked
/// against both endpoints before any DATA is sent.
class BerScanOptions {
  const BerScanOptions({this.preparationAmplitude, this.expectedBase});
  final int? preparationAmplitude, expectedBase;
}

class BerController {
  BerController({
    required this.command,
    required this.emergencyStop,
    required this.changed,
    required this.auditFactory,
    this.invalidateConnections,
    Duration Function()? now,
    Future<void> Function(Duration)? sleep,
  }) : now = now ?? _berClock(),
       sleep = sleep ?? Future<void>.delayed;
  final Future<String> Function(bool, String) command;
  final Future<void> Function(bool, String) emergencyStop;
  final Future<void> Function()? invalidateConnections;
  final void Function() changed;
  final BerAudit Function() auditFactory;
  final Duration Function() now;
  final Future<void> Function(Duration) sleep;
  BerAudit? _audit;
  BerLedger? ledger;
  BerCapture? lastCapture;
  Map<String, int> status = {}, health = {};
  Map<String, String> txDiagnostics = {};
  Map<String, String> txDiagnosticsInitial = {};
  String message = '连接 TX 和 RX 后可开始；状态检查只需 RX';
  String state = 'idle', phase = '等待';
  String? error, exportPath;
  String setupTx = 'not_started';
  bool setupRxConfirmed = false;
  String? failedPhase;
  BerCommandFailure? commandFailure;
  String connectionCheck = '尚未自检';
  String operation = 'trial';
  bool running = false, stopRequested = false;
  bool _finishPacketOnStop = false, _packetInFlight = false;
  int? confirmedBase;
  bool cleanupFailed = false;
  final _poisoned = <bool>{};
  bool get requiresReconnect => _poisoned.isNotEmpty;
  int target = 0, progress = 0;
  final events = <String>[];
  void connectionOpened(bool isTx) {
    _poisoned.remove(isTx);
    changed();
  }

  void stop() {
    stopRequested = true;
    update(_finishPacketOnStop ? '正在停止：等待当前包发送、接收及证据保存完成' : '正在停止，保留当前包状态');
  }

  void update(String text) {
    message = text;
    events.insert(0, text);
    if (events.length > 150) events.removeLast();
    changed();
  }

  void log(String kind, Map<String, Object?> fields) =>
      _audit?.log(kind, fields);
  void raw(bool tx, List<int> bytes) {
    if (running && _audit != null && bytes.isNotEmpty) {
      log('serial_rx', {'device': tx ? 'TX' : 'RX', 'rx_hex': berHex(bytes)});
    }
  }

  void rawTransmit(bool tx, List<int> bytes) {
    if (running && _audit != null && bytes.isNotEmpty) {
      log('serial_tx', {'device': tx ? 'TX' : 'RX', 'tx_hex': berHex(bytes)});
    }
  }

  void _checkStop() {
    if (stopRequested && !(_finishPacketOnStop && _packetInFlight)) {
      throw BerStopped();
    }
  }

  Future<void> pause(Duration duration) async {
    _checkStop();
    await sleep(duration);
    _checkStop();
  }

  Future<String> request(bool tx, String cmd, {bool cancellable = true}) async {
    if (cancellable) _checkStop();
    if (_poisoned.contains(tx)) throw StateError('串口响应未决，需要断开并重新连接');
    log('command', {
      'device': tx ? 'TX' : 'RX',
      'command': cmd,
      'tx_hex': berHex(ascii.encode('$cmd\n')),
    });
    late String reply;
    final started = now();
    try {
      reply = await command(tx, cmd);
    } catch (e) {
      // Writes, disconnects and response timeouts can all leave a late ACK.
      // Invalidate BOTH channels before any new session, never retry SEND.
      _poisoned.addAll([true, false]);
      final failure = BerCommandFailure(tx, cmd, phase, now() - started, e);
      commandFailure ??= failure;
      log('command_error', failure.toJson());
      throw failure;
    }
    log('reply', {'device': tx ? 'TX' : 'RX', 'command': cmd, 'line': reply});
    return reply;
  }

  Future<String> expect(bool tx, String cmd, [String prefix = 'OK']) async {
    final line = await request(tx, cmd);
    if (line != prefix && !line.startsWith('$prefix ')) {
      throw StateError('$cmd: $line');
    }
    return line;
  }

  Future<Uint8List?> binary(
    String cmd,
    String name,
    int size, {
    bool cancellable = true,
  }) async {
    for (var i = 0; i < 3; i++) {
      final line = await request(false, cmd, cancellable: cancellable);
      if (name == 'RECORD' && line == 'OK BER EMPTY') return null;
      if (line == 'ERR BER SPI') {
        ledger?.transportErrors++;
        ledger?.spiErrors++;
        continue;
      }
      if (line.startsWith('ERR')) throw StateError(line);
      try {
        return berTransport(line, name, size);
      } on FormatException {
        ledger?.transportErrors++;
        ledger?.crcTransportErrors++;
      }
    }
    throw StateError('$cmd 连续三次传输校验失败；未弹出诊断队列');
  }

  Future<Map<String, int>> readStatus() async {
    status = berStatus((await binary('BER STATUS', 'STATUS', 32))!);
    ledger?.diagnostic = status;
    changed();
    return status;
  }

  Future<Map<String, int>> readHealth() async {
    health = berHealth((await binary('BER HEALTH', 'HEALTH', 20))!);
    log('fpga_health', health);
    changed();
    return health;
  }

  Future<void> readTxDiagnostics() async {
    final line = await request(true, 'UART DIAG', cancellable: false);
    if (!line.startsWith('OK UART DIAG ')) {
      txDiagnostics = {};
      log('tx_uart_diag_unavailable', {'line': line});
      return;
    }
    final values = {
      for (final m in RegExp(r'(\w+)=([^\s]*)').allMatches(line)) m[1]!: m[2]!,
    };
    for (final key in [
      'rxerr',
      'rxovf',
      'lineovf',
      'cmderr',
      'badlen',
      'rendermax',
      'uartbudget',
      'renderlate',
      'renders',
      'dwt',
    ]) {
      if (!RegExp(r'^\d+$').hasMatch(values[key] ?? '')) {
        throw FormatException('TX UART DIAG字段无效：$key');
      }
    }
    final hex = values['badhex'];
    if (hex == null ||
        !RegExp(r'^(?:[0-9A-Fa-f]{2})*$').hasMatch(hex) ||
        hex.length > 64 ||
        hex.length > int.parse(values['badlen']!) * 2 ||
        !['0', '1'].contains(values['dwt'])) {
      throw const FormatException('TX UART DIAG捕获或周期状态无效');
    }
    txDiagnostics = values;
    log('tx_uart_diag', txDiagnostics);
    changed();
  }

  Future<Map<String, String>> rxStatus() async {
    final fields = berFields(await expect(false, 'STATUS'));
    for (final k in ['fpga', 'uart_err', 'rx_restart', 'tx_err', 'overflow']) {
      if (!RegExp(r'^\d+$').hasMatch(fields[k] ?? '')) {
        throw FormatException('RX缺少字段 $k');
      }
    }
    if (fields['fpga'] != '1') throw StateError('RX FPGA未连接');
    return fields;
  }

  Future<Map<String, String>> txStatus() async {
    final fields = berFields(await expect(true, 'STATUS'));
    for (final k in [
      'run',
      'fs',
      'err',
      'dmaerr',
      'hde',
      'hae',
      'mode',
      'time_base_pending',
      'time_valid',
      'base_s',
      'len',
    ]) {
      if (!RegExp(r'^\d+$').hasMatch(fields[k] ?? '')) {
        throw FormatException('TX缺少字段 $k');
      }
    }
    if (fields['mod'] != 'FSK' ||
        fields['fs'] != '48000' ||
        ['err', 'dmaerr', 'hde', 'hae'].any((k) => fields[k] != '0') ||
        !['0', '1'].contains(fields['run']) ||
        !['0', '1'].contains(fields['time_base_pending'])) {
      throw StateError('TX模式/采样率或DMA/HAL状态异常：$fields');
    }
    return fields;
  }

  Future<void> ensureRxFsk() async {
    // MOD is a deferred FPGA transaction, including a same-mode commit.
    // Drain an existing transaction before deciding whether one is necessary.
    final deadline = now() + const Duration(seconds: 5);
    var submitted = false;
    while (true) {
      final line = await expect(false, 'ASK STATUS', 'OK ASK STATUS');
      final fields = berFields(line);
      if (!['FSK', 'OOK'].contains(fields['mode']) ||
          !['0', '1'].contains(fields['pending']) ||
          !['0', '1'].contains(fields['error'])) {
        throw FormatException('RX配置状态字段无效：$line');
      }
      if (fields['error'] != '0') {
        throw StateError('RX配置被拒绝：$line');
      }
      if (fields['pending'] == '0' && fields['mode'] == 'FSK') {
        return;
      }
      if (now() >= deadline) {
        // Complete read-only reply; no reset, parameter change or SEND retry.
        final tuning = await request(false, 'FSK STATUS');
        throw StateError(
          '等待RX FSK配置生效超时（5秒），未发测试包；'
          'ASK状态：$line；门限/忙状态：$tuning',
        );
      }
      if (fields['pending'] == '0' && !submitted) {
        await expect(false, 'MOD FSK', 'OK MOD FSK');
        submitted = true;
      } else {
        update(
          '等待RX配置生效：mode=${fields['mode']} pending=${fields['pending']} error=${fields['error']}',
        );
        await pause(const Duration(milliseconds: 100));
      }
    }
  }

  Future<void> transmit(int bodyBytes) async {
    final before = await txStatus();
    if (before['run'] != '0' ||
        (bodyBytes == 41 &&
            (before['len'] != '32' ||
                before['time_valid'] != '1' ||
                before['time_base_pending'] != '0')) ||
        (bodyBytes == 10 && before['time_base_pending'] != '1')) {
      throw StateError('TX发送前状态不符合本次DATA/TIME_BASE');
    }
    final start = now();
    final duration = Duration(milliseconds: (32 + bodyBytes * 8) * 10 + 200);
    var seen = false;
    await expect(true, 'SEND');
    // Finish only an accepted send. A stop during preflight/ARM must still
    // prevent a DATA SEND that has not yet been submitted.
    if (_finishPacketOnStop) _packetInFlight = true;
    while (now() - start < duration + const Duration(seconds: 3)) {
      final s = await txStatus();
      final elapsed = now() - start;
      if (s['run'] == '1') {
        seen = true;
        if (s['mode'] != '5') throw StateError('TX没有运行PACKET模式');
      } else {
        if (!seen || elapsed < duration - const Duration(milliseconds: 100)) {
          throw StateError('不能确认发完：未观察到运行或过早结束');
        }
        final guard = duration + const Duration(milliseconds: 100) - elapsed;
        if (guard > Duration.zero) await sleep(guard);
        final end = await txStatus();
        if (end['run'] != '0' || end['time_base_pending'] != '0') {
          throw StateError('发送完成复核失败');
        }
        return;
      }
      await sleep(const Duration(milliseconds: 150));
    }
    throw StateError('超过预计帧时长仍未停止；本包未决');
  }

  Future<void> drain() async {
    final line = await expect(false, 'READ', 'OK DATA');
    final m = RegExp(
      r'^OK DATA ([0-9A-Fa-f]*) time_valid=[01] timestamp_ms=\d+$',
    ).firstMatch(line);
    if (m == null) {
      throw const FormatException('普通READ响应格式错误');
    }
    final p = berUnhex(m[1]!);
    log('normal_read', {'payload_hex': berHex(p), 'new': ledger!.delivery(p)});
    for (var i = 0; i < 16; i++) {
      final s = await readStatus();
      if (s['count'] == 0) return;
      final bytes = await binary('BER READ', 'RECORD', 64);
      if (bytes == null) throw StateError('诊断队列意外变空');
      log('diagnostic_raw', {
        'record_hex': berHex(bytes),
      }); // flushed before POP
      final c = BerCapture.parse(bytes);
      lastCapture = c;
      final matched = ledger!.capture(c);
      log('diagnostic_alignment', {'capture_id': c.id, 'matched': matched});
      final pop = await request(false, 'BER POP ${c.id}');
      final after = await readStatus();
      if (!['OK BER ACK', 'ERR BER SPI'].contains(pop) ||
          after['popped'] != s['popped']! + 1) {
        throw StateError('POP结果未决，未重发：$pop');
      }
      log('diagnostic_pop', {'capture_id': c.id, 'popped': after['popped']});
      changed();
    }
    throw StateError('诊断记录持续进入，停止本次试验');
  }

  Future<void> checkObserverCapability() async {
    final line = await request(false, 'BER OBS INFO');
    if (line.startsWith('ERR')) {
      throw StateError('逐包阶段诊断需要配套新版RX FPGA和RX MCU；请升级后重试。$line');
    }
    if (ascii.decode(berTransport(line, 'OBS INFO', 4)) != 'BO01') {
      throw const FormatException('逐包观察器签名不符');
    }
  }

  Future<int> armObserver(int sequence) async {
    // Control is exactly once: a transport CRC failure must NOT re-ARM it.
    final line = await request(false, 'BER OBS ARM');
    final bytes = berTransport(line, 'OBS ARM', 4);
    final id = ByteData.sublistView(bytes).getUint32(0, Endian.little);
    log('stage_window_armed', {'sequence': sequence, 'window_id': id});
    return id;
  }

  Future<void> collectEvidence(BerAttempt attempt, int windowId) async {
    final stop = await request(false, 'BER OBS STOP', cancellable: false);
    if (stop != 'OK BER ACK') throw StateError('观察窗口冻结失败：$stop');
    final summary = (await binary(
      'BER OBS READ',
      'OBS READ',
      96,
      cancellable: false,
    ))!;
    log('stage_summary_raw', {
      'sequence': attempt.sequence,
      'window_id': windowId,
      'summary_hex': berHex(summary),
    });
    final count = BerEvidence.eventCount(summary);
    if (ByteData.sublistView(summary).getUint32(4, Endian.little) != windowId) {
      throw const FormatException('逐包观察窗口ID变化；停止，避免覆盖证据');
    }
    final pages = <Uint8List>[];
    for (var i = 0; i < (count + 1) ~/ 2; i++) {
      final page = (await binary(
        'BER OBS PAGE $i',
        'OBS PAGE',
        64,
        cancellable: false,
      ))!;
      log('stage_events_raw', {
        'sequence': attempt.sequence,
        'window_id': windowId,
        'page': i,
        'page_hex': berHex(page),
      });
      pages.add(page);
    }
    final evidence = BerEvidence.parse(summary, pages, windowId);
    attempt.evidence = evidence;
    final capture = ledger!.captures[attempt.sequence];
    attempt.stageDiagnosis = evidence.diagnose(
      delivered: ledger!.delivered.contains(attempt.sequence),
      complete: attempt.tx == 'complete' && attempt.windowComplete,
      aligned: capture != null,
      payloadErrors: capture?.errors(attempt.payload),
    );
    log('stage_evidence', {
      'sequence': attempt.sequence,
      'diagnosis': attempt.stageDiagnosis,
      'evidence': evidence.toJson(),
    });
    if (attempt.stageDiagnosis!['code'] != 'delivered') {
      update(
        '第${attempt.sequence + 1}包：${attempt.stageDiagnosis!['label']}（已保存窗口证据）',
      );
    }
    changed();
  }

  Future<void> inspect() async {
    if (running || requiresReconnect) return;
    running = true;
    stopRequested = false;
    state = 'inspecting';
    operation = 'inspect';
    error = null;
    commandFailure = null;
    failedPhase = null;
    phase = '读取诊断状态';
    update('读取诊断状态/健康寄存器/队首，不POP');
    try {
      _audit = auditFactory();
      exportPath = _audit!.path;
      await readStatus();
      await readHealth();
      final bytes = await binary('BER READ', 'RECORD', 64);
      if (bytes != null) log('diagnostic_raw', {'record_hex': berHex(bytes)});
      lastCapture = bytes == null ? null : BerCapture.parse(bytes);
      state = 'inspected';
      update(
        '状态检查完成；${lastCapture == null ? '诊断队列为空' : '队首#${lastCapture!.id}仍保留'}',
      );
    } catch (e) {
      state = 'aborted';
      failedPhase = phase;
      error = '$e';
      update('状态检查失败：$e');
    } finally {
      await finish(inspectOnly: true);
    }
  }

  Future<void> checkConnections() async {
    if (running || requiresReconnect) return;
    running = true;
    stopRequested = false;
    state = 'checking';
    operation = 'connection_check';
    error = null;
    commandFailure = null;
    failedPhase = null;
    setupTx = 'not_started';
    setupRxConfirmed = false;
    target = progress = 0;
    ledger = null;
    lastCapture = null;
    status = {};
    health = {};
    txDiagnostics = {};
    txDiagnosticsInitial = {};
    connectionCheck = '自检中';
    update('双串口只读自检：不发射、不配置、不清空诊断记录');
    try {
      _audit = auditFactory();
      exportPath = _audit!.path;
      for (var i = 0; i < 5; i++) {
        phase = '串口自检 ${i + 1}/5';
        final tx = berFields(await expect(true, 'STATUS'));
        if (!['0', '1'].contains(tx['run']) || tx['mod'] == null) {
          throw const FormatException('TX STATUS字段不完整');
        }
        final rx = await rxStatus();
        log('connection_check', {'round': i + 1, 'tx': tx, 'rx': rx});
        update('串口自检 ${i + 1}/5：TX/RX STATUS均已回复；TX run=${tx['run']}');
        if (i < 4) await pause(const Duration(milliseconds: 400));
      }
      await readHealth();
      await readTxDiagnostics();
      state = 'checked';
      connectionCheck = '5轮STATUS通过';
      update('串口只读自检通过；这不能证明发射期间串口或声学链路正常');
    } catch (e) {
      failedPhase = phase;
      state = e is BerStopped ? 'stopped' : 'aborted';
      error = '$e';
      connectionCheck = '自检未完成';
      update('串口自检中止：$e');
    } finally {
      await finish(inspectOnly: true);
    }
  }

  Future<void> start(BerConfig config, {BerScanOptions? scan}) async {
    if (running || requiresReconnect) return;
    config.validate();
    if (scan?.preparationAmplitude case final amplitude?) {
      if (amplitude < 1 || amplitude > 2047) {
        throw const FormatException('准备幅度范围1..2047');
      }
    }
    _finishPacketOnStop = scan != null;
    _packetInFlight = false;
    confirmedBase = null;
    cleanupFailed = false;
    running = true;
    stopRequested = false;
    state = 'running';
    operation = 'trial';
    exportPath = null;
    error = null;
    setupTx = 'not_started';
    setupRxConfirmed = false;
    failedPhase = null;
    commandFailure = null;
    target = config.count;
    progress = 0;
    ledger = BerLedger(config.batch);
    txDiagnostics = {};
    txDiagnosticsInitial = {};
    lastCapture = null;
    events.clear();
    update('准备双串口FSK测试');
    Duration? measurementStart;
    try {
      _audit = auditFactory();
      exportPath = _audit!.path;
      log('configuration', {
        'count': config.count,
        'batch': config.batch,
        'amplitude': config.amplitude,
        'rx_wait_ms': config.receiveWait.inMilliseconds,
        if (scan != null)
          'scan': {
            'preparation_amplitude': scan.preparationAmplitude,
            'expected_base_s': scan.expectedBase,
          },
        'control_byte_gap_us': berCommandByteGap.inMicroseconds,
      });
      phase = '配置';
      await expect(true, 'STOP');
      await expect(true, 'MOD FSK');
      await expect(true, 'MODE PACKET');
      await expect(
        true,
        'AMP ${scan?.preparationAmplitude ?? config.amplitude}',
      );
      final configured = await txStatus();
      if (scan != null &&
          (configured['run'] != '0' ||
              configured['amp'] !=
                  '${scan.preparationAmplitude ?? config.amplitude}')) {
        throw StateError('准备幅度回读不符或TX未停止：$configured');
      }
      await readTxDiagnostics();
      txDiagnosticsInitial = Map.of(txDiagnostics);
      await expect(false, 'PING', 'OK PONG');
      await ensureRxFsk();
      await checkObserverCapability();
      await expect(false, 'BER STOP', 'OK BER ACK');
      final deadline = now() + const Duration(seconds: 2);
      while ((await readStatus())['state']! & 2 != 0) {
        if (now() >= deadline) {
          throw StateError('BER STOP后仍忙');
        }
        await pause(const Duration(milliseconds: 50));
      }
      await expect(false, 'BER CLEAR', 'OK BER ACK');
      if (scan?.expectedBase == null) {
        phase = '时间基准';
        update('建立TIME_BASE，未计入测试包');
        final t = DateTime.now();
        String n(int v) => '$v'.padLeft(2, '0');
        await expect(
          true,
          'SET_TIME ${t.year}-${n(t.month)}-${n(t.day)} ${n(t.hour)}:${n(t.minute)}:${n(t.second)}',
        );
        await expect(true, 'TIME_BASE');
        setupTx = 'pending';
        log('setup_tx', {'state': setupTx});
        try {
          await transmit(10);
          setupTx = 'complete';
        } catch (_) {
          setupTx = 'unresolved';
          rethrow;
        } finally {
          _packetInFlight = false;
          log('setup_tx', {'state': setupTx});
        }
        final base = (await txStatus())['base_s'];
        final until = now() + config.receiveWait;
        while (true) {
          final s = await rxStatus();
          log('time_base_rx_check', {'expected_base_s': base, 'rx_status': s});
          if (s['base_s'] == base &&
              s['type'] == '1' &&
              s['time_valid'] == '1') {
            setupRxConfirmed = true;
            break;
          }
          if (now() >= until) {
            ledger!.rxFinal = s;
            ledger!.healthFinal = await readHealth();
            log('time_base_unconfirmed', {
              'expected_base_s': base,
              'rx_status': s,
              'fpga_health': health,
              'data_sent': false,
            });
            throw StateError(
              'RX未确认本次TIME_BASE：期望base_s=$base，'
              '实收base_s=${s['base_s']} type=${s['type']} '
              'time_valid=${s['time_valid']}；未发送DATA测试包',
            );
          }
          await pause(const Duration(milliseconds: 100));
        }
        confirmedBase = int.parse(base!);
      } else {
        phase = '复核扫描时间基准';
        final tx = await txStatus(), rx = await rxStatus();
        if (tx['base_s'] != '${scan!.expectedBase}' ||
            rx['base_s'] != '${scan.expectedBase}' ||
            tx['time_valid'] != '1' ||
            rx['time_valid'] != '1' ||
            tx['time_base_pending'] != '0') {
          throw StateError('扫描时间基准已变化，停止扫描；未发送本档DATA');
        }
        confirmedBase = scan.expectedBase;
        setupTx = 'reused';
        setupRxConfirmed = true;
        log('setup_reused', {'base_s': confirmedBase});
      }
      if (scan != null) {
        phase = '设置并复核扫描幅度';
        await expect(true, 'AMP ${config.amplitude}');
        final tx = await txStatus();
        if (tx['amp'] != '${config.amplitude}' || tx['run'] != '0') {
          throw StateError('TX幅度回读不符或仍在发送：$tx');
        }
        await pause(const Duration(milliseconds: 200));
      }
      await expect(false, 'BER START', 'OK BER ACK');
      ledger!.rxInitial = await rxStatus();
      ledger!.healthInitial = await readHealth();
      measurementStart = now();
      for (var sequence = 0; sequence < config.count; sequence++) {
        _checkStop();
        phase = '准备包';
        final a = BerAttempt(sequence, berPayload(config.batch, sequence));
        await expect(true, 'META 2 0 ${sequence & 255}');
        await expect(true, 'PAYLOAD ${berHex(a.payload)}');
        ledger!.attempts[sequence] = a;
        log('attempt', a.toJson());
        final start = now();
        int? observerId;
        Object? primaryError;
        _checkStop();
        try {
          phase = '开启逐包观察窗口';
          observerId = await armObserver(sequence);
          phase = '物理发送';
          update('包 ${sequence + 1}/${config.count}：等待TX发完');
          try {
            await transmit(41);
            a.tx = 'complete';
            log('tx_complete', {'sequence': sequence});
          } catch (_) {
            a.tx = 'unresolved';
            log('tx_unresolved', {'sequence': sequence});
            rethrow;
          }
          phase = '接收/诊断';
          update('包 ${sequence + 1}/${config.count}：读取正常交付与诊断');
          final end = now() + config.receiveWait;
          while (true) {
            await drain();
            if (now() >= end) {
              a.windowComplete = true;
              break;
            }
            await pause(const Duration(milliseconds: 100));
          }
        } catch (e) {
          primaryError = e;
          rethrow;
        } finally {
          final originalPhase = phase;
          try {
            if (observerId != null && !requiresReconnect) {
              try {
                phase = '冻结并保存逐包证据';
                await collectEvidence(a, observerId);
              } catch (e) {
                a.evidenceError = '$e';
                log('stage_evidence_error', {
                  'sequence': sequence,
                  'error': '$e',
                });
                if (primaryError == null) rethrow;
              }
            } else if (observerId != null) {
              a.evidenceError = '串口响应未决，未继续发送诊断命令；窗口可能未完成';
            }
          } finally {
            if (primaryError != null) phase = originalPhase;
            a.elapsed = (now() - start).inMicroseconds / 1e6;
            ledger!.elapsed = (now() - measurementStart).inMicroseconds / 1e6;
          }
        }
        ledger!.healthFinal = await readHealth();
        progress = sequence + 1;
        log('trial', {'sequence': sequence, 'report': ledger!.report});
        _packetInFlight = false;
        changed();
      }
      phase = '结束排空';
      await expect(false, 'BER STOP', 'OK BER ACK');
      final end = now() + const Duration(seconds: 2);
      while (true) {
        await drain();
        if (status['state']! & 2 == 0) {
          break;
        }
        if (now() >= end) throw StateError('末尾发布未完成');
        await pause(const Duration(milliseconds: 50));
      }
      ledger!.rxFinal = await rxStatus();
      ledger!.healthFinal = await readHealth();
      state = 'complete';
      update('测试完成：$progress/${config.count}包，报告已保存');
    } catch (e) {
      failedPhase = phase;
      state = e is BerStopped ? 'stopped' : 'aborted';
      error = '$e';
      update('测试中止：$e');
    } finally {
      if (measurementStart != null) {
        ledger!.elapsed = (now() - measurementStart).inMicroseconds / 1e6;
      }
      _packetInFlight = false;
      await finish();
      _finishPacketOnStop = false;
    }
  }

  Future<void> finish({bool inspectOnly = false}) async {
    try {
      if (!inspectOnly) {
        for (final tx in [true, false]) {
          final cmd = tx ? 'STOP' : 'BER STOP';
          try {
            log('cleanup_stop', {'device': tx ? 'TX' : 'RX', 'command': cmd});
            if (requiresReconnect) {
              await emergencyStop(tx, cmd);
            } else {
              final response = await request(tx, cmd, cancellable: false);
              if (response != (tx ? 'OK' : 'OK BER ACK')) {
                throw StateError(response);
              }
            }
          } catch (e) {
            cleanupFailed = true;
            log('cleanup_error', {'error': '$e'});
          }
          if (tx && !requiresReconnect) {
            try {
              await readTxDiagnostics();
            } catch (e) {
              log('tx_uart_diag_unavailable', {'error': '$e'});
            }
          }
        }
      }
      if (requiresReconnect) await invalidateConnections?.call();
    } finally {
      try {
        _audit?.finish({
          'state': state,
          'error': error,
          'inspection_only': inspectOnly,
          'control_byte_gap_us': berCommandByteGap.inMicroseconds,
          'operation': operation,
          'setup_tx': setupTx,
          'setup_rx_confirmed': setupRxConfirmed,
          'failed_phase': failedPhase,
          'command_failure': commandFailure?.toJson(),
          'cleanup_failed': cleanupFailed,
          'status': status,
          'health': health,
          'tx_uart_diagnostics': txDiagnostics,
          'tx_uart_diagnostics_initial': txDiagnosticsInitial,
          if (ledger != null && !inspectOnly) ...ledger!.toJson(),
        });
      } catch (e) {
        state = 'aborted';
        error = '报告写入失败：$e';
        update(error!);
      }
      _audit = null;
      running = false;
      phase = '结束';
      changed();
    }
  }
}
