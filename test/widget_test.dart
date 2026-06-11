import 'package:flutter_test/flutter_test.dart';

import 'package:vhosts/main.dart';

void main() {
  testWidgets('app boots without throwing', (WidgetTester tester) async {
    await tester.pumpWidget(const VhostsApp());
    await tester.pump();

    expect(find.byType(VhostsApp), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
