import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/search_prefs.dart';
import '../state/app_state.dart';
import '../theme.dart';
import '../widgets/highlighted_text.dart';

typedef SearchHit = ({String path, bool isDir});

/// 全盘文件名搜索：结果高亮、点目录跳转、点文件预览，历史可复用。
class SearchPage extends StatefulWidget {
  const SearchPage({super.key});

  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage> {
  final TextEditingController _controller = TextEditingController();
  List<String> _history = const [];
  String _query = '';

  @override
  void initState() {
    super.initState();
    SearchPrefs.read().then((h) {
      if (mounted) setState(() => _history = h);
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  static String _lastSegment(String path) {
    final clean = path.endsWith('/')
        ? path.substring(0, path.length - 1)
        : path;
    final i = clean.lastIndexOf('/');
    return i < 0 ? clean : clean.substring(i + 1);
  }

  static String _parentOf(String path) {
    final clean = path.endsWith('/')
        ? path.substring(0, path.length - 1)
        : path;
    final i = clean.lastIndexOf('/');
    return i < 0 ? '根目录' : clean.substring(0, i);
  }

  List<SearchHit> _results(AppState state) {
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return const [];

    final out = <SearchHit>[];
    for (final f in state.files) {
      if (!_lastSegment(f.path).toLowerCase().contains(q)) continue;
      out.add((path: f.path, isDir: f.isDir));
      if (out.length >= 200) break; // 结果太多反而没法看
    }
    out.sort((a, b) => a.path.compareTo(b.path));
    return out;
  }

  void _run(String keyword, {bool remember = false}) {
    final trimmed = keyword.trim();
    setState(() => _query = trimmed);
    if (!remember || trimmed.isEmpty) return;
    SearchPrefs.add(trimmed).then((h) {
      if (mounted) setState(() => _history = h);
    });
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final results = _results(state);

    return Scaffold(
      appBar: AppBar(
        title: TextField(
          controller: _controller,
          autofocus: true,
          textInputAction: TextInputAction.search,
          decoration: const InputDecoration(
            hintText: '搜索文件 / 文件夹名',
            border: InputBorder.none,
          ),
          onChanged: _run,
          onSubmitted: (v) => _run(v, remember: true),
        ),
        actions: [
          if (_controller.text.isNotEmpty)
            IconButton(
              tooltip: '清空',
              icon: const Icon(Icons.close),
              onPressed: () {
                _controller.clear();
                _run('');
              },
            ),
        ],
      ),
      body: _query.isEmpty
          ? _historyView()
          : results.isEmpty
          ? const Center(child: Text('没有匹配的文件'))
          : ListView.separated(
              padding: kPagePadding,
              itemCount: results.length,
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (context, i) {
                final hit = results[i];
                final name = _lastSegment(hit.path);
                return ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(
                    hit.isDir
                        ? Icons.folder_rounded
                        : Icons.description_outlined,
                  ),
                  title: HighlightedText(text: name, query: _query),
                  subtitle: Text(
                    _parentOf(hit.path),
                    style: const TextStyle(fontSize: 11),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  onTap: () => Navigator.pop(context, hit),
                );
              },
            ),
    );
  }

  Widget _historyView() {
    if (_history.isEmpty) {
      return const Center(
        child: Text('输入关键字开始搜索', style: TextStyle(fontSize: 13)),
      );
    }
    return ListView(
      padding: kPagePadding,
      children: [
        Row(
          children: [
            const Text('搜索历史', style: TextStyle(fontSize: 12)),
            const Spacer(),
            TextButton(
              onPressed: () async {
                await SearchPrefs.clear();
                if (mounted) setState(() => _history = const []);
              },
              child: const Text('清空'),
            ),
          ],
        ),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final h in _history)
              ActionChip(
                label: Text(h),
                onPressed: () {
                  _controller.text = h;
                  _run(h, remember: true);
                },
              ),
          ],
        ),
      ],
    );
  }
}
