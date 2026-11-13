import 'dart:async';

import 'package:flutter/services.dart';

/// 传输通知桥：通过 MethodChannel 调用 MainActivity 里的原生实现。
///
/// 不引入 flutter_local_notifications，原因见 MainActivity.kt 的注释：
/// 这里只需要一条可更新的进度通知，插件带来的 compileSdk 37 / desugaring
/// 要求与已知崩溃不值得。
class TransferNotifications {
  TransferNotifications._();

  static const _channel = MethodChannel('netdisk/notifications');

  /// 平台不支持（widget 测试、非 Android）时置 false，之后不再尝试，
  /// 避免每次进度更新都抛 MissingPluginException。
  static bool _available = true;

  static DateTime _lastShown = DateTime.fromMillisecondsSinceEpoch(0);

  /// 进度更新最多 800ms 一次；状态变化传 `force: true` 绕过。
  ///
  /// 传输回调是 250ms 一次，5 个并发就是 20 次/秒的跨语言调用，
  /// 不节流会明显拖慢 UI 线程。
  static const _minInterval = Duration(milliseconds: 800);

  static Future<void> ensurePermission() async {
    if (!_available) return;
    try {
      await _channel.invokeMethod<void>('ensurePermission');
    } catch (_) {
      _available = false;
    }
  }

  static Future<void> show({
    required String title,
    required String text,
    int? progress,
    bool ongoing = true,
    bool force = false,
  }) async {
    if (!_available) return;

    final now = DateTime.now();
    if (!force && now.difference(_lastShown) < _minInterval) return;
    _lastShown = now;

    try {
      await _channel.invokeMethod<void>('show', <String, Object?>{
        'title': title,
        'text': text,
        'progress': progress ?? -1,
        'ongoing': ongoing,
      });
    } catch (_) {
      _available = false;
    }
  }

  static Future<void> cancel() async {
    if (!_available) return;
    try {
      await _channel.invokeMethod<void>('cancel');
    } catch (_) {
      _available = false;
    }
  }

  // ---------------------------------------------------------------------------
  // 前台服务（后台保活）
  // ---------------------------------------------------------------------------

  /// 启动前台服务。必须带一条通知，否则系统会拒绝。
  static Future<void> startService({
    required String title,
    required String text,
    int? progress,
  }) async {
    if (!_available) return;
    try {
      await _channel.invokeMethod<void>('startService', <String, Object?>{
        'title': title,
        'text': text,
        'progress': progress ?? -1,
      });
    } catch (_) {
      _available = false;
    }
  }

  static Future<void> updateService({
    required String title,
    required String text,
    int? progress,
    bool force = false,
  }) async {
    if (!_available) return;

    final now = DateTime.now();
    if (!force && now.difference(_lastShown) < _minInterval) return;
    _lastShown = now;

    try {
      await _channel.invokeMethod<void>('updateService', <String, Object?>{
        'title': title,
        'text': text,
        'progress': progress ?? -1,
      });
    } catch (_) {
      _available = false;
    }
  }

  static Future<void> stopService() async {
    if (!_available) return;
    try {
      await _channel.invokeMethod<void>('stopService');
    } catch (_) {
      _available = false;
    }
  }

  // ---------------------------------------------------------------------------
  // 厂商后台策略
  // ---------------------------------------------------------------------------

  /// 是否已豁免电池优化；平台不支持时返回 null。
  static Future<bool?> isIgnoringBatteryOptimizations() async {
    if (!_available) return null;
    try {
      return await _channel.invokeMethod<bool>(
        'isIgnoringBatteryOptimizations',
      );
    } catch (_) {
      _available = false;
      return null;
    }
  }

  /// 弹出系统的「忽略电池优化」确认框。
  static Future<bool> requestIgnoreBatteryOptimizations() async {
    if (!_available) return false;
    try {
      return await _channel.invokeMethod<bool>(
            'requestIgnoreBatteryOptimizations',
          ) ??
          false;
    } catch (_) {
      _available = false;
      return false;
    }
  }

  /// 跳转厂商的「自启动 / 后台管理」页；返回是否命中了厂商专属页面。
  static Future<bool> openAutoStartSettings() async {
    if (!_available) return false;
    try {
      return await _channel.invokeMethod<bool>('openAutoStartSettings') ??
          false;
    } catch (_) {
      _available = false;
      return false;
    }
  }

  /// 设备信息：manufacturer / brand / model / sdk / harmony。
  static Future<Map<String, Object?>?> deviceInfo() async {
    if (!_available) return null;
    try {
      final res = await _channel.invokeMethod<Map<Object?, Object?>>(
        'deviceInfo',
      );
      return res?.map((k, v) => MapEntry(k.toString(), v));
    } catch (_) {
      _available = false;
      return null;
    }
  }
}
