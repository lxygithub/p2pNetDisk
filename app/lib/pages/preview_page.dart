import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/transfer_task.dart';
import '../state/app_state.dart';
import '../widgets/glass.dart';
import '../widgets/text_input_dialog.dart';
import '../widgets/app_icons.dart';

/// 文件预览。
///
/// - 图片：同目录下的图片支持左右滑动连续预览；单页双指缩放 / 双击放大。
/// - 文本：只读前 200 KB。
/// - 其他：不下载，直接提示。
///
/// 顶部提供下载 / 重命名 / 删除 —— 看完一张图想改个名字不用退回列表。
class PreviewPage extends StatefulWidget {
  const PreviewPage({
    super.key,
    required this.remote,
    this.gallery = const [],
    this.initialIndex = 0,
  });

  final String remote;

  /// 同目录下的图片路径（含 [remote]）。为空表示只预览单文件。
  final List<String> gallery;
  final int initialIndex;

  @override
  State<PreviewPage> createState() => _PreviewPageState();
}

class _PreviewPageState extends State<PreviewPage> {
  static const _imageExts = {
    'jpg',
    'jpeg',
    'png',
    'gif',
    'webp',
    'bmp',
    'heic',
  };
  static const _textExts = {
    'txt',
    'md',
    'json',
    'yaml',
    'yml',
    'log',
    'csv',
    'xml',
    'ini',
    'conf',
  };

  late final List<String> _images = widget.gallery.isEmpty
      ? <String>[widget.remote]
      : [...widget.gallery];

  late int _page = widget.gallery.isEmpty
      ? 0
      : widget.initialIndex.clamp(0, widget.gallery.length - 1);

  late final PageController _controller = PageController(initialPage: _page);

  // 非图片（文本）单页预览的状态
  String? _textPath;
  String? _textError;
  bool _textLoading = true;

  String get _current => _images[_page];

  String get _ext {
    final name = _current.split('/').last;
    return name.contains('.') ? name.split('.').last.toLowerCase() : '';
  }

  bool get _isImage => _imageExts.contains(_ext);
  bool get _isGallery => _images.length > 1;
  bool get _supported => _isImage || _textExts.contains(_ext);

  @override
  void initState() {
    super.initState();
    if (!_isImage) _loadText();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _loadText() async {
    try {
      final local = await context.read<AppState>().downloadForPreview(
        widget.remote,
      );
      if (!mounted) return;
      setState(() {
        _textPath = local;
        _textLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _textError = '$e';
        _textLoading = false;
      });
    }
  }

  // ---------------------------------------------------------------------------
  // 文件操作
  // ---------------------------------------------------------------------------

  int _sizeOf(String path) {
    for (final f in context.read<AppState>().files) {
      if (f.path == path) return f.size;
    }
    return 0;
  }

  void _toast(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 2)),
    );
  }

  Future<void> _download() async {
    final state = context.read<AppState>();
    final path = _current;
    await state.enqueueDownload(path, _sizeOf(path));
    if (!mounted) return;
    _toast('已加入下载队列');
  }

  /// 拆出「所在目录 + 文件名」：重命名只改名字，不逼用户重输整个路径。
  (String, String) _split(String path) {
    final clean = path.endsWith('/')
        ? path.substring(0, path.length - 1)
        : path;
    final slash = clean.lastIndexOf('/');
    final dir = slash >= 0 ? clean.substring(0, slash + 1) : '';
    return (dir, clean.substring(dir.length));
  }

  Future<void> _rename() async {
    final path = _current;
    final (dir, name) = _split(path);
    final next = await showTextInputDialog(
      context,
      title: '重命名',
      label: '新名称',
      helper: dir.isEmpty ? '位于根目录' : '位于 $dir',
      initial: name,
    );
    final trimmed = next?.trim() ?? '';
    if (trimmed.isEmpty || trimmed == name || !mounted) return;

    final target = '$dir$trimmed';
    await context.read<AppState>().renameFile(path, target);
    if (!mounted) return;
    setState(() => _images[_page] = target);
  }

  Future<void> _delete() async {
    final path = _current;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除'),
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
    if (ok != true || !mounted) return;
    await context.read<AppState>().deleteMany([path]);
    if (!mounted) return;
    Navigator.pop(context);
  }

  void _onAction(String action) {
    switch (action) {
      case 'rename':
        unawaited(_rename());
      case 'delete':
        unawaited(_delete());
    }
  }

  // ---------------------------------------------------------------------------
  // UI
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final name = _current.split('/').last;
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        title: Text(
          _isGallery ? '${_page + 1}/${_images.length} · $name' : name,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          IconButton(
            tooltip: '下载',
            icon: const AppIconView(AppIcons.download_outlined),
            onPressed: () => unawaited(_download()),
          ),
          PopupMenuButton<String>(
            tooltip: '更多操作',
            icon: const AppIconView(AppIcons.more_vert),
            onSelected: _onAction,
            itemBuilder: (_) => const [
              PopupMenuItem(
                value: 'rename',
                child: ListTile(
                  dense: true,
                  leading: AppIconView(AppIcons.drive_file_rename_outline),
                  title: Text('重命名'),
                ),
              ),
              PopupMenuItem(
                value: 'delete',
                child: ListTile(
                  dense: true,
                  leading: AppIconView(AppIcons.delete_outline),
                  title: Text('删除'),
                ),
              ),
            ],
          ),
        ],
      ),
      body: Padding(padding: const EdgeInsets.all(16), child: _body()),
    );
  }

  Widget _body() {
    if (_isImage) {
      return Stack(
        children: [
          Positioned.fill(
            child: PageView.builder(
              controller: _controller,
              itemCount: _images.length,
              onPageChanged: (i) => setState(() => _page = i),
              itemBuilder: (context, i) =>
                  _ZoomableImage(key: ValueKey(_images[i]), remote: _images[i]),
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: Center(child: _hint()),
          ),
        ],
      );
    }

    if (!_supported) {
      return Center(
        child: GlassCard(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              AppIconView(
                AppIcons.insert_drive_file_outlined,
                size: 44,
                color: Theme.of(context).colorScheme.outline,
              ),
              const SizedBox(height: 10),
              Text(_ext.isEmpty ? '该文件没有扩展名，无法判断类型' : '暂不支持预览 .$_ext 类型'),
              const SizedBox(height: 4),
              Text(
                '可以下载后用其他应用打开',
                style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      );
    }

    if (_textLoading) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 12),
            const Text('正在下载以预览…', style: TextStyle(fontSize: 13)),
            const SizedBox(height: 4),
            Text(
              '服务端无响应时会自动提示，不会一直转圈',
              style: TextStyle(
                fontSize: 11,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      );
    }
    if (_textError != null) {
      return _errorView(
        _textError!,
        onRetry: () {
          setState(() {
            _textError = null;
            _textLoading = true;
          });
          _loadText();
        },
      );
    }
    return FutureBuilder<String>(
      future: _readText(_textPath!),
      builder: (context, snap) {
        if (!snap.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        return GlassCard(
          blur: 10,
          padding: const EdgeInsets.all(16),
          child: SingleChildScrollView(
            child: SelectableText(
              snap.data!,
              style: const TextStyle(fontSize: 13, height: 1.55),
            ),
          ),
        );
      },
    );
  }

  Widget _hint() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.black54,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        _isGallery ? '左右滑动切换 · 双指缩放 · 双击放大' : '双指缩放 · 双击放大 / 还原',
        style: const TextStyle(fontSize: 11, color: Colors.white70),
      ),
    );
  }

  Widget _errorView(String message, {required VoidCallback onRetry}) {
    return Center(
      child: GlassCard(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            AppIconView(
              AppIcons.error_outline,
              color: Theme.of(context).colorScheme.error,
            ),
            const SizedBox(height: 8),
            Text(message, textAlign: TextAlign.center),
            const SizedBox(height: 14),
            FilledButton.icon(
              onPressed: onRetry,
              icon: const AppIconView(AppIcons.refresh, size: 18),
              label: const Text('重试'),
            ),
          ],
        ),
      ),
    );
  }

  /// 只读前 200 KB —— 大日志文件全量读进来会把内存吃满。
  Future<String> _readText(String path) async {
    const limit = 200 * 1024;
    final file = File(path);
    final len = await file.length();
    final take = len < limit ? len : limit;
    final builder = BytesBuilder(copy: false);
    await for (final chunk in file.openRead(0, take)) {
      builder.add(chunk);
    }
    final text = utf8.decode(builder.takeBytes(), allowMalformed: true);
    return len > limit
        ? '$text\n\n…（已截断，仅显示前 ${humanSize(limit)}，共 ${humanSize(len)}）'
        : text;
  }
}

/// 单张可缩放图片。
///
/// 关键点：`panEnabled` 只在放大后打开 —— 未放大时把水平拖动让给外层
/// `PageView`，否则两者抢手势，左右滑动切图会失效。
class _ZoomableImage extends StatefulWidget {
  const _ZoomableImage({super.key, required this.remote});

  final String remote;

  @override
  State<_ZoomableImage> createState() => _ZoomableImageState();
}

class _ZoomableImageState extends State<_ZoomableImage> {
  final TransformationController _transform = TransformationController();
  String? _localPath;
  String? _error;
  bool _zoomed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _transform.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final local = await context.read<AppState>().downloadForPreview(
        widget.remote,
      );
      if (!mounted) return;
      setState(() => _localPath = local);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '$e');
    }
  }

  void _toggleZoom() {
    final zoomed = _transform.value.getMaxScaleOnAxis() > 1.01;
    _transform.value = zoomed
        ? Matrix4.identity()
        : (Matrix4.identity()..scaleByDouble(2.5, 2.5, 1, 1));
    if (zoomed != _zoomed) setState(() => _zoomed = zoomed);
  }

  void _syncZoomState() {
    final zoomed = _transform.value.getMaxScaleOnAxis() > 1.01;
    if (zoomed != _zoomed) setState(() => _zoomed = zoomed);
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return Center(
        child: GlassCard(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              AppIconView(
                AppIcons.broken_image_outlined,
                size: 40,
                color: Theme.of(context).colorScheme.error,
              ),
              const SizedBox(height: 10),
              Text(_error!, textAlign: TextAlign.center),
              const SizedBox(height: 12),
              FilledButton.icon(
                onPressed: () {
                  setState(() {
                    _error = null;
                    _localPath = null;
                  });
                  _load();
                },
                icon: const AppIconView(AppIcons.refresh, size: 18),
                label: const Text('重试'),
              ),
            ],
          ),
        ),
      );
    }

    if (_localPath == null) {
      return const Center(child: CircularProgressIndicator());
    }

    return GestureDetector(
      onDoubleTap: _toggleZoom,
      child: InteractiveViewer(
        transformationController: _transform,
        minScale: 1,
        maxScale: 8,
        // 允许拖到边界外一点，放大后看边缘细节更顺手。
        boundaryMargin: const EdgeInsets.all(160),
        // 未放大时不要吃掉水平拖动，交给 PageView 翻页。
        panEnabled: _zoomed,
        onInteractionEnd: (_) => _syncZoomState(),
        child: Center(
          child: Image.file(
            File(_localPath!),
            fit: BoxFit.contain,
            // 解码尺寸限制，避免大图直接 OOM；放大时也要够清楚。
            cacheWidth: 3200,
            errorBuilder: (_, _, _) => const Text('图片解码失败'),
          ),
        ),
      ),
    );
  }
}
