import 'package:app/domain/entities/update_info.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:app/ui/update/states/update_banner_state.dart';
import 'package:app/ui/update/viewmodels/update_banner_viewmodel.dart';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

/// In-app update banner. Renders nothing when hidden.
/// Triggers silent check on Home mount. Tapping downloads the update; X dismisses.
class UpdateBanner extends StatefulWidget {
  const UpdateBanner({super.key});

  @override
  State<UpdateBanner> createState() => _UpdateBannerState();
}

class _UpdateBannerState extends State<UpdateBanner> {
  @override
  void initState() {
    super.initState();
    // `context.read` is safe in initState (does not subscribe).
    // Best-effort check silences all errors and is a no-op outside Android.
    context.read<UpdateBannerViewModel>().check();
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<UpdateBannerViewModel>().state;
    return switch (state) {
      UpdateBannerHidden() => const SizedBox.shrink(),
      UpdateBannerVisible(:final info) => _UpdateCard(info: info),
    };
  }
}

/// Banner card at top of Home screen.
class _UpdateCard extends StatelessWidget {
  const _UpdateCard({required this.info});

  final UpdateInfo info;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final vm = context.read<UpdateBannerViewModel>();
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: Material(
        color: colors.surface,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          key: const Key('update-banner-download'),
          borderRadius: BorderRadius.circular(12),
          onTap: vm.download,
          child: Container(
            padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: colors.accent.withValues(alpha: 0.45)),
            ),
            child: Row(
              children: [
                Icon(
                  LucideIcons.arrowDownToLine,
                  size: 18,
                  color: colors.accent,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        'Update available',
                        overflow: TextOverflow.ellipsis,
                        style: context.typo.sansBody.copyWith(
                          color: colors.text,
                          fontWeight: FontWeight.w600,
                          fontSize: 13.5,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'v${info.version} · tap to download the APK',
                        overflow: TextOverflow.ellipsis,
                        style: context.typo.monoSmall.copyWith(
                          color: colors.muted,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 4),
                IconButton(
                  key: const Key('update-banner-dismiss'),
                  tooltip: 'Dismiss',
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.all(6),
                  constraints: const BoxConstraints(),
                  icon: Icon(LucideIcons.x, size: 16, color: colors.muted2),
                  onPressed: vm.dismiss,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
