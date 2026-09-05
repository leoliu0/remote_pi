import 'package:app/domain/entities/update_info.dart';

/// Fetches the release manifest (`latest.json`).
/// Best-effort: any failure returns `null` (never throws).
abstract class UpdateChecker {
  Future<UpdateInfo?> fetchLatest();
}
