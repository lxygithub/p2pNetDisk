import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// 设置页里由用户手动填写的连接参数。
class ConnectionConfig {
  const ConnectionConfig({
    required this.relay,
    required this.token,
    required this.addr,
  });

  final String relay;
  final String token;
  final String addr;
}

/// 连接参数的本地持久化。
///
/// 编译期注入（`--dart-define=NETDISK_ENDPOINT_ID`）仍是默认来源：只有在设置页
/// 改过值才会写这个文件，不会把注入值再复制一份到磁盘。文件位于 App 私有
/// 文档目录，其他应用读不到，也不在版本控制里。
///
/// `addr` 含真实 EndpointId，属于设备本地的配对信息；不要把它同步到公开仓库、
/// 日志或聊天里。读/写失败一律静默回落，绝不能阻塞启动或本次连接。
class ConnectionPrefs {
  ConnectionPrefs._();

  static const int _version = 1;
  static const String _fileName = 'connection_config.json';

  static Future<File> _target() async {
    final dir = await getApplicationDocumentsDirectory();
    return File(p.join(dir.path, _fileName));
  }

  /// 只做结构校验：JSON 对象 + 非空 id。
  /// EndpointId 本身的格式由 Rust 侧（iroh）校验，这里不重复实现。
  static bool isValidAddr(String value) {
    final text = value.trim();
    if (!text.startsWith('{') || !text.endsWith('}')) return false;
    try {
      final decoded = jsonDecode(text);
      return decoded is Map &&
          decoded['id'] is String &&
          (decoded['id'] as String).trim().isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  static Future<ConnectionConfig?> read() async {
    try {
      final file = await _target();
      if (!await file.exists()) return null;
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map) return null;
      final data = Map<String, dynamic>.from(decoded);
      if (data['v'] != _version) return null;

      final relay = data['relay'];
      final token = data['token'];
      final addr = data['addr'];
      if (relay is! String || token is! String || addr is! String) return null;
      // 半截输入或被手工改坏的文件一律忽略，回落到编译期默认值。
      if (!isValidAddr(addr)) return null;
      return ConnectionConfig(relay: relay, token: token, addr: addr);
    } catch (_) {
      return null;
    }
  }

  static Future<void> save(ConnectionConfig config) async {
    try {
      final file = await _target();
      await file.writeAsString(
        jsonEncode({
          'v': _version,
          'relay': config.relay,
          'token': config.token,
          'addr': config.addr,
        }),
      );
    } catch (_) {
      // 写失败只影响「下次启动记住」，不影响本次连接。
    }
  }

  static Future<void> clear() async {
    try {
      final file = await _target();
      if (await file.exists()) await file.delete();
    } catch (_) {
      // 同上：清不掉也不该报错给用户。
    }
  }
}
