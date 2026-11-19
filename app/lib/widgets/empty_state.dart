import 'package:flutter/material.dart';

import 'app_icons.dart';

/// 统一的空白页占位：严格居中（横竖都居中）。
///
/// 直接把 `_EmptyState` 放进 `ListView.children` 时，ListView 会把内容顶到最上面，
/// `Center` 只在横向生效 —— 用户看到的「空白页文字贴在顶部」就是这个原因。
/// 这里用 `LayoutBuilder` 拿到父级高度，用 `ConstrainedBox(minHeight: 视口高)`
/// 撑满，再 `Center`，同时保留 `AlwaysScrollableScrollPhysics` 让下拉刷新可用。
class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    this.action,
  });

  final AppIcon icon;
  final String title;
  final String subtitle;

  /// 可选的额外操作（比如「重试」按钮），放在文案下方。
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: constraints.maxHeight),
          child: Center(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(32, 24, 32, 48),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Container(
                    width: 88,
                    height: 88,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: scheme.primaryContainer.withValues(alpha: 0.45),
                    ),
                    child: Center(
                      child: AppIconView(
                        icon,
                        size: 40,
                        color: scheme.primary,
                        stroke: 1.5,
                      ),
                    ),
                  ),
                  const SizedBox(height: 22),
                  Text(
                    title,
                    textAlign: TextAlign.center,
                    style: textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    subtitle,
                    textAlign: TextAlign.center,
                    style: textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                      height: 1.5,
                    ),
                  ),
                  if (action != null) ...[const SizedBox(height: 24), action!],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
