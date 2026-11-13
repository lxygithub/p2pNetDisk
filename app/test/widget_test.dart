import 'package:flutter_test/flutter_test.dart';

import 'package:netdisk_app/main.dart';

void main() {
  testWidgets('home page renders without the native library', (tester) async {
    await tester.pumpWidget(const NetdiskApp());

    expect(find.text('个人网盘'), findsOneWidget);
    expect(find.text('未连接'), findsOneWidget);
    expect(find.text('连接'), findsOneWidget);
  });
}
