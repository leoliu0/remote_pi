import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:app/data/local/app_database.dart';
import 'package:app/data/mesh/mesh_blob.dart';
import 'package:app/data/mesh/mesh_client.dart';
import 'package:app/data/mesh/mesh_sync_service.dart';
import 'package:app/pairing/owner_identity_bridge.dart';
import 'package:app/pairing/storage.dart';
import 'package:cryptography/cryptography.dart';
import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_pi_identity/remote_pi_identity.dart';

class _FakeSecureStorage implements FlutterSecureStorage {
  final Map<String, String> values;
  _FakeSecureStorage([Map<String, String>? values])
      : values = values ?? <String, String>{};

  @override
  Future<String?> read({
    required String key,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async =>
      values[key];

  @override
  Future<Map<String, String>> readAll({
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async =>
      Map<String, String>.of(values);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Reply {
  final int status;
  final String body;
  final Future<void>? gate;
  final Completer<void>? seen;

  const _Reply(this.status, this.body, {this.gate, this.seen});
}

class _CapturedRequest {
  final String method;
  final Uri uri;
  final String? body;

  const _CapturedRequest(this.method, this.uri, this.body);
}

class _ScriptedAdapter implements HttpClientAdapter {
  final Map<String, List<_Reply>> _replies = <String, List<_Reply>>{};
  final List<_CapturedRequest> requests = <_CapturedRequest>[];
  int _active = 0;
  int maxActive = 0;

  void enqueue(String method, String path, _Reply reply) {
    _replies.putIfAbsent('$method $path', () => <_Reply>[]).add(reply);
  }

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final bytes = <int>[];
    if (requestStream != null) {
      await for (final chunk in requestStream) {
        bytes.addAll(chunk);
      }
    }
    final body = bytes.isEmpty ? null : utf8.decode(bytes);
    requests.add(_CapturedRequest(options.method, options.uri, body));

    final key = '${options.method} ${options.uri.path}';
    final queue = _replies[key];
    if (queue == null || queue.isEmpty) {
      throw StateError('No scripted response for $key');
    }
    final reply = queue.removeAt(0);
    _active++;
    if (_active > maxActive) maxActive = _active;
    reply.seen?.complete();
    try {
      if (reply.gate != null) await reply.gate;
      return ResponseBody.fromBytes(
        Uint8List.fromList(utf8.encode(reply.body)),
        reply.status,
        headers: const <String, List<String>>{
          Headers.contentTypeHeader: <String>['application/json'],
        },
      );
    } finally {
      _active--;
    }
  }
}

class _OwnerFixture {
  final SimpleKeyPair keyPair;
  final Uint8List ownerPk;
  final OwnerIdentity identity;

  const _OwnerFixture(this.keyPair, this.ownerPk, this.identity);
}

Future<_OwnerFixture> _newOwner() async {
  final keyPair = await Ed25519().newKeyPair();
  final public = await keyPair.extractPublicKey();
  final ownerPk = Uint8List.fromList(public.bytes);
  final identity = OwnerIdentity(
    ownerPk: ownerPk,
    ownerSk: Uint8List.fromList(await keyPair.extractPrivateKeyBytes()),
  );
  return _OwnerFixture(keyPair, ownerPk, identity);
}

class _Fixture {
  final AppDatabase database;
  final PairingStorage storage;
  final InMemoryOwnerIdentityStore identityStore;
  final OwnerIdentityBridge bridge;
  final _ScriptedAdapter adapter;
  final MeshSyncService service;
  final String ownerHash;
  final String Function() relay;

  const _Fixture({
    required this.database,
    required this.storage,
    required this.identityStore,
    required this.bridge,
    required this.adapter,
    required this.service,
    required this.ownerHash,
    required this.relay,
  });
}

Future<_Fixture> _fixture(
  _OwnerFixture owner, {
  required String Function() relay,
  _FakeSecureStorage? legacy,
  AppDatabase? database,
}) async {
  final db = database ?? AppDatabase.memory();
  final storage = PairingStorage(db, legacyStore: legacy ?? _FakeSecureStorage());
  await storage.initialize(ownerPk: owner.ownerPk, relayUrl: relay());
  final identityStore = InMemoryOwnerIdentityStore(initial: owner.identity);
  final bridge = OwnerIdentityBridge(identityStore, storage);
  expect(await bridge.boot(), isA<IdentityReady>());
  final adapter = _ScriptedAdapter();
  final dio = Dio(BaseOptions(
    validateStatus: (_) => true,
    responseType: ResponseType.plain,
  ))..httpClientAdapter = adapter;
  final client = MeshClient(baseUrlProvider: relay, dio: dio);
  final service = MeshSyncService(client, bridge, storage);
  final hash = await MeshClient.ownerPkHash(owner.ownerPk);

  addTearDown(service.dispose);
  addTearDown(bridge.dispose);
  addTearDown(identityStore.dispose);
  if (database == null) addTearDown(db.dispose);
  return _Fixture(
    database: db,
    storage: storage,
    identityStore: identityStore,
    bridge: bridge,
    adapter: adapter,
    service: service,
    ownerHash: hash,
    relay: relay,
  );
}

Future<String> _snapshotBody(
  _OwnerFixture owner,
  int version,
  List<MeshMember> members, {
  int? responseVersion,
  int updatedAt = 1000,
  bool corruptSignature = false,
}) async {
  final blob = MeshBlob(
    version: version,
    issuedAt: updatedAt,
    ownerPk: owner.ownerPk,
    members: members,
  );
  final signed = await blob.signWith(owner.keyPair);
  final signature = Uint8List.fromList(signed.sig);
  if (corruptSignature) signature[0] ^= 0xff;
  return jsonEncode(<String, Object?>{
    'blob': base64.encode(signed.blob),
    'sig': base64.encode(signature),
    'version': responseVersion ?? version,
    'updated_at': updatedAt,
  });
}

MeshBlob _postedBlob(_CapturedRequest request) {
  final json = jsonDecode(request.body!) as Map<String, Object?>;
  return MeshBlob.fromCanonicalBytes(base64.decode(json['blob']! as String));
}

const _alpha = MeshMember(
  remoteEpk: 'alpha',
  relayUrl: 'wss://relay.example.test',
  pairedAt: '2026-09-01T00:00:00Z',
  nickname: 'Alpha',
);
const _beta = MeshMember(
  remoteEpk: 'beta',
  relayUrl: 'wss://relay.example.test',
  pairedAt: '2026-09-02T00:00:00Z',
  nickname: 'Beta',
);
const _gammaPeer = PeerRecord(
  remoteEpk: 'gamma',
  sessionName: 'gamma-session',
  relayUrl: 'wss://relay.example.test',
  pairedAt: '2026-09-03T00:00:00Z',
  nickname: 'Gamma',
);

const _migratedA = PeerRecord(
  remoteEpk: 'migrated-a',
  sessionName: 'Migrated A',
  relayUrl: 'https://relay.example.test',
  pairedAt: '2026-08-01T00:00:00Z',
  nickname: 'A',
);
const _migratedB = PeerRecord(
  remoteEpk: 'migrated-b',
  sessionName: 'Migrated B',
  relayUrl: 'https://relay.example.test',
  pairedAt: '2026-08-02T00:00:00Z',
  nickname: 'B',
);

_FakeSecureStorage _legacyPeers(List<PeerRecord> peers) {
  return _FakeSecureStorage(<String, String>{
    'dev.remotepi.peers_index':
        jsonEncode(peers.map((peer) => peer.remoteEpk).toList()),
    for (final peer in peers)
      'dev.remotepi.peers:${peer.remoteEpk}': jsonEncode(peer.toJson()),
  });
}

void main() {
  test('signed member legacy URL does not redefine active relay scope',
      () async {
    final owner = await _newOwner();
    final fixture = await _fixture(
      owner,
      relay: () => 'http://relay.example.test:3000',
    );
    const legacyMember = MeshMember(
      remoteEpk: 'legacy-member',
      relayUrl: 'http://relay.example.test',
      pairedAt: '2026-08-01T00:00:00Z',
      nickname: 'Legacy',
    );
    fixture.adapter.enqueue(
      'GET',
      '/mesh/${fixture.ownerHash}',
      _Reply(
        200,
        await _snapshotBody(
          owner,
          1,
          const <MeshMember>[legacyMember],
        ),
      ),
    );

    expect(await fixture.service.synchronize(), isTrue);
    final stored = (await fixture.storage.listPeers()).single;
    expect(stored.remoteEpk, legacyMember.remoteEpk);
    expect(stored.relayUrl, legacyMember.relayUrl);
    expect(fixture.storage.membershipScope?.relayUrl,
        'http://relay.example.test:3000');
  });

  test('migration recovery cannot publish before relay confirms 404',
      () async {
    final owner = await _newOwner();
    final fixture = await _fixture(
      owner,
      relay: () => 'https://relay.example.test',
      legacy: _legacyPeers(const <PeerRecord>[_migratedA, _migratedB]),
    );
    await fixture.storage.savePeer(
      _gammaPeer,
      intent: PeerSaveIntent.enroll,
    );

    expect(await fixture.service.drainPending(), isFalse);
    expect(
      fixture.adapter.requests.where((request) => request.method == 'POST'),
      isEmpty,
    );
    expect(fixture.storage.pendingMembershipOperationCount, 1);
  });

  test('404 recovery revokes one migrated peer without revoking the rest',
      () async {
    final owner = await _newOwner();
    final fixture = await _fixture(
      owner,
      relay: () => 'https://relay.example.test',
      legacy: _legacyPeers(const <PeerRecord>[_migratedA, _migratedB]),
    );
    await fixture.storage.deletePeer(_migratedA.remoteEpk);
    fixture.adapter.enqueue(
      'GET',
      '/mesh/${fixture.ownerHash}',
      const _Reply(404, ''),
    );
    fixture.adapter.enqueue(
      'POST',
      '/mesh/${fixture.ownerHash}',
      const _Reply(200, '{"version":1,"updated_at":1}'),
    );

    expect(await fixture.service.synchronize(), isTrue);
    final posted = fixture.adapter.requests
        .where((request) => request.method == 'POST')
        .single;
    expect(
      _postedBlob(posted).members.map((member) => member.remoteEpk),
      <String>[_migratedB.remoteEpk],
    );
  });

  test('404 recovery adds a new enrollment to every migrated peer', () async {
    final owner = await _newOwner();
    final fixture = await _fixture(
      owner,
      relay: () => 'https://relay.example.test',
      legacy: _legacyPeers(const <PeerRecord>[_migratedA, _migratedB]),
    );
    await fixture.storage.savePeer(
      _gammaPeer,
      intent: PeerSaveIntent.enroll,
    );
    fixture.adapter.enqueue(
      'GET',
      '/mesh/${fixture.ownerHash}',
      const _Reply(404, ''),
    );
    fixture.adapter.enqueue(
      'POST',
      '/mesh/${fixture.ownerHash}',
      const _Reply(200, '{"version":1,"updated_at":1}'),
    );

    expect(await fixture.service.synchronize(), isTrue);
    final posted = fixture.adapter.requests
        .where((request) => request.method == 'POST')
        .single;
    expect(
      _postedBlob(posted).members.map((member) => member.remoteEpk).toSet(),
      <String>{_migratedA.remoteEpk, _migratedB.remoteEpk, 'gamma'},
    );
  });

  test('valid signed snapshot never unions unrelated migrated projection',
      () async {
    final owner = await _newOwner();
    final fixture = await _fixture(
      owner,
      relay: () => 'https://relay.example.test',
      legacy: _legacyPeers(const <PeerRecord>[_migratedA, _migratedB]),
    );
    await fixture.storage.savePeer(
      _gammaPeer,
      intent: PeerSaveIntent.enroll,
    );
    const signedA = MeshMember(
      remoteEpk: 'migrated-a',
      relayUrl: 'https://relay.example.test',
      pairedAt: '2026-08-01T00:00:00Z',
      nickname: 'A',
    );
    fixture.adapter.enqueue(
      'GET',
      '/mesh/${fixture.ownerHash}',
      _Reply(
        200,
        await _snapshotBody(owner, 5, const <MeshMember>[signedA]),
      ),
    );
    fixture.adapter.enqueue(
      'POST',
      '/mesh/${fixture.ownerHash}',
      const _Reply(200, '{"version":6,"updated_at":6}'),
    );

    expect(await fixture.service.synchronize(), isTrue);
    final posted = fixture.adapter.requests
        .where((request) => request.method == 'POST')
        .single;
    expect(
      _postedBlob(posted).members.map((member) => member.remoteEpk).toSet(),
      <String>{_migratedA.remoteEpk, 'gamma'},
    );
    expect(
      (await fixture.storage.listPeers()).map((peer) => peer.remoteEpk).toSet(),
      <String>{_migratedA.remoteEpk, 'gamma'},
    );
  });

  test('404 establishes a signed base without erasing migrated inventory',
      () async {
    final owner = await _newOwner();
    const local = PeerRecord(
      remoteEpk: 'legacy-local',
      sessionName: 'Legacy',
      relayUrl: 'https://relay.example.test',
      pairedAt: '2026-08-01T00:00:00Z',
    );
    final legacy = _FakeSecureStorage(<String, String>{
      'dev.remotepi.peers_index': jsonEncode(<String>[local.remoteEpk]),
      'dev.remotepi.peers:${local.remoteEpk}': jsonEncode(local.toJson()),
    });
    final fixture = await _fixture(
      owner,
      relay: () => 'https://relay.example.test',
      legacy: legacy,
    );
    fixture.adapter.enqueue(
      'GET',
      '/mesh/${fixture.ownerHash}',
      const _Reply(404, ''),
    );
    fixture.adapter.enqueue(
      'POST',
      '/mesh/${fixture.ownerHash}',
      const _Reply(200, '{"version":1,"updated_at":1}'),
    );

    expect(await fixture.service.synchronize(), isTrue);
    expect(await fixture.storage.listPeers(), <PeerRecord>[local]);
    expect(fixture.service.lastVersion, 1);
  });

  test('offline enrollment survives restart and drains on reconnect', () async {
    final owner = await _newOwner();
    final database = AppDatabase.memory();
    addTearDown(database.dispose);
    final first = await _fixture(
      owner,
      relay: () => 'https://relay.example.test',
      database: database,
    );
    await first.storage.savePeer(_gammaPeer, intent: PeerSaveIntent.enroll);
    first.service.dispose();
    first.bridge.dispose();

    final restarted = await _fixture(
      owner,
      relay: () => 'https://relay.example.test',
      database: database,
    );
    restarted.adapter.enqueue(
      'GET',
      '/mesh/${restarted.ownerHash}',
      const _Reply(404, ''),
    );
    restarted.adapter.enqueue(
      'POST',
      '/mesh/${restarted.ownerHash}',
      const _Reply(200, '{"version":1,"updated_at":1}'),
    );

    expect(await restarted.service.synchronize(), isTrue);
    final posted = restarted.adapter.requests.where((r) => r.method == 'POST').single;
    expect(_postedBlob(posted).members.map((m) => m.remoteEpk), <String>['gamma']);
    expect(restarted.storage.pendingMembershipOperationCount, 0);
  });

  test('conflict rebases enrollment only and does not resurrect unrelated revocation', () async {
    final owner = await _newOwner();
    final fixture = await _fixture(
      owner,
      relay: () => 'https://relay.example.test',
    );
    fixture.adapter.enqueue(
      'GET',
      '/mesh/${fixture.ownerHash}',
      _Reply(200, await _snapshotBody(owner, 5, const <MeshMember>[_alpha, _beta])),
    );
    expect(await fixture.service.synchronize(), isTrue);
    await fixture.storage.savePeer(_gammaPeer, intent: PeerSaveIntent.enroll);

    fixture.adapter.enqueue(
      'POST',
      '/mesh/${fixture.ownerHash}',
      const _Reply(409, ''),
    );
    fixture.adapter.enqueue(
      'GET',
      '/mesh/${fixture.ownerHash}',
      _Reply(200, await _snapshotBody(owner, 6, const <MeshMember>[_alpha])),
    );
    fixture.adapter.enqueue(
      'POST',
      '/mesh/${fixture.ownerHash}',
      const _Reply(200, '{"version":7,"updated_at":7}'),
    );

    expect(await fixture.service.drainPending(), isTrue);
    final posts = fixture.adapter.requests.where((request) => request.method == 'POST').toList();
    expect(_postedBlob(posts[0]).members.map((m) => m.remoteEpk).toSet(),
        <String>{'alpha', 'beta', 'gamma'});
    expect(_postedBlob(posts[1]).members.map((m) => m.remoteEpk).toSet(),
        <String>{'alpha', 'gamma'});
    expect((await fixture.storage.listPeers()).map((p) => p.remoteEpk).toSet(),
        <String>{'alpha', 'gamma'});
    expect(fixture.storage.pendingMembershipOperationCount, 0);
  });

  test('rename written during publication survives captured-operation ACK', () async {
    final owner = await _newOwner();
    final fixture = await _fixture(
      owner,
      relay: () => 'https://relay.example.test',
    );
    fixture.adapter.enqueue(
      'GET',
      '/mesh/${fixture.ownerHash}',
      _Reply(200, await _snapshotBody(owner, 1, const <MeshMember>[_alpha])),
    );
    await fixture.service.synchronize();
    final current = (await fixture.storage.listPeers()).single;
    await fixture.storage.savePeer(
      current.copyWith(nickname: 'First rename'),
      intent: PeerSaveIntent.nickname,
    );

    final releaseFirst = Completer<void>();
    final firstSeen = Completer<void>();
    fixture.adapter.enqueue(
      'POST',
      '/mesh/${fixture.ownerHash}',
      _Reply(200, '{"version":2,"updated_at":2}',
          gate: releaseFirst.future, seen: firstSeen),
    );
    fixture.adapter.enqueue(
      'POST',
      '/mesh/${fixture.ownerHash}',
      const _Reply(200, '{"version":3,"updated_at":3}'),
    );

    final draining = fixture.service.drainPending();
    await firstSeen.future;
    await fixture.storage.savePeer(
      current.copyWith(nickname: 'Newest rename'),
      intent: PeerSaveIntent.nickname,
    );
    releaseFirst.complete();

    expect(await draining, isTrue);
    final posts = fixture.adapter.requests.where((request) => request.method == 'POST').toList();
    expect(_postedBlob(posts[0]).members.single.nickname, 'First rename');
    expect(_postedBlob(posts[1]).members.single.nickname, 'Newest rename');
    expect(fixture.storage.pendingMembershipOperationCount, 0);
    expect((await fixture.storage.listPeers()).single.nickname, 'Newest rename');
  });

  test('explicit revoke can publish empty; stale metadata cannot restore it', () async {
    final owner = await _newOwner();
    final fixture = await _fixture(
      owner,
      relay: () => 'https://relay.example.test',
    );
    fixture.adapter.enqueue(
      'GET',
      '/mesh/${fixture.ownerHash}',
      _Reply(200, await _snapshotBody(owner, 1, const <MeshMember>[_alpha])),
    );
    await fixture.service.synchronize();
    final stale = (await fixture.storage.listPeers()).single;

    await fixture.storage.deletePeer(stale.remoteEpk);
    await fixture.storage.savePeer(
      stale.copyWith(roomId: 'late-room'),
      intent: PeerSaveIntent.localMetadata,
    );
    fixture.adapter.enqueue(
      'POST',
      '/mesh/${fixture.ownerHash}',
      const _Reply(200, '{"version":2,"updated_at":2}'),
    );

    expect(await fixture.service.drainPending(), isTrue);
    final posts = fixture.adapter.requests.where((request) => request.method == 'POST').toList();
    expect(posts, hasLength(1));
    expect(_postedBlob(posts.single).members, isEmpty);
    expect(await fixture.storage.listPeers(), isEmpty);
    expect(await fixture.service.drainPending(), isTrue);
    expect(fixture.adapter.requests.where((request) => request.method == 'POST'), hasLength(1));
  });

  test('newer signed snapshot applies a real remote revocation', () async {
    final owner = await _newOwner();
    final fixture = await _fixture(
      owner,
      relay: () => 'https://relay.example.test',
    );
    fixture.adapter.enqueue(
      'GET',
      '/mesh/${fixture.ownerHash}',
      _Reply(200, await _snapshotBody(owner, 1, const <MeshMember>[_alpha, _beta])),
    );
    await fixture.service.synchronize();
    fixture.adapter.enqueue(
      'GET',
      '/mesh/${fixture.ownerHash}',
      _Reply(200, await _snapshotBody(owner, 2, const <MeshMember>[_alpha])),
    );

    expect(await fixture.service.synchronize(), isTrue);
    expect((await fixture.storage.listPeers()).map((peer) => peer.remoteEpk),
        <String>['alpha']);
  });

  test('remote revocation supersedes an ordinary pending rename', () async {
    final owner = await _newOwner();
    final fixture = await _fixture(
      owner,
      relay: () => 'https://relay.example.test',
    );
    fixture.adapter.enqueue(
      'GET',
      '/mesh/${fixture.ownerHash}',
      _Reply(200, await _snapshotBody(owner, 1, const <MeshMember>[_alpha])),
    );
    await fixture.service.synchronize();
    final alpha = (await fixture.storage.listPeers()).single;
    await fixture.storage.savePeer(
      alpha.copyWith(nickname: 'Pending rename'),
      intent: PeerSaveIntent.nickname,
    );

    fixture.adapter.enqueue(
      'GET',
      '/mesh/${fixture.ownerHash}',
      _Reply(200, await _snapshotBody(owner, 2, const <MeshMember>[])),
    );
    expect(await fixture.service.synchronize(), isTrue);

    expect(await fixture.storage.listPeers(), isEmpty);
    expect(fixture.storage.pendingMembershipOperationCount, 0);
    expect(
      fixture.adapter.requests.where((request) => request.method == 'POST'),
      isEmpty,
    );
  });

  test('invalid signature, wrong owner, and response/blob version mismatch are ignored', () async {
    final owner = await _newOwner();
    final other = await _newOwner();
    final fixture = await _fixture(
      owner,
      relay: () => 'https://relay.example.test',
    );

    fixture.adapter.enqueue(
      'GET',
      '/mesh/${fixture.ownerHash}',
      _Reply(
        200,
        await _snapshotBody(
          owner,
          1,
          const <MeshMember>[_alpha],
          corruptSignature: true,
        ),
      ),
    );
    expect(await fixture.service.synchronize(), isFalse);

    fixture.adapter.enqueue(
      'GET',
      '/mesh/${fixture.ownerHash}',
      _Reply(200, await _snapshotBody(other, 1, const <MeshMember>[_alpha])),
    );
    expect(await fixture.service.synchronize(), isFalse);

    fixture.adapter.enqueue(
      'GET',
      '/mesh/${fixture.ownerHash}',
      _Reply(
        200,
        await _snapshotBody(
          owner,
          1,
          const <MeshMember>[_alpha],
          responseVersion: 2,
        ),
      ),
    );
    expect(await fixture.service.synchronize(), isFalse);
    expect(await fixture.storage.listPeers(), isEmpty);
    expect(fixture.service.lastVersion, 0);
  });

  test('mismatched publish response version cannot acknowledge intent',
      () async {
    final owner = await _newOwner();
    final fixture = await _fixture(
      owner,
      relay: () => 'https://relay.example.test',
    );
    await fixture.storage.savePeer(
      _gammaPeer,
      intent: PeerSaveIntent.enroll,
    );
    fixture.adapter.enqueue(
      'GET',
      '/mesh/${fixture.ownerHash}',
      const _Reply(404, ''),
    );
    fixture.adapter.enqueue(
      'POST',
      '/mesh/${fixture.ownerHash}',
      const _Reply(200, '{"version":2,"updated_at":2}'),
    );

    expect(await fixture.service.synchronize(), isFalse);
    expect(fixture.storage.pendingMembershipOperationCount, 1);
    expect(fixture.service.lastVersion, 0);
    expect(await fixture.storage.loadPeer(_gammaPeer.remoteEpk), _gammaPeer);
  });

  test('corrupt durable snapshot is never re-signed and is recoverable',
      () async {
    final owner = await _newOwner();
    final fixture = await _fixture(
      owner,
      relay: () => 'https://relay.example.test',
    );
    fixture.adapter.enqueue(
      'GET',
      '/mesh/${fixture.ownerHash}',
      _Reply(200, await _snapshotBody(owner, 1, const <MeshMember>[_alpha])),
    );
    expect(await fixture.service.synchronize(), isTrue);

    final forgedBlob = MeshBlob(
      version: 1,
      issuedAt: 999,
      ownerPk: owner.ownerPk,
      members: const <MeshMember>[_beta],
    ).toCanonicalBytes();
    fixture.database.db.execute(
      '''
        UPDATE mesh_sync_state
        SET envelope_blob = ?
      ''',
      <Object?>[forgedBlob],
    );
    await fixture.storage.savePeer(
      _gammaPeer,
      intent: PeerSaveIntent.enroll,
    );

    fixture.adapter.enqueue(
      'GET',
      '/mesh/${fixture.ownerHash}',
      const _Reply(500, ''),
    );
    expect(await fixture.service.synchronize(), isFalse);
    expect(
      fixture.service.lastProblem,
      MeshSyncProblem.corruptStoredSnapshot,
    );
    expect(
      fixture.adapter.requests.where((request) => request.method == 'POST'),
      isEmpty,
    );
    expect(fixture.storage.pendingMembershipOperationCount, 1);
    expect(
      (await fixture.storage.listPeers()).map((peer) => peer.remoteEpk),
      <String>['alpha', 'gamma'],
    );

    fixture.adapter.enqueue(
      'GET',
      '/mesh/${fixture.ownerHash}',
      _Reply(200, await _snapshotBody(owner, 1, const <MeshMember>[_alpha])),
    );
    fixture.adapter.enqueue(
      'POST',
      '/mesh/${fixture.ownerHash}',
      const _Reply(200, '{"version":2,"updated_at":2}'),
    );
    expect(await fixture.service.synchronize(), isTrue);
    expect(fixture.service.lastProblem, isNull);
    expect(fixture.storage.pendingMembershipOperationCount, 0);
  });

  test('out-of-order signed snapshot cannot replace newer durable state', () async {
    final owner = await _newOwner();
    final fixture = await _fixture(
      owner,
      relay: () => 'https://relay.example.test',
    );
    fixture.adapter.enqueue(
      'GET',
      '/mesh/${fixture.ownerHash}',
      _Reply(200, await _snapshotBody(owner, 3, const <MeshMember>[_alpha])),
    );
    expect(await fixture.service.synchronize(), isTrue);

    fixture.adapter.enqueue(
      'GET',
      '/mesh/${fixture.ownerHash}',
      _Reply(200, await _snapshotBody(owner, 2, const <MeshMember>[_beta])),
    );
    expect(await fixture.service.synchronize(), isFalse);
    expect((await fixture.storage.listPeers()).map((peer) => peer.remoteEpk),
        <String>['alpha']);
    expect(fixture.service.lastVersion, 3);
  });

  test('relay change during fetch drops the stale response', () async {
    final owner = await _newOwner();
    var relay = 'https://relay-one.example.test';
    final fixture = await _fixture(owner, relay: () => relay);
    final release = Completer<void>();
    final seen = Completer<void>();
    fixture.adapter.enqueue(
      'GET',
      '/mesh/${fixture.ownerHash}',
      _Reply(
        200,
        await _snapshotBody(owner, 1, const <MeshMember>[_alpha]),
        gate: release.future,
        seen: seen,
      ),
    );

    final syncing = fixture.service.synchronize();
    await seen.future;
    relay = 'https://relay-two.example.test';
    await fixture.storage.initialize(ownerPk: owner.ownerPk, relayUrl: relay);
    release.complete();

    expect(await syncing, isFalse);
    expect(await fixture.storage.listPeers(), isEmpty);
    expect(fixture.service.lastVersion, 0);
  });

  test('owner change during fetch invalidates before wipe and drops stale response', () async {
    final owner = await _newOwner();
    final other = await _newOwner();
    final fixture = await _fixture(
      owner,
      relay: () => 'https://relay.example.test',
    );
    final reset = Completer<void>();
    fixture.bridge.startWatching(
      onBeforeReset: () async {},
      onReset: () async => reset.complete(),
    );
    final release = Completer<void>();
    final seen = Completer<void>();
    fixture.adapter.enqueue(
      'GET',
      '/mesh/${fixture.ownerHash}',
      _Reply(
        200,
        await _snapshotBody(owner, 1, const <MeshMember>[_alpha]),
        gate: release.future,
        seen: seen,
      ),
    );

    final syncing = fixture.service.synchronize();
    await seen.future;
    await fixture.identityStore.save(other.identity);
    await reset.future;
    release.complete();

    expect(await syncing, isFalse);
    await fixture.storage.initialize(
      ownerPk: other.ownerPk,
      relayUrl: 'https://relay.example.test',
    );
    expect(await fixture.storage.listPeers(), isEmpty);
  });

  test('concurrent synchronizations are serialized', () async {
    final owner = await _newOwner();
    final fixture = await _fixture(
      owner,
      relay: () => 'https://relay.example.test',
    );
    final release = Completer<void>();
    final firstSeen = Completer<void>();
    fixture.adapter.enqueue(
      'GET',
      '/mesh/${fixture.ownerHash}',
      _Reply(404, '', gate: release.future, seen: firstSeen),
    );
    fixture.adapter.enqueue(
      'GET',
      '/mesh/${fixture.ownerHash}',
      const _Reply(404, ''),
    );

    final first = fixture.service.synchronize();
    await firstSeen.future;
    final second = fixture.service.synchronize();
    await pumpEventQueue();
    expect(fixture.adapter.requests, hasLength(1));
    release.complete();

    expect(await first, isTrue);
    expect(await second, isTrue);
    expect(fixture.adapter.maxActive, 1);
  });
}
