// Basic smoke test for LANShare.
//
// The default `flutter create` template generates a counter-app test that
// references a `MyApp` widget. This project's root widget is `LanShareApp`
// (see lib/main.dart) and there is no counter, so that template test no
// longer applies - this replaces it with a smoke test that matches the
// actual app.

import 'package:flutter_test/flutter_test.dart';

import 'package:lanshare/main.dart';

void main() {
  testWidgets('HomePage shows Create Server and Join Server buttons', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const LanShareApp());

    expect(find.text('Create Server'), findsOneWidget);
    expect(find.text('Join Server'), findsOneWidget);
  });
}
