// Tests for the PairingStorage surface that survives plan 23 (W2A):
// PeerRecord (de)serialization, nickname/roomId edges, and the new
// `wipeAll()` helper that the OwnerIdentityBridge calls on sync-reset.

import 'dart:convert';
import 'package:app/pairing/storage.dart';
import 'package:app/protocol/protocol.dart' show PiHarness;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeSecureStorage implements FlutterSecureStorage {
  final Map<String, String> _store = {};

  @override
  Future<String?> read({
    required String key,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async => _store[key];

  @override
  Future<void> write({
    required String key,
    required String? value,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    if (value == null) {
      _store.remove(key);
    } else {
      _store[key] = value;
    }
  }

  @override
  Future<void> delete({
    required String key,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async => _store.remove(key);

  @override
  Future<Map<String, String>> readAll({
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async => Map.from(_store);

  @override
  Future<void> deleteAll({
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async => _store.clear();

  @override
  Future<bool> containsKey({
    required String key,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async => _store.containsKey(key);

  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}
class _EmptyReadAllFakeSecureStorage implements FlutterSecureStorage {
  final Map<String, String> _store = {};

  @override
  Future<String?> read({
    required String key,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async => _store[key];

  @override
  Future<void> write({
    required String key,
    required String? value,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    if (value == null) {
      _store.remove(key);
    } else {
      _store[key] = value;
    }
  }

  @override
  Future<void> delete({
    required String key,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async => _store.remove(key);

  @override
  Future<Map<String, String>> readAll({
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async => <String, String>{};

  @override
  Future<void> deleteAll({
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async => _store.clear();

  @override
  Future<bool> containsKey({
    required String key,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async => _store.containsKey(key);

  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}
class _FailingWriteSecureStorage extends _EmptyReadAllFakeSecureStorage {
  bool failNextWrite = false;
  bool failIndexWrite = false;
  @override
  Future<void> write({
    required String key,
    required String? value,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    if (failNextWrite || (failIndexWrite && key == 'dev.remotepi.peers_index')) {
      throw Exception('Simulated storage write failure');
    }
    await super.write(
      key: key,
      value: value,
      iOptions: iOptions,
      aOptions: aOptions,
      lOptions: lOptions,
      webOptions: webOptions,
      mOptions: mOptions,
      wOptions: wOptions,
    );
  }
}
class _InterceptingSecureStorage implements FlutterSecureStorage {
  final FlutterSecureStorage _delegate;
  final String? Function(String key)? onRead;

  _InterceptingSecureStorage(this._delegate, {this.onRead});

  @override
  Future<String?> read({
    required String key,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    final override = onRead?.call(key);
    if (override != null) return override;
    return _delegate.read(
      key: key,
      iOptions: iOptions,
      aOptions: aOptions,
      lOptions: lOptions,
      webOptions: webOptions,
      mOptions: mOptions,
      wOptions: wOptions,
    );
  }

  @override
  Future<void> write({
    required String key,
    required String? value,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) => _delegate.write(
    key: key,
    value: value,
    iOptions: iOptions,
    aOptions: aOptions,
    lOptions: lOptions,
    webOptions: webOptions,
    mOptions: mOptions,
    wOptions: wOptions,
  );

  @override
  Future<void> delete({
    required String key,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) => _delegate.delete(
    key: key,
    iOptions: iOptions,
    aOptions: aOptions,
    lOptions: lOptions,
    webOptions: webOptions,
    mOptions: mOptions,
    wOptions: wOptions,
  );

  @override
  Future<Map<String, String>> readAll({
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) => _delegate.readAll(
    iOptions: iOptions,
    aOptions: aOptions,
    lOptions: lOptions,
    webOptions: webOptions,
    mOptions: mOptions,
    wOptions: wOptions,
  );

  @override
  Future<void> deleteAll({
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) => _delegate.deleteAll(
    iOptions: iOptions,
    aOptions: aOptions,
    lOptions: lOptions,
    webOptions: webOptions,
    mOptions: mOptions,
    wOptions: wOptions,
  );

  @override
  Future<bool> containsKey({
    required String key,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) => _delegate.containsKey(
    key: key,
    iOptions: iOptions,
    aOptions: aOptions,
    lOptions: lOptions,
    webOptions: webOptions,
    mOptions: mOptions,
    wOptions: wOptions,
  );

  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

void main() {
  group('PeerRecord — minimal post-rollback shape', () {
    test('serializes and deserializes the 4 retained fields', () {
      const record = PeerRecord(
        remoteEpk: 'pk_ed25519',
        sessionName: 'test',
        relayUrl: 'ws://localhost',
        pairedAt: '2026-01-01T00:00:00Z',
      );

      final json = record.toJson();
      expect(json['remote_epk'], 'pk_ed25519');
      expect(json['session_name'], 'test');
      expect(json['relay_url'], 'ws://localhost');
      expect(json['paired_at'], '2026-01-01T00:00:00Z');
      expect(json['nickname'], isNull);

      final restored = PeerRecord.fromJson(json);
      expect(restored.remoteEpk, 'pk_ed25519');
      expect(restored.sessionName, 'test');
      expect(restored.nickname, isNull);
    });

    test('nickname round-trips through toJson/fromJson', () {
      const record = PeerRecord(
        remoteEpk: 'pk1',
        sessionName: 'remote_pi · main',
        relayUrl: 'ws://x',
        pairedAt: '2026-01-01T00:00:00Z',
        nickname: 'Mac de casa',
      );
      final restored = PeerRecord.fromJson(record.toJson());
      expect(restored.nickname, 'Mac de casa');
      expect(restored.sessionName, 'remote_pi · main');
    });

    test('legacy record without nickname field → fromJson returns null', () {
      final restored = PeerRecord.fromJson({
        'remote_epk': 'pk1',
        'session_name': 'name',
        'relay_url': 'ws://x',
        'paired_at': '2026-01-01T00:00:00Z',
      });
      expect(restored.nickname, isNull);
    });

    test('copyWith(nickname: null) clears the nickname', () {
      const record = PeerRecord(
        remoteEpk: 'pk1',
        sessionName: 'n',
        relayUrl: 'ws://x',
        pairedAt: '2026-01-01T00:00:00Z',
        nickname: 'old',
      );
      final cleared = record.copyWith(nickname: null);
      expect(cleared.nickname, isNull);

      final preserved = record.copyWith(sessionName: 'new');
      expect(preserved.nickname, 'old');
      expect(preserved.sessionName, 'new');
    });

    test('harness round-trips through toJson/fromJson (plan/27 Wave A)', () {
      const record = PeerRecord(
        remoteEpk: 'pk1',
        sessionName: 'name',
        relayUrl: 'ws://x',
        pairedAt: '2026-01-01T00:00:00Z',
        harness: PiHarness(name: 'Pi coding agent', version: '0.4.2'),
      );
      final json = record.toJson();
      expect(json['harness'], {'name': 'Pi coding agent', 'version': '0.4.2'});
      final restored = PeerRecord.fromJson(json);
      expect(restored.harness, isNotNull);
      expect(restored.harness!.name, 'Pi coding agent');
      expect(restored.harness!.version, '0.4.2');
    });

    test('legacy record without harness field → fromJson keeps null', () {
      final restored = PeerRecord.fromJson({
        'remote_epk': 'pk1',
        'session_name': 'name',
        'relay_url': 'ws://x',
        'paired_at': '2026-01-01T00:00:00Z',
      });
      expect(restored.harness, isNull);
    });

    test('copyWith(harness: ...) updates while preserving other fields', () {
      const record = PeerRecord(
        remoteEpk: 'pk1',
        sessionName: 'n',
        relayUrl: 'ws://x',
        pairedAt: '2026-01-01T00:00:00Z',
        nickname: 'Macbook',
        harness: PiHarness(name: 'Pi coding agent', version: '0.4.0'),
      );
      final updated = record.copyWith(
        harness: const PiHarness(name: 'Claude Code', version: '0.7.1'),
      );
      expect(updated.harness!.name, 'Claude Code');
      expect(updated.nickname, 'Macbook');
      // Sentinel default: omitting harness preserves it.
      final preserved = record.copyWith(nickname: 'mac');
      expect(preserved.harness!.version, '0.4.0');
    });

    test('list/save/load round-trips through fake storage', () async {
      final storage = PairingStorage(_FakeSecureStorage());
      const r = PeerRecord(
        remoteEpk: 'epk1',
        sessionName: 'sess',
        relayUrl: 'ws://x',
        pairedAt: '2026-01-01T00:00:00Z',
      );
      await storage.savePeer(r);

      final loaded = await storage.loadPeer('epk1');
      expect(loaded?.sessionName, 'sess');

      final all = await storage.listPeers();
      expect(all, hasLength(1));

      await storage.deletePeer('epk1');
      expect(await storage.listPeers(), isEmpty);
    });
  });

  group('PairingStorage.wipeAll (plan 23 sync-reset)', () {
    test('clears every peer + every persisted rooms entry', () async {
      final fake = _FakeSecureStorage();
      final storage = PairingStorage(fake);
      const a = PeerRecord(
        remoteEpk: 'epk-a',
        sessionName: 'A',
        relayUrl: 'ws://x',
        pairedAt: '2026-01-01T00:00:00Z',
      );
      const b = PeerRecord(
        remoteEpk: 'epk-b',
        sessionName: 'B',
        relayUrl: 'ws://x',
        pairedAt: '2026-01-01T00:00:00Z',
      );
      await storage.savePeer(a);
      await storage.savePeer(b);
      await storage.saveRooms('epk-a', const [
        PersistedRoom(roomId: 'main', startedAt: 1700000000000),
      ]);

      expect(await storage.listPeers(), hasLength(2));
      expect(await storage.loadRooms('epk-a'), hasLength(1));

      await storage.wipeAll();

      expect(await storage.listPeers(), isEmpty);
      expect(await storage.loadRooms('epk-a'), isEmpty);
    });

    test('notifies listeners exactly once', () async {
      final storage = PairingStorage(_FakeSecureStorage());
      var notifications = 0;
      storage.addListener(() => notifications++);

      await storage.wipeAll();

      expect(notifications, 1);
    });
  });

  group('PairingStorage — Android readAll resilience & durable index', () {
    test('savePeer then listPeers survives when readAll returns empty map', () async {
      final fake = _EmptyReadAllFakeSecureStorage();
      final storage = PairingStorage(fake);
      const r = PeerRecord(
        remoteEpk: 'epk-test',
        sessionName: 'Mac',
        relayUrl: 'ws://relay',
        pairedAt: '2026-09-29T00:00:00Z',
      );
      await storage.savePeer(r);

      final all = await storage.listPeers();
      expect(all, hasLength(1));
      expect(all.first.remoteEpk, 'epk-test');
    });

    test('cold-start listPeers loads peers via durable index when readAll returns empty map', () async {
      final fake = _EmptyReadAllFakeSecureStorage();
      final storage1 = PairingStorage(fake);
      const r = PeerRecord(
        remoteEpk: 'epk-test',
        sessionName: 'Mac',
        relayUrl: 'ws://relay',
        pairedAt: '2026-09-29T00:00:00Z',
      );
      await storage1.savePeer(r);

      // Simulate app restart: brand-new PairingStorage instance on same underlying store
      final storage2 = PairingStorage(fake);
      final all = await storage2.listPeers();
      expect(all, hasLength(1));
      expect(all.first.remoteEpk, 'epk-test');
    });

    test('migrates existing legacy keys into durable index when readAll succeeds', () async {
      final fake = _FakeSecureStorage();
      fake._store['dev.remotepi.peers:epk-legacy'] = jsonEncode(const PeerRecord(
        remoteEpk: 'epk-legacy',
        sessionName: 'Legacy PC',
        relayUrl: 'ws://relay',
        pairedAt: '2026-09-29T00:00:00Z',
      ).toJson());
      expect(fake._store.containsKey('dev.remotepi.peers_index'), isFalse);

      final storage = PairingStorage(fake);
      final all = await storage.listPeers();
      expect(all, hasLength(1));
      expect(all.first.remoteEpk, 'epk-legacy');
      expect(fake._store.containsKey('dev.remotepi.peers_index'), isTrue);
    });

    test('deletePeer updates durable index even if readAll returns empty', () async {
      final fake = _EmptyReadAllFakeSecureStorage();
      final storage = PairingStorage(fake);
      const r1 = PeerRecord(
        remoteEpk: 'epk-1',
        sessionName: 'PC 1',
        relayUrl: 'ws://relay',
        pairedAt: '2026-09-29T00:00:00Z',
      );
      const r2 = PeerRecord(
        remoteEpk: 'epk-2',
        sessionName: 'PC 2',
        relayUrl: 'ws://relay',
        pairedAt: '2026-09-29T00:00:00Z',
      );
      await storage.savePeer(r1);
      await storage.savePeer(r2);
      expect(await storage.listPeers(), hasLength(2));

      await storage.deletePeer('epk-1');
      expect(await storage.listPeers(), hasLength(1));

      final restarted = PairingStorage(fake);
      final list = await restarted.listPeers();
      expect(list, hasLength(1));
      expect(list.first.remoteEpk, 'epk-2');
    });

    test('cold-start savePeer hydrates existing peers before persisting index (old + new preserved)', () async {
      final fake = _EmptyReadAllFakeSecureStorage();
      final s1 = PairingStorage(fake);
      await s1.savePeer(const PeerRecord(
        remoteEpk: 'epk-old',
        sessionName: 'Old Mac',
        relayUrl: 'ws://relay',
        pairedAt: '2026-09-20T00:00:00Z',
      ));

      // Cold start: brand-new instance, immediately call savePeer WITHOUT calling listPeers first
      final s2 = PairingStorage(fake);
      await s2.savePeer(const PeerRecord(
        remoteEpk: 'epk-new',
        sessionName: 'New Mac',
        relayUrl: 'ws://relay',
        pairedAt: '2026-09-29T00:00:00Z',
      ));

      final peers = await s2.listPeers();
      final epks = peers.map((p) => p.remoteEpk).toSet();
      expect(epks, contains('epk-old'));
      expect(epks, contains('epk-new'));
      expect(peers, hasLength(2));
    });

    test('cold-start deletePeer hydrates existing peers before rewriting index', () async {
      final fake = _EmptyReadAllFakeSecureStorage();
      final s1 = PairingStorage(fake);
      await s1.savePeer(const PeerRecord(
        remoteEpk: 'epk-1',
        sessionName: 'Mac 1',
        relayUrl: 'ws://relay',
        pairedAt: '2026-09-20T00:00:00Z',
      ));
      await s1.savePeer(const PeerRecord(
        remoteEpk: 'epk-2',
        sessionName: 'Mac 2',
        relayUrl: 'ws://relay',
        pairedAt: '2026-09-20T00:00:00Z',
      ));

      // Cold start: immediately call deletePeer WITHOUT listPeers first
      final s2 = PairingStorage(fake);
      await s2.deletePeer('epk-1');

      final peers = await s2.listPeers();
      expect(peers, hasLength(1));
      expect(peers.first.remoteEpk, 'epk-2');
    });

    test('failed storage write does not leave phantom record in cache', () async {
      final fake = _FailingWriteSecureStorage();
      final storage = PairingStorage(fake);

      fake.failNextWrite = true;
      expect(
        () => storage.savePeer(const PeerRecord(
          remoteEpk: 'epk-fail',
          sessionName: 'Fail',
          relayUrl: 'ws://relay',
          pairedAt: '2026-09-29T00:00:00Z',
        )),
        throwsA(isA<Exception>()),
      );

      final peers = await storage.listPeers();
      expect(peers.where((p) => p.remoteEpk == 'epk-fail'), isEmpty);
    });

    test('wipeAll deletes individual indexed keys even if readAll returns empty', () async {
      final fake = _EmptyReadAllFakeSecureStorage();
      final storage = PairingStorage(fake);
      await storage.savePeer(const PeerRecord(
        remoteEpk: 'epk-target',
        sessionName: 'Target',
        relayUrl: 'ws://relay',
        pairedAt: '2026-09-29T00:00:00Z',
      ));
      await storage.saveRooms('epk-target', const [
        PersistedRoom(roomId: 'main', startedAt: 1700000000000),
      ]);

      expect(await fake.read(key: 'dev.remotepi.peers:epk-target'), isNotNull);
      expect(await fake.read(key: 'dev.remotepi.rooms:epk-target'), isNotNull);

      await storage.wipeAll();

      expect(await fake.read(key: 'dev.remotepi.peers:epk-target'), isNull);
      expect(await fake.read(key: 'dev.remotepi.rooms:epk-target'), isNull);
      expect(await storage.listPeers(), isEmpty);
    });

    test('transient per-key read failure preserves unresolved epk in index on save, and later recovery retains both', () async {
      final fake = _EmptyReadAllFakeSecureStorage();
      final s1 = PairingStorage(fake);
      await s1.savePeer(const PeerRecord(
        remoteEpk: 'epk-a',
        sessionName: 'PC A',
        relayUrl: 'ws://relay',
        pairedAt: '2026-09-20T00:00:00Z',
      ));
      await s1.savePeer(const PeerRecord(
        remoteEpk: 'epk-b',
        sessionName: 'PC B',
        relayUrl: 'ws://relay',
        pairedAt: '2026-09-20T00:00:00Z',
      ));

      var failEpkB = true;
      final interceptedFake = _InterceptingSecureStorage(fake, onRead: (key) {
        if (failEpkB && key == 'dev.remotepi.peers:epk-b') {
          throw Exception('Transient read failure');
        }
        return null;
      });

      final s2 = PairingStorage(interceptedFake);
      await s2.savePeer(const PeerRecord(
        remoteEpk: 'epk-c',
        sessionName: 'PC C',
        relayUrl: 'ws://relay',
        pairedAt: '2026-09-29T00:00:00Z',
      ));

      final rawIndex = await fake.read(key: 'dev.remotepi.peers_index');
      expect(rawIndex, isNotNull);
      final indexedEpks = (jsonDecode(rawIndex!) as List<dynamic>).cast<String>();
      expect(indexedEpks, contains('epk-a'));
      expect(indexedEpks, contains('epk-c'));
      expect(indexedEpks, contains('epk-b'));

      failEpkB = false;
      final all = await s2.listPeers();
      final allEpks = all.map((p) => p.remoteEpk).toSet();
      expect(allEpks, contains('epk-a'));
      expect(allEpks, contains('epk-b'));
      expect(allEpks, contains('epk-c'));
      expect(all, hasLength(3));
    });

    test('fails closed for mutations when index key is unreadable', () async {
      final fake = _EmptyReadAllFakeSecureStorage();
      final intercepted = _InterceptingSecureStorage(fake, onRead: (key) {
        if (key == 'dev.remotepi.peers_index') {
          throw Exception('Keystore locked or corrupted index');
        }
        return null;
      });

      final storage = PairingStorage(intercepted);
      expect(
        () => storage.savePeer(const PeerRecord(
          remoteEpk: 'epk-new',
          sessionName: 'New',
          relayUrl: 'ws://relay',
          pairedAt: '2026-09-29T00:00:00Z',
        )),
        throwsA(isA<StateError>()),
      );
    });

    test('failed index write propagates exception and does not emit successful save', () async {
      final fake = _FailingWriteSecureStorage();
      final storage = PairingStorage(fake);
      var notifications = 0;
      storage.addListener(() => notifications++);

      fake.failIndexWrite = true;
      expect(
        () => storage.savePeer(const PeerRecord(
          remoteEpk: 'epk-fail-idx',
          sessionName: 'FailIdx',
          relayUrl: 'ws://relay',
          pairedAt: '2026-09-29T00:00:00Z',
        )),
        throwsA(isA<Exception>()),
      );

      expect(notifications, 0);
      final peers = await storage.listPeers();
      expect(peers.where((p) => p.remoteEpk == 'epk-fail-idx'), isEmpty);
    });
  });
}
