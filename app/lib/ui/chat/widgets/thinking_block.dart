import 'package:app/ui/chat/widgets/agent_markdown.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:flutter/material.dart';

// Thinking traces — `<think>…</think>` (also thought/thinking/antThinking)
// sections in an assistant reply. With Settings › "Show thinking traces" ON
// they render as a muted, collapsible `Thinking` block; OFF strips them
// ([stripThinkingTrace]). Independent of the tool-call display mode.

final RegExp _openTag = RegExp(
  r'<\s*(?:think|thought|thinking|antThinking)\b[^>]*>',
  caseSensitive: false,
);
final RegExp _closeTag = RegExp(
  r'<\/\s*(?:think|thought|thinking|antThinking)\s*>',
  caseSensitive: false,
);
final RegExp _lineStartBefore = RegExp(r'(?:^|\n)[ \t]*$');

/// One run of an assistant reply: visible text or a thinking trace.
class ThinkingSegment {
  final String text;
  final bool isThinking;

  /// False for a trace whose `</think>` has not arrived (still streaming, or a
  /// turn split before it closed).
  final bool closed;

  const ThinkingSegment.text(this.text) : isThinking = false, closed = true;
  const ThinkingSegment.thinking(this.text, {this.closed = true})
    : isThinking = true;
}

/// Splits [text] into visible-text and thinking segments, in order. Closed
/// tags match anywhere; an UNCLOSED open tag counts as a trace (running to the
/// end of the text) only when it starts a line — a `<thinking>` mentioned
/// inline in prose or code stays literal text. Whitespace-only runs are
/// dropped; segments are trimmed.
List<ThinkingSegment> splitThinking(String text) {
  final out = <ThinkingSegment>[];
  void addText(String s) {
    final t = s.trim();
    if (t.isNotEmpty) out.add(ThinkingSegment.text(t));
  }

  void addThinking(String s, {required bool closed}) {
    final t = s.trim();
    if (t.isNotEmpty || !closed) {
      out.add(ThinkingSegment.thinking(t, closed: closed));
    }
  }

  var pos = 0; // start of the pending visible-text run
  var searchFrom = 0;
  while (true) {
    final open = _openTag.allMatches(text, searchFrom).firstOrNull;
    if (open == null) break;
    final close = _closeTag.allMatches(text, open.end).firstOrNull;
    if (close != null) {
      addText(text.substring(pos, open.start));
      addThinking(text.substring(open.end, close.start), closed: true);
      pos = searchFrom = close.end;
      continue;
    }
    if (_lineStartBefore.hasMatch(text.substring(0, open.start))) {
      addText(text.substring(pos, open.start));
      addThinking(text.substring(open.end), closed: false);
      return out;
    }
    searchFrom = open.end; // literal mention; keep scanning
  }
  addText(text.substring(pos));
  return out;
}

/// An assistant reply with its thinking traces either shown as [ThinkingBlock]s
/// ([showThinking]) or stripped. [live] = the reply is still streaming.
class AssistantContent extends StatelessWidget {
  final String text;
  final bool showThinking;
  final bool live;
  final bool selectable;

  const AssistantContent(
    this.text, {
    super.key,
    required this.showThinking,
    this.live = false,
    this.selectable = false,
  });

  /// Whether anything would render for [text] under these settings.
  static bool hasContent(
    String text, {
    required bool showThinking,
    bool live = false,
  }) => showThinking
      ? splitThinking(text).isNotEmpty
      : stripThinkingTrace(text, isLiveStreaming: live).isNotEmpty;

  @override
  Widget build(BuildContext context) {
    if (!showThinking) {
      final visible = stripThinkingTrace(text, isLiveStreaming: live);
      if (visible.isEmpty) return const SizedBox.shrink();
      return AgentMarkdown(visible, selectable: selectable);
    }
    final segments = splitThinking(text);
    if (segments.isEmpty) return const SizedBox.shrink();
    if (segments.length == 1 && !segments.single.isThinking) {
      return AgentMarkdown(segments.single.text, selectable: selectable);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final (i, s) in segments.indexed) ...[
          if (i > 0) const SizedBox(height: 8),
          s.isThinking
              ? ThinkingBlock(s.text)
              : AgentMarkdown(s.text, selectable: selectable),
        ],
      ],
    );
  }
}

/// Muted, collapsible `Thinking` block: collapsed to its first 2 lines, tap
/// to expand (and again to collapse).
class ThinkingBlock extends StatefulWidget {
  final String text;
  const ThinkingBlock(this.text, {super.key});

  @override
  State<ThinkingBlock> createState() => _ThinkingBlockState();
}

class _ThinkingBlockState extends State<ThinkingBlock> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final mono = context.typo.mono.copyWith(
      fontSize: 13.0,
      height: 1.4,
      color: colors.muted,
    );
    return Material(
      key: const Key('thinking-block'),
      color: Colors.transparent,
      child: InkWell(
        onTap: () => setState(() => _expanded = !_expanded),
        borderRadius: BorderRadius.circular(8),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.fromLTRB(10, 6, 10, 6),
          decoration: BoxDecoration(
            border: Border(
              left: BorderSide(color: colors.border, width: 2),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Text(
                    'Thinking',
                    style: mono.copyWith(
                      fontStyle: FontStyle.italic,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(width: 4),
                  Icon(
                    _expanded ? Icons.expand_less : Icons.expand_more,
                    size: 14,
                    color: colors.muted,
                  ),
                ],
              ),
              if (widget.text.isNotEmpty) ...[
                const SizedBox(height: 2),
                Text(
                  widget.text,
                  maxLines: _expanded ? null : 2,
                  overflow: _expanded ? null : TextOverflow.ellipsis,
                  style: mono,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
