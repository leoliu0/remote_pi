import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:app/data/local/app_database.dart';
import 'package:app/pairing/legacy_pairing_migration.dart';
import 'package:app/pairing/storage.dart';
import 'package:app/protocol/protocol.dart' show PiHarness;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeSecureStorage implements FlutterSecureStorage {
  final Map<String, String> values;
  final Set<String> unreadableKeys;
  bool failAllReads;
  bool failReadAll;
  int readCount = 0;

  _FakeSecureStorage({
    Map<String, String>? values,
    Set<String>? unreadableKeys,
    this.failAllReads = false,
    this.failReadAll = false,
  })  : values = values ?? <String, String>{},
        unreadableKeys = unreadableKeys ?? <String>{};

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
    readCount++;
    if (failAllReads || unreadableKeys.contains(key)) {
      throw StateError('secure value is unreadable: $key');
    }
    return values[key];
  }

  @override
  Future<Map<String, String>> readAll({
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    readCount++;
    if (failAllReads || failReadAll) {
      throw StateError('secure inventory is unreadable');
    }
    return Map<String, String>.of(values);
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
  }) async {
    if (value == null) {
      values.remove(key);
    } else {
      values[key] = value;
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
  }) async {
    values.remove(key);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _BlockingFirstIndexReadStorage extends _FakeSecureStorage {
  final Completer<void> firstReadStarted = Completer<void>();
  final Completer<void> releaseFirstRead = Completer<void>();
  bool _blocked = false;

  _BlockingFirstIndexReadStorage({required super.values});

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
    if (key == legacyPeersIndexKey && !_blocked) {
      _blocked = true;
      firstReadStarted.complete();
      await releaseFirstRead.future;
    }
    return super.read(
      key: key,
      iOptions: iOptions,
      aOptions: aOptions,
      lOptions: lOptions,
      webOptions: webOptions,
      mOptions: mOptions,
      wOptions: wOptions,
    );
  }
}

final Uint8List _ownerA = Uint8List.fromList(List<int>.generate(32, (i) => i));
final Uint8List _ownerB = Uint8List.fromList(List<int>.generate(32, (i) => 31 - i));

const _peer = PeerRecord(
  remoteEpk: 'epk-one',
  sessionName: 'workstation',
  relayUrl: 'wss://Relay.Example.test/',
  pairedAt: '2026-09-20T12:00:00Z',
  nickname: 'Desk',
  roomId: 'main',
  harness: PiHarness(name: 'Pi coding agent', version: '0.5.0'),
);

Future<PairingStorage> _storage(
  AppDatabase database, {
  FlutterSecureStorage? legacyStore,
  Uint8List? ownerPk,
  String relayUrl = 'https://relay.example.test',
}) async {
  final storage = PairingStorage(database, legacyStore: legacyStore);
  await storage.initialize(ownerPk: ownerPk ?? _ownerA, relayUrl: relayUrl);
  return storage;
}

void main() {
  group('Pairing records', () {
    test('peer and room JSON retain every rendering and routing field', () {
      expect(PeerRecord.fromJson(_peer.toJson()), _peer);

      const room = PersistedRoom(
        roomId: 'room-1',
        name: 'Agent',
        cwd: '/home/leo/project',
        startedAt: 42,
        localName: 'Release',
        model: 'openai-codex:gpt-5.6-codex',
      );
      final restored = PersistedRoom.fromJson(room.toJson());
      expect(restored.roomId, room.roomId);
      expect(restored.name, room.name);
      expect(restored.cwd, room.cwd);
      expect(restored.startedAt, room.startedAt);
      expect(restored.localName, room.localName);
      expect(restored.model, room.model);
    });
  });

  group('secure-storage legacy import', () {
    test('imports indexed peers and rooms once without deleting old keys', () async {
      final database = AppDatabase.memory();
      addTearDown(database.dispose);
      final legacy = _FakeSecureStorage(
        failReadAll: true,
        values: <String, String>{
          'dev.remotepi.peers_index': jsonEncode(<String>[_peer.remoteEpk]),
          'dev.remotepi.peers:${_peer.remoteEpk}': jsonEncode(_peer.toJson()),
          'dev.remotepi.rooms:${_peer.remoteEpk}': jsonEncode(<Object?>[
            const PersistedRoom(
              roomId: 'main',
              startedAt: 7,
              model: 'anthropic:claude-sonnet-4-5',
            ).toJson(),
          ]),
        },
      );

      final storage = await _storage(database, legacyStore: legacy);
      expect(await storage.listPeers(), <PeerRecord>[_peer]);
      expect((await storage.loadRooms(_peer.remoteEpk)).single.model,
          'anthropic:claude-sonnet-4-5');
      expect(legacy.values['dev.remotepi.peers:${_peer.remoteEpk}'], isNotNull);
      expect(legacy.values['dev.remotepi.rooms:${_peer.remoteEpk}'], isNotNull);

      final imported = database.db.select(
        "SELECT row_count FROM legacy_imports WHERE source = 'pairing.secure_storage'",
      );
      expect(imported.single['row_count'], 2);

      legacy.failAllReads = true;
      final restarted = await _storage(database, legacyStore: legacy);
      expect(await restarted.listPeers(), <PeerRecord>[_peer]);
    });

    test('imports pre-index inventory when enumeration succeeds', () async {
      final database = AppDatabase.memory();
      addTearDown(database.dispose);
      final legacy = _FakeSecureStorage(values: <String, String>{
        'dev.remotepi.peers:${_peer.remoteEpk}': jsonEncode(_peer.toJson()),
      });

      final storage = await _storage(database, legacyStore: legacy);
      expect(await storage.loadPeer(_peer.remoteEpk), _peer);
      expect(legacy.values, contains('dev.remotepi.peers:${_peer.remoteEpk}'));
    });

    test('ignores orphaned pre-index room cache while preserving its source',
        () async {
      const peer = PeerRecord(
        remoteEpk: 'retained-peer',
        sessionName: 'Retained',
        relayUrl: 'https://relay.example.test',
        pairedAt: '2026-08-01T00:00:00Z',
      );
      final legacy = _FakeSecureStorage(values: <String, String>{
        '$legacyPeersService:${peer.remoteEpk}': jsonEncode(peer.toJson()),
        '$legacyRoomsService:${peer.remoteEpk}': jsonEncode(<Object?>[
          const PersistedRoom(roomId: 'main', startedAt: 1).toJson(),
        ]),
        '$legacyRoomsService:already-revoked': jsonEncode(<Object?>[
          const PersistedRoom(roomId: 'stale', startedAt: 2).toJson(),
        ]),
      });
      final database = AppDatabase.memory();
      addTearDown(database.dispose);

      final storage = await _storage(database, legacyStore: legacy);

      expect(await storage.listPeers(), <PeerRecord>[peer]);
      expect(await storage.loadRooms(peer.remoteEpk), hasLength(1));
      expect(
        legacy.values,
        contains('$legacyRoomsService:already-revoked'),
        reason: 'migration never mutates supported legacy source data',
      );
    });

    test('imports legacy peer URL into the selected relay namespace', () async {
      const legacyPeer = PeerRecord(
        remoteEpk: 'legacy-endpoint-peer',
        sessionName: 'Legacy endpoint',
        relayUrl: 'http://relay.example.test',
        pairedAt: '2026-08-01T00:00:00Z',
      );
      final database = AppDatabase.memory();
      addTearDown(database.dispose);
      final legacy = _FakeSecureStorage(values: <String, String>{
        'dev.remotepi.peers_index':
            jsonEncode(<String>[legacyPeer.remoteEpk]),
        'dev.remotepi.peers:${legacyPeer.remoteEpk}':
            jsonEncode(legacyPeer.toJson()),
      });

      final storage = await _storage(
        database,
        legacyStore: legacy,
        relayUrl: 'http://relay.example.test:3000',
      );

      expect(await storage.listPeers(), <PeerRecord>[legacyPeer]);
      expect(
        (await storage.listPeers()).single.relayUrl,
        'http://relay.example.test',
        reason: 'legacy payload is preserved but never used as scope routing',
      );
    });

    test('canonicalizes legacy standard-base64 identity without data loss',
        () async {
      const standard =
          'Bz02uLiwrmQZ0S8qiwtFJAt0KzUvrgepYO/oMQ6yyQE=';
      const urlSafe =
          'Bz02uLiwrmQZ0S8qiwtFJAt0KzUvrgepYO_oMQ6yyQE';
      const legacyPeer = PeerRecord(
        remoteEpk: standard,
        sessionName: 'Legacy PC',
        relayUrl: 'https://relay.example.test',
        pairedAt: '2026-08-01T00:00:00Z',
      );
      final database = AppDatabase.memory();
      addTearDown(database.dispose);
      final legacy = _FakeSecureStorage(values: <String, String>{
        'dev.remotepi.peers_index': jsonEncode(<String>[standard]),
        'dev.remotepi.peers:$standard': jsonEncode(legacyPeer.toJson()),
        'dev.remotepi.rooms:$standard': jsonEncode(<Object?>[
          const PersistedRoom(roomId: 'main', startedAt: 1).toJson(),
        ]),
      });

      final storage = await _storage(database, legacyStore: legacy);
      expect((await storage.listPeers()).single.remoteEpk, urlSafe);
      expect(await storage.loadRooms(standard), hasLength(1));
      expect(legacy.values, contains('dev.remotepi.peers:$standard'));
    });

    test('known unreadable record rolls back import and leaves no marker', () async {
      final database = AppDatabase.memory();
      addTearDown(database.dispose);
      final legacy = _FakeSecureStorage(
        values: <String, String>{
          'dev.remotepi.peers_index': jsonEncode(<String>['epk-good', 'epk-bad']),
          'dev.remotepi.peers:epk-good': jsonEncode(const PeerRecord(
            remoteEpk: 'epk-good',
            sessionName: 'good',
            relayUrl: 'https://relay.example.test',
            pairedAt: '2026-09-01T00:00:00Z',
          ).toJson()),
          'dev.remotepi.peers:epk-bad': jsonEncode(const PeerRecord(
            remoteEpk: 'epk-bad',
            sessionName: 'bad',
            relayUrl: 'https://relay.example.test',
            pairedAt: '2026-09-01T00:00:00Z',
          ).toJson()),
        },
        unreadableKeys: <String>{'dev.remotepi.peers:epk-bad'},
      );
      final storage = PairingStorage(database, legacyStore: legacy);

      await expectLater(
        storage.initialize(ownerPk: _ownerA, relayUrl: 'https://relay.example.test'),
        throwsA(isA<PairingMigrationException>()),
      );
      expect(database.db.select('SELECT * FROM pairing_peers'), isEmpty);
      expect(
        database.db.select(
          "SELECT * FROM legacy_imports WHERE source = 'pairing.secure_storage'",
        ),
        isEmpty,
      );
      expect(legacy.values, contains('dev.remotepi.peers:epk-good'));
      expect(legacy.values, contains('dev.remotepi.peers:epk-bad'));
    });

    test('unreadable inventory fails closed instead of becoming empty', () async {
      final database = AppDatabase.memory();
      addTearDown(database.dispose);
      final storage = PairingStorage(
        database,
        legacyStore: _FakeSecureStorage(failAllReads: true),
      );

      await expectLater(
        storage.initialize(ownerPk: _ownerA, relayUrl: 'https://relay.example.test'),
        throwsA(isA<PairingMigrationException>()),
      );
      expect(database.db.select('SELECT * FROM pairing_peers'), isEmpty);
    });
  });

  group('SQLite durability and scope', () {
    test('database close/reopen retains peers, rooms, and pending intent',
        () async {
      final directory =
          await Directory.systemTemp.createTemp('remote_pi_pairing_test_');
      addTearDown(() => directory.delete(recursive: true));
      final path = '${directory.path}/app.sqlite';

      final firstDatabase = AppDatabase.openForTest(path);
      addTearDown(firstDatabase.dispose);
      final first = await _storage(
        firstDatabase,
        legacyStore: _FakeSecureStorage(),
      );
      await first.savePeer(_peer, intent: PeerSaveIntent.enroll);
      await first.saveRooms(_peer.remoteEpk, const <PersistedRoom>[
        PersistedRoom(roomId: 'main', startedAt: 99, model: 'openai:gpt-5'),
      ]);
      firstDatabase.dispose();

      final secondDatabase = AppDatabase.openForTest(path);
      addTearDown(secondDatabase.dispose);
      final second = await _storage(
        secondDatabase,
        legacyStore: _FakeSecureStorage(failAllReads: true),
      );
      expect(await second.loadPeer(_peer.remoteEpk), _peer);
      expect((await second.loadRooms(_peer.remoteEpk)).single.startedAt, 99);
      expect(second.pendingMembershipOperationCount, 1);
    });

    test('membership intent keeps legacy peer URL inside active scope',
        () async {
      final database = AppDatabase.memory();
      addTearDown(database.dispose);
      final storage = await _storage(
        database,
        legacyStore: _FakeSecureStorage(),
        relayUrl: 'http://relay.example.test:3000',
      );
      const peer = PeerRecord(
        remoteEpk: 'legacy-payload-peer',
        sessionName: 'PC',
        relayUrl: 'http://relay.example.test',
        pairedAt: '2026-09-01T00:00:00Z',
      );

      await storage.savePeer(peer, intent: PeerSaveIntent.enroll);

      expect(await storage.listPeers(), <PeerRecord>[peer]);
      expect(storage.pendingMembershipOperationCount, 1);
    });

    test('late initialization cannot overwrite a newer relay scope', () async {
      const peer = PeerRecord(
        remoteEpk: 'race-peer',
        sessionName: 'PC',
        relayUrl: 'http://legacy.example.test',
        pairedAt: '2026-09-01T00:00:00Z',
      );
      final legacy = _BlockingFirstIndexReadStorage(values: <String, String>{
        legacyPeersIndexKey: jsonEncode(<String>[peer.remoteEpk]),
        '$legacyPeersService:${peer.remoteEpk}': jsonEncode(peer.toJson()),
      });
      final database = AppDatabase.memory();
      addTearDown(database.dispose);
      final storage = PairingStorage(database, legacyStore: legacy);

      final staleInitialization = storage.initialize(
        ownerPk: _ownerA,
        relayUrl: 'http://old-scope.example.test',
      );
      await legacy.firstReadStarted.future;
      await storage.initialize(
        ownerPk: _ownerA,
        relayUrl: 'http://new-scope.example.test',
      );
      legacy.releaseFirstRead.complete();
      await staleInitialization;

      expect(
        storage.membershipScope?.relayUrl,
        'http://new-scope.example.test',
      );
      expect(await storage.listPeers(), <PeerRecord>[peer]);
      await storage.initialize(
        ownerPk: _ownerA,
        relayUrl: 'http://old-scope.example.test',
      );
      expect(await storage.listPeers(), isEmpty);
    });

    test('owner and normalized relay scopes never expose each other', () async {
      final database = AppDatabase.memory();
      addTearDown(database.dispose);
      final storage = await _storage(database, legacyStore: _FakeSecureStorage());
      await storage.savePeer(_peer, intent: PeerSaveIntent.enroll);

      await storage.initialize(
        ownerPk: _ownerA,
        relayUrl: 'https://other.example.test/',
      );
      expect(await storage.listPeers(), isEmpty);

      await storage.initialize(
        ownerPk: _ownerB,
        relayUrl: 'HTTPS://RELAY.EXAMPLE.TEST/',
      );
      expect(await storage.listPeers(), isEmpty);

      await storage.initialize(
        ownerPk: _ownerA,
        relayUrl: 'wss://relay.example.test',
      );
      expect(await storage.listPeers(), <PeerRecord>[_peer]);
    });

    test('local metadata never creates intent or resurrects a revoked peer', () async {
      final database = AppDatabase.memory();
      addTearDown(database.dispose);
      final storage = await _storage(database, legacyStore: _FakeSecureStorage());
      await storage.savePeer(_peer, intent: PeerSaveIntent.enroll);
      await storage.savePeer(
        _peer.copyWith(roomId: 'room-2'),
        intent: PeerSaveIntent.localMetadata,
      );
      expect(storage.pendingMembershipOperationCount, 1);
      expect((await storage.loadPeer(_peer.remoteEpk))?.roomId, 'room-2');

      await storage.deletePeer(_peer.remoteEpk);
      await storage.savePeer(
        _peer.copyWith(roomId: 'stale-room'),
        intent: PeerSaveIntent.localMetadata,
      );
      expect(await storage.loadPeer(_peer.remoteEpk), isNull);
      expect(storage.pendingMembershipOperationCount, 2);
    });

    test('nickname intent is durable and not confused with local metadata', () async {
      final database = AppDatabase.memory();
      addTearDown(database.dispose);
      final storage = await _storage(database, legacyStore: _FakeSecureStorage());
      await storage.savePeer(_peer, intent: PeerSaveIntent.enroll);
      await storage.savePeer(
        _peer.copyWith(nickname: 'Renamed'),
        intent: PeerSaveIntent.nickname,
      );

      final restarted = await _storage(database);
      expect((await restarted.loadPeer(_peer.remoteEpk))?.nickname, 'Renamed');
      expect(restarted.pendingMembershipOperationCount, 2);
    });

    test('wipeAll atomically removes projection, rooms, journal, and snapshots', () async {
      final database = AppDatabase.memory();
      addTearDown(database.dispose);
      final storage = await _storage(database, legacyStore: _FakeSecureStorage());
      await storage.savePeer(_peer, intent: PeerSaveIntent.enroll);
      await storage.saveRooms(_peer.remoteEpk, const <PersistedRoom>[
        PersistedRoom(roomId: 'main', startedAt: 1),
      ]);

      var notifications = 0;
      storage.addListener(() => notifications++);
      await storage.wipeAll();

      expect(storage.isInitialized, isFalse);
      expect(database.db.select('SELECT * FROM pairing_peers'), isEmpty);
      expect(database.db.select('SELECT * FROM pairing_rooms'), isEmpty);
      expect(
        database.db.select('SELECT * FROM legacy_membership_recovery'),
        isEmpty,
      );
      expect(database.db.select('SELECT * FROM membership_operations'), isEmpty);
      expect(database.db.select('SELECT * FROM mesh_sync_state'), isEmpty);
      expect(notifications, 1);

      await storage.initialize(
        ownerPk: _ownerA,
        relayUrl: 'https://relay.example.test',
      );
      expect(await storage.listPeers(), isEmpty);
      expect(await storage.loadRooms(_peer.remoteEpk), isEmpty);
    });
  });
}
