import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'pages/home_shell.dart';
import 'services/connection_prefs.dart';
import 'state/app_state.dart';
import 'theme.dart';
import 'widgets/glass.dart';

Future<void> main() async {
  // path_provider 走平台通道，必须在 runApp 之前绑定好引擎。
  WidgetsFlutterBinding.ensureInitialized();
  // 本机保存的连接参数先读出来，页面构建时就是最终值。
  final saved = await ConnectionPrefs.read();
  runApp(NetdiskApp(savedConfig: saved));
}

class NetdiskApp extends StatelessWidget {
  const NetdiskApp({
    super.key,
    this.autoConnect = true,
    this.savedConfig,
  });

  /// 是否在启动时自动连接。widget 测试里关掉，避免留下重试定时器。
  final bool autoConnect;

  /// main() 在启动阶段读入的本机连接配置，null 表示用编译期默认值。
  final ConnectionConfig? savedConfig;

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider(
      create: (_) {
        final state = AppState(savedConfig: savedConfig);
        // 启动即自动连接并拉列表，用户不用先点「连接」。
        if (autoConnect) unawaited(state.bootstrap());
        return state;
      },
      child: MaterialApp(
        title: 'p2pNetDisk',
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
