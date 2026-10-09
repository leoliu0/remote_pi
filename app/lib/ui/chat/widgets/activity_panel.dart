import 'dart:async';

import 'package:app/protocol/protocol.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:flutter/material.dart';

// Activity panel — running subagents + background jobs, pinned just above the
// input bar like omp's TUI. Fed by `agent_activity` snapshots. Same strings as
// the terminal and the web client:
//
//   waiting on 2 jobs
//   ⠋ └─ bg_1 sleep 20 · 12.3s
//   ⠋ └─ AgentB Run sleep command and report echoed output · 1m 05s
//          Running sleep then echo · 1 tools · 1.6k tok

/// `12.3s` under a minute, else `1m 05s`. Negative spans clamp to zero.
String formatActivityElapsed(int ms) {
  final clamped = ms < 0 ? 0 : ms;
  final tenths = clamped ~/ 100;
  if (tenths < 600) return '${tenths ~/ 10}.${tenths % 10}s';
  final seconds = clamped ~/ 1000;
  return '${seconds ~/ 60}m ${(seconds % 60).toString().padLeft(2, '0')}s';
}

/// Client-side elapsed: `now - started_at` while running, `ended_at -
/// started_at` once finished (falls back to now when `ended_at` is missing).
int activityElapsedMs(AgentActivityJob job, int nowMs) {
  final end = job.status == AgentActivityStatus.running
      ? nowMs
      : (job.endedAt ?? nowMs);
  return end - job.startedAt;
}

/// `waiting on 1 job` / `waiting on N jobs`, N = running rows.
String activityHeader(List<AgentActivityJob> jobs) {
  final n = jobs.where((j) => j.status == AgentActivityStatus.running).length;
  return 'waiting on $n ${n == 1 ? 'job' : 'jobs'}';
}

/// `└─ <id> <command for bash | label for others> · <elapsed>`.
String activityRowText(AgentActivityJob job, int nowMs) {
  final what = job.kind == AgentActivityKind.bash
      ? (job.command ?? job.label)
      : job.label;
  return '└─ ${job.id} $what · '
      '${formatActivityElapsed(activityElapsedMs(job, nowMs))}';
}

/// Subagent second line: `detail`, else `<tool> <tool_args>`, plus
/// ` · <n> tools` and ` · <x.x>k tok` when reported. Null when there is
/// nothing to say (and always for non-subagent rows).
String? activityDetailText(AgentActivityJob job) {
  if (job.kind != AgentActivityKind.subagent) return null;
  final progress = job.progress;
  final detail = job.detail?.trim();
  final base = (detail != null && detail.isNotEmpty)
      ? detail
      : [progress?.tool, progress?.toolArgs]
            .whereType<String>()
            .where((s) => s.trim().isNotEmpty)
            .join(' ');
  final parts = <String>[
    if (base.isNotEmpty) base,
    if (progress?.toolCount case final count?) '$count tools',
    if (progress?.tokens case final tokens?)
      '${(tokens / 1000).toStringAsFixed(1)}k tok',
  ];
  return parts.isEmpty ? null : parts.join(' · ');
}

const List<String> _brailleFrames = [
  '⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏', //
];

class ActivityPanel extends StatefulWidget {
  final List<AgentActivityJob> jobs;

  /// Injectable clock so tests can pin elapsed times.
  final DateTime Function() clock;

  const ActivityPanel({super.key, required this.jobs, this.clock = DateTime.now});

  @override
  State<ActivityPanel> createState() => _ActivityPanelState();
}

class _ActivityPanelState extends State<ActivityPanel> {
  bool _collapsed = false;
  Timer? _ticker;
  int _tick = 0;

  bool get _anyRunning =>
      widget.jobs.any((j) => j.status == AgentActivityStatus.running);

  @override
  void initState() {
    super.initState();
    _syncTicker();
  }

  @override
  void didUpdateWidget(covariant ActivityPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncTicker();
  }

  /// One timer drives the spinner frames and the elapsed counters (which are
  /// recomputed from the clock on every build); it only runs while a row is.
  void _syncTicker() {
    if (_anyRunning) {
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
    final jobs = widget.jobs;
    if (jobs.isEmpty) return const SizedBox.shrink();
    final colors = context.colors;
    final mono = context.typo.mono.copyWith(fontSize: 12.5, height: 1.35);
    final muted = mono.copyWith(color: colors.muted);
    final nowMs = widget.clock().millisecondsSinceEpoch;
    final spinner = _brailleFrames[_tick % _brailleFrames.length];

    return Container(
      key: const Key('activity-panel'),
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
            onTap: () => setState(() => _collapsed = !_collapsed),
            child: Row(
              children: [
                Expanded(child: Text(activityHeader(jobs), style: muted)),
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
              // Many parallel subagents must not push the composer off screen.
              constraints: const BoxConstraints(maxHeight: 180),
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (final job in jobs)
                      _row(job, nowMs, spinner, mono, muted, colors),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _row(
    AgentActivityJob job,
    int nowMs,
    String spinner,
    TextStyle mono,
    TextStyle muted,
    AppColors colors,
  ) {
    final (glyph, glyphColor) = switch (job.status) {
      AgentActivityStatus.running => (spinner, colors.accent),
      AgentActivityStatus.done => ('✓', colors.success),
      AgentActivityStatus.failed ||
      AgentActivityStatus.cancelled => ('✗', colors.error),
    };
    final detail = activityDetailText(job);
    return Padding(
      padding: const EdgeInsets.only(top: 2),
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
                  activityRowText(job, nowMs),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: mono.copyWith(color: colors.text),
                ),
                if (detail != null)
                  Padding(
                    padding: const EdgeInsets.only(left: 24),
                    child: Text(
                      detail,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: muted,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
