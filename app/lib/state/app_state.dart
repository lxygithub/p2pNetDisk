import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/transfer_task.dart';
import '../services/connection_prefs.dart';
import '../services/download_prefs.dart';
import '../services/endpoint_addr.dart';
import '../services/list_cache.dart';
import '../services/path_utils.dart';
import '../services/storage_access.dart';
import '../services/transfer_notifications.dart';
import '../services/transfer_store.dart';
import '../src/netdisk_worker.dart';

/// 默认走 n0 官方公共 relay（实测 aps1-1/euc1-1 握手 8/8，自建港服仅 2/8）。
const kDefaultRelay = 'n0';

/// 默认 EndpointId。公开仓库里**只放占位符**：n0 模式没有应用层鉴权，
/// 把真实 EndpointId 写进版本控制等于把网盘地址公开。
///
/// 私有部署用编译期注入，不必改源码（地址也不会进仓库）。只传纯 hex，
/// 不带 JSON 引号 —— PowerShell 传原生程序时会吃掉参数里的双引号：
/// ```bash
/// flutter build apk --debug --dart-define=NETDISK_ENDPOINT_ID=<你的 EndpointId>
/// ```
/// 不注入时可在设置页手填完整地址；改动会持久化到本机，重启后自动套用。
const kDefaultEndpointId = String.fromEnvironment(
  'NETDISK_ENDPOINT_ID',
  defaultValue: 'YOUR_ENDPOINT_ID',
);

/// n0 模式经 dns.iroh.link 解析出完整地址（含 relay），所以只需 EndpointId；
/// 服务端换 relay 也不用改。
const kDefaultAddr = '{"id":"$kDefaultEndpointId","addrs":[]}';

/// 应用级状态：连接、文件浏览、传输队列。
///
/// 之前所有逻辑都堆在一个 StatefulWidget 的 State 里，页面一多就没法共享
/// （比如传输页要看队列、文件页要看连接态）。这里统一收进 ChangeNotifier，
/// 页面通过 provider 订阅。
class AppState extends ChangeNotifier with WidgetsBindingObserver {
  /// [savedConfig] 在 runApp 之前由 main() 读入；页面构建时连接参数就已就位，
  /// 不会出现「设置页先显示占位符、随后又被异步覆盖」的竞态。
  AppState({ConnectionConfig? savedConfig}) {
    WidgetsBinding.instance.addObserver(this);
    if (savedConfig != null) {
      relay = savedConfig.relay;
      token = savedConfig.token;
      serverAddr = savedConfig.addr;
    }
  }

  /// 回到前台立刻探活一次：手机锁屏/切后台时连接可能已经断了，
  /// 不主动探活就会一直显示上一次的「直连」。
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      if (connected) {
        _startHeartbeat();
        unawaited(_probe());
      }
    } else if (state == AppLifecycleState.paused) {
      _stopHeartbeat();
      // 切后台立刻落盘：被系统杀掉时才有东西可恢复。
      unawaited(TransferStore.write(tasks));
    }
  }

  /// worker 里的 FFI 调用无法取消；一旦卡死，重新连接时会换成一个干净的
  /// isolate（见 [NetdiskWorker.isStuck]），所以这里不能是 final。
  NetdiskWorker _worker = NetdiskWorker();

  // ---- 连接配置 ----
  String relay = kDefaultRelay;
  String token = '';
  String serverAddr = kDefaultAddr;

  // ---- 连接状态 ----
  bool connected = false;
  bool busy = false;
  bool _booting = false;

  String _status = '未连接';

  /// 状态文本统一在这里脱敏：底层异常可能把 EndpointAddr / token 带上来，
  /// 直接显示等于把网盘地址印在界面上（还会进截图）。
  String get status => _status;

  set status(String value) {
    _status = scrubConnectionText(value, addr: serverAddr, token: token);
  }

  /// 界面上只展示打码后的 EndpointId。
  String get maskedEndpointId =>
      maskEndpointId(splitEndpointAddr(serverAddr).id);

  /// 是否至少填过非占位符的 EndpointId。
  bool get endpointConfigured {
    final id = splitEndpointAddr(serverAddr).id.trim();
    return id.isNotEmpty && id != 'YOUR_ENDPOINT_ID';
  }

  /// 当前显示的列表是否来自本地缓存（还没被真实列表替换）。
  bool showingCache = false;
  DateTime? cacheTime;

  /// 上一次列表 RPC 的耗时，状态栏里可见，便于观察首屏耗时。
  int? lastListMs;

  /// 进行中的刷新。bootstrap 自动刷新与用户下拉同时到达时复用同一个 Future，
  /// 避免 worker 串行排队让第二屏多等一整轮 RPC。
  Future<void>? _refreshFuture;

  /// 是否正在自动重建后台线程，防止并发触发多次重连。
  bool _recovering = false;

  /// 启动时的自动初始化：先渲染缓存列表 → 连接 → 后台拉新列表。
  ///
  /// 冷启动时网络、DNS、relay 都可能还没就绪，直接把「连接失败」甩给用户很糟。
  /// 所以失败后按 2s / 4s 退避重试，三次都失败才停在错误态，此时仍可手动重试。
  Future<void> bootstrap() async {
    if (_booting) return;
    _booting = true;
    try {
      // 通知权限请求与首屏无关，别把平台通道往返压在关键路径上。
      unawaited(TransferNotifications.ensurePermission());
      // 本地读快照通常 < 20ms，先让列表可见，再去等网络握手。
      await _restoreCache();
      // 传输队列也要恢复：重启后看不到上一次的任务会让人以为白传了。
      await _restoreTasks();
      for (var attempt = 1; attempt <= 3; attempt++) {
        await connect();
        if (connected) {
          await refresh(firstLoad: true);
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

  /// 用上一次成功拉取的快照填第一屏。按服务端地址的 hash 隔离，
  /// 换了一台服务端时不会错误地显示别人的文件列表。
  Future<void> _restoreCache() async {
    final snapshot = await ListCache.read(serverAddr.hashCode.toString());
    if (snapshot == null) return;
    files = snapshot.entries;
    showingCache = true;
    cacheTime = snapshot.savedAt;
    status = '显示上次列表，正在连接…';
    notifyListeners();
  }

  /// 「直连 · 8 ms」/「中继 · 1.2 s」，未连接或旧库不支持时为 null。
  String? pathSummary;

  /// 当前链路 RTT（毫秒），用于给徽标上色；null 表示未知（旧库 / 未连接）。
  int? pathLatencyMs;

  /// 最近一次**列表 RPC** 是否成功。与 QUIC 路径观测分开：
  /// 「已连接 / 直连」只说明建过连接，不等于服务端还能响应请求。
  /// 只有它为真时才显示 [pathSummary]，避免半死连接留下误导性的「直连」。
  bool rpcHealthy = false;

  // ---- 文件浏览 ----
  List<({String path, int size, bool isDir})> files = [];

  /// 当前目录，空串表示根，否则以 `/` 结尾。
  String cwd = '';

  // ---- 下载位置 ----
  String _downloadRoot = '';

  /// 是否已获得公共目录写权限（Android 11+ 的「所有文件访问」）。
  ///
  /// 为 false 时默认下载位置会退到 App 专属目录，卸载 App 会连带删掉文件，
  /// 设置页据此给出授权引导。
  bool publicStorageGranted = false;

  /// 当前下载根目录。空串表示还没初始化，调用方应先 await [ensureDownloadRoot]。
  String get downloadRoot => _downloadRoot;

  /// 只有 Android 存在公共目录权限问题，其他平台恒为 true（不影响 UI 分支）。
  bool get publicStorageSupported => Platform.isAndroid;

  /// 当前下载目录是否在卸载 App 后仍然保留。
  ///
  /// App 专属目录形如 `/storage/emulated/0/Android/data/<包名>/...`，卸载时会被
  /// 系统清掉；公共目录（Download）与 SD 卡路径会保留。
  bool get downloadRootSurvivesUninstall {
    final root = _downloadRoot.replaceAll('\\', '/');
    if (root.isEmpty) return false;
    return !root.contains('/Android/data/');
  }

  /// 取（必要时初始化）下载根目录，并确保目录存在。
  ///
  /// 优先用户自定义位置，其次公共「下载」目录（卸载保留），最后回退 App 专属
  /// 外部目录与系统临时目录 —— 保证下载入口不会因为拿不到路径直接报错。
  Future<String> ensureDownloadRoot() async {
    if (_downloadRoot.isNotEmpty) return _downloadRoot;
    if (Platform.isAndroid) {
      publicStorageGranted = await StorageAccess.hasPublicAccess();
    }
    try {
      final override = await DownloadPrefs.readOverride();
      // 旧版本的默认位置曾落在 App 专属目录（Android/data/...）。用户现在拿到了
      // 公共目录权限，就不能再沿用那条「卸载即删除」的路径，自动迁到新默认值。
      final appScoped =
          override?.replaceAll('\\', '/').contains('/Android/data/') ?? false;
      final migrate = override != null && appScoped && publicStorageGranted;
      if (override != null && !migrate) {
        _downloadRoot = override;
      } else {
        _downloadRoot = await DownloadPrefs.defaultRoot();
        if (migrate) await DownloadPrefs.saveOverride(_downloadRoot);
      }
    } catch (_) {
      try {
        final docs = await getApplicationDocumentsDirectory();
        _downloadRoot = p.join(docs.path, 'downloads');
      } catch (_) {
        _downloadRoot = p.join(Directory.systemTemp.path, 'p2pNetDisk');
      }
    }
    try {
      await Directory(_downloadRoot).create(recursive: true);
    } catch (_) {
      // 目录建不出来时保留路径，具体错误会在第一个任务里暴露。
    }
    return _downloadRoot;
  }

  /// 重新解析下载目录。用户从系统设置返回、权限状态可能已变化时调用。
  ///
  /// 自定义位置优先，所以这里不会把用户手动选的目录冲掉。
  Future<void> refreshDownloadRoot() async {
    _downloadRoot = '';
    await ensureDownloadRoot();
    notifyListeners();
  }

  /// 打开系统「所有文件访问」授权页。返回 false 表示设置页都打不开。
  Future<bool> requestPublicStorageAccess() async {
    final opened = await StorageAccess.requestPublicAccess();
    if (!opened) {
      status = '无法打开权限设置页，请在系统设置里手动授予「所有文件访问」';
      notifyListeners();
    }
    return opened;
  }

  /// 设置自定义下载位置。返回 false 表示目录不可写，原位置保持不变。
  Future<bool> setDownloadRoot(String path) async {
    if (!await DownloadPrefs.isWritable(path)) return false;
    _downloadRoot = DownloadPrefs.normalize(path);
    await DownloadPrefs.saveOverride(_downloadRoot);
    status = '下载位置已更新：$_downloadRoot';
    notifyListeners();
    return true;
  }

  /// 恢复默认下载位置（清掉本机记住的自定义目录）。
  Future<void> resetDownloadRoot() async {
    await DownloadPrefs.clearOverride();
    _downloadRoot = await DownloadPrefs.defaultRoot();
    try {
      await Directory(_downloadRoot).create(recursive: true);
    } catch (_) {
      // 同上，留给首个任务报错。
    }
    status = '下载位置已恢复默认：$_downloadRoot';
    notifyListeners();
  }

  // ---- 传输队列 ----
  final List<TransferTask> tasks = [];
  int _nextTaskId = 1;

  Timer? _persistTimer;

  /// 恢复上次的传输队列。上次在跑的任务降级为排队，上传任务先检查本地文件。
  Future<void> _restoreTasks() async {
    final saved = await TransferStore.read();
    if (saved.isEmpty) return;

    var maxId = 0;
    for (final task in saved) {
      if (task.id > maxId) maxId = task.id;
      // 上次没跑完的任务恢复成「已暂停」而不是「排队中」：直接续跑会在冷启动
      // 时突然吃掉流量，用户点「全部开始」再继续更符合预期。
      if (task.status == TransferStatus.running ||
          task.status == TransferStatus.queued) {
        task
          ..status = TransferStatus.paused
          ..sent = 0;
      }
      if (task.kind == TransferKind.upload &&
          task.status == TransferStatus.paused &&
          !await File(task.local).exists()) {
        task
          ..status = TransferStatus.failed
          ..error = '本地文件已不存在';
      }
      tasks.add(task);
    }
    if (maxId >= _nextTaskId) _nextTaskId = maxId + 1;
    notifyListeners();
  }

  /// 把队列落盘（400ms 防抖：进度更新很频繁，没必要每次都写）。
  void _schedulePersist() {
    _persistTimer?.cancel();
    _persistTimer = Timer(const Duration(milliseconds: 400), () {
      unawaited(TransferStore.write(tasks));
    });
  }

  /// 优先传输：把任务插到队列最前面（只对排队中的任务有意义）。
  void prioritizeTask(TransferTask task) {
    if (task.status != TransferStatus.queued) return;
    tasks.remove(task);
    tasks.insert(0, task);
    notifyListeners();
    _schedulePersist();
  }

  /// 暂停：只在排队阶段有效。已经开始的传输由 native 调用占着，无法中断。
  bool pauseTask(TransferTask task) {
    if (task.status != TransferStatus.queued) return false;
    task.status = TransferStatus.paused;
    notifyListeners();
    _schedulePersist();
    return true;
  }

  void resumeTask(TransferTask task) {
    if (task.status != TransferStatus.paused) return;
    task.status = TransferStatus.queued;
    notifyListeners();
    _schedulePersist();
    unawaited(_pump());
  }

  /// 暂停全部：运行中的任务没法中断，只把排队的收起来。
  void pauseAll() {
    var changed = false;
    for (final t in tasks) {
      if (t.status == TransferStatus.queued) {
        t.status = TransferStatus.paused;
        changed = true;
      }
    }
    if (!changed) return;
    notifyListeners();
    _schedulePersist();
  }

  void resumeAll() {
    var changed = false;
    for (final t in tasks) {
      if (t.status == TransferStatus.paused) {
        t.status = TransferStatus.queued;
        changed = true;
      }
    }
    if (!changed) return;
    notifyListeners();
    _schedulePersist();
    unawaited(_pump());
  }

  /// 重试所有失败任务。
  void retryAllFailed() {
    var changed = false;
    for (final t in tasks) {
      if (t.status == TransferStatus.failed) {
        t
          ..status = TransferStatus.queued
          ..sent = 0
          ..error = null
          ..speed = 0;
        t.meter.reset();
        changed = true;
      }
    }
    if (!changed) return;
    notifyListeners();
    _schedulePersist();
    unawaited(_pump());
  }

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
  // 连接参数持久化
  // ---------------------------------------------------------------------------

  /// 连接参数页点「保存」时调用：内存立即生效、同步落盘、通知界面刷新。
  ///
  /// 页面内的输入是草稿，只有点保存才写进来，不会出现「半截 JSON 被存进
  /// 配置、下次启动连不上」的情况。
  Future<void> saveConnectionConfig({
    required String relay,
    required String token,
    required String addr,
  }) async {
    this.relay = relay;
    this.token = token;
    serverAddr = addr;
    await _persistConnectionConfig();
    notifyListeners();
  }

  Future<void> _persistConnectionConfig() async {
    // 与编译期默认完全一致时删掉文件，让注入值重新生效。
    if (relay == kDefaultRelay && token.isEmpty && serverAddr == kDefaultAddr) {
      await ConnectionPrefs.clear();
      return;
    }
    // 半截输入不落盘，下次启动仍用上一次的有效配置。
    if (!ConnectionPrefs.isValidAddr(serverAddr)) return;
    await ConnectionPrefs.save(
      ConnectionConfig(relay: relay, token: token, addr: serverAddr),
    );
  }

  /// 「恢复默认」：清掉本机配置，回到编译期注入的地址。
  Future<void> resetConnectionConfig() async {
    relay = kDefaultRelay;
    token = '';
    serverAddr = kDefaultAddr;
    await ConnectionPrefs.clear();
    notifyListeners();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _stopHeartbeat();
    _statusTimer?.cancel();
    _persistTimer?.cancel();
    // 尽力落盘一次，让下次启动能恢复队列。
    unawaited(TransferStore.write(tasks));
    _disposeTransferPool();
    _worker.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // 连接
  // ---------------------------------------------------------------------------

  /// 进行中的连接尝试。用户连点「重试」、自动重试和心跳恢复可能同时触发，
  /// 并发 connect 会多次 spawn isolate 并互相覆盖，最后谁都连不上。
  Future<void>? _connecting;

  Future<void> connect() {
    // 有在途传输时绝不能动 worker：close/dispose 会把正在跑的上传下载全部
    // 打断，表现就是「传输列表突然全红：worker 已关闭 / 后台 isolate 未启动」。
    if (_running > 0) {
      status = '还有 $_running 个传输在进行，结束后再重连';
      notifyListeners();
      return Future<void>.value();
    }
    return _connecting ??= _doConnect().whenComplete(() {
      _connecting = null;
    });
  }

  Future<void> _doConnect() async {
    for (var attempt = 1; attempt <= 2; attempt++) {
      final error = await _attemptConnect();
      if (error == null) return;

      connected = false;
      // 失败后丢掉这个 worker（坏掉的是 isolate 里的 native client）；
      // 但传输中不能重建 —— dispose 会连带打断在跑的任务。
      if (_running == 0) {
        // 池 worker 用的是旧连接参数/旧 endpoint，一并重建。
        _disposeTransferPool();
        _worker.dispose();
        _worker = NetdiskWorker();
      }

      // 只有「后台线程 / isolate 起不来」才自动重试一次 —— 这类是进程内瞬态
      // 故障，重建后通常就好了。网络类失败重试只会让用户多等一轮。
      if (attempt == 2 || !_isWorkerBootError(error)) {
        status = '连接失败: $error';
        notifyListeners();
        return;
      }
      status = '后台线程启动失败，正在重建并重试…';
      notifyListeners();
      await Future<void>.delayed(const Duration(milliseconds: 400));
    }
  }

  /// 单次连接尝试。成功返回 null，失败返回错误文本（不直接覆盖 status）。
  Future<String?> _attemptConnect() async {
    // 先释放旧的 endpoint 句柄。
    //
    // 掉线时 worker 通常没「卡死」，connect() 会复用它，旧的 iroh endpoint
    // 就一直活着；再 init 一个同身份（同一 secret）的新 endpoint，两者的
    // relay 注册/连接互相干扰，重连就永远失败 —— 表现正是「杀进程重开才好」。
    // 必须显式 netdisk_close 把旧 endpoint drop 掉。
    if (!_worker.isStuck) {
      await _worker.closeConnection();
      // relay/QUIC 侧清理旧连接需要一点时间，太紧地接着 bind 容易被判成重复连接。
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }

    // 上一次 RPC 超时后，旧 isolate 里还挂着一条取消不了的 native 调用。
    // 换一个新的（dispose 会 kill 掉旧的），否则新命令只会继续排队。
    final rebuilt = _worker.isStuck;
    if (rebuilt) {
      _worker.dispose();
      _worker = NetdiskWorker();
    }

    // 每次重连都清掉旧的路径摘要：「直连」只是上一次连接的本地路径观测，
    // 留着会让人误以为当前链路仍然可用。
    pathSummary = null;
    pathLatencyMs = null;
    rpcHealthy = false;
    busy = true;
    status = rebuilt ? '正在重建后台线程…' : '正在启动后台线程…';
    notifyListeners();

    try {
      await _worker.start(libraryPath: Platform.environment['NETDISK_FFI_DLL']);

      // 前置校验：确认打包进 APK 的 .so 与当前 UI 版本匹配。
      final ver = await _worker.version();
      if (ver == null || !ver.contains('n0')) {
        return '动态库过旧（不支持 n0）：请重新交叉编译 .so 后再打 APK';
      }

      status = '正在建立 endpoint…';
      notifyListeners();
      await _worker.init(relay, token, serverAddr);
      connected = true;
      status = '已连接';
      _startHeartbeat();
      // 后台再起一个传输专用 endpoint，让上传/下载能并行；失败不影响主连接。
      unawaited(_ensureTransferPool());
      return null;
    } catch (e) {
      _stopHeartbeat();
      return '$e';
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  /// 判断错误是否属于「后台线程 / isolate 起不来」这类重建就能修的问题。
  static bool _isWorkerBootError(String error) {
    final t = error.toLowerCase();
    return t.contains('isolate') ||
        t.contains('worker 已关闭') ||
        t.contains('启动超时');
  }

  // ---------------------------------------------------------------------------
  // 连接保活
  // ---------------------------------------------------------------------------

  Timer? _heartbeat;

  /// 空闲时也要知道连接还在不在。
  ///
  /// 之前只有「刷新/操作失败」才会发现掉线，于是标题栏一直挂着上次的
  /// 「直连 · 8 ms」，用户点了文件才发现断了。现在每 15s 探活一次，
  /// 回到前台时也立刻探一次。
  void _startHeartbeat() {
    _heartbeat?.cancel();
    _heartbeat = Timer.periodic(
      const Duration(seconds: 15),
      (_) => unawaited(_probe()),
    );
  }

  void _stopHeartbeat() {
    _heartbeat?.cancel();
    _heartbeat = null;
  }

  bool _probing = false;

  /// 轻量探活。传输中跳过，免得和正在跑的任务抢同一条 RPC 通道。
  Future<void> _probe() async {
    // 上一次探活还没回来就不要再发：网络很差时 ping 会挂满超时，
    // 每 15s 再叠一个只会越积越多。
    if (_probing || !connected || busy) return;
    _probing = true;
    try {
      await _worker.ping().timeout(const Duration(seconds: 10));
    } catch (_) {
      if (!connected) return;
      _markOffline('连接已断开（心跳超时）· 下拉或点「重连」');
    } finally {
      _probing = false;
    }
  }

  /// 统一的掉线处理：清掉路径徽标，否则界面会一直显示上一次的「直连」。
  void _markOffline(String message) {
    connected = false;
    rpcHealthy = false;
    pathSummary = null;
    pathLatencyMs = null;
    _stopHeartbeat();
    setTransientStatus(message, ttl: const Duration(seconds: 15));
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

  /// 直接跳到某个目录（搜索结果里点目录时用）。
  void jumpTo(String path) {
    var d = path.replaceAll('\\', '/');
    while (d.startsWith('/')) {
      d = d.substring(1);
    }
    if (!d.endsWith('/')) d = '$d/';
    cwd = d;
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

  /// 防抖：bootstrap 自动刷新与用户下拉/手动刷新同时到达时复用同一次 RPC，
  /// 否则 worker 串行排队会让第二屏白等一整轮列表请求。
  Future<void> refresh({bool silent = false, bool firstLoad = false}) {
    final pending = _refreshFuture;
    if (pending != null) return pending;
    final future = _refreshImpl(silent: silent, firstLoad: firstLoad);
    _refreshFuture = future;
    unawaited(future.whenComplete(() => _refreshFuture = null));
    return future;
  }

  Future<void> _refreshImpl({
    required bool silent,
    required bool firstLoad,
  }) async {
    if (!connected) {
      // 已经用缓存渲染出列表时，不要用「请先连接」盖掉可见内容。
      if (!showingCache) {
        status = '请先连接';
        notifyListeners();
      }
      return;
    }
    if (!silent) {
      busy = true;
      status = showingCache ? '正在刷新列表…' : '正在拉取列表…';
      notifyListeners();
    }
    final sw = Stopwatch()..start();
    try {
      final list = await _worker.list(
        // 服务端无响应时，旧的 90s ×3 会让人干等四分半还看不到错误。
        // 首屏 15s、手动 30s，都只重试一次：快速失败后自动重建后台线程，
        // 比在一个卡死的 isolate 后面反复排队有效得多。
        timeLimit: firstLoad
            ? const Duration(seconds: 15)
            : const Duration(seconds: 30),
        maxAttempts: 2,
        onAttempt: (n) {
          if (n > 1) {
            status = '链路超时，第 $n 次重试…';
            notifyListeners();
          }
        },
      );
      files = list;
      showingCache = false;
      cacheTime = null;
      lastListMs = sw.elapsedMilliseconds;
      rpcHealthy = true;
      // 当前目录可能已被删除/重命名，退回根目录避免停在空视图。
      if (cwd.isNotEmpty && !files.any((f) => f.path.startsWith(cwd))) {
        cwd = '';
      }
      if (!silent) {
        status = '共 ${files.length} 个文件 · 列表 ${lastListMs}ms';
      }
      unawaited(ListCache.write(serverAddr.hashCode.toString(), files));
    } catch (e) {
      rpcHealthy = false;
      // worker 被一条取消不了的 FFI 调用堵死了。此时再发请求只会排队，
      // 所以在没有在途传输时直接换一个干净的 isolate 并重连；有传输时
      // 不自动重建，避免 kill 掉正在跑的上传/下载。
      if (_worker.isStuck) {
        connected = false;
        pathSummary = null;
        pathLatencyMs = null;
        if (_running == 0) {
          status = '后台线程无响应，正在重建并重新连接…';
          unawaited(_recoverWorker());
        } else {
          status = '后台线程无响应，传输结束后点「重新连接」';
        }
      } else if (_looksOffline(e)) {
        connected = false;
        // 不清掉路径徽标的话，界面会一直显示「直连」直到下次连接。
        pathSummary = null;
        pathLatencyMs = null;
        _stopHeartbeat();
        status = showingCache ? '连接已断开，显示上次列表 · 下拉重试' : '连接已断开，下拉或点「重试」重新连接';
      } else if (!silent) {
        status = showingCache ? '刷新失败，显示上次列表: $e' : '刷新失败: $e';
      }
    } finally {
      if (!silent) busy = false;
      notifyListeners();
    }
    // 路径摘要只是锦上添花，别让刷新/bootstrap 在它上面多等一次 RPC。
    unawaited(_updatePath());
    // 打洞要几秒才完成，稍后再读一次路径让「中继」能变成「直连」。
    unawaited(Future<void>.delayed(const Duration(seconds: 4), _updatePath));
  }

  /// 粗判是否为链路类错误。与 worker 内部的重试判断保持一致的取向：
  /// 宁可多给一次重连机会，也不要把「超时」当成业务失败。
  static bool _looksOffline(Object e) {
    final t = e.toString().toLowerCase();
    return t.contains('timed out') ||
        t.contains('timeout') ||
        // worker 的超时消息是中文，漏判会让「已连接」状态卡住不提示掉线。
        t.contains('超时') ||
        t.contains('丢包') ||
        t.contains('connection') ||
        t.contains('unreachable') ||
        t.contains('reset') ||
        t.contains('broken pipe');
  }

  /// 自动重建卡死的后台线程并重新连接，成功后补拉一次列表。
  ///
  /// 只在没有在途传输时调用：dispose 会 kill 掉旧 isolate，那会打断上传/下载。
  Future<void> _recoverWorker() async {
    if (_recovering) return;
    _recovering = true;
    try {
      // connect() 内部检测到 isStuck 会换一个新 worker。
      await connect();
      // 等当前那次 refresh 的防抖 Future 收尾，否则补拉会被直接复用掉。
      final pending = _refreshFuture;
      if (pending != null) {
        try {
          await pending;
        } catch (_) {
          // 刷新失败也已经写进 status，这里只负责继续流程。
        }
      }
      await Future<void>.delayed(Duration.zero);
      if (connected && !_worker.isStuck) {
        await refresh(silent: true);
      }
    } finally {
      _recovering = false;
    }
  }

  /// 读取当前连接路径，压成「直连 · 8 ms」这种短文本。
  ///
  /// 这个摘要只是**本地缓存连接的路径观测**，本身不发请求、不探测对端存活，
  /// 不能证明服务端还能响应 RPC。所以只在「连接 + 列表 RPC 刚刚成功」时显示，
  /// 掉线或后台线程中毒时一律清空，避免留下误导性的「直连」。
  Future<void> _updatePath() async {
    if (!connected || !rpcHealthy || _worker.isStuck) {
      _clearPathSummary();
      return;
    }
    final info = await _worker.paths();
    if (info == null || info.desc.contains('no active connection')) {
      _clearPathSummary();
      return;
    }
    final m = RegExp(
      r'(direct|relay)\*\s+(\S+)\s+rtt=(\d+)ms',
    ).firstMatch(info.desc);
    pathSummary = m == null
        ? (info.direct ? '直连' : '中继')
        : '${m.group(1) == 'direct' ? '直连' : '中继'} · ${m.group(3)} ms';
    pathLatencyMs = m == null ? null : int.tryParse(m.group(3) ?? '');
    notifyListeners();
  }

  void _clearPathSummary() {
    if (pathSummary == null && pathLatencyMs == null) return;
    pathSummary = null;
    pathLatencyMs = null;
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
    _schedulePersist();
    await _pump();
  }

  /// 上传整个本地目录，保持相对结构。
  ///
  /// 服务端 `Put` 会自动 `create_dir_all(parent)`，所以有文件的目录不必逐个
  /// Mkdir；只有**空目录**需要单独创建，否则远端会丢掉空目录结构。
  ///
  /// 隐藏文件/目录会被跳过：服务端 `safe_path` 明确拒绝 `.` 开头的路径，
  /// 不剪掉的话 `.git/`、`.nomedia` 会刷出一串失败任务。
  Future<void> enqueueDirectoryUpload(String localDir) async {
    if (!connected) {
      status = '请先连接';
      notifyListeners();
      return;
    }
    final dir = Directory(localDir);
    if (!await dir.exists()) {
      status = '目录不存在：$localDir';
      notifyListeners();
      return;
    }
    final rootName = p.basename(DownloadPrefs.normalize(localDir));
    if (rootName.isEmpty || rootName == '.' || rootName == '..') {
      status = '无法识别目录名：$localDir';
      notifyListeners();
      return;
    }

    status = '正在扫描 $rootName …';
    notifyListeners();

    final picked = <({String name, String path, int size})>[];
    final emptyDirs = <String>[];
    var skipped = 0;
    var totalBytes = 0;
    try {
      await for (final entity in dir.list(
        recursive: true,
        followLinks: false,
      )) {
        final rel = p
            .relative(entity.path, from: localDir)
            .replaceAll('\\', '/');
        if (rel.isEmpty || rel.startsWith('..')) continue;
        if (shouldSkipUploadPath(rel)) {
          skipped++;
          continue;
        }
        if (entity is Directory) {
          // 空目录（含只有隐藏项）不会因为上传文件而被创建，得单独记下来。
          if (await entity.list().isEmpty) {
            emptyDirs.add('$cwd$rootName/$rel');
          }
        } else if (entity is File) {
          final stat = await entity.stat();
          totalBytes += stat.size;
          picked.add((
            name: '$rootName/$rel',
            path: entity.path,
            size: stat.size,
          ));
        }
      }
    } catch (e) {
      status = '扫描目录失败: $e';
      notifyListeners();
      return;
    }

    if (picked.isEmpty && emptyDirs.isEmpty) {
      status = '目录为空（或只含隐藏文件）：$rootName';
      notifyListeners();
      return;
    }

    var dirFailures = 0;
    for (final d in emptyDirs) {
      try {
        await _worker.mkdir(d);
      } catch (_) {
        dirFailures++;
      }
    }

    // 只含空目录的文件夹：没有文件要传，但目录结构已经建好了。
    if (picked.isEmpty) {
      final created = emptyDirs.length - dirFailures;
      status = created > 0 ? '已在远端创建 $created 个空目录' : '空目录创建失败（$dirFailures 个）';
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

    final skippedText = skipped > 0 ? '，跳过 $skipped 项隐藏内容' : '';
    final failText = dirFailures > 0 ? '，$dirFailures 个空目录创建失败' : '';
    status =
        '已加入 ${picked.length} 个文件（${humanSize(totalBytes)}）'
        '$skippedText$failText';
    notifyListeners();
    _schedulePersist();
    await _pump();
  }

  Future<void> enqueueDownload(String remote, int size) async {
    await enqueueDownloads([(path: remote, size: size)]);
  }

  /// 下载远端整个目录（保持目录结构）。
  ///
  /// 服务端 `List` 返回的是整棵树的扁平列表，所以目录下载不需要新协议：
  /// 直接按前缀过滤出所有条目，再把相对路径映射到本地下载根目录下。
  Future<void> enqueueDirectoryDownload(String remoteDir) async {
    if (!connected) {
      status = '请先连接';
      notifyListeners();
      return;
    }
    var dir = remoteDir.replaceAll('\\', '/');
    while (dir.endsWith('/')) {
      dir = dir.substring(0, dir.length - 1);
    }
    if (dir.isEmpty) {
      status = '根目录请逐项选择下载';
      notifyListeners();
      return;
    }

    final under = entriesUnder(files, dir);
    final items = <({String path, int size})>[
      for (final e in under)
        if (!e.isDir) (path: e.path, size: e.size),
    ];
    final dirs = <String>[
      for (final e in under)
        if (e.isDir) e.path,
    ];
    if (items.isEmpty && dirs.isEmpty) {
      status = '目录为空或列表尚未刷新：$dir';
      notifyListeners();
      return;
    }

    final base = parentOf(dir);
    if (items.isEmpty) {
      // 只有空目录：本地也建出来，别让用户以为下载失败。
      final root = await ensureDownloadRoot();
      final local = joinUnder(root, localRelPath(dir, remoteBase: base));
      try {
        await Directory(local).create(recursive: true);
        status = '目录为空，已在本地创建 $local';
      } catch (e) {
        status = '创建本地目录失败: $e';
      }
      notifyListeners();
      return;
    }

    status = '正在准备下载 ${dirName(dir)}（${items.length} 个文件）…';
    notifyListeners();
    await enqueueDownloads(items, remoteBase: base, extraDirs: dirs);
  }

  /// 批量下载。
  ///
  /// [remoteBase] 为 null 时按单文件/多选处理：文件**平铺**到下载根目录，
  /// 只保留文件名（保持原有行为）。非 null 时保留结构，供目录下载使用；
  /// [extraDirs] 里的远端目录会在本地创建出来，避免空目录丢失。
  Future<void> enqueueDownloads(
    List<({String path, int size})> items, {
    String? remoteBase,
    List<String> extraDirs = const [],
  }) async {
    if (!connected) {
      status = '请先连接';
      notifyListeners();
      return;
    }
    if (items.isEmpty && extraDirs.isEmpty) return;

    final String root;
    try {
      root = await ensureDownloadRoot();
    } catch (e) {
      status = '无法准备下载目录: $e';
      notifyListeners();
      return;
    }

    final base = remoteBase ?? '';
    final keepStructure = remoteBase != null;

    for (final dir in extraDirs) {
      final rel = keepStructure ? localRelPath(dir, remoteBase: base) : '';
      if (rel.isEmpty) continue;
      try {
        await Directory(joinUnder(root, rel)).create(recursive: true);
      } catch (_) {
        // 单个目录建不出来不影响后续文件，最终会在任务里暴露。
      }
    }

    for (final item in items) {
      final rel = keepStructure
          ? localRelPath(item.path, remoteBase: base)
          : p.basename(item.path);
      final local = joinUnder(root, rel.isEmpty ? p.basename(item.path) : rel);
      try {
        await Directory(p.dirname(local)).create(recursive: true);
      } catch (_) {
        // 同上：目录创建失败会在打开文件时变成明确错误。
      }
      tasks.add(
        TransferTask(
          id: _nextTaskId++,
          kind: TransferKind.download,
          remote: item.path,
          local: local,
          total: item.size,
        ),
      );
    }

    status = '已加入 ${items.length} 个下载任务 → $root';
    notifyListeners();
    _schedulePersist();
    await _pump();
  }

  /// 最大并发传输数。
  ///
  /// iroh 的一条 QUIC 连接支持多流并发，Rust 侧 `connection()` 用双检锁保证
  /// 只会建一条连接，所以多个 put/get 可以真正并行。上限设 5 是为了避免
  /// 手机网络下过多流互相挤占带宽，反而让每个任务都变慢。
  int _running = 0;
  bool _anyDone = false;

  // ---------------------------------------------------------------------------
  // 传输专用 worker
  // ---------------------------------------------------------------------------
  //
  // 单个 worker isolate 里的 native 调用是同步的，`put/get` 只能排队执行 ——
  // 所以「并发 5 个任务」实际是 1 个在传。这里额外起一个独立 endpoint 的
  // worker 专门跑传输，让上传/下载真正并行（服务端也已按流并发处理）。
  // 池只是加速：建不起来就退回单 worker，不影响功能。

  static const int _transferPoolSize = 1;

  final List<NetdiskWorker> _pool = [];
  final Set<NetdiskWorker> _busyPool = {};
  bool _warmingPool = false;

  Future<void> _ensureTransferPool() async {
    if (_warmingPool || _pool.length >= _transferPoolSize) return;
    _warmingPool = true;
    try {
      while (_pool.length < _transferPoolSize) {
        final w = NetdiskWorker();
        try {
          await w.start(libraryPath: Platform.environment['NETDISK_FFI_DLL']);
          await w.init(relay, token, serverAddr);
          _pool.add(w);
        } catch (_) {
          w.dispose();
          return;
        }
      }
    } finally {
      _warmingPool = false;
    }
  }

  void _disposeTransferPool() {
    _busyPool.clear();
    for (final w in _pool) {
      w.dispose();
    }
    _pool.clear();
  }

  /// 取一个可用的传输 worker：优先空闲的池 worker，否则退回主 worker。
  (NetdiskWorker, bool) _acquireTransferWorker() {
    for (final w in _pool) {
      if (!_busyPool.contains(w)) {
        _busyPool.add(w);
        return (w, true);
      }
    }
    return (_worker, false);
  }

  void _releaseTransferWorker(
    NetdiskWorker worker,
    bool fromPool, {
    required bool failed,
  }) {
    if (!fromPool) return;
    _busyPool.remove(worker);
    if (failed) {
      // 池 worker 出过错就直接丢掉，下次补一个新的；否则会一直用坏连接。
      _pool.remove(worker);
      worker.dispose();
      unawaited(_ensureTransferPool());
    }
  }

  /// 消费队列：最多同时跑「1 + 池大小」个，其余保持 queued。
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

        // 池里每多一个 worker 就多一条并行通道；池没建好时退化为串行。
        if (_running >= 1 + _pool.length) {
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
    _schedulePersist();

    unawaited(() async {
      final (worker, fromPool) = _acquireTransferWorker();
      var failed = false;
      try {
        void onProgress(int sent, int total) {
          task
            ..sent = sent
            ..speed = task.meter.sample(sent);
          notifyListeners();
          _notifyTransfers();
        }

        final Map<String, dynamic> res = task.kind == TransferKind.upload
            ? await worker.put(
                task.remote,
                task.local,
                totalBytes: task.total,
                onProgress: onProgress,
              )
            : await worker.get(
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
        failed = true;
        task
          ..status = TransferStatus.failed
          ..error = '$e';
      } finally {
        _releaseTransferWorker(worker, fromPool, failed: failed);
        task
          ..finishedAt = DateTime.now()
          ..speed = 0;
        _running--;
        notifyListeners();
        _notifyTransfers(force: true);
        _schedulePersist();
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
    _schedulePersist();
  }

  /// 前台服务是否在运行（决定通知走 startService 还是普通 show）。
  bool _serviceRunning = false;

  /// 把整个队列的状态汇总成**一条**通知，同时驱动前台服务保活。
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

    final active = running + queued;
    final finished = done + failed;

    if (active == 0) {
      if (_serviceRunning) {
        _serviceRunning = false;
        unawaited(_finishNotification(done, failed));
        return;
      }
      if (finished == 0) {
        unawaited(TransferNotifications.cancel());
        return;
      }
      unawaited(
        TransferNotifications.show(
          title: failed == 0 ? '传输完成' : '部分传输失败',
          text: failed == 0 ? '$done 个文件已完成' : '$done 个完成，$failed 个失败',
          ongoing: false,
          force: true,
        ),
      );
      return;
    }

    final total = active + finished;
    final parts = <String>[
      if (running > 0) '进行中 $running',
      if (queued > 0) '排队 $queued',
    ];
    final title = '正在传输';
    final text = '${parts.join(' · ')}（已完成 $finished/$total）';
    final progress = total > 0 ? finished * 100 ~/ total : null;

    // 第一次有任务时拉起前台服务：锁屏/切后台后进程才不会被回收。
    if (!_serviceRunning) {
      _serviceRunning = true;
      unawaited(
        TransferNotifications.startService(
          title: title,
          text: text,
          progress: progress,
        ),
      );
      return;
    }

    unawaited(
      TransferNotifications.updateService(
        title: title,
        text: text,
        progress: progress,
        force: force,
      ),
    );
  }

  /// 收尾：先撤前台服务，再补一条结果通知。
  ///
  /// 顺序不能反 —— `stopForeground(REMOVE)` 会把当前通知一起抹掉，
  /// 若先发结果通知再停服务，用户什么都看不到。
  Future<void> _finishNotification(int done, int failed) async {
    await TransferNotifications.stopService();
    // stopForeground 由系统异步处理，稍等再发，避免刚发就被移除。
    await Future<void>.delayed(const Duration(milliseconds: 200));

    if (done + failed == 0) {
      await TransferNotifications.cancel();
      return;
    }
    await TransferNotifications.show(
      title: failed == 0 ? '传输完成' : '部分传输失败',
      text: failed == 0 ? '$done 个文件已完成' : '$done 个完成，$failed 个失败',
      ongoing: false,
      force: true,
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
    _schedulePersist();
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
      setTransientStatus('已删除：$path（在服务端回收站）');
      await refresh(silent: true);
    } catch (e) {
      setTransientStatus('删除失败: $e', ttl: const Duration(seconds: 6));
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
      setTransientStatus('已重命名：$from → $to');
      await refresh(silent: true);
    } catch (e) {
      setTransientStatus('重命名失败: $e', ttl: const Duration(seconds: 6));
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
      setTransientStatus('已复制：$from → $to');
      await refresh(silent: true);
    } catch (e) {
      setTransientStatus('复制失败: $e', ttl: const Duration(seconds: 6));
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  /// 在当前目录下新建目录。返回是否成功。
  Future<bool> createDir(String name) async {
    return createDirAt(cwd, name);
  }

  /// 在指定父目录下建目录（目录选择器里用，不受当前 `cwd` 影响）。
  Future<bool> createDirAt(String parent, String name) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return false;
    final base = parent.isEmpty || parent.endsWith('/') ? parent : '$parent/';

    busy = true;
    status = '正在创建目录 $trimmed …';
    notifyListeners();
    try {
      await _worker.mkdir('$base$trimmed');
      await refresh(silent: true);
      setTransientStatus('已创建目录：$base$trimmed');
      return true;
    } catch (e) {
      setTransientStatus('创建目录失败: $e', ttl: const Duration(seconds: 6));
      return false;
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  /// 预览缓存：远端路径 → 本地临时文件。左右滑动连续预览时避免反复下载。
  final Map<String, String> _previewPaths = {};

  /// 把远程文件下载到临时目录，用于预览。返回本地路径。
  ///
  /// 预览是「用完即弃」的，所以落到 `getTemporaryDirectory()` 而不是 App 文档目录，
  /// 避免重复预览时占满用户空间（系统会自行回收）。
  Future<String> downloadForPreview(String remote) async {
    final cached = _previewPaths[remote];
    if (cached != null && await File(cached).exists()) return cached;

    final dir = await getTemporaryDirectory();
    // 不同目录可能有同名文件，用路径 hash 前缀区分。
    final local = p.join(
      dir.path,
      'preview',
      '${remote.hashCode.toRadixString(16)}-${p.basename(remote)}',
    );
    await Directory(p.dirname(local)).create(recursive: true);

    final res = await _worker.get(
      remote,
      local,
      // 预览是「看一眼」，不该沿用大文件传输的 30 分钟超时。服务端没响应
      // 时最多 30s ×2 就给出明确错误，而不是无限转圈。
      timeLimit: const Duration(seconds: 30),
    );
    final err = res['Error'];
    if (err != null) throw Exception(err);
    _previewPaths[remote] = local;
    return local;
  }

  // ---------------------------------------------------------------------------
  // 缩略图（文件列表用）
  // ---------------------------------------------------------------------------

  final Map<String, Uint8List> _thumbs = {};
  final Map<String, Future<Uint8List?>> _thumbPending = {};
  int _thumbsBytes = 0;
  int _thumbRunning = 0;
  final List<Completer<void>> _thumbWaiters = [];

  /// 单张原图超过这个大小就不取缩略图：滚动一次把几十 MB 拉下来不值得。
  static const int _thumbMaxEntry = 12 * 1024 * 1024;
  static const int _thumbMaxCache = 48 * 1024 * 1024;
  static const int _thumbConcurrency = 3;

  /// 取图片缩略图（内存 LRU + 临时文件缓存）。
  ///
  /// 同一路径的并发请求会复用同一个 future，列表滚动时不会重复下载。
  Future<Uint8List?> thumbnail(String path, int size) {
    if (!connected || size <= 0 || size > _thumbMaxEntry) {
      return Future.value(null);
    }
    final cached = _thumbs[path];
    if (cached != null) return Future.value(cached);
    return _thumbPending.putIfAbsent(path, () => _loadThumb(path, size));
  }

  Future<Uint8List?> _loadThumb(String path, int size) async {
    await _acquireThumbSlot();
    try {
      final tmp = await getTemporaryDirectory();
      final dir = Directory(p.join(tmp.path, 'netdisk_thumbs'));
      await dir.create(recursive: true);
      // 用路径 hash 当文件名：原路径可能含 `/` 和中文，不能直接做文件名。
      final file = File(p.join(dir.path, path.hashCode.toRadixString(16)));

      if (!await file.exists() || await file.length() != size) {
        final res = await _worker.get(
          path,
          file.path,
          totalBytes: size,
          timeLimit: const Duration(seconds: 25),
        );
        if (res['Error'] != null) return null;
      }

      final bytes = await file.readAsBytes();
      _thumbs[path] = bytes;
      _thumbsBytes += bytes.length;
      while (_thumbsBytes > _thumbMaxCache && _thumbs.isNotEmpty) {
        final oldest = _thumbs.keys.first;
        _thumbsBytes -= _thumbs.remove(oldest)!.length;
      }
      return bytes;
    } catch (_) {
      // 缩略图只是锦上添花，失败就当没有，不要影响列表本身。
      return null;
    } finally {
      _releaseThumbSlot();
      _thumbPending.remove(path);
    }
  }

  Future<void> _acquireThumbSlot() async {
    if (_thumbRunning < _thumbConcurrency) {
      _thumbRunning++;
      return;
    }
    final waiter = Completer<void>();
    _thumbWaiters.add(waiter);
    await waiter.future;
  }

  void _releaseThumbSlot() {
    if (_thumbWaiters.isNotEmpty) {
      // 槽位直接转交给下一个等待者，计数保持不变。
      _thumbWaiters.removeAt(0).complete();
    } else {
      _thumbRunning--;
    }
  }

  /// 目录规范化：去掉开头的 `/`，补上结尾的 `/`；空串表示根目录。
  static String _normalizeDir(String raw) {
    var d = raw.trim();
    while (d.startsWith('/')) {
      d = d.substring(1);
    }
    if (d.isEmpty) return '';
    return d.endsWith('/') ? d : '$d/';
  }

  /// 批量删除。路径可以是文件，也可以是目录。
  ///
  /// 文件走 `Delete`（单文件进回收站）；目录走 `RemoveDir`，服务端把**整棵目录**
  /// 一次性 rename 进回收站 —— 保留内部结构，可以整体恢复。不要在这里展开成
  /// 逐个文件删除：那样回收站里只剩散落的文件，原目录结构就丢了。
  Future<void> deleteMany(List<String> paths) async {
    if (paths.isEmpty) return;

    final filePaths = <String>{};
    final dirPaths = <String>{};
    for (final raw in paths) {
      final isDir =
          raw.endsWith('/') || files.any((e) => e.path == raw && e.isDir);
      if (isDir) {
        dirPaths.add(
          raw.endsWith('/') ? raw.substring(0, raw.length - 1) : raw,
        );
      } else {
        filePaths.add(raw);
      }
    }

    if (filePaths.isEmpty && dirPaths.isEmpty) return;

    busy = true;
    status =
        '正在删除 ${filePaths.length} 个文件'
        '${dirPaths.isEmpty ? '' : '、${dirPaths.length} 个文件夹'}…';
    notifyListeners();

    var okFiles = 0;
    final failures = <String>[];
    for (final path in filePaths) {
      try {
        await _worker.delete(path);
        okFiles++;
      } catch (e) {
        failures.add('${p.basename(path)}（$e）');
      }
    }

    // 深的目录先删，父目录才会变空。
    final ordered = dirPaths.toList()
      ..sort((a, b) => b.length.compareTo(a.length));
    var okDirs = 0;
    for (final dir in ordered) {
      try {
        await _worker.rmdir(dir);
        okDirs++;
      } catch (e) {
        failures.add('${p.basename(dir)}/（$e）');
      }
    }

    final parts = <String>[
      if (okFiles > 0) '$okFiles 个文件',
      if (okDirs > 0) '$okDirs 个文件夹',
    ];
    setTransientStatus(
      failures.isEmpty
          ? '已删除${parts.isEmpty ? '' : ' ${parts.join('、')}'}'
          : '删除完成 ${parts.join('、')}，失败 ${failures.length} 项：${failures.first}',
      ttl: failures.isEmpty
          ? const Duration(seconds: 4)
          : const Duration(seconds: 8),
    );
    await refresh(silent: true);
    busy = false;
    notifyListeners();
  }

  /// 批量移动：目标是「目录 + 原文件名」。
  Future<void> moveMany(List<String> paths, String targetDir) async {
    if (paths.isEmpty) return;
    final dir = _normalizeDir(targetDir);
    busy = true;
    status = '正在移动 ${paths.length} 个文件…';
    notifyListeners();

    var ok = 0;
    final failures = <String>[];
    for (final path in paths) {
      try {
        await _worker.rename(path, '$dir${p.basename(path)}');
        ok++;
      } catch (e) {
        failures.add('${p.basename(path)}（$e）');
      }
    }

    setTransientStatus(
      failures.isEmpty
          ? '已移动 $ok 个文件'
          : '移动完成 $ok 个，失败 ${failures.length} 个：${failures.first}',
      ttl: failures.isEmpty
          ? const Duration(seconds: 4)
          : const Duration(seconds: 8),
    );
    await refresh(silent: true);
    busy = false;
    notifyListeners();
  }

  /// 批量复制：服务端本地复制，不走网络。
  Future<void> copyMany(List<String> paths, String targetDir) async {
    if (paths.isEmpty) return;
    final dir = _normalizeDir(targetDir);
    busy = true;
    status = '正在复制 ${paths.length} 个文件…';
    notifyListeners();

    var ok = 0;
    final failures = <String>[];
    for (final path in paths) {
      try {
        await _worker.copy(path, '$dir${p.basename(path)}');
        ok++;
      } catch (e) {
        failures.add('${p.basename(path)}（$e）');
      }
    }

    setTransientStatus(
      failures.isEmpty
          ? '已复制 $ok 个文件'
          : '复制完成 $ok 个，失败 ${failures.length} 个：${failures.first}',
      ttl: failures.isEmpty
          ? const Duration(seconds: 4)
          : const Duration(seconds: 8),
    );
    await refresh(silent: true);
    busy = false;
    notifyListeners();
  }

  void setStatus(String value) {
    status = value;
    notifyListeners();
  }

  Timer? _statusTimer;

  /// 操作结果类消息（已删除/已移动/已创建…）：显示几秒后自动回到空闲状态。
  ///
  /// 之前这类消息会一直挂在底部，用户看到「已删除 3 个文件」以为任务还在跑。
  void setTransientStatus(
    String value, {
    Duration ttl = const Duration(seconds: 4),
  }) {
    status = value;
    notifyListeners();
    _statusTimer?.cancel();
    _statusTimer = Timer(ttl, () {
      status = idleStatus;
      notifyListeners();
    });
  }

  /// 空闲状态栏该显示什么：优先复用列表摘要，没有就退回连接状态。
  String get idleStatus {
    if (!connected) return '未连接';
    if (showingCache) return '显示上次列表';
    if (lastListMs != null) {
      return '共 ${files.length} 个文件 · 列表 ${lastListMs}ms';
    }
    return '已连接';
  }
}
