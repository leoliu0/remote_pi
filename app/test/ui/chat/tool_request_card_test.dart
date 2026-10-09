import 'package:app/domain/session_state.dart';
import 'package:app/ui/chat/widgets/tool_request_card.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

Widget _wrap(Widget child) => MaterialApp(home: Scaffold(body: child));

const _bashTool = ToolEvent(
  id: 'tc1',
  toolCallId: 'tc1',
  tool: 'Bash',
  args: {'command': 'ls -la'},
);

const _editToolWithHunk = ToolEvent(
  id: 'tc2',
  toolCallId: 'tc4',
  tool: 'edit',
  args: {
    'path': 'app/test/ui/chat/tool_request_card_test.dart',
    'hunks': [
      {
        'lines': [
          {'kind': 'context', 'oldLine': 16, 'newLine': 16, 'text': 'args: {'},
          {'kind': 'remove', 'oldLine': 17, 'text': "  tool: 'Edit',"},
          {'kind': 'add', 'newLine': 17, 'text': "  tool: 'edit',"},
          {'kind': 'context', 'oldLine': 18, 'newLine': 18, 'text': '},'},
        ],
      },
    ],
  },
);

void main() {
  group('ToolRequestCard (informational)', () {
    testWidgets('shows tool name and command', (tester) async {
      await tester.pumpWidget(_wrap(const ToolRequestCard(tool: _bashTool)));
      expect(find.text('BASH'), findsOneWidget);
      expect(find.text(r'$ ls -la'), findsOneWidget);
    });

    testWidgets('edit renders rich hunks with context lines', (tester) async {
      await tester.pumpWidget(
        _wrap(const ToolRequestCard(tool: _editToolWithHunk)),
      );

      expect(
        find.textContaining('   16 args: {', findRichText: true),
        findsOneWidget,
      );
      expect(
        find.textContaining("-  17   tool: 'Edit',", findRichText: true),
        findsOneWidget,
      );
      expect(
        find.textContaining("+  17   tool: 'edit',", findRichText: true),
        findsOneWidget,
      );
      expect(
        find.textContaining('   18 },', findRichText: true),
        findsOneWidget,
      );
    });

    testWidgets('pending state shows RUNNING and no Allow/Deny buttons', (
      tester,
    ) async {
      await tester.pumpWidget(_wrap(const ToolRequestCard(tool: _bashTool)));
      expect(find.text('RUNNING'), findsOneWidget);
      expect(find.text('Allow'), findsNothing);
      expect(find.text('Deny'), findsNothing);
      expect(find.textContaining('s'), findsAny); // no '60s' countdown
      expect(find.textContaining('60s'), findsNothing);
    });

    testWidgets('completed state shows DONE', (tester) async {
      const done = ToolEvent(
        id: 'tc1',
        toolCallId: 'tc1',
        tool: 'read',
        args: {'path': 'README.md'},
        status: ToolEventStatus.completed,
      );
      await tester.pumpWidget(_wrap(const ToolRequestCard(tool: done)));
      expect(find.text('DONE'), findsOneWidget);
      expect(find.textContaining('Done'), findsAny);
    });

    testWidgets('denied state shows DENIED label', (tester) async {
      const denied = ToolEvent(
        id: 'tc1',
        toolCallId: 'tc1',
        tool: 'Bash',
        args: {'command': 'ls'},
        status: ToolEventStatus.denied,
        error: 'user denied',
      );
      await tester.pumpWidget(_wrap(const ToolRequestCard(tool: denied)));
      expect(find.text('DENIED'), findsOneWidget);
    });

    testWidgets('allowed state shows RUNNING (still in flight)', (
      tester,
    ) async {
      const allowed = ToolEvent(
        id: 'tc1',
        toolCallId: 'tc1',
        tool: 'Bash',
        args: {'command': 'ls'},
        status: ToolEventStatus.allowed,
      );
      await tester.pumpWidget(_wrap(const ToolRequestCard(tool: allowed)));
      expect(find.text('RUNNING'), findsOneWidget);
      expect(find.text('Allow'), findsNothing);
    });

    // Plan/32 — the card is colored by status: running blue, done green,
    // failed red. We assert the outcome line's color (the same _statusColor
    // drives the border / icon / tool name).
    Color? outcomeColor(WidgetTester tester, String text) =>
        tester.widget<Text>(find.text(text)).style?.color;

    testWidgets('completed → green "✓ Done"', (tester) async {
      const done = ToolEvent(
        id: 'tc1',
        toolCallId: 'tc1',
        tool: 'read',
        args: {'path': 'README.md'},
        status: ToolEventStatus.completed,
      );
      await tester.pumpWidget(_wrap(const ToolRequestCard(tool: done)));
      expect(outcomeColor(tester, '✓ Done'), AppColors.dark.success);
    });

    testWidgets('failed → red "✗ {error}" + FAILED label', (tester) async {
      const failed = ToolEvent(
        id: 'tc1',
        toolCallId: 'tc1',
        tool: 'read',
        args: {'path': 'missing.md'},
        status: ToolEventStatus.failed,
        error: 'ENOENT: missing.md',
      );
      await tester.pumpWidget(_wrap(const ToolRequestCard(tool: failed)));
      expect(find.text('FAILED'), findsOneWidget);
      expect(
        outcomeColor(tester, '✗ ENOENT: missing.md'),
        AppColors.dark.error,
      );
    });

    testWidgets('running → blue "⏳ Running…"', (tester) async {
      const running = ToolEvent(
        id: 'tc1',
        toolCallId: 'tc1',
        tool: 'read',
        args: {'path': 'README.md'},
      );
      await tester.pumpWidget(_wrap(const ToolRequestCard(tool: running)));
      expect(outcomeColor(tester, '⏳ Running…'), AppColors.dark.accent);
    });

    testWidgets('brief mode renders compact single-line pill', (tester) async {
      const done = ToolEvent(
        id: 'tc1',
        toolCallId: 'tc1',
        tool: 'Bash',
        args: {'command': 'git status'},
        status: ToolEventStatus.completed,
      );
      await tester.pumpWidget(_wrap(const ToolRequestCard(tool: done, brief: true)));
      expect(find.text('BASH'), findsOneWidget);
      expect(find.text('git status'), findsOneWidget);
      expect(find.text('✓'), findsOneWidget);
      // In brief collapsed state, the outcome text '✓ Done' is not rendered yet
      expect(find.text('✓ Done'), findsNothing);
    });

    testWidgets('tapping brief pill expands to full details and collapses back', (tester) async {
      const done = ToolEvent(
        id: 'tc1',
        toolCallId: 'tc1',
        tool: 'Bash',
        args: {'command': 'git status'},
        status: ToolEventStatus.completed,
        result: 'clean\n\nWall time: 0.10 seconds',
      );
      await tester.pumpWidget(_wrap(const ToolRequestCard(tool: done, brief: true)));
      expect(find.text('Output'), findsNothing);

      // Tap the pill to expand
      await tester.tap(find.text('BASH'));
      await tester.pumpAndSettle();
      expect(find.text(r'$ git status'), findsOneWidget);
      expect(find.text('Output'), findsOneWidget);
      expect(find.text('Wall: 0.10s'), findsOneWidget);
      expect(find.text('DONE'), findsOneWidget);

      // Tap collapse chevron
      await tester.tap(find.byIcon(LucideIcons.chevronUp));
      await tester.pumpAndSettle();
      expect(find.text('Output'), findsNothing);
    });

    group('bash Full card (terminal / web parity)', () {
      Color? spanColor(WidgetTester tester, String footer, String part) {
        final rich = tester.widget<Text>(find.text(footer));
        Color? found;
        rich.textSpan!.visitChildren((span) {
          if (span is TextSpan && span.text == part) {
            found = span.style?.color;
            return false;
          }
          return true;
        });
        return found;
      }

      testWidgets('live tool_result error: exact strings + red exit', (
        tester,
      ) async {
        // Shape of a live `tool_result` for a failing command: pi-extension
        // sends the full tool text as `error` (isError) → status failed.
        const failed = ToolEvent(
          id: 'tc1',
          toolCallId: 'tc1',
          tool: 'bash',
          args: {
            'command': 'flutter test',
            'timeout': 300,
            'i': 'Running app tests',
            'cwd': 'app',
          },
          status: ToolEventStatus.failed,
          error:
              'error: command not found: flutter\n\n\nWall time: 0.00 seconds'
              '\n\nCommand exited with code 127',
        );
        await tester.pumpWidget(_wrap(const ToolRequestCard(tool: failed)));
        expect(find.text(r'$ flutter test'), findsOneWidget);
        expect(find.text('Running app tests'), findsOneWidget);
        expect(find.text('in app'), findsOneWidget);
        expect(find.text('Output'), findsOneWidget);
        expect(find.text('error: command not found: flutter'), findsOneWidget);
        expect(find.textContaining('Wall time'), findsNothing);
        expect(find.textContaining('Command exited'), findsNothing);
        const footer = 'Wall: 0.00s | Timeout: 300s | exit 127';
        expect(find.text(footer), findsOneWidget);
        expect(spanColor(tester, footer, ' | exit 127'), AppColors.dark.error);
        expect(
          spanColor(tester, footer, 'Wall: 0.00s | Timeout: 300s'),
          isNot(AppColors.dark.error),
        );
      });

      testWidgets('history-synced result: (no output) + wall-only footer', (
        tester,
      ) async {
        // A replayed history event lands as `result` on a completed row.
        const done = ToolEvent(
          id: 'tc2',
          toolCallId: 'tc2',
          tool: 'bash',
          args: {'command': 'sleep 15'},
          status: ToolEventStatus.completed,
          result: '(no output)\n\nWall time: 15.67 seconds',
        );
        await tester.pumpWidget(_wrap(const ToolRequestCard(tool: done)));
        expect(find.text('(no output)'), findsOneWidget);
        expect(find.text('Wall: 15.67s'), findsOneWidget);
        expect(find.textContaining('exit'), findsNothing);
        expect(find.text('✓ Done'), findsNothing);
      });

      testWidgets('empty result shows (no output)', (tester) async {
        const done = ToolEvent(
          id: 'tc3',
          toolCallId: 'tc3',
          tool: 'bash',
          args: {'command': 'true'},
          status: ToolEventStatus.completed,
          result: '',
        );
        await tester.pumpWidget(_wrap(const ToolRequestCard(tool: done)));
        expect(find.text('(no output)'), findsOneWidget);
      });

      testWidgets('running: no Output section, footer Running…', (
        tester,
      ) async {
        await tester.pumpWidget(_wrap(const ToolRequestCard(tool: _bashTool)));
        expect(find.text('Output'), findsNothing);
        expect(find.text('Running…'), findsOneWidget);
        expect(
          tester.widget<Text>(find.text('Running…')).textSpan!.style!.color,
          AppColors.dark.accent,
        );
      });

      testWidgets('multi-line command is shown in full, never truncated', (
        tester,
      ) async {
        final longCmd = [
          for (var i = 0; i < 40; i++) 'echo line-$i-${'x' * 60}',
        ].join('\n');
        await tester.pumpWidget(
          _wrap(
            SingleChildScrollView(
              child: ToolRequestCard(
                tool: ToolEvent(
                  id: 'tc4',
                  toolCallId: 'tc4',
                  tool: 'bash',
                  args: {'command': longCmd},
                ),
              ),
            ),
          ),
        );
        final cmdFinder = find.ancestor(
          of: find.text('\$ $longCmd'),
          matching: find.byType(SelectableText),
        );
        expect(tester.widget<SelectableText>(cmdFinder).maxLines, isNull);
        // Wraps and grows with the command instead of clipping it.
        expect(tester.getSize(cmdFinder).height, greaterThan(400));
      });

      testWidgets('long output scrolls inside the card', (tester) async {
        final longOut = [for (var i = 0; i < 200; i++) 'row $i'].join('\n');
        await tester.pumpWidget(
          _wrap(
            SingleChildScrollView(
              child: ToolRequestCard(
                tool: ToolEvent(
                  id: 'tc5',
                  toolCallId: 'tc5',
                  tool: 'bash',
                  args: const {'command': 'seq 200'},
                  status: ToolEventStatus.completed,
                  result: '$longOut\n\nWall time: 0.01 seconds',
                ),
              ),
            ),
          ),
        );
        final scroll = find.ancestor(
          of: find.text(longOut),
          matching: find.byType(SingleChildScrollView),
        );
        expect(tester.getSize(scroll.first).height, lessThanOrEqualTo(320));
        expect(find.text('Wall: 0.01s'), findsOneWidget);
      });

      testWidgets('map result (cmd key) renders cleanly', (tester) async {
        const withMapResult = ToolEvent(
          id: 'tc1',
          toolCallId: 'tc1',
          tool: 'Bash',
          args: {'cmd': 'git branch'},
          status: ToolEventStatus.completed,
          result: {'output': '* main\n  feature-1'},
        );
        await tester.pumpWidget(
          _wrap(const ToolRequestCard(tool: withMapResult)),
        );
        expect(find.text('Output'), findsOneWidget);
        expect(find.text('* main\n  feature-1'), findsOneWidget);
        expect(find.text(r'$ git branch'), findsOneWidget);
      });
    });
    testWidgets('edit with old_string and new_string renders diff lines', (
      tester,
    ) async {
      const editTool = ToolEvent(
        id: 'tc1',
        toolCallId: 'tc1',
        tool: 'edit',
        args: {
          'file_path': 'lib/foo.dart',
          'old_string': 'final a = 1;',
          'new_string': 'final a = 2;',
        },
        status: ToolEventStatus.completed,
      );
      await tester.pumpWidget(_wrap(const ToolRequestCard(tool: editTool)));
      expect(find.textContaining('- final a = 1;', findRichText: true), findsOneWidget);
      expect(find.textContaining('+ final a = 2;', findRichText: true), findsOneWidget);
    });

    testWidgets('edit with input patch format renders diff lines', (
      tester,
    ) async {
      const patchTool = ToolEvent(
        id: 'tc1',
        toolCallId: 'tc1',
        tool: 'edit',
        args: {
          'input': '[lib/bar.dart#1A2B]\nPUT 5.=6:\n-old line\n+new line',
        },
        status: ToolEventStatus.completed,
      );
      await tester.pumpWidget(_wrap(const ToolRequestCard(tool: patchTool)));
      expect(find.textContaining('-old line', findRichText: true), findsOneWidget);
      expect(find.textContaining('+new line', findRichText: true), findsOneWidget);
    });

    testWidgets('write tool renders content lines', (tester) async {
      const writeTool = ToolEvent(
        id: 'tc1',
        toolCallId: 'tc1',
        tool: 'write',
        args: {
          'path': 'lib/baz.dart',
          'content': 'void main() {\n  print("hello");\n}',
        },
        status: ToolEventStatus.completed,
      );
      await tester.pumpWidget(_wrap(const ToolRequestCard(tool: writeTool)));
      expect(find.textContaining('write lib/baz.dart', findRichText: true), findsOneWidget);
      expect(find.textContaining('void main() {', findRichText: true), findsOneWidget);
    });
  });
}
