import 'package:app/ui/chat/widgets/input_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('goal button opens menu and selecting new goal prefills /goal',
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
    await tester.pumpAndSettle();

    final newGoalOption = find.byKey(const Key('goal-menu-new'));
    expect(newGoalOption, findsOneWidget);
    await tester.tap(newGoalOption);
    await tester.pumpAndSettle();

    expect(sent, isNull);
    expect(find.widgetWithText(TextField, '/goal '), findsOneWidget);
  });

  testWidgets('goal button opens menu and selecting resume sends /goal resume',
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
    await tester.pumpAndSettle();

    final resumeOption = find.byKey(const Key('goal-menu-resume'));
    expect(resumeOption, findsOneWidget);
    await tester.tap(resumeOption);
    await tester.pumpAndSettle();

    expect(sent, '/goal resume');
  });

  testWidgets('goal button opens menu when active and pause sends /goal pause',
      (tester) async {
    String? sent;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: InputBar(
            onSend: (t) => sent = t,
            goalStatus: 'active',
          ),
        ),
      ),
    );

    final goalKey = find.byKey(const Key('input-bar-goal-mode'));
    expect(goalKey, findsOneWidget);
    await tester.tap(goalKey);
    await tester.pumpAndSettle();

    final pauseOption = find.byKey(const Key('goal-menu-pause'));
    expect(pauseOption, findsOneWidget);
    await tester.tap(pauseOption);
    await tester.pumpAndSettle();

    expect(sent, '/goal pause');
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
