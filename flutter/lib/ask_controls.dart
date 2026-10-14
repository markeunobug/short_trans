import 'package:flutter/material.dart';

typedef AskCommand = Future<String> Function(bool isTx, String command);

bool askReplyMatches(String command, String line) {
  if (line.startsWith('ERR')) return true;
  if (command == 'ASK STATUS') return line.startsWith('OK ASK STATUS ');
  if (command.startsWith('MOD ')) return line.startsWith('OK MOD ');
  if (command.startsWith('ASK THRESH ')) {
    return line.startsWith('OK ASK THRESH ');
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

// This coordinator reports each endpoint separately: a successful TX write
// cannot be treated as a successful RX mode change or threshold commit.
class AskController {
  AskController(this.command);
  final AskCommand command;
  AskStatus? status;
  String? txMode;

  Future<AskStatus> readStatus() async {
    final result = AskStatus.parse(await command(false, 'ASK STATUS'));
    status = result;
    return result;
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
  String _mode = 'FSK';
  String _message = '门限默认值尚未经过硬件标定；设备重启后恢复默认值';
  bool _busy = false;

  @override
  void didUpdateWidget(covariant AskControls oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.rxConnected || !widget.txConnected) {
      _controller.status = null;
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
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final enabled = !_busy && !widget.sweepRunning;
    final status = _controller.status;
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
        ],
      ),
    );
  }
}
