import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../theme.dart';

/// 主题偏好的本地存储。
///
/// 只是个字符串，单独存一个小文件，不跟连接配置混在一起——
/// 这样改主题不会触碰 EndpointId / token。
class ThemePrefs {
  ThemePrefs._();

  static const String _fileName = 'theme.json';

  static Future<File> _target() async {
    final dir = await getApplicationDocumentsDirectory();
    return File(p.join(dir.path, _fileName));
  }

  static Future<AppTheme> read() async {
    try {
      final file = await _target();
      if (!await file.exists()) return AppTheme.ocean;
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is Map && decoded['theme'] is String) {
        return AppTheme.fromName(decoded['theme'] as String);
      }
    } catch (_) {
      // 文件损坏就回默认主题，不影响启动。
    }
    return AppTheme.ocean;
  }

  static Future<void> save(AppTheme theme) async {
    try {
      await (await _target()).writeAsString(jsonEncode({'theme': theme.name}));
    } catch (_) {
      // 持久化失败不影响本次切换。
    }
  }
}
