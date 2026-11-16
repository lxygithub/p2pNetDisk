import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/transfer_task.dart';
import '../state/app_state.dart';
import '../widgets/glass.dart';

/// 文件预览：先把远程文件下载到临时目录，再按类型渲染。
///
/// 只支持图片与文本 —— 其他类型没有可靠的跨平台内嵌渲染方案，
/// 与其给一个打不开的黑框，不如明确提示并引导下载。
class PreviewPage extends StatefulWidget {
  const PreviewPage({super.key, required this.remote});

  final String remote;

  @override
  State<PreviewPage> createState() => _PreviewPageState();
}

class _PreviewPageState extends State<PreviewPage> {
  String? _localPath;
  String? _error;
  bool _loading = true;

  /// 图片缩放/平移状态。双击在 1x 与 2.5x 之间切换，AppBar 上还能一键还原。
  final TransformationController _transform = TransformationController();

  @override
  void dispose() {
    _transform.dispose();
    super.dispose();
  }

  void _toggleZoom() {
    final zoomed = _transform.value.getMaxScaleOnAxis() > 1.01;
    _transform.value = zoomed
        ? Matrix4.identity()
        : (Matrix4.identity()..scaleByDouble(2.5, 2.5, 1, 1));
  }

  void _resetZoom() => _transform.value = Matrix4.identity();

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

  String get _ext {
    final name = widget.remote.split('/').last;
    return name.contains('.') ? name.split('.').last.toLowerCase() : '';
  }

  /// 只有图片和文本走预览；其他类型不该为了「看一眼」把整个文件下下来。
  bool get _supported => _imageExts.contains(_ext) || _textExts.contains(_ext);

  @override
  void initState() {
    super.initState();
    if (!_supported) {
      _loading = false;
      return;
    }
    _load();
  }

  Future<void> _load() async {
    try {
      final local = await context.read<AppState>().downloadForPreview(
        widget.remote,
      );
      if (!mounted) return;
      setState(() {
        _localPath = local;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  /// 失败后让用户就地重试；若后台线程已卡死，AppState 会在重新连接时
  /// 换一个干净的 isolate，这次重试才能真正发出去。
  void _retry() {
    setState(() {
      _error = null;
      _localPath = null;
      _loading = true;
    });
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final name = widget.remote.split('/').last;
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        title: Text(name, overflow: TextOverflow.ellipsis),
        actions: [
          if (_imageExts.contains(_ext))
            IconButton(
              tooltip: '还原缩放',
              icon: const Icon(Icons.fit_screen_outlined),
              onPressed: _resetZoom,
            ),
        ],
      ),
      body: Padding(padding: const EdgeInsets.all(16), child: _body()),
    );
  }

  Widget _body() {
    // 不支持的类型直接给提示，不做任何下载。
    if (!_supported) {
      return Center(
        child: GlassCard(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.insert_drive_file_outlined,
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

    if (_loading) {
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
    if (_error != null) {
      return Center(
        child: GlassCard(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.error_outline,
                color: Theme.of(context).colorScheme.error,
              ),
              const SizedBox(height: 8),
              Text(_error!, textAlign: TextAlign.center),
              const SizedBox(height: 14),
              FilledButton.icon(
                onPressed: _retry,
                icon: const Icon(Icons.refresh, size: 18),
                label: const Text('重试'),
              ),
            ],
          ),
        ),
      );
    }

    final path = _localPath!;
    if (_imageExts.contains(_ext)) {
      return Stack(
        children: [
          Positioned.fill(
            child: GestureDetector(
              onDoubleTap: _toggleZoom,
              child: InteractiveViewer(
                transformationController: _transform,
                minScale: 1,
                maxScale: 8,
                // 允许拖到边界外一点，放大后看边缘细节更顺手。
                boundaryMargin: const EdgeInsets.all(160),
                child: Center(
                  child: Image.file(
                    File(path),
                    fit: BoxFit.contain,
                    // 解码尺寸限制，避免大图直接 OOM；放大时也要够清楚。
                    cacheWidth: 3200,
                    errorBuilder: (_, _, _) => const Text('图片解码失败'),
                  ),
                ),
              ),
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: Center(
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 4,
                ),
                decoration: BoxDecoration(
                  color: Colors.black54,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Text(
                  '双指缩放 · 双击放大 / 还原',
                  style: TextStyle(fontSize: 11, color: Colors.white70),
                ),
              ),
            ),
          ),
        ],
      );
    }
    if (_textExts.contains(_ext)) {
      return FutureBuilder<String>(
        future: _readText(path),
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

    return Center(
      child: GlassCard(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.insert_drive_file_outlined,
              size: 44,
              color: Theme.of(context).colorScheme.outline,
            ),
            const SizedBox(height: 10),
            Text('暂不支持预览 .$_ext 类型'),
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
