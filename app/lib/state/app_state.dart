import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/transfer_task.dart';
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

  /// 「直连 · 8 ms」/「中继 · 1.2 s」，未连接或旧库不支持时为 null。
  String? pathSummary;

  // ---- 文件浏览 ----
  List<({String path, int size})> files = [];

  /// 当前目录，空串表示根，否则以 `/` 结尾。
  String cwd = '';

  // ---- 传输队列 ----
  final List<TransferTask> tasks = [];
  int _nextTaskId = 1;
  bool _pumping = false;

  int get activeCount => tasks
      .where((t) =>
          t.status == TransferStatus.queued ||
          t.status == TransferStatus.running)
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
  List<({String name, bool isDir, int size, String path})> get entries {
    final fileItems = <({String name, bool isDir, int size, String path})>[];
    final dirNames = <String>{};

    for (final f in files) {
      if (!f.path.startsWith(cwd)) continue;
      final rest = f.path.substring(cwd.length);
      if (rest.isEmpty) continue;
      final slash = rest.indexOf('/');
      if (slash < 0) {
        fileItems.add((name: rest, isDir: false, size: f.size, path: f.path));
      } else {
        dirNames.add(rest.substring(0, slash));
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
      if (!silent) status = '刷新失败: $e';
    } finally {
      if (!silent) busy = false;
      notifyListeners();
    }
    await _updatePath();
    // 打洞要几秒才完成，稍后再读一次路径让「中继」能变成「直连」。
    Future<void>.delayed(const Duration(seconds: 4), _updatePath);
  }

  /// 读取当前连接路径，压成「直连 · 8 ms」这种短文本。
  Future<void> _updatePath() async {
    final info = await _worker.paths();
    if (info == null) return;
    final m =
        RegExp(r'(direct|relay)\*\s+(\S+)\s+rtt=(\d+)ms').firstMatch(info.desc);
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

  /// 串行消费队列。
  ///
  /// 不并发是有意的：FFI 句柄内部只有一条 QUIC 连接和一个 Mutex，
  /// 同时发多个 put/get 只会在锁上互相等待，还会把进度回调搅乱。
  Future<void> _pump() async {
    if (_pumping) return;
    _pumping = true;
    var anyDone = false;
    try {
      while (true) {
        TransferTask? task;
        for (final t in tasks) {
          if (t.status == TransferStatus.queued) {
            task = t;
            break;
          }
        }
        if (task == null) break;

        task.status = TransferStatus.running;
        task.startedAt = DateTime.now();
        task.meter.reset();
        notifyListeners();

        try {
          void onProgress(int sent, int total) {
            task!.sent = sent;
            task.speed = task.meter.sample(sent);
            notifyListeners();
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

          task.sent = task.total;
          task.status = TransferStatus.done;
          anyDone = true;
        } catch (e) {
          task.status = TransferStatus.failed;
          task.error = '$e';
        } finally {
          task.finishedAt = DateTime.now();
          task.speed = 0;
          notifyListeners();
        }
      }
    } finally {
      _pumping = false;
    }
    if (anyDone) await refresh(silent: true);
  }

  /// 清掉已完成/失败的任务，保留进行中的。
  void clearFinishedTasks() {
    tasks.removeWhere((t) =>
        t.status == TransferStatus.done || t.status == TransferStatus.failed);
    notifyListeners();
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
