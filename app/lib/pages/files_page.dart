import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/transfer_task.dart';
import '../state/app_state.dart';
import '../theme.dart';
import '../widgets/breadcrumb.dart';
import '../widgets/path_chip.dart';

/// 文件浏览页：面包屑 + 目录/文件列表 + 上传入口。
class FilesPage extends StatelessWidget {
  const FilesPage({super.key});

  @override
  Widget build(BuildContext context) {
    final s = context.watch<AppState>();

    return Scaffold(
      appBar: AppBar(
        title: const Text('文件'),
        actions: [
          if (s.pathSummary != null) PathChip(text: s.pathSummary!),
          IconButton(
            tooltip: '刷新',
            onPressed: s.busy || !s.connected ? null : () => s.refresh(),
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: Column(
        children: [
          if (!s.connected) const _ConnectHint(),
          Breadcrumb(),
          Expanded(child: _FileList(state: s)),
          _StatusBar(text: s.status),
        ],
      ),
      floatingActionButton: s.connected
          ? FloatingActionButton.extended(
              onPressed: s.busy ? null : () => _pickAndUpload(context),
              icon: const Icon(Icons.upload_file),
              label: const Text('上传'),
            )
          : null,
    );
  }

  Future<void> _pickAndUpload(BuildContext context) async {
    final state = context.read<AppState>();

    List<PlatformFile> picked;
    try {
      // file_picker 13.x：pickFiles() 直接返回列表，取消时是空列表。
      picked = await FilePicker.pickFiles();
    } catch (e) {
      state.setStatus('打开文件选择器失败: $e');
      return;
    }
    if (picked.isEmpty) return;

    final files = <({String name, String path, int size})>[];
    for (final f in picked) {
      final path = f.path;
      if (path == null) continue;
      // v13 的 PlatformFile 没有 size 字段。
      final size = f.lengthSync() ?? await f.length() ?? 0;
      files.add((name: f.name, path: path, size: size));
    }
    if (files.isEmpty) {
      state.setStatus('拿不到文件路径（部分平台只给流）');
      return;
    }
    await state.enqueueUploads(files);
  }
}

class _ConnectHint extends StatelessWidget {
  const _ConnectHint();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: scheme.secondaryContainer,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          Icon(Icons.info_outline, color: scheme.onSecondaryContainer),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              '尚未连接。到「设置」页确认地址后点「连接」。',
              style: TextStyle(color: scheme.onSecondaryContainer),
            ),
          ),
        ],
      ),
    );
  }
}

class _FileList extends StatelessWidget {
  const _FileList({required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    if (!state.connected) {
      return const SizedBox.shrink();
    }
    if (state.files.isEmpty) {
      return const _EmptyState(
        icon: Icons.cloud_off,
        title: '还没有文件',
        subtitle: '点右下角「上传」把文件传上来',
      );
    }
    final entries = state.entries;
    if (entries.isEmpty) {
      return const _EmptyState(
        icon: Icons.folder_open,
        title: '此目录为空',
        subtitle: '上传的文件会放到当前目录',
      );
    }

    return ListView.separated(
      padding: kPagePadding,
      itemCount: entries.length,
      separatorBuilder: (_, _) => const SizedBox(height: 8),
      itemBuilder: (context, i) {
        final e = entries[i];
        return e.isDir
            ? _DirTile(
                name: e.name,
                onTap: state.busy ? null : () => state.enterDir(e.name),
              )
            : _FileTile(
                name: e.name,
                size: e.size,
                busy: state.busy,
                onDownload: () => state.enqueueDownload(e.path, e.size),
                onRename: () => _renameDialog(context, state, e.path),
                onDelete: () => _deleteConfirm(context, state, e.path),
              );
      },
    );
  }

  Future<void> _deleteConfirm(
    BuildContext context,
    AppState state,
    String path,
  ) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除文件'),
        content: Text('$path\n\n会移入服务端回收站，不会立即物理删除。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok == true) await state.deleteFile(path);
  }

  Future<void> _renameDialog(
    BuildContext context,
    AppState state,
    String current,
  ) async {
    final controller = TextEditingController(text: current);
    final next = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('重命名 / 移动'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: '新路径（可含子目录）',
            helperText: '目标已存在时不会覆盖，会直接报错',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('确定'),
          ),
        ],
      ),
    );
    final target = next?.trim() ?? '';
    controller.dispose();
    if (target.isEmpty || target == current) return;
    await state.renameFile(current, target);
  }
}

class _DirTile extends StatelessWidget {
  const _DirTile({required this.name, this.onTap});

  final String name;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surfaceContainerLow,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Row(
            children: [
              Icon(Icons.folder, color: scheme.primary),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  name,
                  style: const TextStyle(fontWeight: FontWeight.w500),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Icon(Icons.chevron_right, size: 18, color: scheme.outline),
            ],
          ),
        ),
      ),
    );
  }
}

class _FileTile extends StatelessWidget {
  const _FileTile({
    required this.name,
    required this.size,
    required this.busy,
    required this.onDownload,
    required this.onRename,
    required this.onDelete,
  });

  final String name;
  final int size;
  final bool busy;
  final VoidCallback onDownload;
  final VoidCallback onRename;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surfaceContainerLow,
      borderRadius: BorderRadius.circular(14),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 4, 10),
        child: Row(
          children: [
            Icon(Icons.insert_drive_file_outlined, color: scheme.onSurfaceVariant),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(name, overflow: TextOverflow.ellipsis),
                  const SizedBox(height: 2),
                  Text(
                    humanSize(size),
                    style: TextStyle(
                      fontSize: 12,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            PopupMenuButton<String>(
              enabled: !busy,
              tooltip: '更多操作',
              icon: const Icon(Icons.more_vert, size: 20),
              onSelected: (v) {
                switch (v) {
                  case 'download':
                    onDownload();
                  case 'rename':
                    onRename();
                  case 'delete':
                    onDelete();
                }
              },
              itemBuilder: (_) => const [
                PopupMenuItem(
                  value: 'download',
                  child: ListTile(
                    dense: true,
                    leading: Icon(Icons.download),
                    title: Text('下载'),
                  ),
                ),
                PopupMenuItem(
                  value: 'rename',
                  child: ListTile(
                    dense: true,
                    leading: Icon(Icons.drive_file_rename_outline),
                    title: Text('重命名'),
                  ),
                ),
                PopupMenuItem(
                  value: 'delete',
                  child: ListTile(
                    dense: true,
                    leading: Icon(Icons.delete_outline),
                    title: Text('删除'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  final IconData icon;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 48, color: scheme.outline),
          const SizedBox(height: 12),
          Text(title, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 4),
          Text(
            subtitle,
            style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13),
          ),
        ],
      ),
    );
  }
}

class _StatusBar extends StatelessWidget {
  const _StatusBar({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 10),
      child: Text(
        text,
        style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }
}
