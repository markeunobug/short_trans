import 'dart:io';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'ber_controller.dart';
import 'ber_data.dart';

class BerView extends StatefulWidget {
  const BerView({
    super.key,
    required this.controller,
    required this.connected,
    required this.canStart,
    required this.rxConnected,
    required this.connections,
  });
  final BerController controller;
  // Connection guidance must not depend on commands waiting for a reply.
  final bool connected;
  final bool canStart, rxConnected;
  final Widget connections;
  @override
  State<BerView> createState() => _BerViewState();
}

class _BerViewState extends State<BerView> {
  final _count = TextEditingController(text: '3');
  final _batch = TextEditingController(
    text: Random.secure().nextInt(0x100000000).toString(),
  );
  final _amplitude = TextEditingController(text: '256');
  final _wait = TextEditingController(text: '2');
  String? _error;
  bool _showAllEvidence = false;
  BerController get c => widget.controller;
  @override
  void dispose() {
    for (final v in [_count, _batch, _amplitude, _wait]) {
      v.dispose();
    }
    super.dispose();
  }

  Widget evidencePanel() {
    final attempts = c.ledger?.attempts.values.toList() ?? <BerAttempt>[];
    final failed = attempts
        .where(
          (a) =>
              a.stageDiagnosis != null &&
                  a.stageDiagnosis!['code'] != 'delivered' ||
              a.evidenceError != null,
        )
        .toList();
    final visible = _showAllEvidence ? attempts : failed;
    final saved = attempts.where((a) => a.evidence != null).length;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '逐包故障定位 / 自动证据',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            Text('已保存 $saved 个窗口；失败/未完成 ${failed.length} 个'),
            const Text('按发送窗口关联，不凭噪声事件推定包身份；分类给出失败阶段范围，不等于物理根因。正常帧尾失锁不自动判为失败。'),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('同时显示成功窗口'),
              value: _showAllEvidence,
              onChanged: (v) => setState(() => _showAllEvidence = v),
            ),
            if (attempts.isEmpty)
              const Text('新版RX FPGA + RX MCU配套运行后，每次SEND前自动开启观察；无需手动抓取。'),
            for (final a in visible)
              ExpansionTile(
                tilePadding: EdgeInsets.zero,
                title: Text(
                  '第${a.sequence + 1}包 / seq=${a.sequence}：${a.stageDiagnosis?['label'] ?? '窗口证据未完成'}',
                ),
                subtitle: Text(
                  a.evidenceError ??
                      '观察窗口 ${a.evidence?.windowId ?? '—'}；${a.windowComplete ? '接收等待已结束' : '接收窗口未结束'}',
                ),
                childrenPadding: const EdgeInsets.only(bottom: 12),
                children: [
                  if (a.evidence != null) ...[
                    SelectableText(
                      a.evidence!.summary.entries
                          .map((e) => '${e.key}=${e.value}')
                          .join('  '),
                    ),
                    Text(
                      '最大能量=${a.evidence!.maxEnergy}；标志=0x${a.evidence!.faultFlags.toRadixString(16)}',
                    ),
                    if (a.evidence!.truncated)
                      const Text(
                        '事件环已覆盖：只保留最近32个事件，阶段计数仍保留整个窗口。',
                        style: TextStyle(color: Colors.orange),
                      ),
                    for (final e in a.evidence!.events)
                      Align(
                        alignment: Alignment.centerLeft,
                        child: SelectableText(
                          '${(e['time_ms'] as num).toStringAsFixed(3)} ms  ${(e['events'] as List).join(' / ')}'
                          '  E=${e['energy']} T=${e['threshold']} C=${e['confidence']}'
                          ' phase=${e['phase']} adjust=${e['timing_adjust']} parser=${e['parser_state']} symbol=${e['symbol_state']} payload_bytes=${e['payload_bytes']} state=0x${(e['state_flags'] as int).toRadixString(16)}',
                        ),
                      ),
                  ],
                ],
              ),
          ],
        ),
      ),
    );
  }

  void start() {
    try {
      int number(String text) {
        final t = text.trim();
        final n = t.startsWith('0x')
            ? int.tryParse(t.substring(2), radix: 16)
            : int.tryParse(t);
        if (n == null) {
          throw const FormatException('包数/批次/幅度须为整数');
        }
        return n;
      }

      final wait = double.tryParse(_wait.text.trim());
      if (wait == null || !wait.isFinite || wait < 0 || wait > 60) {
        throw const FormatException('接收等待范围0..60秒');
      }
      final config = BerConfig(
        count: number(_count.text),
        batch: number(_batch.text),
        amplitude: number(_amplitude.text),
        receiveWait: Duration(milliseconds: (wait * 1000).round()),
      );
      config.validate();
      setState(() => _error = null);
      c.start(config);
    } catch (e) {
      setState(() => _error = '$e');
    }
  }

  Future<void> openDirectory() async {
    try {
      if (c.exportPath != null) {
        await Process.start('explorer.exe', [c.exportPath!]);
      }
    } catch (e) {
      if (mounted) setState(() => _error = '打开目录失败：$e');
    }
  }

  Widget field(String label, TextEditingController controller, String hint) =>
      SizedBox(
        width: 210,
        child: TextField(
          controller: controller,
          enabled: !c.running,
          decoration: InputDecoration(
            labelText: label,
            helperText: hint,
            border: const OutlineInputBorder(),
          ),
        ),
      );
  Widget card(String label, String value, {Color? color}) => SizedBox(
    width: 200,
    child: Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label),
            const SizedBox(height: 8),
            Text(
              value,
              style: Theme.of(
                context,
              ).textTheme.headlineSmall?.copyWith(color: color),
            ),
          ],
        ),
      ),
    ),
  );
  String ratio(Object? value, {bool percent = false}) => value is num
      ? percent
            ? '${(value * 100).toStringAsFixed(2)}%'
            : value.toStringAsExponential(3)
      : '—';

  @override
  Widget build(BuildContext context) {
    final report = c.ledger?.report ?? <String, Object?>{};
    final total = report['tx_completed'] ?? 0;
    final rows =
        c.ledger?.attempts.values.toList().reversed.take(100).toList() ??
        <BerAttempt>[];
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text('FSK 误码率调试', style: Theme.of(context).textTheme.headlineSmall),
        const SizedBox(height: 8),
        const Text(
          '正常 DATA 帧 · 固定 32 字节 Payload · 双串口 stop-and-wait。开始会建立 TIME_BASE，并清空上一批 RX BER 记录。',
        ),
        const SizedBox(height: 12),
        widget.connections,
        const SizedBox(height: 16),
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            field('测试包数', _count, '首次建议 3 包'),
            field('批次号（uint32）', _batch, '十进制或0x开头；每轮更换'),
            field('TX 幅度', _amplitude, '0..2047'),
            field('接收等待（秒）', _wait, '每包发完后等待，0..60'),
          ],
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 10,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            FilledButton.icon(
              onPressed: widget.canStart && !c.running && !c.requiresReconnect
                  ? start
                  : null,
              icon: const Icon(Icons.play_arrow),
              label: const Text('开始 BER 测试'),
            ),
            OutlinedButton.icon(
              onPressed: c.running && ['running', 'checking'].contains(c.state)
                  ? c.stop
                  : null,
              icon: const Icon(Icons.stop),
              label: const Text('停止并保存'),
            ),
            OutlinedButton(
              onPressed:
                  widget.rxConnected && !c.running && !c.requiresReconnect
                  ? c.inspect
                  : null,
              child: const Text('读取状态 / 队首'),
            ),
            OutlinedButton(
              onPressed: widget.canStart && !c.running && !c.requiresReconnect
                  ? c.checkConnections
                  : null,
              child: const Text('双串口自检（不发包）'),
            ),
            TextButton(
              onPressed: c.running
                  ? null
                  : () => setState(
                      () => _batch.text = Random.secure()
                          .nextInt(0x100000000)
                          .toString(),
                    ),
              child: const Text('生成新批次'),
            ),
          ],
        ),
        if (!widget.connected)
          const Padding(
            padding: EdgeInsets.only(top: 8),
            child: Text('测试需要两个不同串口：TX 与 RX；状态检查只需 RX。'),
          ),
        if (c.requiresReconnect)
          const Padding(
            padding: EdgeInsets.only(top: 8),
            child: Text(
              '串口响应未决，连接已失效。请重新连接 TX / RX 后再测试；不会重发 SEND。',
              style: TextStyle(color: Colors.red),
            ),
          ),
        if (_error != null)
          Text(_error!, style: const TextStyle(color: Colors.red)),
        const SizedBox(height: 14),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  c.message,
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
                Text(
                  '阶段：${c.phase}　已结束包窗口：${c.progress}/${c.target}　状态：${c.state}',
                ),
                Text(
                  c.operation == 'connection_check'
                      ? '本次为串口自检，不发送 TIME_BASE 或 DATA'
                      : 'TIME_BASE发送：${{'not_started': '未开始', 'pending': '等待确认', 'complete': '已确认完成', 'unresolved': '未决，未确认发完'}[c.setupTx]}；RX确认：${c.setupRxConfirmed ? '是' : '否'}',
                ),
                Text('双串口自检：${c.connectionCheck}'),
                if (c.failedPhase != null) Text('中止阶段：${c.failedPhase}'),
                if (c.running)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: LinearProgressIndicator(
                      value: c.target > 0 ? c.progress / c.target : null,
                    ),
                  ),
                if (c.error != null)
                  SelectableText(
                    c.error!,
                    style: const TextStyle(color: Colors.red),
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            card('端到端 PER', ratio(report['per'], percent: true)),
            card('可对齐 Payload BER', ratio(report['ber'])),
            card('比较覆盖率', ratio(report['coverage'], percent: true)),
            card('正常交付 / 发完包数', '${report['delivered_unique'] ?? 0} / $total'),
            card(
              '误码数 / 比较位数',
              '${report['payload_bit_errors'] ?? 0} / ${report['compared_payload_bits'] ?? 0}',
            ),
            card(
              '有效吞吐（bit/s）',
              report['effective_throughput_bps'] is num
                  ? (report['effective_throughput_bps'] as num).toStringAsFixed(
                      2,
                    )
                  : '—',
            ),
          ],
        ),
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 12),
          child: Text(
            'BER 仅统计同步后、完整且身份校验通过的 Payload，有选择偏差，必须结合覆盖率。CRC 坏帧可用于诊断，正常 FIFO 仍拒收。身份不可靠、失锁和漏捕不猜算误码。— 表示分母为零或接收窗口未完成。',
          ),
        ),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            Chip(label: Text('TX 未决 ${report['tx_unresolved'] ?? 0}')),
            Chip(
              label: Text('接收窗口未结束 ${report['rx_windows_unfinished'] ?? 0}'),
            ),
            Chip(
              label: Text(
                '未对齐 ${report['unaligned_records'] ?? 0} / 部分 ${report['partial_records'] ?? 0}',
              ),
            ),
            Chip(
              label: Text(
                '旁路满丢弃 ${c.status['dropped'] ?? 0} / 忙漏捕 ${c.status['missed_sync'] ?? 0}',
              ),
            ),
            Chip(
              label: Text(
                '传输错误 ${report['transport_errors'] ?? 0} / 诊断协议错误 ${c.status['protocol_errors'] ?? 0}',
              ),
            ),
            Chip(label: Text('诊断队列 ${c.status['count'] ?? 0}/8')),
            Chip(
              label: Text(
                'FPGA CRC 错误计数 ${c.health['crc_error_count'] ?? '—'}',
              ),
            ),
            Chip(
              label: Text(
                '正常 FIFO 溢出标志 ${c.health['error_flags'] == null
                    ? '—'
                    : c.health['error_flags']! & 16 != 0
                    ? '1'
                    : '0'}',
              ),
            ),
            if (c.txDiagnostics.isNotEmpty)
              Chip(
                label: Text(
                  'TX UART err/ORE/ovf/parse ${c.txDiagnostics['rxerr'] ?? '—'}/${c.txDiagnostics['ore'] ?? '—'}/${c.txDiagnostics['rxovf'] ?? '—'}/${c.txDiagnostics['cmderr'] ?? '—'}',
                ),
              ),
            if (c.txDiagnostics['dwt'] == '1')
              Chip(
                label: Text(
                  'DMA重绘超UART预算 ${c.txDiagnostics['renderlate']} / 最大周期 ${c.txDiagnostics['rendermax']} / 字符预算 ${c.txDiagnostics['uartbudget']}',
                ),
              ),
            if (c.txDiagnostics['dwt'] == '0')
              const Chip(label: Text('TX周期计数器不可用；重绘耗时未测得')),
            if ((c.txDiagnostics['badhex'] ?? '').isNotEmpty)
              SizedBox(
                width: double.infinity,
                child: SelectableText(
                  'TX最近拒绝命令 HEX：${c.txDiagnostics['badhex']}',
                ),
              ),
          ],
        ),
        const SizedBox(height: 12),
        evidencePanel(),
        const SizedBox(height: 12),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '审计日志自动保存',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                SelectableText(c.exportPath ?? '开始测试后生成 exports/ber/ber_<时间戳>'),
                const Text(
                  'raw.jsonl：串口及逐包阶段原始证据；report.json：完整台账；failure_evidence.json：失败/未完成窗口及事件时间线。停止/异常同样保存。',
                ),
                Wrap(
                  spacing: 8,
                  children: [
                    TextButton(
                      onPressed: c.exportPath == null ? null : openDirectory,
                      child: const Text('打开结果目录'),
                    ),
                    TextButton(
                      onPressed: c.exportPath == null
                          ? null
                          : () => Clipboard.setData(
                              ClipboardData(text: c.exportPath!),
                            ),
                      child: const Text('复制目录路径'),
                    ),
                    TextButton(
                      onPressed: c.ledger == null
                          ? null
                          : () => Clipboard.setData(
                              ClipboardData(text: c.ledger!.report.toString()),
                            ),
                      child: const Text('复制统计'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
        if (c.lastCapture != null) ...[
          const SizedBox(height: 12),
          ExpansionTile(
            title: Text(
              '最新诊断记录 #${c.lastCapture!.id}　${c.lastCapture!.bits}/328 bit　${c.lastCapture!.identity == null ? '无法可靠对齐' : '身份有效'}',
            ),
            children: [
              Padding(
                padding: const EdgeInsets.all(16),
                child: SelectableText(
                  'flags=0x${c.lastCapture!.flags.toRadixString(16)}\nraw=${berHex(c.lastCapture!.raw)}',
                ),
              ),
            ],
          ),
        ],
        if (rows.isNotEmpty) ...[
          const SizedBox(height: 12),
          Text('逐包台账（最近100包）', style: Theme.of(context).textTheme.titleMedium),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: DataTable(
              columns: const [
                DataColumn(label: Text('32位包号')),
                DataColumn(label: Text('TX状态')),
                DataColumn(label: Text('正常交付')),
                DataColumn(label: Text('诊断对齐')),
                DataColumn(label: Text('Payload误码')),
                DataColumn(label: Text('RX窗口')),
              ],
              rows: [
                for (final a in rows)
                  DataRow(
                    cells: [
                      DataCell(Text('${a.sequence}')),
                      DataCell(Text(a.tx)),
                      DataCell(
                        Text(
                          c.ledger!.delivered.contains(a.sequence)
                              ? '是'
                              : '未观察到',
                        ),
                      ),
                      DataCell(
                        Text(
                          c.ledger!.captures.containsKey(a.sequence)
                              ? '是'
                              : '否',
                        ),
                      ),
                      DataCell(
                        Text(
                          c.ledger!.captures[a.sequence]
                                  ?.errors(a.payload)
                                  .toString() ??
                              '—',
                        ),
                      ),
                      DataCell(Text(a.windowComplete ? '完成' : '未结束')),
                    ],
                  ),
              ],
            ),
          ),
        ],
        const SizedBox(height: 12),
        ExpansionTile(
          title: const Text('运行事件'),
          children: [
            for (final event in c.events.take(30))
              ListTile(dense: true, title: Text(event)),
          ],
        ),
      ],
    );
  }
}
