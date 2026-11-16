/// 远端路径与本地路径之间的映射工具。
///
/// 全部是纯函数，便于单测；目录上传/下载时两边路径语义差别很大：
/// - 远端统一用 `/` 分隔、无前导 `/`；
/// - 本地在 Windows 上还需要盘符与 `\`，所以拼接一律走 `package:path`。
library;

import 'package:path/path.dart' as p;

/// 服务端 `safe_path` 明确拒绝的名字：隐藏文件、身份私钥、上传中的临时文件。
///
/// 上传本地目录时必须在客户端先跳过，否则 `.git/config`、`.nomedia` 这类
/// 常见文件会逐个报错，把队列刷满失败任务。
bool shouldSkipUploadName(String name) {
  if (name.isEmpty) return true;
  if (name.startsWith('.')) return true;
  if (name == 'secret.key') return true;
  if (name.endsWith('.netdisk-tmp')) return true;
  return false;
}

/// 远端相对路径的任意一段是否该跳过（用于递归遍历时剪掉 `/.git/...`）。
bool shouldSkipUploadPath(String relative) {
  return relative
      .split('/')
      .any((segment) => segment.isNotEmpty && shouldSkipUploadName(segment));
}

/// 把远端路径映射成「相对 [remoteBase] 的路径」。
///
/// 例：`localRelPath('photos/2026/a.jpg', remoteBase: 'photos/')` → `2026/a.jpg`。
/// 不在前缀内时原样返回（防御性：宁可按完整路径落盘，也不要把文件写到根上）。
String localRelPath(String remotePath, {String remoteBase = ''}) {
  final path = remotePath.replaceAll('\\', '/');
  var base = remoteBase.replaceAll('\\', '/');
  if (base.isEmpty) return path;
  if (!base.endsWith('/')) base = '$base/';
  if (path == base || path == base.substring(0, base.length - 1)) return '';
  return path.startsWith(base) ? path.substring(base.length) : path;
}

/// 拼接本地绝对路径，过滤空段与 `.` / `..`，避免远端路径影响本地目录结构。
String joinUnder(String root, String relative) {
  final segments = relative
      .split('/')
      .where((s) => s.isNotEmpty && s != '.' && s != '..')
      .toList(growable: false);
  if (segments.isEmpty) return root;
  return p.joinAll([root, ...segments]);
}

/// 从全量递归列表里挑出某个目录（含自身）下的所有条目。
///
/// 服务端 `List` 返回的是**整棵树的扁平列表**，所以目录下载不需要新协议，
/// 本地过滤前缀即可。这里用 `dir/` 判断，避免 `photos` 误匹配 `photos2`。
List<({String path, int size, bool isDir})> entriesUnder(
  List<({String path, int size, bool isDir})> all,
  String dir,
) {
  var d = dir.replaceAll('\\', '/');
  while (d.endsWith('/')) {
    d = d.substring(0, d.length - 1);
  }
  if (d.isEmpty) return List.of(all);
  return [
    for (final e in all)
      if (e.path == d || e.path.startsWith('$d/')) e,
  ];
}

/// 目录 `dir` 的直接子目录名（已排序，不含文件）。
///
/// 目录选择器用它逐级浏览：列表里既没有文件也不需要递归，只关心下一层文件夹。
List<String> childDirNames(
  List<({String path, int size, bool isDir})> all,
  String dir,
) {
  var d = dir.replaceAll('\\', '/');
  while (d.endsWith('/')) {
    d = d.substring(0, d.length - 1);
  }
  final prefix = d.isEmpty ? '' : '$d/';
  final names = <String>{};
  for (final e in all) {
    if (!e.path.startsWith(prefix)) continue;
    final rest = e.path.substring(prefix.length);
    if (rest.isEmpty) continue;
    final slash = rest.indexOf('/');
    if (slash >= 0) {
      names.add(rest.substring(0, slash));
    } else if (e.isDir) {
      names.add(rest);
    }
  }
  return names.toList()..sort();
}

/// 目录 `dir` 的父目录（以 `/` 结尾；根目录返回空串）。
///
/// 例：`parentOf('photos/2026/')` → `photos/`，`parentOf('photos/')` → ``。
String parentOf(String dir) {
  var d = dir.replaceAll('\\', '/');
  while (d.endsWith('/')) {
    d = d.substring(0, d.length - 1);
  }
  final idx = d.lastIndexOf('/');
  return idx < 0 ? '' : d.substring(0, idx + 1);
}

/// 目录自身的最后一段名称。`photos/2026/` → `2026`。
String dirName(String dir) {
  var d = dir.replaceAll('\\', '/');
  while (d.endsWith('/')) {
    d = d.substring(0, d.length - 1);
  }
  final idx = d.lastIndexOf('/');
  return idx < 0 ? d : d.substring(idx + 1);
}
