import 'dart:async';

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
  final String? workingLabel;
  final VoidCallback? onCancel;

  const StreamingBubble({
    super.key,
    this.streaming,
    this.isWorking = true,
    this.brief = false,
    this.workingLabel,
    this.onCancel,
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
    final hasVisibleText = buffer.isNotEmpty;
    if (!hasVisibleText && !widget.isWorking) return const SizedBox.shrink();
    final showBanner = widget.isWorking && widget.workingLabel != null;

    return SizedBox(
      width: double.infinity,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (showBanner && !hasVisibleText)
            _TerminalWorkingBanner(
              label: widget.workingLabel!,
              onCancel: widget.onCancel,
            ),
          if (hasVisibleText) AgentMarkdown(buffer),
          if (showBanner && hasVisibleText)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: _TerminalWorkingBanner(
                label: widget.workingLabel!,
                onCancel: widget.onCancel,
              ),
            ),
            _BlinkingCursor(controller: _blink),
        ],
      ),
    );
  }
}

class _TerminalWorkingBanner extends StatefulWidget {
  final String label;
  final VoidCallback? onCancel;

  const _TerminalWorkingBanner({
    super.key,
    required this.label,
    this.onCancel,
  });

  @override
  State<_TerminalWorkingBanner> createState() => _TerminalWorkingBannerState();
}

class _TerminalWorkingBannerState extends State<_TerminalWorkingBanner>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Timer _spinnerTimer;
  int _spinnerTick = 0;
  static const _brailleFrames = ['⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏'];

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1600),
    )..repeat();
    _spinnerTimer = Timer.periodic(const Duration(milliseconds: 80), (_) {
      if (mounted) setState(() => _spinnerTick++);
    });
  }

  @override
  void dispose() {
    _spinnerTimer.cancel();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final typo = context.typo;

    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        final dx = -1.2 + 3.2 * _controller.value;

        return Container(
          key: const Key('thinking-indicator'),
          width: double.infinity,
          margin: const EdgeInsets.only(bottom: 8),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: colors.codeBg,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: colors.accent.withValues(alpha: 0.25)),
          ),
          child: Row(
            children: [
              Text(
                _brailleFrames[_spinnerTick % _brailleFrames.length],
                style: typo.mono.copyWith(
                  color: colors.accent,
                  fontSize: 13.5,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: ShaderMask(
                  blendMode: BlendMode.srcIn,
                  shaderCallback: (bounds) {
                    return LinearGradient(
                      begin: Alignment(dx - 0.6, 0),
                      end: Alignment(dx + 0.6, 0),
                      colors: [
                        colors.muted,
                        colors.accent,
                        colors.muted,
                      ],
                      stops: const [0.0, 0.5, 1.0],
                    ).createShader(bounds);
                  },
                  child: Text(
                    widget.label,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: typo.mono.copyWith(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w500,
                      height: 1.3,
                    ),
                  ),
                ),
              ),
              if (widget.onCancel != null) ...[
                const SizedBox(width: 8),
                Material(
                  color: Colors.transparent,
                  child: InkWell(
                    onTap: widget.onCancel,
                    borderRadius: BorderRadius.circular(4),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                      decoration: BoxDecoration(
                        color: colors.error.withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(4),
                        border: Border.all(
                          color: colors.error.withValues(alpha: 0.4),
                          width: 0.8,
                        ),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Container(
                            width: 6,
                            height: 6,
                            decoration: BoxDecoration(
                              color: colors.error,
                              borderRadius: BorderRadius.circular(1),
                            ),
                          ),
                          const SizedBox(width: 4),
                          Text(
                            'Stop',
                            style: typo.mono.copyWith(
                              fontSize: 10.5,
                              fontWeight: FontWeight.w700,
                              color: colors.error,
                              letterSpacing: 0.3,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ],
          ),
        );
      },
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

