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

  // 读本机保存的连接参数，但**绝不能让这一步挡住首帧**。
  //
  // 从后台恢复、进程刚重建时，平台通道偶发迟迟不返回；如果这里无限等待，
  // `runApp` 就不会执行、Flutter 首帧不渲染，Android 的开屏 logo 会一直挂着
  // —— 表现就是「偶现切回前台卡在启动页」。正常情况下这一步 < 50ms。
  ConnectionConfig? saved;
  try {
    saved = await ConnectionPrefs.read().timeout(const Duration(seconds: 3));
  } catch (_) {
    // 超时/异常都退回编译期默认值，先让界面起来。
    saved = null;
  }
  runApp(NetdiskApp(savedConfig: saved));
}

class NetdiskApp extends StatelessWidget {
  const NetdiskApp({super.key, this.autoConnect = true, this.savedConfig});

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
