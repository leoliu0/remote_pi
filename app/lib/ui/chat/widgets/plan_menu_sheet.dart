import 'package:app/protocol/protocol.dart';
import 'package:app/routing/adaptive.dart';
import 'package:app/ui/chat/quick_actions/widgets/dismiss_on_session_change.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

/// Bottom sheet menu for omp plan mode, driven by the session's latest
/// `plan_state`. Returns the `plan_mode` action the user picked (null when
/// dismissed); the caller confirms an exit and dispatches it.
Future<PlanModeAction?> showPlanMenuSheet(
  BuildContext context, {
  required PlanState? planState,
}) {
  final selection = Provider.of<SessionSelection?>(context, listen: false);
  final body = _PlanMenuSheetBody(planState: planState);
  return showModalBottomSheet<PlanModeAction>(
    context: context,
    backgroundColor: context.colors.bg,
    barrierColor: Colors.black.withValues(alpha: 0.6),
    isScrollControlled: true,
    showDragHandle: false,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (ctx) => selection != null
        ? DismissOnSessionChange(
            selection: selection,
            child: body,
          )
        : body,
  );
}

/// omp asks this before leaving plan mode while a plan exists; the Pi answers
/// omp's own confirm with Yes, so the user must agree here first.
Future<bool> confirmPlanExit(BuildContext context) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dCtx) {
      final colors = dCtx.colors;
      return AlertDialog(
        backgroundColor: colors.bg,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
          side: BorderSide(color: colors.border),
        ),
        title: Text(
          'Exit plan mode?',
          style: TextStyle(
            fontFamily: kMonoFamily,
            fontSize: 14,
            color: colors.text,
          ),
        ),
        content: Text(
          'This exits plan mode without approving a plan.',
          style: TextStyle(
            fontFamily: kMonoFamily,
            fontSize: 12,
            color: colors.muted,
          ),
        ),
        actions: [
          TextButton(
            key: const Key('plan-exit-cancel'),
            onPressed: () => Navigator.of(dCtx).pop(false),
            child: Text(
              'Cancel',
              style: TextStyle(fontFamily: kMonoFamily, color: colors.muted),
            ),
          ),
          FilledButton(
            key: const Key('plan-exit-confirm'),
            style: FilledButton.styleFrom(
              backgroundColor: colors.warning,
              foregroundColor: colors.onAccent,
            ),
            onPressed: () => Navigator.of(dCtx).pop(true),
            child: const Text(
              'Exit',
              style: TextStyle(fontFamily: kMonoFamily),
            ),
          ),
        ],
      );
    },
  );
  return confirmed ?? false;
}

class _PlanMenuSheetBody extends StatelessWidget {
  final PlanState? planState;
  const _PlanMenuSheetBody({required this.planState});

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final status = planState?.status ?? PlanStatus.idle;
    final planPath = planState?.planFilePath;

    final (String title, Color statusColor) = switch (status) {
      PlanStatus.idle => ('Plan mode: off', colors.muted),
      PlanStatus.active => ('Plan mode: planning', colors.accent),
      PlanStatus.paused => ('Plan mode: paused', colors.warning),
      PlanStatus.review => ('Plan mode: ready for review', colors.accent),
    };
    final canReview =
        status == PlanStatus.review ||
        (status == PlanStatus.active && planPath != null);

    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 12, 8, 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                width: 36,
                height: 4,
                margin: const EdgeInsets.only(bottom: 12),
                decoration: BoxDecoration(
                  color: colors.border,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(
                children: [
                  Container(
                    width: 8,
                    height: 8,
                    margin: const EdgeInsets.only(right: 8),
                    decoration: BoxDecoration(
                      color: statusColor,
                      shape: BoxShape.circle,
                    ),
                  ),
                  Text(
                    title,
                    style: TextStyle(
                      fontFamily: kMonoFamily,
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: colors.text,
                    ),
                  ),
                ],
              ),
            ),
            if (planPath != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(32, 0, 16, 4),
                child: Text(
                  planPath,
                  style: TextStyle(
                    fontFamily: kMonoFamily,
                    fontSize: 11,
                    color: colors.muted,
                  ),
                ),
              ),
            const SizedBox(height: 4),
            if (canReview)
              _PlanOption(
                key: const Key('plan-menu-review'),
                icon: LucideIcons.fileCheck,
                label: 'Review plan',
                color: colors.accent,
                onTap: () => Navigator.of(context).pop(PlanModeAction.review),
              ),
            if (status == PlanStatus.idle)
              _PlanOption(
                key: const Key('plan-menu-enter'),
                icon: LucideIcons.listTodo,
                label: 'Enter plan mode',
                onTap: () => Navigator.of(context).pop(PlanModeAction.enter),
              )
            else
              _PlanOption(
                key: const Key('plan-menu-exit'),
                icon: LucideIcons.listTodo,
                label: 'Exit plan mode',
                color: colors.warning,
                onTap: () => Navigator.of(context).pop(PlanModeAction.exit),
              ),
          ],
        ),
      ),
    );
  }
}

class _PlanOption extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final Color? color;

  const _PlanOption({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final optColor = color ?? colors.text;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            children: [
              Icon(icon, size: 18, color: optColor),
              const SizedBox(width: 12),
              Text(
                label,
                style: TextStyle(
                  fontFamily: kMonoFamily,
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                  color: optColor,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
