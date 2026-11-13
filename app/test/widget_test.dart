import 'package:flutter_test/flutter_test.dart';

import 'package:netdisk_app/main.dart';

void main() {
  testWidgets('未连接时文件页给出提示', (tester) async {
    await tester.pumpWidget(const NetdiskApp(autoConnect: false));
    await tester.pump();

    // 「文件」同时出现在 AppBar 标题和底部导航标签。
    expect(find.text('文件'), findsWidgets);
    // 「未连接」出现在空状态标题和底部状态栏。
    expect(find.text('未连接'), findsWidgets);
    // 未连接时给出重试入口，而不是静默空白。
    expect(find.text('重试'), findsOneWidget);
  });
}
