import 'package:app/domain/session_state.dart';
import 'package:app/protocol/protocol.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:flutter/material.dart';

// Inline tool execution card that appears in the chat flow.
//
// Historically this widget rendered Allow/Deny buttons + a 60s countdown
// assuming the Pi paused execution until the user decided. With the current
// Claude SDK integration the pi-extension emits `tool_request` AFTER the
// SDK has already accepted the tool (`tool_execution_start` fires post
// auto-approval), so the buttons could only blink for a few hundred
// milliseconds before `tool_result` arrived — confusing UX with no real
// gating. The card is now purely informational.
//
// `onDecide` is kept on the API for forward compat — when the Pi adds a
// real approval pause we can re-enable the controls. Today it is unused.

import 'package:lucide_icons_flutter/lucide_icons.dart';

class ToolRequestCard extends StatefulWidget {
  final ToolEvent tool;
  final void Function(String toolCallId, ApproveDecision decision)? onDecide;
  final bool brief;

  const ToolRequestCard({
    super.key,
    required this.tool,
    this.onDecide,
    this.brief = false,
  });

  @override
  State<ToolRequestCard> createState() => _ToolRequestCardState();
}

class _ToolRequestCardState extends State<ToolRequestCard> {
  bool _expanded = false;

  ToolEvent get tool => widget.tool;
  /// Plan/32 — one color drives the whole card so the outcome is unmistakable:
  /// running → blue, done → green, failed → red, denied/expired → grey.
  Color _statusColor(BuildContext context) {
    final colors = context.colors;
    return switch (tool.status) {
      ToolEventStatus.pending || ToolEventStatus.allowed => colors.accent,
      ToolEventStatus.completed => colors.success,
      ToolEventStatus.failed => colors.error,
      ToolEventStatus.denied || ToolEventStatus.expired => colors.muted,
    };
  }

  @override
  Widget build(BuildContext context) {
    final color = _statusColor(context);
    if (widget.brief && !_expanded) {
      return _buildBriefPill(context, color);
    }

    final dimmed =
        tool.status == ToolEventStatus.denied ||
        tool.status == ToolEventStatus.expired;

    return Opacity(
      opacity: dimmed ? 0.65 : 1.0,
      child: Container(
        decoration: BoxDecoration(
          color: context.colors.surface,
          border: Border.all(color: color, width: 1),
          borderRadius: BorderRadius.circular(12),
          boxShadow: [
            BoxShadow(
              color: color.withValues(alpha: 0.13),
              blurRadius: 20,
              spreadRadius: 1,
            ),
          ],
        ),
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildHeader(context, color),
            const SizedBox(height: 10),
            _buildCodeBlock(context),
            const SizedBox(height: 8),
            _buildOutcome(color),
          ],
        ),
      ),
    );
  }

  Widget _buildBriefPill(BuildContext context, Color color) {
    final colors = context.colors;
    final summary = _formatBriefSummary(tool.tool, tool.args);
    final statusIcon = switch (tool.status) {
      ToolEventStatus.pending || ToolEventStatus.allowed => '⏳',
      ToolEventStatus.completed => '✓',
      ToolEventStatus.failed => '✗',
      ToolEventStatus.denied => '⊘',
      ToolEventStatus.expired => '⏱',
    };
    final dimmed =
        tool.status == ToolEventStatus.denied ||
        tool.status == ToolEventStatus.expired;
    final monoFont = context.typo.mono.fontFamily ?? kMonoFamily;

    return Opacity(
      opacity: dimmed ? 0.65 : 1.0,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: () => setState(() => _expanded = !_expanded),
          borderRadius: BorderRadius.circular(8),
          child: Container(
            decoration: BoxDecoration(
              color: colors.codeBg,
              border: Border.all(color: color.withValues(alpha: 0.5)),
              borderRadius: BorderRadius.circular(8),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
            child: Row(
              children: [
                CustomPaint(
                  size: const Size(12, 12),
                  painter: _TerminalIconPainter(color: color),
                ),
                const SizedBox(width: 7),
                Text(
                  tool.tool.toUpperCase(),
                  style: TextStyle(
                    fontFamily: monoFont,
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: color,
                    letterSpacing: 0.4,
                  ),
                ),
                if (summary.isNotEmpty) ...[
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      summary,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontFamily: monoFont,
                        fontSize: 11.5,
                        color: colors.text,
                      ),
                    ),
                  ),
                ] else ...[
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      tool.status == ToolEventStatus.pending ||
                              tool.status == ToolEventStatus.allowed
                          ? 'running…'
                          : '',
                      style: TextStyle(
                        fontFamily: monoFont,
                        fontSize: 11.5,
                        color: colors.muted,
                        fontStyle: FontStyle.italic,
                      ),
                    ),
                  ),
                ],
                Text(
                  statusIcon,
                  style: TextStyle(
                    fontSize: 11,
                    color: color,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(width: 4),
                Icon(
                  LucideIcons.chevronDown,
                  size: 13,
                  color: colors.muted,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildHeader(BuildContext context, Color color) {
    final statusLabel = switch (tool.status) {
      ToolEventStatus.pending || ToolEventStatus.allowed => 'RUNNING',
      ToolEventStatus.completed => 'DONE',
      ToolEventStatus.failed => 'FAILED',
      ToolEventStatus.denied => 'DENIED',
      ToolEventStatus.expired => 'EXPIRED',
    };

    return Row(
      children: [
        CustomPaint(
          size: const Size(14, 14),
          painter: _TerminalIconPainter(color: color),
        ),
        const SizedBox(width: 8),
        Text(
          tool.tool.toUpperCase(),
          style: TextStyle(
            fontFamily: kMonoFamily,
            fontSize: 11.5,
            color: color,
            letterSpacing: 0.6,
          ),
        ),
        const Spacer(),
        Text(
          statusLabel,
          style: TextStyle(
            fontFamily: context.typo.mono.fontFamily ?? kMonoFamily,
            fontSize: 10,
            color: color,
            letterSpacing: 0.4,
          ),
        ),
        if (widget.brief && _expanded) ...[
          const SizedBox(width: 6),
          GestureDetector(
            onTap: () => setState(() => _expanded = false),
            child: Icon(LucideIcons.chevronUp, size: 14, color: color),
          ),
        ],
      ],
    );
  }

  Widget _buildCodeBlock(BuildContext context) {
    final colors = context.colors;
    final typo = context.typo;
    final content = _buildToolSummary(context);
    return Container(
      decoration: BoxDecoration(
        color: colors.codeBg,
        border: Border.all(color: colors.border),
        borderRadius: BorderRadius.circular(8),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(r'$ ', style: typo.mono.copyWith(color: colors.muted)),
          Expanded(child: content),
        ],
      ),
    );
  }

  Widget _buildToolSummary(BuildContext context) {
    final colors = context.colors;
    final typo = context.typo;
    final display = _formatToolDisplay(tool.tool, tool.args);
    if (display == null) {
      return Text(_formatArgs(tool.tool, tool.args), style: typo.mono);
    }

    return Text.rich(
      TextSpan(
        style: typo.mono,
        children: [
          TextSpan(text: display.command),
          for (final line in display.lines) ...[
            const TextSpan(text: '\n'),
            TextSpan(
              text: line.text,
              style: TextStyle(color: line.color(colors)),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildOutcome(Color color) {
    final text = switch (tool.status) {
      ToolEventStatus.pending || ToolEventStatus.allowed => '⏳ Running…',
      ToolEventStatus.completed => '✓ Done',
      ToolEventStatus.failed => '✗ ${tool.error ?? "Failed"}',
      ToolEventStatus.denied => '✗ ${tool.error ?? "Denied"}',
      ToolEventStatus.expired => '✗ Expired',
    };
    return Text(
      text,
      style: TextStyle(fontFamily: kMonoFamily, fontSize: 12, color: color),
    );
  }

  static String _formatBriefSummary(String tool, dynamic args) {
    if (args == null) return '';
    final normalized = tool.toLowerCase();
    if (args is Map) {
      final intent = args['i'] ?? args['title'] ?? args['description'];
      final specific = switch (normalized) {
        'bash' => ((args['command'] ?? args['cmd'] ?? args['code'] ?? args['c']) as String?)?.replaceAll('\n', ' ').trim(),
        'edit' => _extractEditTarget(args),
        'write' || 'read' => _stringArg(args, const ['file_path', 'path', 'file']),
        'glob' => (args['pattern'] ?? args['path'] ?? '').toString(),
        'grep' => (args['pattern'] ?? args['path'] ?? '').toString(),
        'eval' => (args['title'] ?? args['code'] ?? args['expression'] ?? '').toString().replaceAll('\n', ' ').trim(),
        'web_search' => (args['query'] ?? args['q'] ?? '').toString(),
        'task' => (args['task'] ?? args['context'] ?? '').toString().replaceAll('\n', ' ').trim(),
        'hub' => _formatHubArgs(args),
        'ask' => _formatAskArgs(args),
        'lsp' => '${args['action'] ?? ''} ${_stringArg(args, const ['file', 'path'])}'.trim(),
        'browser' => '${args['action'] ?? ''} ${args['url'] ?? ''}'.trim(),
        _ => null,
      };

      if (specific != null && specific.isNotEmpty) {
        return specific;
      }
      if (intent is String && intent.isNotEmpty) {
        return intent.replaceAll('\n', ' ').trim();
      }
      return _formatArgs(tool, args).replaceAll('\n', ' ').trim();
    }
    return args.toString().replaceAll('\n', ' ').trim();
  }

  static String _extractEditTarget(Map args) {
    final direct = _stringArg(args, const ['file_path', 'path', 'file']);
    if (direct.isNotEmpty) return direct;
    final input = args['input'];
    if (input is String) {
      final match = RegExp(r'\[([^#\n\]]+)').firstMatch(input);
      if (match != null) return match.group(1)!.trim();
    }
    return '';
  }

  static String _formatHubArgs(Map args) {
    final op = args['op'] ?? '';
    final target = args['to'] ?? args['name'] ?? args['application'] ?? args['from'] ?? '';
    if (target != null && target.toString().isNotEmpty) {
      return '$op $target';
    }
    return op.toString();
  }

  static String _formatAskArgs(Map args) {
    final questions = args['questions'];
    if (questions is List && questions.isNotEmpty) {
      final first = questions.first;
      if (first is Map && first['question'] != null) {
        return first['question'].toString();
      }
    }
    return '';
  }

  static String _formatArgs(String tool, dynamic args) {
    if (args == null) return '';
    final normalizedTool = tool.toLowerCase();
    if (args is Map) {
      return switch (normalizedTool) {
        'bash' => (args['command'] as String?) ?? '',
        'edit' || 'write' || 'read' =>
          '$normalizedTool ${_stringArg(args, const ['file_path', 'path', 'file'])}',
        _ => args.entries.map((e) => '${e.key}=${e.value}').join(' '),
      };
    }
    return args.toString();
  }

  static _ToolDisplay? _formatToolDisplay(String tool, dynamic args) {
    if (args is! Map) return null;
    return switch (tool.toLowerCase()) {
      'edit' => _formatEditDisplay(args),
      _ => null,
    };
  }

  static _ToolDisplay? _formatEditDisplay(Map args) {
    final filePath = _stringArg(args, const ['file_path', 'path']);
    final lines = <_DiffLine>[];
    final hunks = args['hunks'];
    if (hunks is! Iterable) return null;

    for (final hunk in hunks) {
      if (hunk is! Map || hunk['lines'] is! Iterable) continue;
      if (lines.isNotEmpty) lines.add(_DiffLine.context('      ...'));
      for (final rawLine in hunk['lines'] as Iterable) {
        if (rawLine is! Map) continue;
        final text = _lineText(rawLine);
        switch (rawLine['kind']) {
          case 'context':
            lines.add(_DiffLine.context(text));
          case 'remove':
            lines.add(_DiffLine.removed(text));
          case 'add':
            lines.add(_DiffLine.added(text));
          case 'ellipsis':
            lines.add(_DiffLine.context('      ...'));
        }
      }
    }

    if (lines.isEmpty) return null;
    return _ToolDisplay(command: 'edit $filePath', lines: lines);
  }

  static String _lineText(Map rawLine) {
    final sign = switch (rawLine['kind']) {
      'remove' => '-',
      'add' => '+',
      _ => ' ',
    };
    final lineNumber = rawLine['oldLine'] ?? rawLine['newLine'];
    final number = lineNumber is int ? lineNumber.toString().padLeft(3) : '   ';
    return '$sign $number ${rawLine['text'] ?? ''}';
  }

  static String _stringArg(Map args, List<String> keys) {
    for (final key in keys) {
      final value = args[key];
      if (value is String) return value;
    }
    return '';
  }
}

class _ToolDisplay {
  final String command;
  final List<_DiffLine> lines;

  const _ToolDisplay({required this.command, required this.lines});
}

class _DiffLine {
  final String text;
  final Color Function(AppColors colors) color;

  const _DiffLine._(this.text, this.color);

  factory _DiffLine.removed(String text) =>
      _DiffLine._(text, (colors) => colors.error);

  factory _DiffLine.added(String text) =>
      _DiffLine._(text, (colors) => colors.success);

  factory _DiffLine.context(String text) =>
      _DiffLine._(text, (colors) => colors.text);
}

// Minimal terminal icon (rectangle + > and —)
class _TerminalIconPainter extends CustomPainter {
  final Color color;
  const _TerminalIconPainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2
      ..strokeCap = StrokeCap.round;

    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(0.5, 1, size.width - 1, size.height - 2),
        const Radius.circular(1.6),
      ),
      paint,
    );
    final path = Path()
      ..moveTo(3, 4.5)
      ..lineTo(5.5, 7)
      ..lineTo(3, 9.5);
    canvas.drawPath(path, paint);
    canvas.drawLine(
      Offset(6.5, size.height / 2),
      Offset(size.width - 2, size.height / 2),
      paint,
    );
  }

  @override
  bool shouldRepaint(_TerminalIconPainter old) => old.color != color;
}
