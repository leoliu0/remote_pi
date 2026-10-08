import 'dart:convert';
import 'dart:typed_data';

import 'package:app/data/site/site_config.dart';

/// Builds the one-time sign-in link for the web client:
///
/// `<siteBase>/web#k=<base64url seed, no padding>&r=<encoded relay URL>`
///
/// [ownerSeed] is the 32-byte Ed25519 seed of the Owner key, so the link
/// grants full control of every paired PC. Both values travel in the URL
/// fragment, which browsers never send to the server.
String buildWebSignInLink({
  required Uint8List ownerSeed,
  required String relayUrl,
  String siteBase = kWebClientBaseUrl,
}) {
  if (ownerSeed.length != 32) {
    throw ArgumentError.value(
      ownerSeed.length,
      'ownerSeed.length',
      'Ed25519 seed must be exactly 32 bytes',
    );
  }
  final base = siteBase.endsWith('/')
      ? siteBase.substring(0, siteBase.length - 1)
      : siteBase;
  final k = base64Url.encode(ownerSeed).replaceAll('=', '');
  final r = Uri.encodeComponent(relayUrl);
  return '$base/web#k=$k&r=$r';
}
