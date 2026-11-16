import 'dart:io';

import 'package:flutter/services.dart';

/// 公共存储目录的访问能力（Android 专用，其他平台恒为「可用」）。
///
/// 为什么需要它：下载默认落到公共 `Download/p2pNetDisk`，这样卸载 App 不会
/// 连带删掉已下载的文件。但 Android 11+ 的分区存储不允许普通 App 写公共目录，
/// 必须拿到「所有文件访问」（`MANAGE_EXTERNAL_STORAGE`）特殊权限；
/// Android 10 及以下则是普通的「写外部存储」运行时权限。
///
/// 所有方法都吞掉平台异常并返回「不可用」，让调用方走 App 专属目录的回退分支 ——
/// 「查权限」本身不该变成下载失败的原因。
class StorageAccess {
  StorageAccess._();

  static const MethodChannel _channel = MethodChannel('netdisk/storage');

  /// 当前是否可以在公共目录按绝对路径写文件。
  static Future<bool> hasPublicAccess() async {
    if (!Platform.isAndroid) return true;
    try {
      return await _channel.invokeMethod<bool>('hasPublicAccess') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// 打开系统授权页。返回 false 表示连设置页都打不开。
  ///
  /// 授权结果无法在这里同步拿到（用户要在系统设置里手动允许再返回），
  /// 调用方应在 App resume 后重新查询 [hasPublicAccess]。
  static Future<bool> requestPublicAccess() async {
    if (!Platform.isAndroid) return true;
    try {
      return await _channel.invokeMethod<bool>('requestPublicAccess') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// 公共「下载」目录的绝对路径，如 `/storage/emulated/0/Download`。
  static Future<String?> publicDownloadsPath() async {
    if (!Platform.isAndroid) return null;
    try {
      final path = await _channel.invokeMethod<String>('publicDownloadsPath');
      return (path == null || path.isEmpty) ? null : path;
    } catch (_) {
      return null;
    }
  }
}
