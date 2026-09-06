import 'package:app/ui/chat/widgets/input_bar.dart';
import 'package:app/ui/chat/widgets/loop_menu_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('loop button opens menu and selecting enable loop sends /loop',
      (tester) async {
    String? sent;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: InputBar(
            onSend: (t) => sent = t,
            loopStatus: 'idle',
          ),
        ),
      ),
    );

    final loopKey = find.byKey(const Key('input-bar-loop-mode'));
    expect(loopKey, findsOneWidget);
    await tester.tap(loopKey);
    await tester.pumpAndSettle();

    final enableOption = find.byKey(const Key('loop-menu-enable'));
    expect(enableOption, findsOneWidget);
    await tester.tap(enableOption);
    await tester.pumpAndSettle();

    expect(sent, '/loop');
  });

  testWidgets('loop button opens menu when active and pause sends /loop',
      (tester) async {
    String? sent;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: InputBar(
            onSend: (t) => sent = t,
            loopStatus: 'active',
          ),
        ),
      ),
    );

    final loopKey = find.byKey(const Key('input-bar-loop-mode'));
    expect(loopKey, findsOneWidget);
    await tester.tap(loopKey);
    await tester.pumpAndSettle();

    final pauseOption = find.byKey(const Key('loop-menu-pause'));
    expect(pauseOption, findsOneWidget);
    await tester.tap(pauseOption);
    await tester.pumpAndSettle();

    expect(sent, '/loop');
  });

  testWidgets('loop button shows active indicator when loop is active',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: InputBar(
            onSend: (_) {},
            loopStatus: 'active',
          ),
        ),
      ),
    );

    final loopButton = tester.widget<IconButton>(
      find.byKey(const Key('input-bar-loop-mode')),
    );
    expect(loopButton.tooltip, contains('active'));
  });

  testWidgets('loop button shows warning badge when loop is paused',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: InputBar(
            onSend: (_) {},
            loopStatus: 'paused',
          ),
        ),
      ),
    );

    final loopButton = tester.widget<IconButton>(
      find.byKey(const Key('input-bar-loop-mode')),
    );
    expect(loopButton.tooltip, contains('paused'));
  });
}
