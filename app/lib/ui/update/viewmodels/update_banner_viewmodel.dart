import 'package:app/domain/contracts/dismissed_update_store.dart';
import 'package:app/domain/contracts/update_checker.dart';
import 'package:app/domain/contracts/url_opener.dart';
import 'package:app/domain/value_objects/semver.dart';
import 'package:app/ui/core/viewmodel/viewmodel.dart';
import 'package:app/ui/update/states/update_banner_state.dart';

/// In-app update banner view model (Android-only).
///
/// Checks release manifest on Home mount; emits [UpdateBannerVisible] if a newer,
/// undismissed version is available. Fails silently on network errors.
class UpdateBannerViewModel extends ViewModel<UpdateBannerState> {
  UpdateBannerViewModel(
    this._checker,
    this._dismissed,
    this._opener, {
    required this.currentVersion,
    required this.enabled,
    this.platform = 'android',
    this.format = 'apk',
    this.arch = 'universal',
    this.fallbackUrl = _kFallbackUrl,
  }) : super(const UpdateBannerHidden());

  final UpdateChecker _checker;
  final DismissedUpdateStore _dismissed;
  final UrlOpener _opener;

  /// Running app version (from `package_info`).
  final String currentVersion;

  /// `true` on Android; `false` on iOS (which updates via App Store).
  final bool enabled;

  /// Artifact coordinates (Android = universal apk).
  final String platform;
  final String format;
  final String arch;

  /// Website download page fallback URL.
  final String fallbackUrl;

  static const String _kFallbackUrl =
      'https://remote-pi.jacobmoura.work/download';

  bool _checked = false;
  bool _disposed = false;

  /// Checks release manifest and determines if the banner should be shown.
  /// Idempotent per instance.
  Future<void> check() async {
    if (!enabled) return; // iOS / non-Android -> never show.
    if (_checked) return;
    _checked = true;

    final latest = await _checker.fetchLatest();
    if (_disposed) return;
    if (latest == null) return; // network error / invalid manifest -> silent return.
    if (!isNewerVersion(latest.version, currentVersion)) {
      return; // equal or older -> nothing to show.
    }

    final dismissed = await _dismissed.dismissedVersion();
    if (_disposed) return;
    if (dismissed == latest.version) return; // dismissed -> nothing to show.

    emit(UpdateBannerVisible(latest));
  }

  /// Dismisses the banner and persists the version as dismissed.
  Future<void> dismiss() async {
    final current = state;
    if (current is! UpdateBannerVisible) return;
    final version = current.info.version;
    emit(const UpdateBannerHidden());
    await _dismissed.dismiss(version);
  }

  /// Downloads the APK (opens download URL in external browser).
  Future<void> download() async {
    final current = state;
    if (current is! UpdateBannerVisible) return;
    final artifact = current.info.artifactFor(
      platform: platform,
      format: format,
      arch: arch,
    );
    await _opener.open(artifact?.url ?? fallbackUrl);
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
