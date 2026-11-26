import 'package:flutter/material.dart';

typedef AskCommand = Future<String> Function(bool isTx, String command);

bool askReplyMatches(String command, String line) {
  if (line.startsWith('ERR')) return true;
  if (command == 'ASK STATUS') return line.startsWith('OK ASK STATUS ');
  if (command.startsWith('MOD ')) return line.startsWith('OK MOD ');
  if (command.startsWith('ASK THRESH ')) {
    return line.startsWith('OK ASK THRESH ');
  }
  if (command == 'FSK STATUS') return line.startsWith('OK FSK STATUS ');
  if (command.startsWith('FSK THRESH ')) {
    return line.startsWith('OK FSK THRESH ');
  }
  return false;
}

class AskThresholds {
  const AskThresholds(this.low, this.high);
  final int low;
  final int high;

  factory AskThresholds.parse(String lowText, String highText) {
    int value(String text) {
      if (!RegExp(r'^\d+$').hasMatch(text.trim())) {
        throw const FormatException('门限必须为十进制非负整数');
      }
      final parsed = int.tryParse(text.trim());
      if (parsed == null || parsed > 0xffffffff) {
        throw const FormatException('门限范围为 0 至 4294967295');
      }
      return parsed;
    }

    final low = value(lowText);
    final high = value(highText);
    if (low >= high) throw const FormatException('下门限必须小于上门限');
    return AskThresholds(low, high);
  }

  String get command => 'ASK THRESH $low $high';
}

class AskStatus {
  const AskStatus({
    required this.mode,
    required this.low,
    required this.high,
    required this.energy,
    required this.pending,
    required this.error,
    required this.generation,
    required this.bit,
    required this.locked,
    required this.ready,
  });
  final String mode;
  final int low, high, energy, generation;
  final bool pending, error, bit, locked, ready;

  factory AskStatus.parse(String line) {
    if (!line.startsWith('OK ASK STATUS ')) {
      throw FormatException('未收到有效 OOK 状态：$line');
    }
    final fields = <String, String>{};
    for (final token in line.split(RegExp(r'\s+'))) {
      final at = token.indexOf('=');
      if (at > 0) fields[token.substring(0, at)] = token.substring(at + 1);
    }
    int number(String key, [int maximum = 0xffffffff]) {
      final n = int.tryParse(fields[key] ?? '');
      if (n == null || n < 0 || n > maximum) {
        throw FormatException('无效 OOK 状态字段：$key');
      }
      return n;
    }

    final mode = fields['mode'];
    if (mode != 'FSK' && mode != 'OOK') {
      throw const FormatException('无效接收调制模式');
    }
    final low = number('low');
    final high = number('high');
    if (low >= high) throw const FormatException('设备返回的门限关系无效');
    return AskStatus(
      mode: mode!,
      low: low,
      high: high,
      energy: number('energy'),
      pending: number('pending', 1) == 1,
      error: number('error', 1) == 1,
      generation: number('generation', 255),
      bit: number('bit', 1) == 1,
      locked: number('locked', 1) == 1,
      ready: number('ready', 1) == 1,
    );
  }
}

class FskCarrierConfig {
  const FskCarrierConfig(this.marginQ4_4, this.offsetUnits);
  final int marginQ4_4;
  final int offsetUnits;

  factory FskCarrierConfig.parse(String marginText, String offsetText) {
    int number(String text, int maximum, String label) {
      if (!RegExp(r'^\d+$').hasMatch(text.trim())) {
        throw FormatException('$label 必须为十进制非负整数');
      }
      final value = int.tryParse(text.trim());
      if (value == null || value > maximum) {
        throw FormatException('$label 超出范围 0 至 $maximum');
      }
      return value;
    }

    final margin = number(marginText, 255, '倍率Q4.4');
    if (margin == 0) throw const FormatException('倍率不能为 0');
    return FskCarrierConfig(margin, number(offsetText, 65535, '偏置单位'));
  }

  String get command => 'FSK THRESH $marginQ4_4 $offsetUnits';
  double get multiplier => marginQ4_4 / 16.0;
}

class FskCarrierStatus {
  const FskCarrierStatus({
    required this.marginQ4_4,
    required this.offsetUnits,
    required this.pending,
    required this.error,
    required this.busy,
    required this.sweep,
    required this.mode,
    required this.generation,
  });
  final int marginQ4_4, offsetUnits, mode, generation;
  final bool pending, error, busy, sweep;
  double get multiplier => marginQ4_4 / 16.0;

  factory FskCarrierStatus.parse(String line) {
    if (!line.startsWith('OK FSK STATUS ')) {
      throw FormatException('未收到有效 FSK 状态：$line');
    }
    final fields = <String, String>{};
    for (final token in line.split(RegExp(r'\s+'))) {
      final at = token.indexOf('=');
      if (at > 0) fields[token.substring(0, at)] = token.substring(at + 1);
    }
    int number(String key, [int maximum = 0xffffffff]) {
      final value = int.tryParse(fields[key] ?? '');
      if (value == null || value < 0 || value > maximum) {
        throw FormatException('无效 FSK 状态字段：$key');
      }
      return value;
    }

    final margin = number('margin', 255);
    final mode = number('mode', 2);
    if (margin == 0 || (mode != 1 && mode != 2)) {
      throw const FormatException('FPGA 返回了无效的 FSK 参数状态');
    }
    return FskCarrierStatus(
      marginQ4_4: margin,
      offsetUnits: number('offset', 65535),
      pending: number('pending', 1) == 1,
      error: number('error', 1) == 1,
      busy: number('busy', 1) == 1,
      sweep: number('sweep', 1) == 1,
      mode: mode,
      generation: number('generation', 255),
    );
  }
}
// This coordinator reports each endpoint separately: a successful TX write
// cannot be treated as a successful RX mode change or threshold commit.
class AskController {
  AskController(this.command);
  final AskCommand command;
  AskStatus? status;
  FskCarrierStatus? fskStatus;
  String? txMode;

  Future<AskStatus> readStatus() async {
    final result = AskStatus.parse(await command(false, 'ASK STATUS'));
    status = result;
    return result;
  }

  Future<FskCarrierStatus> readFskStatus() async {
    final result = FskCarrierStatus.parse(await command(false, 'FSK STATUS'));
    fskStatus = result;
    return result;
  }

  Future<String> setFskCarrier(FskCarrierConfig config) async {
    final reply = await command(false, config.command);
    final expected = 'OK FSK THRESH margin=${config.marginQ4_4} offset=${config.offsetUnits}';
    if (!reply.startsWith(expected) || !RegExp(r' pending=[01]\s*$').hasMatch(reply)) {
      throw StateError('FSK 阈值未确认：$reply');
    }
    final active = await readFskStatus();
    if (active.error) throw StateError('FPGA 拒绝了 FSK 阈值');
    if (active.pending) return 'FSK 参数已提交，等待接收空闲后生效';
    if (active.marginQ4_4 != config.marginQ4_4 || active.offsetUnits != config.offsetUnits) {
      throw StateError('FSK 参数读回与请求不一致');
    }
    return 'FSK 门限已生效：倍率 ${active.multiplier.toStringAsFixed(2)}x，偏置 ${active.offsetUnits} 单位';
  }
  Future<String> setMode(String mode) async {
    if (mode != 'FSK' && mode != 'OOK') {
      throw const FormatException('不支持的调制模式');
    }
    final txReply = await command(true, 'MOD $mode');
    if (txReply.trim() != 'OK MOD $mode') {
      throw StateError('TX 未确认切换：$txReply');
    }
    txMode = mode;
    try {
      final rxReply = await command(false, 'MOD $mode');
      if (!RegExp('^OK MOD $mode pending=[01]\\s*\$').hasMatch(rxReply)) {
        throw StateError(rxReply);
      }
      final active = await readStatus();
      if (active.error) throw StateError('RX 配置错误标志已置位');
      if (active.pending) return 'TX 已切换为 $mode；RX 等待空闲生效，请稍后读取状态';
      if (active.mode != mode) throw StateError('RX 实际模式仍为 ${active.mode}');
      return 'TX / RX 已确认 $mode 模式';
    } catch (error) {
      throw StateError('TX 已切换为 $mode；RX 未确认。请检查后重新应用：$error');
    }
  }

  Future<String> setThresholds(AskThresholds thresholds) async {
    final reply = await command(false, thresholds.command);
    if (!RegExp(
      '^OK ASK THRESH low=${thresholds.low} high=${thresholds.high} pending=[01]\\s*\$',
    ).hasMatch(reply)) {
      throw StateError('门限未确认：$reply');
    }
    final active = await readStatus();
    if (active.error) throw StateError('RX 配置错误标志已置位');
    if (active.pending) return '门限已提交，等待接收空闲后生效；请稍后读取状态';
    if (active.low != thresholds.low || active.high != thresholds.high) {
      throw StateError('读回门限与请求不一致，尚未确认生效');
    }
    return '门限已生效：${active.low} / ${active.high}';
  }
}

class AskControls extends StatefulWidget {
  const AskControls({
    super.key,
    required this.txConnected,
    required this.rxConnected,
    required this.sweepRunning,
    required this.command,
    required this.onBusy,
  });
  final bool txConnected, rxConnected, sweepRunning;
  final AskCommand command;
  final ValueChanged<bool> onBusy;
  @override
  State<AskControls> createState() => _AskControlsState();
}

class _AskControlsState extends State<AskControls> {
  late final AskController _controller = AskController(
    (tx, command) => widget.command(tx, command),
  );
  final _low = TextEditingController(text: '400');
  final _high = TextEditingController(text: '600');
  final _fskMargin = TextEditingController(text: '32');
  final _fskOffset = TextEditingController(text: '200');
  String _mode = 'FSK';
  String _message = '门限默认值尚未经过硬件标定；设备重启后恢复默认值';
  bool _busy = false;

  @override
  void didUpdateWidget(covariant AskControls oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.rxConnected && !widget.rxConnected) {
      _controller.status = null;
      _controller.fskStatus = null;
    }
    if (oldWidget.txConnected && !widget.txConnected) {
      _controller.txMode = null;
    }
  }
  Future<void> _perform(Future<String> Function() action) async {
    if (_busy || widget.sweepRunning) return;
    setState(() => _busy = true);
    widget.onBusy(true);
    try {
      final result = await action();
      if (mounted) setState(() => _message = result);
    } catch (error) {
      if (mounted) setState(() => _message = error.toString());
    } finally {
      widget.onBusy(false);
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    _low.dispose();
    _high.dispose();
    _fskMargin.dispose();
    _fskOffset.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final enabled = !_busy && !widget.sweepRunning;
    final status = _controller.status;
    final fskStatus = _controller.fskStatus;
    return Card(
      child: ExpansionTile(
        initiallyExpanded: true,
        title: const Text('调制与 OOK 固定门限'),
        subtitle: Text(_message, maxLines: 2, overflow: TextOverflow.ellipsis),
        childrenPadding: const EdgeInsets.all(12),
        children: [
          Wrap(
            spacing: 12,
            runSpacing: 12,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              SizedBox(
                width: 200,
                child: DropdownButtonFormField<String>(
                  initialValue: _mode,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: '通信调制'),
                  items: const [
                    DropdownMenuItem(value: 'FSK', child: Text('模式 1：2FSK')),
                    DropdownMenuItem(
                      value: 'OOK',
                      child: Text('模式 2：OOK 1.8 kHz'),
                    ),
                  ],
                  onChanged: enabled
                      ? (value) => setState(() => _mode = value!)
                      : null,
                ),
              ),
              FilledButton(
                onPressed: enabled && widget.txConnected && widget.rxConnected
                    ? () => _perform(() => _controller.setMode(_mode))
                    : null,
                child: const Text('应用到 TX / RX'),
              ),
              SizedBox(
                width: 170,
                child: TextField(
                  controller: _low,
                  enabled: enabled,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: '下门限（能量值）'),
                ),
              ),
              SizedBox(
                width: 170,
                child: TextField(
                  controller: _high,
                  enabled: enabled,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: '上门限（能量值）'),
                ),
              ),
              OutlinedButton(
                onPressed: enabled && widget.rxConnected
                    ? () => _perform(
                        () => _controller.setThresholds(
                          AskThresholds.parse(_low.text, _high.text),
                        ),
                      )
                    : null,
                child: const Text('提交门限'),
              ),
              OutlinedButton(
                onPressed: enabled && widget.rxConnected
                    ? () => _perform(() async {
                        final active = await _controller.readStatus();
                        if (active.error) return 'RX 配置错误，请检查设备响应';
                        return active.pending ? '配置仍在等待空闲生效' : '已读取 RX 实际配置';
                      })
                    : null,
                child: const Text('读取实际状态'),
              ),
            ],
          ),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              SizedBox(
                width: 180,
                child: TextField(
                  controller: _fskMargin,
                  enabled: enabled,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: 'FSK 倍率 Q4.4'),
                ),
              ),
              SizedBox(
                width: 180,
                child: TextField(
                  controller: _fskOffset,
                  enabled: enabled,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: '偏置单位 (x256)'),
                ),
              ),
              OutlinedButton(
                onPressed: enabled && widget.rxConnected
                    ? () => _perform(() => _controller.setFskCarrier(
                          FskCarrierConfig.parse(_fskMargin.text, _fskOffset.text),
                        ))
                    : null,
                child: const Text('提交 FSK 载波门限'),
              ),
              OutlinedButton(
                onPressed: enabled && widget.rxConnected
                    ? () => _perform(() async {
                        final active = await _controller.readFskStatus();
                        if (active.error) return 'FSK 参数错误，请检查设备状态';
                        return active.pending ? 'FSK 参数等待空闲生效' : '已读取 FSK 实际参数';
                      })
                    : null,
                child: const Text('读取 FSK 参数'),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: Text(
              status == null
                  ? 'RX 实际配置：尚未读取。切换调制前请先停止 TX；模式 3 请使用扫频页面。'
                  : 'RX：${status.mode}  生效门限 ${status.low} / ${status.high}  '
                        '能量 ${status.energy}  bit=${status.bit ? 1 : 0}  '
                        '锁定=${status.locked ? 1 : 0}  就绪=${status.ready ? 1 : 0}  '
                        '待生效=${status.pending ? 1 : 0}  版本=${status.generation}',
            ),
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: Text(
              fskStatus == null
                  ? 'FSK 实际参数：尚未读取。Q4.4 原始值 32 = 2.0x；偏置每单位增加 256 个能量计数。'
                  : 'FSK：${fskStatus.multiplier.toStringAsFixed(2)}x  偏置 ${fskStatus.offsetUnits} 单位 (${fskStatus.offsetUnits * 256} 能量计数)  '
                        '忙=${fskStatus.busy ? 1 : 0}  待生效=${fskStatus.pending ? 1 : 0}  错误=${fskStatus.error ? 1 : 0}  代数=${fskStatus.generation}',
            ),
          ),
        ],
      ),
    );
  }
}
