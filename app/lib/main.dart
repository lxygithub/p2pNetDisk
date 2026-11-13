import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'src/netdisk_worker.dart';

// 默认走 n0 官方公共 relay（实测 aps1-1/euc1-1 握手 8/8，自建港服仅 2/8）。
// 数据面靠打洞/IPv6 直连绕过 relay，relay 只承担引荐。
const _defaultRelay = 'n0';
// 常驻服务的固定身份；n0 模式经 dns.iroh.link 解析出完整地址（含 relay）。
const _defaultAddr =
    '{"id":"YOUR_ENDPOINT_ID",'
    '"addrs":[]}';

void main() => runApp(const NetdiskApp());

class NetdiskApp extends StatelessWidget {
  const NetdiskApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '个人网盘',
      theme: ThemeData(useMaterial3: true, colorSchemeSeed: Colors.blue),
      home: const HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final _relay = TextEditingController(text: _defaultRelay);
  final _token = TextEditingController();
  final _addr = TextEditingController(text: _defaultAddr);

  // 所有 FFI 调用都在后台 isolate 执行，避免阻塞 UI 线程（曾导致 ANR）。
  final _worker = NetdiskWorker();

  String _status = '未连接';
  String? _pathSummary;
  List<({String path, int size})> _files = [];
  bool _busy = false;
  bool _connected = false;

  @override
  void dispose() {
    _worker.dispose();
    _relay.dispose();
    _token.dispose();
    _addr.dispose();
    super.dispose();
  }

  void _setStatus(String value) {
    if (!mounted) return;
    setState(() => _status = value);
  }

  /// 桌面开发时可用 NETDISK_FFI_DLL 指向构建产物；Android 用打包进 APK 的 .so。
  String? get _libraryPath => Platform.environment['NETDISK_FFI_DLL'];

  Future<void> _connect() async {
    setState(() => _busy = true);
    _setStatus('正在启动后台线程…');
    try {
      await _worker.start(libraryPath: _libraryPath);
      // 前置校验：确认打包进 APK 的 .so 与当前 UI 版本匹配。
      final ver = await _worker.version();
      if (ver == null || !ver.contains('n0')) {
        _setStatus('动态库过旧（不支持 n0）：请重新交叉编译 .so 后再打 APK');
        return;
      }
      _setStatus('正在建立 endpoint…');
      await _worker.init(
        _relay.text.trim(),
        _token.text.trim(),
        _addr.text.trim(),
      );
      if (!mounted) return;
      setState(() => _connected = true);
      _setStatus('已连接（点「刷新列表」验证链路）');
    } catch (e) {
      if (!mounted) return;
      setState(() => _connected = false);
      _setStatus('连接失败: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _refresh({bool silent = false}) async {
    if (!_connected) {
      _setStatus('请先连接');
      return;
    }
    if (!silent) {
      setState(() => _busy = true);
      _setStatus('正在拉取列表…');
    }
    try {
      final files = await _worker.list(
        onAttempt: (n) {
          if (n > 1) _setStatus('链路超时，第 $n 次重试…');
        },
      );
      if (!mounted) return;
      setState(() {
        _files = files;
        if (!silent) _status = '共 ${files.length} 个文件';
      });
    } catch (e) {
      if (!silent) _setStatus('刷新失败: $e');
    } finally {
      if (!silent && mounted) setState(() => _busy = false);
    }
    await _updatePath();
    // 打洞要几秒才完成，稍后再读一次路径，让「中继」能变成「直连」。
    Future<void>.delayed(const Duration(seconds: 4), _updatePath);
  }

  /// 读取当前连接的传输路径，压成「直连 · 5 ms」这种短文本。
  Future<void> _updatePath() async {
    final info = await _worker.paths();
    if (!mounted || info == null) return;
    final m = RegExp(r'(direct|relay)\*\s+(\S+)\s+rtt=(\d+)ms').firstMatch(info.desc);
    final summary = m == null
        ? (info.direct ? '直连' : '中继')
        : '${m.group(1) == 'direct' ? '直连' : '中继'} · ${m.group(3)} ms';
    setState(() => _pathSummary = summary);
  }

  Future<void> _pickAndUpload() async {
    if (!_connected) {
      _setStatus('请先连接');
      return;
    }
    // file_picker 13.x：pickFiles() 直接返回 List<PlatformFile>，
    // 取消时返回空列表（v11 及以前是 FilePickerResult? + allowMultiple 参数）。
    List<PlatformFile> picked;
    try {
      picked = await FilePicker.pickFiles();
    } catch (e) {
      _setStatus('打开文件选择器失败: $e');
      return;
    }
    if (picked.isEmpty) return;

    final files = picked.where((f) => f.path != null).toList();
    if (files.isEmpty) {
      _setStatus('拿不到文件路径（部分平台只给流，需另做适配）');
      return;
    }

    setState(() => _busy = true);
    var ok = 0;
    final failures = <String>[];
    for (var i = 0; i < files.length; i++) {
      final file = files[i];
      final name = file.name;
      _setStatus('上传 ${i + 1}/${files.length}：$name');
      try {
        final res = await _worker.put(name, file.path!);
        final err = res['Error'];
        if (err != null) {
          throw Exception(err);
        }
        ok++;
      } catch (e) {
        failures.add('$name（$e）');
      }
    }

    await _refresh(silent: true);
    if (!mounted) return;
    setState(() => _busy = false);
    _setStatus(
      failures.isEmpty
          ? '上传完成：$ok 个文件'
          : '上传完成 $ok 个，失败 ${failures.length} 个：${failures.first}',
    );
  }

  Future<void> _download(String remote) async {
    setState(() => _busy = true);
    _setStatus('下载 $remote …');
    try {
      final dir = await getApplicationDocumentsDirectory();
      final target = p.join(dir.path, 'downloads', p.basename(remote));
      await Directory(p.dirname(target)).create(recursive: true);
      final res = await _worker.get(remote, target);
      final err = res['Error'];
      if (err != null) {
        throw Exception(err);
      }
      final size = (res['Downloaded']?['size'] as num?)?.toInt() ?? 0;
      _setStatus('已保存 $size 字节\n$target');
    } catch (e) {
      _setStatus('下载失败: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    await _updatePath();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('个人网盘'),
        actions: [
          if (_pathSummary != null)
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: Center(
                child: Chip(
                  visualDensity: VisualDensity.compact,
                  avatar: Icon(
                    _pathSummary!.startsWith('直连')
                        ? Icons.bolt
                        : Icons.cloud_queue,
                    size: 16,
                  ),
                  label: Text(_pathSummary!, style: const TextStyle(fontSize: 12)),
                ),
              ),
            ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _relay,
              decoration: const InputDecoration(
                labelText: 'Relay（n0 = 官方公共中继）',
                helperText: '填 n0 用官方节点；填 https://host:8443 用自建',
              ),
            ),
            TextField(
              controller: _token,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: 'Relay Token（仅自建需要）',
                helperText: 'n0 官方 relay 不需要 token，留空即可',
              ),
            ),
            TextField(
              controller: _addr,
              maxLines: 3,
              decoration:
                  const InputDecoration(labelText: '服务端 EndpointAddr JSON'),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                FilledButton(
                  onPressed: _busy ? null : _connect,
                  child: Text(_connected ? '重新连接' : '连接'),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: _busy ? null : _refresh,
                  child: const Text('刷新列表'),
                ),
                const SizedBox(width: 8),
                OutlinedButton.icon(
                  onPressed: _busy ? null : _pickAndUpload,
                  icon: const Icon(Icons.upload_file, size: 18),
                  label: const Text('上传'),
                ),
                if (_busy) ...[
                  const SizedBox(width: 12),
                  const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 8),
            Text(_status),
            const Divider(height: 24),
            if (_files.isEmpty)
              const Text('（列表为空，点「刷新列表」）')
            else
              for (final f in _files)
                ListTile(
                  dense: true,
                  leading: const Icon(Icons.insert_drive_file),
                  title: Text(f.path),
                  subtitle: Text('${f.size} bytes'),
                  trailing: IconButton(
                    tooltip: '下载到 App 文档目录',
                    icon: const Icon(Icons.download),
                    onPressed: _busy ? null : () => _download(f.path),
                  ),
                ),
          ],
        ),
      ),
    );
  }
}
