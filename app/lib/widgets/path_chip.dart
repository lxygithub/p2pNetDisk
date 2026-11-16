import 'package:flutter/material.dart';

/// 传输路径徽标：直连用闪电图标、中继用云图标，背景色按 RTT 分档。
///
/// 用户有权知道自己的数据有没有经过中继服务器，所以这个信息常驻标题栏；
/// 延迟用颜色表达比读数字更快：
/// - ≤ 60ms  绿（直连通常在这个区间）
/// - ≤ 160ms 橘（可用，但已经开始影响列表/预览手感）
/// - > 160ms 红（多为中继或链路质量差）
class PathChip extends StatelessWidget {
  const PathChip({super.key, required this.text, this.latencyMs});

  /// 形如 `直连 · 8 ms` 或 `中继 · 1.2 s`。
  final String text;

  /// 链路 RTT（毫秒）。null 表示未知（旧动态库或还没探测），退回默认配色。
  final int? latencyMs;

  static const int goodMax = 60;
  static const int warnMax = 160;

  String get _qualityLabel {
    final ms = latencyMs;
    if (ms == null) return '延迟未知';
    if (ms <= goodMax) return '低延迟';
    if (ms <= warnMax) return '延迟一般';
    return '高延迟';
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final direct = text.startsWith('直连');
    final ms = latencyMs;

    Color bg;
    Color fg;
    if (ms == null) {
      // 没有数值时保持原有语义：直连高亮、中继中性。
      bg = direct ? scheme.tertiaryContainer : scheme.surfaceContainerHighest;
      fg = direct ? scheme.onTertiaryContainer : scheme.onSurfaceVariant;
    } else if (ms <= goodMax) {
      bg = dark ? const Color(0xFF14432B) : const Color(0xFFD9F5E4);
      fg = dark ? const Color(0xFF7BE3A6) : const Color(0xFF11663C);
    } else if (ms <= warnMax) {
      bg = dark ? const Color(0xFF4A3212) : const Color(0xFFFFEBCF);
      fg = dark ? const Color(0xFFF5B95B) : const Color(0xFF8A5300);
    } else {
      bg = dark ? const Color(0xFF4A1D1D) : const Color(0xFFFFDADA);
      fg = dark ? const Color(0xFFFF9A9A) : const Color(0xFF9B1C1C);
    }

    return Center(
      child: Tooltip(
        message: ms == null ? text : '$text（$_qualityLabel）',
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
      ),
    );
  }
}
