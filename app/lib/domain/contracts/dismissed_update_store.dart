/// Persists the update version dismissed by the user.
/// The banner remains hidden for this version and reappears for newer versions.
abstract class DismissedUpdateStore {
  /// The latest dismissed version, or `null` if none.
  Future<String?> dismissedVersion();

  /// Marks [version] as dismissed.
  Future<void> dismiss(String version);
}
