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
            if (_buildResultBlock(context) case final resultWidget?)
              resultWidget,
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
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 280),
        child: SingleChildScrollView(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(r'$ ', style: typo.mono.copyWith(color: colors.muted)),
              Expanded(child: content),
            ],
          ),
        ),
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
  Widget? _buildResultBlock(BuildContext context) {
    final output = _extractResultText(tool.result, tool.error);
    if (output == null || output.isEmpty) return null;

    final colors = context.colors;
    final typo = context.typo;
    final isError = tool.status == ToolEventStatus.failed || tool.error != null;

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(top: 8),
      decoration: BoxDecoration(
        color: colors.codeBg,
        border: Border.all(
          color: isError
              ? colors.error.withValues(alpha: 0.5)
              : colors.border.withValues(alpha: 0.8),
        ),
        borderRadius: BorderRadius.circular(8),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Icon(
                isError ? LucideIcons.circleAlert : LucideIcons.cornerDownRight,
                size: 11,
                color: isError ? colors.error : colors.muted,
              ),
              const SizedBox(width: 5),
              Text(
                isError ? 'ERROR' : 'OUTPUT',
                style: typo.mono.copyWith(
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.4,
                  color: isError ? colors.error : colors.muted,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 240),
            child: SingleChildScrollView(
              child: SelectableText(
                output,
                style: typo.mono.copyWith(
                  fontSize: 12.0,
                  height: 1.35,
                  color: isError ? colors.error : colors.text,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  static String? _extractResultText(dynamic result, String? error) {
    if (error != null && error.trim().isNotEmpty) {
      return error.trim();
    }
    if (result == null) return null;
    if (result is String) {
      final t = result.trim();
      return t.isNotEmpty ? t : null;
    }
    if (result is Map) {
      final out = result['output'] ??
          result['stdout'] ??
          result['result'] ??
          result['data'] ??
          result['error'] ??
          result['stderr'];
      if (out != null) {
        final t = out.toString().trim();
        if (t.isNotEmpty) return t;
      }
      return result.entries.map((e) => '${e.key}: ${e.value}').join('\n').trim();
    }
    if (result is List) {
      return result.map((e) => e.toString()).join('\n').trim();
    }
    final t = result.toString().trim();
    return t.isNotEmpty ? t : null;
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
        'bash' => () {
            final cmd = ((args['command'] ?? args['cmd'] ?? args['code'] ?? args['c']) as String?)?.replaceAll('\n', ' ').trim();
            if (intent is String && intent.isNotEmpty) {
              return cmd != null && cmd.isNotEmpty ? '$cmd ($intent)' : intent;
            }
            return cmd;
          }(),
        'edit' => () {
            final target = _extractEditTarget(args);
            if (intent is String && intent.isNotEmpty) {
              return target.isNotEmpty ? '$target ($intent)' : intent;
            }
            return target;
          }(),
        'write' => () {
            final target = _stringArg(args, const ['file_path', 'path', 'file']);
            if (intent is String && intent.isNotEmpty) {
              return target.isNotEmpty ? '$target ($intent)' : intent;
            }
            return target;
          }(),
        'ast_edit' => () {
            final paths = args['paths'] is List ? (args['paths'] as List).join(', ') : '';
            if (intent is String && intent.isNotEmpty) {
              return paths.isNotEmpty ? '$paths ($intent)' : intent;
            }
            return paths;
          }(),
        'eval' => (args['title'] ?? args['code'] ?? args['expression'] ?? '').toString().replaceAll('\n', ' ').trim(),
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
      final intent = args['i'] ?? args['title'] ?? args['description'];
      return switch (normalizedTool) {
        'bash' => () {
            final cmd = (args['command'] ??
                args['cmd'] ??
                args['code'] ??
                args['script'] ??
                args['c']) as String?;
            if (cmd != null && cmd.isNotEmpty) {
              if (intent != null && intent.toString().isNotEmpty) {
                return '$cmd\n# $intent';
              }
              return cmd;
            }
            if (intent != null && intent.toString().isNotEmpty) {
              return '# $intent';
            }
            return args.entries.map((e) => '${e.key}=${e.value}').join(' ');
          }(),
        'edit' || 'write' || 'read' => () {
            final path = _stringArg(args, const ['file_path', 'path', 'file']);
            final action = path.isNotEmpty ? '$normalizedTool $path' : normalizedTool;
            if (intent != null && intent.toString().isNotEmpty) {
              return '$action\n# $intent';
            }
            return action;
          }(),
        _ => () {
            final summary =
                args.entries.map((e) => '${e.key}=${e.value}').join(' ');
            if (intent != null && intent.toString().isNotEmpty) {
              return '$summary\n# $intent';
            }
            return summary;
          }(),
      };
    }
    return args.toString();
  }

  static _ToolDisplay? _formatToolDisplay(String tool, dynamic args) {
    if (args is! Map) return null;
    final normalized = tool.toLowerCase();
    return switch (normalized) {
      'edit' => _formatEditDisplay(args),
      'write' => _formatWriteDisplay(args),
      'ast_edit' => _formatAstEditDisplay(args),
      _ => null,
    };
  }

  static _ToolDisplay? _formatEditDisplay(Map args) {
    var filePath = _stringArg(args, const ['file_path', 'path', 'file']);
    final lines = <_DiffLine>[];

    // Case 1: Structured hunks
    final hunks = args['hunks'];
    if (hunks is Iterable) {
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
    }

    // Case 2: old_string / new_string (or old_str / new_str)
    final oldStr = args['old_string'] ?? args['old_str'] ?? args['target'];
    final newStr = args['new_string'] ?? args['new_str'] ?? args['replacement'];
    if (lines.isEmpty && (oldStr is String || newStr is String)) {
      if (oldStr is String && oldStr.isNotEmpty) {
        for (final line in oldStr.split('\n')) {
          lines.add(_DiffLine.removed('- $line'));
        }
      }
      if (newStr is String && newStr.isNotEmpty) {
        for (final line in newStr.split('\n')) {
          lines.add(_DiffLine.added('+ $line'));
        }
      }
    }

    // Case 3: input (hashline patch format or diff)
    final input = args['input'] ?? args['patch'] ?? args['diff'];
    if (lines.isEmpty && input is String && input.trim().isNotEmpty) {
      final splitLines = input.trim().split('\n');
      for (final line in splitLines) {
        if (filePath.isEmpty && line.startsWith('[') && line.contains(']')) {
          final m = RegExp(r'\[([^#\n\]]+)').firstMatch(line);
          if (m != null) filePath = m.group(1)!.trim();
        }
        if (line.startsWith('+') && !line.startsWith('+++')) {
          lines.add(_DiffLine.added(line));
        } else if (line.startsWith('-') && !line.startsWith('---')) {
          lines.add(_DiffLine.removed(line));
        } else if (line.startsWith('PUT ') || line.startsWith('CUT ') || line.startsWith('REM') || line.startsWith('MV ')) {
          lines.add(_DiffLine.header(line));
        } else {
          lines.add(_DiffLine.context('  $line'));
        }
      }
    }

    if (lines.isEmpty) return null;
    final header = filePath.isNotEmpty ? 'edit $filePath' : 'edit';
    return _ToolDisplay(command: header, lines: lines);
  }

  static _ToolDisplay? _formatWriteDisplay(Map args) {
    final filePath = _stringArg(args, const ['file_path', 'path', 'file']);
    final content = args['content'] ?? args['text'] ?? args['code'];
    if (content is! String || content.trim().isEmpty) return null;

    final lines = <_DiffLine>[];
    final splitLines = content.split('\n');
    const maxPreviewLines = 40;
    final displayLines = splitLines.take(maxPreviewLines);
    var lineNum = 1;
    for (final line in displayLines) {
      final numStr = lineNum.toString().padLeft(3);
      lines.add(_DiffLine.added('+ $numStr $line'));
      lineNum++;
    }
    if (splitLines.length > maxPreviewLines) {
      lines.add(_DiffLine.context('      ... +${splitLines.length - maxPreviewLines} more lines'));
    }

    final header = filePath.isNotEmpty ? 'write $filePath' : 'write';
    return _ToolDisplay(command: header, lines: lines);
  }

  static _ToolDisplay? _formatAstEditDisplay(Map args) {
    final paths = args['paths'] is List ? (args['paths'] as List).join(', ') : '';
    final ops = args['ops'];
    if (ops is! Iterable || ops.isEmpty) return null;

    final lines = <_DiffLine>[];
    for (final op in ops) {
      if (op is! Map) continue;
      final pat = op['pat'] as String?;
      final out = op['out'] as String?;
      if (pat != null && pat.isNotEmpty) {
        for (final l in pat.split('\n')) {
          lines.add(_DiffLine.removed('- $l'));
        }
      }
      if (out != null && out.isNotEmpty) {
        for (final l in out.split('\n')) {
          lines.add(_DiffLine.added('+ $l'));
        }
      }
    }

    if (lines.isEmpty) return null;
    final header = paths.isNotEmpty ? 'ast_edit $paths' : 'ast_edit';
    return _ToolDisplay(command: header, lines: lines);
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

  factory _DiffLine.header(String text) =>
      _DiffLine._(text, (colors) => colors.accent);

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
