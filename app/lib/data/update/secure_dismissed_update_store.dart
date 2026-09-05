import 'package:app/domain/contracts/dismissed_update_store.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Persists the dismissed update version key in [FlutterSecureStorage].
class SecureDismissedUpdateStore implements DismissedUpdateStore {
  SecureDismissedUpdateStore([FlutterSecureStorage? store])
      : _store = store ?? const FlutterSecureStorage();

  final FlutterSecureStorage _store;

  static const String _key = 'update.dismissed_version';

  @override
  Future<String?> dismissedVersion() async {
    final raw = await _store.read(key: _key);
    return (raw != null && raw.isNotEmpty) ? raw : null;
  }

  @override
  Future<void> dismiss(String version) =>
      _store.write(key: _key, value: version);
}
