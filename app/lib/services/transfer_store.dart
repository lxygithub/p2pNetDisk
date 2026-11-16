import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/transfer_task.dart';

/// 传输队列的本地快照。
///
/// 重启后把上次的队列恢复出来：上次在跑的任务降级为排队，已完成的保留展示，
/// 失败/暂停的保持原状态。上传任务还会检查本地文件是否还在 —— 临时文件可能
/// 已被系统清掉，恢复成「排队」只会在开始后又失败一次。
///
/// 只存必要的元信息（不存进度累积），文件落在 App 文档目录，卸载即清除。
class TransferStore {
  TransferStore._();

  static const int _version = 1;
  static const String _fileName = 'transfer_tasks.json';

  /// 只保留最近这么多条，避免长期使用后 JSON 无限增长。
  static const int _maxTasks = 200;

  static Future<File> _target() async {
    final dir = await getApplicationDocumentsDirectory();
    return File(p.join(dir.path, _fileName));
  }

  static Future<List<TransferTask>> read() async {
    try {
      final file = await _target();
      if (!await file.exists()) return const [];
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map || decoded['version'] != _version) return const [];
      final list = decoded['tasks'];
      if (list is! List) return const [];
      final out = <TransferTask>[];
      for (final raw in list) {
        if (raw is! Map) continue;
        final task = _decode(raw);
        if (task != null) out.add(task);
      }
      return out;
    } catch (_) {
      return const [];
    }
  }

  static Future<void> write(List<TransferTask> tasks) async {
    try {
      final keep = tasks.length > _maxTasks
          ? tasks.sublist(tasks.length - _maxTasks)
          : tasks;
      final payload = <String, Object?>{
        'version': _version,
        'tasks': [for (final t in keep) _encode(t)],
      };
      await (await _target()).writeAsString(jsonEncode(payload));
    } catch (_) {
      // 持久化失败不影响当前会话。
    }
  }

  static Map<String, Object?> _encode(TransferTask t) => <String, Object?>{
    'id': t.id,
    'kind': t.kind.name,
    'remote': t.remote,
    'local': t.local,
    'total': t.total,
    'sent': t.sent,
    'status': t.status.name,
    'error': t.error,
  };

  static TransferTask? _decode(Map raw) {
    final remote = raw['remote'];
    final local = raw['local'];
    if (remote is! String || local is! String) return null;

    final task = TransferTask(
      id: (raw['id'] as num?)?.toInt() ?? 0,
      kind: raw['kind'] == 'download'
          ? TransferKind.download
          : TransferKind.upload,
      remote: remote,
      local: local,
      total: (raw['total'] as num?)?.toInt() ?? 0,
    );
    task.sent = (raw['sent'] as num?)?.toInt() ?? 0;
    task.error = raw['error'] as String?;
    task.status = switch (raw['status']) {
      'done' => TransferStatus.done,
      'failed' => TransferStatus.failed,
      'paused' => TransferStatus.paused,
      // running 也是上次异常退出的产物，恢复成排队。
      _ => TransferStatus.queued,
    };
    return task;
  }
}
