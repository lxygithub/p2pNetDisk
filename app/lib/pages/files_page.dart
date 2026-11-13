import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/transfer_task.dart';
import '../state/app_state.dart';
import '../theme.dart';
import '../widgets/breadcrumb.dart';
import '../widgets/glass.dart';
import '../widgets/path_chip.dart';
import 'preview_page.dart';

/// 文件浏览页：面包屑 + 目录/文件列表 + 上传/新建目录入口。
class FilesPage extends StatelessWidget {
  const FilesPage({super.key});

  @override
  Widget build(BuildContext context) {
    final s = context.watch<AppState>();

    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        title: const Text('文件'),
        actions: [
          if (s.pathSummary != null) PathChip(text: s.pathSummary!),
          IconButton(
            tooltip: '新建目录',
            onPressed: s.busy || !s.connected ? null : () => _newDir(context),
            icon: const Icon(Icons.create_new_folder_outlined),
          ),
          IconButton(
            tooltip: '刷新',
            onPressed: s.busy || !s.connected ? null : () => s.refresh(),
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: Column(
        children: [
          const Breadcrumb(),
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

  Future<void> _newDir(BuildContext context) async {
    final state = context.read<AppState>();
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('新建目录'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: '目录名',
            helperText: '可带子路径，例如 photos/2026',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('创建'),
          ),
        ],
      ),
    );
    final trimmed = name?.trim() ?? '';
    controller.dispose();
    if (trimmed.isEmpty) return;
    await state.createDir(trimmed);
  }
}

class _FileList extends StatelessWidget {
  const _FileList({required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    return RefreshIndicator(
      onRefresh: () async {
        if (!state.connected) {
          await state.connect();
        }
        await state.refresh(silent: true);
      },
      child: _content(context),
    );
  }

  /// 未连接与空状态也用可滚动容器包住，否则下拉刷新在空白页上失效。
  Widget _content(BuildContext context) {
    if (!state.connected) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(24, 80, 24, 24),
        children: [
          const _EmptyState(
            icon: Icons.cloud_off,
            title: '未连接',
            subtitle: '下拉刷新，或点下面的「重试」',
          ),
          const SizedBox(height: 16),
          Center(
            child: FilledButton.icon(
              onPressed: state.busy
                  ? null
                  : () {
                      unawaited(state.bootstrap());
                    },
              icon: const Icon(Icons.refresh),
              label: const Text('重试'),
            ),
          ),
        ],
      );
    }

    if (state.files.isEmpty) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(24, 80, 24, 24),
        children: const [
          _EmptyState(
            icon: Icons.cloud_off,
            title: '还没有文件',
            subtitle: '点右下角「上传」把文件传上来',
          ),
        ],
      );
    }

    final entries = state.entries;
    if (entries.isEmpty) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(24, 80, 24, 24),
        children: const [
          _EmptyState(
            icon: Icons.folder_open,
            title: '此目录为空',
            subtitle: '上传的文件会放到当前目录',
          ),
        ],
      );
    }

    return ListView.separated(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: kPagePadding,
      itemCount: entries.length,
      separatorBuilder: (_, _) => const SizedBox(height: 8),
      itemBuilder: (context, i) {
        final e = entries[i];
        if (e.isDir) {
          return _DirTile(
            name: e.name,
            onTap: state.busy ? null : () => state.enterDir(e.name),
            onRename: () => _renameDialog(context, state, e.path),
          );
        }
        return _FileTile(
          name: e.name,
          size: e.size,
          busy: state.busy,
          onPreview: () => _openPreview(context, e.path),
          onDownload: () => state.enqueueDownload(e.path, e.size),
          onCopy: () => _copyDialog(context, state, e.path),
          onRename: () => _renameDialog(context, state, e.path),
          onDelete: () => _deleteConfirm(context, state, e.path),
        );
      },
    );
  }

  void _openPreview(BuildContext context, String path) {
    Navigator.of(
      context,
    ).push(MaterialPageRoute<void>(builder: (_) => PreviewPage(remote: path)));
  }

  Future<void> _copyDialog(
    BuildContext context,
    AppState state,
    String source,
  ) async {
    // 预填「同目录 + _copy 后缀」，比让用户从零输入省事。
    final dot = source.lastIndexOf('.');
    final slash = source.lastIndexOf('/');
    final suggested = dot > slash
        ? '${source.substring(0, dot)}_copy${source.substring(dot)}'
        : '${source}_copy';

    final controller = TextEditingController(text: suggested);
    final target = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('复制到'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: '目标路径',
            helperText: '服务端本地复制，不消耗流量',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('复制'),
          ),
        ],
      ),
    );
    final trimmed = target?.trim() ?? '';
    controller.dispose();
    if (trimmed.isEmpty || trimmed == source) return;
    await state.copyFile(source, trimmed);
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

  /// 重命名与移动共用：改整条相对路径，换目录即移动。
  Future<void> _renameDialog(
    BuildContext context,
    AppState state,
    String path,
  ) async {
    final controller = TextEditingController(text: path);
    final next = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('重命名 / 移动'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: '新路径',
            helperText: '改目录即移动；目标已存在时不会覆盖',
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
    if (target.isEmpty || target == path) return;
    await state.renameFile(path, target);
  }
}

class _DirTile extends StatelessWidget {
  const _DirTile({required this.name, this.onTap, required this.onRename});

  final String name;
  final VoidCallback? onTap;
  final VoidCallback onRename;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return GlassCard(
      padding: const EdgeInsets.fromLTRB(14, 4, 4, 4),
      onTap: onTap,
      child: Row(
        children: [
          Icon(Icons.folder_rounded, color: scheme.primary),
          const SizedBox(width: 12),
          Expanded(
            child: SizedBox(
              height: 44,
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  name,
                  style: const TextStyle(fontWeight: FontWeight.w500),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
          ),
          IconButton(
            tooltip: '重命名 / 移动',
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.more_vert, size: 20),
            onPressed: onRename,
          ),
        ],
      ),
    );
  }
}

class _FileTile extends StatelessWidget {
  const _FileTile({
    required this.name,
    required this.size,
    required this.busy,
    required this.onPreview,
    required this.onDownload,
    required this.onCopy,
    required this.onRename,
    required this.onDelete,
  });

  final String name;
  final int size;
  final bool busy;
  final VoidCallback onPreview;
  final VoidCallback onDownload;
  final VoidCallback onCopy;
  final VoidCallback onRename;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return GlassCard(
      padding: const EdgeInsets.fromLTRB(14, 10, 4, 10),
      child: Row(
        children: [
          Icon(_iconFor(name), color: scheme.onSurfaceVariant),
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
                case 'preview':
                  onPreview();
                case 'download':
                  onDownload();
                case 'copy':
                  onCopy();
                case 'rename':
                  onRename();
                case 'delete':
                  onDelete();
              }
            },
            itemBuilder: (_) => const [
              PopupMenuItem(
                value: 'preview',
                child: ListTile(
                  dense: true,
                  leading: Icon(Icons.visibility_outlined),
                  title: Text('预览'),
                ),
              ),
              PopupMenuItem(
                value: 'download',
                child: ListTile(
                  dense: true,
                  leading: Icon(Icons.download),
                  title: Text('下载'),
                ),
              ),
              PopupMenuItem(
                value: 'copy',
                child: ListTile(
                  dense: true,
                  leading: Icon(Icons.copy_outlined),
                  title: Text('复制'),
                ),
              ),
              PopupMenuItem(
                value: 'rename',
                child: ListTile(
                  dense: true,
                  leading: Icon(Icons.drive_file_rename_outline),
                  title: Text('重命名 / 移动'),
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
    );
  }

  static IconData _iconFor(String name) {
    final ext = name.contains('.') ? name.split('.').last.toLowerCase() : '';
    if (const {
      'jpg',
      'jpeg',
      'png',
      'gif',
      'webp',
      'bmp',
      'heic',
    }.contains(ext)) {
      return Icons.image_outlined;
    }
    if (const {'mp4', 'mkv', 'mov', 'avi', 'webm'}.contains(ext)) {
      return Icons.movie_outlined;
    }
    if (const {'mp3', 'flac', 'wav', 'aac', 'm4a'}.contains(ext)) {
      return Icons.audiotrack_outlined;
    }
    if (const {'zip', 'rar', '7z', 'tar', 'gz'}.contains(ext)) {
      return Icons.folder_zip_outlined;
    }
    if (ext == 'pdf') return Icons.picture_as_pdf_outlined;
    if (const {
      'txt',
      'md',
      'json',
      'yaml',
      'yml',
      'log',
      'csv',
    }.contains(ext)) {
      return Icons.description_outlined;
    }
    return Icons.insert_drive_file_outlined;
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
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 10),
      child: Text(
        text,
        style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }
}
