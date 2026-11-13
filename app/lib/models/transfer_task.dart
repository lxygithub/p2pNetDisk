/// 传输任务模型。
///
/// 一个任务对应一次「上传一个文件」或「下载一个文件」。队列串行执行，
/// 因为 FFI 句柄内部只有一条 QUIC 连接 + 一个 Mutex，并发调用只会互相阻塞。
library;

enum TransferKind { upload, download }

enum TransferStatus { queued, running, done, failed }

class TransferTask {
  TransferTask({
    required this.id,
    required this.kind,
    required this.remote,
    required this.local,
    required this.total,
  });

  final int id;
  final TransferKind kind;

  /// 服务端相对路径（含目录前缀）。
  final String remote;

  /// 本地绝对路径。
  final String local;

  /// 总字节数；未知时为 0。
  final int total;

  int sent = 0;
  TransferStatus status = TransferStatus.queued;
  String? error;

  /// 瞬时速度（字节/秒），由 [SpeedMeter] 采样得出。
  double speed = 0.0;

  final SpeedMeter meter = SpeedMeter();

  DateTime? startedAt;
  DateTime? finishedAt;

  double get progress => total > 0 ? (sent / total).clamp(0.0, 1.0) : 0.0;

  String get kindLabel => kind == TransferKind.upload ? '上传' : '下载';

  /// 只取文件名部分，列表中显示更紧凑。
  String get name {
    final i = remote.lastIndexOf('/');
    return i < 0 ? remote : remote.substring(i + 1);
  }

  /// 任务结束后可用于「用时」展示。
  Duration? get elapsed {
    final s = startedAt;
    if (s == null) return null;
    return (finishedAt ?? DateTime.now()).difference(s);
  }
}

/// 滑动窗口测速：只保留最近 [window] 内的采样点，避免平均值把瞬时速度抹平。
class SpeedMeter {
  SpeedMeter({this.window = const Duration(seconds: 2)});

  final Duration window;
  final List<({DateTime at, int sent})> _samples = [];

  /// 采样一次并返回当前速度（字节/秒）。数据不足两个点时返回 0。
  double sample(int sent) {
    final now = DateTime.now();
    _samples.add((at: now, sent: sent));
    _samples.removeWhere((s) => now.difference(s.at) > window);
    if (_samples.length < 2) return 0;

    final first = _samples.first;
    final seconds = now.difference(first.at).inMilliseconds / 1000.0;
    if (seconds <= 0) return 0;

    final delta = sent - first.sent;
    if (delta <= 0) return 0;
    return delta / seconds;
  }

  void reset() => _samples.clear();
}

/// 把字节数格式化成 `1.2 MB`、`860 KB` 这类易读形式。
String humanSize(int bytes) {
  if (bytes < 1024) return '$bytes B';
  const units = ['KB', 'MB', 'GB', 'TB'];
  var v = bytes / 1024.0;
  var i = 0;
  while (v >= 1024 && i < units.length - 1) {
    v /= 1024;
    i++;
  }
  return '${v.toStringAsFixed(v >= 100 ? 0 : 1)} ${units[i]}';
}

/// 速度格式化，例如 `3.4 MB/s`。
String humanSpeed(double bytesPerSecond) {
  if (bytesPerSecond <= 0) return '—';
  return '${humanSize(bytesPerSecond.round())}/s';
}

/// 时长格式化，例如 `12s`、`1m 20s`。
String humanDuration(Duration d) {
  if (d.inSeconds < 60) return '${d.inSeconds}s';
  final m = d.inMinutes;
  final s = d.inSeconds % 60;
  return '${m}m ${s}s';
}
