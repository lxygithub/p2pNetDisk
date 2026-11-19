import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/endpoint_addr.dart';
import '../state/app_state.dart';
import '../theme.dart';
import '../widgets/glass.dart';
import '../widgets/app_icons.dart';

/// 连接参数编辑页。
///
/// 与设置页分开，是为了把敏感输入集中在一个地方管理：
/// - EndpointId 与 addrs 用两个输入框，用户不用手拼 JSON；
/// - 已配置的真实 EndpointId 默认隐藏，设置页只显示打码摘要；
/// - 页面内是草稿，点「保存」才会写入状态与本机配置，半截输入不会落盘。
class ConnectionPage extends StatefulWidget {
  const ConnectionPage({super.key});

  @override
  State<ConnectionPage> createState() => _ConnectionPageState();
}

class _ConnectionPageState extends State<ConnectionPage> {
  late final TextEditingController _relay;
  late final TextEditingController _token;
  late final TextEditingController _id;
  late final TextEditingController _addrs;

  /// 占位符不敏感，第一次配置时直接展开，方便粘贴核对；
  /// 已经有真实 ID 时默认隐藏。
  late bool _showId;

  /// `addrs` 为 `[]` 时展开方便编辑；含自建 relay 地址时默认隐藏。
  late bool _showAddrs;
  bool _showToken = false;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final s = context.read<AppState>();
    final parts = splitEndpointAddr(s.serverAddr);
    _relay = TextEditingController(text: s.relay);
    _token = TextEditingController(text: s.token);
    _id = TextEditingController(text: parts.id);
    _addrs = TextEditingController(text: parts.addrs);
    _showId = !s.endpointConfigured;
    _showAddrs = parts.addrs == '[]';
  }

  @override
  void dispose() {
    _relay.dispose();
    _token.dispose();
    _id.dispose();
    _addrs.dispose();
    super.dispose();
  }

  void _clearError() {
    if (_error != null) setState(() => _error = null);
  }

  void _snack(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  /// 校验 + 写入 AppState + 同步落盘。返回是否保存成功。
  Future<bool> _save() async {
    final result = buildEndpointAddr(id: _id.text, addrs: _addrs.text);
    if (result.error != null) {
      setState(() => _error = result.error);
      return false;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    await context.read<AppState>().saveConnectionConfig(
      relay: _relay.text.trim(),
      token: _token.text.trim(),
      addr: result.addr!,
    );
    if (!mounted) return false;
    setState(() => _saving = false);
    _snack('连接参数已保存到本机');
    return true;
  }

  Future<void> _saveAndConnect() async {
    if (!await _save()) return;
    if (!mounted) return;
    await context.read<AppState>().connect();
    if (!mounted) return;
    // 回设置页看连接状态与链路摘要。
    Navigator.of(context).pop();
  }

  Future<void> _reset() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('恢复默认连接参数？'),
        content: const Text('将清除本机保存的服务端地址与 Relay 设置，回到编译期注入的默认值。'),
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
    final s = context.read<AppState>();
    await s.resetConnectionConfig();
    if (!mounted) return;
    final parts = splitEndpointAddr(s.serverAddr);
    setState(() {
      _relay.text = s.relay;
      _token.text = s.token;
      _id.text = parts.id;
      _addrs.text = parts.addrs;
      _showId = !s.endpointConfigured;
      _showAddrs = parts.addrs == '[]';
      _error = null;
    });
    _snack('已恢复默认连接参数（清除本机保存的地址）');
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('连接参数'),
        actions: [
          TextButton(
            onPressed: _saving ? null : () => unawaited(_save()),
            child: const Text('保存'),
          ),
        ],
      ),
      body: ListView(
        padding: kPagePadding,
        children: [
          _card(
            title: '隐私',
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  AppIconView(
                    AppIcons.visibility_off_outlined,
                    size: 18,
                    color: scheme.primary,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'EndpointId 默认隐藏，设置页只显示打码摘要；'
                      '真实值仅保存在本机，不会写进日志或版本控制。',
                      style: TextStyle(
                        fontSize: 12,
                        color: scheme.onSurfaceVariant,
                        height: 1.5,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 16),
          _card(
            title: '服务端身份',
            children: [
              TextField(
                controller: _id,
                obscureText: !_showId,
                maxLines: 1,
                decoration: InputDecoration(
                  labelText: 'EndpointId',
                  helperText: '纯 ID，不带引号 / 花括号；n0 模式由 dns.iroh.link 解析',
                  suffixIcon: IconButton(
                    icon: AppIconView(
                      _showId ? AppIcons.visibility_off : AppIcons.visibility,
                      size: 20,
                    ),
                    tooltip: _showId ? '隐藏' : '显示',
                    onPressed: () => setState(() => _showId = !_showId),
                  ),
                ),
                onChanged: (_) => _clearError(),
              ),
              const SizedBox(height: 14),
              TextField(
                controller: _addrs,
                // 单行才能配合 obscureText；JSON 数组本来也不长，可横向滚动。
                maxLines: 1,
                obscureText: !_showAddrs,
                decoration: InputDecoration(
                  labelText: 'addrs（地址列表）',
                  helperText:
                      'JSON 数组：n0 填 []；自建 relay 填 [{"Relay":"https://host:8443/"}]',
                  suffixIcon: IconButton(
                    icon: AppIconView(
                      _showAddrs
                          ? AppIcons.visibility_off
                          : AppIcons.visibility,
                      size: 20,
                    ),
                    tooltip: _showAddrs ? '隐藏' : '显示',
                    onPressed: () => setState(() => _showAddrs = !_showAddrs),
                  ),
                ),
                onChanged: (_) => _clearError(),
              ),
              if (_error != null) ...[
                const SizedBox(height: 10),
                Text(
                  _error!,
                  style: TextStyle(fontSize: 12, color: scheme.error),
                ),
              ],
            ],
          ),
          const SizedBox(height: 16),
          _card(
            title: '中继',
            children: [
              TextField(
                controller: _relay,
                decoration: const InputDecoration(
                  labelText: 'Relay',
                  helperText: 'n0 = 官方公共中继；也可填自建 https://host:8443',
                ),
                onChanged: (_) => _clearError(),
              ),
              const SizedBox(height: 14),
              TextField(
                controller: _token,
                obscureText: !_showToken,
                decoration: InputDecoration(
                  labelText: 'Relay Token',
                  helperText: '仅自建 relay 需要；n0 模式留空',
                  suffixIcon: IconButton(
                    icon: AppIconView(
                      _showToken
                          ? AppIcons.visibility_off
                          : AppIcons.visibility,
                      size: 20,
                    ),
                    tooltip: _showToken ? '隐藏' : '显示',
                    onPressed: () => setState(() => _showToken = !_showToken),
                  ),
                ),
                onChanged: (_) => _clearError(),
              ),
            ],
          ),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: _saving ? null : () => unawaited(_saveAndConnect()),
              icon: _saving
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const AppIconView(AppIcons.link),
              label: const Text('保存并连接'),
            ),
          ),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              onPressed: _saving ? null : () => unawaited(_reset()),
              icon: const AppIconView(AppIcons.restore, size: 16),
              label: const Text('恢复默认'),
            ),
          ),
          Text(
            '修改后需点「保存」或「保存并连接」才会生效并记住；直接返回不保存。',
            style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }

  Widget _card({required String title, required List<Widget> children}) {
    final scheme = Theme.of(context).colorScheme;
    return GlassCard(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: scheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 12),
          ...children,
        ],
      ),
    );
  }
}
