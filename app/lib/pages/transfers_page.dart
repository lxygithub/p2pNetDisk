import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/transfer_task.dart';
import '../state/app_state.dart';
import '../theme.dart';

/// 传输队列页：串行执行的上传/下载任务列表，含实时进度与速度。
class TransfersPage extends StatelessWidget {
  const TransfersPage({super.key});

  @override
  Widget build(BuildContext context) {
    final s = context.watch<AppState>();

    return Scaffold(
      appBar: AppBar(
        title: const Text('传输'),
        actions: [
          if (s.tasks.any((t) =>
              t.status == TransferStatus.done ||
              t.status == TransferStatus.failed))
            IconButton(
              tooltip: '清除已完成',
              onPressed: s.clearFinishedTasks,
              icon: const Icon(Icons.cleaning_services_outlined),
            ),
        ],
      ),
      body: s.tasks.isEmpty
          ? const _EmptyTransfers()
          : ListView.separated(
              padding: kPagePadding,
              itemCount: s.tasks.length,
              separatorBuilder: (_, _) => const SizedBox(height: 8),
              itemBuilder: (context, i) => _TaskTile(
                task: s.tasks[i],
                onRetry: () => s.retryTask(s.tasks[i]),
              ),
            ),
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
  const _TaskTile({required this.task, required this.onRetry});

  final TransferTask task;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final running = task.status == TransferStatus.running;
    final queued = task.status == TransferStatus.queued;
    final done = task.status == TransferStatus.done;
    final failed = task.status == TransferStatus.failed;

    return Material(
      color: scheme.surfaceContainerLow,
      borderRadius: BorderRadius.circular(14),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
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
              const SizedBox(height: 6),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                  onPressed: onRetry,
                  icon: const Icon(Icons.refresh, size: 16),
                  label: const Text('重试'),
                ),
              ),
            ],
          ],
        ),
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
    };
    return Text(
      text,
      style: TextStyle(fontSize: 12, color: color, fontWeight: FontWeight.w500),
    );
  }
}
