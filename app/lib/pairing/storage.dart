import 'dart:convert';

import 'package:app/data/local/app_database.dart';
import 'package:app/data/transport/epk_encoding.dart';
import 'package:app/protocol/protocol.dart' show PiHarness;
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'legacy_pairing_migration.dart';
import 'membership_journal.dart';

const Object _unset = Object();
const int _pairMeshSchemaVersion = 2;

class PersistedRoom {
  final String roomId;
  final String? name;
  final String? cwd;
  final int startedAt;
  final String? localName;
  final String? model;

  const PersistedRoom({
    required this.roomId,
    required this.startedAt,
    this.name,
    this.cwd,
    this.localName,
    this.model,
  });

  Map<String, dynamic> toJson() => <String, dynamic>{
        'room_id': roomId,
        'name': name,
        'cwd': cwd,
        'started_at': startedAt,
        'local_name': localName,
        'model': model,
      };

  factory PersistedRoom.fromJson(Map<String, dynamic> json) => PersistedRoom(
        roomId: json['room_id'] as String,
        name: json['name'] as String?,
        cwd: json['cwd'] as String?,
        startedAt: (json['started_at'] as num).toInt(),
        localName: json['local_name'] as String?,
        model: json['model'] as String?,
      );

  PersistedRoom copyWith({
    String? name,
    String? cwd,
    int? startedAt,
    Object? localName = _unset,
    Object? model = _unset,
  }) =>
      PersistedRoom(
        roomId: roomId,
        name: name ?? this.name,
        cwd: cwd ?? this.cwd,
        startedAt: startedAt ?? this.startedAt,
        localName: identical(localName, _unset)
            ? this.localName
            : localName as String?,
        model: identical(model, _unset) ? this.model : model as String?,
      );

  @override
  bool operator ==(Object other) =>
      other is PersistedRoom &&
      other.roomId == roomId &&
      other.name == name &&
      other.cwd == cwd &&
      other.startedAt == startedAt &&
      other.localName == localName &&
      other.model == model;

  @override
  int get hashCode =>
      Object.hash(roomId, name, cwd, startedAt, localName, model);
}

class PeerRecord {
  final String remoteEpk;
  final String sessionName;
  /// Legacy signed/display metadata. Connections and mesh requests always use
  /// the currently configured relay represented by [MembershipScope].
  final String relayUrl;
  final String pairedAt;
  final String? nickname;
  final String? roomId;
  final PiHarness? harness;

  const PeerRecord({
    required this.remoteEpk,
    required this.sessionName,
    required this.relayUrl,
    required this.pairedAt,
    this.nickname,
    this.roomId,
    this.harness,
  });

  Map<String, dynamic> toJson() => <String, dynamic>{
        'remote_epk': remoteEpk,
        'session_name': sessionName,
        'relay_url': relayUrl,
        'paired_at': pairedAt,
        'nickname': nickname,
        'room_id': roomId,
        if (harness != null) 'harness': harness!.toJson(),
      };

  factory PeerRecord.fromJson(Map<String, dynamic> json) {
    final harnessJson = json['harness'];
    return PeerRecord(
      remoteEpk: json['remote_epk'] as String,
      sessionName: json['session_name'] as String,
      relayUrl: json['relay_url'] as String,
      pairedAt: json['paired_at'] as String,
      nickname: json['nickname'] as String?,
      roomId: json['room_id'] as String?,
      harness: harnessJson is Map<String, dynamic>
          ? PiHarness.fromJson(harnessJson)
          : null,
    );
  }

  PeerRecord copyWith({
    String? sessionName,
    Object? nickname = _unset,
    Object? roomId = _unset,
    Object? harness = _unset,
  }) =>
      PeerRecord(
        remoteEpk: remoteEpk,
        sessionName: sessionName ?? this.sessionName,
        relayUrl: relayUrl,
        pairedAt: pairedAt,
        nickname: identical(nickname, _unset)
            ? this.nickname
            : nickname as String?,
        roomId: identical(roomId, _unset) ? this.roomId : roomId as String?,
        harness: identical(harness, _unset)
            ? this.harness
            : harness as PiHarness?,
      );

  @override
  bool operator ==(Object other) =>
      other is PeerRecord &&
      other.remoteEpk == remoteEpk &&
      other.sessionName == sessionName &&
      other.relayUrl == relayUrl &&
      other.pairedAt == pairedAt &&
      other.nickname == nickname &&
      other.roomId == roomId &&
      other.harness == harness;

  @override
  int get hashCode => Object.hash(
        remoteEpk,
        sessionName,
        relayUrl,
        pairedAt,
        nickname,
        roomId,
        harness,
      );
}

/// Why a peer row is being saved.
///
/// Only [enroll] can add a missing peer. [nickname] records a durable mesh
/// rename for an existing peer. [localMetadata] updates room/session rendering
/// fields only and deliberately cannot recreate a peer after revocation.
enum PeerSaveIntent { enroll, nickname, localMetadata }

/// SQLite owner of peer/room projection and membership intent.
///
/// Secure storage is read only by the one-time legacy importer. After
/// [initialize] succeeds, every runtime read and write uses SQLite.
class PairingStorage extends ChangeNotifier {
  final AppDatabase _database;
  final FlutterSecureStorage _legacyStore;
  late final MembershipJournal _journal = MembershipJournal(_database);

  MembershipScope? _scope;
  bool _schemaReady = false;
  int _activationGeneration = 0;
  void Function()? _onPeersMutated;

  PairingStorage(
    this._database, {
    FlutterSecureStorage? legacyStore,
  }) : _legacyStore = legacyStore ?? const FlutterSecureStorage();

  bool get isInitialized => _scope != null;
  MembershipScope? get membershipScope => _scope;

  int get pendingMembershipOperationCount =>
      _journal.pendingCount(_requireScope());

  void attachPeerMutationHook(void Function()? hook) {
    _onPeersMutated = hook;
  }

  /// Creates PairMesh-owned schema, imports legacy secure metadata exactly
  /// once, then activates the owner + normalized-relay namespace.
  Future<void> initialize({
    required Uint8List ownerPk,
    required String relayUrl,
  }) async {
    final activation = ++_activationGeneration;
    _ensureSchema();
    final nextScope = MembershipScope(ownerPk: ownerPk, relayUrl: relayUrl);
    await LegacyPairingMigration(_database, _legacyStore).run(
      importRows: (inventory) => _importLegacy(inventory, nextScope),
      shouldCommit: () => activation == _activationGeneration,
    );
    if (activation != _activationGeneration || _scope == nextScope) return;
    _scope = nextScope;
    notifyListeners();
  }

  void _ensureSchema() {
    if (_schemaReady) return;
    _database.transaction(() {
      final db = _database.db;
      final storedVersionRows = db.select(
        "SELECT value FROM schema_metadata WHERE key = 'pair_mesh.schema_version'",
      );
      if (storedVersionRows.isNotEmpty) {
        final storedVersion =
            int.tryParse(storedVersionRows.single['value'] as String);
        if (storedVersion == null || storedVersion > _pairMeshSchemaVersion) {
          throw StateError(
            'Unsupported PairMesh schema version: '
            '${storedVersionRows.single['value']}',
          );
        }
      }
      db.execute('''
        CREATE TABLE IF NOT EXISTS pairing_peers (
          owner_id TEXT NOT NULL,
          relay_scope TEXT NOT NULL,
          remote_epk TEXT NOT NULL,
          session_name TEXT NOT NULL,
          relay_url TEXT NOT NULL,
          paired_at TEXT NOT NULL,
          nickname TEXT,
          room_id TEXT,
          harness_json TEXT,
          PRIMARY KEY (owner_id, relay_scope, remote_epk)
        )
      ''');
      db.execute('''
        CREATE INDEX IF NOT EXISTS pairing_peers_scope_order
        ON pairing_peers(owner_id, relay_scope, paired_at, remote_epk)
      ''');
      db.execute('''
        CREATE TABLE IF NOT EXISTS pairing_rooms (
          owner_id TEXT NOT NULL,
          relay_scope TEXT NOT NULL,
          remote_epk TEXT NOT NULL,
          room_id TEXT NOT NULL,
          name TEXT,
          cwd TEXT,
          started_at INTEGER NOT NULL,
          local_name TEXT,
          model TEXT,
          PRIMARY KEY (owner_id, relay_scope, remote_epk, room_id),
          FOREIGN KEY (owner_id, relay_scope, remote_epk)
            REFERENCES pairing_peers(owner_id, relay_scope, remote_epk)
            ON DELETE CASCADE
        )
      ''');
      db.execute('''
        CREATE INDEX IF NOT EXISTS pairing_rooms_peer_order
        ON pairing_rooms(owner_id, relay_scope, remote_epk, started_at, room_id)
      ''');
      db.execute('''
        CREATE TABLE IF NOT EXISTS legacy_membership_recovery (
          owner_id TEXT NOT NULL,
          relay_scope TEXT NOT NULL,
          remote_epk TEXT NOT NULL,
          member_relay_url TEXT NOT NULL,
          paired_at TEXT NOT NULL,
          nickname TEXT,
          authorized_by_not_found INTEGER NOT NULL DEFAULT 0
            CHECK (authorized_by_not_found IN (0, 1)),
          PRIMARY KEY (owner_id, relay_scope, remote_epk)
        )
      ''');
      _journal.ensureSchema();
      db.execute(
        '''
          INSERT INTO schema_metadata(key, value)
          VALUES ('pair_mesh.schema_version', '$_pairMeshSchemaVersion')
          ON CONFLICT(key) DO UPDATE SET value = excluded.value
        ''',
      );
    });
    _schemaReady = true;
  }

  void _importLegacy(
    LegacyPairingInventory inventory,
    MembershipScope initialScope,
  ) {
    for (final entry in inventory.entries) {
      final record = PeerRecord.fromJson(entry.peerJson);
      if (toAppEpk(entry.storageEpk) != toAppEpk(record.remoteEpk)) {
        throw PairingMigrationException(
          'Legacy key "${entry.storageEpk}" does not match its peer identity.',
        );
      }
      _requireValidPeerRelay(record);
      final recordScope = initialScope;
      final canonical = _canonicalRecord(record);
      final existing = _loadPeerSync(recordScope, canonical.remoteEpk);
      if (existing != null && existing != canonical) {
        throw PairingMigrationException(
          'Conflicting legacy records resolve to "${canonical.remoteEpk}".',
        );
      }
      if (existing == null) _writePeerRow(recordScope, canonical);
      _writeLegacyRecoveryRow(recordScope, canonical);
      for (final roomJson in entry.roomsJson) {
        _writeRoomRow(
          recordScope,
          canonical.remoteEpk,
          PersistedRoom.fromJson(roomJson),
        );
      }
    }
  }

  Future<void> savePeer(
    PeerRecord record, {
    required PeerSaveIntent intent,
  }) async {
    final scope = _requireScope();
    final canonicalEpk = toAppEpk(record.remoteEpk);
    var changed = false;
    var createdMembershipIntent = false;
    _database.transaction(() {
      final current = _loadPeerSync(scope, canonicalEpk);
      switch (intent) {
        case PeerSaveIntent.enroll:
          _requireValidPeerRelay(record);
          final next = _canonicalRecord(record);
          changed = current != next;
          _writePeerRow(scope, next);
          _journal.appendEnroll(scope, _memberFromPeer(next));
          createdMembershipIntent = true;
          break;
        case PeerSaveIntent.nickname:
          if (current == null) {
            throw StateError('Cannot rename an absent or revoked peer');
          }
          final next = current.copyWith(nickname: record.nickname);
          changed = current != next;
          if (changed) _writePeerRow(scope, next);
          if (current.nickname != next.nickname) {
            _journal.appendRename(scope, canonicalEpk, next.nickname);
            createdMembershipIntent = true;
          }
          break;
        case PeerSaveIntent.localMetadata:
          if (current == null) return;
          final next = PeerRecord(
            remoteEpk: current.remoteEpk,
            sessionName: record.sessionName,
            relayUrl: current.relayUrl,
            pairedAt: current.pairedAt,
            nickname: current.nickname,
            roomId: record.roomId,
            harness: record.harness,
          );
          changed = current != next;
          if (changed) _writePeerRow(scope, next);
          break;
      }
      if (changed || createdMembershipIntent) {
        _database.afterCommit(() {
          if (changed) notifyListeners();
          if (createdMembershipIntent) _onPeersMutated?.call();
        });
      }
    });
  }

  Future<PeerRecord?> loadPeer(String remoteEpk) async =>
      _loadPeerSync(_requireScope(), toAppEpk(remoteEpk));

  Future<List<PeerRecord>> listPeers() async {
    final scope = _requireScope();
    final rows = _database.db.select(
      '''
        SELECT remote_epk, session_name, relay_url, paired_at, nickname,
               room_id, harness_json
        FROM pairing_peers
        WHERE owner_id = ? AND relay_scope = ?
        ORDER BY paired_at ASC, remote_epk ASC
      ''',
      <Object?>[scope.ownerId, scope.relayUrl],
    );
    return rows.map(_peerFromRow).toList(growable: false);
  }

  Future<void> deletePeer(String remoteEpk) async {
    final scope = _requireScope();
    final canonicalEpk = toAppEpk(remoteEpk);
    var changed = false;
    _database.transaction(() {
      changed = _loadPeerSync(scope, canonicalEpk) != null;
      _database.db.execute(
        '''
          DELETE FROM pairing_rooms
          WHERE owner_id = ? AND relay_scope = ? AND remote_epk = ?
        ''',
        <Object?>[scope.ownerId, scope.relayUrl, canonicalEpk],
      );
      _database.db.execute(
        '''
          DELETE FROM pairing_peers
          WHERE owner_id = ? AND relay_scope = ? AND remote_epk = ?
        ''',
        <Object?>[scope.ownerId, scope.relayUrl, canonicalEpk],
      );
      _journal.appendRevoke(scope, canonicalEpk);
      _database.afterCommit(() {
        if (changed) notifyListeners();
        _onPeersMutated?.call();
      });
    });
  }

  Future<void> saveRooms(
    String remoteEpk,
    List<PersistedRoom> rooms,
  ) async {
    final scope = _requireScope();
    final canonicalEpk = toAppEpk(remoteEpk);
    var changed = false;
    _database.transaction(() {
      if (_loadPeerSync(scope, canonicalEpk) == null) return;
      final previous = _loadRoomsSync(scope, canonicalEpk);
      changed = !listEquals(previous, rooms);
      if (!changed) return;
      _database.db.execute(
        '''
          DELETE FROM pairing_rooms
          WHERE owner_id = ? AND relay_scope = ? AND remote_epk = ?
        ''',
        <Object?>[scope.ownerId, scope.relayUrl, canonicalEpk],
      );
      for (final room in rooms) {
        _writeRoomRow(scope, canonicalEpk, room);
      }
      _database.afterCommit(notifyListeners);
    });
  }

  Future<List<PersistedRoom>> loadRooms(String remoteEpk) async =>
      _loadRoomsSync(_requireScope(), toAppEpk(remoteEpk));

  Future<void> deleteRooms(String remoteEpk) async {
    final scope = _requireScope();
    final canonicalEpk = toAppEpk(remoteEpk);
    _database.transaction(() {
      final count = _database.db.select(
        '''
          SELECT COUNT(*) AS count FROM pairing_rooms
          WHERE owner_id = ? AND relay_scope = ? AND remote_epk = ?
        ''',
        <Object?>[scope.ownerId, scope.relayUrl, canonicalEpk],
      ).single['count'] as int;
      if (count == 0) return;
      _database.db.execute(
        '''
          DELETE FROM pairing_rooms
          WHERE owner_id = ? AND relay_scope = ? AND remote_epk = ?
        ''',
        <Object?>[scope.ownerId, scope.relayUrl, canonicalEpk],
      );
      _database.afterCommit(notifyListeners);
    });
  }

  /// Owner-reset cutover. The legacy-import marker intentionally remains so a
  /// restored identity cannot re-adopt the previous owner's secure metadata.
  Future<void> wipeAll() async {
    _activationGeneration++;
    _database.transaction(() {
      _database.db.execute('DELETE FROM pairing_rooms');
      _database.db.execute('DELETE FROM legacy_membership_recovery');
      _database.db.execute('DELETE FROM pairing_peers');
      _journal.clearAll();
      _database.afterCommit(() {
        _scope = null;
        notifyListeners();
      });
    });
  }

  List<MembershipOperation> pendingMembershipOperations(
    MembershipScope scope,
  ) =>
      _journal.pending(scope);

  VerifiedMembershipSnapshot? verifiedMembershipSnapshot(
    MembershipScope scope,
  ) =>
      _journal.loadSnapshot(scope);

  LegacyMembershipRecovery? legacyMembershipRecovery(
    MembershipScope scope,
  ) {
    final rows = _database.db.select(
      '''
        SELECT remote_epk, member_relay_url, paired_at, nickname,
               authorized_by_not_found
        FROM legacy_membership_recovery
        WHERE owner_id = ? AND relay_scope = ?
        ORDER BY remote_epk ASC
      ''',
      <Object?>[scope.ownerId, scope.relayUrl],
    );
    if (rows.isEmpty) return null;
    return LegacyMembershipRecovery(
      members: rows
          .map(
            (row) => MembershipMember(
              remoteEpk: row['remote_epk'] as String,
              relayUrl: row['member_relay_url'] as String,
              pairedAt: row['paired_at'] as String,
              nickname: row['nickname'] as String?,
            ),
          )
          .toList(growable: false),
      authorizedByNotFound: rows.every(
        (row) => (row['authorized_by_not_found'] as int) == 1,
      ),
    );
  }

  bool authorizeLegacyMembershipRecovery(MembershipScope scope) {
    if (_scope != scope) return false;
    var found = false;
    _database.transaction(() {
      final count = _database.db.select(
        '''
          SELECT COUNT(*) AS count
          FROM legacy_membership_recovery
          WHERE owner_id = ? AND relay_scope = ?
        ''',
        <Object?>[scope.ownerId, scope.relayUrl],
      ).single['count'] as int;
      if (count == 0) return;
      _database.db.execute(
        '''
          UPDATE legacy_membership_recovery
          SET authorized_by_not_found = 1
          WHERE owner_id = ? AND relay_scope = ?
        ''',
        <Object?>[scope.ownerId, scope.relayUrl],
      );
      found = true;
    });
    return found;
  }

  /// Atomically persists a verified relay snapshot and replaces the visible
  /// projection with that snapshot rebased through all currently pending ops.
  bool applyVerifiedProjection({
    required MembershipScope scope,
    required List<MembershipMember> members,
    required VerifiedMembershipSnapshot snapshot,
    bool replaceCorruptSnapshot = false,
  }) {
    if (_scope != scope) return false;
    var applied = false;
    _database.transaction(() {
      final current = _journal.loadSnapshot(scope);
      if (!replaceCorruptSnapshot &&
          current != null &&
          current.version >= snapshot.version) {
        return;
      }
      var pending = _journal.pending(scope);
      final superseded = MembershipJournal.supersededRenameSequences(
        members,
        pending,
      );
      if (superseded.isNotEmpty) {
        _journal.acknowledge(scope, superseded);
        pending = _journal.pending(scope);
      }
      final projected = MembershipJournal.rebase(members, pending);
      _replaceProjectionRows(scope, projected);
      _journal.saveSnapshot(scope, snapshot);
      _clearLegacyRecovery(scope);
      _database.afterCommit(notifyListeners);
      applied = true;
    });
    return applied;
  }

  /// Stores an accepted publication as the new verified base, removes only
  /// the operation sequences captured in that request, and replays any later
  /// operations into the visible projection in the same transaction.
  bool acknowledgePublishedSnapshot({
    required MembershipScope scope,
    required VerifiedMembershipSnapshot snapshot,
    required List<MembershipMember> acceptedMembers,
    required Iterable<int> capturedSequences,
  }) {
    if (_scope != scope) return false;
    var accepted = false;
    _database.transaction(() {
      final current = _journal.loadSnapshot(scope);
      if (current != null && current.version >= snapshot.version) return;
      _journal.saveSnapshot(scope, snapshot);
      _journal.acknowledge(scope, capturedSequences);
      final projected = MembershipJournal.rebase(
        acceptedMembers,
        _journal.pending(scope),
      );
      _replaceProjectionRows(scope, projected);
      _clearLegacyRecovery(scope);
      _database.afterCommit(notifyListeners);
      accepted = true;
    });
    return accepted;
  }


  void _replaceProjectionRows(
    MembershipScope scope,
    List<MembershipMember> members,
  ) {
    final existing = <String, PeerRecord>{
      for (final peer in _listPeersSync(scope)) peer.remoteEpk: peer,
    };
    final incoming = <String, PeerRecord>{};
    for (final member in members) {
      final canonicalEpk = toAppEpk(member.remoteEpk);
      if (incoming.containsKey(canonicalEpk)) {
        throw StateError('Verified snapshot contained a duplicate peer');
      }
      final candidate = PeerRecord(
        remoteEpk: canonicalEpk,
        sessionName: member.nickname ?? 'remote_pi',
        relayUrl: member.relayUrl,
        pairedAt: member.pairedAt,
        nickname: member.nickname,
      );
      _requireValidPeerRelay(candidate);
      final previous = existing[canonicalEpk];
      incoming[canonicalEpk] = PeerRecord(
        remoteEpk: canonicalEpk,
        sessionName: previous?.sessionName ?? candidate.sessionName,
        relayUrl: candidate.relayUrl,
        pairedAt: candidate.pairedAt,
        nickname: candidate.nickname,
        roomId: previous?.roomId,
        harness: previous?.harness,
      );
    }
    for (final removed in existing.keys) {
      if (incoming.containsKey(removed)) continue;
      _database.db.execute(
        '''
          DELETE FROM pairing_rooms
          WHERE owner_id = ? AND relay_scope = ? AND remote_epk = ?
        ''',
        <Object?>[scope.ownerId, scope.relayUrl, removed],
      );
      _database.db.execute(
        '''
          DELETE FROM pairing_peers
          WHERE owner_id = ? AND relay_scope = ? AND remote_epk = ?
        ''',
        <Object?>[scope.ownerId, scope.relayUrl, removed],
      );
    }
    for (final peer in incoming.values) {
      _writePeerRow(scope, peer);
    }
  }

  static List<MembershipMember> rebaseMembership(
    Iterable<MembershipMember> base,
    Iterable<MembershipOperation> operations,
  ) =>
      MembershipJournal.rebase(base, operations);

  MembershipScope _requireScope() {
    final scope = _scope;
    if (scope == null) {
      throw StateError('PairingStorage.initialize must complete before use');
    }
    return scope;
  }

  void _requireValidPeerRelay(PeerRecord record) {
    // PeerRecord.relayUrl is legacy signed/display metadata. Validate its
    // shape, but never use it to select the active request namespace.
    normalizeMembershipRelayUrl(record.relayUrl);
  }

  PeerRecord _canonicalRecord(PeerRecord record) => PeerRecord(
        remoteEpk: toAppEpk(record.remoteEpk),
        sessionName: record.sessionName,
        relayUrl: record.relayUrl,
        pairedAt: record.pairedAt,
        nickname: record.nickname,
        roomId: record.roomId,
        harness: record.harness,
      );

  MembershipMember _memberFromPeer(PeerRecord peer) => MembershipMember(
        remoteEpk: peer.remoteEpk,
        relayUrl: peer.relayUrl,
        pairedAt: peer.pairedAt,
        nickname: peer.nickname,
      );

  void _writeLegacyRecoveryRow(
    MembershipScope scope,
    PeerRecord record,
  ) {
    _database.db.execute(
      '''
        INSERT INTO legacy_membership_recovery(
          owner_id, relay_scope, remote_epk, member_relay_url,
          paired_at, nickname, authorized_by_not_found
        ) VALUES (?, ?, ?, ?, ?, ?, 0)
        ON CONFLICT(owner_id, relay_scope, remote_epk) DO UPDATE SET
          member_relay_url = excluded.member_relay_url,
          paired_at = excluded.paired_at,
          nickname = excluded.nickname,
          authorized_by_not_found = 0
      ''',
      <Object?>[
        scope.ownerId,
        scope.relayUrl,
        toAppEpk(record.remoteEpk),
        record.relayUrl,
        record.pairedAt,
        record.nickname,
      ],
    );
  }

  void _clearLegacyRecovery(MembershipScope scope) {
    _database.db.execute(
      '''
        DELETE FROM legacy_membership_recovery
        WHERE owner_id = ? AND relay_scope = ?
      ''',
      <Object?>[scope.ownerId, scope.relayUrl],
    );
  }

  void _writePeerRow(MembershipScope scope, PeerRecord record) {
    _database.db.execute(
      '''
        INSERT INTO pairing_peers(
          owner_id, relay_scope, remote_epk, session_name, relay_url,
          paired_at, nickname, room_id, harness_json
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(owner_id, relay_scope, remote_epk) DO UPDATE SET
          session_name = excluded.session_name,
          relay_url = excluded.relay_url,
          paired_at = excluded.paired_at,
          nickname = excluded.nickname,
          room_id = excluded.room_id,
          harness_json = excluded.harness_json
      ''',
      <Object?>[
        scope.ownerId,
        scope.relayUrl,
        toAppEpk(record.remoteEpk),
        record.sessionName,
        record.relayUrl,
        record.pairedAt,
        record.nickname,
        record.roomId,
        record.harness == null ? null : jsonEncode(record.harness!.toJson()),
      ],
    );
  }

  PeerRecord? _loadPeerSync(MembershipScope scope, String remoteEpk) {
    final rows = _database.db.select(
      '''
        SELECT remote_epk, session_name, relay_url, paired_at, nickname,
               room_id, harness_json
        FROM pairing_peers
        WHERE owner_id = ? AND relay_scope = ? AND remote_epk = ?
      ''',
      <Object?>[scope.ownerId, scope.relayUrl, toAppEpk(remoteEpk)],
    );
    return rows.isEmpty ? null : _peerFromRow(rows.single);
  }

  List<PeerRecord> _listPeersSync(MembershipScope scope) {
    final rows = _database.db.select(
      '''
        SELECT remote_epk, session_name, relay_url, paired_at, nickname,
               room_id, harness_json
        FROM pairing_peers
        WHERE owner_id = ? AND relay_scope = ?
        ORDER BY paired_at ASC, remote_epk ASC
      ''',
      <Object?>[scope.ownerId, scope.relayUrl],
    );
    return rows.map(_peerFromRow).toList(growable: false);
  }

  PeerRecord _peerFromRow(dynamic row) {
    final harnessRaw = row['harness_json'] as String?;
    final harnessJson = harnessRaw == null ? null : jsonDecode(harnessRaw);
    return PeerRecord(
      remoteEpk: row['remote_epk'] as String,
      sessionName: row['session_name'] as String,
      relayUrl: row['relay_url'] as String,
      pairedAt: row['paired_at'] as String,
      nickname: row['nickname'] as String?,
      roomId: row['room_id'] as String?,
      harness: harnessJson is Map<String, dynamic>
          ? PiHarness.fromJson(harnessJson)
          : null,
    );
  }

  void _writeRoomRow(
    MembershipScope scope,
    String remoteEpk,
    PersistedRoom room,
  ) {
    _database.db.execute(
      '''
        INSERT INTO pairing_rooms(
          owner_id, relay_scope, remote_epk, room_id, name, cwd,
          started_at, local_name, model
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(owner_id, relay_scope, remote_epk, room_id) DO UPDATE SET
          name = excluded.name,
          cwd = excluded.cwd,
          started_at = excluded.started_at,
          local_name = excluded.local_name,
          model = excluded.model
      ''',
      <Object?>[
        scope.ownerId,
        scope.relayUrl,
        toAppEpk(remoteEpk),
        room.roomId,
        room.name,
        room.cwd,
        room.startedAt,
        room.localName,
        room.model,
      ],
    );
  }

  List<PersistedRoom> _loadRoomsSync(
    MembershipScope scope,
    String remoteEpk,
  ) {
    final rows = _database.db.select(
      '''
        SELECT room_id, name, cwd, started_at, local_name, model
        FROM pairing_rooms
        WHERE owner_id = ? AND relay_scope = ? AND remote_epk = ?
        ORDER BY started_at ASC, room_id ASC
      ''',
      <Object?>[scope.ownerId, scope.relayUrl, toAppEpk(remoteEpk)],
    );
    return rows
        .map(
          (row) => PersistedRoom(
            roomId: row['room_id'] as String,
            name: row['name'] as String?,
            cwd: row['cwd'] as String?,
            startedAt: row['started_at'] as int,
            localName: row['local_name'] as String?,
            model: row['model'] as String?,
          ),
        )
        .toList(growable: false);
  }
}
