import 'package:app/domain/entities/update_info.dart';

/// State of the in-app update banner. Two cases: hidden (no update to show,
/// iOS, dismissed, or manifest unavailable) or visible with [UpdateInfo].
sealed class UpdateBannerState {
  const UpdateBannerState();
}

/// Hidden state (nothing to show).
final class UpdateBannerHidden extends UpdateBannerState {
  const UpdateBannerHidden();
}

/// Visible state with an available, undismissed update version.
final class UpdateBannerVisible extends UpdateBannerState {
  const UpdateBannerVisible(this.info);

  final UpdateInfo info;

  // Equality by version — re-emitting the same version does not trigger rebuilds.
  @override
  bool operator ==(Object other) =>
      other is UpdateBannerVisible && other.info.version == info.version;

  @override
  int get hashCode => info.version.hashCode;
}
