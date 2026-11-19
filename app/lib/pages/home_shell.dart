import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/app_state.dart';
import 'files_page.dart';
import 'settings_page.dart';
import 'transfers_page.dart';
import '../widgets/app_icons.dart';

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
                icon: AppIconView(AppIcons.folder_outlined, stroke: 1.5),
                selectedIcon: AppIconView(AppIcons.folder, stroke: 2.1),
                label: '文件',
              ),
              NavigationDestination(
                icon: active > 0
                    ? Badge(
                        label: Text('$active'),
                        child: const AppIconView(AppIcons.swap_vert),
                      )
                    : const AppIconView(AppIcons.swap_vert),
                selectedIcon: active > 0
                    ? Badge(
                        label: Text('$active'),
                        child: const AppIconView(AppIcons.swap_vert),
                      )
                    : const AppIconView(AppIcons.swap_vert),
                label: '传输',
              ),
              const NavigationDestination(
                icon: AppIconView(AppIcons.settings_outlined),
                selectedIcon: AppIconView(AppIcons.settings),
                label: '设置',
              ),
            ],
          ),
        ),
      ),
    );
  }
}
