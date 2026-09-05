import 'dart:convert';

import 'package:app/domain/contracts/update_checker.dart';
import 'package:app/domain/entities/update_info.dart';
import 'package:dio/dio.dart';

/// Fetches `latest.json` for the app via HTTP. Short timeout; any
/// failure returns `null` (never throws) so the banner remains quiet offline.
///
/// Mirrors Cockpit manifest schema, with 1 `android`/`apk` artifact.
class UpdateCheckerImpl implements UpdateChecker {
  UpdateCheckerImpl({
    String? manifestUrl,
    Duration timeout = const Duration(seconds: 5),
    Dio? dio,
  })  : manifestUrl = manifestUrl ?? defaultManifestUrl,
        _dio = dio ?? _defaultDio(timeout);

  static const String defaultManifestUrl =
      'https://rp-s3.jacobmoura.work/downloads/app/latest.json';

  final String manifestUrl;
  final Dio _dio;

  static Dio _defaultDio(Duration timeout) {
    return Dio(
      BaseOptions(
        connectTimeout: timeout,
        sendTimeout: timeout,
        receiveTimeout: timeout,
        // Handle non-2xx status manually.
        validateStatus: (_) => true,
        // Plain: manual jsonDecode so parser does not fail on empty/non-JSON 4xx/5xx.
        responseType: ResponseType.plain,
      ),
    );
  }

  @override
  Future<UpdateInfo?> fetchLatest() async {
    try {
      final response = await _dio.getUri<Object?>(Uri.parse(manifestUrl));
      if (response.statusCode != 200) return null;
      final data = response.data;
      final body = data is String ? data : null;
      if (body == null || body.isEmpty) return null;
      return UpdateInfo.fromJson(jsonDecode(body));
    } catch (_) {
      // Offline / 404 / invalid JSON / schema mismatch -> silent null.
      return null;
    }
  }
}
