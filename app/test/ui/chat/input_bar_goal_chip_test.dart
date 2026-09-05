// Goal-mode toggle button and quick-actions status chip pinned on the
// input bar next to history recall.
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
            activeModel: 'zai/glm-5.3-flash',
            activeThinking: 'high',
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

  testWidgets('status chip shows model and thinking, opens quick actions',
      (tester) async {
    var opened = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: InputBar(
            onSend: (_) {},
            onOpenQuickActions: () => opened = true,
            activeModel: 'zai/glm-5.3-flash',
            activeThinking: 'high',
          ),
        ),
      ),
    );
    expect(find.text('glm-5...·high'), findsOneWidget);
    await tester.tap(find.text('glm-5...·high'));
    expect(opened, isTrue);
  });

  testWidgets('status chip falls back to Actions label without meta',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: InputBar(onSend: (_) {}, onOpenQuickActions: () {}),
        ),
      ),
    );
    expect(find.text('Actions'), findsOneWidget);
  });
}
