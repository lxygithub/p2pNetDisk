import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/transfer_notifications.dart';
import '../state/app_state.dart';
import 'connection_page.dart';
import '../theme.dart';
import '../widgets/glass.dart';
import '../widgets/path_chip.dart';

/// 设置页：连接状态、链路信息、后台运行与关于。
///
/// 敏感的连接参数统一放在独立的 [ConnectionPage]，这里只显示打码摘要，
/// 避免真实 EndpointId 出现在常驻页面或截图里。
class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage>
    with WidgetsBindingObserver {
  /// 电池优化豁免状态；null 表示查询中或平台不支持。
  bool? _ignoringBattery;
  Map<String, Object?>? _device;

  @override
  void initState() {
    super.initState();
    // 从系统「所有文件访问」设置页返回时，权限可能刚变化，需要重新解析下载目录。
    WidgetsBinding.instance.addObserver(this);
    _loadDevice();
    _loadDownloadRoot();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _loadDownloadRoot();
    }
  }

  /// 下载根目录是惰性解析的（依赖 path_provider 与存储权限），进入设置页时补一次，
  /// 让「保存到」一行显示真实路径而不是「默认」。
  Future<void> _loadDownloadRoot() async {
    final s = context.read<AppState>();
    // 用 refresh 而不是 ensure：从系统设置返回时权限可能刚变，需要重新解析
    // 默认位置（用户手动选过的自定义位置仍然优先，不会被冲掉）。
    await s.refreshDownloadRoot();
    if (!mounted) return;
    setState(() {});
  }

  Future<void> _grantPublicStorage() async {
    final s = context.read<AppState>();
    final opened = await s.requestPublicStorageAccess();
    if (!mounted) return;
    _snack(
      opened
          ? '请在系统设置里允许「所有文件访问」，返回后自动生效'
          : '无法打开权限设置，请在系统设置 → 应用 → 特殊应用权限里手动授予',
    );
  }

  Future<void> _pickDownloadDir() async {
    final s = context.read<AppState>();
    String? dir;
    try {
      dir = await FilePicker.getDirectoryPath(dialogTitle: '选择下载保存位置');
    } catch (e) {
      _snack('打开目录选择器失败: $e');
      return;
    }
    if (dir == null || dir.isEmpty) return;
    final ok = await s.setDownloadRoot(dir);
    if (!mounted) return;
    _snack(
      ok ? '下载位置已更新' : '该目录不可写（Android 11+ 公共目录需要系统授权），已保留原位置',
    );
  }

  Future<void> _resetDownloadDir() async {
    final s = context.read<AppState>();
    await s.resetDownloadRoot();
    if (!mounted) return;
    _snack('已恢复默认下载位置');
  }

  void _openConnectionPage() {
    unawaited(
      Navigator.of(context).push<void>(
        MaterialPageRoute<void>(builder: (_) => const ConnectionPage()),
      ),
    );
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
              _InfoRow(
                label: 'EndpointId',
                value: s.endpointConfigured ? s.maskedEndpointId : '未配置',
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: _openConnectionPage,
                  icon: const Icon(Icons.tune, size: 18),
                  label: const Text('编辑连接参数'),
                ),
              ),
              const SizedBox(height: 12),
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
              const SizedBox(height: 8),
              Text(
                '连接参数在独立页面管理，EndpointId 默认隐藏；此处只显示打码摘要。',
                style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
              ),
            ],
          ),
          const SizedBox(height: 16),
          _downloadCard(s),
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

  Widget _downloadCard(AppState s) {
    final scheme = Theme.of(context).colorScheme;
    final path = s.downloadRoot;
    return _SectionCard(
      title: '下载',
      children: [
        _InfoRow(
          label: '保存到',
          value: path.isEmpty ? '默认位置（首次下载时创建）' : path,
        ),
        _InfoRow(
          label: '卸载后',
          value: path.isEmpty
              ? '未知'
              : (s.downloadRootSurvivesUninstall
                    ? '保留（公共目录）'
                    : '一并删除（App 专属目录）'),
        ),
        if (s.publicStorageSupported && !s.publicStorageGranted) ...[
          const SizedBox(height: 10),
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: scheme.errorContainer.withValues(alpha: 0.5),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(
              '未获得「所有文件访问」权限：下载会落到 App 专属目录，'
              '卸载 App 时会被系统删除。授予后默认保存到公共 Download/p2pNetDisk。',
              style: TextStyle(
                fontSize: 12,
                color: scheme.onErrorContainer,
                height: 1.5,
              ),
            ),
          ),
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: _grantPublicStorage,
              icon: const Icon(Icons.folder_special, size: 18),
              label: const Text('授予公共目录访问'),
            ),
          ),
        ],
        const SizedBox(height: 12),
        SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            onPressed: _pickDownloadDir,
            icon: const Icon(Icons.folder_open, size: 18),
            label: const Text('选择保存位置'),
          ),
        ),
        const SizedBox(height: 8),
        SizedBox(
          width: double.infinity,
          child: TextButton.icon(
            onPressed: _resetDownloadDir,
            icon: const Icon(Icons.restore, size: 18),
            label: const Text('恢复默认位置'),
          ),
        ),
        const SizedBox(height: 6),
        Text(
          '默认保存到公共「下载」目录（Download/p2pNetDisk）：卸载 App 后文件仍在，'
          '系统文件管理器可直接打开。Android 11+ 需要「所有文件访问」权限才能写'
          '公共目录，未授权时会退到 App 专属目录。任何自定义位置都会先实测写入再保存。',
          style: TextStyle(
            fontSize: 12,
            color: scheme.onSurfaceVariant,
            height: 1.5,
          ),
        ),
      ],
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
