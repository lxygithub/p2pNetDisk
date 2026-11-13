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

/// 条目类型（列表里目录与文件共用）。
typedef _Entry = ({String name, bool isDir, int size, String path});

/// 文件浏览页：面包屑 + 目录/文件列表 + 上传/新建目录/多选批量操作。
///
/// 交互约定：
/// - **点击文件 = 直接预览**（不再经过 ⋮ 菜单）
/// - **长按 = 进入多选**，此后点击变成勾选
/// - 点击目录始终是「进入」
class FilesPage extends StatefulWidget {
  const FilesPage({super.key});

  @override
  State<FilesPage> createState() => _FilesPageState();
}

class _FilesPageState extends State<FilesPage> {
  bool _selectionMode = false;
  final Set<String> _selected = <String>{};

  AppState get _state => context.read<AppState>();

  void _enterSelection(String path) {
    setState(() {
      _selectionMode = true;
      _selected.add(path);
    });
  }

  void _toggle(String path) {
    setState(() {
      if (!_selected.add(path)) {
        _selected.remove(path);
      }
      if (_selected.isEmpty) _selectionMode = false;
    });
  }

  void _exitSelection() {
    if (!_selectionMode && _selected.isEmpty) return;
    setState(() {
      _selectionMode = false;
      _selected.clear();
    });
  }

  void _selectAll(List<_Entry> entries) {
    setState(() {
      _selected
        ..clear()
        ..addAll(entries.where((e) => !e.isDir).map((e) => e.path));
    });
  }

  void _enterDir(String name) {
    _exitSelection();
    _state.enterDir(name);
  }

  void _openPreview(String path) {
    Navigator.of(
      context,
    ).push(MaterialPageRoute<void>(builder: (_) => PreviewPage(remote: path)));
  }

  /// 缓存列表在离线时也可见，但预览/下载/复制/删除都需要连上服务端。
  /// 统一在这里拦一道，别让「点了没反应」变成看不懂的底层报错。
  void _runOnline(VoidCallback action) {
    if (_state.connected) {
      action();
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('离线中，显示的是缓存列表；连上后再操作'),
        duration: Duration(seconds: 2),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = context.watch<AppState>();
    final entries = s.entries;

    // 切到别的目录后，之前勾选的路径已经不在视图里，顺手清理。
    if (_selectionMode && _selected.isNotEmpty) {
      final visible = entries.map((e) => e.path).toSet();
      if (_selected.any((p) => !visible.contains(p))) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          setState(() {
            _selected.removeWhere((p) => !visible.contains(p));
            if (_selected.isEmpty) _selectionMode = false;
          });
        });
      }
    }

    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: _selectionMode ? _selectionAppBar(entries) : _normalAppBar(s),
      body: Column(
        children: [
          if (!_selectionMode) const Breadcrumb(),
          if (!_selectionMode && s.showingCache)
            _CacheBanner(savedAt: s.cacheTime, refreshing: s.busy),
          Expanded(
            child: _FileList(
              state: s,
              selectionMode: _selectionMode,
              selected: _selected,
              onToggle: _toggle,
              onLongPress: _enterSelection,
              // 目录导航是纯本地过滤，离线也可用；其余操作要走网络。
              onEnterDir: _enterDir,
              onPreview: (path) => _runOnline(() => _openPreview(path)),
              onCopy: (path) => _runOnline(() => _copyDialog(path)),
              onRename: (path) => _runOnline(() => _renameDialog(path)),
              onDelete: (path) => _runOnline(() => _deleteConfirm(path)),
              onDownload: (entry) =>
                  _runOnline(() => s.enqueueDownload(entry.path, entry.size)),
            ),
          ),
          if (!_selectionMode) _StatusBar(text: s.status),
        ],
      ),
      bottomNavigationBar: _selectionMode
          ? _selectionBar(context, entries, s.connected)
          : null,
      floatingActionButton: (!_selectionMode && s.connected)
          ? FloatingActionButton.extended(
              onPressed: s.busy ? null : _pickAndUpload,
              icon: const Icon(Icons.upload_file),
              label: const Text('上传'),
            )
          : null,
    );
  }

  AppBar _normalAppBar(AppState s) {
    return AppBar(
      title: const Text('p2pNetDisk'),
      actions: [
        if (s.pathSummary != null) PathChip(text: s.pathSummary!),
        IconButton(
          tooltip: '新建目录',
          onPressed: s.busy || !s.connected ? null : _newDir,
          icon: const Icon(Icons.create_new_folder_outlined),
        ),
        IconButton(
          tooltip: '刷新',
          onPressed: s.busy || !s.connected ? null : () => s.refresh(),
          icon: const Icon(Icons.refresh),
        ),
      ],
    );
  }

  AppBar _selectionAppBar(List<_Entry> entries) {
    final selectable = entries.where((e) => !e.isDir).length;
    return AppBar(
      leading: IconButton(
        tooltip: '退出多选',
        icon: const Icon(Icons.close),
        onPressed: _exitSelection,
      ),
      title: Text('已选 ${_selected.length} 项'),
      actions: [
        IconButton(
          tooltip: '全选',
          icon: const Icon(Icons.select_all),
          onPressed: selectable == 0 ? null : () => _selectAll(entries),
        ),
      ],
    );
  }

  Widget _selectionBar(
    BuildContext context,
    List<_Entry> entries,
    bool online,
  ) {
    final files = _selectedFiles(entries);

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
        child: GlassCard(
          blur: 16,
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
          child: Row(
            children: [
              _SelectionAction(
                icon: Icons.download,
                label: '下载',
                enabled: files.isNotEmpty && online,
                onTap: () => _batchDownload(files),
              ),
              _SelectionAction(
                icon: Icons.copy_outlined,
                label: '复制',
                enabled: files.isNotEmpty && online,
                onTap: () => _batchCopy(files),
              ),
              _SelectionAction(
                icon: Icons.drive_file_move_outline,
                label: '移动',
                enabled: files.isNotEmpty && online,
                onTap: () => _batchMove(files),
              ),
              _SelectionAction(
                icon: Icons.delete_outline,
                label: '删除',
                enabled: files.isNotEmpty && online,
                onTap: () => _batchDelete(files),
              ),
            ],
          ),
        ),
      ),
    );
  }

  List<_Entry> _selectedFiles(List<_Entry> entries) => entries
      .where((e) => !e.isDir && _selected.contains(e.path))
      .toList(growable: false);

  // ---------------------------------------------------------------------------
  // 批量操作
  // ---------------------------------------------------------------------------

  Future<void> _batchDownload(List<_Entry> files) async {
    final items = [for (final f in files) (path: f.path, size: f.size)];
    _exitSelection();
    await _state.enqueueDownloads(items);
  }

  Future<void> _batchDelete(List<_Entry> files) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('删除 ${files.length} 个文件'),
        content: const Text('会移入服务端回收站，不会立即物理删除。'),
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
    if (ok != true) return;
    final paths = [for (final f in files) f.path];
    _exitSelection();
    await _state.deleteMany(paths);
  }

  Future<void> _batchCopy(List<_Entry> files) async {
    final dir = await _askTargetDir('批量复制', '复制到哪个目录？');
    if (dir == null) return;
    final paths = [for (final f in files) f.path];
    _exitSelection();
    await _state.copyMany(paths, dir);
  }

  Future<void> _batchMove(List<_Entry> files) async {
    final dir = await _askTargetDir('批量移动', '移动到哪个目录？');
    if (dir == null) return;
    final paths = [for (final f in files) f.path];
    _exitSelection();
    await _state.moveMany(paths, dir);
  }

  /// 目标目录输入框。留空表示根目录；刻意不预填当前目录，
  /// 否则同一目录内复制/移动会立刻撞上「目标已存在」。
  Future<String?> _askTargetDir(String title, String hint) async {
    final controller = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: InputDecoration(
            labelText: '目标目录',
            helperText: '$hint（留空 = 根目录）',
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
    controller.dispose();
    return result;
  }

  // ---------------------------------------------------------------------------
  // 单个操作
  // ---------------------------------------------------------------------------

  Future<void> _pickAndUpload() async {
    final state = _state;

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
      final size = f.lengthSync() ?? await f.length() ?? 0;
      files.add((name: f.name, path: path, size: size));
    }
    if (files.isEmpty) {
      state.setStatus('拿不到文件路径（部分平台只给流）');
      return;
    }
    await state.enqueueUploads(files);
  }

  Future<void> _newDir() async {
    final state = _state;
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

  Future<void> _copyDialog(String source) async {
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
    await _state.copyFile(source, trimmed);
  }

  Future<void> _deleteConfirm(String path) async {
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
    if (ok == true) await _state.deleteFile(path);
  }

  Future<void> _renameDialog(String path) async {
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
    await _state.renameFile(path, target);
  }
}

class _SelectionAction extends StatelessWidget {
  const _SelectionAction({
    required this.icon,
    required this.label,
    required this.enabled,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = enabled ? scheme.onSurface : scheme.outline;

    return Expanded(
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: enabled ? onTap : null,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 20, color: color),
              const SizedBox(height: 2),
              Text(label, style: TextStyle(fontSize: 11, color: color)),
            ],
          ),
        ),
      ),
    );
  }
}

class _FileList extends StatelessWidget {
  const _FileList({
    required this.state,
    required this.selectionMode,
    required this.selected,
    required this.onToggle,
    required this.onLongPress,
    required this.onEnterDir,
    required this.onPreview,
    required this.onCopy,
    required this.onRename,
    required this.onDelete,
    required this.onDownload,
  });

  final AppState state;
  final bool selectionMode;
  final Set<String> selected;
  final void Function(String path) onToggle;
  final void Function(String path) onLongPress;
  final void Function(String name) onEnterDir;
  final void Function(String path) onPreview;
  final void Function(String path) onCopy;
  final void Function(String path) onRename;
  final void Function(String path) onDelete;
  final void Function(_Entry entry) onDownload;

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
    // 有缓存快照时即使还没连上，也把列表渲染出来（配合顶部缓存提示条）。
    if (!state.connected && !state.showingCache) {
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
      // 正在拉列表时的占位骨架，别先闪一句「还没有文件」再跳成真实列表。
      if (state.busy && state.connected) return const _SkeletonList();
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
            onTap: state.busy ? null : () => onEnterDir(e.name),
            onRename: () => onRename(e.path),
          );
        }

        return _FileTile(
          name: e.name,
          size: e.size,
          busy: state.busy,
          selectionMode: selectionMode,
          selected: selected.contains(e.path),
          // 点击 = 预览；多选态下点击 = 勾选
          onTap: selectionMode
              ? () => onToggle(e.path)
              : () => onPreview(e.path),
          onLongPress: () => onLongPress(e.path),
          onDownload: () => onDownload(e),
          onCopy: () => onCopy(e.path),
          onRename: () => onRename(e.path),
          onDelete: () => onDelete(e.path),
        );
      },
    );
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
    required this.selectionMode,
    required this.selected,
    required this.onTap,
    required this.onLongPress,
    required this.onDownload,
    required this.onCopy,
    required this.onRename,
    required this.onDelete,
  });

  final String name;
  final int size;
  final bool busy;
  final bool selectionMode;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  final VoidCallback onDownload;
  final VoidCallback onCopy;
  final VoidCallback onRename;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return GestureDetector(
      onTap: onTap,
      onLongPress: busy ? null : onLongPress,
      child: GlassCard(
        blur: 0,
        padding: EdgeInsets.fromLTRB(selectionMode ? 4 : 14, 10, 4, 10),
        child: Row(
          children: [
            if (selectionMode)
              Checkbox(
                value: selected,
                onChanged: (_) => onTap(),
                visualDensity: VisualDensity.compact,
              )
            else
              Padding(
                padding: const EdgeInsets.only(right: 12),
                child: Icon(_iconFor(name), color: scheme.onSurfaceVariant),
              ),
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
            if (!selectionMode)
              PopupMenuButton<String>(
                enabled: !busy,
                tooltip: '更多操作',
                icon: const Icon(Icons.more_vert, size: 20),
                onSelected: (v) {
                  switch (v) {
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

/// 首屏显示本地缓存时的提示条：说明数据可能过期，同时给出「正在刷新」反馈。
class _CacheBanner extends StatelessWidget {
  const _CacheBanner({required this.savedAt, required this.refreshing});

  final DateTime? savedAt;
  final bool refreshing;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final t = savedAt;
    final stamp = t == null
        ? ''
        : ' · ${t.hour.toString().padLeft(2, '0')}:'
            '${t.minute.toString().padLeft(2, '0')}';
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: scheme.secondaryContainer.withValues(alpha: 0.45),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            Icon(Icons.history, size: 16, color: scheme.onSurfaceVariant),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                refreshing
                    ? '上次列表$stamp，正在刷新…'
                    : '上次列表$stamp · 离线，下拉可重试',
                style: TextStyle(
                  fontSize: 12,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
            if (refreshing)
              const SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
          ],
        ),
      ),
    );
  }
}

/// 首屏还没拿到列表时的占位骨架，避免空白页跳变与「还没有文件」的误判。
class _SkeletonList extends StatelessWidget {
  const _SkeletonList();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListView.separated(
      physics: const NeverScrollableScrollPhysics(),
      padding: kPagePadding,
      itemCount: 6,
      separatorBuilder: (_, _) => const SizedBox(height: 8),
      itemBuilder: (context, i) => Container(
        height: 68,
        decoration: BoxDecoration(
          color: scheme.onSurface.withValues(alpha: 0.07),
          borderRadius: BorderRadius.circular(16),
        ),
      ),
    );
  }
}
