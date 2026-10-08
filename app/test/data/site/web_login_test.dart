import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:app/data/site/site_config.dart';
import 'package:app/data/site/web_login.dart';
import 'package:cryptography/cryptography.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

const _host = '178-157-59-181.sslip.io';

String _b64u(List<int> bytes) => base64Url.encode(bytes).replaceAll('=', '');
Uint8List _unb64u(String s) => base64Url.decode(base64Url.normalize(s));
Uint8List _range(int start, int length) =>
    Uint8List.fromList(List.generate(length, (i) => start + i));

String _code({
  String scheme = 'remotepi',
  String target = 'web-login',
  String? h = _host,
  String? id = 'EBESExQVFhcYGRobHB0eHw',
  String? pk,
}) {
  final params = [
    if (h != null) 'h=$h',
    if (id != null) 'id=$id',
    if (pk != null) 'pk=$pk',
  ];
  return '$scheme://$target?${params.join('&')}';
}

/// Browser side of the contract, written independently of the code under
/// test: X25519(browser sk, epk) → HKDF-SHA256(salt empty, info, 32) →
/// AES-256-GCM(nonce, AAD = id) over ct || tag.
Future<Map<String, Object?>> _browserDecrypt({
  required SimpleKeyPair browserKeyPair,
  required String id,
  required Map<String, String> body,
}) async {
  final shared = await X25519().sharedSecretKey(
    keyPair: browserKeyPair,
    remotePublicKey: SimplePublicKey(
      _unb64u(body['epk']!),
      type: KeyPairType.x25519,
    ),
  );
  final key = await Hkdf(hmac: Hmac.sha256(), outputLength: 32).deriveKey(
    secretKey: shared,
    nonce: const <int>[],
    info: utf8.encode('remote-pi web-login v1'),
  );
  final sealed = _unb64u(body['ct']!);
  final plain = await AesGcm.with256bits().decrypt(
    SecretBox(
      sealed.sublist(0, sealed.length - 16),
      nonce: _unb64u(body['nonce']!),
      mac: Mac(sealed.sublist(sealed.length - 16)),
    ),
    secretKey: key,
    aad: utf8.encode(id),
  );
  return jsonDecode(utf8.decode(plain)) as Map<String, Object?>;
}

Future<(SimpleKeyPair, WebLoginRequest)> _browser({
  String id = 'EBESExQVFhcYGRobHB0eHw',
}) async {
  final keyPair = await X25519().newKeyPair();
  final pk = await keyPair.extractPublicKey();
  final request = parseWebLoginCode(_code(id: id, pk: _b64u(pk.bytes)));
  return (keyPair, request);
}

class _StubAdapter implements HttpClientAdapter {
  final int? status;
  RequestOptions? lastOptions;
  String? lastBody;

  _StubAdapter(this.status);

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    lastOptions = options;
    if (requestStream != null) {
      final bytes = <int>[];
      await for (final chunk in requestStream) {
        bytes.addAll(chunk);
      }
      lastBody = utf8.decode(bytes);
    }
    final code = status;
    if (code == null) throw const SocketException('offline');
    return ResponseBody.fromBytes(Uint8List(0), code);
  }
}

void main() {
  test('allowed host is the host of kWebClientBaseUrl', () {
    expect(webLoginHost, Uri.parse(kWebClientBaseUrl).host);
    expect(webLoginHost, _host);
  });

  group('parseWebLoginCode', () {
    final pk = _b64u(_range(1, 32));

    test('accepts a web-login code for the web client host', () {
      final request = parseWebLoginCode(_code(pk: pk));
      expect(request.host, _host);
      expect(request.id, 'EBESExQVFhcYGRobHB0eHw');
      expect(request.browserPublicKey, _range(1, 32));
      expect(
        request.deliveryUri.toString(),
        'https://$_host/api/web-login/EBESExQVFhcYGRobHB0eHw',
      );
    });

    test('rejects any other host', () {
      for (final h in [
        'evil.example',
        '$_host.evil.example',
        'evil.$_host',
        '$_host:8443',
        '',
      ]) {
        expect(
          () => parseWebLoginCode(_code(h: h, pk: pk)),
          throwsA(isA<WebLoginCodeException>()),
          reason: h,
        );
      }
      expect(
        () => parseWebLoginCode(_code(h: null, pk: pk)),
        throwsA(isA<WebLoginCodeException>()),
      );
    });

    test('rejects a browser key that is not exactly 32 bytes', () {
      for (final bad in [
        _b64u(_range(1, 31)),
        _b64u(_range(1, 33)),
        '',
        '$pk=',
        pk.replaceRange(0, 1, '+'),
      ]) {
        expect(
          () => parseWebLoginCode(_code(pk: bad)),
          throwsA(isA<WebLoginCodeException>()),
          reason: bad,
        );
      }
      expect(
        () => parseWebLoginCode(_code()),
        throwsA(isA<WebLoginCodeException>()),
      );
    });

    test('rejects a missing or malformed id', () {
      for (final id in [null, '', 'a/b', '../x', 'A' * 65]) {
        expect(
          () => parseWebLoginCode(_code(id: id, pk: pk)),
          throwsA(isA<WebLoginCodeException>()),
          reason: id,
        );
      }
    });

    test('rejects URIs that are not web-login codes', () {
      for (final raw in [
        'remotepi://pair?t=AAAA&epk=BBBB&n=mac',
        _code(target: 'pair', pk: pk),
        _code(scheme: 'https', pk: pk),
        'https://$_host/web#k=${_b64u(_range(0, 32))}',
        'remotepi://web-login/extra?h=$_host&id=EBESExQVFhcYGRobHB0eHw&pk=$pk',
        'hello world',
        '',
      ]) {
        expect(
          () => parseWebLoginCode(raw),
          throwsA(isA<WebLoginCodeException>()),
          reason: raw,
        );
      }
    });

    test('names a pairing code as such', () {
      expect(
        () => parseWebLoginCode('remotepi://pair?t=AAAA&epk=BBBB&n=mac'),
        throwsA(
          isA<WebLoginCodeException>().having(
            (e) => e.message,
            'message',
            contains('pairing code'),
          ),
        ),
      );
    });
  });

  group('buildWebLoginEnvelope', () {
    final seed = _range(0, 32);

    test('round-trips to the browser private key', () async {
      final (browserKeyPair, request) = await _browser();
      final envelope = await buildWebLoginEnvelope(
        request: request,
        ownerSeed: seed,
        relayUrl: 'wss://relay.example',
      );
      final body = envelope.toJson();
      expect(body.keys, unorderedEquals(['epk', 'nonce', 'ct']));
      expect(_unb64u(body['epk']!), hasLength(32));
      expect(_unb64u(body['nonce']!), hasLength(12));
      for (final v in body.values) {
        expect(v, isNot(contains('=')));
      }

      final plain = await _browserDecrypt(
        browserKeyPair: browserKeyPair,
        id: request.id,
        body: body,
      );
      expect(plain.keys, ['v', 'seed', 'relay']);
      expect(plain['v'], 1);
      expect(plain['seed'], isNot(contains('=')));
      expect(_unb64u(plain['seed']! as String), seed);
      expect(plain['relay'], 'wss://relay.example');
    });

    test('binds the ciphertext to the login id (AAD)', () async {
      final (browserKeyPair, request) = await _browser();
      final envelope = await buildWebLoginEnvelope(
        request: request,
        ownerSeed: seed,
        relayUrl: 'wss://relay.example',
      );
      await expectLater(
        _browserDecrypt(
          browserKeyPair: browserKeyPair,
          id: 'AAAAAAAAAAAAAAAAAAAAAA',
          body: envelope.toJson(),
        ),
        throwsA(isA<SecretBoxAuthenticationError>()),
      );
    });

    test('only the browser key decrypts it', () async {
      final (_, request) = await _browser();
      final envelope = await buildWebLoginEnvelope(
        request: request,
        ownerSeed: seed,
        relayUrl: 'wss://relay.example',
      );
      await expectLater(
        _browserDecrypt(
          browserKeyPair: await X25519().newKeyPair(),
          id: request.id,
          body: envelope.toJson(),
        ),
        throwsA(isA<SecretBoxAuthenticationError>()),
      );
    });

    test('uses a fresh phone key and nonce per delivery', () async {
      final (_, request) = await _browser();
      Future<WebLoginEnvelope> build() => buildWebLoginEnvelope(
            request: request,
            ownerSeed: seed,
            relayUrl: 'wss://relay.example',
          );
      final a = await build();
      final b = await build();
      expect(a.epk, isNot(b.epk));
      expect(a.nonce, isNot(b.nonce));
    });

    test('matches the browser WebCrypto vector byte for byte', () async {
      // Generated with WebCrypto (X25519 deriveBits → HKDF SHA-256 with empty
      // salt → AES-GCM with additionalData = id), as the browser runs it:
      // browser sk = 0x01..0x20, phone sk = 0x21..0x40, nonce = 0xa0..0xab,
      // seed = 0x00..0x1f, relay = wss://relay.example.
      final request = parseWebLoginCode(
        _code(pk: 'B6N8vBQgk8i3VdwbEOhstCY3StFqqFPtC9_AsrhtHHw'),
      );
      final envelope = await buildWebLoginEnvelope(
        request: request,
        ownerSeed: seed,
        relayUrl: 'wss://relay.example',
        phoneKeyPair: await X25519().newKeyPairFromSeed(_range(33, 32)),
        nonce: _range(0xa0, 12),
      );
      expect(envelope.toJson(), {
        'epk': 'WGmv9FBUlzLLqu1eXfmzCm2jHLDldCutWtShp2jxpns',
        'nonce': 'oKGio6Slpqeoqaqr',
        'ct': 'jYFEyWJNi-O4SgF42RKMkhPj7GH4MxjUDOhICHAIPS7PVekLmxC7ZBmIMyFOtMPo'
            'mLbg5iXJl9stqD56B_UFqy2uFMwNEL8-29HFGJSPD2LVdXmf17yFv9fiyOghJ3GS'
            'gWbsjIxE4X4IKQ',
      });
    });

    test('matches the website test vector (web-login-crypto.test.ts)',
        () async {
      final request = parseWebLoginCode(
        _code(
          id: 'AAECAwQFBgcICQoLDA0ODw',
          pk: 'B6N8vBQgk8i3VdwbEOhstCY3StFqqFPtC9_AsrhtHHw',
        ),
      );
      final envelope = await buildWebLoginEnvelope(
        request: request,
        ownerSeed: _range(0xa0, 32),
        relayUrl: 'wss://relay.example.test',
        phoneKeyPair: await X25519().newKeyPairFromSeed(_range(0x40, 32)),
        nonce: _range(0xf0, 12),
      );
      expect(envelope.toJson(), {
        'epk': 'eaYx7t4b-cmPEgMs3q3Q56B5OY_HhriMyEbsia-FpRo',
        'nonce': '8PHy8_T19vf4-fr7',
        'ct': '_QoeQ7vzsUcpZLtSx0tv85n--H3AVuE-WgumjGP9bwxYscarWFnbtaKgQPGmFA1L'
            'sWeV8BIwtA7IhQvOFAkZ6NWpemcJu90tBZbyE4LHmCEsdx8yIU43OJQwCo1YXDYd'
            '7FRmcNGL9Y8Heor4fnWU',
      });
    });

    test('rejects a seed that is not 32 bytes', () async {
      final (_, request) = await _browser();
      await expectLater(
        buildWebLoginEnvelope(
          request: request,
          ownerSeed: Uint8List(64),
          relayUrl: 'wss://relay.example',
        ),
        throwsArgumentError,
      );
    });
  });

  group('WebLoginClient.deliver', () {
    Future<(WebLoginResult, _StubAdapter)> deliver(int? status) async {
      final adapter = _StubAdapter(status);
      final client = WebLoginClient(dio: Dio()..httpClientAdapter = adapter);
      final request = parseWebLoginCode(_code(pk: _b64u(_range(1, 32))));
      const envelope = WebLoginEnvelope(epk: 'e', nonce: 'n', ct: 'c');
      return (await client.deliver(request, envelope), adapter);
    }

    test('POSTs the envelope as JSON to https://<h>/api/web-login/<id>',
        () async {
      final (result, adapter) = await deliver(204);
      expect(result, isA<WebLoginDelivered>());
      expect(adapter.lastOptions!.method, 'POST');
      expect(
        adapter.lastOptions!.uri.toString(),
        'https://$_host/api/web-login/EBESExQVFhcYGRobHB0eHw',
      );
      expect(adapter.lastOptions!.contentType, startsWith('application/json'));
      expect(jsonDecode(adapter.lastBody!), {
        'epk': 'e',
        'nonce': 'n',
        'ct': 'c',
      });
    });

    test('maps 404 to expired, 409 to already used, others to server error',
        () async {
      expect((await deliver(404)).$1, isA<WebLoginExpired>());
      expect((await deliver(409)).$1, isA<WebLoginAlreadyUsed>());
      expect(
        (await deliver(500)).$1,
        isA<WebLoginServerError>().having((e) => e.status, 'status', 500),
      );
    });

    test('maps a transport failure to a network error', () async {
      expect((await deliver(null)).$1, isA<WebLoginNetworkError>());
    });
  });
}
