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

  /// 结果列表的渲染上限。超过时明确提示「只显示前 N 条」，
  /// 而不是悄悄吞掉 —— 静默截断会让人以为文件不存在。
  static const int _maxResults = 200;

  ({List<SearchHit> hits, bool truncated}) _search(AppState state) {
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return (hits: const <SearchHit>[], truncated: false);

    final out = <SearchHit>[];
    var truncated = false;
    for (final f in state.files) {
      if (!_lastSegment(f.path).toLowerCase().contains(q)) continue;
      if (out.length >= _maxResults) {
        truncated = true;
        break;
      }
      out.add((path: f.path, isDir: f.isDir));
    }
    out.sort((a, b) => a.path.compareTo(b.path));
    return (hits: out, truncated: truncated);
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
    final scheme = Theme.of(context).colorScheme;
    final search = _search(state);
    final results = search.hits;

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
          : Column(
              children: [
                if (search.truncated)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
                    child: Text(
                      '结果较多，仅显示前 $_maxResults 条，试试更精确的关键字',
                      style: TextStyle(
                        fontSize: 11,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                Expanded(
                  child: ListView.separated(
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
                ),
              ],
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
