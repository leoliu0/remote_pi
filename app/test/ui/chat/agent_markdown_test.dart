// Plan/32b — AgentMarkdown renders fenced code with a copy button.

import 'package:app/ui/chat/widgets/agent_markdown.dart';
import 'package:flutter_math_fork/flutter_math.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<void> pump(WidgetTester tester, String md) {
    return tester.pumpWidget(
      MaterialApp(home: Scaffold(body: AgentMarkdown(md))),
    );
  }

  testWidgets('fenced code block shows a copy button', (tester) async {
    await pump(tester, '```dart\nfinal x = 1;\n```');
    await tester.pump();
    expect(find.byKey(const Key('code-copy')), findsOneWidget);
    expect(find.textContaining('final x = 1;'), findsOneWidget);
  });

  testWidgets('tapping copy puts the code on the clipboard', (tester) async {
    final calls = <MethodCall>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') calls.add(call);
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );

    await pump(tester, '```\nhello code\n```');
    await tester.pump();
    await tester.tap(find.byKey(const Key('code-copy')));
    await tester.pump();

    expect(calls, isNotEmpty, reason: 'Clipboard.setData was invoked');
    final text = (calls.first.arguments as Map)['text'] as String;
    expect(text, contains('hello code'));
  });

  testWidgets('plain prose renders without a code block', (tester) async {
    await pump(tester, 'just a normal sentence.');
    await tester.pump();
    expect(find.byKey(const Key('code-copy')), findsNothing);
  });

  testWidgets('renders markdown headings with proper formatting', (tester) async {
    await pump(tester, '# Major Heading\n\n## Subheading\n\nNormal paragraph.');
    await tester.pump();

    expect(find.textContaining('Major Heading'), findsOneWidget);
    expect(find.textContaining('Subheading'), findsOneWidget);
    expect(find.textContaining('Normal paragraph.'), findsOneWidget);
  });

  testWidgets('renders inline code and bold text in markdown', (tester) async {
    await pump(tester, 'This has `inline_code` and **bold summary** in it.');
    await tester.pump();

    expect(find.textContaining('inline_code'), findsOneWidget);
    expect(find.textContaining('bold summary'), findsOneWidget);
  });
  testWidgets(r'renders LaTeX math equations ($...$ and $$...$$)', (tester) async {
    tester.view.physicalSize = const Size(390 * 3, 844 * 3);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(() => tester.view.resetPhysicalSize());
    await pump(tester, r'Formula inline $E = mc^2$ and display: $$\\sum_{i=1}^n x_i$$');
    await tester.pumpAndSettle();
    expect(find.byType(AgentMarkdown), findsOneWidget);
    expect(find.byType(Math), findsNWidgets(2));
  });

  testWidgets(r'selectable AgentMarkdown renders LaTeX math inside SelectionArea without crashing', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AgentMarkdown(
            r'Formula $E = mc^2$ and $$\\frac{a}{b}$$ in selectable mode',
            selectable: true,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(SelectionArea), findsOneWidget);
    expect(find.byType(Math), findsNWidgets(2));
  });

  testWidgets('two stray \$\$ far apart render as prose, not Math (freeze guard)', (tester) async {
    final prose = 'Payment \$\$${'x' * 600}\$\$ received. '
        'Nothing mathematical here, just finance prose with dollar signs.';
    await pump(tester, prose);
    await tester.pumpAndSettle();
    expect(find.byType(Math), findsNothing);
    expect(find.textContaining('finance prose'), findsOneWidget);
  });

  testWidgets(r'preserves subscripts with underscores without converting to italics', (tester) async {
    await pump(tester, r'The coefficient is $\beta_1$ and $\beta_2$.');
    await tester.pump();
    expect(find.byType(Math), findsNWidgets(2));
  });

  testWidgets('currency amounts like \$100 are not parsed as math', (tester) async {
    await pump(tester, r'The cost is $100 and bonus is $50.');
    await tester.pump();
    expect(find.byType(Math), findsNothing);
    expect(find.textContaining(r'$100'), findsOneWidget);
  });

  testWidgets('fenced math code block renders display math', (tester) async {
    await pump(tester, "```latex\n\\int_0^1 x^2 dx = \\frac{1}{3}\n```");
    await tester.pump();
    expect(find.byType(Math), findsOneWidget);
  });

  group('stripThinkingTrace', () {
    test('strips closed <think>, <thought>, and <thinking> blocks', () {
      expect(
        stripThinkingTrace('<think>internal reasoning</think>Final answer'),
        'Final answer',
      );
      expect(
        stripThinkingTrace('<thought>\nline 1\nline 2\n</thought>\n\nHere is the result.'),
        'Here is the result.',
      );
      expect(
        stripThinkingTrace('<thinking>step 1\nstep 2</thinking>Output only'),
        'Output only',
      );
    });
    test('strips antThinking and mid-line/indented think blocks', () {
      expect(
        stripThinkingTrace('<antThinking>claude reasoning</antThinking>Actual answer'),
        'Actual answer',
      );
      expect(
        stripThinkingTrace('Here is my plan: <think>secret thoughts</think>I will write code.'),
        'Here is my plan: I will write code.',
      );
      expect(
        stripThinkingTrace('Line 1\n  <think>secret</think>\nLine 2'),
        'Line 1\n  \nLine 2',
      );
    });


    test('strips unclosed opening tag ONLY during live streaming', () {
      expect(
        stripThinkingTrace('<think>still thinking in progress...', isLiveStreaming: true),
        '',
      );
      // Finalized messages with inline backticks or text must not truncate
      expect(
        stripThinkingTrace('Reasoning Density: Average 10,581 characters of `thinking` per prompt.'),
        'Reasoning Density: Average 10,581 characters of `thinking` per prompt.',
      );
    });

    test('leaves regular text and inline code untouched', () {
      expect(
        stripThinkingTrace('Normal text with `<thinking>` code tag'),
        'Normal text with `<thinking>` code tag',
      );
    });
    test('strips an unclosed think block that opens after visible text (live)', () {
      // Daemon wraps streamed reasoning in <think>; a block opening mid-reply
      // must hide while it grows, without eating the visible text before it.
      expect(
        stripThinkingTrace('Story end.\n\n<think>The user wants', isLiveStreaming: true),
        'Story end.',
      );
      // Finalized mode keeps unclosed blocks untouched.
      expect(
        stripThinkingTrace('Story end.\n\n<think>The user wants'),
        'Story end.\n\n<think>The user wants',
      );
    });

    test('never truncates bullet points containing <think> mentions in finalized mode', () {
      const fullMessage = '''
• Progress: 1,924 traces generated on disk.
• Reasoning Density: Average 10,581 characters of <think> chain-of-thought per prompt.
• Hardware Load: 100% compute utilization.
• Master Queue Status: queue_active.sh remains running.
''';
      final result = stripThinkingTrace(fullMessage, isLiveStreaming: false);
      expect(result, contains('• Progress: 1,924 traces'));
      expect(result, contains('• Hardware Load: 100% compute'));
      expect(result, contains('• Master Queue Status: queue_active.sh'));
    });
  });
}
