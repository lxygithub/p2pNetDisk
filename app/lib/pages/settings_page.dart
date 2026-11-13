import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/app_state.dart';
import '../theme.dart';
import '../widgets/glass.dart';
import '../widgets/path_chip.dart';

/// 设置页：连接参数、连接状态、链路信息。
///
/// 目前参数不持久化（重启要重填），后续接 shared_preferences；
/// n0 模式下只有地址可能需要改，所以痛点不算重。
class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late final TextEditingController _relay;
  late final TextEditingController _token;
  late final TextEditingController _addr;

  @override
  void initState() {
    super.initState();
    final s = context.read<AppState>();
    _relay = TextEditingController(text: s.relay);
    _token = TextEditingController(text: s.token);
    _addr = TextEditingController(text: s.serverAddr);
  }

  @override
  void dispose() {
    _relay.dispose();
    _token.dispose();
    _addr.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = context.watch<AppState>();
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: ListView(
        padding: kPagePadding,
        children: [
          _SectionCard(
            title: '连接',
            trailing: s.connected
                ? Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: scheme.primaryContainer,
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(
                      '已连接',
                      style: TextStyle(
                        fontSize: 11,
                        color: scheme.onPrimaryContainer,
                      ),
                    ),
                  )
                : null,
            children: [
              TextField(
                controller: _relay,
                decoration: const InputDecoration(
                  labelText: 'Relay',
                  helperText: 'n0 = 官方公共中继；也可填自建 https://host:8443',
                ),
                onChanged: (v) => s.relay = v.trim(),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _token,
                obscureText: true,
                decoration: const InputDecoration(
                  labelText: 'Relay Token',
                  helperText: '仅自建 relay 需要；n0 模式留空',
                ),
                onChanged: (v) => s.token = v.trim(),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _addr,
                maxLines: 3,
                minLines: 2,
                decoration: const InputDecoration(
                  labelText: '服务端 EndpointAddr',
                  helperText: 'n0 模式只需 {"id":"…","addrs":[]}',
                ),
                onChanged: (v) => s.serverAddr = v.trim(),
              ),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: s.busy ? null : s.connect,
                  icon: s.busy
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.link),
                  label: Text(s.connected ? '重新连接' : '连接'),
                ),
              ),
              if (s.pathSummary != null) ...[
                const SizedBox(height: 12),
                Row(
                  children: [
                    Text(
                      '当前链路',
                      style: TextStyle(
                        fontSize: 13,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                    const Spacer(),
                    PathChip(text: s.pathSummary!),
                  ],
                ),
              ],
              const SizedBox(height: 10),
              Text(
                s.status,
                style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
              ),
            ],
          ),
          const SizedBox(height: 16),
          _SectionCard(
            title: '关于',
            children: [
              _InfoRow(label: '应用', value: '个人网盘 0.1.0'),
              _InfoRow(label: '传输协议', value: 'iroh / QUIC + ALPN netdisk/0'),
              _InfoRow(label: '完整性校验', value: 'BLAKE3 端到端'),
              const SizedBox(height: 8),
              Text(
                '服务端不持有公网 IP，靠 iroh 打洞或 IPv6 直连；'
                '打不通时由 relay 转发。所有传输均为 QUIC 加密。',
                style: TextStyle(
                  fontSize: 12,
                  color: scheme.onSurfaceVariant,
                  height: 1.5,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _SectionCard extends StatelessWidget {
  const _SectionCard({
    required this.title,
    required this.children,
    this.trailing,
  });

  final String title;
  final List<Widget> children;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return GlassCard(
      padding: const EdgeInsets.all(16),
      child: Padding(
        padding: EdgeInsets.zero,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                const Spacer(),
                ?trailing,
              ],
            ),
            const SizedBox(height: 12),
            ...children,
          ],
        ),
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 88,
            child: Text(
              label,
              style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
            ),
          ),
          Expanded(child: Text(value, style: const TextStyle(fontSize: 13))),
        ],
      ),
    );
  }
}
