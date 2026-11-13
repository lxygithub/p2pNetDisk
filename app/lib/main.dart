import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'pages/home_shell.dart';
import 'state/app_state.dart';
import 'theme.dart';
import 'widgets/glass.dart';

void main() => runApp(const NetdiskApp());

class NetdiskApp extends StatelessWidget {
  const NetdiskApp({super.key, this.autoConnect = true});

  /// 是否在启动时自动连接。widget 测试里关掉，避免留下重试定时器。
  final bool autoConnect;

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider(
      create: (_) {
        final state = AppState();
        // 启动即自动连接并拉列表，用户不用先点「连接」。
        if (autoConnect) unawaited(state.bootstrap());
        return state;
      },
      child: MaterialApp(
        title: '个人网盘',
        debugShowCheckedModeBanner: false,
        builder: (context, child) =>
            GlassBackground(child: child ?? const SizedBox.shrink()),
        theme: buildAppTheme(Brightness.light),
        darkTheme: buildAppTheme(Brightness.dark),
        home: const HomeShell(),
      ),
    );
  }
}
