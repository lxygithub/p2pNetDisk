import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/app_state.dart';
import 'files_page.dart';
import 'settings_page.dart';
import 'transfers_page.dart';

/// 底部导航外壳：文件 / 传输 / 设置。
///
/// 用 `IndexedStack` 而不是切换 body，页面状态（滚动位置、输入内容）在切页后保留。
class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _index = 0;

  @override
  Widget build(BuildContext context) {
    final active = context.select<AppState, int>((s) => s.activeCount);

    return Scaffold(
      body: IndexedStack(
        index: _index,
        children: const [FilesPage(), TransfersPage(), SettingsPage()],
      ),
      bottomNavigationBar: ClipRect(
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
          child: NavigationBar(
            selectedIndex: _index,
            onDestinationSelected: (i) => setState(() => _index = i),
            destinations: [
              const NavigationDestination(
                icon: Icon(Icons.folder_outlined),
                selectedIcon: Icon(Icons.folder),
                label: '文件',
              ),
              NavigationDestination(
                icon: active > 0
                    ? Badge(
                        label: Text('$active'),
                        child: const Icon(Icons.swap_vert),
                      )
                    : const Icon(Icons.swap_vert),
                selectedIcon: active > 0
                    ? Badge(
                        label: Text('$active'),
                        child: const Icon(Icons.swap_vert),
                      )
                    : const Icon(Icons.swap_vert),
                label: '传输',
              ),
              const NavigationDestination(
                icon: Icon(Icons.settings_outlined),
                selectedIcon: Icon(Icons.settings),
                label: '设置',
              ),
            ],
          ),
        ),
      ),
    );
  }
}
