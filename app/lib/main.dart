import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'pages/home_shell.dart';
import 'state/app_state.dart';
import 'theme.dart';
import 'widgets/glass.dart';

void main() => runApp(const NetdiskApp());

class NetdiskApp extends StatelessWidget {
  const NetdiskApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider(
      create: (_) => AppState(),
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
