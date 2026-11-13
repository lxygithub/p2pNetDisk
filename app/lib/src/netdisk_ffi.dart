// Dart 绑定：加载 `netdisk_ffi` 动态库并调用 Rust 导出的 C ABI。
//
// 返回值统一是 `netdisk-core::Response` 的 JSON，例如
// `{"Entries":{"entries":[{"path":"a.txt","size":12}]}}` 或 `{"Error":"..."}`。
// 所有 Rust 分配的字符串都必须经 `netdisk_string_free` 释放，这里已封装。

import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

/// 不透明句柄，对应 Rust 侧的 `Handle`。
final class NetdiskHandle extends Opaque {}

typedef _InitFn = Pointer<NetdiskHandle> Function(
    Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>);
typedef _Call1Fn = Pointer<Utf8> Function(Pointer<NetdiskHandle>);
typedef _Call2Fn = Pointer<Utf8> Function(Pointer<NetdiskHandle>, Pointer<Utf8>);
typedef _Call3Fn = Pointer<Utf8> Function(
    Pointer<NetdiskHandle>, Pointer<Utf8>, Pointer<Utf8>);
typedef _LastErrorFn = Pointer<Utf8> Function();
typedef _VersionFn = Pointer<Utf8> Function();
typedef _PathsFn = Pointer<Utf8> Function(Pointer<NetdiskHandle>);
typedef _FreeStrNative = Void Function(Pointer<Utf8>);
typedef _FreeStrDart = void Function(Pointer<Utf8>);
typedef _CloseNative = Void Function(Pointer<NetdiskHandle>);
typedef _CloseDart = void Function(Pointer<NetdiskHandle>);

String defaultLibraryName() {
  if (Platform.isAndroid || Platform.isLinux) return 'libnetdisk_ffi.so';
  if (Platform.isMacOS) return 'libnetdisk_ffi.dylib';
  return 'netdisk_ffi.dll';
}

class NetdiskClient {
  late final DynamicLibrary _lib;
  late final _InitFn _init;
  late final _Call1Fn _ping;
  late final _Call1Fn _list;
  late final _Call3Fn _put;
  late final _Call3Fn _get;
  late final _LastErrorFn _lastError;
  late final _FreeStrDart _freeString;
  late final _CloseDart _closeHandle;
  /// 旧库可能没有这个符号（可选能力）。
  _PathsFn? _paths;
  _Call2Fn? _deleteFn;
  _Call3Fn? _renameFn;

  Pointer<NetdiskHandle>? _handle;

  NetdiskClient({String? libraryPath}) {
    final lib = DynamicLibrary.open(libraryPath ?? defaultLibraryName());
    _lib = lib;
    _init = lib.lookupFunction<_InitFn, _InitFn>('netdisk_init');
    _ping = lib.lookupFunction<_Call1Fn, _Call1Fn>('netdisk_ping');
    _list = lib.lookupFunction<_Call1Fn, _Call1Fn>('netdisk_list');
    _put = lib.lookupFunction<_Call3Fn, _Call3Fn>('netdisk_put');
    _get = lib.lookupFunction<_Call3Fn, _Call3Fn>('netdisk_get');
    _lastError = lib.lookupFunction<_LastErrorFn, _LastErrorFn>('netdisk_last_error');
    _freeString = lib.lookupFunction<_FreeStrNative, _FreeStrDart>('netdisk_string_free');
    _closeHandle = lib.lookupFunction<_CloseNative, _CloseDart>('netdisk_close');
    try {
      _paths = lib.lookupFunction<_PathsFn, _PathsFn>('netdisk_paths');
    } catch (_) {
      _paths = null;
    }
    try {
      _deleteFn = lib.lookupFunction<_Call2Fn, _Call2Fn>('netdisk_delete');
    } catch (_) {
      _deleteFn = null;
    }
    try {
      _renameFn = lib.lookupFunction<_Call3Fn, _Call3Fn>('netdisk_rename');
    } catch (_) {
      _renameFn = null;
    }
  }

  Pointer<NetdiskHandle> get _h {
    final h = _handle;
    if (h == null) throw StateError('call connect() first');
    return h;
  }

  /// 动态库能力标记，例如 `netdisk-ffi 0.1.0 (relay-modes: n0,custom; proto: netdisk/0)`。
  ///
  /// 旧版库没有这个符号，返回 null —— 客户端可用它判断 `.so` 是否与 UI 版本匹配。
  String? version() {
    try {
      final fn = _lib.lookupFunction<_VersionFn, _VersionFn>('netdisk_ffi_version');
      final p = fn();
      final s = p.toDartString();
      _freeString(p);
      return s;
    } catch (_) {
      return null;
    }
  }

  /// 成功返回 null，失败返回错误说明。
  String? connect(String relayUrl, String token, String serverAddr) {
    final a = relayUrl.toNativeUtf8();
    final b = token.toNativeUtf8();
    final c = serverAddr.toNativeUtf8();
    final h = _init(a, b, c);
    malloc.free(a);
    malloc.free(b);
    malloc.free(c);
    if (h.address == 0) return lastError();
    _handle = h;
    return null;
  }

  Map<String, dynamic> _decode(Pointer<Utf8> p) {
    final raw = p.toDartString();
    _freeString(p);
    final decoded = jsonDecode(raw);
    if (decoded is Map) return Map<String, dynamic>.from(decoded);
    // serde 把无字段枚举（Pong / Ready）序列化成裸字符串，统一包成 Map。
    if (decoded is String) return {decoded: null};
    return {'Error': 'unexpected response: $raw'};
  }

  Map<String, dynamic> _call3(
      _Call3Fn fn, String first, String second) {
    final a = first.toNativeUtf8();
    final b = second.toNativeUtf8();
    final res = fn(_h, a, b);
    malloc.free(a);
    malloc.free(b);
    return _decode(res);
  }

  Map<String, dynamic> ping() => _decode(_ping(_h));
  Map<String, dynamic> listFiles() => _decode(_list(_h));

  /// [remote] 是服务端相对路径，[local] 是本地文件路径。
  Map<String, dynamic> put(String remote, String local) =>
      _call3(_put, remote, local);
  Map<String, dynamic> get(String remote, String local) =>
      _call3(_get, remote, local);

  /// 删除文件（服务端移入回收站，不是硬删）。
  Map<String, dynamic> delete(String path) {
    final fn = _deleteFn;
    if (fn == null) {
      throw StateError('动态库缺少 netdisk_delete：请重新交叉编译 .so');
    }
    final a = path.toNativeUtf8();
    final res = fn(_h, a);
    malloc.free(a);
    return _decode(res);
  }

  /// 重命名 / 移动；目标已存在时服务端返回 Error。
  Map<String, dynamic> rename(String from, String to) {
    final fn = _renameFn;
    if (fn == null) {
      throw StateError('动态库缺少 netdisk_rename：请重新交叉编译 .so');
    }
    return _call3(fn, from, to);
  }

  String lastError() {
    final p = _lastError();
    final s = p.toDartString();
    _freeString(p);
    return s;
  }

  /// 当前连接的传输路径；未连接或旧库不支持时返回 null。
  ({String desc, bool direct})? paths() {
    final fn = _paths;
    final h = _handle;
    if (fn == null || h == null) return null;
    final res = _decode(fn(h));
    final p = res['Paths'];
    if (p is! Map) return null;
    return (
      desc: (p['desc'] as String?) ?? '',
      direct: (p['direct'] as bool?) ?? false,
    );
  }

  void close() {
    final h = _handle;
    if (h != null) {
      _closeHandle(h);
      _handle = null;
    }
  }
}

/// 把 `Entries` 响应解析成 (path, size) 记录列表。
List<({String path, int size})> parseEntries(Map<String, dynamic> response) {
  final err = response['Error'];
  if (err != null) throw StateError(err.toString());
  final entries = response['Entries']?['entries'] as List<dynamic>? ?? <dynamic>[];
  return entries.map((e) {
    final m = Map<String, dynamic>.from(e as Map);
    return (path: m['path'] as String, size: (m['size'] as num).toInt());
  }).toList();
}
