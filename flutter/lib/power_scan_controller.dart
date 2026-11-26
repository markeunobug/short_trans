import 'dart:io';
import 'dart:math';
import 'ber_controller.dart';
import 'ber_data.dart';

class PowerScanConfig {
  const PowerScanConfig({
    this.start = 64,
    this.end = 576,
    this.step = 64,
    this.fineStep = 16,
    this.count = 5,
    this.retestCount = 30,
    this.preparationAmplitude = 256,
    this.margin = 64,
    this.receiveWait = const Duration(seconds: 2),
    this.targetDelivery = 0.95,
    this.maxBer = 0.001,
  });
  final int start, end, step, fineStep, count, retestCount;
  final int preparationAmplitude, margin;
  final Duration receiveWait;
  final double targetDelivery, maxBer;
  void validate() {
    if (start < 0 ||
        end > 2047 ||
        start > end ||
        step < 1 ||
        step > 2047 ||
        fineStep < 1 ||
        fineStep > step ||
        margin < 0 ||
        margin > 2047 ||
        preparationAmplitude < 1 ||
        preparationAmplitude < start ||
        preparationAmplitude > end ||
        count < 1 ||
        count > 100000 ||
        retestCount < count ||
        retestCount > 100000 ||
        receiveWait < const Duration(milliseconds: 100) ||
        receiveWait > const Duration(seconds: 60) ||
        !targetDelivery.isFinite ||
        targetDelivery <= 0 ||
        targetDelivery > 1 ||
        !maxBer.isFinite ||
        maxBer < 0 ||
        maxBer > 1) {
      throw const FormatException(
        '幅度0..2047且起点≤终点；准备幅度须大于0且在扫描范围内；'
        '步进≥1且细扫步进≤粗扫步进；复测包数≥每档包数；'
        '接收等待0.1..60秒；目标收包率(0,100]%，BER上限[0,100]%',
      );
    }
    if (coarseAmplitudes.length > 128) {
      throw const FormatException('粗扫最多128档，请增大步进或缩小范围');
    }
  }

  List<int> get coarseAmplitudes {
    if (step <= 0) return [];
    final values = <int>[];
    for (var a = start; a <= end && values.length <= 128; a += step) {
      values.add(a);
    }
    if (values.isNotEmpty && values.last != end) values.add(end);
    return values;
  }

  // Lower bound: serial commands, time-base setup, evidence reads and fine
  // scan are additional. Never present this as an ETA or measured duration.
  double get coarseLowerBoundSeconds =>
      coarseAmplitudes.length *
      count *
      (3.8 + receiveWait.inMilliseconds / 1000);
  Map<String, Object?> toJson() => {
    'start': start,
    'end': end,
    'step': step,
    'fine_step': fineStep,
    'packets_per_point': count,
    'retest_packets': retestCount,
    'preparation_amplitude': preparationAmplitude,
    'margin_codes': margin,
    'receive_wait_ms': receiveWait.inMilliseconds,
    'target_delivery': targetDelivery,
    'max_payload_ber': maxBer,
    'unit': 'DAC amplitude code, not calibrated power',
  };
}

class PowerPointResult {
  PowerPointResult({
    required this.amplitude,
    required this.stage,
    required this.batch,
    required this.state,
    required this.report,
    required this.evidenceComplete,
    required this.clippedWindows,
    required this.chainFault,
    required this.transportFault,
    this.error,
    this.auditPath,
    this.maxEnergy,
  });
  final int amplitude, batch, clippedWindows;
  final String stage, state;
  final String? error, auditPath;
  final Map<String, Object?> report;
  final bool evidenceComplete, chainFault, transportFault;
  final int? maxEnergy;
  double? get delivery => (report['per'] as num?) == null
      ? null
      : 1 - (report['per'] as num).toDouble();
  double? get ber => (report['ber'] as num?)?.toDouble();
  double? get coverage => (report['coverage'] as num?)?.toDouble();
  bool get valid =>
      state == 'complete' &&
      (report['tx_completed'] as int? ?? 0) > 0 &&
      report['tx_unresolved'] == 0 &&
      report['rx_windows_unfinished'] == 0 &&
      evidenceComplete &&
      !chainFault &&
      !transportFault;
  bool passes(PowerScanConfig config) =>
      valid &&
      clippedWindows == 0 &&
      delivery != null &&
      delivery! + 1e-12 >= config.targetDelivery &&
      coverage != null &&
      coverage! + 1e-12 >= config.targetDelivery &&
      ber != null &&
      ber! <= config.maxBer;
  String verdict(PowerScanConfig config) => !valid
      ? '数据无效/未完成'
      : clippedWindows > 0
      ? '存在削顶'
      : passes(config)
      ? '达标'
      : '未达标';
  Map<String, Object?> toJson(PowerScanConfig config) => {
    'amplitude': amplitude,
    'stage': stage,
    'batch': batch,
    'state': state,
    'error': error,
    'ber_audit_path': auditPath,
    'report': report,
    'evidence_complete': evidenceComplete,
    'clipped_windows': clippedWindows,
    'chain_fault': chainFault,
    'transport_fault': transportFault,
    'max_energy': maxEnergy,
    'valid': valid,
    'passed': passes(config),
    'verdict': verdict(config),
  };
  factory PowerPointResult.fromBer(
    BerController c,
    int amplitude,
    String stage,
    int batch,
  ) {
    final l = c.ledger;
    final attempts = l?.attempts.values.toList() ?? <BerAttempt>[];
    final evidence = attempts.map((a) => a.evidence).nonNulls.toList();
    bool changed(Map<String, String> a, Map<String, String> b, String key) =>
        a[key] != null && b[key] != null && a[key] != b[key];
    final transport =
        c.requiresReconnect ||
        c.cleanupFailed ||
        (l?.transportErrors ?? 0) > 0 ||
        (l?.invalidNormal ?? 0) > 0 ||
        (l?.diagnostic['dropped'] ?? 0) > 0 ||
        (l?.diagnostic['protocol_errors'] ?? 0) > 0 ||
        ((l?.healthFinal['error_flags'] ?? 0) & 0xf6) != 0 ||
        l?.rxFinal['overflow'] == '1' ||
        [
          'uart_err',
          'rx_restart',
          'tx_err',
          'overflow',
        ].any((key) => changed(l?.rxInitial ?? {}, l?.rxFinal ?? {}, key)) ||
        [
          'rxerr',
          'rxovf',
          'lineovf',
          'cmderr',
          'ore',
          'fe',
          'ne',
          'pe',
          'rearmfail',
          'txerr',
        ].any((key) => changed(c.txDiagnosticsInitial, c.txDiagnostics, key));
    return PowerPointResult(
      amplitude: amplitude,
      stage: stage,
      batch: batch,
      state: c.state,
      report: l == null ? {} : Map.of(l.report),
      evidenceComplete:
          attempts.isNotEmpty &&
          evidence.length == attempts.length &&
          attempts.every((a) => a.evidenceError == null),
      clippedWindows: evidence.where((e) => e.faultFlags & 16 != 0).length,
      chainFault: evidence.any(
        (e) =>
            e.faultFlags & 12 != 0 ||
            e.summary['chain_unavailable_cycles']! > 0 ||
            e.summary['samples'] == 0 ||
            e.summary['metrics'] == 0,
      ),
      transportFault: transport,
      error: c.error,
      auditPath: c.exportPath,
      maxEnergy: evidence.isEmpty
          ? null
          : evidence.map((e) => e.maxEnergy).reduce(max),
    );
  }
}

class PowerScanController {
  PowerScanController({
    required this.ber,
    required this.changed,
    BerAudit Function()? auditFactory,
    int Function()? nextBatch,
    void Function(String, String)? writeCsv,
  }) : auditFactory =
           auditFactory ??
           (() => BerFileAudit(
             Directory('exports/power_scan'),
             prefix: 'power_scan',
           )),
       nextBatch = nextBatch ?? (() => Random.secure().nextInt(0x100000000)),
       writeCsv =
           writeCsv ??
           ((path, csv) =>
               File('$path/points.csv').writeAsStringSync(csv, flush: true));
  final BerController ber;
  final void Function() changed;
  final BerAudit Function() auditFactory;
  final int Function() nextBatch;
  final void Function(String, String) writeCsv;
  final points = <PowerPointResult>[];
  PowerScanConfig? config;
  BerAudit? _audit;
  final _batches = <int>{};
  bool running = false, stopRequested = false, applying = false;
  String state = 'idle', message = '连接TX和RX后设置扫描范围；准备幅度应为已验证可通信档位';
  String? error, exportPath;
  int? currentAmplitude, _base, _proposed;
  int? appliedAmplitude;
  int? get minimumAmplitude {
    final values = points
        .where(
          (p) => p.stage != 'retest' && config != null && p.passes(config!),
        )
        .map((p) => p.amplitude);
    return values.isEmpty ? null : values.reduce(min);
  }

  int? get recommendedAmplitude =>
      state == 'complete' &&
          _proposed != null &&
          points.any(
            (p) =>
                p.stage == 'retest' &&
                p.amplitude == _proposed &&
                p.passes(config!),
          )
      ? _proposed
      : null;
  bool get lowerBoundaryReached => minimumAmplitude == config?.start;
  void stop() {
    if (!running) return;
    stopRequested = true;
    if (ber.running) ber.stop();
    message = '正在停止：完成当前已接受包的接收窗口后保存部分结果';
    changed();
  }

  void _checkStop() {
    if (stopRequested) throw BerStopped();
  }

  int _batch() {
    var value = nextBatch() & 0xffffffff;
    while (!_batches.add(value)) {
      value = (value + 1) & 0xffffffff;
    }
    return value;
  }

  Future<PowerPointResult> _point(
    int amplitude,
    String stage,
    int count,
  ) async {
    _checkStop();
    final cfg = config!, batch = _batch();
    currentAmplitude = amplitude;
    message =
        '${stage == 'coarse'
            ? '粗扫'
            : stage == 'fine'
            ? '细扫'
            : '复测'}：幅度 $amplitude，$count 包';
    changed();
    _audit!.log('point_start', {
      'amplitude': amplitude,
      'stage': stage,
      'batch': batch,
    });
    await ber.start(
      BerConfig(
        count: count,
        batch: batch,
        amplitude: amplitude,
        receiveWait: cfg.receiveWait,
      ),
      scan: BerScanOptions(
        expectedBase: _base,
        preparationAmplitude: _base == null ? cfg.preparationAmplitude : null,
      ),
    );
    final result = PowerPointResult.fromBer(ber, amplitude, stage, batch);
    points.add(result);
    _audit!.log('power_point', result.toJson(cfg));
    _base ??= ber.confirmedBase;
    changed();
    _checkStop();
    if (ber.state != 'complete' || ber.requiresReconnect || ber.cleanupFailed) {
      throw StateError(ber.error ?? '本档测量或停止确认失败，已保存部分结果');
    }
    if (!result.valid) {
      throw StateError('本档存在控制通信、采样、捕获或证据异常；停止扫描，详情见报告');
    }
    return result;
  }

  Future<void> start(PowerScanConfig cfg) async {
    if (running || applying || ber.running || ber.requiresReconnect) return;
    cfg.validate();
    running = true;
    stopRequested = false;
    state = 'running';
    config = cfg;
    error = null;
    exportPath = null;
    currentAmplitude = null;
    _base = null;
    _proposed = null;
    appliedAmplitude = null;
    points.clear();
    _batches.clear();
    changed();
    try {
      _audit = auditFactory();
      exportPath = _audit!.path;
      _audit!.log('configuration', cfg.toJson());
      for (final amplitude in cfg.coarseAmplitudes) {
        await _point(amplitude, 'coarse', cfg.count);
      }
      // Full coarse scan preserves non-monotonic high-amplitude degradation.
      // Refine only the bracket below the lowest passing measured point.
      final coarseMinimum = minimumAmplitude;
      if (coarseMinimum != null &&
          coarseMinimum > cfg.start &&
          cfg.fineStep < cfg.step) {
        final lower = cfg.coarseAmplitudes.lastWhere((a) => a < coarseMinimum);
        for (
          var a = lower + cfg.fineStep;
          a < coarseMinimum;
          a += cfg.fineStep
        ) {
          await _point(a, 'fine', cfg.count);
        }
      }
      _checkStop();
      final minimum = minimumAmplitude;
      if (minimum == null) {
        state = 'no_candidate';
        message = '扫描完成：没有满足收包率、覆盖率、BER和无削顶条件的档位';
      } else {
        final candidates =
            points
                .where(
                  (p) =>
                      p.stage != 'retest' &&
                      p.amplitude >= minimum + cfg.margin &&
                      p.passes(cfg),
                )
                .map((p) => p.amplitude)
                .toList()
              ..sort();
        if (candidates.isEmpty) {
          state = 'no_margin';
          message = '扫描完成：最低实测达标幅度 $minimum；范围内没有满足工作余量的达标档位';
        } else {
          _proposed = candidates.first;
          final result = await _point(_proposed!, 'retest', cfg.retestCount);
          _checkStop();
          state = result.passes(cfg) ? 'complete' : 'retest_failed';
          message = result.passes(cfg)
              ? '扫描及复测完成：最低实测达标 $minimum，推荐 $_proposed（幅度码）'
              : '候选幅度 $_proposed 复测未达标；本次不输出推荐值';
        }
      }
    } catch (e) {
      state = e is BerStopped ? 'stopped' : 'aborted';
      error = '$e';
      message = e is BerStopped ? '已停止，部分结果已保留；没有最终推荐值' : '扫描中止：$e';
    } finally {
      currentAmplitude = null;
      try {
        if (_audit != null) {
          writeCsv(_audit!.path, csv);
          _audit!.finish(report);
        }
      } catch (e) {
        state = 'aborted';
        error = '扫描报告保存失败：$e';
        message = error!;
        // Close the audit even if the CSV write failed; best effort retains
        // an explicit aborted summary rather than a stale recommendation.
        try {
          _audit?.finish(report);
        } catch (_) {}
      }
      _audit = null;
      running = false;
      changed();
    }
  }

  Future<void> applyRecommended() async {
    final amplitude = recommendedAmplitude;
    if (amplitude == null ||
        running ||
        applying ||
        ber.running ||
        ber.requiresReconnect) {
      return;
    }
    applying = true;
    error = null;
    appliedAmplitude = null;
    changed();
    try {
      // Serialize through the same paced, timeout-poisoning BER transport.
      final before = await ber.txStatus();
      if (before['run'] != '0') throw StateError('TX仍在发送，请先停止');
      await ber.expect(true, 'AMP $amplitude');
      final after = await ber.txStatus();
      if (after['run'] != '0' || after['amp'] != '$amplitude') {
        throw StateError('应用后幅度回读不符：$after');
      }
      appliedAmplitude = amplitude;
      message = '已应用推荐幅度 $amplitude；TX保持停止';
    } catch (e) {
      error = '$e';
      message = '应用失败：$e';
      if (ber.requiresReconnect) await ber.invalidateConnections?.call();
    } finally {
      applying = false;
      changed();
    }
  }

  Map<String, Object?> get report => {
    'schema': 1,
    'operation': 'power_scan',
    'state': state,
    'error': error,
    'configuration': config?.toJson(),
    'minimum_measured_amplitude': minimumAmplitude,
    'recommended_amplitude': recommendedAmplitude,
    'candidate_amplitude': _proposed,
    'lower_boundary_reached': lowerBoundaryReached,
    'scope': '本次固定接收设置与环境；幅度码未经W/dBm标定；小样本达标不等于可靠性验收',
    'points': [for (final p in points) p.toJson(config!)],
  };
  String get csv {
    final rows = <String>[
      'stage,amplitude,batch,state,tx_completed,delivered_unique,delivery_rate,payload_ber,coverage,clipped_windows,valid,passed,max_energy',
    ];
    for (final p in points) {
      rows.add(
        [
          p.stage,
          p.amplitude,
          p.batch,
          p.state,
          p.report['tx_completed'],
          p.report['delivered_unique'],
          p.delivery,
          p.ber,
          p.coverage,
          p.clippedWindows,
          p.valid,
          p.passes(config!),
          p.maxEnergy,
        ].map((v) => v ?? '').join(','),
      );
    }
    return '${rows.join('\r\n')}\r\n';
  }
}
