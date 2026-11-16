import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import '../models/transfer_task.dart';

/// 传输队列的持久化（SQLite）。
///
/// 之前用 JSON 全量重写：每次任务状态变化都要把整个队列序列化一遍，队列越长
/// 越慢，还得自己维护「保留多少条」的截断逻辑；写到一半被杀进程还会留下半截
/// JSON，下次启动整个队列读废。
///
/// 换成 SQLite 后：
/// - 单条 upsert，只写变化的行；
/// - 已完成历史用 SQL 按时间裁剪，未完成任务不受影响；
/// - 事务保证要么全写进去，要么完全不动。
class TransferStore {
  TransferStore._();

  static const String _dbName = 'transfers.db';
  static const String _table = 'transfer_tasks';

  /// 已完成的历史只留最近这么多条（只作参考记录，越老越没用）。
  static const int maxDoneHistory = 200;

  /// 未完成的任务理论上全留；这个上限只防病态情况（比如误选十万个文件）。
  static const int maxPending = 1000;

  static Database? _db;

  static Future<Database> _open() async {
    final cached = _db;
    if (cached != null) return cached;

    final dir = await getApplicationDocumentsDirectory();
    final db = await openDatabase(
      p.join(dir.path, _dbName),
      version: 1,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE $_table (
            id INTEGER PRIMARY KEY,
            kind TEXT NOT NULL,
            remote TEXT NOT NULL,
            local TEXT NOT NULL,
            total INTEGER NOT NULL DEFAULT 0,
            sent INTEGER NOT NULL DEFAULT 0,
            status TEXT NOT NULL,
            error TEXT,
            created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL
          )
        ''');
        await db.execute('CREATE INDEX idx_transfer_status ON $_table(status)');
        await db.execute(
          'CREATE INDEX idx_transfer_created ON $_table(created_at)',
        );
        await _migrateLegacyJson(db);
      },
    );
    _db = db;
    return db;
  }

  /// 把早期版本留下的 `transfer_tasks.json` 导入一次，然后删掉。
  static Future<void> _migrateLegacyJson(Database db) async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final legacy = File(p.join(dir.path, 'transfer_tasks.json'));
      if (!await legacy.exists()) return;

      final decoded = jsonDecode(await legacy.readAsString());
      final list = decoded is Map ? decoded['tasks'] : null;
      if (list is List && list.isNotEmpty) {
        final now = DateTime.now().millisecondsSinceEpoch;
        final batch = db.batch();
        var i = 0;
        for (final raw in list) {
          if (raw is! Map) continue;
          final remote = raw['remote'];
          final local = raw['local'];
          if (remote is! String || local is! String) continue;
          // 旧数据没有创建时间：用 now + 序号维持原有顺序。
          batch.insert(_table, <String, Object?>{
            'id': (raw['id'] as num?)?.toInt() ?? (i + 1),
            'kind': raw['kind'] == 'download' ? 'download' : 'upload',
            'remote': remote,
            'local': local,
            'total': (raw['total'] as num?)?.toInt() ?? 0,
            'sent': (raw['sent'] as num?)?.toInt() ?? 0,
            'status': raw['status'] is String ? raw['status'] : 'queued',
            'error': raw['error'],
            'created_at': now + i,
            'updated_at': now,
          }, conflictAlgorithm: ConflictAlgorithm.replace);
          i++;
        }
        await batch.commit(noResult: true);
      }
      await legacy.delete();
    } catch (_) {
      // 迁移失败就留着旧文件，不影响新库使用。
    }
  }

  static Future<List<TransferTask>> read() async {
    try {
      final db = await _open();
      final rows = await db.query(_table, orderBy: 'created_at ASC, id ASC');
      return [for (final row in rows) _fromRow(row)];
    } catch (_) {
      return const [];
    }
  }

  /// 只写这些任务对应的行（事务批量）。
  static Future<void> upsertMany(Iterable<TransferTask> items) async {
    try {
      final list = items.toList(growable: false);
      if (list.isEmpty) return;
      final db = await _open();
      final batch = db.batch();
      for (final t in list) {
        batch.insert(
          _table,
          _toRow(t),
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
      await batch.commit(noResult: true);
    } catch (_) {
      // 持久化失败不影响当前会话。
    }
  }

  static Future<void> remove(Iterable<int> ids) async {
    try {
      final list = ids.toList(growable: false);
      if (list.isEmpty) return;
      final placeholders = List.filled(list.length, '?').join(',');
      await (await _open()).delete(
        _table,
        where: 'id IN ($placeholders)',
        whereArgs: list,
      );
    } catch (_) {
      // 忽略。
    }
  }

  /// 清掉所有已完成/失败记录（列表页「清除已完成」）。
  static Future<void> clearFinished() async {
    try {
      await (await _open()).delete(
        _table,
        where: 'status IN (?, ?)',
        whereArgs: ['done', 'failed'],
      );
    } catch (_) {
      // 忽略。
    }
  }

  /// 按保留策略裁剪：已完成留最近 [maxDoneHistory] 条，未完成留最近 [maxPending] 条。
  static Future<void> prune() async {
    try {
      final db = await _open();
      await db.rawDelete(
        '''
        DELETE FROM $_table WHERE status = 'done' AND id NOT IN (
          SELECT id FROM $_table WHERE status = 'done'
          ORDER BY created_at DESC, id DESC LIMIT ?
        )
        ''',
        [maxDoneHistory],
      );
      await db.rawDelete(
        '''
        DELETE FROM $_table WHERE status IN ('queued', 'paused', 'failed')
          AND id NOT IN (
            SELECT id FROM $_table WHERE status IN ('queued', 'paused', 'failed')
            ORDER BY created_at DESC, id DESC LIMIT ?
          )
        ''',
        [maxPending],
      );
    } catch (_) {
      // 忽略。
    }
  }

  static Map<String, Object?> _toRow(TransferTask t) => <String, Object?>{
    'id': t.id,
    'kind': t.kind.name,
    'remote': t.remote,
    'local': t.local,
    'total': t.total,
    'sent': t.sent,
    'status': t.status.name,
    'error': t.error,
    'created_at': t.createdAt.millisecondsSinceEpoch,
    'updated_at': DateTime.now().millisecondsSinceEpoch,
  };

  static TransferTask _fromRow(Map<String, Object?> row) {
    final task = TransferTask(
      id: (row['id'] as num?)?.toInt() ?? 0,
      kind: row['kind'] == 'download'
          ? TransferKind.download
          : TransferKind.upload,
      remote: row['remote'] as String? ?? '',
      local: row['local'] as String? ?? '',
      total: (row['total'] as num?)?.toInt() ?? 0,
      createdAt: DateTime.fromMillisecondsSinceEpoch(
        (row['created_at'] as num?)?.toInt() ?? 0,
      ),
    );
    task.sent = (row['sent'] as num?)?.toInt() ?? 0;
    task.error = row['error'] as String?;
    task.status = switch (row['status']) {
      'done' => TransferStatus.done,
      'failed' => TransferStatus.failed,
      'paused' => TransferStatus.paused,
      'running' => TransferStatus.queued, // 上次异常退出，恢复成排队
      _ => TransferStatus.queued,
    };
    return task;
  }
}
