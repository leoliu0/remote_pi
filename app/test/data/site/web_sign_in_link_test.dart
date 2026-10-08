import 'dart:convert';
import 'dart:typed_data';

import 'package:app/data/site/site_config.dart';
import 'package:app/data/site/web_sign_in_link.dart';
import 'package:flutter_test/flutter_test.dart';

/// Seed whose base64 form needs both URL-safe substitutions (`-` and `_`)
/// and would end in `=` padding.
Uint8List _seed() => Uint8List.fromList(
      List<int>.generate(32, (i) => i.isEven ? 0xFB : 0xFF),
    );

void main() {
  group('buildWebSignInLink', () {
    test('points at <siteBase>/web with values in the fragment only', () {
      final link = buildWebSignInLink(
        ownerSeed: _seed(),
        relayUrl: 'https://relay.example',
      );
      final uri = Uri.parse(link);
      // The link carries the owner key: it must target this fork's own web
      // client, never the upstream public site.
      expect(link, startsWith('$kWebClientBaseUrl/web#'));
      expect(uri.host, isNot(Uri.parse(kSiteBaseUrl).host));
      expect(uri.scheme, 'https');
      expect(uri.path, '/web');
      expect(uri.hasQuery, isFalse);
      expect(link.contains('?'), isFalse);
      expect(uri.fragment, startsWith('k='));
    });

    test('k is base64url without padding and decodes to the 32-byte seed',
        () {
      final seed = _seed();
      final link = buildWebSignInLink(
        ownerSeed: seed,
        relayUrl: 'https://relay.example',
      );
      final params = Uri.splitQueryString(Uri.parse(link).fragment);
      final k = params['k']!;

      expect(k.length, 43); // ceil(32 * 4 / 3) without '=' padding.
      expect(k, matches(RegExp(r'^[A-Za-z0-9_-]{43}$')));
      expect(k.contains('='), isFalse);
      // Standard base64 of this seed contains '+' and '/'; url-safe must not.
      expect(base64.encode(seed), contains('+'));
      expect(base64.encode(seed), contains('/'));
      expect(base64Url.decode('$k='), seed);
    });

    test('r is the percent-encoded relay URL', () {
      const relay = 'https://relay.example:8443/a b?x=1&y=2#z';
      final link = buildWebSignInLink(ownerSeed: _seed(), relayUrl: relay);
      final fragment = Uri.parse(link).fragment;

      final raw = fragment.split('&').firstWhere((p) => p.startsWith('r='));
      expect(raw, 'r=${Uri.encodeComponent(relay)}');
      // Reserved characters must not leak into the fragment unencoded.
      expect(raw.substring(2), isNot(contains(RegExp(r'[:/?&#= ]'))));
      expect(Uri.splitQueryString(fragment)['r'], relay);
      expect(fragment.split('&').map((p) => p.split('=').first), ['k', 'r']);
    });

    test('honours a custom site base and drops its trailing slash', () {
      final link = buildWebSignInLink(
        ownerSeed: _seed(),
        relayUrl: 'http://127.0.0.1:8080',
        siteBase: 'http://localhost:3000/',
      );
      expect(link, startsWith('http://localhost:3000/web#k='));
      expect(link, endsWith('&r=http%3A%2F%2F127.0.0.1%3A8080'));
    });

    test('rejects a seed that is not 32 bytes', () {
      expect(
        () => buildWebSignInLink(
          ownerSeed: Uint8List(64),
          relayUrl: 'https://relay.example',
        ),
        throwsArgumentError,
      );
    });
  });
}
