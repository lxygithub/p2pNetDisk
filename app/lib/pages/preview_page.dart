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

  @override
  void initState() {
    super.initState();
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

  @override
  Widget build(BuildContext context) {
    final name = widget.remote.split('/').last;
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(title: Text(name, overflow: TextOverflow.ellipsis)),
      body: Padding(padding: const EdgeInsets.all(16), child: _body()),
    );
  }

  Widget _body() {
    if (_loading) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 12),
            Text('正在下载以预览…', style: TextStyle(fontSize: 13)),
          ],
        ),
      );
    }
    if (_error != null) {
      return Center(
        child: GlassCard(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.error_outline,
                color: Theme.of(context).colorScheme.error,
              ),
              const SizedBox(height: 8),
              Text(_error!, textAlign: TextAlign.center),
            ],
          ),
        ),
      );
    }

    final path = _localPath!;
    if (_imageExts.contains(_ext)) {
      return Center(
        child: InteractiveViewer(
          maxScale: 5,
          child: Image.file(
            File(path),
            fit: BoxFit.contain,
            // 解码尺寸限制，避免大图直接 OOM。
            cacheWidth: 2400,
            errorBuilder: (_, _, _) => const Text('图片解码失败'),
          ),
        ),
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
