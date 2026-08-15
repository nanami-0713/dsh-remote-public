import 'package:flutter_test/flutter_test.dart';

import 'package:dsh_remote/main.dart';

void main() {
  testWidgets('DSH Remote app builds', (WidgetTester tester) async {
    await tester.pumpWidget(const DshRemoteApp());
    expect(find.text('DSH-Remote'), findsOneWidget);
  });
}
