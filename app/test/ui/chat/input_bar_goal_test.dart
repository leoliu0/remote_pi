import 'package:app/ui/chat/widgets/input_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('goal button prefills composer with /goal instead of sending',
      (tester) async {
    String? sent;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: InputBar(
            onSend: (t) => sent = t,
          ),
        ),
      ),
    );

    final goalKey = find.byKey(const Key('input-bar-goal-mode'));
    expect(goalKey, findsOneWidget);
    await tester.tap(goalKey);
    await tester.pump();
    expect(sent, isNull);
    expect(find.widgetWithText(TextField, '/goal '), findsOneWidget);
  });
}
