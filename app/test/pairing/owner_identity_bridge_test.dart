import 'dart:async';
import 'dart:typed_data';

import 'package:app/data/local/app_database.dart';
import 'package:app/pairing/owner_identity_bridge.dart';
import 'package:app/pairing/storage.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_pi_identity/remote_pi_identity.dart';

class _EmptySecureStorage implements FlutterSecureStorage {
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
      null;

  @override
  Future<Map<String, String>> readAll({
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async =>
      <String, String>{};

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<OwnerIdentity> _identity(int seedByte) async {
  final seed = Uint8List(32)..fillRange(0, 32, seedByte);
  final keyPair = await Ed25519().newKeyPairFromSeed(seed);
  final public = await keyPair.extractPublicKey();
  return OwnerIdentity(
    ownerPk: Uint8List.fromList(public.bytes),
    ownerSk: seed,
  );
}

Future<PairingStorage> _storage(AppDatabase database, OwnerIdentity owner) async {
  final storage = PairingStorage(database, legacyStore: _EmptySecureStorage());
  await storage.initialize(
    ownerPk: owner.ownerPk,
    relayUrl: 'https://relay.example.test',
  );
  return storage;
}

void main() {
  test('boot reuses native-store identity and requireKeyPair signs with it', () async {
    final identity = await _identity(1);
    final database = AppDatabase.memory();
    addTearDown(database.dispose);
    final storage = await _storage(database, identity);
    final nativeStore = InMemoryOwnerIdentityStore(initial: identity);
    addTearDown(nativeStore.dispose);
    final bridge = OwnerIdentityBridge(nativeStore, storage);
    addTearDown(bridge.dispose);

    final result = await bridge.boot();
    expect(result, isA<IdentityReady>());
    expect((result as IdentityReady).generated, isFalse);
    expect(bridge.currentOwnerPk, orderedEquals(identity.ownerPk));

    final message = <int>[1, 2, 3];
    final signature = await Ed25519().sign(
      message,
      keyPair: await bridge.requireKeyPair(),
    );
    expect(
      await Ed25519().verify(
        message,
        signature: Signature(
          signature.bytes,
          publicKey: SimplePublicKey(identity.ownerPk, type: KeyPairType.ed25519),
        ),
      ),
      isTrue,
    );
  });

  test('same-owner watch event neither wipes storage nor resets runtime', () async {
    final identity = await _identity(2);
    final database = AppDatabase.memory();
    addTearDown(database.dispose);
    final storage = await _storage(database, identity);
    await storage.savePeer(
      const PeerRecord(
        remoteEpk: 'precious',
        sessionName: 'PC',
        relayUrl: 'https://relay.example.test',
        pairedAt: '2026-09-01T00:00:00Z',
      ),
      intent: PeerSaveIntent.enroll,
    );
    final nativeStore = InMemoryOwnerIdentityStore(initial: identity);
    addTearDown(nativeStore.dispose);
    final bridge = OwnerIdentityBridge(nativeStore, storage);
    addTearDown(bridge.dispose);
    await bridge.boot();
    var beforeCalls = 0;
    var resetCalls = 0;
    bridge.startWatching(
      onBeforeReset: () async => beforeCalls++,
      onReset: () async => resetCalls++,
    );

    await nativeStore.save(identity);
    await pumpEventQueue();

    expect(beforeCalls, 0);
    expect(resetCalls, 0);
    expect(await storage.loadPeer('precious'), isNotNull);
  });

  test('different owner invalidates runtime before transactional wipe', () async {
    final first = await _identity(3);
    final second = await _identity(4);
    final database = AppDatabase.memory();
    addTearDown(database.dispose);
    final storage = await _storage(database, first);
    await storage.savePeer(
      const PeerRecord(
        remoteEpk: 'old-peer',
        sessionName: 'PC',
        relayUrl: 'https://relay.example.test',
        pairedAt: '2026-09-01T00:00:00Z',
      ),
      intent: PeerSaveIntent.enroll,
    );
    final nativeStore = InMemoryOwnerIdentityStore(initial: first);
    addTearDown(nativeStore.dispose);
    final bridge = OwnerIdentityBridge(nativeStore, storage);
    addTearDown(bridge.dispose);
    await bridge.boot();

    final resetDone = Completer<void>();
    final order = <String>[];
    bridge.startWatching(
      onBeforeReset: () async {
        order.add('invalidate');
        expect(await storage.loadPeer('old-peer'), isNotNull);
      },
      onReset: () async {
        order.add('restart');
        expect(storage.isInitialized, isFalse);
        await storage.initialize(
          ownerPk: second.ownerPk,
          relayUrl: 'https://relay.example.test',
        );
        expect(await storage.listPeers(), isEmpty);
        resetDone.complete();
      },
    );

    await nativeStore.save(second);
    await resetDone.future;

    expect(order, <String>['invalidate', 'restart']);
    expect(bridge.currentOwnerPk, orderedEquals(second.ownerPk));
    expect(database.db.select('SELECT * FROM membership_operations'), isEmpty);
    expect(database.db.select('SELECT * FROM mesh_sync_state'), isEmpty);
  });

  test('watch event received before boot is adopted without wiping cache', () async {
    final identity = await _identity(5);
    final database = AppDatabase.memory();
    addTearDown(database.dispose);
    final storage = await _storage(database, identity);
    await storage.savePeer(
      const PeerRecord(
        remoteEpk: 'stable-peer',
        sessionName: 'PC',
        relayUrl: 'https://relay.example.test',
        pairedAt: '2026-09-01T00:00:00Z',
      ),
      intent: PeerSaveIntent.enroll,
    );
    final nativeStore = InMemoryOwnerIdentityStore();
    addTearDown(nativeStore.dispose);
    final bridge = OwnerIdentityBridge(nativeStore, storage);
    addTearDown(bridge.dispose);
    var resetCalls = 0;
    bridge.startWatching(
      onBeforeReset: () async {},
      onReset: () async => resetCalls++,
    );

    await nativeStore.save(identity);
    await pumpEventQueue();

    expect(bridge.currentOwnerPk, orderedEquals(identity.ownerPk));
    expect(resetCalls, 0);
    expect(await storage.loadPeer('stable-peer'), isNotNull);
  });
}
