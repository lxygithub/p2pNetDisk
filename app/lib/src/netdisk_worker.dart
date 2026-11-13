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
import 'dart:isolate';

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

  /// worker 是否已就绪。
  bool get isRunning => _tx != null;

  /// 启动 worker 并加载动态库。重复调用是安全的（幂等）。
  ///
  /// [libraryPath] 为 null 时使用平台默认库名（Android 为 `libnetdisk_ffi.so`，
  /// 由 APK 的 `jniLibs` 提供）。
  Future<void> start({String? libraryPath}) async {
    if (_disposed) throw NetdiskWorkerException('worker 已关闭');
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
          completer.complete(<String, dynamic>{'Error': 'unexpected payload: $payload'});
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
    final res = await _call('version');
    return res['Version'] as String?;
  }

  /// 当前连接的传输路径；未连接或动态库不支持时返回 null。
  Future<({String desc, bool direct})?> paths() async {
    if (!isRunning) return null;
    final res = await _call('paths');
    final p = res['Paths'];
    if (p is! Map) return null;
    return (
      desc: (p['desc'] as String?) ?? '',
      direct: (p['direct'] as bool?) ?? false,
    );
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

  Future<Map<String, dynamic>> ping({void Function(int attempt)? onAttempt}) =>
      _retry('ping', const <Object?>[], onAttempt: onAttempt);

  /// 列出服务端文件。失败抛异常。
  ///
  /// 家宽 → 港服这条链路存在间歇性丢包（架构 R14），单次 connect 常直接超时，
  /// 因此这里默认重试，和 `netdisk-cli` 的行为保持一致。
  Future<List<({String path, int size})>> list({
    void Function(int attempt)? onAttempt,
  }) async {
    final res = await _retry('list', const <Object?>[], onAttempt: onAttempt);
    return parseEntries(res);
  }

  /// 上传本地文件到 [remote]。返回原始响应（Stored 或 Error）。
  Future<Map<String, dynamic>> put(
    String remote,
    String local, {
    void Function(int attempt)? onAttempt,
  }) =>
      _retry(
        'put',
        <Object?>[remote, local],
        timeLimit: transferTimeout,
        maxAttempts: 2,
        onAttempt: onAttempt,
      );

  /// 下载 [remote] 到本地 [local]。返回原始响应（Downloaded 或 Error）。
  Future<Map<String, dynamic>> get(
    String remote,
    String local, {
    void Function(int attempt)? onAttempt,
  }) =>
      _retry(
        'get',
        <Object?>[remote, local],
        timeLimit: transferTimeout,
        maxAttempts: 2,
        onAttempt: onAttempt,
      );

  /// 只对「链路类」错误重试（超时 / 连接失败）。
  ///
  /// token 被拒、路径不存在、hash 不一致这些是确定性错误，重试只会浪费时间，
  /// 所以直接抛出。
  static bool _isTransient(Object error) {
    if (error is TimeoutException) return true;
    final text = error.toString().toLowerCase();
    return text.contains('timed out') ||
        text.contains('timeout') ||
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
  Future<void> closeConnection() async {
    if (!isRunning) return;
    try {
      await _call('close');
    } catch (_) {
      // 关闭失败不影响后续重建。
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
  }) async {
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
      throw NetdiskWorkerException(
        '$pendingOp 超时（${limit.inSeconds}s）：服务端无响应，'
        '可能是链路丢包，请重试',
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
          payload = _require(client).put(msg[2] as String, msg[3] as String);
        case 'get':
          payload = _require(client).get(msg[2] as String, msg[3] as String);
        default:
          throw NetdiskWorkerException('unknown op: $op');
      }
    } catch (e) {
      error = e.toString();
    }
    tx.send(<Object?>['res', id, payload, error]);
  });
}

NetdiskClient _require(NetdiskClient? client) {
  if (client == null) {
    throw NetdiskWorkerException('未连接：请先调用 init()');
  }
  return client;
}
