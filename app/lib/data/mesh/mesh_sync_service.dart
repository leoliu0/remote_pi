import 'dart:async';

import 'package:app/data/transport/epk_encoding.dart';
import 'package:app/pairing/membership_journal.dart';
import 'package:app/pairing/owner_identity_bridge.dart';
import 'package:app/pairing/storage.dart';
import 'package:flutter/foundation.dart';

import 'mesh_blob.dart';
import 'mesh_client.dart';
import 'mesh_envelope.dart';

enum MeshSyncProblem { corruptStoredSnapshot }

/// Serializes verified relay snapshots with explicit, durable local membership
/// intent. The visible peer projection is never used as a publication base.
class MeshSyncService extends ChangeNotifier {
  final MeshClient _client;
  final OwnerIdentityBridge _ownerBridge;
  final PairingStorage _storage;

  Future<void> _serialTail = Future<void>.value();
  Timer? _pollTimer;
  bool _pollTickQueued = false;
  bool _disposed = false;
  MembershipScope? _observedStorageScope;
  int _scopeGeneration = 0;
  int _lastVersion = 0;

  int? lastUpdatedAt;
  MeshSyncProblem? lastProblem;

  MeshSyncService(this._client, this._ownerBridge, this._storage) {
    _observedStorageScope = _storage.membershipScope;
    _loadVisibleState(_observedStorageScope);
    _storage.addListener(_onStorageChanged);
  }

  int get lastVersion => _lastVersion;

  /// Boot/reconnect/resume operation: fetch a verified snapshot, apply it with
  /// pending intent, then drain every durable operation. Calls are serialized.
  Future<bool> synchronize() => _serialized(() async {
        final capture = await _activateCurrentScope();
        if (capture == null) return false;
        final pulled = await _pull(capture);
        if (!pulled || !_isCurrent(capture)) return false;
        return _drain(capture);
      });

  /// Publishes queued intent without allowing another pull/publication to
  /// interleave. The method keeps draining so operations written while a
  /// request is in flight are not accidentally acknowledged or stranded.
  Future<bool> drainPending() => _serialized(() async {
        final capture = await _activateCurrentScope();
        if (capture == null) return false;
        return _drain(capture);
      });

  Future<T> _serialized<T>(Future<T> Function() operation) {
    final previous = _serialTail;
    final released = Completer<void>();
    _serialTail = released.future;
    return () async {
      await previous;
      try {
        return await operation();
      } finally {
        released.complete();
      }
    }();
  }

  Future<_SyncCapture?> _activateCurrentScope() async {
    if (_disposed) return null;
    final ownerPk = _ownerBridge.currentOwnerPk;
    if (ownerPk == null) return null;
    final copiedOwner = Uint8List.fromList(ownerPk);
    final String relay;
    try {
      relay = normalizeMembershipRelayUrl(_client.baseUrlProvider());
    } catch (_) {
      return null;
    }

    await _storage.initialize(ownerPk: copiedOwner, relayUrl: relay);
    final currentOwner = _ownerBridge.currentOwnerPk;
    if (currentOwner == null || !_bytesEqual(currentOwner, copiedOwner)) {
      return null;
    }
    String currentRelay;
    try {
      currentRelay = normalizeMembershipRelayUrl(_client.baseUrlProvider());
    } catch (_) {
      return null;
    }
    if (currentRelay != relay) return null;
    final scope = MembershipScope(ownerPk: copiedOwner, relayUrl: relay);
    if (_storage.membershipScope != scope) return null;
    return _SyncCapture(
      scope: scope,
      ownerPk: copiedOwner,
      generation: _scopeGeneration,
    );
  }

  Future<bool> _pull(_SyncCapture capture) async {
    if (!_isCurrent(capture)) return false;
    final storedSnapshot =
        _storage.verifiedMembershipSnapshot(capture.scope);
    var durable = storedSnapshot;
    var replacingCorruptSnapshot = false;
    if (storedSnapshot != null) {
      final members = await _verifiedMembersFromStoredSnapshot(
        storedSnapshot,
        capture,
      );
      if (!_isCurrent(capture)) return false;
      if (members == null) {
        durable = null;
        replacingCorruptSnapshot = true;
        _setProblem(MeshSyncProblem.corruptStoredSnapshot);
      }
    }

    final hash = await MeshClient.ownerPkHash(capture.ownerPk);
    if (!_isCurrent(capture)) return false;
    final result = await _client.fetch(
      hash,
      since: durable?.version,
    );
    if (!_isCurrent(capture)) return false;

    switch (result) {
      case MeshFetchNotModified():
        if (durable == null) return false;
        _clearProblem();
        return true;
      case MeshFetchNotFound():
        if (replacingCorruptSnapshot) return false;
        if (durable == null) {
          _storage.authorizeLegacyMembershipRecovery(capture.scope);
        }
        // A 404 authorizes only the migration candidate captured separately;
        // it is never treated as a generic empty roster.
        _clearProblem();
        return true;
      case MeshFetchFailure():
        return false;
      case MeshFetchOk(
          envelope: final envelope,
          version: final responseVersion,
          updatedAt: final updatedAt,
        ):
        return _verifyAndApplyFetch(
          capture,
          envelope,
          responseVersion,
          updatedAt,
          durable,
          replaceCorruptSnapshot: replacingCorruptSnapshot,
        );
    }
  }

  Future<bool> _verifyAndApplyFetch(
    _SyncCapture capture,
    MeshEnvelope envelope,
    int responseVersion,
    int updatedAt,
    VerifiedMembershipSnapshot? durable, {
    required bool replaceCorruptSnapshot,
  }) async {
    if (!await MeshBlob.verifyEnvelope(envelope)) return false;
    if (!_isCurrent(capture)) return false;

    final MeshBlob blob;
    try {
      blob = MeshBlob.fromCanonicalBytes(envelope.blob);
    } catch (_) {
      return false;
    }
    if (blob.version != responseVersion ||
        !_bytesEqual(blob.ownerPk, capture.ownerPk) ||
        (durable != null && responseVersion <= durable.version)) {
      return false;
    }
    final members = _membershipMembers(blob);
    if (members == null || !_isCurrent(capture)) return false;

    final snapshot = VerifiedMembershipSnapshot(
      version: responseVersion,
      updatedAt: updatedAt,
      blob: envelope.blob,
      signature: envelope.sig,
    );
    final applied = _storage.applyVerifiedProjection(
      scope: capture.scope,
      members: members,
      snapshot: snapshot,
      replaceCorruptSnapshot: replaceCorruptSnapshot,
    );
    if (!applied || !_isCurrent(capture)) return false;
    _clearProblem();
    _setVisibleState(snapshot);
    return true;
  }

  Future<bool> _drain(_SyncCapture capture) async {
    var conflicts = 0;
    while (_isCurrent(capture)) {
      final operations =
          _storage.pendingMembershipOperations(capture.scope);
      final baseSnapshot =
          _storage.verifiedMembershipSnapshot(capture.scope);
      final List<MembershipMember> baseMembers;
      var publishingRecovery = false;
      if (baseSnapshot != null) {
        final verified = await _verifiedMembersFromStoredSnapshot(
          baseSnapshot,
          capture,
        );
        if (!_isCurrent(capture)) return false;
        if (verified == null) {
          _setProblem(MeshSyncProblem.corruptStoredSnapshot);
          return false;
        }
        baseMembers = verified;
      } else {
        final recovery = _storage.legacyMembershipRecovery(capture.scope);
        if (recovery != null) {
          if (!recovery.authorizedByNotFound) return false;
          baseMembers = recovery.members;
          publishingRecovery = true;
        } else {
          baseMembers = const <MembershipMember>[];
        }
      }
      if (operations.isEmpty && !publishingRecovery) return true;
      final rebased = PairingStorage.rebaseMembership(baseMembers, operations);

      if (rebased.isEmpty &&
          !operations.any(
            (operation) =>
                operation.kind == MembershipOperationKind.revoke,
          )) {
        return false;
      }

      final nextVersion = (baseSnapshot?.version ?? 0) + 1;
      final blob = MeshBlob(
        version: nextVersion,
        issuedAt: DateTime.now().toUtc().millisecondsSinceEpoch,
        ownerPk: capture.ownerPk,
        members: rebased
            .map(
              (member) => MeshMember(
                remoteEpk: toStandardB64(member.remoteEpk),
                relayUrl: member.relayUrl,
                pairedAt: member.pairedAt,
                nickname: member.nickname,
              ),
            )
            .toList(growable: false),
      );
      final keyPair = await _ownerBridge.requireKeyPair();
      if (!_isCurrent(capture)) return false;
      final envelope = await blob.signWith(keyPair);
      if (!_isCurrent(capture)) return false;
      final hash = await MeshClient.ownerPkHash(capture.ownerPk);
      if (!_isCurrent(capture)) return false;
      final result = await _client.publish(hash, envelope);
      if (!_isCurrent(capture)) return false;

      switch (result) {
        case MeshPublishOk(version: final version, updatedAt: final updatedAt):
          if (version != nextVersion) return false;
          final snapshot = VerifiedMembershipSnapshot(
            version: version,
            updatedAt: updatedAt,
            blob: envelope.blob,
            signature: envelope.sig,
          );
          final acknowledged = _storage.acknowledgePublishedSnapshot(
            scope: capture.scope,
            snapshot: snapshot,
            acceptedMembers: rebased,
            capturedSequences:
                operations.map((operation) => operation.sequence),
          );
          if (!acknowledged || !_isCurrent(capture)) return false;
          _clearProblem();
          _setVisibleState(snapshot);
          conflicts = 0;
          continue;
        case MeshPublishConflict():
          conflicts++;
          if (conflicts > 3 || !await _pull(capture)) return false;
          continue;
        case MeshPublishBadRequest():
        case MeshPublishForbidden():
        case MeshPublishTooLarge():
        case MeshPublishFailure():
          return false;
      }
    }
    return false;
  }

  Future<List<MembershipMember>?> _verifiedMembersFromStoredSnapshot(
    VerifiedMembershipSnapshot snapshot,
    _SyncCapture capture,
  ) async {
    final envelope = MeshEnvelope(
      blob: snapshot.blob,
      sig: snapshot.signature,
    );
    if (!await MeshBlob.verifyEnvelope(envelope)) return null;
    if (!_isCurrent(capture)) return null;
    try {
      final blob = MeshBlob.fromCanonicalBytes(snapshot.blob);
      if (blob.version != snapshot.version ||
          !_bytesEqual(blob.ownerPk, capture.ownerPk)) {
        return null;
      }
      return _membershipMembers(blob);
    } catch (_) {
      return null;
    }
  }

  List<MembershipMember>? _membershipMembers(MeshBlob blob) {
    final members = <MembershipMember>[];
    final seen = <String>{};
    for (final member in blob.members) {
      final epk = toAppEpk(member.remoteEpk);
      if (!seen.add(epk)) return null;
      try {
        // member.relayUrl is a legacy signed payload field. The configured
        // MeshClient endpoint, captured separately, owns request scope.
        normalizeMembershipRelayUrl(member.relayUrl);
      } catch (_) {
        return null;
      }
      members.add(
        MembershipMember(
          remoteEpk: epk,
          relayUrl: member.relayUrl,
          pairedAt: member.pairedAt,
          nickname: member.nickname,
        ),
      );
    }
    members.sort((a, b) => a.remoteEpk.compareTo(b.remoteEpk));
    return members;
  }


  bool _isCurrent(_SyncCapture capture) {
    if (_disposed || capture.generation != _scopeGeneration) return false;
    if (_storage.membershipScope != capture.scope) return false;
    final ownerPk = _ownerBridge.currentOwnerPk;
    if (ownerPk == null || !_bytesEqual(ownerPk, capture.ownerPk)) return false;
    try {
      return normalizeMembershipRelayUrl(_client.baseUrlProvider()) ==
          capture.scope.relayUrl;
    } catch (_) {
      return false;
    }
  }

  void _onStorageChanged() {
    final current = _storage.membershipScope;
    if (current == _observedStorageScope) return;
    _observedStorageScope = current;
    _scopeGeneration++;
    _loadVisibleState(current);
    notifyListeners();
  }

  void _loadVisibleState(MembershipScope? scope) {
    lastProblem = null;
    if (scope == null) {
      _lastVersion = 0;
      lastUpdatedAt = null;
      return;
    }
    final snapshot = _storage.verifiedMembershipSnapshot(scope);
    _lastVersion = snapshot?.version ?? 0;
    lastUpdatedAt = snapshot?.updatedAt;
  }

  void _setProblem(MeshSyncProblem problem) {
    if (lastProblem == problem) return;
    lastProblem = problem;
    notifyListeners();
  }

  void _clearProblem() {
    if (lastProblem == null) return;
    lastProblem = null;
    notifyListeners();
  }

  void _setVisibleState(VerifiedMembershipSnapshot snapshot) {
    _lastVersion = snapshot.version;
    lastUpdatedAt = snapshot.updatedAt;
    notifyListeners();
  }

  void startPolling({Duration interval = const Duration(seconds: 60)}) {
    if (_disposed) return;
    stopPolling();
    _pollTimer = Timer.periodic(interval, (_) {
      if (_pollTickQueued || _disposed) return;
      _pollTickQueued = true;
      unawaited(
        synchronize().whenComplete(() {
          _pollTickQueued = false;
        }),
      );
    });
  }

  void stopPolling() {
    _pollTimer?.cancel();
    _pollTimer = null;
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    stopPolling();
    _storage.removeListener(_onStorageChanged);
    _storage.attachPeerMutationHook(null);
    super.dispose();
  }
}

final class _SyncCapture {
  final MembershipScope scope;
  final Uint8List ownerPk;
  final int generation;

  const _SyncCapture({
    required this.scope,
    required this.ownerPk,
    required this.generation,
  });
}

bool _bytesEqual(Uint8List first, Uint8List second) {
  if (first.length != second.length) return false;
  for (var index = 0; index < first.length; index++) {
    if (first[index] != second[index]) return false;
  }
  return true;
}
