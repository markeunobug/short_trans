import 'dart:async';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:short_trans_host/ber_data.dart';
import 'package:short_trans_host/power_scan_controller.dart';
import 'ber_test.dart' show MockLink, MemoryAudit, wire;

class PowerLink extends MockLink {
  int amplitude = 256, minimumGood = 128;
  int? clippedAt, degradedAt;
  bool baseReceived = false, wrongAmplitude = false, corruptBase = false;
  bool failCleanup = false, badEvidence = false, failRetest = false;
  int dataSends = 0;
  PowerScanController? scan;
  int? stopAtDataSend;
  bool timeoutData = false, stopBeforeSend = false;
  @override
  Future<String> command(bool tx, String cmd) async {
    if (tx && cmd.startsWith('AMP ') && !wrongAmplitude) {
      amplitude = int.parse(cmd.substring(4));
    }
    if (!tx && cmd == 'BER OBS ARM' && stopBeforeSend) scan!.stop();
    if (tx && cmd == 'SEND') {
      if (pending) {
        baseReceived = amplitude >= minimumGood;
      } else {
        dataSends++;
        if (stopAtDataSend == dataSends) scan!.stop();
        if (timeoutData) {
          commands.add('TX SEND');
          throw TimeoutException('mock data response timeout');
        }
      }
    }
    outcomes = [
      amplitude >= minimumGood &&
              (degradedAt == null || amplitude < degradedAt!) &&
              !(failRetest && scan?.points.length == 3)
          ? 'good'
          : 'lost',
    ];
    if (failCleanup && tx && cmd == 'STOP' && dataSends > 0) {
      commands.add('TX STOP');
      return 'ERR STOP';
    }
    final reply = await super.command(tx, cmd);
    if (tx && cmd == 'STATUS') return '$reply amp=$amplitude';
    if (!tx &&
        cmd == 'STATUS' &&
        (!baseReceived || corruptBase && dataSends > 0)) {
      return reply.replaceFirst('base_s=123', 'base_s=122');
    }
    if (!tx && cmd == 'BER OBS READ' && (badEvidence || clippedAt != null)) {
      final bytes = berTransport(reply, 'OBS READ', 96);
      if (clippedAt != null && amplitude >= clippedAt!) {
        ByteData.sublistView(bytes).setUint32(92, 16, Endian.little);
      }
      if (badEvidence) {
        ByteData.sublistView(bytes).setUint32(16, 0, Endian.little);
      }
      return wire('OBS READ', bytes);
    }
    return reply;
  }
}

(PowerScanController, MemoryAudit, PowerLink) setup({
  PowerLink? link,
  void Function(String, String)? writeCsv,
}) {
  final l = link ?? PowerLink(), audit = MemoryAudit();
  final ber = l.create(MemoryAudit());
  final c = PowerScanController(
    ber: ber,
    changed: () {},
    auditFactory: () => audit,
    nextBatch: () => 42,
    writeCsv: writeCsv ?? (_, _) {},
  );
  l.scan = c;
  return (c, audit, l);
}

const quick = PowerScanConfig(
  start: 64,
  end: 192,
  step: 64,
  fineStep: 32,
  count: 1,
  retestCount: 2,
  preparationAmplitude: 128,
  margin: 64,
  receiveWait: Duration(milliseconds: 100),
);

void main() {
  test(
    'scans low-loss point, refines, reuses base once and independently retests',
    () async {
      final (c, audit, link) = setup();
      await c.start(quick);
      expect(c.state, 'complete', reason: c.error);
      expect(c.points.map((p) => p.amplitude), [64, 128, 192, 96, 192]);
      expect(c.points.first.delivery, 0);
      expect(c.points.first.valid, true);
      expect(c.points.first.ber, isNull);
      expect(c.minimumAmplitude, 128);
      expect(c.recommendedAmplitude, 192);
      expect(c.points.last.report['tx_completed'], 2);
      expect(link.commands.where((s) => s == 'TX TIME_BASE'), hasLength(1));
      expect(c.points.map((p) => p.batch).toSet(), hasLength(5));
      expect(
        link.commands.indexOf('TX AMP 128'),
        lessThan(link.commands.indexOf('TX TIME_BASE')),
      );
      expect(audit.saved!['recommended_amplitude'], 192);
      expect(c.csv.split('\r\n'), hasLength(7));
      await c.applyRecommended();
      expect(c.appliedAmplitude, 192);
      expect(link.commands.last, 'TX STATUS');
      expect(link.dataSends, 6);
    },
  );
  test(
    'request stop during accepted SEND completes its receive and evidence window',
    () async {
      final (c, audit, link) = setup(link: PowerLink()..stopAtDataSend = 1);
      await c.start(
        const PowerScanConfig(
          start: 64,
          end: 192,
          step: 64,
          fineStep: 32,
          count: 3,
          retestCount: 3,
          preparationAmplitude: 128,
          receiveWait: Duration(milliseconds: 100),
        ),
      );
      expect(c.state, 'stopped');
      expect(link.dataSends, 1);
      final attempt = c.ber.ledger!.attempts.values.single;
      expect(attempt.tx, 'complete');
      expect(attempt.windowComplete, true);
      expect(attempt.evidence, isNotNull);
      expect(c.points, hasLength(1));
      expect(c.recommendedAmplitude, isNull);
      expect(audit.saved!['state'], 'stopped');
    },
  );
  test('stop during observer ARM prevents an unsubmitted DATA SEND', () async {
    final (c, _, link) = setup(link: PowerLink()..stopBeforeSend = true);
    await c.start(quick);
    expect(c.state, 'stopped');
    expect(link.dataSends, 0);
    expect(link.observerActive, false);
    expect(c.recommendedAmplitude, isNull);
  });
  test(
    'minimum at starting boundary is labelled and zero margin can be retested',
    () async {
      final (c, _, _) = setup(link: PowerLink()..minimumGood = 64);
      await c.start(
        const PowerScanConfig(
          start: 64,
          end: 64,
          step: 64,
          fineStep: 64,
          count: 1,
          retestCount: 1,
          preparationAmplitude: 64,
          margin: 0,
          receiveWait: Duration(milliseconds: 100),
        ),
      );
      expect(c.state, 'complete');
      expect(c.minimumAmplitude, 64);
      expect(c.lowerBoundaryReached, true);
      expect(c.recommendedAmplitude, 64);
    },
  );
  test(
    'out-of-range preparation, descending range and excessive point count rejected',
    () {
      for (final cfg in [
        const PowerScanConfig(start: 512),
        const PowerScanConfig(start: 500, end: 400),
        const PowerScanConfig(start: 1, end: 2047, step: 1, fineStep: 1),
        const PowerScanConfig(retestCount: 1),
        const PowerScanConfig(targetDelivery: double.nan),
      ]) {
        expect(cfg.validate, throwsFormatException);
      }
    },
  );
  test(
    'zero amplitude can be measured after a nonzero preparation base',
    () async {
      final (c, _, _) = setup(link: PowerLink()..minimumGood = 64);
      await c.start(
        const PowerScanConfig(
          start: 0,
          end: 64,
          step: 64,
          fineStep: 64,
          count: 1,
          retestCount: 1,
          preparationAmplitude: 64,
          margin: 0,
          receiveWait: Duration(milliseconds: 100),
        ),
      );
      expect(c.state, 'complete');
      expect(c.points.first.amplitude, 0);
      expect(c.points.first.delivery, 0);
      expect(c.recommendedAmplitude, 64);
    },
  );
  test('always includes the upper endpoint', () {
    expect(
      const PowerScanConfig(start: 64, end: 200, step: 64).coarseAmplitudes,
      [64, 128, 192, 200],
    );
  });
  test('clipping excludes high-energy points from recommendation', () async {
    final (c, _, _) = setup(link: PowerLink()..clippedAt = 192);
    await c.start(quick);
    expect(c.state, 'no_margin', reason: c.error);
    expect(c.points.firstWhere((p) => p.amplitude == 192).clippedWindows, 1);
    expect(c.minimumAmplitude, 128);
    expect(c.recommendedAmplitude, isNull);
  });
  test(
    'high amplitude degradation is measured and not treated as monotonic',
    () async {
      final (c, _, _) = setup(link: PowerLink()..degradedAt = 192);
      await c.start(quick);
      expect(c.points.map((p) => p.amplitude), contains(192));
      expect(c.state, 'no_margin');
      expect(c.recommendedAmplitude, isNull);
    },
  );
  test(
    'no passing point returns no_candidate, not an invented optimum',
    () async {
      final (lost, _, _) = setup(link: PowerLink()..degradedAt = 64);
      await lost.start(quick);
      expect(lost.state, 'no_candidate');
      expect(lost.minimumAmplitude, isNull);
      expect(lost.recommendedAmplitude, isNull);
    },
  );
  test('retest failure suppresses recommendation', () async {
    final (c, _, _) = setup(link: PowerLink()..failRetest = true);
    // No fine scan so the fourth point is the independent retest.
    await c.start(
      const PowerScanConfig(
        start: 64,
        end: 192,
        step: 64,
        fineStep: 64,
        count: 1,
        retestCount: 2,
        preparationAmplitude: 128,
        margin: 64,
        receiveWait: Duration(milliseconds: 100),
      ),
    );
    expect(c.state, 'retest_failed');
    expect(c.recommendedAmplitude, isNull);
  });
  test(
    'unresolved serial timeout aborts without SEND retry or next amplitude',
    () async {
      final (c, audit, link) = setup(link: PowerLink()..timeoutData = true);
      await c.start(quick);
      expect(c.state, 'aborted');
      expect(c.ber.requiresReconnect, true);
      expect(link.invalidated, true);
      expect(link.dataSends, 1);
      expect(c.points, hasLength(1));
      expect(audit.saved!['recommended_amplitude'], isNull);
    },
  );
  test('preparation amplitude mismatch aborts before TIME_BASE SEND', () async {
    final (c, _, link) = setup(link: PowerLink()..wrongAmplitude = true);
    await c.start(quick);
    expect(c.state, 'aborted');
    expect(link.sends, 0);
  });
  test(
    'missing input samples aborts rather than labelling link weak',
    () async {
      final (c, _, link) = setup(link: PowerLink()..badEvidence = true);
      await c.start(quick);
      expect(c.state, 'aborted');
      expect(link.dataSends, 1);
      expect(c.points.single.valid, false);
    },
  );
  test('cleanup rejection aborts scan and preserves row', () async {
    final (c, _, link) = setup(link: PowerLink()..failCleanup = true);
    await c.start(quick);
    expect(c.state, 'aborted');
    expect(c.ber.cleanupFailed, true);
    expect(c.recommendedAmplitude, isNull);
    expect(link.dataSends, 1);
  });
  test('changed time base aborts before next point DATA', () async {
    final (c, _, link) = setup(link: PowerLink()..corruptBase = true);
    await c.start(quick);
    expect(c.state, 'aborted');
    expect(c.points, hasLength(2));
    expect(link.dataSends, 1);
  });
  test(
    'failed CSV persistence invalidates recommendation and saves aborted summary',
    () async {
      final (c, audit, _) = setup(
        writeCsv: (_, _) => throw StateError('disk full'),
      );
      await c.start(quick);
      expect(c.state, 'aborted');
      expect(c.recommendedAmplitude, isNull);
      expect(audit.saved!['state'], 'aborted');
    },
  );
}
