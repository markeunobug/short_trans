import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:short_trans_host/ber_data.dart';
import 'package:short_trans_host/ber_controller.dart';
import 'package:short_trans_host/trace_data.dart';
import 'ber_evidence_test.dart' show evidenceFixture;

String wire(String type, Uint8List data) =>
    'OK BER $type ${berHex(data)} crc=${berCrc16(data).toRadixString(16).padLeft(4, '0').toUpperCase()}';

Uint8List captureBytes(Uint8List payload, int id, {String outcome = 'good'}) {
  final b = Uint8List(64), d = ByteData(64);
  b.setAll(0, ascii.encode('BR01'));
  d.setUint32(4, id, Endian.little);
  d.setUint16(8, 328, Endian.little);
  b.setRange(4, 10, d.buffer.asUint8List().sublist(4, 10));
  b[10] = 0x71;
  b[11] = 41;
  b[16] = 0x20;
  b[17] = ByteData.sublistView(payload).getUint32(4, Endian.big) & 255;
  b[18] = 32;
  b[19] = berCrc8(b.sublist(16, 19));
  b.setAll(23, payload);
  final crc = berCrc16(b.sublist(16, 55));
  b[55] = crc >> 8;
  b[56] = crc & 255;
  if (outcome == 'bad') {
    b[38] ^= 0x15;
    b[10] = 0x51;
  }
  if (outcome == 'identity') {
    b[24] ^= 1;
    b[10] = 0x51;
  }
  return b;
}

class MemoryAudit implements BerAudit {
  @override
  String get path => 'mock-log';
  final events = <(String, Map<String, Object?>)>[];
  Map<String, Object?>? saved;
  bool failRaw = false;
  @override
  void log(String kind, Map<String, Object?> fields) {
    if (failRaw && kind == 'diagnostic_raw') {
      throw const FileSystemException('mock disk full');
    }
    events.add((kind, fields));
  }

  @override
  void finish(Map<String, Object?> report) {
    saved = report;
  }
}

class MockLink {
  Duration time = Duration.zero;
  Duration until = Duration.zero;
  List<String> outcomes = ['good', 'bad', 'identity', 'lost'];
  List<String> commands = [];
  List<Uint8List> queue = [];
  Uint8List payload = Uint8List(0), latest = Uint8List(0);
  bool pending = false, enabled = false, corruptOnce = false, popError = false;
  int started = 0, popped = 0, sends = 0, cleared = 0;
  bool invalidated = false;
  String rxMode = 'FSK';
  int configPendingReads = 0, pendingAfterMod = 0, modeCommits = 0;
  bool configStuck = false, configError = false, stopDuringConfig = false;
  int txStatusReads = 0, txStatusDuringSetup = 0;
  int uartErrors = 0,
      uartRingOverflows = 0,
      uartLineOverflows = 0,
      uartCommandErrors = 0;
  String lastBadHex = '';
  String? fault;
  int observerId = 0;
  bool observerActive = false;
  BerController? controller;
  Future<void> sleep(Duration value) async {
    time += value;
  }

  Uint8List status() {
    final b = Uint8List(32), d = ByteData(32);
    b.setAll(0, ascii.encode('BS01'));
    b[4] = 16 | (enabled ? 1 : 0) | (queue.isNotEmpty ? 4 : 0);
    b[5] = queue.length;
    b[6] = 8;
    b[7] = 64;
    d.setUint32(8, started, Endian.little);
    d.setUint32(16, started, Endian.little);
    d.setUint32(24, popped, Endian.little);
    b.setRange(8, 32, d.buffer.asUint8List().sublist(8));
    return b;
  }

  Future<String> command(bool tx, String cmd) async {
    commands.add('${tx ? 'TX' : 'RX'} $cmd');
    time += const Duration(milliseconds: 5);
    if (tx) {
      if (cmd == 'STATUS') {
        txStatusReads++;
        if (sends == 1) txStatusDuringSetup++;
        if (fault == 'command_error' && sends > 1 && time < until) {
          uartCommandErrors++;
          lastBadHex = berHex(ascii.encode('TATUS'));
          return 'ERR COMMAND';
        }
        if ((fault == 'setup_status_timeout' &&
                sends == 1 &&
                txStatusDuringSetup == 3) ||
            (fault == 'selfcheck_timeout' && txStatusReads == 3)) {
          time += const Duration(seconds: 2);
          throw TimeoutException(
            'Future not completed',
            const Duration(seconds: 2),
          );
        }
        final run = fault == 'never'
            ? false
            : fault == 'stuck' && sends > 1
            ? true
            : time < until;
        return 'OK run=${run ? 1 : 0} mode=${run ? 5 : 0} mod=FSK fs=48000 err=0 dmaerr=${fault == 'dma' && sends > 1 ? 1 : 0} hde=0 hae=0 time_base_pending=${pending ? 1 : 0} time_valid=1 base_s=123 len=${payload.length}';
      }
      if (cmd.startsWith('SET_TIME') || cmd == 'TIME_BASE') pending = true;
      if (cmd.startsWith('PAYLOAD ')) payload = berUnhex(cmd.substring(8));
      if (cmd == 'SEND') {
        sends++;
        if (fault == 'timeout' && sends > 1) {
          throw TimeoutException('SEND ACK missing');
        }
        final isBase = pending;
        pending = false;
        until =
            time +
            Duration(milliseconds: (32 + (isBase ? 10 : 41) * 8) * 10 + 200);
        if (!isBase) {
          final seq = ByteData.sublistView(payload).getUint32(4, Endian.big);
          final outcome = outcomes[seq % outcomes.length];
          if (outcome == 'good') {
            latest = payload;
          }
          if (outcome != 'lost' && enabled) {
            queue.add(captureBytes(payload, ++started, outcome: outcome));
          }
          if (fault == 'stop') controller!.stop();
        }
      }
      if (cmd == 'UART DIAG') {
        return 'OK UART DIAG rxerr=$uartErrors rxovf=$uartRingOverflows lineovf=$uartLineOverflows cmderr=$uartCommandErrors badlen=${lastBadHex.length ~/ 2} badhex=$lastBadHex rendermax=1200 uartbudget=13021 renderlate=0 renders=4 dwt=1';
      }
      return cmd == 'MOD FSK' ? 'OK MOD FSK' : 'OK';
    }
    if (cmd == 'PING') return 'OK PONG';
    if (cmd == 'ASK STATUS') {
      final pendingConfig = configStuck || configPendingReads > 0;
      if (configPendingReads > 0) configPendingReads--;
      if (modeCommits > 0 && !pendingConfig) rxMode = 'FSK';
      if (stopDuringConfig) controller!.stop();
      return 'OK ASK STATUS mode=$rxMode low=400 high=600 energy=0 pending=${pendingConfig ? 1 : 0} error=${configError ? 1 : 0} generation=0 bit=0 locked=0 ready=0';
    }
    if (cmd == 'MOD FSK') {
      modeCommits++;
      configPendingReads = pendingAfterMod;
      return 'OK MOD FSK pending=1';
    }
    if (cmd == 'FSK STATUS') {
      return 'OK FSK STATUS mode=1 pending=1 error=0 busy=1 sweep=0';
    }
    if (cmd == 'STATUS') {
      return 'OK fpga=1 type=1 time_valid=1 base_s=${fault == 'stale_base' ? 122 : 123} uart_err=0 rx_restart=0 tx_err=0 overflow=0';
    }
    if (cmd == 'READ') {
      return 'OK DATA ${berHex(latest)} time_valid=1 timestamp_ms=123000';
    }
    if (cmd == 'BER OBS INFO') {
      return wire('OBS INFO', Uint8List.fromList(ascii.encode('BO01')));
    }
    if (cmd == 'BER OBS ARM') {
      if (observerActive) return 'ERR BER OBS BUSY';
      observerActive = true;
      observerId++;
      final b = Uint8List(4);
      ByteData.sublistView(b).setUint32(0, observerId, Endian.little);
      return wire('OBS ARM', b);
    }
    if (cmd == 'BER OBS STOP') {
      observerActive = false;
      return 'OK BER ACK';
    }
    if (cmd == 'BER OBS READ' || cmd.startsWith('BER OBS PAGE ')) {
      final seq = ByteData.sublistView(payload).getUint32(4, Endian.big);
      final outcome = outcomes[seq % outcomes.length];
      final f = evidenceFixture(
        observerId,
        counters: {
          'samples': 4800,
          'metrics': 100,
          'bits': 328,
          if (outcome != 'lost') ...{
            'carrier_rises': 1,
            'preambles': 1,
            'lock_rises': 1,
            'syncs': 1,
          },
          if (outcome == 'good') 'good_frames': 1,
          if (outcome == 'bad' || outcome == 'identity') 'crc_errors': 1,
        },
      );
      return cmd == 'BER OBS READ'
          ? wire('OBS READ', f.$1)
          : wire('OBS PAGE', f.$2.single);
    }
    if (cmd == 'BER START') enabled = true;
    if (cmd == 'BER STOP') enabled = false;
    if (cmd == 'BER CLEAR') {
      cleared++;
      queue.clear();
    }
    if (cmd == 'BER STATUS') return wire('STATUS', status());
    if (cmd == 'BER HEALTH') {
      final b = Uint8List(20)..setAll(0, ascii.encode('BH01'));
      b[4] = 0xa7;
      b[5] = 0x14;
      return wire('HEALTH', b);
    }
    if (cmd == 'BER READ') {
      if (queue.isEmpty) return 'OK BER EMPTY';
      final reply = wire('RECORD', queue.first);
      if (corruptOnce) {
        corruptOnce = false;
        return '${reply.substring(0, reply.length - 4)}FFFF';
      }
      return reply;
    }
    if (cmd.startsWith('BER POP ')) {
      if (queue.isEmpty ||
          ByteData.sublistView(queue.first).getUint32(4, Endian.little) !=
              int.parse(cmd.substring(8))) {
        return 'ERR BER ID';
      }
      popped++;
      queue.removeAt(0);
      return popError ? 'ERR BER SPI' : 'OK BER ACK';
    }
    return cmd == 'MOD FSK' ? 'OK MOD FSK pending=0' : 'OK BER ACK';
  }

  BerController create(MemoryAudit audit) {
    return controller = BerController(
      command: command,
      emergencyStop: (tx, cmd) async {
        commands.add('cleanup $tx $cmd');
      },
      changed: () {},
      auditFactory: () => audit,
      now: () => time,
      sleep: sleep,
      invalidateConnections: () async {
        invalidated = true;
      },
    );
  }
}

void main() {
  final vectors =
      (jsonDecode(File('test/fixtures/ber_vectors.json').readAsStringSync())
              as Map)['vectors']
          as List;
  const config = BerConfig(
    count: 4,
    batch: 12345,
    amplitude: 256,
    receiveWait: Duration(milliseconds: 200),
  );
  test('old peripheral blocks new evidence trial before any SEND', () async {
    final link = MockLink(), audit = MemoryAudit();
    final c = BerController(
      command: (tx, cmd) => !tx && cmd == 'BER OBS INFO'
          ? Future.value('ERR BER UNSUPPORTED')
          : link.command(tx, cmd),
      emergencyStop: (tx, cmd) async {},
      changed: () {},
      auditFactory: () => audit,
      now: () => link.time,
      sleep: link.sleep,
    );
    await c.start(config);
    expect(c.state, 'aborted');
    expect(c.error, contains('配套新版'));
    expect(link.sends, 0);
    expect(c.requiresReconnect, false);
  });
  test(
    'bad frozen evidence aborts before another ARM or SEND, preserving raw summary',
    () async {
      final link = MockLink(), audit = MemoryAudit();
      final c = BerController(
        command: (tx, cmd) => !tx && cmd.startsWith('BER OBS PAGE ')
            ? Future.value('ERR BER SPI')
            : link.command(tx, cmd),
        emergencyStop: (tx, cmd) async {},
        changed: () {},
        auditFactory: () => audit,
        now: () => link.time,
        sleep: link.sleep,
      );
      await c.start(config);
      expect(c.state, 'aborted');
      expect(link.sends, 2);
      expect(link.observerId, 1);
      expect(link.observerActive, false);
      expect(
        audit.events.where((e) => e.$1 == 'stage_summary_raw'),
        isNotEmpty,
      );
      expect(c.ledger!.attempts[0]!.evidenceError, isNotNull);
      expect((audit.saved!['failure_evidence'] as List).length, 1);
    },
  );
  test('Dart patterns and records match independent Python/zlib vectors', () {
    expect(berCrc16(ascii.encode('123456789')), 0x29b1);
    expect(berCrc8(ascii.encode('123456789')), 0xf4);
    expect(berCrc32(ascii.encode('123456789')), 0xcbf43926);
    for (final v in vectors) {
      final p = berPayload(v['batch'] as int, v['sequence'] as int);
      expect(berHex(p), v['payload']);
      final good = BerCapture.parse(berUnhex(v['good'] as String));
      expect(good.identity, (v['batch'], v['sequence']));
      expect(good.errors(p), 0);
      expect(BerCapture.parse(berUnhex(v['bad'] as String)).errors(p), 3);
      expect(
        BerCapture.parse(berUnhex(v['identity_bad'] as String)).identity,
        isNull,
      );
    }
  });
  test('strict record/CRC/padding validation and fragmented serial lines', () {
    final good = berUnhex(vectors.first['good'] as String);
    final line = wire('RECORD', good);
    expect(berTransport(line, 'RECORD', 64), good);
    expect(
      () =>
          berTransport('${line.substring(0, line.length - 1)}Z', 'RECORD', 64),
      throwsFormatException,
    );
    for (final at in [0, 8, 10, 11, 57]) {
      final bad = Uint8List.fromList(good);
      bad[at] ^= 128;
      expect(() => BerCapture.parse(bad), throwsFormatException);
    }
    final lines = <String>[];
    final decoder = TraceSerialDecoder(onLine: lines.add, onBlock: (_) {});
    for (final byte in ascii.encode('$line\r\n')) {
      decoder.add([byte]);
    }
    expect(lines, [line]);
  });
  test(
    'dual-port good/bad/identity/lost trial, exact stats and no SEND retry',
    () async {
      final link = MockLink()
        ..corruptOnce = true
        ..popError = true;
      final audit = MemoryAudit();
      final c = link.create(audit);
      await c.start(config);
      expect(c.error, isNull);
      expect(c.state, 'complete');
      expect(
        c.ledger!.attempts.values.every((a) => a.evidence != null),
        isTrue,
      );
      expect(c.ledger!.attempts[3]!.stageDiagnosis!['code'], 'below_threshold');
      expect(
        c.ledger!.attempts[1]!.stageDiagnosis!['code'],
        'frame_bit_errors',
      );
      expect((audit.saved!['failure_evidence'] as List).length, 3);
      expect(
        link.commands.indexOf('RX BER OBS ARM'),
        lessThan(link.commands.lastIndexOf('TX SEND')),
      );
      expect(link.sends, 5);
      final r = c.ledger!.report;
      expect(r['per'], .75);
      expect(r['coverage'], .5);
      expect(r['ber'], 3 / 512);
      expect(r['transport_errors'], 1);
      expect(r['unaligned_records'], 1);
      expect(link.popped, 3);
      expect(
        audit.events.indexWhere((e) => e.$1 == 'diagnostic_raw'),
        lessThan(audit.events.indexWhere((e) => e.$1 == 'diagnostic_pop')),
      );
      expect(audit.saved!['state'], 'complete');
      expect(c.running, isFalse);
    },
  );
  test(
    'SEND timeout closes session, marks unresolved and requires both reconnects',
    () async {
      final link = MockLink()..fault = 'timeout';
      final audit = MemoryAudit();
      final c = link.create(audit);
      await c.start(config);
      expect(c.state, 'aborted');
      expect(c.requiresReconnect, isTrue);
      expect(link.invalidated, isTrue);
      expect(c.ledger!.report['tx_unresolved'], 1);
      expect(c.ledger!.report['per'], isNull);
      expect(link.sends, 2);
      final errorAt = audit.events.indexWhere((e) => e.$1 == 'command_error');
      expect(
        audit.events
            .skip(errorAt + 1)
            .where((e) => e.$1 == 'command' && e.$2['command'] == 'UART DIAG'),
        isEmpty,
      );
      c.connectionOpened(true);
      expect(c.requiresReconnect, isTrue);
      c.connectionOpened(false);
      expect(c.requiresReconnect, isFalse);
    },
  );
  test(
    'malformed TX STATUS records UART counters and last rejected line',
    () async {
      final link = MockLink()..fault = 'command_error';
      final audit = MemoryAudit();
      final c = link.create(audit);
      await c.start(config);
      expect(c.state, 'aborted');
      expect(c.error, contains('STATUS: ERR COMMAND'));
      expect(c.requiresReconnect, isFalse);
      expect(c.setupTx, 'complete');
      expect(link.sends, 2); // TIME_BASE setup plus one DATA; neither retried.
      expect(link.commands, contains('TX UART DIAG'));
      expect(c.txDiagnostics['cmderr'], '1');
      expect(c.txDiagnostics['badhex'], berHex(ascii.encode('TATUS')));
      expect(audit.saved!['tx_uart_diagnostics'], c.txDiagnostics);
      expect(c.ledger!.attempts[0]!.tx, 'unresolved');
      expect(c.ledger!.report['tx_completed'], 0);
      expect(c.ledger!.report['tx_unresolved'], 1);
      expect(c.txDiagnostics['rendermax'], '1200');
      expect(c.txDiagnostics['uartbudget'], '13021');
    },
  );
  test(
    'old TX firmware can reject UART DIAG without hiding the original test error',
    () async {
      final link = MockLink()..fault = 'command_error';
      final audit = MemoryAudit();
      final c = BerController(
        command: (tx, cmd) => tx && cmd == 'UART DIAG'
            ? Future.value('ERR COMMAND')
            : link.command(tx, cmd),
        emergencyStop: (tx, cmd) async {},
        changed: () {},
        auditFactory: () => audit,
        now: () => link.time,
        sleep: link.sleep,
      );
      await c.start(config);
      expect(c.error, contains('STATUS: ERR COMMAND'));
      expect(c.txDiagnostics, isEmpty);
      expect(
        audit.events.where((e) => e.$1 == 'tx_uart_diag_unavailable'),
        isNotEmpty,
      );
      expect(link.sends, 2);
    },
  );
  test('already active FSK skips redundant deferred MOD transaction', () async {
    final link = MockLink();
    final c = link.create(MemoryAudit());
    await c.start(config);
    expect(c.state, 'complete');
    expect(link.modeCommits, 0);
  });
  test(
    'live TIME_BASE third STATUS timeout names command and saves unresolved setup',
    () async {
      final link = MockLink()..fault = 'setup_status_timeout';
      final audit = MemoryAudit();
      final c = link.create(audit);
      await c.start(config);
      expect(c.state, 'aborted');
      expect(c.error, contains('TX「STATUS」响应超时'));
      expect(c.error, contains('时间基准'));
      expect(c.setupTx, 'unresolved');
      expect(c.setupRxConfirmed, isFalse);
      expect(c.failedPhase, '时间基准');
      expect(c.ledger!.attempts, isEmpty);
      expect(c.ledger!.report['per'], isNull);
      expect(link.sends, 1); // Only setup SEND, never retried and no DATA.
      expect(link.txStatusDuringSetup, 3);
      expect(c.requiresReconnect, isTrue);
      expect(link.invalidated, isTrue);
      expect(audit.saved!['setup_tx'], 'unresolved');
      final failure = audit.saved!['command_failure'] as Map<String, Object?>;
      expect(failure['device'], 'TX');
      expect(failure['command'], 'STATUS');
      expect(failure['phase'], '时间基准');
      expect(audit.events.where((e) => e.$1 == 'command_error'), hasLength(1));
    },
  );
  test(
    'dual serial selfcheck only reads, never emits STOP/SEND/MOD/CLEAR/POP',
    () async {
      final link = MockLink();
      final audit = MemoryAudit();
      final c = link.create(audit);
      await c.checkConnections();
      expect(c.state, 'checked');
      expect(c.connectionCheck, '5轮STATUS通过');
      expect(link.commands.where((s) => s == 'TX STATUS'), hasLength(5));
      expect(link.commands.where((s) => s == 'RX STATUS'), hasLength(5));
      expect(
        link.commands,
        everyElement(
          isIn(['TX STATUS', 'RX STATUS', 'RX BER HEALTH', 'TX UART DIAG']),
        ),
      );
      expect(link.sends, 0);
      expect(link.cleared, 0);
      expect(link.popped, 0);
      expect(audit.saved!['operation'], 'connection_check');
      expect(c.ledger, isNull);
    },
  );
  test(
    'selfcheck clears stale TIME_BASE completion from a previous trial',
    () async {
      final link = MockLink();
      final audit = MemoryAudit();
      final c = link.create(audit);
      c.setupTx = 'complete';
      c.setupRxConfirmed = true;
      c.target = 1;
      c.ledger = BerLedger(123);
      await c.checkConnections();
      expect(c.setupTx, 'not_started');
      expect(c.setupRxConfirmed, isFalse);
      expect(c.target, 0);
      expect(c.ledger, isNull);
      expect(audit.saved!['setup_tx'], 'not_started');
      expect(audit.saved!['setup_rx_confirmed'], isFalse);
    },
  );
  test(
    'selfcheck timeout aborts without retransmitting reads or transmitting frames',
    () async {
      final link = MockLink()..fault = 'selfcheck_timeout';
      final audit = MemoryAudit();
      final c = link.create(audit);
      await c.checkConnections();
      expect(c.state, 'aborted');
      expect(c.error, contains('TX「STATUS」响应超时'));
      expect(c.failedPhase, '串口自检 3/5');
      expect(link.commands.where((s) => s == 'TX STATUS'), hasLength(3));
      expect(link.commands.where((s) => s == 'RX STATUS'), hasLength(2));
      expect(link.commands, everyElement(isIn(['TX STATUS', 'RX STATUS'])));
      expect(c.requiresReconnect, isTrue);
      expect(link.invalidated, isTrue);
      expect(audit.saved!['operation'], 'connection_check');
    },
  );
  test('captured live pending=1 status is polled until settled', () async {
    final link = MockLink()..configPendingReads = 3;
    final audit = MemoryAudit();
    final c = link.create(audit);
    await c.start(config);
    expect(c.state, 'complete');
    expect(link.modeCommits, 0);
    final statuses = link.commands.where((s) => s == 'RX ASK STATUS');
    expect(statuses.length, 4);
    expect(
      audit.events.where(
        (e) => e.$1 == 'reply' && '${e.$2['line']}'.contains('pending=1'),
      ),
      isNotEmpty,
    );
  });
  test(
    'stale RX TIME_BASE reports expected and actual values without sending DATA',
    () async {
      final link = MockLink()..fault = 'stale_base';
      final audit = MemoryAudit();
      final c = link.create(audit);
      await c.start(config);
      expect(c.state, 'aborted');
      expect(c.setupTx, 'complete');
      expect(c.setupRxConfirmed, isFalse);
      expect(c.error, contains('期望base_s=123'));
      expect(c.error, contains('实收base_s=122'));
      expect(link.sends, 1);
      expect(c.ledger!.attempts, isEmpty);
      expect(c.ledger!.report['per'], isNull);
      expect(c.ledger!.rxFinal['base_s'], '122');
      expect(
        audit.events.where((e) => e.$1 == 'time_base_unconfirmed'),
        hasLength(1),
      );
    },
  );
  test(
    'OOK to FSK submits once and waits for asynchronous mode apply',
    () async {
      final link = MockLink()
        ..rxMode = 'OOK'
        ..pendingAfterMod = 3;
      final c = link.create(MemoryAudit());
      await c.start(config);
      expect(c.state, 'complete');
      expect(link.modeCommits, 1);
      expect(link.rxMode, 'FSK');
      expect(link.sends, 5);
    },
  );
  test(
    'stuck pending times out before CLEAR or SEND with busy context',
    () async {
      final link = MockLink()..configStuck = true;
      final c = link.create(MemoryAudit());
      await c.start(config);
      expect(c.state, 'aborted');
      expect(c.error, contains('5秒'));
      expect(c.error, contains('pending=1'));
      expect(c.error, contains('busy=1'));
      expect(link.sends, 0);
      expect(link.cleared, 0);
      expect(link.modeCommits, 0);
      expect(c.ledger!.attempts, isEmpty);
      expect(c.requiresReconnect, isFalse);
    },
  );
  test(
    'rejected config fails immediately, never mistaken for pending',
    () async {
      final link = MockLink()..configError = true;
      final c = link.create(MemoryAudit());
      await c.start(config);
      expect(c.state, 'aborted');
      expect(c.error, contains('error=1'));
      expect(link.sends, 0);
      expect(link.modeCommits, 0);
      expect(link.time, lessThan(const Duration(seconds: 1)));
    },
  );
  test(
    'stop during configuration wait is cancellable without test SEND',
    () async {
      final link = MockLink()
        ..configPendingReads = 3
        ..stopDuringConfig = true;
      final c = link.create(MemoryAudit());
      await c.start(config);
      expect(c.state, 'stopped');
      expect(link.sends, 0);
      expect(c.requiresReconnect, isFalse);
    },
  );
  test(
    'DMA failure / early-stop / never completes never causes a resend',
    () async {
      for (final fault in ['dma', 'never', 'stuck', 'stop']) {
        final link = MockLink()..fault = fault;
        final c = link.create(MemoryAudit());
        await c.start(config);
        expect(c.state, isNot('complete'));
        expect(link.sends, lessThanOrEqualTo(2));
        if (fault != 'never') {
          expect(c.ledger!.report['tx_unresolved'], 1);
        }
      }
    },
  );
  test('disk-full before POP preserves diagnostic record', () async {
    final link = MockLink();
    final audit = MemoryAudit()..failRaw = true;
    final c = link.create(audit);
    await c.start(config);
    expect(c.state, 'aborted');
    expect(link.popped, 0);
    expect(link.queue, isNotEmpty);
    expect(c.ledger!.report['rx_windows_unfinished'], 1);
    expect(c.ledger!.report['per'], isNull);
  });
  test('inspection never clears/starts/pops; latest record remains', () async {
    final link = MockLink()..queue.add(captureBytes(berPayload(1, 0), 1));
    final c = link.create(MemoryAudit());
    await c.inspect();
    expect(c.state, 'inspected');
    expect(link.cleared, 0);
    expect(link.popped, 0);
    expect(link.sends, 0);
    expect(c.lastCapture!.id, 1);
  });
  test(
    'zero denominators, duplicate cached READ and captures are not new deliveries',
    () {
      final ledger = BerLedger(1);
      expect(ledger.report['per'], isNull);
      expect(ledger.report['ber'], isNull);
      final a = BerAttempt(0, berPayload(1, 0))..tx = 'complete';
      ledger.attempts[0] = a;
      expect(ledger.report['per'], isNull);
      a.windowComplete = true;
      ledger.delivery(a.payload);
      ledger.delivery(a.payload);
      final capture = BerCapture.parse(captureBytes(a.payload, 1));
      ledger.capture(capture);
      ledger.capture(capture);
      expect(ledger.report['delivered_unique'], 1);
      expect(ledger.duplicateReads, 1);
      expect(ledger.duplicateCaptures, 1);
      expect(ledger.report['per'], 0);
    },
  );
  test(
    'real file audit flushes bytes and writes aborted report without serial hardware',
    () {
      final root = Directory(
        '../_codex/ber_20261102/flutter_ui_20261103/mock_audit',
      );
      final audit = BerFileAudit(root);
      audit.log('diagnostic_raw', {'record_hex': 'test only, not board data'});
      audit.finish({
        'state': 'aborted',
        'report': {'per': null},
      });
      expect(File('${audit.path}/raw.jsonl').readAsLinesSync(), hasLength(2));
      expect(
        jsonDecode(
          File('${audit.path}/report.json').readAsStringSync(),
        )['state'],
        'aborted',
      );
    },
  );
}
