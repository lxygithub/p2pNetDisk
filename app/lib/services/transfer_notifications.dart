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
}
