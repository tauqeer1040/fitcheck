import 'package:flutter_test/flutter_test.dart';

import 'package:fitcheck/main.dart';

void main() {
  testWidgets('App renders gallery screen', (WidgetTester tester) async {
    await tester.pumpWidget(const FitCheckApp());
    expect(find.text('FitCheck'), findsOneWidget);
  });
}
