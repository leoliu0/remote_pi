// Plan/32a — the thinking cursor: an empty StreamingMessage renders just the
// blinking cursor (no text), so the cursor shows during the pre-chunk gap.

import 'package:app/domain/session_state.dart';
import 'package:app/ui/chat/widgets/agent_markdown.dart';
import 'package:app/ui/chat/widgets/streaming_bubble.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<void> pump(WidgetTester tester, StreamingMessage m) {
    return tester.pumpWidget(
      MaterialApp(home: Scaffold(body: StreamingBubble(streaming: m))),
    );
  }

  testWidgets('empty buffer without workingLabel shows blinking cursor (no working text)', (
    tester,
  ) async {
    await pump(tester, const StreamingMessage(inReplyTo: 'x'));
    await tester.pump();
    expect(find.byKey(const Key('streaming-cursor')), findsOneWidget);
    expect(find.byKey(const Key('thinking-indicator')), findsNothing);
  });
  testWidgets('cursor sits one line BELOW the response (not inline)', (
    tester,
  ) async {
    await pump(
      tester,
      const StreamingMessage(inReplyTo: 'x', buffer: 'a long enough reply'),
    );
    await tester.pump();
    expect(find.byType(AgentMarkdown), findsOneWidget);
    final md = tester.getRect(find.byType(AgentMarkdown));
    final cursor = tester.getRect(find.byKey(const Key('streaming-cursor')));
    // Below the rendered markdown, and left-aligned — never floating aside.
    expect(cursor.top, greaterThanOrEqualTo(md.bottom - 0.5));
    expect(cursor.left, closeTo(md.left, 1));
  });

  testWidgets('brief mode strips thinking tags and hides indicator once visible text arrives', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: StreamingBubble(
            streaming: StreamingMessage(
              inReplyTo: 'x',
              buffer: '<think>internal reason</think>visible reply',
            ),
            brief: true,
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('Working…'), findsNothing);
    expect(find.textContaining('visible reply'), findsOneWidget);
    expect(find.textContaining('internal reason'), findsNothing);
  });

  testWidgets('working turn with workingLabel shows interactive Stop button', (
    tester,
  ) async {
    var cancelled = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StreamingBubble(
            streaming: const StreamingMessage(inReplyTo: 'x'),
            brief: true,
            isWorking: true,
            workingLabel: 'Searching files…',
            onCancel: () => cancelled = true,
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.byKey(const Key('thinking-indicator')), findsOneWidget);
    expect(find.text('Searching files…'), findsOneWidget);
    expect(find.text('Stop'), findsOneWidget);

    await tester.tap(find.text('Stop'));
    await tester.pump();
    expect(cancelled, isTrue);
  });
  testWidgets('custom workingLabel is displayed in thinking indicator', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: StreamingBubble(
            streaming: StreamingMessage(inReplyTo: 'x'),
            brief: true,
            isWorking: true,
            workingLabel: 'Searching files…',
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.byKey(const Key('thinking-indicator')), findsOneWidget);
    expect(find.text('Searching files…'), findsOneWidget);
  });

  testWidgets('working turn without onCancel hides Stop button', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: StreamingBubble(
            streaming: StreamingMessage(inReplyTo: 'x'),
            brief: true,
            isWorking: true,
            workingLabel: 'Searching files…',
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('Searching files…'), findsOneWidget);
    expect(find.text('Stop'), findsNothing);
  });

  testWidgets('finished stream with onCancel hides Stop button when isWorking is false', (
    tester,
  ) async {
    var cancelled = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StreamingBubble(
            streaming: const StreamingMessage(
              inReplyTo: 'x',
              buffer: 'Finished streaming text',
            ),
            brief: true,
            isWorking: false,
            onCancel: () => cancelled = true,
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('Stop'), findsNothing);
    expect(find.textContaining('Finished streaming text'), findsOneWidget);
  });
}
