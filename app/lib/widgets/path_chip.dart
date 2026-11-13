import 'package:flutter/material.dart';

/// 传输路径徽标：直连用高亮色 + 闪电图标，中继用中性色 + 云图标。
///
/// 用户有权知道自己的数据有没有经过中继服务器，所以这个信息常驻标题栏。
class PathChip extends StatelessWidget {
  const PathChip({super.key, required this.text});

  /// 形如 `直连 · 8 ms` 或 `中继 · 1.2 s`。
  final String text;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final direct = text.startsWith('直连');
    final bg = direct ? scheme.tertiaryContainer : scheme.surfaceContainerHighest;
    final fg = direct ? scheme.onTertiaryContainer : scheme.onSurfaceVariant;

    return Center(
      child: Container(
        margin: const EdgeInsets.only(right: 4),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(direct ? Icons.bolt : Icons.cloud_queue, size: 14, color: fg),
            const SizedBox(width: 4),
            Text(
              text,
              style: TextStyle(
                fontSize: 11,
                color: fg,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
