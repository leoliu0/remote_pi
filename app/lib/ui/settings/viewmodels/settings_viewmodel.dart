import 'dart:async';
import 'package:app/data/mesh/mesh_sync_service.dart';
import 'package:app/data/preferences/preferences.dart';
import 'package:app/data/transport/connection_manager.dart';
import 'package:app/data/transport/relay_config.dart';
import 'package:app/pairing/storage.dart';
import 'package:app/pairing/owner_identity_bridge.dart';
import 'package:app/ui/core/viewmodel/viewmodel.dart';
import 'package:app/ui/settings/states/settings_state.dart';

/// Settings is config-only (nickname + revoke). The peer switcher moved
/// to Home; the connection itself is shared and owned by
/// [ConnectionManager] from app boot (plano 12). Revoke side-effect:
/// re-subscribe the relay's presence push so the removed epk is dropped.
class SettingsViewModel extends ViewModel<SettingsState> {
  final PairingStorage _storage;
  final Preferences _prefs;
  final ConnectionManager _conn;

  final MeshSyncService? _meshSync;
  final OwnerIdentityBridge? _ownerBridge;
  bool _disposed = false;

  SettingsViewModel(
    this._storage,
    this._prefs,
    this._conn, [
    this._meshSync,
    this._ownerBridge,
  ]) : super(const SettingsLoading()) {
    _load();
  }

  Future<void> _load() async {
    final peers = await _storage.listPeers();
    if (_disposed) return;
    if (peers.isEmpty) {
      emit(const SettingsNoPeer());
      return;
    }
    emit(SettingsList(peers: peers));
  }

  /// Set or clear the local nickname for the peer at [epk].
  Future<void> setNickname(String epk, String? nickname) async {
    final s = state;
    if (s is! SettingsList) return;
    PeerRecord? target;
    for (final p in s.peers) {
      if (p.remoteEpk == epk) {
        target = p;
        break;
      }
    }
    if (target == null) return;
    final trimmed = nickname?.trim();
    final normalized = (trimmed == null || trimmed.isEmpty) ? null : trimmed;
    final updated = target.copyWith(nickname: normalized);
    await _storage.savePeer(updated, intent: PeerSaveIntent.nickname);
    await _load();
  }

  /// Effective relay URL the app is connecting to right now.
  String get effectiveRelayUrl => resolveRelayUrl(_prefs);

  /// User-set override for the relay URL. If `null`, the app is using the
  /// default endpoint [kDefaultRelayUrl].
  String get relayUrlOverride => _prefs.relayUrl ?? kDefaultRelayUrl;

  Future<String?> saveRelayUrl(
    String? value, {
    bool alwaysReconnect = false,
  }) async {
    var changed = false;
    if (value == null || value.trim().isEmpty) {
      changed = _prefs.relayUrl != null;
      await resetRelayUrl();
    } else {
      final normalized = normalizeRelayUrl(value);
      final reason = relayUrlValidationMessage(normalized);
      if (reason != null) return reason;
      changed = _prefs.relayUrl != normalized;
      await _prefs.setRelayUrl(normalized);
    }

    if (alwaysReconnect || changed) {
      final scopeError = await _activateRelayScope();
      if (scopeError != null) return scopeError;
      unawaited(_resumeRelay());
    }
    return null;
  }

  Future<void> resetRelayUrl() async {
    await _prefs.setRelayUrl(null);
  }

  Future<String?> _activateRelayScope() async {
    final bridge = _ownerBridge;
    if (bridge == null) return null;
    final ownerPk = bridge.currentOwnerPk;
    if (ownerPk == null) {
      return 'Owner identity is unavailable. Retry after reopening the app.';
    }
    await _conn.disconnect();
    try {
      await _storage.initialize(
        ownerPk: ownerPk,
        relayUrl: resolveRelayUrl(_prefs),
      );
      return null;
    } catch (_) {
      return 'Could not open saved data for this relay. Retry to reconnect.';
    }
  }

  Future<void> _resumeRelay() async {
    await _conn.reconnect(preferredEpk: _prefs.selectedPeerEpk);
    final meshSync = _meshSync;
    if (meshSync == null || !await meshSync.synchronize()) return;

    final peers = await _storage.listPeers();
    var selected = _prefs.selectedPeerEpk;
    if (selected == null ||
        !peers.any((peer) => peer.remoteEpk == selected)) {
      selected = peers.isEmpty ? null : peers.first.remoteEpk;
      await _prefs.setSelectedPeerEpk(selected);
    }
    await _conn.reconnect(preferredEpk: selected);
  }

  /// Revoke pairing intentionally. The peer mutation and durable revoke
  /// operation commit together; synchronization can retry after process death.
  Future<void> revoke(String epk) async {
    final wasActive = _conn.activePeer?.remoteEpk == epk;
    if (_prefs.selectedPeerEpk == epk) {
      await _prefs.setSelectedPeerEpk(null);
    }
    await _storage.deletePeer(epk);
    final remaining = await _storage.listPeers();
    await _meshSync?.drainPending();
    _conn.subscribeToPeers(remaining.map((p) => p.remoteEpk).toList());
    if (wasActive) {
      await _conn.disconnect();
      if (remaining.isNotEmpty) {
        final fallback = remaining.first;
        await _prefs.setSelectedPeerEpk(fallback.remoteEpk);
        unawaited(_conn.boot(preferredEpk: fallback.remoteEpk));
      }
    }
    if (remaining.isEmpty) {
      await _prefs.setOnboardingCompleted(false);
    }
    await _load();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
