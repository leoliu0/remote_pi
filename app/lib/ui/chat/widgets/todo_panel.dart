import 'dart:async';

import 'package:app/domain/session_state.dart' show ToolEventStatus;
import 'package:app/protocol/protocol.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:flutter/material.dart';

// Todo panel — omp's todo list (the TUI's `TODO` panel), pinned above the
// input bar next to the activity panel. Fed by `todo_state` snapshots. Same
// rules and strings as omp v18.9.2 and the web client:
//
//   TODO 2/6                                   (done = completed + abandoned)
//   I. Setup · 1/2                             (active phase: accent, bold)
//     ✓ Create repo                            (done: struck through, muted)
//     ○ Add CI
//   II. Build · 1/4
//     ⠋ Write parser                           (in progress: highlighted)
//     ! Write tests (blocked)  waiting on fixtures
//     ✗ Ship                                   (dropped)

/// `(done, total)` over [tasks]; omp counts dropped tasks as done.
(int, int) todoCount(Iterable<TodoTask> tasks) {
  var done = 0;
  var total = 0;
  for (final t in tasks) {
    total++;
    if (t.status.isDone) done++;
  }
  return (done, total);
}

/// The phase omp highlights: first with pending/in-progress work, else the last.
int todoActivePhase(List<TodoPhase> phases) {
  final open = phases.indexWhere(
    (p) => p.tasks.any(
      (t) => t.status == TodoStatus.pending || t.status == TodoStatus.inProgress,
    ),
  );
  return open == -1 ? phases.length - 1 : open;
}

const List<(int, String)> _roman = [
  (1000, 'M'), (900, 'CM'), (500, 'D'), (400, 'CD'), (100, 'C'), (90, 'XC'), //
  (50, 'L'), (40, 'XL'), (10, 'X'), (9, 'IX'), (5, 'V'), (4, 'IV'), (1, 'I'),
];

/// `I. Setup` when the list has several phases (omp numbers them), else the name.
String todoPhaseTitle(String name, int index, int phaseCount) {
  if (phaseCount <= 1) return name;
  var n = index + 1;
  final roman = StringBuffer();
  for (final (value, digits) in _roman) {
    while (n >= value) {
      roman.write(digits);
      n -= value;
    }
  }
  return '$roman. $name';
}

/// The task omp treats as current: the in-progress one, else the first pending.
TodoTask? todoCurrentTask(List<TodoPhase> phases) {
  final tasks = [for (final p in phases) ...p.tasks];
  for (final t in tasks) {
    if (t.status == TodoStatus.inProgress) return t;
  }
  for (final t in tasks) {
    if (t.status == TodoStatus.pending) return t;
  }
  return null;
}

// omp's todo result text: `Overall: 3/7 done, 4 open.` / `Todo list cleared.`
final RegExp _overall = RegExp(r'^Overall: (\d+)/(\d+) done\b', multiLine: true);

/// The one-line pill a `todo` tool row shows instead of a full card:
/// `Todo · 3/7` + `done · Write parser` (`Todo · <op>` while it runs).
(String, String) todoPillText(Object? args, String? output, ToolEventStatus status) {
  final a = args is Map ? args : const {};
  final op = a['op'] is String ? a['op'] as String : 'update';
  final target = [a['task'], a['phase']]
      .whereType<String>()
      .where((s) => s.isNotEmpty)
      .firstOrNull;
  final list = a['list'] is List ? (a['list'] as List).length : 0;
  final items = a['items'] is List ? (a['items'] as List).length : 0;
  final detail = target != null
      ? '$op · $target'
      : list > 0
          ? '$op · $list phase${list == 1 ? '' : 's'}'
          : items > 0
              ? '$op · $items item${items == 1 ? '' : 's'}'
              : op;
  switch (status) {
    case ToolEventStatus.pending || ToolEventStatus.allowed:
      return ('Todo · $op', target ?? '');
    case ToolEventStatus.failed ||
        ToolEventStatus.denied ||
        ToolEventStatus.expired:
      return ('Todo · failed', detail);
    case ToolEventStatus.completed:
      final m = output == null ? null : _overall.firstMatch(output);
      if (m != null) return ('Todo · ${m[1]}/${m[2]}', detail);
      return (output != null && output.contains('cleared') ? 'Todo · cleared' : 'Todo', detail);
  }
}

const List<String> _brailleFrames = [
  '⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏', //
];

class TodoPanel extends StatefulWidget {
  final List<TodoPhase> phases;

  /// The agent is running: the in-progress task spins.
  final bool working;

  const TodoPanel({super.key, required this.phases, this.working = false});

  @override
  State<TodoPanel> createState() => _TodoPanelState();
}

class _TodoPanelState extends State<TodoPanel> {
  bool _collapsed = false;
  // Finished phases start folded (omp's checklist `collapsed`); tap unfolds.
  final Set<String> _unfolded = {};
  Timer? _ticker;
  int _tick = 0;

  bool get _spinning =>
      widget.working &&
      widget.phases.any((p) => p.tasks.any((t) => t.status == TodoStatus.inProgress));

  @override
  void initState() {
    super.initState();
    _syncTicker();
  }

  @override
  void didUpdateWidget(covariant TodoPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncTicker();
  }

  void _syncTicker() {
    if (_spinning) {
      _ticker ??= Timer.periodic(const Duration(milliseconds: 100), (_) {
        if (mounted) setState(() => _tick++);
      });
    } else {
      _ticker?.cancel();
      _ticker = null;
    }
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final phases = widget.phases;
    if (phases.isEmpty) return const SizedBox.shrink();
    final colors = context.colors;
    final mono = context.typo.mono.copyWith(fontSize: 12.5, height: 1.35);
    final muted = mono.copyWith(color: colors.muted);
    final (done, total) = todoCount([for (final p in phases) ...p.tasks]);
    final current = todoCurrentTask(phases);
    final active = todoActivePhase(phases);

    return Container(
      key: const Key('todo-panel'),
      width: double.infinity,
      decoration: BoxDecoration(
        color: colors.codeBg,
        border: Border(top: BorderSide(color: colors.border)),
      ),
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          InkWell(
            key: const Key('todo-panel-header'),
            onTap: () => setState(() => _collapsed = !_collapsed),
            child: Row(
              children: [
                Text(
                  'TODO',
                  style: mono.copyWith(color: colors.accent, fontWeight: FontWeight.w700),
                ),
                const SizedBox(width: 6),
                Text('$done/$total', style: muted),
                if (_collapsed) ...[
                  Text(' · ', style: muted),
                  Expanded(
                    child: Text(
                      current?.content ?? '✓ done',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: mono.copyWith(color: current == null ? colors.success : colors.text),
                    ),
                  ),
                ] else
                  const Spacer(),
                Icon(
                  _collapsed ? Icons.expand_less : Icons.expand_more,
                  size: 16,
                  color: colors.muted,
                ),
              ],
            ),
          ),
          if (!_collapsed)
            ConstrainedBox(
              // A long list must not push the composer off screen.
              constraints: const BoxConstraints(maxHeight: 220),
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (var i = 0; i < phases.length; i++)
                      ..._phase(phases[i], i, phases.length, i == active, mono, muted, colors),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  List<Widget> _phase(
    TodoPhase phase,
    int index,
    int phaseCount,
    bool isActive,
    TextStyle mono,
    TextStyle muted,
    AppColors colors,
  ) {
    final (done, total) = todoCount(phase.tasks);
    // Finished phases other than the active one fold (the TUI always lists the
    // active phase's tasks).
    final finished = !isActive && done == total;
    final open = !finished || _unfolded.contains(phase.name);
    final title = todoPhaseTitle(phase.name, index, phaseCount);
    return [
      InkWell(
        onTap: finished
            ? () => setState(() {
                  if (!_unfolded.remove(phase.name)) _unfolded.add(phase.name);
                })
            : null,
        child: Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Row(
            children: [
              Flexible(
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: isActive
                      ? mono.copyWith(color: colors.accent, fontWeight: FontWeight.w700)
                      : muted,
                ),
              ),
              Text(' · $done/$total', style: muted.copyWith(fontSize: 11.5)),
              if (finished)
                Icon(
                  open ? Icons.expand_more : Icons.chevron_right,
                  size: 14,
                  color: colors.muted,
                ),
            ],
          ),
        ),
      ),
      if (open)
        for (final task in phase.tasks) _task(task, mono, muted, colors),
    ];
  }

  Widget _task(TodoTask task, TextStyle mono, TextStyle muted, AppColors colors) {
    final struck = muted.copyWith(decoration: TextDecoration.lineThrough);
    final (glyph, glyphColor, textStyle) = switch (task.status) {
      TodoStatus.inProgress => (
          widget.working ? _brailleFrames[_tick % _brailleFrames.length] : '●',
          colors.accent,
          mono.copyWith(color: colors.text, fontWeight: FontWeight.w600),
        ),
      TodoStatus.pending => ('○', colors.muted, mono.copyWith(color: colors.text.withValues(alpha: 0.75))),
      TodoStatus.completed => ('✓', colors.success, struck),
      TodoStatus.abandoned => ('✗', colors.error, struck),
      TodoStatus.blocked => ('!', colors.warning, mono.copyWith(color: colors.warning)),
    };
    final highlighted = task.status == TodoStatus.inProgress;
    return Container(
      margin: const EdgeInsets.only(top: 2, left: 8),
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
      decoration: highlighted
          ? BoxDecoration(
              color: colors.accent.withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(4),
            )
          : null,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 16,
            child: Text(glyph, style: mono.copyWith(color: glyphColor)),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  task.status == TodoStatus.blocked ? '${task.content} (blocked)' : task.content,
                  style: textStyle,
                ),
                if (task.blocker case final blocker?)
                  Text(blocker, style: muted.copyWith(fontSize: 11.5)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
