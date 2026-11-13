import 'package:flutter_test/flutter_test.dart';

import 'package:netdisk_app/main.dart';

void main() {
  testWidgets('未连接时文件页给出提示', (tester) async {
    await tester.pumpWidget(const NetdiskApp());
    await tester.pump();

    // 「文件」同时出现在 AppBar 标题和底部导航标签。
    expect(find.text('文件'), findsWidgets);
    // 状态栏初始文案。
    expect(find.text('未连接'), findsOneWidget);
    // 未连接时不再显示「上传」FAB，而是提示去设置页连接。
    expect(find.textContaining('尚未连接'), findsOneWidget);
  });
}
