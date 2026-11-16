import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// 搜索历史的本地存储（最多 [maxItems] 条，最近使用的排前面）。
class SearchPrefs {
  SearchPrefs._();

  static const int maxItems = 10;
  static const String _fileName = 'search_history.json';

  static Future<File> _target() async {
    final dir = await getApplicationDocumentsDirectory();
    return File(p.join(dir.path, _fileName));
  }

  static Future<List<String>> read() async {
    try {
      final file = await _target();
      if (!await file.exists()) return const [];
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! List) return const [];
      return [
        for (final e in decoded)
          if (e is String && e.isNotEmpty) e,
      ];
    } catch (_) {
      return const [];
    }
  }

  /// 记录一次搜索，返回更新后的历史列表。
  static Future<List<String>> add(String keyword) async {
    final trimmed = keyword.trim();
    if (trimmed.isEmpty) return read();
    final list = [...await read()]..removeWhere((e) => e == trimmed);
    list.insert(0, trimmed);
    final trimmedList = list.take(maxItems).toList();
    try {
      await (await _target()).writeAsString(jsonEncode(trimmedList));
    } catch (_) {
      // 写失败不影响搜索本身。
    }
    return trimmedList;
  }

  static Future<void> clear() async {
    try {
      final file = await _target();
      if (await file.exists()) await file.delete();
    } catch (_) {
      // 忽略。
    }
  }
}
