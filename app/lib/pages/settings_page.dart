import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/transfer_notifications.dart';
import '../state/app_state.dart';
import '../theme.dart';
import '../widgets/glass.dart';
import '../widgets/path_chip.dart';

/// 设置页：连接参数、连接状态、链路信息。
///
/// 参数改动经 [AppState.updateConnectionConfig] 持久化到 App 私有目录，冷启动时
/// 由 main() 读回；「恢复默认」清掉本机配置，回到编译期注入的默认值。
class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late final TextEditingController _relay;
  late final TextEditingController _token;
  late final TextEditingController _addr;

  /// 电池优化豁免状态；null 表示查询中或平台不支持。
  bool? _ignoringBattery;
  Map<String, Object?>? _device;

  @override
  void initState() {
    super.initState();
    final s = context.read<AppState>();
    _relay = TextEditingController(text: s.relay);
    _token = TextEditingController(text: s.token);
    _addr = TextEditingController(text: s.serverAddr);
    _loadDevice();
  }

  Future<void> _loadDevice() async {
    final ignoring =
        await TransferNotifications.isIgnoringBatteryOptimizations();
    final info = await TransferNotifications.deviceInfo();
    if (!mounted) return;
    setState(() {
      _ignoringBattery = ignoring;
      _device = info;
    });
  }

  Future<void> _requestIgnoreBattery() async {
    final opened =
        await TransferNotifications.requestIgnoreBatteryOptimizations();
    if (!mounted) return;
    if (!opened) {
      _snack('无法打开电池优化设置，请在系统设置中手动操作');
      return;
    }
    // 用户可能停留一会儿才回来，延迟刷新状态。
    await Future<void>.delayed(const Duration(seconds: 2));
    await _loadDevice();
  }

  Future<void> _openAutoStart() async {
    final hit = await TransferNotifications.openAutoStartSettings();
    if (!mounted) return;
    if (!hit) _snack('未找到厂商专属页面，已打开应用详情');
  }

  void _snack(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  /// 清掉本机保存的连接参数，回到编译期注入的默认值。
  ///
  /// 手填的 EndpointId 有 52 个字符，误触清掉很麻烦，所以先确认一次。
  Future<void> _resetToDefault(AppState s) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('恢复默认连接参数？'),
        content: const Text(
          '将清除本机保存的服务端地址与 Relay 设置，回到编译期注入的默认值。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('清除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await s.resetConnectionConfig();
    if (!mounted) return;
    // controller 只在 initState 里初始化过一次，值变了要手动同步回输入框。
    setState(() {
      _relay.text = s.relay;
      _token.text = s.token;
      _addr.text = s.serverAddr;
    });
    _snack('已恢复默认连接参数（清除本机保存的地址）');
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
                onChanged: (v) => s.updateConnectionConfig(relay: v.trim()),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _token,
                obscureText: true,
                decoration: const InputDecoration(
                  labelText: 'Relay Token',
                  helperText: '仅自建 relay 需要；n0 模式留空',
                ),
                onChanged: (v) => s.updateConnectionConfig(token: v.trim()),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _addr,
                maxLines: 3,
                minLines: 2,
                decoration: const InputDecoration(
                  labelText: '服务端 EndpointAddr',
                  helperText: 'n0 模式只需 {"id":"…","addrs":[]}，改动自动保存到本机',
                ),
                onChanged: (v) => s.updateConnectionConfig(addr: v.trim()),
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
              Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                  onPressed: () => unawaited(_resetToDefault(s)),
                  icon: const Icon(Icons.restore, size: 16),
                  label: const Text('恢复默认'),
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
          _backgroundCard(),
          const SizedBox(height: 16),
          _SectionCard(
            title: '关于',
            children: [
              Row(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(14),
                    child: Image.asset(
                      'assets/images/logo.png',
                      width: 52,
                      height: 52,
                    ),
                  ),
                  const SizedBox(width: 14),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'p2pNetDisk',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                          color: scheme.onSurface,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'P2P 个人网盘客户端',
                        style: TextStyle(
                          fontSize: 12,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 12),
              _InfoRow(label: '版本', value: '0.1.0'),
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

  Widget _backgroundCard() {
    final scheme = Theme.of(context).colorScheme;
    final device = _device;
    final deviceLabel = device == null
        ? '未知'
        : '${device['manufacturer']} ${device['model']}'
              '${device['harmony'] == true ? ' · HarmonyOS' : ''}';

    final ignoring = _ignoringBattery;

    return _SectionCard(
      title: '后台运行',
      children: [
        _InfoRow(label: '设备', value: deviceLabel),
        _InfoRow(
          label: '电池优化',
          value: ignoring == null ? '未知' : (ignoring ? '已豁免' : '未豁免'),
        ),
        const SizedBox(height: 12),
        if (ignoring == false) ...[
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: _requestIgnoreBattery,
              icon: const Icon(Icons.battery_saver_outlined),
              label: const Text('关闭电池优化'),
            ),
          ),
          const SizedBox(height: 8),
        ],
        SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            onPressed: _openAutoStart,
            icon: const Icon(Icons.tune),
            label: const Text('自启动 / 后台管理设置'),
          ),
        ),
        const SizedBox(height: 10),
        Text(
          '锁屏或切到后台时系统可能冻结进程，导致传输中断。'
          '华为/荣耀需在「应用启动管理」允许后台活动，小米需开「自启动」，'
          'OPPO/vivo 需允许后台运行。',
          style: TextStyle(
            fontSize: 12,
            color: scheme.onSurfaceVariant,
            height: 1.5,
          ),
        ),
      ],
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
