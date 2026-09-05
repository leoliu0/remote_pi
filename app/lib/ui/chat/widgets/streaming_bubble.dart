import 'package:app/domain/session_state.dart';
import 'package:app/ui/chat/widgets/agent_markdown.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:flutter/material.dart';

// StreamingBubble — shows the assistant's growing response + blinking cursor.
// The buffer is already batched with 16ms debounce in SessionRepository.

class StreamingBubble extends StatefulWidget {
  final StreamingMessage? streaming;
  final bool isWorking;
  final bool brief;
  const StreamingBubble({
    super.key,
    this.streaming,
    this.isWorking = true,
    this.brief = false,
  });
  @override
  State<StreamingBubble> createState() => _StreamingBubbleState();
}

class _StreamingBubbleState extends State<StreamingBubble>
    with SingleTickerProviderStateMixin {
  late final AnimationController _blink;

  @override
  void initState() {
    super.initState();
    _blink = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1000),
    )..repeat();
  }

  @override
  void dispose() {
    _blink.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final raw = widget.streaming?.buffer ?? '';
    final buffer = widget.brief
        ? stripThinkingTrace(raw, isLiveStreaming: true)
        : raw;
    final hasText = buffer.isNotEmpty;
    if (!hasText && !widget.isWorking) return const SizedBox.shrink();
    return SizedBox(
      width: double.infinity,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!hasText && widget.isWorking && !widget.brief)
            const _ThinkingIndicator(),
          if (hasText) AgentMarkdown(buffer),
          if (widget.isWorking && widget.streaming != null)
            _BlinkingCursor(controller: _blink),
        ],
      ),
    );
  }
}

class _ThinkingIndicator extends StatelessWidget {
  const _ThinkingIndicator();

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final typo = context.typo;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: colors.codeBg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: colors.accent.withValues(alpha: 0.3)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 10,
            height: 10,
            child: CircularProgressIndicator(
              strokeWidth: 1.8,
              color: colors.accent,
            ),
          ),
          const SizedBox(width: 7),
          Text(
            'Thinking & analyzing…',
            style: typo.mono.copyWith(
              fontSize: 13.0,
              color: colors.muted,
              fontStyle: FontStyle.italic,
            ),
          ),
        ],
      ),
    );
  }
}

class _BlinkingCursor extends AnimatedWidget {
  const _BlinkingCursor({required AnimationController controller})
    : super(listenable: controller);

  @override
  Widget build(BuildContext context) {
    final controller = listenable as AnimationController;
    final visible = controller.value < 0.5;
    return Container(
      key: const Key('streaming-cursor'),
      width: 7,
      height: 14,
      margin: const EdgeInsets.only(left: 3, bottom: 1),
      color: visible ? context.colors.accent : Colors.transparent,
    );
  }
}
