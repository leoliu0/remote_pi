import 'package:app/ui/chat/widgets/input_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('goal button prefills composer with /goal when idle or new',
      (tester) async {
    String? sent;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: InputBar(
            onSend: (t) => sent = t,
            goalStatus: 'idle',
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

  testWidgets('goal button resumes paused goal with /goal resume on tap',
      (tester) async {
    String? sent;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: InputBar(
            onSend: (t) => sent = t,
            goalStatus: 'paused',
          ),
        ),
      ),
    );

    final goalKey = find.byKey(const Key('input-bar-goal-mode'));
    expect(goalKey, findsOneWidget);
    await tester.tap(goalKey);
    await tester.pump();
    expect(sent, '/goal resume');
  });

  testWidgets('goal button shows active indicator when goal is active',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: InputBar(
            onSend: (_) {},
            goalStatus: 'active',
          ),
        ),
      ),
    );

    final goalButton = tester.widget<IconButton>(
      find.byKey(const Key('input-bar-goal-mode')),
    );
    expect(goalButton.tooltip, contains('active'));
  });
}
