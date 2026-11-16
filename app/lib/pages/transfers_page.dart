import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/transfer_task.dart';
import '../state/app_state.dart';
import '../theme.dart';
import '../widgets/glass.dart';

/// 传输队列页：上传/下载任务列表，支持暂停、优先、重试、移除与批量操作。
class TransfersPage extends StatefulWidget {
  const TransfersPage({super.key});

  @override
  State<TransfersPage> createState() => _TransfersPageState();
}

class _TransfersPageState extends State<TransfersPage> {
  bool _selectionMode = false;
  final Set<int> _selected = <int>{};

  void _enterSelection(TransferTask task) {
    if (task.status == TransferStatus.running) return;
    setState(() {
      _selectionMode = true;
      _selected.add(task.id);
    });
  }

  void _toggle(TransferTask task) {
    if (task.status == TransferStatus.running) return;
    setState(() {
      if (!_selected.add(task.id)) _selected.remove(task.id);
      if (_selected.isEmpty) _selectionMode = false;
    });
  }

  void _exitSelection() {
    setState(() {
      _selectionMode = false;
      _selected.clear();
    });
  }

  void _removeSelected(AppState state) {
    state.removeTasks(
      state.tasks.where((t) => _selected.contains(t.id)).toList(),
    );
    _exitSelection();
  }

  @override
  Widget build(BuildContext context) {
    final s = context.watch<AppState>();
    final hasQueued = s.tasks.any((t) => t.status == TransferStatus.queued);
    final hasPaused = s.tasks.any((t) => t.status == TransferStatus.paused);
    final hasFailed = s.tasks.any((t) => t.status == TransferStatus.failed);
    final hasFinished = s.tasks.any(
      (t) =>
          t.status == TransferStatus.done || t.status == TransferStatus.failed,
    );

    return Scaffold(
      appBar: _selectionMode
          ? _selectionAppBar(s)
          : _normalAppBar(
              s,
              hasQueued: hasQueued,
              hasPaused: hasPaused,
              hasFailed: hasFailed,
              hasFinished: hasFinished,
            ),
      body: s.tasks.isEmpty
          ? const _EmptyTransfers()
          : ListView.separated(
              padding: kPagePadding,
              itemCount: s.tasks.length,
              separatorBuilder: (_, _) => const SizedBox(height: 8),
              itemBuilder: (context, i) {
                final task = s.tasks[i];
                final selectable = task.status != TransferStatus.running;
                return GestureDetector(
                  onLongPress: selectable ? () => _enterSelection(task) : null,
                  onTap: _selectionMode ? () => _toggle(task) : null,
                  child: _TaskTile(
                    task: task,
                    selectionMode: _selectionMode,
                    selected: _selected.contains(task.id),
                    onToggle: () => _toggle(task),
                    onRetry: () => s.retryTask(task),
                    onPause: () => s.pauseTask(task),
                    onResume: () => s.resumeTask(task),
                    onPrioritize: () => s.prioritizeTask(task),
                    onRemove: () => s.removeTasks([task]),
                  ),
                );
              },
            ),
    );
  }

  AppBar _normalAppBar(
    AppState s, {
    required bool hasQueued,
    required bool hasPaused,
    required bool hasFailed,
    required bool hasFinished,
  }) {
    return AppBar(
      title: const Text('传输'),
      actions: [
        if (s.tasks.isNotEmpty)
          PopupMenuButton<String>(
            tooltip: '批量操作',
            icon: const Icon(Icons.more_vert),
            onSelected: (v) {
              switch (v) {
                case 'pause':
                  s.pauseAll();
                case 'resume':
                  s.resumeAll();
                case 'retry':
                  s.retryAllFailed();
                case 'clear':
                  s.clearFinishedTasks();
                case 'removeAll':
                  s.removeAllTasks();
              }
            },
            itemBuilder: (_) => [
              PopupMenuItem(
                value: 'pause',
                enabled: hasQueued,
                child: const ListTile(
                  dense: true,
                  leading: Icon(Icons.pause_circle_outline),
                  title: Text('全部暂停'),
                ),
              ),
              PopupMenuItem(
                value: 'resume',
                enabled: hasPaused,
                child: const ListTile(
                  dense: true,
                  leading: Icon(Icons.play_circle_outline),
                  title: Text('全部开始'),
                ),
              ),
              PopupMenuItem(
                value: 'retry',
                enabled: hasFailed,
                child: const ListTile(
                  dense: true,
                  leading: Icon(Icons.refresh),
                  title: Text('全部重试'),
                ),
              ),
              PopupMenuItem(
                value: 'clear',
                enabled: hasFinished,
                child: const ListTile(
                  dense: true,
                  leading: Icon(Icons.cleaning_services_outlined),
                  title: Text('清除已完成'),
                ),
              ),
              PopupMenuItem(
                value: 'removeAll',
                child: const ListTile(
                  dense: true,
                  leading: Icon(Icons.delete_sweep_outlined),
                  title: Text('移除全部'),
                ),
              ),
            ],
          ),
      ],
    );
  }

  AppBar _selectionAppBar(AppState s) {
    return AppBar(
      leading: IconButton(
        tooltip: '退出多选',
        icon: const Icon(Icons.close),
        onPressed: _exitSelection,
      ),
      title: Text('已选 ${_selected.length} 项'),
      actions: [
        IconButton(
          tooltip: '移除',
          icon: const Icon(Icons.delete_outline),
          onPressed: _selected.isEmpty ? null : () => _removeSelected(s),
        ),
      ],
    );
  }
}

class _EmptyTransfers extends StatelessWidget {
  const _EmptyTransfers();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.swap_vert, size: 48, color: scheme.outline),
          const SizedBox(height: 12),
          Text('没有传输任务', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 4),
          Text(
            '在「文件」页上传或下载后，任务会出现在这里',
            style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13),
          ),
        ],
      ),
    );
  }
}

class _TaskTile extends StatelessWidget {
  const _TaskTile({
    required this.task,
    required this.selectionMode,
    required this.selected,
    required this.onToggle,
    required this.onRetry,
    required this.onPause,
    required this.onResume,
    required this.onPrioritize,
    required this.onRemove,
  });

  final TransferTask task;
  final bool selectionMode;
  final bool selected;
  final VoidCallback onToggle;
  final VoidCallback onRetry;
  final VoidCallback onPause;
  final VoidCallback onResume;
  final VoidCallback onPrioritize;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final running = task.status == TransferStatus.running;
    final queued = task.status == TransferStatus.queued;
    final done = task.status == TransferStatus.done;
    final failed = task.status == TransferStatus.failed;
    final paused = task.status == TransferStatus.paused;

    return GlassCard(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (selectionMode)
                Checkbox(
                  value: selected,
                  onChanged: running ? null : (_) => onToggle(),
                  visualDensity: VisualDensity.compact,
                ),
              Icon(
                task.kind == TransferKind.upload
                    ? Icons.upload_file
                    : Icons.download,
                size: 20,
                color: done
                    ? scheme.primary
                    : failed
                    ? scheme.error
                    : scheme.onSurfaceVariant,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  task.name,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w500),
                ),
              ),
              const SizedBox(width: 8),
              _StatusLabel(task: task),
            ],
          ),
          if (running || queued) ...[
            const SizedBox(height: 10),
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: LinearProgressIndicator(
                value: running ? task.progress : null,
                minHeight: 6,
              ),
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                Text(
                  '${humanSize(task.sent)} / ${humanSize(task.total)}',
                  style: TextStyle(
                    fontSize: 12,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                const Spacer(),
                Text(
                  running ? humanSpeed(task.speed) : '排队中',
                  style: TextStyle(
                    fontSize: 12,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ],
          if (paused) ...[
            const SizedBox(height: 6),
            Text(
              '已暂停 · ${humanSize(task.sent)} / ${humanSize(task.total)}',
              style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
            ),
          ],
          if (done) ...[
            const SizedBox(height: 6),
            Text(
              '${task.kindLabel}完成 · ${humanSize(task.total)}'
              '${task.elapsed != null ? ' · ${humanDuration(task.elapsed!)}' : ''}',
              style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
            ),
          ],
          if (failed) ...[
            const SizedBox(height: 6),
            Text(
              task.error ?? '未知错误',
              style: TextStyle(fontSize: 12, color: scheme.error),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ],
          // 多选态只做勾选，避免误触；运行中的任务没有操作行（停不下来）。
          if (!selectionMode && !running) ...[
            const SizedBox(height: 2),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                if (queued) ...[
                  TextButton.icon(
                    onPressed: onPrioritize,
                    icon: const Icon(Icons.vertical_align_top, size: 16),
                    label: const Text('优先'),
                  ),
                  TextButton.icon(
                    onPressed: onPause,
                    icon: const Icon(Icons.pause, size: 16),
                    label: const Text('暂停'),
                  ),
                ],
                if (paused)
                  TextButton.icon(
                    onPressed: onResume,
                    icon: const Icon(Icons.play_arrow, size: 16),
                    label: const Text('开始'),
                  ),
                if (failed)
                  TextButton.icon(
                    onPressed: onRetry,
                    icon: const Icon(Icons.refresh, size: 16),
                    label: const Text('重试'),
                  ),
                TextButton.icon(
                  onPressed: onRemove,
                  style: TextButton.styleFrom(foregroundColor: scheme.error),
                  icon: const Icon(Icons.delete_outline, size: 16),
                  label: const Text('移除'),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _StatusLabel extends StatelessWidget {
  const _StatusLabel({required this.task});

  final TransferTask task;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (text, color) = switch (task.status) {
      TransferStatus.queued => ('排队中', scheme.onSurfaceVariant),
      TransferStatus.running => ('${task.kindLabel}中', scheme.primary),
      TransferStatus.done => ('已完成', scheme.onSurfaceVariant),
      TransferStatus.failed => ('失败', scheme.error),
      TransferStatus.paused => ('已暂停', scheme.tertiary),
    };
    return Text(
      text,
      style: TextStyle(fontSize: 12, color: color, fontWeight: FontWeight.w500),
    );
  }
}
