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
      expect(find.text('ls -la'), findsOneWidget);
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
        tool: 'Bash',
        args: {'command': 'ls'},
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
        tool: 'Bash',
        args: {'command': 'ls'},
        status: ToolEventStatus.completed,
      );
      await tester.pumpWidget(_wrap(const ToolRequestCard(tool: done)));
      expect(outcomeColor(tester, '✓ Done'), AppColors.dark.success);
    });

    testWidgets('failed → red "✗ {error}" + FAILED label', (tester) async {
      const failed = ToolEvent(
        id: 'tc1',
        toolCallId: 'tc1',
        tool: 'Bash',
        args: {'command': 'exit 1'},
        status: ToolEventStatus.failed,
        error: 'command failed: exit 1',
      );
      await tester.pumpWidget(_wrap(const ToolRequestCard(tool: failed)));
      expect(find.text('FAILED'), findsOneWidget);
      expect(
        outcomeColor(tester, '✗ command failed: exit 1'),
        AppColors.dark.error,
      );
    });

    testWidgets('running → blue "⏳ Running…"', (tester) async {
      // pending defaults
      await tester.pumpWidget(_wrap(const ToolRequestCard(tool: _bashTool)));
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
      );
      await tester.pumpWidget(_wrap(const ToolRequestCard(tool: done, brief: true)));
      expect(find.text('✓ Done'), findsNothing);

      // Tap the pill to expand
      await tester.tap(find.text('BASH'));
      await tester.pumpAndSettle();
      expect(find.text('✓ Done'), findsOneWidget);
      expect(find.text('DONE'), findsOneWidget);

      // Tap collapse chevron
      await tester.tap(find.byIcon(LucideIcons.chevronUp));
      await tester.pumpAndSettle();
      expect(find.text('✓ Done'), findsNothing);
    });
    testWidgets('renders command output block when tool result is present', (
      tester,
    ) async {
      const withResult = ToolEvent(
        id: 'tc1',
        toolCallId: 'tc1',
        tool: 'Bash',
        args: {'command': 'echo "hello world"', 'i': 'Print greeting'},
        status: ToolEventStatus.completed,
        result: 'hello world\nline 2',
      );
      await tester.pumpWidget(_wrap(const ToolRequestCard(tool: withResult)));
      expect(find.text('OUTPUT'), findsOneWidget);
      expect(find.text('hello world\nline 2'), findsOneWidget);
      expect(find.textContaining('# Print greeting'), findsOneWidget);
    });

    testWidgets('renders map tool result output cleanly', (tester) async {
      const withMapResult = ToolEvent(
        id: 'tc1',
        toolCallId: 'tc1',
        tool: 'Bash',
        args: {'cmd': 'git branch'},
        status: ToolEventStatus.completed,
        result: {'output': '* main\n  feature-1'},
      );
      await tester.pumpWidget(_wrap(const ToolRequestCard(tool: withMapResult)));
      expect(find.text('OUTPUT'), findsOneWidget);
      expect(find.text('* main\n  feature-1'), findsOneWidget);
      expect(find.text('git branch'), findsOneWidget);
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
