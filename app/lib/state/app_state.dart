import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/transfer_task.dart';
import '../services/transfer_notifications.dart';
import '../src/netdisk_worker.dart';

/// 默认走 n0 官方公共 relay（实测 aps1-1/euc1-1 握手 8/8，自建港服仅 2/8）。
const kDefaultRelay = 'n0';

/// 常驻服务的固定身份。n0 模式经 dns.iroh.link 解析出完整地址（含 relay），
/// 所以这里只需要 EndpointId，服务端换 relay 也不用改。
const kDefaultAddr =
    '{"id":"YOUR_ENDPOINT_ID",'
    '"addrs":[]}';

/// 应用级状态：连接、文件浏览、传输队列。
///
/// 之前所有逻辑都堆在一个 StatefulWidget 的 State 里，页面一多就没法共享
/// （比如传输页要看队列、文件页要看连接态）。这里统一收进 ChangeNotifier，
/// 页面通过 provider 订阅。
class AppState extends ChangeNotifier {
  final NetdiskWorker _worker = NetdiskWorker();

  // ---- 连接配置 ----
  String relay = kDefaultRelay;
  String token = '';
  String serverAddr = kDefaultAddr;

  // ---- 连接状态 ----
  bool connected = false;
  bool busy = false;
  String status = '未连接';
  bool _booting = false;

  /// 启动时的自动初始化：连接 → 拉列表。
  ///
  /// 冷启动时网络、DNS、relay 都可能还没就绪，直接把「连接失败」甩给用户很糟。
  /// 所以失败后按 2s / 4s 退避重试，三次都失败才停在错误态，此时仍可手动重试。
  Future<void> bootstrap() async {
    if (_booting) return;
    _booting = true;
    try {
      // Android 13+ 需要运行时授权才能发通知；拒绝也不影响传输本身。
      await TransferNotifications.ensurePermission();
      for (var attempt = 1; attempt <= 3; attempt++) {
        await connect();
        if (connected) {
          await refresh();
          return;
        }
        if (attempt < 3) {
          final wait = Duration(seconds: attempt * 2);
          status = '连接失败，${wait.inSeconds} 秒后重试（$attempt/3）…';
          notifyListeners();
          await Future<void>.delayed(wait);
        }
      }
    } finally {
      _booting = false;
    }
  }

  /// 「直连 · 8 ms」/「中继 · 1.2 s」，未连接或旧库不支持时为 null。
  String? pathSummary;

  // ---- 文件浏览 ----
  List<({String path, int size, bool isDir})> files = [];

  /// 当前目录，空串表示根，否则以 `/` 结尾。
  String cwd = '';

  // ---- 传输队列 ----
  final List<TransferTask> tasks = [];
  int _nextTaskId = 1;
  bool _pumping = false;

  int get activeCount => tasks
      .where(
        (t) =>
            t.status == TransferStatus.queued ||
            t.status == TransferStatus.running,
      )
      .length;

  int get failedCount =>
      tasks.where((t) => t.status == TransferStatus.failed).length;

  // ---------------------------------------------------------------------------
  // 连接
  // ---------------------------------------------------------------------------

  Future<void> connect() async {
    busy = true;
    status = '正在启动后台线程…';
    notifyListeners();
    try {
      await _worker.start(libraryPath: Platform.environment['NETDISK_FFI_DLL']);

      // 前置校验：确认打包进 APK 的 .so 与当前 UI 版本匹配。
      final ver = await _worker.version();
      if (ver == null || !ver.contains('n0')) {
        status = '动态库过旧（不支持 n0）：请重新交叉编译 .so 后再打 APK';
        return;
      }

      status = '正在建立 endpoint…';
      notifyListeners();
      await _worker.init(relay, token, serverAddr);
      connected = true;
      status = '已连接';
    } catch (e) {
      connected = false;
      status = '连接失败: $e';
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  // ---------------------------------------------------------------------------
  // 文件浏览
  // ---------------------------------------------------------------------------

  /// 当前目录下的直接子项：目录在前、文件在后，各自按名称排序。
  ///
  /// 目录名有两个来源：服务端显式返回的目录项（能覆盖空目录），
  /// 以及从文件路径里推断出的父目录（兼容不返回目录项的旧服务端）。
  List<({String name, bool isDir, int size, String path})> get entries {
    final fileItems = <({String name, bool isDir, int size, String path})>[];
    final dirNames = <String>{};

    for (final f in files) {
      if (!f.path.startsWith(cwd)) continue;
      final rest = f.path.substring(cwd.length);
      if (rest.isEmpty) continue;
      final slash = rest.indexOf('/');
      if (slash >= 0) {
        dirNames.add(rest.substring(0, slash));
      } else if (f.isDir) {
        dirNames.add(rest);
      } else {
        fileItems.add((name: rest, isDir: false, size: f.size, path: f.path));
      }
    }

    final dirs = dirNames.toList()..sort();
    fileItems.sort((a, b) => a.name.compareTo(b.name));
    return [
      for (final d in dirs) (name: d, isDir: true, size: 0, path: '$cwd$d/'),
      ...fileItems,
    ];
  }

  /// 面包屑各段，根目录返回空列表。
  List<String> get cwdParts =>
      cwd.split('/').where((e) => e.isNotEmpty).toList();

  void enterDir(String name) {
    cwd = '$cwd$name/';
    notifyListeners();
  }

  void goUp() {
    if (cwd.isEmpty) return;
    final trimmed = cwd.substring(0, cwd.length - 1);
    final idx = trimmed.lastIndexOf('/');
    cwd = idx < 0 ? '' : trimmed.substring(0, idx + 1);
    notifyListeners();
  }

  void goToDepth(int depth) {
    final parts = cwdParts.take(depth).join('/');
    cwd = parts.isEmpty ? '' : '$parts/';
    notifyListeners();
  }

  Future<void> refresh({bool silent = false}) async {
    if (!connected) {
      status = '请先连接';
      notifyListeners();
      return;
    }
    if (!silent) {
      busy = true;
      status = '正在拉取列表…';
      notifyListeners();
    }
    try {
      final list = await _worker.list(
        onAttempt: (n) {
          if (n > 1) {
            status = '链路超时，第 $n 次重试…';
            notifyListeners();
          }
        },
      );
      files = list;
      // 当前目录可能已被删除/重命名，退回根目录避免停在空视图。
      if (cwd.isNotEmpty && !files.any((f) => f.path.startsWith(cwd))) {
        cwd = '';
      }
      if (!silent) status = '共 ${files.length} 个文件';
    } catch (e) {
      // 链路类错误视为掉线：置为未连接，UI 会给出「重试」，下拉也能重连。
      // 否则 connected 一直是 true，用户看到的是「已连接但什么都刷不出来」。
      if (_looksOffline(e)) {
        connected = false;
        status = '连接已断开，下拉或点「重试」重新连接';
      } else if (!silent) {
        status = '刷新失败: $e';
      }
    } finally {
      if (!silent) busy = false;
      notifyListeners();
    }
    await _updatePath();
    // 打洞要几秒才完成，稍后再读一次路径让「中继」能变成「直连」。
    Future<void>.delayed(const Duration(seconds: 4), _updatePath);
  }

  /// 粗判是否为链路类错误。与 worker 内部的重试判断保持一致的取向：
  /// 宁可多给一次重连机会，也不要把「超时」当成业务失败。
  static bool _looksOffline(Object e) {
    final t = e.toString().toLowerCase();
    return t.contains('timed out') ||
        t.contains('timeout') ||
        t.contains('connection') ||
        t.contains('unreachable') ||
        t.contains('reset') ||
        t.contains('broken pipe');
  }

  /// 读取当前连接路径，压成「直连 · 8 ms」这种短文本。
  Future<void> _updatePath() async {
    final info = await _worker.paths();
    if (info == null) return;
    final m = RegExp(
      r'(direct|relay)\*\s+(\S+)\s+rtt=(\d+)ms',
    ).firstMatch(info.desc);
    pathSummary = m == null
        ? (info.direct ? '直连' : '中继')
        : '${m.group(1) == 'direct' ? '直连' : '中继'} · ${m.group(3)} ms';
    notifyListeners();
  }

  // ---------------------------------------------------------------------------
  // 传输队列（串行）
  // ---------------------------------------------------------------------------

  Future<void> enqueueUploads(
    List<({String name, String path, int size})> picked,
  ) async {
    if (!connected) {
      status = '请先连接';
      notifyListeners();
      return;
    }
    for (final f in picked) {
      tasks.add(
        TransferTask(
          id: _nextTaskId++,
          kind: TransferKind.upload,
          remote: '$cwd${f.name}',
          local: f.path,
          total: f.size,
        ),
      );
    }
    notifyListeners();
    await _pump();
  }

  Future<void> enqueueDownload(String remote, int size) async {
    if (!connected) {
      status = '请先连接';
      notifyListeners();
      return;
    }
    final dir = await getApplicationDocumentsDirectory();
    final local = p.join(dir.path, 'downloads', p.basename(remote));
    await Directory(p.dirname(local)).create(recursive: true);

    tasks.add(
      TransferTask(
        id: _nextTaskId++,
        kind: TransferKind.download,
        remote: remote,
        local: local,
        total: size,
      ),
    );
    notifyListeners();
    await _pump();
  }

  /// 最大并发传输数。
  ///
  /// iroh 的一条 QUIC 连接支持多流并发，Rust 侧 `connection()` 用双检锁保证
  /// 只会建一条连接，所以多个 put/get 可以真正并行。上限设 5 是为了避免
  /// 手机网络下过多流互相挤占带宽，反而让每个任务都变慢。
  static const int maxConcurrency = 5;

  int _running = 0;
  bool _anyDone = false;

  /// 消费队列：最多同时跑 [maxConcurrency] 个，其余保持 queued。
  ///
  /// 用轮询而不是 Completer 池，是因为任务的完成时间不固定，
  /// 60ms 的调度间隔对 UI 完全无感，代码却简单得多。
  Future<void> _pump() async {
    if (_pumping) return;
    _pumping = true;
    try {
      while (true) {
        TransferTask? next;
        for (final t in tasks) {
          if (t.status == TransferStatus.queued) {
            next = t;
            break;
          }
        }
        if (next == null) break;

        if (_running >= maxConcurrency) {
          await Future<void>.delayed(const Duration(milliseconds: 60));
          continue;
        }
        _startTask(next);
      }

      // 等所有在途任务结束，再决定是否刷新列表。
      while (_running > 0) {
        await Future<void>.delayed(const Duration(milliseconds: 60));
      }
    } finally {
      _pumping = false;
    }

    if (_anyDone) {
      _anyDone = false;
      await refresh(silent: true);
    }
  }

  /// 启动单个任务（不等待完成，由调用方通过 `_running` 计数感知）。
  void _startTask(TransferTask task) {
    _running++;
    task
      ..status = TransferStatus.running
      ..startedAt = DateTime.now();
    task.meter.reset();
    notifyListeners();
    _notifyTransfers(force: true);

    unawaited(() async {
      try {
        void onProgress(int sent, int total) {
          task
            ..sent = sent
            ..speed = task.meter.sample(sent);
          notifyListeners();
          _notifyTransfers();
        }

        final Map<String, dynamic> res = task.kind == TransferKind.upload
            ? await _worker.put(
                task.remote,
                task.local,
                totalBytes: task.total,
                onProgress: onProgress,
              )
            : await _worker.get(
                task.remote,
                task.local,
                totalBytes: task.total,
                onProgress: onProgress,
              );

        final err = res['Error'];
        if (err != null) throw Exception(err);

        task
          ..sent = task.total
          ..status = TransferStatus.done;
        _anyDone = true;
      } catch (e) {
        task
          ..status = TransferStatus.failed
          ..error = '$e';
      } finally {
        task
          ..finishedAt = DateTime.now()
          ..speed = 0;
        _running--;
        notifyListeners();
        _notifyTransfers(force: true);
      }
    }());
  }

  /// 清掉已完成/失败的任务，保留进行中的。
  void clearFinishedTasks() {
    tasks.removeWhere(
      (t) =>
          t.status == TransferStatus.done || t.status == TransferStatus.failed,
    );
    notifyListeners();
  }

  /// 把整个队列的状态汇总成**一条**通知。
  ///
  /// 不按任务发多条：5 个并发会瞬间刷出 5 条通知，用户还得挨个清。
  /// 汇总成「进行中 2 · 排队 1（已完成 3/6）」反而一眼能看懂。
  void _notifyTransfers({bool force = false}) {
    final running = tasks
        .where((t) => t.status == TransferStatus.running)
        .length;
    final queued = tasks.where((t) => t.status == TransferStatus.queued).length;
    final done = tasks.where((t) => t.status == TransferStatus.done).length;
    final failed = tasks.where((t) => t.status == TransferStatus.failed).length;

    if (running + queued == 0) {
      if (done + failed == 0) {
        unawaited(TransferNotifications.cancel());
        return;
      }
      unawaited(
        TransferNotifications.show(
          title: failed == 0 ? '传输完成' : '部分传输失败',
          text: failed == 0 ? '$done 个文件已完成' : '$done 个完成，$failed 个失败',
          // 结束后不再显示进度条
          ongoing: false,
          force: true,
        ),
      );
      return;
    }

    final total = running + queued + done + failed;
    final finished = done + failed;
    final parts = <String>[
      if (running > 0) '进行中 $running',
      if (queued > 0) '排队 $queued',
    ];

    unawaited(
      TransferNotifications.show(
        title: '正在传输',
        text: '${parts.join(' · ')}（已完成 $finished/$total）',
        progress: total > 0 ? finished * 100 ~/ total : null,
        ongoing: true,
        force: force,
      ),
    );
  }

  void retryTask(TransferTask task) {
    if (task.status != TransferStatus.failed) return;
    task
      ..status = TransferStatus.queued
      ..sent = 0
      ..error = null
      ..speed = 0;
    task.meter.reset();
    notifyListeners();
    unawaited(_pump());
  }

  // ---------------------------------------------------------------------------
  // 删除 / 重命名
  // ---------------------------------------------------------------------------

  Future<void> deleteFile(String path) async {
    busy = true;
    status = '正在删除 $path …';
    notifyListeners();
    try {
      await _worker.delete(path);
      status = '已删除：$path（在服务端回收站）';
      await refresh(silent: true);
    } catch (e) {
      status = '删除失败: $e';
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  Future<void> renameFile(String from, String to) async {
    busy = true;
    status = '正在重命名为 $to …';
    notifyListeners();
    try {
      await _worker.rename(from, to);
      status = '已重命名：$from → $to';
      await refresh(silent: true);
    } catch (e) {
      status = '重命名失败: $e';
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  /// 复制文件：服务端本地 copy，数据不过网络。
  Future<void> copyFile(String from, String to) async {
    busy = true;
    status = '正在复制到 $to …';
    notifyListeners();
    try {
      await _worker.copy(from, to);
      status = '已复制：$from → $to';
      await refresh(silent: true);
    } catch (e) {
      status = '复制失败: $e';
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  /// 在当前目录下新建目录。返回是否成功。
  Future<bool> createDir(String name) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return false;

    busy = true;
    status = '正在创建目录 $trimmed …';
    notifyListeners();
    try {
      await _worker.mkdir('$cwd$trimmed');
      status = '已创建目录：$cwd$trimmed';
      await refresh(silent: true);
      return true;
    } catch (e) {
      status = '创建目录失败: $e';
      return false;
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  /// 把远程文件下载到临时目录，用于预览。返回本地路径。
  ///
  /// 预览是「用完即弃」的，所以落到 `getTemporaryDirectory()` 而不是 App 文档目录，
  /// 避免重复预览时占满用户空间（系统会自行回收）。
  Future<String> downloadForPreview(String remote) async {
    final dir = await getTemporaryDirectory();
    final local = p.join(dir.path, 'preview', p.basename(remote));
    await Directory(p.dirname(local)).create(recursive: true);

    final res = await _worker.get(remote, local);
    final err = res['Error'];
    if (err != null) throw Exception(err);
    return local;
  }

  void setStatus(String value) {
    status = value;
    notifyListeners();
  }

  @override
  void dispose() {
    _worker.dispose();
    super.dispose();
  }
}
