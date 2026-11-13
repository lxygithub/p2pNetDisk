import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// 与 `AppState.files` 相同的记录类型。
typedef CachedEntry = ({String path, int size, bool isDir});

class ListSnapshot {
  const ListSnapshot({required this.savedAt, required this.entries});

  final DateTime savedAt;
  final List<CachedEntry> entries;
}

/// 上次成功拉取的文件列表快照。
///
/// 冷启动的第一屏慢在「建 endpoint → 首次 QUIC 握手 → 全量列表」，这几步
/// 都在网络上，少则几秒、链路差时十几秒。这里把上一次的结果落在 App 私有
/// 目录里，启动时先渲染旧列表（stale-while-revalidate），再后台刷新。
///
/// 安全：缓存里只有路径/大小/是否目录，服务端地址只存 `hashCode` 作为隔离
/// 键，不写入 EndpointId 本体；文件位于 App 私有目录，其他应用读不到。
class ListCache {
  ListCache._();

  static const int _version = 1;
  static const String _fileName = 'file_list_cache.json';

  static Future<File> _target() async {
    final dir = await getApplicationDocumentsDirectory();
    return File(p.join(dir.path, _fileName));
  }

  static Future<ListSnapshot?> read(String endpointKey) async {
    try {
      final file = await _target();
      if (!await file.exists()) return null;
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map) return null;
      final data = Map<String, dynamic>.from(decoded);
      if (data['v'] != _version || data['endpoint'] != endpointKey) return null;

      final raw = data['entries'];
      if (raw is! List) return null;
      final entries = <CachedEntry>[];
      for (final item in raw) {
        if (item is! Map) continue;
        final path = item['path'];
        if (path is! String || path.isEmpty) continue;
        entries.add((
          path: path,
          size: (item['size'] as num?)?.toInt() ?? 0,
          isDir: item['isDir'] as bool? ?? false,
        ));
      }
      if (entries.isEmpty) return null;
      return ListSnapshot(
        savedAt: DateTime.fromMillisecondsSinceEpoch(
          (data['savedAt'] as num?)?.toInt() ?? 0,
        ),
        entries: entries,
      );
    } catch (_) {
      // 缓存损坏 / 平台不支持（widget 测试）时当作没有缓存。
      return null;
    }
  }

  static Future<void> write(
    String endpointKey,
    List<CachedEntry> entries,
  ) async {
    try {
      final file = await _target();
      await file.writeAsString(
        jsonEncode(<String, dynamic>{
          'v': _version,
          'endpoint': endpointKey,
          'savedAt': DateTime.now().millisecondsSinceEpoch,
          'entries': <Map<String, dynamic>>[
            for (final e in entries)
              <String, dynamic>{
                'path': e.path,
                'size': e.size,
                'isDir': e.isDir,
              },
          ],
        }),
      );
    } catch (_) {
      // 写缓存失败不影响本次刷新结果。
    }
  }
}
