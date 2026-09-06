import 'package:app/routing/adaptive.dart';
import 'package:app/ui/chat/quick_actions/widgets/dismiss_on_session_change.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

/// Actions available from the Goal Mode action sheet.
enum GoalMenuAction {
  resume,
  pause,
  details,
  newGoal,
  drop,
}

/// Bottom sheet menu for Goal Mode operations (resume, pause, details, new, drop).
Future<GoalMenuAction?> showGoalMenuSheet(
  BuildContext context, {
  required String? goalStatus,
}) {
  final selection = Provider.of<SessionSelection?>(context, listen: false);
  final body = _GoalMenuSheetBody(goalStatus: goalStatus);
  return showModalBottomSheet<GoalMenuAction>(
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

class _GoalMenuSheetBody extends StatelessWidget {
  final String? goalStatus;
  const _GoalMenuSheetBody({required this.goalStatus});

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final isPaused = goalStatus == 'paused';
    final isActive = goalStatus == 'active';

    String title;
    Color statusColor;
    if (isActive) {
      title = 'Goal Mode: Active';
      statusColor = colors.accent;
    } else if (isPaused) {
      title = 'Goal Mode: Paused';
      statusColor = colors.warning;
    } else {
      title = 'Goal Mode: Idle';
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
            if (isPaused)
              _GoalOption(
                key: const Key('goal-menu-resume'),
                icon: LucideIcons.play,
                label: 'Resume Goal',
                color: colors.accent,
                onTap: () => Navigator.of(context).pop(GoalMenuAction.resume),
              ),
            if (isActive)
              _GoalOption(
                key: const Key('goal-menu-pause'),
                icon: LucideIcons.pause,
                label: 'Pause Goal',
                color: colors.warning,
                onTap: () => Navigator.of(context).pop(GoalMenuAction.pause),
              ),
            if (isActive || isPaused) ...[
              _GoalOption(
                key: const Key('goal-menu-details'),
                icon: LucideIcons.info,
                label: 'Show Goal Details',
                onTap: () => Navigator.of(context).pop(GoalMenuAction.details),
              ),
              _GoalOption(
                key: const Key('goal-menu-drop'),
                icon: LucideIcons.trash2,
                label: 'Drop Goal',
                color: colors.error,
                onTap: () => Navigator.of(context).pop(GoalMenuAction.drop),
              ),
            ],
            _GoalOption(
              key: const Key('goal-menu-new'),
              icon: LucideIcons.plus,
              label: 'New Goal (/goal)',
              onTap: () => Navigator.of(context).pop(GoalMenuAction.newGoal),
            ),
          ],
        ),
      ),
    );
  }
}

class _GoalOption extends StatelessWidget {
  const _GoalOption({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
    this.color,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final iconColor = color ?? colors.accent;
    return ListTile(
      onTap: onTap,
      leading: Icon(icon, color: iconColor, size: 20),
      title: Text(
        label,
        style: TextStyle(
          fontFamily: kMonoFamily,
          fontSize: 14,
          color: color ?? colors.text,
        ),
      ),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
    );
  }
}
