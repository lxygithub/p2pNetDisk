import 'package:flutter/material.dart';

import '../services/path_utils.dart';
import '../state/app_state.dart';
import 'text_input_dialog.dart';
import '../widgets/app_icons.dart';

/// 选择远端目录：逐级浏览 + 新建 + 「选择此目录」。
///
/// 返回以 `/` 结尾的相对路径，根目录返回空串，取消返回 null。
/// 批量移动/复制用它替代手输路径 —— 手输既要记路径又容易打错，还会撞上
/// 「目标已存在」的报错。
Future<String?> showDirectoryPicker(
  BuildContext context, {
  required AppState state,
  String title = '选择目录',
}) {
  return showDialog<String>(
    context: context,
    builder: (_) => _DirectoryPickerDialog(state: state, title: title),
  );
}

class _DirectoryPickerDialog extends StatefulWidget {
  const _DirectoryPickerDialog({required this.state, required this.title});

  final AppState state;
  final String title;

  @override
  State<_DirectoryPickerDialog> createState() => _DirectoryPickerDialogState();
}

class _DirectoryPickerDialogState extends State<_DirectoryPickerDialog> {
  String _cwd = '';

  void _enter(String name) => setState(() => _cwd = '$_cwd$name/');

  void _goTo(String dir) => setState(() => _cwd = dir);

  void _goUp() {
    if (_cwd.isEmpty) return;
    setState(() => _cwd = parentOf(_cwd));
  }

  Future<void> _create() async {
    final name = await showTextInputDialog(
      context,
      title: '新建文件夹',
      label: '文件夹名',
      initial: '新文件夹',
      confirmLabel: '创建',
    );
    final trimmed = name?.trim() ?? '';
    if (trimmed.isEmpty) return;

    final ok = await widget.state.createDirAt(_cwd, trimmed);
    if (!mounted || ok) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(widget.state.status)));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      contentPadding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
      content: SizedBox(
        width: 420,
        height: 380,
        child: ListenableBuilder(
          listenable: widget.state,
          builder: (context, _) => _browser(),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        TextButton.icon(
          onPressed: _create,
          icon: const AppIconView(
            AppIcons.create_new_folder_outlined,
            size: 18,
          ),
          label: const Text('新建'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _cwd),
          child: const Text('选择此目录'),
        ),
      ],
    );
  }

  Widget _browser() {
    final dirs = childDirNames(widget.state.files, _cwd);
    final showUp = _cwd.isNotEmpty;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _crumbs(),
        const Divider(height: 1),
        Expanded(
          child: dirs.isEmpty && !showUp
              ? const Center(
                  child: Text('没有子目录', style: TextStyle(fontSize: 12)),
                )
              : ListView.builder(
                  itemCount: dirs.length + (showUp ? 1 : 0),
                  itemBuilder: (context, i) {
                    if (showUp && i == 0) {
                      return ListTile(
                        dense: true,
                        leading: const AppIconView(
                          AppIcons.arrow_upward,
                          size: 20,
                        ),
                        title: const Text('上级目录'),
                        onTap: _goUp,
                      );
                    }
                    final name = dirs[showUp ? i - 1 : i];
                    return ListTile(
                      dense: true,
                      leading: const AppIconView(
                        AppIcons.folder_rounded,
                        size: 20,
                      ),
                      title: Text(name, overflow: TextOverflow.ellipsis),
                      trailing: const AppIconView(
                        AppIcons.chevron_right,
                        size: 18,
                      ),
                      onTap: () => _enter(name),
                    );
                  },
                ),
        ),
        const Divider(height: 1),
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 8, 8, 10),
          child: Text(
            _cwd.isEmpty ? '当前：根目录' : '当前：$_cwd',
            style: const TextStyle(fontSize: 11),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }

  /// 面包屑：根目录 / a / b，最后一段不可点（就是当前层）。
  Widget _crumbs() {
    final parts = _cwd.split('/').where((e) => e.isNotEmpty).toList();
    final children = <Widget>[
      TextButton(
        onPressed: _cwd.isEmpty ? null : () => _goTo(''),
        child: const Text('根目录', style: TextStyle(fontSize: 12)),
      ),
    ];
    var acc = '';
    for (var i = 0; i < parts.length; i++) {
      acc += '${parts[i]}/';
      final dir = acc;
      final isLast = i == parts.length - 1;
      children.add(const Text('/', style: TextStyle(fontSize: 12)));
      children.add(
        TextButton(
          onPressed: isLast ? null : () => _goTo(dir),
          child: Text(parts[i], style: const TextStyle(fontSize: 12)),
        ),
      );
    }
    return SizedBox(
      height: 40,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(children: children),
      ),
    );
  }
}
