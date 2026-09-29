import 'dart:convert';
import 'dart:typed_data';

import 'package:app/data/local/app_database.dart';
import 'package:app/data/transport/epk_encoding.dart';
import 'package:app/data/transport/relay_config.dart';

/// Owner + relay namespace for every membership snapshot and operation.
///
/// Owner bytes are encoded losslessly and relay URLs are canonicalized to the
/// HTTP form used by [MeshClient]. This prevents pending intent from leaking
/// across an identity restore or relay-profile switch.
final class MembershipScope {
  final String ownerId;
  final String relayUrl;

  MembershipScope({required Uint8List ownerPk, required String relayUrl})
      : ownerId = base64Url.encode(ownerPk).replaceAll('=', ''),
        relayUrl = normalizeMembershipRelayUrl(relayUrl) {
    if (ownerPk.length != 32) {
      throw ArgumentError.value(
        ownerPk.length,
        'ownerPk.length',
        'Ed25519 owner public key must be exactly 32 bytes',
      );
    }
  }

  const MembershipScope.stored({required this.ownerId, required this.relayUrl});

  @override
  bool operator ==(Object other) =>
      other is MembershipScope &&
      other.ownerId == ownerId &&
      other.relayUrl == relayUrl;

  @override
  int get hashCode => Object.hash(ownerId, relayUrl);
}

String normalizeMembershipRelayUrl(String raw) {
  final initiallyNormalized = normalizeRelayUrl(raw);
  final parsed = Uri.parse(initiallyNormalized);
  var scheme = parsed.scheme.toLowerCase();
  if (scheme == 'ws') scheme = 'http';
  if (scheme == 'wss') scheme = 'https';
  if (scheme != 'http' && scheme != 'https') {
    throw FormatException('Unsupported relay URL scheme: ${parsed.scheme}');
  }
  if (parsed.host.isEmpty) {
    throw const FormatException('Relay URL must include a host');
  }

  var path = parsed.path;
  while (path.endsWith('/') && path.isNotEmpty) {
    path = path.substring(0, path.length - 1);
  }
  final isDefaultPort =
      (scheme == 'http' && parsed.port == 80) ||
      (scheme == 'https' && parsed.port == 443);
  return Uri(
    scheme: scheme,
    userInfo: parsed.userInfo,
    host: parsed.host.toLowerCase(),
    port: isDefaultPort ? null : (parsed.hasPort ? parsed.port : null),
    path: path,
  ).toString();
}

final class MembershipMember {
  final String remoteEpk;
  final String relayUrl;
  final String pairedAt;
  final String? nickname;

  const MembershipMember({
    required this.remoteEpk,
    required this.relayUrl,
    required this.pairedAt,
    this.nickname,
  });

  MembershipMember copyWithNickname(String? value) => MembershipMember(
        remoteEpk: remoteEpk,
        relayUrl: relayUrl,
        pairedAt: pairedAt,
        nickname: value,
      );

  @override
  bool operator ==(Object other) =>
      other is MembershipMember &&
      toAppEpk(other.remoteEpk) == toAppEpk(remoteEpk) &&
      other.relayUrl == relayUrl &&
      other.pairedAt == pairedAt &&
      other.nickname == nickname;

  @override
  int get hashCode =>
      Object.hash(toAppEpk(remoteEpk), relayUrl, pairedAt, nickname);
}

enum MembershipOperationKind { enroll, rename, revoke }

final class MembershipOperation {
  final int sequence;
  final MembershipOperationKind kind;
  final String remoteEpk;
  final String? relayUrl;
  final String? pairedAt;
  final String? nickname;

  const MembershipOperation({
    required this.sequence,
    required this.kind,
    required this.remoteEpk,
    this.relayUrl,
    this.pairedAt,
    this.nickname,
  });

  MembershipMember get enrolledMember {
    if (kind != MembershipOperationKind.enroll ||
        relayUrl == null ||
        pairedAt == null) {
      throw StateError('Only a complete enroll operation has a member value');
    }
    return MembershipMember(
      remoteEpk: remoteEpk,
      relayUrl: relayUrl!,
      pairedAt: pairedAt!,
      nickname: nickname,
    );
  }
}

final class VerifiedMembershipSnapshot {
  final int version;
  final int updatedAt;
  final Uint8List blob;
  final Uint8List signature;

  VerifiedMembershipSnapshot({
    required this.version,
    required this.updatedAt,
    required Uint8List blob,
    required Uint8List signature,
  })  : blob = Uint8List.fromList(blob),
        signature = Uint8List.fromList(signature) {
    if (version <= 0) {
      throw ArgumentError.value(version, 'version', 'must be positive');
    }
  }
}

/// One-time recovery candidate captured from the pre-SQLite peer inventory.
/// It may become a publication base only after this relay explicitly returns
/// 404. A valid signed snapshot always supersedes it.
final class LegacyMembershipRecovery {
  final List<MembershipMember> members;
  final bool authorizedByNotFound;

  LegacyMembershipRecovery({
    required List<MembershipMember> members,
    required this.authorizedByNotFound,
  }) : members = List<MembershipMember>.unmodifiable(members);
}

/// SQLite-backed explicit membership intent and last verified relay snapshot.
/// All methods are synchronous so callers can compose them inside one database
/// transaction without awaiting between related writes.
final class MembershipJournal {
  final AppDatabase _database;

  MembershipJournal(this._database);

  void ensureSchema() {
    _database.transaction(() {
      final db = _database.db;
      db.execute('''
        CREATE TABLE IF NOT EXISTS membership_operations (
          sequence INTEGER PRIMARY KEY AUTOINCREMENT,
          owner_id TEXT NOT NULL,
          relay_url TEXT NOT NULL,
          kind TEXT NOT NULL CHECK (kind IN ('enroll', 'rename', 'revoke')),
          remote_epk TEXT NOT NULL,
          member_relay_url TEXT,
          paired_at TEXT,
          nickname TEXT,
          created_at_ms INTEGER NOT NULL
        )
      ''');
      db.execute('''
        CREATE INDEX IF NOT EXISTS membership_operations_scope_sequence
        ON membership_operations(owner_id, relay_url, sequence)
      ''');
      db.execute('''
        CREATE TABLE IF NOT EXISTS mesh_sync_state (
          owner_id TEXT NOT NULL,
          relay_url TEXT NOT NULL,
          version INTEGER NOT NULL CHECK (version > 0),
          updated_at_ms INTEGER NOT NULL,
          envelope_blob BLOB NOT NULL,
          envelope_signature BLOB NOT NULL,
          PRIMARY KEY (owner_id, relay_url)
        )
      ''');
    });
  }

  int appendEnroll(MembershipScope scope, MembershipMember member) =>
      _append(
        scope,
        MembershipOperationKind.enroll,
        member.remoteEpk,
        relayUrl: member.relayUrl,
        pairedAt: member.pairedAt,
        nickname: member.nickname,
      );

  int appendRename(MembershipScope scope, String remoteEpk, String? nickname) =>
      _append(
        scope,
        MembershipOperationKind.rename,
        remoteEpk,
        nickname: nickname,
      );

  int appendRevoke(MembershipScope scope, String remoteEpk) =>
      _append(scope, MembershipOperationKind.revoke, remoteEpk);

  int _append(
    MembershipScope scope,
    MembershipOperationKind kind,
    String remoteEpk, {
    String? relayUrl,
    String? pairedAt,
    String? nickname,
  }) {
    return _database.transaction(() {
      _database.db.execute(
        '''
          INSERT INTO membership_operations(
            owner_id, relay_url, kind, remote_epk, member_relay_url,
            paired_at, nickname, created_at_ms
          ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        ''',
        <Object?>[
          scope.ownerId,
          scope.relayUrl,
          kind.name,
          toAppEpk(remoteEpk),
          relayUrl,
          pairedAt,
          nickname,
          DateTime.now().toUtc().millisecondsSinceEpoch,
        ],
      );
      return _database.db.lastInsertRowId;
    });
  }

  List<MembershipOperation> pending(MembershipScope scope) {
    final rows = _database.db.select(
      '''
        SELECT sequence, kind, remote_epk, member_relay_url, paired_at, nickname
        FROM membership_operations
        WHERE owner_id = ? AND relay_url = ?
        ORDER BY sequence ASC
      ''',
      <Object?>[scope.ownerId, scope.relayUrl],
    );
    return rows
        .map(
          (row) => MembershipOperation(
            sequence: row['sequence'] as int,
            kind: MembershipOperationKind.values.byName(row['kind'] as String),
            remoteEpk: row['remote_epk'] as String,
            relayUrl: row['member_relay_url'] as String?,
            pairedAt: row['paired_at'] as String?,
            nickname: row['nickname'] as String?,
          ),
        )
        .toList(growable: false);
  }

  int pendingCount(MembershipScope scope) {
    final row = _database.db.select(
      '''
        SELECT COUNT(*) AS count
        FROM membership_operations
        WHERE owner_id = ? AND relay_url = ?
      ''',
      <Object?>[scope.ownerId, scope.relayUrl],
    ).single;
    return row['count'] as int;
  }

  void acknowledge(MembershipScope scope, Iterable<int> sequences) {
    final captured = sequences.toList(growable: false);
    if (captured.isEmpty) return;
    _database.transaction(() {
      for (final sequence in captured) {
        _database.db.execute(
          '''
            DELETE FROM membership_operations
            WHERE owner_id = ? AND relay_url = ? AND sequence = ?
          ''',
          <Object?>[scope.ownerId, scope.relayUrl, sequence],
        );
      }
    });
  }

  VerifiedMembershipSnapshot? loadSnapshot(MembershipScope scope) {
    final rows = _database.db.select(
      '''
        SELECT version, updated_at_ms, envelope_blob, envelope_signature
        FROM mesh_sync_state
        WHERE owner_id = ? AND relay_url = ?
      ''',
      <Object?>[scope.ownerId, scope.relayUrl],
    );
    if (rows.isEmpty) return null;
    final row = rows.single;
    return VerifiedMembershipSnapshot(
      version: row['version'] as int,
      updatedAt: row['updated_at_ms'] as int,
      blob: row['envelope_blob'] as Uint8List,
      signature: row['envelope_signature'] as Uint8List,
    );
  }

  void saveSnapshot(MembershipScope scope, VerifiedMembershipSnapshot snapshot) {
    _database.db.execute(
      '''
        INSERT INTO mesh_sync_state(
          owner_id, relay_url, version, updated_at_ms,
          envelope_blob, envelope_signature
        ) VALUES (?, ?, ?, ?, ?, ?)
        ON CONFLICT(owner_id, relay_url) DO UPDATE SET
          version = excluded.version,
          updated_at_ms = excluded.updated_at_ms,
          envelope_blob = excluded.envelope_blob,
          envelope_signature = excluded.envelope_signature
      ''',
      <Object?>[
        scope.ownerId,
        scope.relayUrl,
        snapshot.version,
        snapshot.updatedAt,
        snapshot.blob,
        snapshot.signature,
      ],
    );
  }

  void clearAll() {
    _database.db.execute('DELETE FROM membership_operations');
    _database.db.execute('DELETE FROM mesh_sync_state');
  }

  /// Rename is an ordinary update, not enrollment. Once a freshly verified
  /// base proves the target absent (and no earlier pending enroll restores
  /// it), that rename is superseded by the remote revocation.
  static List<int> supersededRenameSequences(
    Iterable<MembershipMember> base,
    Iterable<MembershipOperation> operations,
  ) {
    final present = <String>{
      for (final member in base) toAppEpk(member.remoteEpk),
    };
    final superseded = <int>[];
    for (final operation in operations) {
      final epk = toAppEpk(operation.remoteEpk);
      switch (operation.kind) {
        case MembershipOperationKind.enroll:
          present.add(epk);
          break;
        case MembershipOperationKind.rename:
          if (!present.contains(epk)) superseded.add(operation.sequence);
          break;
        case MembershipOperationKind.revoke:
          present.remove(epk);
          break;
      }
    }
    return superseded;
  }

  static List<MembershipMember> rebase(
    Iterable<MembershipMember> base,
    Iterable<MembershipOperation> operations,
  ) {
    final members = <String, MembershipMember>{
      for (final member in base) toAppEpk(member.remoteEpk): MembershipMember(
        remoteEpk: toAppEpk(member.remoteEpk),
        relayUrl: member.relayUrl,
        pairedAt: member.pairedAt,
        nickname: member.nickname,
      ),
    };
    for (final operation in operations) {
      final epk = toAppEpk(operation.remoteEpk);
      switch (operation.kind) {
        case MembershipOperationKind.enroll:
          final member = operation.enrolledMember;
          members[epk] = MembershipMember(
            remoteEpk: epk,
            relayUrl: member.relayUrl,
            pairedAt: member.pairedAt,
            nickname: member.nickname,
          );
          break;
        case MembershipOperationKind.rename:
          final current = members[epk];
          if (current != null) {
            members[epk] = current.copyWithNickname(operation.nickname);
          }
          break;
        case MembershipOperationKind.revoke:
          members.remove(epk);
          break;
      }
    }
    final result = members.values.toList(growable: false)
      ..sort((a, b) => a.remoteEpk.compareTo(b.remoteEpk));
    return result;
  }
}
