import 'package:flutter/material.dart';

/// 文本输入对话框，`TextEditingController` 由对话框自己持有并释放。
///
/// **不要在 `showDialog` 外面 new 一个 controller、等 `await` 返回后立刻
/// `dispose()`**：`Navigator.pop` 之后关闭动画还在跑，`TextField` 仍挂在树上游，
/// 这时 dispose 会触发 `'_dependents.isEmpty': is not true` 断言并整屏红掉。
/// 把生命周期交给对话框的 State，是这类问题的标准解法。
///
/// 预填内容会自动全选，用户直接输入即可替换。
Future<String?> showTextInputDialog(
  BuildContext context, {
  required String title,
  String? label,
  String? helper,
  String initial = '',
  String confirmLabel = '确定',
}) {
  return showDialog<String>(
    context: context,
    builder: (_) => _TextInputDialog(
      title: title,
      label: label,
      helper: helper,
      initial: initial,
      confirmLabel: confirmLabel,
    ),
  );
}

class _TextInputDialog extends StatefulWidget {
  const _TextInputDialog({
    required this.title,
    required this.label,
    required this.helper,
    required this.initial,
    required this.confirmLabel,
  });

  final String title;
  final String? label;
  final String? helper;
  final String initial;
  final String confirmLabel;

  @override
  State<_TextInputDialog> createState() => _TextInputDialogState();
}

class _TextInputDialogState extends State<_TextInputDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initial,
  );

  @override
  void initState() {
    super.initState();
    _controller.selection = TextSelection(
      baseOffset: 0,
      extentOffset: widget.initial.length,
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() => Navigator.pop(context, _controller.text);

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: TextField(
        controller: _controller,
        autofocus: true,
        textInputAction: TextInputAction.done,
        onSubmitted: (_) => _submit(),
        decoration: InputDecoration(
          labelText: widget.label,
          helperText: widget.helper,
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(onPressed: _submit, child: Text(widget.confirmLabel)),
      ],
    );
  }
}
