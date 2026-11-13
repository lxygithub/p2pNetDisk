import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/app_state.dart';

/// 路径面包屑：`/ › photos › 2026`，每段可点回对应层级。
///
/// 根目录时整行隐藏，避免占位；非根目录左侧额外给一个「上一级」按钮。
class Breadcrumb extends StatelessWidget {
  const Breadcrumb({super.key});

  @override
  Widget build(BuildContext context) {
    final s = context.watch<AppState>();
    final parts = s.cwdParts;
    if (parts.isEmpty) return const SizedBox.shrink();

    final scheme = Theme.of(context).colorScheme;

    return Material(
      color: Colors.transparent,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 2, 16, 2),
        child: Row(
          children: [
            IconButton(
              tooltip: '上一级',
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.arrow_upward, size: 18),
              onPressed: s.busy ? null : s.goUp,
            ),
            Expanded(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    TextButton(
                      style: TextButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                        minimumSize: const Size(0, 32),
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                      ),
                      onPressed: s.busy ? null : () => s.goToDepth(0),
                      child: const Text('/'),
                    ),
                    for (var i = 0; i < parts.length; i++) ...[
                      Icon(Icons.chevron_right, size: 16, color: scheme.outline),
                      TextButton(
                        style: TextButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                          minimumSize: const Size(0, 32),
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                        ),
                        onPressed:
                            s.busy ? null : () => s.goToDepth(i + 1),
                        child: Text(
                          parts[i],
                          style: TextStyle(
                            color: i == parts.length - 1
                                ? scheme.onSurface
                                : scheme.onSurfaceVariant,
                            fontWeight: i == parts.length - 1
                                ? FontWeight.w600
                                : FontWeight.normal,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
