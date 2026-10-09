// Thinking traces: `<think>…</think>` in assistant replies render as a muted,
// collapsible `Thinking` block when Settings › "Show thinking traces" is ON,
// and are stripped when OFF — independent of the tool-call display mode.

import 'package:app/domain/session_state.dart';
import 'package:app/ui/chat/widgets/message_bubble.dart';
import 'package:app/ui/chat/widgets/thinking_block.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _wrap(Widget child) => MaterialApp(home: Scaffold(body: child));

void main() {
  group('splitThinking', () {
    List<(bool, String, bool)> parts(String s) => [
      for (final seg in splitThinking(s)) (seg.isThinking, seg.text, seg.closed),
    ];

    test('closed blocks of every tag variant, in order with the text', () {
      expect(parts('<think>plan</think>Answer'), [
        (true, 'plan', true),
        (false, 'Answer', true),
      ]);
      expect(parts('Intro\n<thought>\na\nb\n</thought>\n\nOutro'), [
        (false, 'Intro', true),
        (true, 'a\nb', true),
        (false, 'Outro', true),
      ]);
      expect(parts('<thinking>x</thinking><antThinking>y</antThinking>z'), [
        (true, 'x', true),
        (true, 'y', true),
        (false, 'z', true),
      ]);
    });

    test('unterminated block at a line start runs to the end (streaming)', () {
      expect(parts('Story end.\n\n<think>The user wants'), [
        (false, 'Story end.', true),
        (true, 'The user wants', false),
      ]);
      expect(parts('<think>'), [(true, '', false)]);
    });

    test('an inline, unclosed tag mention stays literal text', () {
      expect(parts('Normal text with `<thinking>` code tag'), [
        (false, 'Normal text with `<thinking>` code tag', true),
      ]);
    });

    test('no tags → one text segment; blank → nothing', () {
      expect(parts('plain'), [(false, 'plain', true)]);
      expect(parts('  \n '), isEmpty);
      expect(parts('<think>  </think>'), isEmpty);
    });
  });

  group('AssistantBubble (live-finalized and history rows)', () {
    const msg = AssistantMsg(
      id: 'a1',
      text: '<think>line one\nline two\nline three\nline four</think>\n\n'
          'The answer is 42.',
    );

    testWidgets('ON: muted Thinking block collapsed to 2 lines, tap expands', (
      tester,
    ) async {
      await tester.pumpWidget(_wrap(const AssistantBubble(msg)));
      expect(find.byKey(const Key('thinking-block')), findsOneWidget);
      expect(find.text('Thinking'), findsOneWidget);
      expect(find.textContaining('The answer is 42.'), findsOneWidget);
      expect(find.textContaining('<think>'), findsNothing);

      final trace = find.text('line one\nline two\nline three\nline four');
      expect(tester.widget<Text>(trace).maxLines, 2);
      expect(tester.widget<Text>(trace).overflow, TextOverflow.ellipsis);

      await tester.tap(find.text('Thinking'));
      await tester.pump();
      expect(tester.widget<Text>(trace).maxLines, isNull);

      await tester.tap(find.text('Thinking'));
      await tester.pump();
      expect(tester.widget<Text>(trace).maxLines, 2);
    });

    testWidgets('OFF: the trace is stripped entirely', (tester) async {
      await tester.pumpWidget(
        _wrap(const AssistantBubble(msg, showThinking: false)),
      );
      expect(find.byKey(const Key('thinking-block')), findsNothing);
      expect(find.textContaining('line one'), findsNothing);
      expect(find.textContaining('The answer is 42.'), findsOneWidget);
    });

    testWidgets('a reply that is only a trace: ON shows it, OFF renders nothing', (
      tester,
    ) async {
      const only = AssistantMsg(id: 'a2', text: '<think>just reasoning</think>');
      expect(AssistantContent.hasContent(only.text, showThinking: true), isTrue);
      expect(
        AssistantContent.hasContent(only.text, showThinking: false),
        isFalse,
      );
      await tester.pumpWidget(_wrap(const AssistantBubble(only)));
      expect(find.text('just reasoning'), findsOneWidget);
      await tester.pumpWidget(
        _wrap(const AssistantBubble(only, showThinking: false)),
      );
      expect(find.text('just reasoning'), findsNothing);
    });

    testWidgets('finalized reply that ends inside an unclosed block (turn split '
        'before </think>): ON shows it as a block, OFF strips it', (
      tester,
    ) async {
      const split = AssistantMsg(id: 'a3', text: '<think>half a thought');
      await tester.pumpWidget(_wrap(const AssistantBubble(split)));
      expect(find.byKey(const Key('thinking-block')), findsOneWidget);
      expect(find.text('half a thought'), findsOneWidget);

      await tester.pumpWidget(
        _wrap(const AssistantBubble(split, showThinking: false)),
      );
      expect(find.textContaining('half a thought'), findsNothing);
    });
  });
}
