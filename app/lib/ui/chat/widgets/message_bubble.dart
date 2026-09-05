import 'package:app/domain/session_state.dart';
import 'package:app/ui/chat/widgets/agent_markdown.dart';
import 'package:app/ui/chat/widgets/image_bubble.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

// ---------------------------------------------------------------------------
// UserBubble — right-aligned dark card
// ---------------------------------------------------------------------------

class UserBubble extends StatelessWidget {
  final UserMsg message;
  const UserBubble(this.message, {super.key});

  @override
  Widget build(BuildContext context) {
    // Plan/24-fix-app-source-of-truth: render the lifecycle stage of
    // the bubble. `pending` (sent over WS, Pi hasn't echoed yet) gets
    // reduced opacity + a small spinner; `failed` (no echo in 15s) gets
    // a red exclamation badge so the user knows to retry.
    final isPending = message.status == UserMsgStatus.pending;
    final isFailed = message.status == UserMsgStatus.failed;
    final isSteering = message.steering;
    // Plan/30 — when an image is attached the bubble becomes an ImageBubble
    // (thumbnail + caption); otherwise the existing text card.
    final image = message.image;
    final colors = context.colors;
    final typo = context.typo;
    return Align(
      alignment: Alignment.centerRight,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 300),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Opacity(
              opacity: isPending ? 0.6 : 1.0,
              child: image != null
                  ? ImageBubble(
                      image: image,
                      caption: message.text,
                      isFailed: isFailed,
                    )
                  : Container(
                      decoration: BoxDecoration(
                        color: colors.userBubble,
                        borderRadius: BorderRadius.circular(12),
                        border: isFailed
                            ? Border.all(color: colors.error, width: 1)
                            : null,
                      ),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 13,
                        vertical: 10,
                      ),
                      // Selectable so the user can copy their own message (the
                      // agent reply is already selectable via AgentMarkdown).
                      child: SelectableText(
                        message.text,
                        style: typo.mono.copyWith(
                          fontSize: 15.0,
                          color: colors.text,
                          height: 1.45,
                        ),
                      ),
                    ),
            ),
            if (isPending || isSteering || isFailed)
              Padding(
                padding: const EdgeInsets.only(top: 4, right: 4),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (isPending || isSteering) ...[
                      SizedBox(
                        width: 10,
                        height: 10,
                        child: CircularProgressIndicator(
                          color: colors.muted,
                          strokeWidth: 1.2,
                        ),
                      ),
                      const SizedBox(width: 6),
                      Text(
                        isSteering ? 'steering…' : 'sending…',
                        style: typo.sansBody.copyWith(
                          color: colors.muted,
                          fontSize: 12,
                        ),
                      ),
                    ] else ...[
                      Icon(
                        LucideIcons.circleAlert,
                        size: 12,
                        color: colors.error,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        'not delivered',
                        style: typo.sansBody.copyWith(
                          color: colors.error,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// CompactionBubble — centered system card (plan/32)
// ---------------------------------------------------------------------------

/// A system message distinct from user/assistant: shows that the Pi compacted
/// the context, with the recap summary and the reclaimed token count. Mirrors
/// the TUI's CompactionSummaryMessageComponent.
class CompactionBubble extends StatefulWidget {
  final CompactionMsg message;
  const CompactionBubble(this.message, {super.key});

  @override
  State<CompactionBubble> createState() => _CompactionBubbleState();
}

class _CompactionBubbleState extends State<CompactionBubble> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final tokens = widget.message.tokensBefore;
    final summary = widget.message.summary.trim();
    final colors = context.colors;
    final hasSummary = summary.isNotEmpty;

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 380),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: hasSummary ? () => setState(() => _expanded = !_expanded) : null,
            borderRadius: BorderRadius.circular(8),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: colors.surface,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: colors.border.withValues(alpha: 0.8)),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(LucideIcons.check, size: 12, color: colors.success),
                      const SizedBox(width: 5),
                      Expanded(
                        child: Text(
                          'Context compacted',
                          style: context.typo.mono.copyWith(
                            fontSize: 13.0,
                            color: colors.text,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      if (tokens != null) ...[
                        Text(
                          '~$tokens tokens',
                          style: context.typo.mono.copyWith(
                            fontSize: 12.0,
                            color: colors.muted,
                          ),
                        ),
                        const SizedBox(width: 4),
                      ],
                      if (hasSummary)
                        Icon(
                          _expanded ? LucideIcons.chevronUp : LucideIcons.chevronDown,
                          size: 12,
                          color: colors.muted,
                        ),
                    ],
                  ),
                  if (hasSummary) ...[
                    const SizedBox(height: 3),
                    Text(
                      summary,
                      maxLines: _expanded ? null : 1,
                      overflow: _expanded ? TextOverflow.visible : TextOverflow.ellipsis,
                      style: context.typo.mono.copyWith(
                        fontSize: 12.5,
                        color: colors.muted2,
                        height: 1.35,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// AssistantBubble — left-aligned monospace text
// ---------------------------------------------------------------------------

class AssistantBubble extends StatelessWidget {
  final AssistantMsg message;
  final bool brief;
  const AssistantBubble(this.message, {super.key, this.brief = false});

  @override
  Widget build(BuildContext context) {
    final text = brief ? stripThinkingTrace(message.text) : message.text;
    if (text.isEmpty) return const SizedBox.shrink();
    // Plan/32b — agent output is rendered as Markdown (GFM + code blocks),
    // spanning the FULL content width (the message list already pads 16px on
    // each side) — unlike the user's right-aligned chat bubble, which stays
    // capped. Selectable so prose/code can be copied.
    return SizedBox(
      width: double.infinity,
      child: AgentMarkdown(text, selectable: true),
    );
  }
}
