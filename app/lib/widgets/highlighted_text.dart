import 'package:flutter/material.dart';

/// 文本高亮：把 [text] 里所有匹配 [query] 的片段用主题色加粗显示。
///
/// 大小写不敏感；query 为空时原样输出。
class HighlightedText extends StatelessWidget {
  const HighlightedText({
    super.key,
    required this.text,
    required this.query,
    this.style,
    this.maxLines = 1,
  });

  final String text;
  final String query;
  final TextStyle? style;
  final int maxLines;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final base = style ?? DefaultTextStyle.of(context).style;
    final needle = query.trim().toLowerCase();

    if (needle.isEmpty) {
      return Text(
        text,
        style: base,
        maxLines: maxLines,
        overflow: TextOverflow.ellipsis,
      );
    }

    final lower = text.toLowerCase();
    final spans = <TextSpan>[];
    var start = 0;
    while (true) {
      final i = lower.indexOf(needle, start);
      if (i < 0) {
        if (start < text.length) {
          spans.add(TextSpan(text: text.substring(start)));
        }
        break;
      }
      if (i > start) spans.add(TextSpan(text: text.substring(start, i)));
      spans.add(
        TextSpan(
          text: text.substring(i, i + needle.length),
          style: TextStyle(color: scheme.primary, fontWeight: FontWeight.w700),
        ),
      );
      start = i + needle.length;
    }

    return Text.rich(
      TextSpan(children: spans),
      style: base,
      maxLines: maxLines,
      overflow: TextOverflow.ellipsis,
    );
  }
}
