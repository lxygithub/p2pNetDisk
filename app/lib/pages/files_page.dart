import 'dart:async';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/transfer_task.dart';
import '../state/app_state.dart';
import '../theme.dart';
import '../widgets/breadcrumb.dart';
import '../widgets/directory_picker.dart';
import '../widgets/glass.dart';
import '../widgets/path_chip.dart';
import '../widgets/text_input_dialog.dart';
import 'preview_page.dart';
import 'search_page.dart';

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

/// 把 `a/b/c.txt` 拆成 (`a/b/`, `c.txt`)；目录带尾斜杠也能正确处理。
(String, String) _splitPath(String path) {
  final clean = path.endsWith('/') ? path.substring(0, path.length - 1) : path;
  final slash = clean.lastIndexOf('/');
  final dir = slash >= 0 ? clean.substring(0, slash + 1) : '';
  return (dir, clean.substring(dir.length));
}

class _FilesPageState extends State<FilesPage> {
  /// 每页条数。列表一次只渲染这么多，触底再追加，目录很大时也不卡。
  static const int _pageSize = 50;

  bool _selectionMode = false;
  final Set<String> _selected = <String>{};

  /// 当前已加载的条数（分页）。
  int _visible = _pageSize;

  /// 上一次渲染的目录，用于在切换目录时把分页重置回第一页。
  String? _lastCwd;

  AppState get _state => context.read<AppState>();

  /// 触底追加一页。
  void _growVisible(int total) {
    if (_visible >= total) return;
    final next = _visible + _pageSize;
    setState(() => _visible = next > total ? total : next);
  }

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
        // 目录也能入选：批量下载需要支持「整个目录」。复制/移动/删除
        // 仍只会作用于其中的文件（服务端 Delete 不接受目录）。
        ..addAll(entries.map((e) => e.path));
    });
  }

  void _enterDir(String name) {
    _exitSelection();
    _state.enterDir(name);
  }

  /// 全盘搜索：点目录跳过去，点文件先切到它所在目录再预览
  /// （这样预览页能拿到同目录的图片列表，可以左右滑动）。
  Future<void> _openSearch() async {
    final hit = await Navigator.of(
      context,
    ).push<SearchHit>(MaterialPageRoute(builder: (_) => const SearchPage()));
    if (hit == null || !mounted) return;

    if (hit.isDir) {
      _state.jumpTo(hit.path);
      return;
    }
    final dir = _splitPath(hit.path).$1;
    if (dir != _state.cwd) _state.jumpTo(dir);
    _openPreview(hit.path);
  }

  /// 同目录下的图片一起传给预览页，支持左右滑动连续看。
  void _openPreview(String path) {
    final images = [
      for (final e in _state.entries)
        if (!e.isDir && _FileTile._iconFor(e.name) == Icons.image_outlined)
          e.path,
    ];
    final index = images.indexOf(path);
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => PreviewPage(
          remote: path,
          gallery: index >= 0 ? images : const <String>[],
          initialIndex: index >= 0 ? index : 0,
        ),
      ),
    );
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

    // 切目录后分页回到第一页（直接改字段，不额外 setState —— 这次 build 就会用新值）。
    if (_lastCwd != s.cwd) {
      _lastCwd = s.cwd;
      _visible = _pageSize;
    }

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
            child: NotificationListener<ScrollNotification>(
              onNotification: (n) {
                // 距底部 240px 时追加一页，滚动过程中无感。
                if (n.metrics.pixels >= n.metrics.maxScrollExtent - 240) {
                  _growVisible(entries.length);
                }
                return false;
              },
              child: _FileList(
                state: s,
                selectionMode: _selectionMode,
                selected: _selected,
                visible: _visible,
                onToggle: _toggle,
                onLongPress: _enterSelection,
                // 目录导航是纯本地过滤，离线也可用；其余操作要走网络。
                onEnterDir: _enterDir,
                onPreview: (path) => _runOnline(() => _openPreview(path)),
                onCopy: (path) => _runOnline(() => _copyDialog(path)),
                onRename: (path) => _runOnline(() => _renameDialog(path)),
                onDelete: (path) => _runOnline(() => _deleteConfirm(path)),
                onDownload: (entry) => _runOnline(() => _startDownload(entry)),
                onDownloadDir: (entry) =>
                    _runOnline(() => _startDirDownload(entry)),
              ),
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
              onPressed: s.busy ? null : _showUploadMenu,
              icon: const Icon(Icons.add),
              label: const Text('上传'),
            )
          : null,
    );
  }

  AppBar _normalAppBar(AppState s) {
    return AppBar(
      title: const Text('p2pNetDisk'),
      actions: [
        IconButton(
          tooltip: '搜索',
          icon: const Icon(Icons.search),
          onPressed: s.busy ? null : _openSearch,
        ),
        if (s.connected && s.pathSummary != null)
          PathChip(text: s.pathSummary!, latencyMs: s.pathLatencyMs)
        else if (!s.connected)
          OfflineChip(onTap: s.busy ? null : s.connect),
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
    final allSelected =
        entries.isNotEmpty && entries.every((e) => _selected.contains(e.path));

    return AppBar(
      leading: IconButton(
        tooltip: '退出多选',
        icon: const Icon(Icons.close),
        onPressed: _exitSelection,
      ),
      title: Text('已选 ${_selected.length} 项'),
      actions: [
        IconButton(
          // 全选之后变成「取消全选」：之前只能退出多选再重进，很别扭。
          tooltip: allSelected ? '取消全选' : '全选',
          icon: Icon(allSelected ? Icons.deselect : Icons.select_all),
          onPressed: entries.isEmpty
              ? null
              : allSelected
              ? _exitSelection
              : () => _selectAll(entries),
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
    final dirs = _selectedDirs(entries);

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
                // 目录可以整棵下载，所以这里不能只数文件。
                enabled: (files.isNotEmpty || dirs.isNotEmpty) && online,
                onTap: () => _batchDownload(entries),
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
                // rename 对文件和目录都有效。
                enabled: (files.isNotEmpty || dirs.isNotEmpty) && online,
                onTap: () => _batchMove(entries),
              ),
              _SelectionAction(
                icon: Icons.delete_outline,
                label: '删除',
                // 目录也能删（里面的文件进回收站，空壳随后移除）。
                enabled: (files.isNotEmpty || dirs.isNotEmpty) && online,
                onTap: () => _batchDelete(entries),
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

  List<_Entry> _selectedDirs(List<_Entry> entries) => entries
      .where((e) => e.isDir && _selected.contains(e.path))
      .toList(growable: false);

  // ---------------------------------------------------------------------------
  // 批量操作
  // ---------------------------------------------------------------------------

  Future<void> _batchDownload(List<_Entry> entries) async {
    final selected = entries
        .where((e) => _selected.contains(e.path))
        .toList(growable: false);
    final items = [
      for (final e in selected)
        if (!e.isDir) (path: e.path, size: e.size),
    ];
    final dirs = [
      for (final e in selected)
        if (e.isDir) e.path,
    ];
    _exitSelection();

    // 文件平铺到下载根目录（保持原有行为），目录保持各自的相对结构。
    if (items.isNotEmpty) await _state.enqueueDownloads(items);
    for (final dir in dirs) {
      await _state.enqueueDirectoryDownload(dir);
    }
    _toastSaved();
  }

  Future<void> _batchDelete(List<_Entry> entries) async {
    final selected = entries
        .where((e) => _selected.contains(e.path))
        .toList(growable: false);
    if (selected.isEmpty) return;

    final fileCount = selected.where((e) => !e.isDir).length;
    final dirCount = selected.length - fileCount;
    final what = [
      if (fileCount > 0) '$fileCount 个文件',
      if (dirCount > 0) '$dirCount 个文件夹（含其中所有文件）',
    ].join('、');

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('删除 $what'),
        content: const Text('会移入服务端回收站，不会立即物理删除；文件夹的空壳会被移除。'),
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
    if (!mounted) return;
    final paths = [for (final e in selected) e.path];
    _exitSelection();
    await _state.deleteMany(paths);
  }

  Future<void> _batchCopy(List<_Entry> files) async {
    final dir = await showDirectoryPicker(context, state: _state, title: '复制到');
    if (dir == null || !mounted) return;
    final paths = [for (final f in files) f.path];
    _exitSelection();
    await _state.copyMany(paths, dir);
  }

  /// 批量移动。选中项里可能同时有文件和文件夹 —— 服务端的 rename 两者都支持，
  /// 所以这里不再只挑文件。
  Future<void> _batchMove(List<_Entry> entries) async {
    final selected = entries
        .where((e) => _selected.contains(e.path))
        .toList(growable: false);
    if (selected.isEmpty) return;

    final dir = await showDirectoryPicker(context, state: _state, title: '移动到');
    if (dir == null || !mounted) return;
    // 目录路径在列表里带尾斜杠，rename 时去掉更干净。
    final paths = [
      for (final e in selected)
        e.path.endsWith('/') ? e.path.substring(0, e.path.length - 1) : e.path,
    ];
    _exitSelection();
    await _state.moveMany(paths, dir);
  }

  // ---------------------------------------------------------------------------
  // 单个操作
  // ---------------------------------------------------------------------------

  /// 下载完成后把保存位置提示出来 —— 用户在 Android 上很难自己找到
  /// `Android/data/<包名>/files` 这种目录，不提示等于「下载了但不知道在哪」。
  void _toastSaved() {
    if (!mounted) return;
    final root = _state.downloadRoot;
    if (root.isEmpty) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('保存到 $root'),
        duration: const Duration(seconds: 3),
      ),
    );
  }

  Future<void> _startDownload(_Entry entry) async {
    await _state.enqueueDownload(entry.path, entry.size);
    _toastSaved();
  }

  Future<void> _startDirDownload(_Entry entry) async {
    await _state.enqueueDirectoryDownload(entry.path);
    _toastSaved();
  }

  /// 上传入口菜单：文件 / 文件夹分开，避免把「选文件夹」藏进多选逻辑里。
  Future<void> _showUploadMenu() async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.upload_file),
              title: const Text('上传文件'),
              subtitle: const Text('可一次选多个'),
              onTap: () => Navigator.pop(ctx, 'files'),
            ),
            ListTile(
              leading: const Icon(Icons.drive_folder_upload),
              title: const Text('上传文件夹'),
              subtitle: const Text('保持目录结构；隐藏文件会跳过'),
              onTap: () => Navigator.pop(ctx, 'dir'),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (!mounted) return;
    if (choice == 'files') {
      await _pickAndUpload();
    } else if (choice == 'dir') {
      await _pickAndUploadDir();
    }
  }

  Future<void> _pickAndUploadDir() async {
    final state = _state;
    String? dir;
    try {
      dir = await FilePicker.getDirectoryPath(dialogTitle: '选择要上传的文件夹');
    } catch (e) {
      state.setStatus('打开目录选择器失败: $e');
      return;
    }
    if (dir == null || dir.isEmpty) return;
    await state.enqueueDirectoryUpload(dir);
  }

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
    final name = await showTextInputDialog(
      context,
      title: '新建目录',
      label: '目录名',
      helper: '可带子路径，例如 photos/2026',
      initial: '新文件夹',
      confirmLabel: '创建',
    );
    final trimmed = name?.trim() ?? '';
    if (trimmed.isEmpty || !mounted) return;
    await _state.createDir(trimmed);
  }

  Future<void> _copyDialog(String source) async {
    final dot = source.lastIndexOf('.');
    final slash = source.lastIndexOf('/');
    final suggested = dot > slash
        ? '${source.substring(0, dot)}_copy${source.substring(dot)}'
        : '${source}_copy';

    final target = await showTextInputDialog(
      context,
      title: '复制到',
      label: '目标路径',
      helper: '服务端本地复制，不消耗流量',
      initial: suggested,
      confirmLabel: '复制',
    );
    final trimmed = target?.trim() ?? '';
    if (trimmed.isEmpty || trimmed == source || !mounted) return;
    await _state.copyFile(source, trimmed);
  }

  Future<void> _deleteConfirm(String path) async {
    final isDir =
        path.endsWith('/') ||
        _state.files.any((e) => e.path == path && e.isDir);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(isDir ? '删除文件夹' : '删除文件'),
        content: Text(
          isDir
              ? '$path\n\n整个文件夹会移入服务端回收站，可以整体恢复。'
              : '$path\n\n会移入服务端回收站，不会立即物理删除。',
        ),
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
    if (ok != true || !mounted) return;
    await _state.deleteMany([path]);
  }

  /// 重命名：只改最后一段名字，路径保持不变（要换目录用批量移动）。
  Future<void> _renameDialog(String path) async {
    final (dir, name) = _splitPath(path);
    final next = await showTextInputDialog(
      context,
      title: '重命名',
      label: '新名称',
      helper: dir.isEmpty ? '位于根目录' : '位于 $dir',
      initial: name,
    );
    final trimmed = next?.trim() ?? '';
    if (trimmed.isEmpty || trimmed == name || !mounted) return;
    // from 用去掉尾斜杠的干净路径：目录带 `/` 时 rename 更稳妥。
    await _state.renameFile('$dir$name', '$dir$trimmed');
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
    required this.onDownloadDir,
    required this.visible,
  });

  final AppState state;
  final bool selectionMode;
  final Set<String> selected;

  /// 当前分页已加载的条数（列表只渲染前 [visible] 项）。
  final int visible;
  final void Function(String path) onToggle;
  final void Function(String path) onLongPress;
  final void Function(String name) onEnterDir;
  final void Function(String path) onPreview;
  final void Function(String path) onCopy;
  final void Function(String path) onRename;
  final void Function(String path) onDelete;
  final void Function(_Entry entry) onDownload;
  final void Function(_Entry entry) onDownloadDir;

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
      itemCount: entries.length > visible ? visible : entries.length,
      separatorBuilder: (_, _) => const SizedBox(height: 8),
      itemBuilder: (context, i) {
        final e = entries[i];

        if (e.isDir) {
          return _DirTile(
            name: e.name,
            onTap: state.busy ? null : () => onEnterDir(e.name),
            onRename: () => onRename(e.path),
            onDownload: () => onDownloadDir(e),
            onDelete: () => onDelete(e.path),
            onToggle: () => onToggle(e.path),
            onLongPress: () => onLongPress(e.path),
            selectionMode: selectionMode,
            selected: selected.contains(e.path),
          );
        }

        return _FileTile(
          name: e.name,
          path: e.path,
          size: e.size,
          state: state,
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
  const _DirTile({
    required this.name,
    this.onTap,
    required this.onRename,
    required this.onDownload,
    required this.onDelete,
    required this.onToggle,
    required this.onLongPress,
    this.selectionMode = false,
    this.selected = false,
  });

  final String name;
  final VoidCallback? onTap;
  final VoidCallback onRename;
  final VoidCallback onDownload;
  final VoidCallback onDelete;
  final VoidCallback onToggle;
  final VoidCallback onLongPress;
  final bool selectionMode;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return GestureDetector(
      // 长按进多选；多选态下点击是勾选，不再是「进入目录」。
      onLongPress: onLongPress,
      onTap: selectionMode ? onToggle : onTap,
      child: GlassCard(
        padding: EdgeInsets.fromLTRB(selectionMode ? 4 : 14, 4, 4, 4),
        child: Row(
          children: [
            if (selectionMode)
              Checkbox(value: selected, onChanged: (_) => onToggle())
            else
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
            // 多选态隐藏菜单：此时整行都是勾选目标，避免误触。
            if (!selectionMode)
              PopupMenuButton<String>(
                tooltip: '更多',
                icon: const Icon(Icons.more_vert, size: 20),
                onSelected: (value) {
                  switch (value) {
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
                    child: Row(
                      children: [
                        Icon(Icons.download, size: 20),
                        SizedBox(width: 12),
                        Text('下载整个目录'),
                      ],
                    ),
                  ),
                  PopupMenuItem(
                    value: 'rename',
                    child: Row(
                      children: [
                        Icon(Icons.drive_file_rename_outline, size: 20),
                        SizedBox(width: 12),
                        Text('重命名'),
                      ],
                    ),
                  ),
                  PopupMenuItem(
                    value: 'delete',
                    child: Row(
                      children: [
                        Icon(Icons.delete_outline, size: 20),
                        SizedBox(width: 12),
                        Text('删除文件夹'),
                      ],
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

class _FileTile extends StatelessWidget {
  const _FileTile({
    required this.name,
    required this.path,
    required this.size,
    required this.state,
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
  final String path;
  final int size;
  final AppState state;
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
                padding: const EdgeInsets.only(right: 10),
                child: _FileThumb(
                  state: state,
                  path: path,
                  name: name,
                  size: size,
                ),
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

/// 文件列表左侧的缩略图：图片取远端缩略图，其他类型显示类型图标。
///
/// 缩略图下载失败/过大时静默回退成图标 —— 列表本身不该因为一张图加载不出来
/// 而变慢或报错。
class _FileThumb extends StatelessWidget {
  const _FileThumb({
    required this.state,
    required this.path,
    required this.name,
    required this.size,
  });

  final AppState state;
  final String path;
  final String name;
  final int size;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final fallback = Icon(
      _FileTile._iconFor(name),
      color: scheme.onSurfaceVariant,
    );

    final isImage = _FileTile._iconFor(name) == Icons.image_outlined;
    if (!isImage || size <= 0) {
      return SizedBox(width: 32, height: 32, child: Center(child: fallback));
    }

    return SizedBox(
      width: 40,
      height: 40,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: FutureBuilder<Uint8List?>(
          future: state.thumbnail(path, size),
          builder: (context, snap) {
            final bytes = snap.data;
            if (bytes == null) {
              return Container(
                color: scheme.surfaceContainerHighest,
                child: Icon(
                  Icons.image_outlined,
                  size: 18,
                  color: scheme.onSurfaceVariant,
                ),
              );
            }
            return Image.memory(
              bytes,
              fit: BoxFit.cover,
              // 列表里最多显示 40dp，按 96px 解码足够，省内存也省解码时间。
              cacheWidth: 96,
              gaplessPlayback: true,
              errorBuilder: (_, _, _) => Center(child: fallback),
            );
          },
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
                refreshing ? '上次列表$stamp，正在刷新…' : '上次列表$stamp · 离线，下拉可重试',
                style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
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
