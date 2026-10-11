// todo_state — wire parsing, omp's todo rules shared with the web client, the
// chat's todo-tool pill and the panel widget. Payloads captured from a scratch
// omp v18.9.2 run (pi-extension/src/todo_state.fixture.json): init with
// Setup/Build, done, start out of order, block, append, drop.

import 'package:app/domain/session_state.dart';
import 'package:app/protocol/protocol.dart';
import 'package:app/ui/chat/widgets/todo_panel.dart';
import 'package:app/ui/chat/widgets/tool_request_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

// The list after `drop Ship`, as the pi-extension sends it.
const Map<String, dynamic> _afterDrop = {
  'type': 'todo_state',
  'ts': 1791587119493,
  'phases': [
    {
      'name': 'Setup',
      'tasks': [
        {'content': 'Create repo', 'status': 'completed'},
        {'content': 'Add CI', 'status': 'pending'},
      ],
    },
    {
      'name': 'Build',
      'tasks': [
        {'content': 'Write parser', 'status': 'in_progress'},
        {'content': 'Write tests', 'status': 'blocked', 'blocker': 'waiting on fixtures'},
        {'content': 'Ship', 'status': 'abandoned'},
        {'content': 'Write docs', 'status': 'pending'},
      ],
    },
  ],
};

List<TodoPhase> _phases(Map<String, dynamic> json) =>
    (ServerMessage.fromJson(json) as TodoState).phases;

void main() {
  group('todo_state parsing', () {
    test('captured snapshot', () {
      final phases = _phases(_afterDrop);
      expect(phases.map((p) => p.name), ['Setup', 'Build']);
      expect(phases[1].tasks[0].status, TodoStatus.inProgress);
      expect(
        phases[1].tasks[1],
        const TodoTask(content: 'Write tests', status: TodoStatus.blocked, blocker: 'waiting on fixtures'),
      );
      expect(phases[1].tasks[2].status, TodoStatus.abandoned);
    });

    test('drops unknown statuses, malformed tasks and empty phases; [] = hidden', () {
      final phases = _phases({
        'type': 'todo_state',
        'phases': [
          {'name': 'Empty', 'tasks': []},
          {
            'name': 'B',
            'tasks': [
              {'content': 'x', 'status': 'someday'},
              {'status': 'pending'},
              {'content': 'y', 'status': 'pending'},
            ],
          },
          {'tasks': []},
        ],
      });
      expect(phases, const [
        TodoPhase(name: 'B', tasks: [TodoTask(content: 'y', status: TodoStatus.pending)]),
      ]);
      expect(_phases({'type': 'todo_state', 'phases': [], 'ts': 1}), isEmpty);
    });
  });

  group('omp todo rules', () {
    test('done counts dropped tasks; active phase = first with open work', () {
      final phases = _phases(_afterDrop);
      expect(todoCount([for (final p in phases) ...p.tasks]), (2, 6));
      expect(todoCount(phases[1].tasks), (1, 4));
      // Setup still has a pending task, so it stays the active phase (as in the TUI).
      expect(todoActivePhase(phases), 0);
      expect(todoCurrentTask(phases)?.content, 'Write parser');
    });

    test('Roman phase numbers only with several phases', () {
      expect(todoPhaseTitle('Setup', 0, 2), 'I. Setup');
      expect(todoPhaseTitle('Build', 1, 2), 'II. Build');
      expect(todoPhaseTitle('Tasks', 0, 1), 'Tasks');
    });

    test('tool pill: op while running, done/total from the result text', () {
      expect(todoPillText({'op': 'done', 'task': 'Create repo'}, null, ToolEventStatus.pending), ('Todo · done', 'Create repo'));
      const dropText = 'Remaining items (3):\n  - Add CI [pending] (Setup)\n'
          'Overall: 2/6 done, 3 open, 1 blocked.\nActive phase 1/2 "Setup" (1/2).';
      expect(todoPillText({'op': 'drop', 'task': 'Ship'}, dropText, ToolEventStatus.completed), ('Todo · 2/6', 'drop · Ship'));
      expect(
        todoPillText({'op': 'init', 'list': [{}, {}]}, 'Overall: 0/5 done, 5 open.', ToolEventStatus.completed),
        ('Todo · 0/5', 'init · 2 phases'),
      );
      expect(
        todoPillText({'op': 'done', 'task': 'No such task'}, 'Errors: Task "No such task" not found', ToolEventStatus.failed),
        ('Todo · failed', 'done · No such task'),
      );
    });
  });

  group('TodoPanel widget', () {
    Future<void> pumpPanel(WidgetTester tester, List<TodoPhase> phases, {bool working = false}) =>
        tester.pumpWidget(
          MaterialApp(home: Scaffold(body: TodoPanel(phases: phases, working: working))),
        );

    testWidgets('renders phases, counts and statuses like the TUI', (tester) async {
      await pumpPanel(tester, _phases(_afterDrop));
      expect(find.text('TODO'), findsOneWidget);
      expect(find.text('2/6'), findsOneWidget);
      expect(find.text('I. Setup'), findsOneWidget);
      expect(find.text(' · 1/2'), findsOneWidget);
      expect(find.text('II. Build'), findsOneWidget);
      expect(find.text(' · 1/4'), findsOneWidget);
      expect(find.text('Write tests (blocked)'), findsOneWidget);
      expect(find.text('waiting on fixtures'), findsOneWidget);
      expect(find.text('✓'), findsOneWidget); // Create repo
      expect(find.text('✗'), findsOneWidget); // Ship (dropped)
      expect(find.text('!'), findsOneWidget); // blocked
      expect(find.text('●'), findsOneWidget); // in progress, agent idle
      expect(find.text('○'), findsNWidgets(2)); // Add CI, Write docs
    });

    testWidgets('spins the in-progress task while the agent works', (tester) async {
      await pumpPanel(tester, _phases(_afterDrop), working: true);
      expect(find.text('⠋'), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('⠙'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('collapses to one line with the current task', (tester) async {
      await pumpPanel(tester, _phases(_afterDrop));
      await tester.tap(find.byKey(const Key('todo-panel-header')));
      await tester.pump();
      expect(find.text('I. Setup'), findsNothing);
      expect(find.text('Write parser'), findsOneWidget);
      expect(find.text('2/6'), findsOneWidget);
    });

    testWidgets('a finished phase is folded until tapped; empty list renders nothing', (tester) async {
      final phases = _phases({
        'type': 'todo_state',
        'phases': [
          {
            'name': 'Setup',
            'tasks': [
              {'content': 'Create repo', 'status': 'completed'},
              {'content': 'Add CI', 'status': 'completed'},
            ],
          },
          {
            'name': 'Build',
            'tasks': [
              {'content': 'Write parser', 'status': 'in_progress'},
            ],
          },
        ],
      });
      await pumpPanel(tester, phases);
      expect(find.text('I. Setup'), findsOneWidget);
      expect(find.text('Create repo'), findsNothing);
      await tester.tap(find.text('I. Setup'));
      await tester.pump();
      expect(find.text('Create repo'), findsOneWidget);

      await pumpPanel(tester, const []);
      expect(find.byKey(const Key('todo-panel')), findsNothing);
    });
  });

  group('todo tool row', () {
    testWidgets('is a one-line pill in brief and full mode; tap shows the card', (tester) async {
      const tool = ToolEvent(
        id: 't1',
        toolCallId: 'toolu_01FB2EA2igyTY2sCgCZpK3SA',
        tool: 'todo',
        args: {'op': 'drop', 'task': 'Ship'},
        status: ToolEventStatus.completed,
        result: 'Remaining items (3):\nOverall: 2/6 done, 3 open, 1 blocked.',
      );
      for (final brief in [true, false]) {
        await tester.pumpWidget(
          MaterialApp(home: Scaffold(body: ToolRequestCard(key: ValueKey(brief), tool: tool, brief: brief))),
        );
        expect(find.byKey(const Key('todo-tool-pill')), findsOneWidget);
        expect(find.text('Todo · 2/6'), findsOneWidget);
        expect(find.text('drop · Ship'), findsOneWidget);
        await tester.tap(find.byKey(const Key('todo-tool-pill')));
        await tester.pump();
        expect(find.byKey(const Key('todo-tool-pill')), findsNothing);
        expect(find.text('DONE'), findsOneWidget);
      }
    });
  });
}
