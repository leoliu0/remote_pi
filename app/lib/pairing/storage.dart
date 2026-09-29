import 'dart:convert';

import 'package:app/data/transport/epk_encoding.dart';
import 'package:app/protocol/protocol.dart' show PiHarness;
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

const _kPeersService = 'dev.remotepi.peers';
const _kRoomsService = 'dev.remotepi.rooms';
const _kPeersIndexKey = 'dev.remotepi.peers_index';

/// Plan-17 follow-up — persisted snapshot of every room we have ever
/// learned about for a peer (relay-announced via `room_announced` /
/// `rooms` push). Allows Home to keep showing the same tiles after a
/// cold start while the relay is still warming up + lets the user
/// open a chat offline and read history.
class PersistedRoom {
  final String roomId;
  final String? name;
  final String? cwd;
  final int startedAt;
  /// Local-only override for [name]. When non-null, takes precedence
  /// in UI (long-press rename).
  final String? localName;
  /// Plan 18 — last-known model the Pi-extension is running with.
  /// Persisted so the subtitle survives cold starts.
  final String? model;

  const PersistedRoom({
    required this.roomId,
    required this.startedAt,
    this.name,
    this.cwd,
    this.localName,
    this.model,
  });

  Map<String, dynamic> toJson() => {
    'room_id': roomId,
    'name': name,
    'cwd': cwd,
    'started_at': startedAt,
    'local_name': localName,
    'model': model,
  };

  factory PersistedRoom.fromJson(Map<String, dynamic> j) => PersistedRoom(
    roomId: j['room_id'] as String,
    name: j['name'] as String?,
    cwd: j['cwd'] as String?,
    startedAt: (j['started_at'] as num).toInt(),
    localName: j['local_name'] as String?,
    model: j['model'] as String?,
  );

  PersistedRoom copyWith({
    String? name,
    String? cwd,
    int? startedAt,
    Object? localName = _unset,
    Object? model = _unset,
  }) => PersistedRoom(
    roomId: roomId,
    name: name ?? this.name,
    cwd: cwd ?? this.cwd,
    startedAt: startedAt ?? this.startedAt,
    localName: identical(localName, _unset)
        ? this.localName
        : localName as String?,
    model: identical(model, _unset)
        ? this.model
        : model as String?,
  );
}

// ---------------------------------------------------------------------------
// PeerRecord — persisted per pairing
// ---------------------------------------------------------------------------

// Sentinel for nullable copyWith parameters that need to distinguish
// "keep current" (omit) from "set to null" (pass `null` explicitly).
const Object _unset = Object();

class PeerRecord {
  // base64 Ed25519 pubkey of the Pi — the only peer identifier post-rollback.
  final String remoteEpk;
  final String sessionName;
  final String relayUrl;
  final String pairedAt; // ISO-8601
  // Local-only display label (Pi does not know about this). Renders in
  // place of [sessionName] when set; null = use sessionName everywhere.
  final String? nickname;
  /// Plan 17 fix — Pi-side room id (cwd-session) this pairing is bound
  /// to. Set from `PairOk.roomId` on pair, or discovered lazily via
  /// `subscribe_rooms` for legacy peers persisted before this fix.
  /// `null` = not yet discovered; outbound sends fall back to 'main'
  /// while ConnectionManager runs the discovery once.
  final String? roomId;
  /// Plan/27 Wave A — agent harness reported by the PC at pair time.
  /// Surfaced as the "via Pi coding agent" subtitle on the PiCard.
  /// `null` for PeerRecords saved before the field existed; consumers
  /// fall back to [PiHarness.piCodingAgentUnknown] so the UI never
  /// renders an empty subtitle.
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

  Map<String, dynamic> toJson() => {
    'remote_epk': remoteEpk,
    'session_name': sessionName,
    'relay_url': relayUrl,
    'paired_at': pairedAt,
    'nickname': nickname,
    'room_id': roomId,
    if (harness != null) 'harness': harness!.toJson(),
  };

  factory PeerRecord.fromJson(Map<String, dynamic> j) {
    final harnessJson = j['harness'];
    return PeerRecord(
      remoteEpk: j['remote_epk'] as String,
      sessionName: j['session_name'] as String,
      relayUrl: j['relay_url'] as String,
      pairedAt: j['paired_at'] as String,
      // Legacy records (saved before plan 10.3) have no 'nickname' field.
      nickname: j['nickname'] as String?,
      // Legacy records (saved before plan 17 fix) have no 'room_id'.
      // Stays null until ConnectionManager discovers it via subscribe_rooms.
      roomId: j['room_id'] as String?,
      // Plan/27 Wave A — harness was added later. Records saved before
      // it lack the field; null falls back to the default at consumer
      // side.
      harness: harnessJson is Map<String, dynamic>
          ? PiHarness.fromJson(harnessJson)
          : null,
    );
  }

  PeerRecord copyWith({
    String? sessionName,
    // Sentinel-typed so the caller can pass `nickname: null` to clear.
    Object? nickname = _unset,
    Object? roomId = _unset,
    Object? harness = _unset,
  }) => PeerRecord(
    remoteEpk: remoteEpk,
    sessionName: sessionName ?? this.sessionName,
    relayUrl: relayUrl,
    pairedAt: pairedAt,
    nickname: identical(nickname, _unset)
        ? this.nickname
        : nickname as String?,
    roomId: identical(roomId, _unset)
        ? this.roomId
        : roomId as String?,
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

// ---------------------------------------------------------------------------
// PairingStorage
// ---------------------------------------------------------------------------

/// Pairing storage with change notification.
///
/// Mutations to the peer set (`savePeer`, `deletePeer`) and to the
/// per-peer rooms cache (`saveRooms`, `deleteRooms`) call
/// `notifyListeners()` so any UI watching the storage (HomeViewModel,
/// SettingsViewModel) can refresh without manual plumbing between
/// screens. Read methods do not notify.
class PairingStorage extends ChangeNotifier {
  final FlutterSecureStorage _store;
  final Map<String, PeerRecord> _peerCache = {};
  final Set<String> _unresolvedEpks = {};
  bool _cacheHydrated = false;
  bool _indexReadFailed = false;
  /// Plan 24 — optional fire-and-forget hook that runs after every
  /// peer mutation (`savePeer` / `deletePeer`). The `MeshSyncService`
  /// registers this so changes propagate to the relay's
  /// `mesh_versions` row in the background. Failures of the hook are
  /// the hook's problem — local mutation is already committed and
  /// observers were notified by the time the hook fires.
  ///
  /// Room mutations are intentionally NOT hooked — rooms are a
  /// per-device cache, not synced membership.
  void Function()? _onPeersMutated;

  PairingStorage([FlutterSecureStorage? store])
    : _store = store ?? const FlutterSecureStorage();

  /// Plug the mesh-publish callback. The hook fires after the local
  /// write completes and after [notifyListeners], so UI sees the
  /// change before the relay does. Pass `null` to detach.
  void attachPeerMutationHook(void Function()? hook) {
    _onPeersMutated = hook;
  }
  // ---- Peer records --------------------------------------------------------

  String _peerKey(String remoteEpk) => '$_kPeersService:$remoteEpk';

  Future<void> savePeer(PeerRecord record) async {
    await _writePeer(record);
    _onPeersMutated?.call();
  }

  /// Same as [savePeer] but skips the mutation hook. Used by the
  /// MeshSyncService when applying a verified mesh blob to the local
  /// cache — without this we'd round-trip back to the relay
  /// (pull→apply→savePeer→hook→publish) and a race could publish an
  /// empty members list (see plan/24-fix-app-publish-race).
  Future<void> savePeerSilent(PeerRecord record) => _writePeer(record);

  Future<PeerRecord?> loadPeer(String remoteEpk) async {
    final appEpk = toAppEpk(remoteEpk);
    if (_cacheHydrated) {
      if (_peerCache.containsKey(appEpk)) return _peerCache[appEpk];
      if (_peerCache.containsKey(remoteEpk)) return _peerCache[remoteEpk];
    }
    final raw = (await _store.read(key: _peerKey(remoteEpk))) ??
        (appEpk != remoteEpk ? await _store.read(key: _peerKey(appEpk)) : null);
    if (raw == null) return null;
    final record = PeerRecord.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    _peerCache[toAppEpk(record.remoteEpk)] = record;
    return record;
  }

  Future<void> deletePeer(String remoteEpk) async {
    await _erasePeer(remoteEpk);
    _onPeersMutated?.call();
  }

  /// Same as [deletePeer] but skips the mutation hook — see
  /// [savePeerSilent] for the rationale.
  Future<void> deletePeerSilent(String remoteEpk) => _erasePeer(remoteEpk);
  /// Delete ONLY the exact storage key for [exactEpk] without removing
  /// the canonical peer from in-memory cache or durable index.
  /// Used by MeshSyncService to clean up legacy non-canonical keys (e.g. standard b64)
  /// without destroying the newly-written canonical key.
  Future<void> pruneLegacyKeySilent(String exactEpk) async {
    try {
      await _store.delete(key: _peerKey(exactEpk));
    } catch (_) {}
  }
  Future<void> _persistIndex() async {
    final epks = {
      ..._peerCache.values.map((p) => p.remoteEpk),
      ..._unresolvedEpks,
    }.toSet().toList();
    await _store.write(
      key: _kPeersIndexKey,
      value: jsonEncode(epks),
    );
  }

  Future<void> _writePeer(PeerRecord record) async {
    if (!_cacheHydrated) {
      await _hydrateCache();
    }
    if (_indexReadFailed) {
      throw StateError('Cannot mutate peers: storage index is unreadable');
    }
    await _store.write(
      key: _peerKey(record.remoteEpk),
      value: jsonEncode(record.toJson()),
    );
    final appEpk = toAppEpk(record.remoteEpk);
    final epks = {
      ..._peerCache.values.map((p) => p.remoteEpk),
      ..._unresolvedEpks,
      record.remoteEpk,
    }.toSet().toList();
    await _store.write(
      key: _kPeersIndexKey,
      value: jsonEncode(epks),
    );
    _unresolvedEpks.remove(record.remoteEpk);
    _unresolvedEpks.remove(appEpk);
    _peerCache[appEpk] = record;
    notifyListeners();
  }

  Future<void> _erasePeer(String remoteEpk) async {
    if (!_cacheHydrated) {
      await _hydrateCache();
    }
    if (_indexReadFailed) {
      throw StateError('Cannot mutate peers: storage index is unreadable');
    }
    await _store.delete(key: _peerKey(remoteEpk));
    final appEpk = toAppEpk(remoteEpk);
    if (appEpk != remoteEpk) {
      try {
        await _store.delete(key: _peerKey(appEpk));
      } catch (_) {}
    }
    final updatedEpks = _peerCache.values
        .where((p) => p.remoteEpk != remoteEpk && toAppEpk(p.remoteEpk) != appEpk)
        .map((p) => p.remoteEpk)
        .toSet()
        .union(_unresolvedEpks.difference({remoteEpk, appEpk}))
        .toList();
    await _store.write(
      key: _kPeersIndexKey,
      value: jsonEncode(updatedEpks),
    );
    _unresolvedEpks.remove(remoteEpk);
    _unresolvedEpks.remove(appEpk);
    _peerCache.remove(appEpk);
    _peerCache.remove(remoteEpk);
    notifyListeners();
  }

  Future<void> _hydrateCache() async {
    _indexReadFailed = false;
    String? rawIndex;
    try {
      rawIndex = await _store.read(key: _kPeersIndexKey).timeout(
        const Duration(seconds: 2),
      );
    } catch (_) {
      // The index key read itself threw (e.g. storage error, hardware keystore lock).
      // Mark as failed so mutations fail closed instead of overwriting existing peers.
      _indexReadFailed = true;
      return;
    }

    if (rawIndex != null && rawIndex.isNotEmpty) {
      final epks = (jsonDecode(rawIndex) as List<dynamic>).whereType<String>().toSet().toList();
      final Map<String, PeerRecord> loaded = {};
      final failedEpks = <String>{};
      for (final epk in epks) {
        try {
          final raw = await _store.read(key: _peerKey(epk)).timeout(
            const Duration(seconds: 2),
          );
          if (raw != null) {
            final record = PeerRecord.fromJson(jsonDecode(raw) as Map<String, dynamic>);
            loaded[toAppEpk(record.remoteEpk)] = record;
          } else {
            failedEpks.add(epk);
          }
        } catch (_) {
          failedEpks.add(epk);
        }
      }

      _peerCache.addAll(loaded);
      _unresolvedEpks.addAll(failedEpks);

      if (failedEpks.isEmpty) {
        _cacheHydrated = true;
      }
      return;
    }

    // 2. Fallback: enumeration via readAll() (cold migration from legacy versions without index).
    try {
      final all = await _store.readAll().timeout(
        const Duration(seconds: 4),
        onTimeout: () => <String, String>{},
      );
      final prefix = '$_kPeersService:';
      final Map<String, PeerRecord> loaded = {};
      for (final e in all.entries) {
        if (!e.key.startsWith(prefix)) continue;
        try {
          final record = PeerRecord.fromJson(
            jsonDecode(e.value) as Map<String, dynamic>,
          );
          loaded[toAppEpk(record.remoteEpk)] = record;
        } catch (_) {}
      }
      if (loaded.isNotEmpty) {
        _peerCache.addAll(loaded);
        _cacheHydrated = true;
        // Migrate durable index so subsequent boots don't rely on readAll()
        try {
          await _persistIndex();
        } catch (_) {}
        return;
      }
    } catch (_) {}
  }

  Future<List<PeerRecord>> listPeers() async {
    if (!_cacheHydrated) {
      await _hydrateCache();
    }
    if (_unresolvedEpks.isNotEmpty) {
      final toRetry = _unresolvedEpks.toList();
      for (final epk in toRetry) {
        try {
          final raw = await _store.read(key: _peerKey(epk)).timeout(
            const Duration(seconds: 2),
          );
          if (raw != null) {
            final record = PeerRecord.fromJson(jsonDecode(raw) as Map<String, dynamic>);
            _peerCache[toAppEpk(record.remoteEpk)] = record;
            _unresolvedEpks.remove(epk);
            _unresolvedEpks.remove(toAppEpk(epk));
          }
        } catch (_) {}
      }
      if (_unresolvedEpks.isEmpty && !_indexReadFailed) {
        _cacheHydrated = true;
      }
    }
    return _peerCache.values.toList();
  }

  /// Wipe every peer + every persisted room map. Used by the
  /// Owner-key bridge when iCloud / Backup sync brings a different
  /// Owner-pk — the previous device's peer list is meaningless for
  /// the newly-synced identity, so we start clean rather than risk
  /// connecting against stale `remote_epk`s.
  Future<void> wipeAll() async {
    if (!_cacheHydrated) {
      await _hydrateCache();
    }
    // Gather all known EPKs from index/cache and unresolved set so we delete them directly
    final epksToDelete = {
      ..._peerCache.values.map((p) => p.remoteEpk),
      ..._unresolvedEpks,
    }.toList();
    for (final epk in epksToDelete) {
      final appEpk = toAppEpk(epk);
      try {
        await _store.delete(key: _peerKey(epk));
      } catch (_) {}
      if (appEpk != epk) {
        try {
          await _store.delete(key: _peerKey(appEpk));
        } catch (_) {}
      }
      try {
        await _store.delete(key: _roomsKey(epk));
      } catch (_) {}
      if (appEpk != epk) {
        try {
          await _store.delete(key: _roomsKey(appEpk));
        } catch (_) {}
      }
    }

    try {
      await _store.delete(key: _kPeersIndexKey);
    } catch (_) {}

    try {
      final all = await _store.readAll();
      final prefixes = ['$_kPeersService:', '$_kRoomsService:'];
      for (final key in all.keys) {
        if (prefixes.any(key.startsWith)) {
          try {
            await _store.delete(key: key);
          } catch (_) {}
        }
      }
    } catch (_) {}

    _peerCache.clear();
    _unresolvedEpks.clear();
    _cacheHydrated = true;
    _indexReadFailed = false;
    notifyListeners();
  }


  // ---- Rooms (plan 17 follow-up) -----------------------------------------

  String _roomsKey(String remoteEpk) => '$_kRoomsService:$remoteEpk';

  /// Persist the full set of known rooms for a peer. Replaces any
  /// previously stored set. Called on every room-state change in
  /// ConnectionManager so a cold start can reflect the same view.
  Future<void> saveRooms(String remoteEpk, List<PersistedRoom> rooms) async {
    await _store.write(
      key: _roomsKey(remoteEpk),
      value: jsonEncode(rooms.map((r) => r.toJson()).toList()),
    );
    notifyListeners();
  }

  Future<List<PersistedRoom>> loadRooms(String remoteEpk) async {
    final raw = await _store.read(key: _roomsKey(remoteEpk));
    if (raw == null) return const [];
    final list = jsonDecode(raw) as List<dynamic>;
    return list
        .map((e) => PersistedRoom.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<void> deleteRooms(String remoteEpk) async {
    await _store.delete(key: _roomsKey(remoteEpk));
    notifyListeners();
  }
}
