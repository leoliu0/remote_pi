import 'dart:async';

import 'package:app/protocol/protocol.dart';
import 'package:app/ui/chat/widgets/agent_markdown.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:flutter/material.dart';

/// Full-screen modal for omp's plan review: an `extension_ui_request` whose
/// [ExtensionUiRequest.plan] envelope carries the proposed plan. Renders the
/// plan markdown and omp's choices in omp's order; a choice is sent as soon as
/// it is tapped (`refine` carries the feedback field's text), "Keep planning"
/// sends `cancelled` (omp: close the review, stay in plan mode).
///
/// Same lifecycle as [ExtensionUiSheet]: the sheet stays open (spinning) until
/// the same-id notify closes it; a warning notify arrives as [error] and
/// re-enables the choices so the user can retry.
class PlanReviewSheet extends StatefulWidget {
  final ExtensionUiRequest request;
  final PlanReview plan;
  final String? error;
  final Future<void> Function(ExtensionUiResponse) onRespond;

  const PlanReviewSheet({
    super.key,
    required this.request,
    required this.plan,
    this.error,
    required this.onRespond,
  });

  @override
  State<PlanReviewSheet> createState() => _PlanReviewSheetState();
}

class _PlanReviewSheetState extends State<PlanReviewSheet> {
  final TextEditingController _feedback = TextEditingController();
  bool _submitting = false;
  // Backstop so an answer that never gets its close/warning (relay drop, Pi
  // gone) doesn't strand the user on a spinner forever.
  Timer? _submitTimeout;
  bool _awaitHint = false;

  @override
  void didUpdateWidget(covariant PlanReviewSheet oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A rejection arrived for this review → stop spinning so the user can act.
    // An error being CLEARED (the viewmodel wiping it at the start of a retry)
    // must not reset, or the choices re-enable mid-flight.
    final errorArrived =
        widget.error != oldWidget.error && widget.error != null;
    if (errorArrived) {
      _submitTimeout?.cancel();
      setState(() {
        _submitting = false;
        _awaitHint = false;
      });
    }
  }

  @override
  void dispose() {
    _submitTimeout?.cancel();
    _feedback.dispose();
    super.dispose();
  }

  Future<void> _send(ExtensionUiResponse response) async {
    if (_submitting) return;
    setState(() {
      _submitting = true;
      _awaitHint = false;
    });
    _submitTimeout?.cancel();
    _submitTimeout = Timer(const Duration(seconds: 10), () {
      if (!mounted || !_submitting) return;
      setState(() {
        _submitting = false;
        _awaitHint = true;
      });
    });
    await widget.onRespond(response);
  }

  Future<void> _choose(PlanReviewAction action) => _send(
    ExtensionUiResponse(
      id: widget.request.id,
      plan: PlanReviewAnswer(action: action, feedback: _feedback.text),
    ),
  );

  Future<void> _keepPlanning() =>
      _send(ExtensionUiResponse(id: widget.request.id, cancelled: true));

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    // System back (Android) = Esc in omp: close the review, keep planning.
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && !_submitting) _keepPlanning();
      },
      child: Material(
        color: colors.bg,
        child: SafeArea(
          child: Scaffold(
            backgroundColor: colors.bg,
            resizeToAvoidBottomInset: true,
            appBar: AppBar(
              backgroundColor: colors.bg,
              elevation: 0,
              scrolledUnderElevation: 0,
              leading: IconButton(
                icon: const Icon(Icons.close),
                tooltip: 'Keep planning',
                onPressed: _submitting ? null : _keepPlanning,
              ),
              title: const Text('Plan ready for review'),
            ),
            // The plan scrolls; the choices stay pinned below it, capped so
            // the plan keeps room even with the keyboard up for feedback.
            body: LayoutBuilder(
              builder: (context, constraints) => Column(
                children: [
                  Expanded(child: _buildPlan(context)),
                  ConstrainedBox(
                    constraints: BoxConstraints(
                      maxHeight: constraints.maxHeight * 0.6,
                    ),
                    child: SingleChildScrollView(child: _buildActions(context)),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildPlan(BuildContext context) {
    final colors = context.colors;
    final text = Theme.of(context).textTheme;
    final plan = widget.plan;
    final content = plan.content;
    final pathStyle = TextStyle(
      fontFamily: kMonoFamily,
      fontSize: 12,
      color: colors.muted,
    );
    return ListView(
      key: const Key('plan-review-plan'),
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
      children: [
        if (plan.title.isNotEmpty)
          Text(plan.title, style: text.titleMedium),
        Text(plan.planFilePath, style: pathStyle),
        const SizedBox(height: 12),
        if (content != null)
          AgentMarkdown(content, selectable: true)
        else ...[
          Text(
            'The plan file could not be read',
            style: text.bodyLarge?.copyWith(color: colors.warning),
          ),
          const SizedBox(height: 4),
          Text(plan.planFilePath, style: pathStyle),
        ],
      ],
    );
  }

  Widget _buildActions(BuildContext context) {
    final colors = context.colors;
    final error = widget.error;
    return Container(
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: colors.border)),
      ),
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (error != null && error.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                error,
                style: TextStyle(color: colors.error, fontSize: 13),
              ),
            )
          else if (_awaitHint)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                'Still waiting for desktop agent to confirm receipt. You can retry or keep planning.',
                style: TextStyle(color: colors.warning, fontSize: 13),
              ),
            ),
          if (_submitting)
            const Padding(
              padding: EdgeInsets.only(bottom: 8),
              child: LinearProgressIndicator(),
            ),
          for (final option in widget.plan.options) ...[
            if (option.action == PlanReviewAction.refine)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: TextField(
                  key: const Key('plan-review-feedback'),
                  controller: _feedback,
                  enabled: !_submitting,
                  minLines: 1,
                  maxLines: 4,
                  decoration: const InputDecoration(
                    hintText: 'What should change? (used by Refine plan)',
                    isDense: true,
                    border: OutlineInputBorder(),
                    contentPadding: EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 10,
                    ),
                  ),
                ),
              ),
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: _optionButton(option),
            ),
          ],
          OutlinedButton(
            key: const Key('plan-review-keep-planning'),
            onPressed: _submitting ? null : _keepPlanning,
            child: const Text('Keep planning'),
          ),
        ],
      ),
    );
  }

  Widget _optionButton(PlanReviewOption option) {
    final key = Key('plan-review-option-${option.action.wire}');
    final onPressed = _submitting || option.disabled
        ? null
        : () => _choose(option.action);
    final label = option.disabled
        ? Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(option.label, textAlign: TextAlign.center),
              const Text(
                'context too full',
                style: TextStyle(fontSize: 11),
              ),
            ],
          )
        : Text(option.label, textAlign: TextAlign.center);
    // The first choice (omp's default, "Approve and execute") is the primary
    // action; the rest are secondary.
    return identical(option, widget.plan.options.first)
        ? FilledButton(key: key, onPressed: onPressed, child: label)
        : FilledButton.tonal(key: key, onPressed: onPressed, child: label);
  }
}
