// agent_activity — wire parsing, the panel's strings (shared with the web
// client), and the widget rendering a snapshot captured from a real omp run
// (pi-extension/src/activity.test.ts: one async `sleep 20` bash job, then a
// `task` call spawning AgentA/AgentB).

import 'package:app/protocol/protocol.dart';
import 'package:app/ui/chat/widgets/activity_panel.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const int _spawnMs = 1791581635609;
const int _nowMs = _spawnMs + 2200;

const Map<String, dynamic> _captured = {
  'type': 'agent_activity',
  'ts': _nowMs,
  'jobs': [
    {
      'id': 'bg_1',
      'kind': 'bash',
      'label': 'sleep 20',
      'command': 'sleep 20',
      'status': 'running',
      'started_at': 1791581631774,
    },
    {
      'id': 'AgentA',
      'kind': 'subagent',
      'label': 'AgentA',
      'status': 'running',
      'started_at': _spawnMs,
      'agent': 'task',
      'parent_tool_call_id': 'toolu_01Kd68jzyNvXctk692znDP89',
    },
    {
      'id': 'AgentB',
      'kind': 'subagent',
      'label': 'Run sleep command and report echoed output',
      'status': 'running',
      'started_at': _spawnMs,
      'agent': 'task',
      'parent_tool_call_id': 'toolu_01Kd68jzyNvXctk692znDP89',
      'description': 'Run sleep command and report echoed output',
      'assignment':
          '# Target\nRun with the bash tool: `sleep 8 && echo beta`\n'
          '# Acceptance\nReport the exact output.',
      'detail': 'Running sleep then echo',
      'progress': {
        'tool': 'bash',
        'tool_args': 'sleep 8 && echo beta',
        'tool_started_at': 1791581637677,
        'tool_count': 1,
        'tokens': 1589,
        'cost': 0.01604,
      },
    },
  ],
};

AgentActivityJob _job({
  String id = 'X',
  AgentActivityKind kind = AgentActivityKind.subagent,
  String label = 'X',
  AgentActivityStatus status = AgentActivityStatus.running,
  int startedAt = 0,
  int? endedAt,
  String? command,
  String? detail,
  AgentActivityProgress? progress,
}) => AgentActivityJob(
  id: id,
  kind: kind,
  label: label,
  status: status,
  startedAt: startedAt,
  endedAt: endedAt,
  command: command,
  detail: detail,
  progress: progress,
);

void main() {
  group('agent_activity parsing', () {
    test('captured omp snapshot decodes every field', () {
      final msg = ServerMessage.fromJson(_captured) as AgentActivity;
      expect(msg.ts, _nowMs);
      expect(msg.jobs.map((j) => j.id), ['bg_1', 'AgentA', 'AgentB']);

      final bash = msg.jobs[0];
      expect(bash.kind, AgentActivityKind.bash);
      expect(bash.command, 'sleep 20');
      expect(bash.status, AgentActivityStatus.running);
      expect(bash.startedAt, 1791581631774);
      expect(bash.endedAt, isNull);
      expect(bash.progress, isNull);

      final b = msg.jobs[2];
      expect(b.kind, AgentActivityKind.subagent);
      expect(b.agent, 'task');
      expect(b.parentToolCallId, 'toolu_01Kd68jzyNvXctk692znDP89');
      expect(b.description, 'Run sleep command and report echoed output');
      expect(b.assignment, startsWith('# Target'));
      expect(b.detail, 'Running sleep then echo');
      expect(b.progress!.tool, 'bash');
      expect(b.progress!.toolArgs, 'sleep 8 && echo beta');
      expect(b.progress!.toolStartedAt, 1791581637677);
      expect(b.progress!.toolCount, 1);
      expect(b.progress!.tokens, 1589);
      expect(b.progress!.cost, 0.01604);
      expect(b.progress!.percent, isNull);
    });

    test('finished rows carry ended_at; job_type for generic jobs', () {
      final msg = ServerMessage.fromJson(const {
        'type': 'agent_activity',
        'ts': 2,
        'jobs': [
          {
            'id': 'bg_1',
            'kind': 'bash',
            'label': 'sleep 4',
            'command': 'sleep 4',
            'status': 'done',
            'started_at': 1791581796129,
            'ended_at': 1791581800156,
          },
          {
            'id': 'j1',
            'kind': 'job',
            'label': 'indexing',
            'job_type': 'index',
            'status': 'failed',
            'started_at': 1,
            'ended_at': 2,
          },
        ],
      }) as AgentActivity;
      expect(msg.jobs[0].status, AgentActivityStatus.done);
      expect(msg.jobs[0].endedAt, 1791581800156);
      expect(msg.jobs[1].jobType, 'index');
      expect(msg.jobs[1].status, AgentActivityStatus.failed);
    });

    test('empty snapshot and forward-compat kinds/statuses', () {
      final empty = ServerMessage.fromJson(const {
        'type': 'agent_activity',
        'jobs': <Object>[],
        'ts': 1,
      }) as AgentActivity;
      expect(empty.jobs, isEmpty);

      final odd = ServerMessage.fromJson(const {
        'type': 'agent_activity',
        'ts': 1,
        'jobs': [
          {'id': 'z', 'kind': 'future', 'status': 'paused', 'started_at': 5},
        ],
      }) as AgentActivity;
      expect(odd.jobs.single.kind, AgentActivityKind.job);
      expect(odd.jobs.single.status, AgentActivityStatus.done);
      expect(odd.jobs.single.label, 'z', reason: 'label falls back to id');
    });
  });

  group('panel strings', () {
    test('elapsed: tenths under a minute, else minutes + padded seconds', () {
      expect(formatActivityElapsed(0), '0.0s');
      expect(formatActivityElapsed(12345), '12.3s');
      expect(formatActivityElapsed(59999), '59.9s');
      expect(formatActivityElapsed(60000), '1m 00s');
      expect(formatActivityElapsed(65000), '1m 05s');
      expect(formatActivityElapsed(3725000), '62m 05s');
      expect(formatActivityElapsed(-50), '0.0s');
    });

    test('elapsed is now - started while running, ended - started after', () {
      expect(activityElapsedMs(_job(startedAt: 1000), 13300), 12300);
      expect(
        activityElapsedMs(
          _job(
            startedAt: 1000,
            endedAt: 9000,
            status: AgentActivityStatus.done,
          ),
          99999,
        ),
        8000,
      );
    });

    test('header counts running rows only, singular/plural', () {
      expect(activityHeader([_job()]), 'waiting on 1 job');
      expect(activityHeader([_job(), _job()]), 'waiting on 2 jobs');
      expect(
        activityHeader([
          _job(),
          _job(status: AgentActivityStatus.done, endedAt: 1),
        ]),
        'waiting on 1 job',
      );
    });

    test('row: command for bash, label for the rest', () {
      expect(
        activityRowText(
          _job(
            id: 'bg_1',
            kind: AgentActivityKind.bash,
            label: 'ignored',
            command: 'sleep 20',
            startedAt: 0,
          ),
          6035,
        ),
        '└─ bg_1 sleep 20 · 6.0s',
      );
      expect(
        activityRowText(
          _job(id: 'AgentB', label: 'Run tests', startedAt: 0),
          65000,
        ),
        '└─ AgentB Run tests · 1m 05s',
      );
    });

    test('subagent detail: detail, else tool + args, plus tools/tokens', () {
      const p = AgentActivityProgress(
        tool: 'bash',
        toolArgs: 'sleep 8 && echo beta',
        toolCount: 3,
        tokens: 1589,
      );
      expect(
        activityDetailText(_job(detail: 'Running sleep then echo', progress: p)),
        'Running sleep then echo · 3 tools · 1.6k tok',
      );
      expect(
        activityDetailText(_job(progress: p)),
        'bash sleep 8 && echo beta · 3 tools · 1.6k tok',
      );
      expect(
        activityDetailText(
          _job(progress: const AgentActivityProgress(tool: 'read')),
        ),
        'read',
      );
      expect(activityDetailText(_job()), isNull);
      expect(
        activityDetailText(
          _job(kind: AgentActivityKind.bash, detail: 'x', command: 'ls'),
        ),
        isNull,
        reason: 'only subagents get a second line',
      );
    });
  });

  group('ActivityPanel widget', () {
    Future<void> pumpPanel(
      WidgetTester tester,
      List<AgentActivityJob> jobs, {
      required DateTime Function() clock,
    }) => tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: ActivityPanel(jobs: jobs, clock: clock)),
      ),
    );

    testWidgets('renders the captured omp snapshot', (tester) async {
      final jobs = (ServerMessage.fromJson(_captured) as AgentActivity).jobs;
      await pumpPanel(
        tester,
        jobs,
        clock: () => DateTime.fromMillisecondsSinceEpoch(_nowMs),
      );

      expect(find.text('waiting on 3 jobs'), findsOneWidget);
      expect(find.text('└─ bg_1 sleep 20 · 6.0s'), findsOneWidget);
      expect(find.text('└─ AgentA AgentA · 2.2s'), findsOneWidget);
      expect(
        find.text('└─ AgentB Run sleep command and report echoed output · 2.2s'),
        findsOneWidget,
      );
      expect(
        find.text('Running sleep then echo · 1 tools · 1.6k tok'),
        findsOneWidget,
      );
      // Three spinners (running rows), no outcome glyphs.
      expect(find.text('✓'), findsNothing);
      expect(find.text('✗'), findsNothing);
      expect(find.text('⠋'), findsNWidgets(3));

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('elapsed ticks every second while running', (tester) async {
      var now = 12300;
      await pumpPanel(tester, [_job(id: 'A', label: 'a')], clock: () {
        return DateTime.fromMillisecondsSinceEpoch(now);
      });
      expect(find.text('└─ A a · 12.3s'), findsOneWidget);

      now += 1000;
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('└─ A a · 13.3s'), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('done ✓, failed/cancelled ✗ in the error color', (
      tester,
    ) async {
      await pumpPanel(tester, [
        _job(id: 'A', status: AgentActivityStatus.done, endedAt: 1000),
        _job(id: 'B', status: AgentActivityStatus.failed, endedAt: 2000),
        _job(id: 'C', status: AgentActivityStatus.cancelled, endedAt: 3000),
      ], clock: () => DateTime.fromMillisecondsSinceEpoch(99999));

      expect(find.text('waiting on 0 jobs'), findsOneWidget);
      expect(find.text('└─ A X · 1.0s'), findsOneWidget);
      expect(find.text('└─ C X · 3.0s'), findsOneWidget);
      expect(find.text('✓'), findsOneWidget);
      final crosses = tester.widgetList<Text>(find.text('✗')).toList();
      expect(crosses, hasLength(2));
      for (final t in crosses) {
        expect(t.style?.color, AppColors.dark.error);
      }
    });

    testWidgets('collapses to the header line and expands back', (
      tester,
    ) async {
      final jobs = (ServerMessage.fromJson(_captured) as AgentActivity).jobs;
      await pumpPanel(
        tester,
        jobs,
        clock: () => DateTime.fromMillisecondsSinceEpoch(_nowMs),
      );
      await tester.tap(find.text('waiting on 3 jobs'));
      await tester.pump();
      expect(find.text('waiting on 3 jobs'), findsOneWidget);
      expect(find.textContaining('└─'), findsNothing);

      await tester.tap(find.text('waiting on 3 jobs'));
      await tester.pump();
      expect(find.textContaining('└─'), findsNWidgets(3));

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('empty snapshot renders nothing', (tester) async {
      await pumpPanel(tester, const [], clock: DateTime.now);
      expect(find.textContaining('waiting on'), findsNothing);
    });
  });
}
