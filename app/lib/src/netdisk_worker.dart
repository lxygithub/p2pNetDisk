// 把 netdisk_ffi 的全部调用放到一个常驻后台 isolate 里执行。
//
// 为什么必须这样做：
// - Rust 侧 `netdisk_init/list/put/get` 都是同步阻塞的（内部 `RT.block_on`），
//   一次 `connect + RPC` 在跨网链路上可能耗时数秒到数十秒（链路丢包时还要重试）；
// - 如果在 UI isolate 上直接调用，主线程会被完全冻结，Android 5 秒无输入响应即 ANR。
//
// 为什么不能简单用 `Isolate.run` 或 `compute`：
// - `Pointer`（FFI 句柄）不能跨 isolate 传递，所以「每次新建 isolate 再 init」等于
//   每次都重建 endpoint，代价不可接受。这里改成常驻 worker：动态库加载、`init`、
//   句柄全部留在 worker isolate 内，主 isolate 只收发命令与 JSON 结果。
//
// 线程模型：worker 内串行处理命令（Rust 端本来就是单 runtime + 单句柄），
// 主 isolate 侧用 Completer 把回复对应回具体请求。

import 'dart:async';
import 'dart:ffi';
import 'dart:isolate';

import 'package:ffi/ffi.dart';

import 'netdisk_ffi.dart';

/// worker 侧返回的错误。
class NetdiskWorkerException implements Exception {
  NetdiskWorkerException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// netdisk-ffi 的后台 isolate 门面。所有方法都是异步的，不会阻塞 UI。
class NetdiskWorker {
  NetdiskWorker({
    this.timeout = const Duration(seconds: 90),
    this.transferTimeout = const Duration(minutes: 30),
  });

  /// 普通 RPC（init / ping / list）的空闲超时。
  final Duration timeout;

  /// 上传下载的超时（大文件 + 慢链路）。
  final Duration transferTimeout;

  final ReceivePort _rx = ReceivePort();
  final Map<int, Completer<Map<String, dynamic>>> _pending = {};
  final Map<int, String> _ops = {};

  Isolate? _isolate;
  SendPort? _tx;
  int _seq = 0;
  bool _disposed = false;

  /// 这个 isolate 是否已经「中毒」。
  ///
  /// worker 里的 FFI 调用是**同步阻塞**的，而 Dart 的 `Future.timeout` 只能让
  /// 主 isolate 放弃等待，**取消不了** native 侧那条还在 `read_frame` 上挂着的
  /// 调用。此后发任何命令都只会堆在它后面，表现为列表、预览、路径全部一直转圈。
  /// 所以一旦超时就把实例标记为不可信，由 AppState 重新连接时换一个干净的
  /// isolate（旧的一起 kill 掉，卡住的 FFI 也随之消失）。
  ///
  /// 这里刻意**不**自动 kill、也不 fail 掉其他挂起请求：worker 是串行的，
  /// 传大文件时下拉刷新可能让 list 排队超时，贸然重建会把正在跑的传输打断。
  bool _stuck = false;

  bool get isStuck => _stuck;

  /// 大文件按体积放宽传输超时。
  ///
  /// 固定的 30 分钟是按小文件定的：手机走中继时约 1MB/s，600MB 就要
  /// 10 分钟以上，2GB 必然被超时打断。按最差 **256 KB/s** 估算并加 5 分钟
  /// 建连/校验余量，上限 6 小时；小任务仍保持 30 分钟，避免卡死时干等。
  Duration _transferTimeoutFor(int totalBytes) {
    if (totalBytes <= 0) return transferTimeout;
    const maxLimit = Duration(hours: 6);
    final estimate =
        Duration(seconds: totalBytes ~/ (256 * 1024)) +
        const Duration(minutes: 5);
    if (estimate <= transferTimeout) return transferTimeout;
    return estimate > maxLimit ? maxLimit : estimate;
  }

  /// worker 是否已就绪。
  bool get isRunning => _tx != null;

  /// 启动 worker 并加载动态库。重复调用是安全的（幂等）。
  ///
  /// [libraryPath] 为 null 时使用平台默认库名（Android 为 `libnetdisk_ffi.so`，
  /// 由 APK 的 `jniLibs` 提供）。
  Future<void> start({String? libraryPath}) async {
    if (_disposed) throw NetdiskWorkerException('worker 已关闭');
    if (_stuck) {
      throw NetdiskWorkerException('后台线程无响应，请重新连接');
    }
    if (_tx != null) return;

    final ready = Completer<void>();

    _rx.listen((Object? msg) {
      // worker 启动完毕，回传自己的命令端口。
      if (msg is List && msg.length >= 2 && msg[0] == 'ready') {
        _tx = msg[1] as SendPort;
        if (!ready.isCompleted) ready.complete();
        return;
      }
      // 命令结果：[ 'res', id, payload, error ]
      if (msg is List && msg.length >= 4 && msg[0] == 'res') {
        final id = msg[1] as int;
        final completer = _pending.remove(id);
        _ops.remove(id);
        if (completer == null) return; // 已超时或已丢弃
        final err = msg[3] as String?;
        if (err != null) {
          completer.completeError(NetdiskWorkerException(err));
          return;
        }
        final payload = msg[2];
        if (payload is Map) {
          completer.complete(Map<String, dynamic>.from(payload));
        } else if (payload is String) {
          // serde 把无字段枚举序列化成裸字符串（Pong / Ready）。
          completer.complete(<String, dynamic>{payload: null});
        } else {
          completer.complete(<String, dynamic>{
            'Error': 'unexpected payload: $payload',
          });
        }
        return;
      }
      // isolate 未捕获异常：[ error, stackTrace ]
      if (msg is List && msg.isNotEmpty && msg[0] is! String) {
        _failAll('后台 isolate 异常: ${msg[0]}');
        return;
      }
      // isolate 退出（onExit 发 null）。
      if (msg == null) {
        _failAll('后台 isolate 已退出');
      }
    });

    _isolate = await Isolate.spawn<List<Object?>>(
      _workerMain,
      <Object?>[_rx.sendPort, libraryPath],
      onError: _rx.sendPort,
      onExit: _rx.sendPort,
      debugName: 'netdisk-ffi-worker',
    );

    // 首次加载 .so 可能稍慢，这里给足时间。
    await ready.future.timeout(
      const Duration(seconds: 30),
      onTimeout: () => throw NetdiskWorkerException('后台 isolate 启动超时'),
    );
  }

  /// 读取动态库的能力标记。旧库没有该符号，返回 null。
  ///
  /// UI 用它做一次前置校验：如果 `.so` 太旧（例如不认识 `n0`），
  /// 就能在连接前给出「请重新交叉编译」的明确提示，而不是抛一个看不懂的解析错误。
  Future<String?> version() async {
    if (!isRunning) await start();
    // 本地查符号，不碰网络；worker 正忙时排队超时不该判成链路卡死。
    final res = await _call('version', poisonOnTimeout: false);
    return res['Version'] as String?;
  }

  /// 当前连接的传输路径；未连接、后台线程不可用或动态库不支持时返回 null。
  ///
  /// 注意：这个值只反映**本地缓存的 QUIC 连接**的路径观测，不发请求、也不
  /// 探测对端是否还活着，所以它不能用来判断「服务端能不能响应 RPC」。
  Future<({String desc, bool direct})?> paths() async {
    if (!isRunning || _stuck) return null;
    try {
      final res = await _call(
        'paths',
        timeLimit: const Duration(seconds: 5),
        poisonOnTimeout: false,
      );
      final p = res['Paths'];
      if (p is! Map) return null;
      return (
        desc: (p['desc'] as String?) ?? '',
        direct: (p['direct'] as bool?) ?? false,
      );
    } catch (_) {
      return null;
    }
  }

  /// 在 worker 内创建 endpoint。失败抛 [NetdiskWorkerException]。
  Future<void> init(String relayUrl, String token, String serverAddr) async {
    if (!isRunning) await start();
    final res = await _call(
      'init',
      args: <Object?>[relayUrl, token, serverAddr],
    );
    if (res['Error'] != null) {
      throw NetdiskWorkerException(res['Error'].toString());
    }
  }

  /// 探活。默认只试一次：心跳失败就是失败，再重试只会占着 RPC 通道。
  Future<Map<String, dynamic>> ping({
    void Function(int attempt)? onAttempt,
    int maxAttempts = 1,
  }) => _retry(
    'ping',
    const <Object?>[],
    maxAttempts: maxAttempts,
    onAttempt: onAttempt,
  );

  /// 列出服务端文件。失败抛异常。
  ///
  /// 家宽 → 港服这条链路存在间歇性丢包（架构 R14），单次 connect 常直接超时，
  /// 因此这里默认重试，和 `netdisk-cli` 的行为保持一致。
  Future<List<({String path, int size, bool isDir})>> list({
    void Function(int attempt)? onAttempt,
    Duration? timeLimit,
    int maxAttempts = 3,
  }) async {
    final res = await _retry(
      'list',
      const <Object?>[],
      onAttempt: onAttempt,
      timeLimit: timeLimit,
      maxAttempts: maxAttempts,
    );
    return parseEntries(res);
  }

  /// 上传本地文件到 [remote]。返回原始响应（Stored 或 Error）。
  ///
  /// [onProgress] 会被周期调用（约 250ms 一次，传已发送字节数与总字节数）。
  /// 回调在主 isolate 上执行，读取的是 Rust 写入的共享内存计数器，不受 worker 阻塞影响。
  Future<Map<String, dynamic>> put(
    String remote,
    String local, {
    void Function(int sent, int total)? onProgress,
    int totalBytes = 0,
    void Function(int attempt)? onAttempt,
  }) async {
    final tracker = _ProgressTracker(onProgress, totalBytes);
    try {
      return await _retry(
        'put',
        <Object?>[remote, local, tracker.addr],
        timeLimit: _transferTimeoutFor(totalBytes),
        maxAttempts: 2,
        onAttempt: onAttempt,
      );
    } finally {
      tracker.dispose();
    }
  }

  /// 下载 [remote] 到本地 [local]。返回原始响应（Downloaded 或 Error）。
  Future<Map<String, dynamic>> get(
    String remote,
    String local, {
    void Function(int sent, int total)? onProgress,
    int totalBytes = 0,
    Duration? timeLimit,
    void Function(int attempt)? onAttempt,
  }) async {
    final tracker = _ProgressTracker(onProgress, totalBytes);
    try {
      return await _retry(
        'get',
        <Object?>[remote, local, tracker.addr],
        // 预览这类「看一眼」的操作不该按大文件传输给 30 分钟，
        // 否则服务端一卡就是无限转圈。
        timeLimit: timeLimit ?? _transferTimeoutFor(totalBytes),
        maxAttempts: 2,
        onAttempt: onAttempt,
      );
    } finally {
      tracker.dispose();
    }
  }

  /// 删除文件（服务端移入回收站）。返回 `{"Deleted":{path,trash}}`。
  ///
  /// 只重试 2 次：第一次可能已经删成功但响应在丢包中丢了，第二次会报
  /// `not found` —— 那其实是成功，UI 刷新后文件消失即可，不必当失败处理。
  Future<Map<String, dynamic>> delete(
    String path, {
    void Function(int attempt)? onAttempt,
  }) => _retry('delete', <Object?>[path], maxAttempts: 2, onAttempt: onAttempt);

  /// 重命名 / 移动。目标已存在时服务端返回错误（不覆盖）。
  Future<Map<String, dynamic>> rename(
    String from,
    String to, {
    void Function(int attempt)? onAttempt,
  }) => _retry(
    'rename',
    <Object?>[from, to],
    maxAttempts: 2,
    onAttempt: onAttempt,
  );

  /// 复制文件（服务端本地复制）。
  Future<Map<String, dynamic>> copy(
    String from,
    String to, {
    void Function(int attempt)? onAttempt,
  }) =>
      _retry('copy', <Object?>[from, to], maxAttempts: 2, onAttempt: onAttempt);

  /// 新建目录（支持多级）。
  Future<Map<String, dynamic>> mkdir(
    String path, {
    void Function(int attempt)? onAttempt,
  }) => _retry('mkdir', <Object?>[path], maxAttempts: 2, onAttempt: onAttempt);

  /// 删除空目录。目录里的文件需要先逐个 [delete]（进回收站）。
  ///
  /// 同样只重试 2 次：第一次可能已删成功但响应丢了，第二次会报 `not found`，
  /// 那是成功，不必当失败。
  Future<Map<String, dynamic>> rmdir(
    String path, {
    void Function(int attempt)? onAttempt,
  }) => _retry('rmdir', <Object?>[path], maxAttempts: 2, onAttempt: onAttempt);

  /// 只对「链路类」错误重试（超时 / 连接失败）。
  ///
  /// token 被拒、路径不存在、hash 不一致这类确定性错误重试只会浪费时间，
  /// 直接抛出。
  static bool _isTransient(Object error) {
    if (error is TimeoutException) return true;
    final text = error.toString().toLowerCase();
    return text.contains('timed out') ||
        text.contains('timeout') ||
        // _call 把 TimeoutException 转成了中文消息，别漏判（否则短超时后不重试）。
        text.contains('超时') ||
        text.contains('丢包') ||
        text.contains('connection') ||
        text.contains('reset') ||
        text.contains('unreachable');
  }

  Future<Map<String, dynamic>> _retry(
    String op,
    List<Object?> args, {
    int maxAttempts = 3,
    Duration? timeLimit,
    void Function(int attempt)? onAttempt,
  }) async {
    Object? lastError;
    for (var attempt = 1; attempt <= maxAttempts; attempt++) {
      onAttempt?.call(attempt);
      try {
        final res = await _call(op, args: args, timeLimit: timeLimit);
        final err = res['Error'];
        if (err != null) {
          throw NetdiskWorkerException(err.toString());
        }
        return res;
      } catch (e) {
        lastError = e;
        if (attempt >= maxAttempts || !_isTransient(e)) {
          rethrow;
        }
        // 退避：1s、2s（R14 是间歇性丢包，等一下往往就通了）。
        await Future<void>.delayed(Duration(seconds: attempt));
      }
    }
    throw NetdiskWorkerException('$lastError');
  }

  /// 释放 worker 内的 endpoint 句柄，但保留 isolate 以便再次 init。
  ///
  /// 必须在每次 `init` 前调用：同一进程里留下两个同身份的 iroh endpoint，
  /// 新 endpoint 的 relay 注册/连接会互相干扰，重连会一直失败。
  Future<void> closeConnection({
    Duration timeLimit = const Duration(seconds: 8),
  }) async {
    if (!isRunning) return;
    try {
      await _call('close', timeLimit: timeLimit);
    } catch (_) {
      // 关闭失败不影响后续重建；超时会把 worker 标记成卡死，交给上层换 isolate。
    }
  }

  /// 停掉 worker isolate并清理所有挂起请求。
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
    _tx = null;
    _failAll('worker 已关闭');
    _rx.close();
  }

  Future<Map<String, dynamic>> _call(
    String op, {
    List<Object?> args = const <Object?>[],
    Duration? timeLimit,
    bool poisonOnTimeout = true,
  }) async {
    if (_stuck) {
      // 旧 isolate 里还挂着一条取消不了的 FFI 调用，再发命令只会排队。
      throw NetdiskWorkerException('后台线程无响应，请重新连接');
    }
    final tx = _tx;
    if (tx == null) {
      throw NetdiskWorkerException('后台 isolate 未启动，请先调用 start()');
    }
    final id = ++_seq;
    final completer = Completer<Map<String, dynamic>>();
    _pending[id] = completer;
    _ops[id] = op;
    tx.send(<Object?>[id, op, ...args]);

    final limit = timeLimit ?? timeout;
    try {
      return await completer.future.timeout(limit);
    } on TimeoutException {
      _pending.remove(id);
      final pendingOp = _ops.remove(id);
      // native 调用无法取消，这个 isolate 后面只会一直堵着。标记后由
      // AppState 重新连接时换掉；查询类调用（version/paths）不标记，
      // 避免「传文件时 worker 忙」被误判成链路卡死。
      if (poisonOnTimeout) _stuck = true;
      throw NetdiskWorkerException(
        '$pendingOp timeout / 超时（${limit.inSeconds}s）：服务端无响应，'
        '${poisonOnTimeout ? '后台线程已隔离，请重新连接' : '可能是链路丢包，请重试'}',
      );
    }
  }

  void _failAll(String reason) {
    final pending = Map<int, Completer<Map<String, dynamic>>>.from(_pending);
    _pending.clear();
    _ops.clear();
    for (final c in pending.values) {
      if (!c.isCompleted) {
        c.completeError(NetdiskWorkerException(reason));
      }
    }
  }
}

/// worker isolate 入口。必须是顶层函数。
void _workerMain(List<Object?> boot) {
  final tx = boot[0] as SendPort;
  final libraryPath = boot[1] as String?;
  final rx = ReceivePort();

  NetdiskClient? client;

  tx.send(<Object?>['ready', rx.sendPort]);

  rx.listen((Object? msg) {
    if (msg is! List || msg.length < 2) return;
    final id = msg[0] as int;
    final op = msg[1] as String;

    Map<String, dynamic>? payload;
    String? error;
    try {
      switch (op) {
        case 'version':
          // 旧库没有该符号，version() 返回 null；这里不视为错误。
          client ??= NetdiskClient(libraryPath: libraryPath);
          payload = <String, dynamic>{'Version': client!.version()};
        case 'paths':
          final p = _require(client).paths();
          payload = <String, dynamic>{
            'Paths': p == null
                ? null
                : <String, dynamic>{'desc': p.desc, 'direct': p.direct},
          };
        case 'init':
          client ??= NetdiskClient(libraryPath: libraryPath);
          // 重复 init 时先释放旧句柄，避免泄漏（close 是幂等的）。
          client!.close();
          final err = client!.connect(
            msg[2] as String,
            msg[3] as String,
            msg[4] as String,
          );
          if (err != null) throw NetdiskWorkerException(err);
          payload = <String, dynamic>{'Ready': null};
        case 'close':
          client?.close();
          client = null;
          payload = <String, dynamic>{'Ready': null};
        case 'ping':
          payload = _require(client).ping();
        case 'list':
          payload = _require(client).listFiles();
        case 'put':
          payload = _require(client).putWithProgress(
            msg[2] as String,
            msg[3] as String,
            _ptrOrNull(msg[4] as int?),
          );
        case 'get':
          payload = _require(client).getWithProgress(
            msg[2] as String,
            msg[3] as String,
            _ptrOrNull(msg[4] as int?),
          );
        case 'delete':
          payload = _require(client).delete(msg[2] as String);
        case 'rename':
          payload = _require(client).rename(msg[2] as String, msg[3] as String);
        case 'copy':
          payload = _require(client).copy(msg[2] as String, msg[3] as String);
        case 'mkdir':
          payload = _require(client).mkdir(msg[2] as String);
        case 'rmdir':
          payload = _require(client).rmdir(msg[2] as String);
        default:
          throw NetdiskWorkerException('unknown op: $op');
      }
    } catch (e) {
      error = e.toString();
    }
    tx.send(<Object?>['res', id, payload, error]);
  });
}

/// 传输进度跟踪器。
///
/// 分配一块 `u64` 交给 Rust 写「已传输字节数」，自己用定时器读取并回调。
/// 关键点：内存由主 isolate 分配/释放，只有地址传入 worker —— 生命周期可控，
/// 不会出现 worker 已 free、主 isolate 还在读的悬空指针。
class _ProgressTracker {
  _ProgressTracker(this._sink, this._total) {
    final sink = _sink;
    if (sink == null) return;
    final buf = malloc<Uint64>(1);
    buf.value = 0;
    _buf = buf;
    final view = buf.asTypedList(1);
    _timer = Timer.periodic(const Duration(milliseconds: 250), (_) {
      sink(view[0], _total);
    });
  }

  final void Function(int sent, int total)? _sink;
  final int _total;
  Pointer<Uint64>? _buf;
  Timer? _timer;

  /// `0` 表示本次调用不需要进度。
  int get addr => _buf?.address ?? 0;

  void dispose() {
    _timer?.cancel();
    _timer = null;
    final buf = _buf;
    if (buf != null) {
      malloc.free(buf);
      _buf = null;
    }
  }
}

NetdiskClient _require(NetdiskClient? client) {
  if (client == null) {
    throw NetdiskWorkerException('未连接：请先调用 init()');
  }
  return client;
}

/// 进度计数器地址 → 指针。`0` / null 表示这次调用不需要进度。
///
/// 内存由**主 isolate** 分配和释放（`malloc<Uint64>(1)`），只把地址传进 worker。
/// 这样生命周期由调用方掌握，避免 worker 提前 free 而主 isolate 还在轮询。
Pointer<Uint64> _ptrOrNull(int? addr) =>
    (addr == null || addr == 0) ? nullptr : Pointer<Uint64>.fromAddress(addr);
