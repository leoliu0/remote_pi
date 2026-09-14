import 'package:app/routing/adaptive.dart';
import 'package:app/ui/chat/quick_actions/widgets/dismiss_on_session_change.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

/// Actions available from the Plan Mode action sheet.
enum PlanMenuAction {
  toggle,
  review,
}

/// Bottom sheet menu for Plan Mode operations (toggle /plan, review /plan-review).
Future<PlanMenuAction?> showPlanMenuSheet(
  BuildContext context, {
  required String? planStatus,
}) {
  final selection = Provider.of<SessionSelection?>(context, listen: false);
  final body = _PlanMenuSheetBody(planStatus: planStatus);
  return showModalBottomSheet<PlanMenuAction>(
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

class _PlanMenuSheetBody extends StatelessWidget {
  final String? planStatus;
  const _PlanMenuSheetBody({required this.planStatus});

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final isReview = planStatus == 'review';
    final isActive = planStatus == 'active';

    String title;
    Color statusColor;
    if (isReview) {
      title = 'Plan Mode: Ready for Review';
      statusColor = colors.accent;
    } else if (isActive) {
      title = 'Plan Mode: Active (Planning)';
      statusColor = colors.accent;
    } else {
      title = 'Plan Mode: Off';
      statusColor = colors.muted;
    }

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
            const SizedBox(height: 4),
            if (isReview || isActive)
              _PlanOption(
                key: const Key('plan-menu-review'),
                icon: LucideIcons.fileCheck,
                label: 'Review Proposed Plan (/plan-review)',
                color: colors.accent,
                onTap: () => Navigator.of(context).pop(PlanMenuAction.review),
              ),
            _PlanOption(
              key: const Key('plan-menu-toggle'),
              icon: LucideIcons.listTodo,
              label: isActive ? 'Exit Plan Mode (/plan)' : 'Enable Plan Mode (/plan)',
              color: isActive ? colors.warning : colors.text,
              onTap: () => Navigator.of(context).pop(PlanMenuAction.toggle),
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
