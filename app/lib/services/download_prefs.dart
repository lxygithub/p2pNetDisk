import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'storage_access.dart';

/// 下载落盘位置的解析与持久化。
///
/// 默认位置是**公共「下载」目录**（`/storage/emulated/0/Download/p2pNetDisk`），
/// 这样卸载 App 不会连带删掉已下载的文件 —— App 专属目录
/// （`Android/data/<包名>/files/...`）会在卸载时被系统清理。
///
/// Android 11+ 的公共目录受分区存储保护，需要「所有文件访问」特殊权限；
/// 拿不到时退回 App 专属外部目录，并在设置页明确提示「卸载会丢」。
///
/// 用户也可以在设置页选一个自定义目录；无论来源，选完都会用 [isWritable]
/// 实测一次（真写一个探针文件），别等下载完才发现写不进去。
class DownloadPrefs {
  DownloadPrefs._();

  static const int _version = 1;
  static const String _fileName = 'download_location.json';

  /// 未配置自定义位置时的默认根目录。
  ///
  /// 优先公共「下载」目录（卸载保留），其次 App 专属外部目录（免权限但会随
  /// 卸载清除），最后回退系统「下载」目录 / 文档目录。
  static Future<String> defaultRoot() async {
    if (Platform.isAndroid) {
      if (await StorageAccess.hasPublicAccess()) {
        final base = await StorageAccess.publicDownloadsPath();
        if (base != null) return p.join(base, 'p2pNetDisk');
      }
    }
    try {
      if (Platform.isAndroid) {
        final ext = await getExternalStorageDirectory();
        if (ext != null) return p.join(ext.path, 'p2pNetDisk');
      }
    } catch (_) {
      // 插件缺失或平台不支持，继续回退。
    }
    try {
      final downloads = await getDownloadsDirectory();
      if (downloads != null) return p.join(downloads.path, 'p2pNetDisk');
    } catch (_) {
      // 同上。
    }
    final docs = await getApplicationDocumentsDirectory();
    return p.join(docs.path, 'downloads');
  }

  /// 规范化用户选中的路径：去空白、去末尾分隔符。
  ///
  /// 保留 `C:\` 这类只有 3 个字符的根路径，否则会被裁成 `C:`。
  static String normalize(String raw) {
    var s = raw.trim();
    while (s.length > 3 && (s.endsWith('/') || s.endsWith('\\'))) {
      s = s.substring(0, s.length - 1);
    }
    return s;
  }

  /// 实测目录是否可写：建目录 + 写一个探针文件再删掉。
  ///
  /// 只看 `Directory.exists` 不够 —— Android 11+ 的公共目录「看得见、写不进」，
  /// 必须真写一次才能提前失败，而不是等下载到一半才报 EACCES。
  static Future<bool> isWritable(String rawPath) async {
    final path = normalize(rawPath);
    if (path.isEmpty) return false;
    try {
      await Directory(path).create(recursive: true);
      final probe = File(p.join(path, '.netdisk-write-probe'));
      await probe.writeAsString('ok', flush: true);
      await probe.delete();
      return true;
    } catch (_) {
      return false;
    }
  }

  static Future<File> _target() async {
    final dir = await getApplicationDocumentsDirectory();
    return File(p.join(dir.path, _fileName));
  }

  /// 读取用户自定义的下载目录；未配置或文件损坏时返回 null（走默认值）。
  static Future<String?> readOverride() async {
    try {
      final file = await _target();
      if (!await file.exists()) return null;
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map) return null;
      final data = Map<String, dynamic>.from(decoded);
      if (data['v'] != _version) return null;
      final path = data['path'];
      if (path is! String) return null;
      final normalized = normalize(path);
      return normalized.isEmpty ? null : normalized;
    } catch (_) {
      return null;
    }
  }

  static Future<void> saveOverride(String path) async {
    try {
      final file = await _target();
      await file.writeAsString(
        jsonEncode({'v': _version, 'path': normalize(path)}),
      );
    } catch (_) {
      // 写失败只影响「下次启动记住」，不影响本次下载。
    }
  }

  static Future<void> clearOverride() async {
    try {
      final file = await _target();
      if (await file.exists()) await file.delete();
    } catch (_) {
      // 清不掉也不该报错给用户。
    }
  }
}
