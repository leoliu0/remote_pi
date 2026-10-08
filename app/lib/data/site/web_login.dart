import 'dart:convert';

import 'package:app/data/site/site_config.dart';
import 'package:cryptography/cryptography.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

/// Reverse web sign-in (WhatsApp-Web style): the website shows
///
/// `remotepi://web-login?h=<host>&id=<id>&pk=<b64u browser X25519 pub>`
///
/// and the phone answers with the Owner seed, end-to-end encrypted to the
/// browser's ephemeral key: X25519 → HKDF-SHA256 (empty salt, info
/// [kWebLoginHkdfInfo], 32 bytes) → AES-256-GCM (12-byte random nonce,
/// AAD = UTF-8 of the login id). The server only relays the opaque body.

/// HKDF `info` shared with the web client.
const String kWebLoginHkdfInfo = 'remote-pi web-login v1';

/// The only host the phone delivers the Owner seed to: the host of
/// [kWebClientBaseUrl].
String get webLoginHost => Uri.parse(kWebClientBaseUrl).host;

/// A validated `remotepi://web-login` code.
@immutable
class WebLoginRequest {
  /// Host of the website that showed the code (== [webLoginHost]).
  final String host;

  /// Login id, base64url without padding. Also the AES-GCM AAD.
  final String id;

  /// The browser's ephemeral X25519 public key (32 bytes).
  final Uint8List browserPublicKey;

  const WebLoginRequest({
    required this.host,
    required this.id,
    required this.browserPublicKey,
  });

  /// `https://<host>/api/web-login/<id>`.
  Uri get deliveryUri =>
      Uri(scheme: 'https', host: host, path: '/api/web-login/$id');
}

/// A scanned code that is not a usable web sign-in code. [message] is
/// user-facing.
class WebLoginCodeException implements Exception {
  final String message;
  const WebLoginCodeException(this.message);

  @override
  String toString() => 'WebLoginCodeException: $message';
}

final RegExp _b64uPattern = RegExp(r'^[A-Za-z0-9_-]+$');

String _b64u(List<int> bytes) => base64Url.encode(bytes).replaceAll('=', '');

Uint8List? _decodeB64u(String value) {
  if (!_b64uPattern.hasMatch(value) || value.length % 4 == 1) return null;
  try {
    return base64Url.decode(base64Url.normalize(value));
  } on FormatException {
    return null;
  }
}

/// Parses and validates a scanned QR payload. Throws
/// [WebLoginCodeException] unless [raw] is a `remotepi://web-login` code
/// for [expectedHost] (default [webLoginHost]) carrying a well-formed id and
/// a 32-byte browser key.
WebLoginRequest parseWebLoginCode(String raw, {String? expectedHost}) {
  final allowedHost = (expectedHost ?? webLoginHost).toLowerCase();
  final Uri uri;
  try {
    uri = Uri.parse(raw.trim());
  } on FormatException {
    throw const WebLoginCodeException(
      'Not a web sign-in code. Scan the QR code shown on the website.',
    );
  }
  if (uri.scheme == 'remotepi' && uri.host == 'pair') {
    throw const WebLoginCodeException(
      'This is a PC pairing code, not a web sign-in code. '
      'Scan the QR code shown on the website.',
    );
  }
  if (uri.scheme != 'remotepi' ||
      uri.host != 'web-login' ||
      (uri.path.isNotEmpty && uri.path != '/')) {
    throw const WebLoginCodeException(
      'Not a web sign-in code. Scan the QR code shown on the website.',
    );
  }

  final params = uri.queryParameters;
  final host = params['h']?.toLowerCase();
  if (host == null || host != allowedHost) {
    throw WebLoginCodeException(
      'Unknown website. Remote Pi only signs in browsers at $allowedHost.',
    );
  }
  final id = params['id'];
  if (id == null || id.length > 64 || _decodeB64u(id) == null) {
    throw const WebLoginCodeException(
      'Damaged sign-in code. Refresh the website and scan again.',
    );
  }
  final pk = params['pk'];
  final browserPublicKey = pk == null ? null : _decodeB64u(pk);
  if (browserPublicKey == null || browserPublicKey.length != 32) {
    throw const WebLoginCodeException(
      'Damaged sign-in code. Refresh the website and scan again.',
    );
  }
  return WebLoginRequest(
    host: host,
    id: id,
    browserPublicKey: browserPublicKey,
  );
}

/// The body POSTed to `/api/web-login/<id>`: all fields base64url without
/// padding; [ct] is the AES-GCM ciphertext followed by its 16-byte tag.
@immutable
class WebLoginEnvelope {
  final String epk;
  final String nonce;
  final String ct;

  const WebLoginEnvelope({
    required this.epk,
    required this.nonce,
    required this.ct,
  });

  Map<String, String> toJson() => {'epk': epk, 'nonce': nonce, 'ct': ct};
}

/// Encrypts `{"v":1,"seed":…,"relay":…}` to the browser key in [request].
///
/// [phoneKeyPair] and [nonce] are fresh random values in production; tests
/// pin them to check against an independent implementation.
Future<WebLoginEnvelope> buildWebLoginEnvelope({
  required WebLoginRequest request,
  required List<int> ownerSeed,
  required String relayUrl,
  @visibleForTesting SimpleKeyPair? phoneKeyPair,
  @visibleForTesting List<int>? nonce,
}) async {
  if (ownerSeed.length != 32) {
    throw ArgumentError.value(
      ownerSeed.length,
      'ownerSeed.length',
      'Ed25519 seed must be exactly 32 bytes',
    );
  }
  final x25519 = X25519();
  final keyPair = phoneKeyPair ?? await x25519.newKeyPair();
  final shared = await x25519.sharedSecretKey(
    keyPair: keyPair,
    remotePublicKey: SimplePublicKey(
      request.browserPublicKey,
      type: KeyPairType.x25519,
    ),
  );
  final key = await Hkdf(hmac: Hmac.sha256(), outputLength: 32).deriveKey(
    secretKey: shared,
    info: utf8.encode(kWebLoginHkdfInfo),
  );
  final aes = AesGcm.with256bits();
  final box = await aes.encrypt(
    utf8.encode(
      jsonEncode({'v': 1, 'seed': _b64u(ownerSeed), 'relay': relayUrl}),
    ),
    secretKey: key,
    nonce: nonce ?? aes.newNonce(),
    aad: utf8.encode(request.id),
  );
  final phonePublicKey = await keyPair.extractPublicKey();
  return WebLoginEnvelope(
    epk: _b64u(phonePublicKey.bytes),
    nonce: _b64u(box.nonce),
    ct: _b64u([...box.cipherText, ...box.mac.bytes]),
  );
}

/// Outcome of approving a web sign-in.
sealed class WebLoginResult {
  const WebLoginResult();
}

/// 204 — the browser can now pick up the envelope.
final class WebLoginDelivered extends WebLoginResult {
  const WebLoginDelivered();
}

/// 404 — the code expired (or never existed).
final class WebLoginExpired extends WebLoginResult {
  const WebLoginExpired();
}

/// 409 — another phone already answered this code.
final class WebLoginAlreadyUsed extends WebLoginResult {
  const WebLoginAlreadyUsed();
}

/// Any other HTTP status.
final class WebLoginServerError extends WebLoginResult {
  final int? status;
  const WebLoginServerError(this.status);
}

/// The request never got an HTTP response (offline, DNS, TLS, timeout).
final class WebLoginNetworkError extends WebLoginResult {
  const WebLoginNetworkError();
}

/// The Owner identity has not booted, so there is no seed to send.
final class WebLoginNoIdentity extends WebLoginResult {
  const WebLoginNoIdentity();
}

/// Delivers a [WebLoginEnvelope] to the website. Raw `DioException`s never
/// escape; every outcome maps to a [WebLoginResult].
class WebLoginClient {
  final Dio _dio;

  WebLoginClient({Dio? dio}) : _dio = dio ?? _defaultDio();

  static Dio _defaultDio() => Dio(
        BaseOptions(
          connectTimeout: const Duration(seconds: 10),
          sendTimeout: const Duration(seconds: 10),
          receiveTimeout: const Duration(seconds: 10),
          validateStatus: (_) => true,
          responseType: ResponseType.plain,
        ),
      );

  /// `POST https://<h>/api/web-login/<id>` with the envelope as JSON.
  Future<WebLoginResult> deliver(
    WebLoginRequest request,
    WebLoginEnvelope envelope,
  ) async {
    try {
      final response = await _dio.postUri<Object?>(
        request.deliveryUri,
        data: jsonEncode(envelope.toJson()),
        options: Options(
          contentType: Headers.jsonContentType,
          responseType: ResponseType.plain,
          validateStatus: (_) => true,
        ),
      );
      return switch (response.statusCode) {
        200 || 204 => const WebLoginDelivered(),
        404 => const WebLoginExpired(),
        409 => const WebLoginAlreadyUsed(),
        final status => WebLoginServerError(status),
      };
    } on DioException catch (e) {
      final status = e.response?.statusCode;
      if (status != null) return WebLoginServerError(status);
      return const WebLoginNetworkError();
    }
  }
}
