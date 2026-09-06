import 'package:app/routing/adaptive.dart';
import 'package:app/ui/chat/quick_actions/widgets/dismiss_on_session_change.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

/// Actions available from the Loop Mode action sheet.
enum LoopMenuAction {
  toggle,
  pause,
  newLoop,
  setCount,
}

/// Bottom sheet menu for Loop Mode operations (toggle, pause, set count, new loop).
Future<LoopMenuAction?> showLoopMenuSheet(
  BuildContext context, {
  required String? loopStatus,
}) {
  final selection = Provider.of<SessionSelection?>(context, listen: false);
  final body = _LoopMenuSheetBody(loopStatus: loopStatus);
  return showModalBottomSheet<LoopMenuAction>(
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

class _LoopMenuSheetBody extends StatelessWidget {
  final String? loopStatus;
  const _LoopMenuSheetBody({required this.loopStatus});

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final isPaused = loopStatus == 'paused';
    final isActive = loopStatus == 'active' || loopStatus == 'running';

    String title;
    Color statusColor;
    if (isActive) {
      title = 'Loop Mode: Active';
      statusColor = colors.accent;
    } else if (isPaused) {
      title = 'Loop Mode: Paused';
      statusColor = colors.warning;
    } else {
      title = 'Loop Mode: Idle';
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
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: Row(
                children: [
                  Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      color: statusColor,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    title,
                    style: TextStyle(
                      fontFamily: kMonoFamily,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: colors.text,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            if (isActive) ...[
              _LoopOption(
                key: const Key('loop-menu-pause'),
                icon: LucideIcons.pause,
                label: 'Pause Loop',
                onTap: () => Navigator.of(context).pop(LoopMenuAction.pause),
              ),
              _LoopOption(
                key: const Key('loop-menu-disable'),
                icon: LucideIcons.power,
                label: 'Disable Loop (/loop)',
                color: colors.error,
                onTap: () => Navigator.of(context).pop(LoopMenuAction.toggle),
              ),
            ] else if (isPaused) ...[
              _LoopOption(
                key: const Key('loop-menu-resume'),
                icon: LucideIcons.play,
                label: 'Resume Loop (/loop)',
                color: colors.accent,
                onTap: () => Navigator.of(context).pop(LoopMenuAction.toggle),
              ),
              _LoopOption(
                key: const Key('loop-menu-disable'),
                icon: LucideIcons.power,
                label: 'Disable Loop',
                color: colors.error,
                onTap: () => Navigator.of(context).pop(LoopMenuAction.toggle),
              ),
            ] else ...[
              _LoopOption(
                key: const Key('loop-menu-enable'),
                icon: LucideIcons.repeat,
                label: 'Enable Loop (/loop)',
                color: colors.accent,
                onTap: () => Navigator.of(context).pop(LoopMenuAction.toggle),
              ),
              _LoopOption(
                key: const Key('loop-menu-new-prompt'),
                icon: LucideIcons.plus,
                label: 'New Loop with Prompt (/loop ...)',
                onTap: () => Navigator.of(context).pop(LoopMenuAction.newLoop),
              ),
              _LoopOption(
                key: const Key('loop-menu-count'),
                icon: LucideIcons.hash,
                label: 'Set Count (/loop 10)',
                onTap: () => Navigator.of(context).pop(LoopMenuAction.setCount),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _LoopOption extends StatelessWidget {
  const _LoopOption({
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
    return ListTile(
      onTap: onTap,
      leading: Icon(icon, color: color ?? colors.accent, size: 20),
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
