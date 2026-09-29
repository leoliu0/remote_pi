// ConnectionManager — lifecycle of the relay connection.
//
// State machine:
//
//   [noPeer] → connect() → [connecting] → success → [online]
//                              ↓                         ↓
//                           failure               (WS close or 2 ping misses)
//                              ↓                         ↓
//                          [offline] ←── canRetry=false
//                          [retrying] ←── backoff 1→2→5→10→30s
//                              ↓
//                          connect() → [connecting] → …
//
// Ping: every 25 s. `_missedPings` increments per tick BEFORE sending the
// next ping; inbound traffic (handled by the channel listener) resets the
// counter back to 0. Two consecutive misses (~50s of silence) → retrying.
//
// Post plan offline-loop (4 patches):
//
//  A) `_channelSub` is stored and cancelled on every transition. The old
//     channel's `onDone` (triggered by the relay killing it on duplicate
//     auth) can no longer leak into a retry storm.
//  B) `_retryAttempt` is no longer reset on factory success — only when
//     the channel listener receives real inbound traffic. With the Pi down
//     the WS keeps re-authenticating against the relay; without this fix
//     the backoff stayed pinned at 1s.
//  C) `_startPing` increments `_missedPings` per tick before sending the
//     ping. Inbound (`_watchChannel` listener) is the only path that
//     zeroes it; with the Pi offline two ticks elapse and we transition
//     to retrying without a leaky-bucket race.

import 'dart:async';

import 'package:app/data/transport/channel.dart';
import 'package:app/data/transport/epk_encoding.dart';
import 'package:app/domain/contracts/service.dart';
import 'package:app/pairing/storage.dart';
import 'package:app/protocol/protocol.dart';

// ---------------------------------------------------------------------------
// Status model
// ---------------------------------------------------------------------------

sealed class ConnectionStatus {
  const ConnectionStatus();
}

class StatusNoPeer extends ConnectionStatus {
  const StatusNoPeer();
}

class StatusConnecting extends ConnectionStatus {
  const StatusConnecting();
}

class StatusOnline extends ConnectionStatus {
  final IChannel channel;
  const StatusOnline(this.channel);
}

class StatusRetrying extends ConnectionStatus {
  final Duration nextRetry;
  final int attempt; // 0-based
  const StatusRetrying({required this.nextRetry, required this.attempt});
}

class StatusOffline extends ConnectionStatus {
  final String reason;
  final bool canRetry;
  const StatusOffline({required this.reason, this.canRetry = true});
}

// ---------------------------------------------------------------------------
// Backoff sequence (seconds)
// ---------------------------------------------------------------------------

const _kBackoff = [1, 2, 5, 10, 30];

Duration _backoffFor(int attempt) =>
    Duration(seconds: _kBackoff[attempt.clamp(0, _kBackoff.length - 1)]);

// ---------------------------------------------------------------------------
// Factory typedef — injectable for tests
// ---------------------------------------------------------------------------

/// Called to establish a new connection for a given peer.
/// Returns an [IChannel] on success, throws on failure.
typedef ConnectionFactory =
    Future<IChannel> Function(PeerRecord peer, CancelToken cancel);

class CancelToken {
  bool _cancelled = false;
  bool get isCancelled => _cancelled;
  void cancel() => _cancelled = true;
}

// ---------------------------------------------------------------------------
// ConnectionManager
// ---------------------------------------------------------------------------

class ConnectionManager extends Service {
  final ConnectionFactory _factory;
  final PairingStorage _storage;

  final _statusController = StreamController<ConnectionStatus>.broadcast();
  // Presence (plano 12): map per remote_epk + a broadcast stream the UI
  // listens to. The map is emitted whole on every change for simple
  // diffing on the consumer side.
  final Map<String, PresenceState> _presence = <String, PresenceState>{};
  final _presenceController =
      StreamController<Map<String, PresenceState>>.broadcast();
  // Plan 17 — rooms tracking. Keys are STANDARD base64 epks (matches
  // presence map). Each value is the canonical room list for that peer.
  // Plan-17 follow-up — `_roomsByPeer` is the CANONICAL set (cached +
  // currently announced). `_liveRoomIds` tracks which roomIds are
  // alive RIGHT NOW (in the relay snapshot). Rooms in `_roomsByPeer`
  // but not in `_liveRoomIds` are "offline" (last-seen state).
  final Map<String, List<RoomInfo>> _roomsByPeer = <String, List<RoomInfo>>{};
  final Map<String, Set<String>> _liveRoomIds = <String, Set<String>>{};
  final _roomsController =
      StreamController<Map<String, List<RoomInfo>>>.broadcast();
  bool _roomsRestored = false;
  bool _liveRoomsKnown = false;
  ConnectionStatus _status = const StatusNoPeer();
  PeerRecord? _activePeer;
  // Plan 17 — active room on the destination Pi. 'main' is the implicit
  // default and matches the per-cwd room a Pi opens.
  String _activeRoomId = 'main';

  Timer? _retryTimer;
  Timer? _pingTimer;
  // Plan-18 follow-up — watchdog timer that periodically checks for
  // "stuck offline" state (active peer set but status not online and
  // no retry / connect in flight). When detected, forces a fresh
  // _scheduleRetry. Belt-and-suspenders against any code path that
  // accidentally drops the retry chain.
  Timer? _watchdogTimer;
  CancelToken? _connectCancel;
  StreamSubscription<ServerMessage>? _channelSub;
  StreamSubscription<ControlInbound>? _controlSub;
  // List currently subscribed for presence (so reconnect can replay it).
  List<String> _subscribedEpks = const [];
  int _missedPings = 0;
  int _retryAttempt = 0;
  // Tracks the last-running connect token so the watchdog can tell
  final Set<String> _unreadFinishedRooms = {};
  // whether a connect is in flight (without poking at the live token).
  bool _connectInFlight = false;
  // Monotonic owner for every connection/scope-changing operation. Async
  // completions and transport callbacks may mutate state only while they own
  // the current generation.
  int _generation = 0;

  // Debounce timers — relay's control-frame firehose (peer_online +
  // presence + rooms snapshots, often dozens per second when multiple
  // devices reconnect) is filtered upstream by the dedup in
  // [_onControl], but legitimate changes still arrive in tight bursts
  // (e.g. cwd switch publishes a new RoomAnnounced + RoomsSnapshot
  // back-to-back). Coalesce those into a single emit per window so
  // downstream listeners (HomeViewModel → Flutter widget rebuilds)
  // see one update instead of three.
  Timer? _presenceEmitTimer;
  Timer? _roomsEmitTimer;
  final Duration _emitDebounce;
  final Duration _workingOffDebounce;
  final Map<String, Timer> _workingOffTimers = <String, Timer>{};

  ConnectionManager({
    required ConnectionFactory factory,
    required PairingStorage storage,
    Duration emitDebounce = const Duration(milliseconds: 50),
    Duration? workingOffDebounce,
  }) : _factory = factory,
       _storage = storage,
       _emitDebounce = emitDebounce,
       _workingOffDebounce = workingOffDebounce ??
           (emitDebounce == Duration.zero
               ? Duration.zero
               : const Duration(milliseconds: 350)) {
    _startWatchdog();
  }

  /// Plan-18 follow-up — periodically checks for stuck offline state
  /// and forces a reconnect attempt. Runs every 15s. Cheap; only
  /// fires the actual `_scheduleRetry` when the conditions match.
  void _startWatchdog() {
    _watchdogTimer?.cancel();
    _watchdogTimer = Timer.periodic(const Duration(seconds: 15), (_) {
      final peer = _activePeer;
      if (peer == null) return;
      if (_status is StatusOnline) return;
      if (_connectInFlight) return;
      if (_retryTimer != null) return;
      _scheduleRetry(peer, _generation);
    });
  }

  int _claimOwnership() {
    _generation++;
    _presenceEmitTimer?.cancel();
    _presenceEmitTimer = null;
    _roomsEmitTimer?.cancel();
    _roomsEmitTimer = null;
    for (final timer in _workingOffTimers.values) {
      timer.cancel();
    }
    _workingOffTimers.clear();
    return _generation;
  }

  bool _owns(int generation) => generation == _generation;

  void _clearLiveState() {
    _presence.clear();
    _liveRoomIds.clear();
    _liveRoomsKnown = false;
    if (!_presenceController.isClosed) {
      _presenceController.add(presenceSnapshot);
    }
    if (!_roomsController.isClosed) {
      _roomsController.add(_roomsSnapshot());
    }
  }

  ConnectionStatus get status => _status;
  Stream<ConnectionStatus> get statusStream => _statusController.stream;

  IChannel? get channel =>
      _status is StatusOnline ? (_status as StatusOnline).channel : null;

  /// The peer this manager is currently driving (online, connecting, or
  /// retrying). Null when there is no active peer (NoPeer / Offline-noRetry
  /// / fresh after disconnect()).
  PeerRecord? get activePeer => _activePeer;

  // ---- Presence (plano 12) -------------------------------------------------

  /// Stream of full presence-map snapshots. Subscribers should treat each
  /// event as the canonical state for all keys present in the map.
  Stream<Map<String, PresenceState>> get presenceStream =>
      _presenceController.stream;

  /// Current presence for an epk (or [PresenceUnknown] if never observed).
  /// Accepts either url-safe (PairingStorage) or standard base64; the map
  /// itself is keyed in standard form (see [_onControl]).
  PresenceState presenceFor(String epk) =>
      _presence[toStandardB64(epk)] ?? const PresenceUnknown();

  /// Full snapshot copy of the current presence map. Keys are standard
  /// base64 — UI code that compares against `PeerRecord.remoteEpk`
  /// (url-safe) should also call [toStandardB64] before lookup. The Home
  /// tile / chat resolver do this via [presenceFor].
  Map<String, PresenceState> get presenceSnapshot =>
      Map.unmodifiable(_presence);

  // ---- Rooms (plan 17) -----------------------------------------------------

  /// Stream of full room-map snapshots. Each event is the canonical
  /// list of rooms per peer (standard-base64 keys).
  Stream<Map<String, List<RoomInfo>>> get roomsStream =>
      _roomsController.stream;

  Map<String, List<RoomInfo>> get roomsSnapshot => _roomsSnapshot();

  /// Hydrate cached rooms from disk. Home waits on this before leaving
  /// [HomeLoading] so the Online tab cannot flash empty ahead of cache.
  Future<void> ensureCachedRoomsRestored() => _restoreCachedRooms();

  /// True after the relay has delivered at least one rooms snapshot or
  /// room_announced for a subscribed peer. Distinguishes "no live rooms"
  /// from "we have not heard yet".
  bool get liveRoomsKnown => _liveRoomsKnown;

  /// Rooms for a single peer (or empty list if none known yet). Accepts
  /// url-safe or standard base64.
  List<RoomInfo> roomsFor(String epk) =>
      List.unmodifiable(_roomsByPeer[toStandardB64(epk)] ?? const []);

  /// Active destination room (the Pi-side room id). 'main' = default.
  String get activeRoomId => _activeRoomId;

  /// Switch the destination room WITHOUT closing the current WS. The
  /// outer envelope's `room` field on subsequent sends will carry this
  /// value. Use when the user taps a different Pi cwd on Home.
  void switchRoom(String roomId) {
    if (roomId == _activeRoomId) {
      return;
    }
    _activeRoomId = roomId;
    final active = _activePeer;
    if (active != null) {
      _activePeer = active.copyWith(roomId: roomId);
    }
    // Push down to the underlying WS transport so outbound envelopes
    // get the right `room` value.
    final cur = _status;
    if (cur is StatusOnline) {
      _propagateActiveRoom(roomId, cur.channel);
    }
    // Re-emit the rooms snapshot so derived per-active-room state
    // (ActionsRepository.activeRoomMeta → the Quick Actions sheet's current
    // model/thinking) recomputes for the NEW room. Switching cwd-rooms on the
    // same Mac doesn't change status/rooms otherwise, so without this the
    // sheet kept showing the previous chat's model.
    if (!_roomsController.isClosed) {
      _roomsController.add(_roomsSnapshot());
    }
  }
  /// Called when the app returns to foreground from background/pause.
  /// Cancels long backoff delays, resets missed pings, and immediately
  /// verifies the active socket or reconnects instantly.
  void onAppResumed() {
    _retryAttempt = 0;
    _missedPings = 0;
    _cancelRetry();
    final active = _activePeer;
    if (active == null) return;

    if (_status case StatusOnline(:final channel)) {
      final observedGeneration = _generation;
      unawaited(
        channel.send(Ping(id: _newId())).catchError((Object _) {
          if (_owns(observedGeneration)) {
            final generation = _claimOwnership();
            unawaited(_connect(active, generation));
          }
        }),
      );
    } else {
      final generation = _claimOwnership();
      unawaited(_connect(active, generation));
    }
  }

  void _propagateActiveRoom(String roomId, IChannel link) {
    // Sends a synthetic control frame ourselves NOT to the relay — we
    // just need a hook into the transport. PlainPeerChannel exposes
    // `setActiveRoom` via a hidden interface; for typing simplicity we
    // try the dynamic call. If the transport doesn't support it, we
    // silently skip and the default 'main' room is used.
    try {
      (link as dynamic).setActiveRoom(roomId);
    } catch (_) {
      // Tests / non-WS transports — fine to ignore.
    }
  }

  /// Subscribe (or re-subscribe) the relay to push presence AND room
  /// updates for [epks] (`peer_online` / `peer_offline` and
  /// `room_announced` / `room_ended` / `rooms` snapshot). Idempotent.
  /// Stored so the subscription is replayed automatically on
  /// reconnect via [_replaySubscriptions].
  ///
  /// Both subscriptions are sent together — historically this method
  /// only emitted `subscribe_presence`, which left a hole after the
  /// first pairing: `adopt()` runs before [_BootState] has had a
  /// chance to call this with the new peer, so `_subscribedEpks` is
  /// empty and `_replaySubscriptions` short-circuits. Home then
  /// subscribed (here) for presence only — never asking the relay to
  /// push rooms — and the first session tile only appeared after the
  /// next cold start (when boot() runs the full subscribe + connect
  /// path). Keeping presence/rooms in lockstep here closes that hole.
  ///
  /// IMPORTANT: every epk on the wire is base64 STANDARD — the relay's
  /// registry is keyed by what comes in `hello.pubkey` (always standard).
  /// Callers may pass url-safe (PairingStorage default) and we normalise
  /// once here. The internal cache (`_subscribedEpks`, `_presence` keys)
  /// is also kept in standard form so lookups don't have to coerce again.
  /// See `epk_encoding.dart` for the recurring-bug history.
  void subscribeToPeers(List<String> epks) {
    final standard = epks.map(toStandardB64).toList();
    _subscribedEpks = standard;
    final link = _controlLink;
    if (link == null) {
      return;
    }
    link.sendControl(subscribePresenceFrame(standard));
    link.sendControl(subscribeRoomsFrame(standard));
    if (standard.isNotEmpty) {
      link.sendControl(presenceCheckFrame(standard));
      link.sendControl(roomsCheckFrame(standard));
    }
  }

  /// One-shot snapshot request without changing the subscription.
  void refreshPresence([List<String>? epks]) {
    final link = _controlLink;
    if (link == null) return;
    final list = (epks ?? _subscribedEpks).map(toStandardB64).toList();
    if (list.isEmpty) return;
    link.sendControl(presenceCheckFrame(list));
  }

  /// Current online channel cast to its control side, when supported.
  IControlLink? get _controlLink {
    final s = _status;
    if (s is! StatusOnline) return null;
    final ch = s.channel;
    return ch is IControlLink ? ch as IControlLink : null;
  }

  /// Open the WS and start driving a peer. Accepts an optional
  /// [preferredEpk] (plano 13) so the caller can express the user's
  /// authoritative choice — typically `Preferences.selectedPeerEpk`.
  /// When the preferred epk is not in storage (or omitted), falls back
  /// to `peers.first`.
  ///
  /// No-op when there is already an active peer (online, connecting, or
  /// retrying). In that case we still re-subscribe presence with the
  /// full peer list, since the storage may have changed.
  Future<void> boot({String? preferredEpk}) async {
    final restoreGeneration = _generation;
    await _restoreCachedRooms(expectedGeneration: restoreGeneration);
    if (!_owns(restoreGeneration)) return;

    // A chat-triggered switch/connect or disconnect owns the coordinator.
    // Boot must never resume after cache hydration under a newer generation.
    if (_activePeer != null) {
      final peers = await _storage.listPeers();
      if (!_owns(restoreGeneration)) return;
      subscribeToPeers(peers.map((p) => p.remoteEpk).toList());
      return;
    }
    if (_status is StatusOnline) return;

    final generation = _claimOwnership();
    final peers = await _storage.listPeers();
    if (!_owns(generation)) return;
    if (peers.isEmpty) {
      _activePeer = null;
      _emit(const StatusNoPeer());
      return;
    }
    subscribeToPeers(peers.map((p) => p.remoteEpk).toList());
    PeerRecord target;
    if (preferredEpk != null) {
      final clean = preferredEpk.split(':').first;
      target = peers.firstWhere(
        (p) =>
            p.remoteEpk == preferredEpk ||
            p.remoteEpk == clean ||
            toStandardB64(p.remoteEpk) == toStandardB64(clean),
        orElse: () => peers.first,
      );
    } else {
      target = peers.first;
    }
    await _connect(target, generation);
  }

  // Connect to a specific peer (used after fresh pairing).
  Future<void> connectTo(PeerRecord peer) {
    final generation = _claimOwnership();
    return _connect(peer, generation);
  }

  /// Force an immediate reconnection with the current/preferred peer.
  /// Used when the relay endpoint or network settings change, so the
  /// app reconnects immediately without requiring an app restart.
  Future<void> reconnect({String? preferredEpk}) async {
    final generation = _claimOwnership();
    _cancelRetry();
    _cancelPing();
    _connectCancel?.cancel();
    _clearLiveState();

    final peers = await _storage.listPeers();
    if (!_owns(generation)) return;
    await _restoreCachedRooms(
      peers: peers,
      force: true,
      expectedGeneration: generation,
    );
    if (!_owns(generation)) return;
    if (peers.isEmpty) {
      await _teardownActive(emitNoPeer: true, generation: generation);
      return;
    }

    final target = preferredEpk != null
        ? peers.firstWhere(
            (p) {
              final clean = preferredEpk.split(':').first;
              return p.remoteEpk == preferredEpk ||
                  p.remoteEpk == clean ||
                  toStandardB64(p.remoteEpk) == toStandardB64(clean);
            },
            orElse: () => _activePeer ?? peers.first,
          )
        : (_activePeer ?? peers.first);

    subscribeToPeers(peers.map((p) => p.remoteEpk).toList());
    await _teardownActive(emitNoPeer: false, generation: generation);
    if (!_owns(generation)) return;
    await _connect(target, generation);
  }

  /// Idempotent switch to another paired peer. If `peer` already matches
  /// [activePeer] AND we are Online, no-op. Otherwise tears down the
  /// current channel WITHOUT emitting a transient `StatusNoPeer` (plano
  /// 13) and starts a fresh connection — the visible transition becomes
  /// `Online → Connecting → Online`, never landing on NoPeer.
  Future<void> switchTo(PeerRecord peer) async {
    final fromEpk = _activePeer?.remoteEpk;
    if (fromEpk == peer.remoteEpk && _status is StatusOnline) {
      return;
    }
    final generation = _claimOwnership();
    await _teardownActive(emitNoPeer: false, generation: generation);
    if (!_owns(generation)) return;
    await _connect(peer, generation);
  }
  // Adopt a channel that was established by an external flow (e.g. the
  // pairing handshake). Skips the factory entirely — the channel is already
  // connected and ready for use.
  void adopt(IChannel channel, PeerRecord peer) {
    _claimOwnership();
    _cancelRetry();
    _cancelPing();
    _connectCancel?.cancel();
    _channelSub?.cancel();
    _channelSub = null;
    _controlSub?.cancel();
    _controlSub = null;
    if (_status case StatusOnline(channel: final oldChannel)) {
      unawaited(oldChannel.close().catchError((Object _) {}));
    }
    _retryAttempt = 0;
    _missedPings = 0;
    _activePeer = peer;
    _emit(StatusOnline(channel));
    final generation = _generation;
    _startPing(peer, channel, generation);
    _watchChannel(peer, channel, generation);
    _watchControl(channel, generation);
    _replaySubscriptions();
  }

  // Permanently disconnect and go to NoPeer.
  Future<void> disconnect() {
    final generation = _claimOwnership();
    return _teardownActive(emitNoPeer: true, generation: generation);
  }

  /// Shared implementation between [disconnect] and [switchTo]. When
  /// [emitNoPeer] is false (switch path), the `_status` is left as-is so
  /// a subsequent `_connect` can emit `StatusConnecting` directly,
  /// avoiding the visible Online → NoPeer → Connecting flicker that used
  /// to trip up `ChatViewModel._bootstrap`.
  Future<void> _teardownActive({
    required bool emitNoPeer,
    required int generation,
  }) async {
    if (!_owns(generation)) return;
    _cancelRetry();
    _cancelPing();
    _connectCancel?.cancel();
    _channelSub?.cancel();
    _channelSub = null;
    _controlSub?.cancel();
    _controlSub = null;
    final activeChannel =
        _status is StatusOnline ? (_status as StatusOnline).channel : null;
    if (activeChannel != null) {
      try {
        await activeChannel.close();
      } catch (_) {}
    }
    if (!_owns(generation)) return;
    if (emitNoPeer) {
      _activePeer = null;
      _roomsRestored = false;
      _clearLiveState();
      _emit(const StatusNoPeer());
    }
  }

  @override
  void dispose() {
    final activeChannel =
        _status is StatusOnline ? (_status as StatusOnline).channel : null;
    _claimOwnership();
    _cancelRetry();
    _cancelPing();
    _connectCancel?.cancel();
    _connectInFlight = false;
    _watchdogTimer?.cancel();
    _watchdogTimer = null;
    _presenceEmitTimer?.cancel();
    _presenceEmitTimer = null;
    _roomsEmitTimer?.cancel();
    _roomsEmitTimer = null;
    for (final t in _workingOffTimers.values) {
      t.cancel();
    }
    _workingOffTimers.clear();
    _channelSub?.cancel();
    _channelSub = null;
    _controlSub?.cancel();
    _controlSub = null;
    _activePeer = null;
    if (activeChannel != null) {
      unawaited(activeChannel.close().catchError((Object _) {}));
    }
    _statusController.close();
    _presenceController.close();
    _roomsController.close();
  }
  // ---------------------------------------------------------------------------

  Future<void> _connect(PeerRecord peer, int generation) async {
    if (!_owns(generation)) return;
    _cancelRetry();
    _cancelPing();
    _connectCancel?.cancel();
    _channelSub?.cancel();
    _channelSub = null;
    _controlSub?.cancel();
    _controlSub = null;

    final token = CancelToken();
    _connectCancel = token;
    _connectInFlight = true;
    final samePeer = _activePeer?.remoteEpk == peer.remoteEpk;
    if (samePeer && _activePeer?.roomId != null) {
      _activePeer = peer.copyWith(roomId: _activeRoomId);
    } else {
      _activePeer = peer;
      final boundRoom = peer.roomId ?? 'main';
      if (boundRoom != _activeRoomId) {
        _activeRoomId = boundRoom;
      }
    }
    _emit(const StatusConnecting());

    try {
      final ch = await _factory(peer, token);
      if (token.isCancelled || !_owns(generation)) {
        await ch.close();
        return;
      }
      _missedPings = 0;
      _propagateActiveRoom(_activeRoomId, ch);
      _emit(StatusOnline(ch));
      _startPing(peer, ch, generation);
      _watchChannel(peer, ch, generation);
      _watchControl(ch, generation);
      _replaySubscriptions();
    } catch (_) {
      if (!token.isCancelled && _owns(generation)) {
        _scheduleRetry(peer, generation);
      }
    } finally {
      if (identical(_connectCancel, token)) _connectInFlight = false;
    }
  }

  void _watchControl(IChannel ch, int generation) {
    _controlSub?.cancel();
    final control = ch is IControlLink ? ch as IControlLink : null;
    if (control == null) {
      _controlSub = null;
      return;
    }
    _controlSub = control.controlFrames.listen(
      (event) => _onControl(event, ch, generation),
    );
  }

  void _onControl(ControlInbound c, IChannel source, int generation) {
    if (!_owns(generation)) return;
    final status = _status;
    if (status is! StatusOnline || !identical(status.channel, source)) {
      return;
    }
    // Relay-reported epks are base64 STANDARD (they came in from the
    // remote peer's `hello.pubkey`). Normalise once on insert so the map
    // is always keyed in the same canonical form regardless of what we
    // received on the wire — and so consumer-side lookups via
    // `presenceFor` (which coerces) round-trip.
    //
    // Dedup contract: relay re-pushes `peer_online`, `presence`, and
    // `rooms` aggressively (every reconnect of every device, every
    // pi-extension restart, periodically as keep-alive). Without
    // de-duplication every push fires `_presenceController` /
    // `_roomsController`, which propagates to `HomeViewModel`, which
    // rebuilds the whole list, which keeps the CPU busy and the
    // device hot. Each case below only flips its `*Dirty` flag if
    // the incoming payload actually changes our cached view.
    var presenceDirty = false;
    var roomsDirty = false;
    switch (c) {
      case PeerOnline(:final peer):
        final key = toStandardB64(peer);
        final prev = _presence[key];
        const next = PresenceOnline();
        if (!_presenceEquals(prev, next)) {
          _presence[key] = next;
          presenceDirty = true;
        }
      case PeerOffline(:final peer, :final sinceTs):
        final key = toStandardB64(peer);
        final prev = _presence[key];
        final next = PresenceOffline(sinceTs: sinceTs);
        if (!_presenceEquals(prev, next)) {
          _presence[key] = next;
          presenceDirty = true;
        }
      case PresenceSnapshot(:final states):
        for (final s in states) {
          final key = toStandardB64(s.peer);
          final prev = _presence[key];
          final next = s.online
              ? PresenceOnline(sinceTs: s.sinceTs)
              : PresenceOffline(sinceTs: s.sinceTs);
          if (!_presenceEquals(prev, next)) {
            _presence[key] = next;
            presenceDirty = true;
          }
        }
      case RoomAnnounced(
        :final peer,
        :final roomId,
        :final name,
        :final cwd,
        :final startedAt,
        :final model,
        :final thinking,
        :final working,
        :final goal,
        :final loop,
        :final plan,
      ):
        final key = toStandardB64(peer);
        final list = _roomsByPeer[key] ?? <RoomInfo>[];
        // Preserve any localName the user already set for this room
        // (long-press rename) — only the live metadata comes from the
        // wire, the rename is local-only.
        String? preservedName;
        // Plan/28 Wave D — also preserve a previously-learned thinking
        // level when the announce frame omits it. Relays that don't
        // flatten `meta.thinking` will keep `thinking == null` here;
        // the previously cached value (if any) survives until the
        // next genuine `room_meta_updated`.
        ThinkingLevel? preservedThinking;
        // Plan/32 — same preserve convention for `working`: a legacy
        // relay that omits it (null) keeps the cached value instead of
        // forcing the room back to idle.
        var preservedWorking = false;
        String? preservedGoal;
        String? preservedLoop;
        String? preservedPlan;
        final existingIdx = list.indexWhere((r) => r.roomId == roomId);
        if (existingIdx >= 0) {
          preservedName = list[existingIdx].name;
          preservedThinking = list[existingIdx].thinking;
          preservedWorking = list[existingIdx].working;
          preservedGoal = list[existingIdx].goal;
          preservedLoop = list[existingIdx].loop;
          preservedPlan = list[existingIdx].plan;
        }
        final next = RoomInfo(
          roomId: roomId,
          name: preservedName ?? name,
          cwd: cwd,
          startedAt: startedAt,
          model: model,
          thinking: thinking ?? preservedThinking,
          working: working ?? preservedWorking,
          goal: goal ?? preservedGoal,
          loop: loop ?? preservedLoop,
          plan: plan ?? preservedPlan,
        );
        final liveAlready = _liveRoomIds[key]?.contains(roomId) ?? false;
        final identicalEntry = existingIdx >= 0 && list[existingIdx] == next;
        if (identicalEntry && liveAlready) {
          // No-op announce — relay re-broadcast. Skip to keep the UI
          // quiet.
          break;
        }
        list.removeWhere((r) => r.roomId == roomId);
        list.add(next);
        _roomsByPeer[key] = list;
        (_liveRoomIds[key] ??= <String>{}).add(roomId);
        _liveRoomsKnown = true;
        roomsDirty = true;
        // Persist the new view so cold restart shows the same tiles.
        // ignore: unawaited_futures
        _persistRoomsForPeer(key, generation);
        // Plan 17 fix — legacy discovery: if the active peer has no
        // persisted roomId yet (PeerRecord saved before this fix or
        // QR without `rm`), adopt the first room we learn about as
        // the canonical one. Persists the choice on the PeerRecord
        // so future reconnects address it directly.
        _maybeAdoptLegacyRoom(key, roomId, generation);
      case RoomEnded(:final peer, :final roomId):
        final key = toStandardB64(peer);
        // Mark the room offline but KEEP it in the cached set so the
        // tile stays in Home (now grey). Removing from _liveRoomIds
        // is enough.
        final removed = _liveRoomIds[key]?.remove(roomId) ?? false;
        if (_liveRoomIds[key]?.isEmpty ?? false) {
          _liveRoomIds.remove(key);
        }
        if (removed) roomsDirty = true;
      case RoomMetaUpdated(
        :final peer,
        :final roomId,
        :final model,
        :final thinking,
        :final working,
        :final goal,
        :final loop,
        :final plan,
        :final hasModel,
        :final hasThinking,
        :final hasGoal,
        :final hasLoop,
        :final hasPlan,
      ):
        final key = toStandardB64(peer);
        final list = _roomsByPeer[key];
        if (list == null) break;
        final idx = list.indexWhere((r) => r.roomId == roomId);
        if (idx < 0) break;
        final current = list[idx];
        // Plan/28 Wave D — meta is open-ended; only update the fields
        // the broadcast actually carried. `hasModel` / `hasThinking`
        // distinguishes "field was absent from the meta envelope"
        // (preserve previous value) from "field was explicitly null"
        // (overwrite with null). Without this, a thinking-only update
        // would clobber the previously cached model with null.
        final nextModel = hasModel ? model : current.model;
        final nextThinking = hasThinking ? thinking : current.thinking;
        final nextGoal = hasGoal ? goal : current.goal;
        final nextLoop = hasLoop ? loop : current.loop;
        final nextPlan = hasPlan ? plan : current.plan;
        if (working == true) {
          _workingOffTimers.remove('$key:$roomId')?.cancel();
          _unreadFinishedRooms.remove('$key:$roomId');
          if (current.model == nextModel &&
              current.thinking == nextThinking &&
              current.goal == nextGoal &&
              current.loop == nextLoop &&
              current.plan == nextPlan &&
              current.working == true) {
            break;
          }
          list[idx] = current.copyWith(
            model: nextModel,
            thinking: nextThinking,
            goal: nextGoal,
            loop: nextLoop,
            plan: nextPlan,
            working: true,
          );
          roomsDirty = true;
          // ignore: unawaited_futures
          _persistRoomsForPeer(key, generation);
        } else if (working == false) {
          if (hasModel || hasThinking || hasGoal || hasLoop || hasPlan) {
            list[idx] = current.copyWith(
              model: nextModel,
              thinking: nextThinking,
              goal: nextGoal,
              loop: nextLoop,
              plan: nextPlan,
            );
          }
          if (current.working) {
            _scheduleRoomWorkingOff(key, roomId, generation);
          }
        } else {
          if (current.model == nextModel &&
              current.thinking == nextThinking &&
              current.goal == nextGoal &&
              current.loop == nextLoop &&
              current.plan == nextPlan) {
            break;
          }
          list[idx] = current.copyWith(
            model: nextModel,
            thinking: nextThinking,
            goal: nextGoal,
            loop: nextLoop,
            plan: nextPlan,
          );
          roomsDirty = true;
          // ignore: unawaited_futures
          _persistRoomsForPeer(key, generation);
        }
      case RoomsSnapshot(:final peer, :final rooms):
        _liveRoomsKnown = true;
        final key = toStandardB64(peer);
        final existing = _roomsByPeer[key] ?? <RoomInfo>[];
        final byId = {for (final r in existing) r.roomId: r};
        for (final r in rooms) {
          final preservedName = byId[r.roomId]?.name ?? r.name;
          final preservedThinking = r.thinking ?? byId[r.roomId]?.thinking;
          final preservedGoal = r.goal ?? byId[r.roomId]?.goal;
          final preservedLoop = r.loop ?? byId[r.roomId]?.loop;
          final preservedPlan = r.plan ?? byId[r.roomId]?.plan;
          final hasActiveWorkingTimer =
              _workingOffTimers.containsKey('$key:${r.roomId}');
          final effectiveWorking =
              hasActiveWorkingTimer ? true : r.working;
          if (r.working) {
            _workingOffTimers.remove('$key:${r.roomId}')?.cancel();
          }
          byId[r.roomId] = RoomInfo(
            roomId: r.roomId,
            name: preservedName,
            cwd: r.cwd,
            startedAt: r.startedAt,
            model: r.model ?? byId[r.roomId]?.model,
            thinking: preservedThinking,
            working: effectiveWorking,
            goal: preservedGoal,
            loop: preservedLoop,
            plan: preservedPlan,
          );
        }
        final newList = byId.values.toList();
        final newLive = rooms.map((r) => r.roomId).toSet();
        final liveChanged = !_setEquals(
          newLive,
          _liveRoomIds[key] ?? const <String>{},
        );
        final listChanged = !_roomListEquals(newList, existing);
        if (!liveChanged && !listChanged) {
          // Relay re-emitted a snapshot identical to what we already
          // have. Skip — no listeners need to know.
          break;
        }
        _roomsByPeer[key] = newList;
        _liveRoomIds[key] = newLive;
        roomsDirty = true;
        // ignore: unawaited_futures
        _persistRoomsForPeer(key, generation);
        // Same legacy-discovery hook as RoomAnnounced.
        if (rooms.isNotEmpty) {
          _maybeAdoptLegacyRoom(key, rooms.first.roomId, generation);
        }
    }
    if (presenceDirty) _schedulePresenceEmit();
    if (roomsDirty) _scheduleRoomsEmit();
  }

  /// Coalesce presence emits within `_emitDebounce`. Each call resets
  /// the timer; the snapshot sent at fire time is whatever `_presence`
  /// looks like then (always the latest view).
  void _schedulePresenceEmit() {
    _presenceEmitTimer?.cancel();
    _presenceEmitTimer = Timer(_emitDebounce, () {
      _presenceEmitTimer = null;
      if (_presenceController.isClosed) return;
      _presenceController.add(Map.unmodifiable(_presence));
    });
  }

  /// Same shape as [_schedulePresenceEmit] but for the rooms stream.
  void _scheduleRoomsEmit() {
    _roomsEmitTimer?.cancel();
    _roomsEmitTimer = Timer(_emitDebounce, () {
      _roomsEmitTimer = null;
      if (_roomsController.isClosed) return;
      _roomsController.add(_roomsSnapshot());
    });
  }

  /// Value-equality helper for [PresenceState] — the sealed classes
  /// don't define their own `==`, and identity equality misfires
  /// because we construct fresh `PresenceOnline(...)` / `PresenceOffline(...)`
  /// objects on each control frame.
  bool _presenceEquals(PresenceState? a, PresenceState? b) {
    if (a == null) return b == null;
    if (b == null) return false;
    if (a.runtimeType != b.runtimeType) return false;
    if (a is PresenceOnline && b is PresenceOnline) {
      return a.sinceTs == b.sinceTs;
    }
    if (a is PresenceOffline && b is PresenceOffline) {
      return a.sinceTs == b.sinceTs;
    }
    // PresenceUnknown has no fields — same type ⇒ equal.
    return true;
  }

  /// `Set<String>` deep-equality (Dart sets don't have value-equality
  /// by default).
  bool _setEquals(Set<String> a, Set<String> b) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    for (final x in a) {
      if (!b.contains(x)) return false;
    }
    return true;
  }

  /// `List<RoomInfo>` order-insensitive equality keyed by `roomId`.
  /// `RoomInfo` already defines value `==`.
  bool _roomListEquals(List<RoomInfo> a, List<RoomInfo> b) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    final byIdB = {for (final r in b) r.roomId: r};
    for (final r in a) {
      if (byIdB[r.roomId] != r) return false;
    }
    return true;
  }

  Map<String, List<RoomInfo>> _roomsSnapshot() => Map.unmodifiable(
    _roomsByPeer.map((k, v) => MapEntry(k, List<RoomInfo>.unmodifiable(v))),
  );

  /// Returns `true` if `roomId` is currently announced live for the
  /// peer. Gated by `_status is StatusOnline` so Home tiles and the
  /// chat AppBar go grey immediately when the WS drops.
  bool isRoomLive(String epk, String roomId) {
    if (_status is! StatusOnline) return false;
    return isRoomInLiveSet(epk, roomId);
  }

  /// Last relay live-set membership, ignoring WS status. Home's Online
  /// filter uses this so a reconnect cannot empty the tab.
  bool isRoomInLiveSet(String epk, String roomId) {
    final live = _liveRoomIds[toStandardB64(epk)];
    return live != null && live.contains(roomId);
  }

  /// Plan/59 — actually QUIT a Pi-side session from a Home tile.
  ///
  /// Sends `/exit` as a user_message to the target room: the extension's
  /// terminal-input interceptor executes slash commands in the TUI, and
  /// omp's `/exit` ends that agent process cleanly (room goes away on the
  /// relay, so every device drops the tile). The transport's outer-envelope
  /// room is targeted and restored WITHOUT touching `_activeRoomId` /
  /// `_activePeer` / the writer binding — no UI churn, no session switch.
  /// The `/exit` echo is then dropped by the inbound room-mismatch guard
  /// unless the user is quitting the room they currently have open.
  ///
  /// Returns `false` (send skipped, caller may still delete the local tile)
  /// when the relay link is down or the room is not in the live set.
  bool quitRoom(String epk, String roomId) {
    final cur = _status;
    if (cur is! StatusOnline) return false;
    if (!isRoomInLiveSet(epk, roomId)) return false;
    final prev = _activeRoomId;
    _propagateActiveRoom(roomId, cur.channel);
    try {
      cur.channel.send(UserMessage(id: _newId(), text: '/exit'));
    } catch (_) {
      _propagateActiveRoom(prev, cur.channel);
      return false;
    }
    _propagateActiveRoom(prev, cur.channel);
    return true;
  }

  /// Restart a Pi-side session from a Home tile or Quick Actions.
  ///
  /// Sends `/restart` as a user_message to the target room: the extension's
  /// terminal-input interceptor executes slash commands in the TUI, and
  /// omp's `/restart` restarts with the same launch flags, resuming the session.
  ///
  /// Returns `false` (send skipped) when the relay link is down or the room
  /// is not in the live set.
  bool restartRoom(String epk, String roomId) {
    final cur = _status;
    if (cur is! StatusOnline) return false;
    if (!isRoomInLiveSet(epk, roomId)) return false;
    final prev = _activeRoomId;
    _propagateActiveRoom(roomId, cur.channel);
    try {
      cur.channel.send(UserMessage(id: _newId(), text: '/restart'));
    } catch (_) {
      _propagateActiveRoom(prev, cur.channel);
      return false;
    }
    _propagateActiveRoom(prev, cur.channel);
    return true;
  }


  /// Plan/32 — `true` when the relay's last room-meta broadcast for
  /// `(epk, roomId)` carried `working: true` (an in-flight agent turn).
  /// Unlike the DB session-index signal (which only covers the single
  /// connected room), this reflects EVERY subscribed room because the
  /// relay broadcasts `meta.working` to all room subscribers — the same
  /// fan-out as presence. Drives the blue Home dot on non-active
  /// sessions.
  ///
  /// Gated on `StatusOnline` (same as [isRoomLive]): a dropped WS means
  /// we have no fresh signal, so we report not-working and let the tile
  /// fall back to the amber "reconnecting" / grey state.
  bool isRoomWorking(String epk, String roomId) {
    if (_status is! StatusOnline) return false;
    final key = toStandardB64(epk);
    if (_workingOffTimers.containsKey('$key:$roomId')) return true;
    final list = _roomsByPeer[key];
    if (list == null) return false;
    for (final r in list) {
      if (r.roomId == roomId) return r.working;
    }
    return false;
  }

  /// App-side correction for the connected room's working flag.
  ///
  /// The relay remains the source for non-active rooms, but the active channel
  /// also sees the actual `user_input` / `agent_done` frames. Use that local
  /// observation as a backstop so a missed or delayed `meta.working=false`
  /// broadcast cannot leave the active chat/Home tile stuck as working.
  void markRoomWorking(String epk, String roomId, bool working) {
    final key = toStandardB64(epk);
    final list = _roomsByPeer[key];
    if (list == null) return;
    final idx = list.indexWhere((r) => r.roomId == roomId);
    if (idx < 0) return;
    if (working) {
      _workingOffTimers.remove('$key:$roomId')?.cancel();
      _unreadFinishedRooms.remove('$key:$roomId');
      if (list[idx].working) return;
      list[idx] = list[idx].copyWith(working: true);
      _scheduleRoomsEmit();
      // ignore: unawaited_futures
      _persistRoomsForPeer(key, _generation);
    } else {
      if (!list[idx].working) return;
      _scheduleRoomWorkingOff(key, roomId, _generation);
    }
  }

  void _scheduleRoomWorkingOff(
    String key,
    String roomId,
    int generation,
  ) {
    final timerKey = '$key:$roomId';
    if (_workingOffTimers.containsKey(timerKey)) return;
    if (_workingOffDebounce == Duration.zero) {
      _commitRoomWorkingOff(key, roomId, generation);
      return;
    }
    _workingOffTimers[timerKey] = Timer(_workingOffDebounce, () {
      _workingOffTimers.remove(timerKey);
      if (!_owns(generation)) return;
      _commitRoomWorkingOff(key, roomId, generation);
    });
  }

  void _commitRoomWorkingOff(String key, String roomId, int generation) {
    if (!_owns(generation)) return;
    final list = _roomsByPeer[key];
    if (list == null) return;
    final idx = list.indexWhere((r) => r.roomId == roomId);
    if (idx < 0) return;
    if (!list[idx].working) return;
    final isCurrentActive =
        toStandardB64(_activePeer?.remoteEpk ?? '') == key &&
        _activeRoomId == roomId;
    if (!isCurrentActive) {
      _unreadFinishedRooms.add('$key:$roomId');
    }
    list[idx] = list[idx].copyWith(working: false);
    _scheduleRoomsEmit();
    unawaited(_persistRoomsForPeer(key, generation));
  }

  bool isRoomUnreadFinished(String epk, String roomId) =>
      _unreadFinishedRooms.contains('${toStandardB64(epk)}:$roomId');

  void markRoomViewed(String epk, String roomId) {
    final key = toStandardB64(epk);
    if (_unreadFinishedRooms.remove('$key:$roomId')) {
      _scheduleRoomsEmit();
    }
  }

  /// Plan-17 follow-up — hydrate `_roomsByPeer` from disk on boot so
  /// Home tiles persist across cold starts even before the relay
  /// pushes a fresh snapshot. Idempotent.
  Future<void> _restoreCachedRooms({
    List<PeerRecord>? peers,
    bool force = false,
    int? expectedGeneration,
  }) async {
    if (_roomsRestored && !force) return;
    final generation = expectedGeneration ?? _generation;
    final scopedPeers = peers ?? await _storage.listPeers();
    if (!_owns(generation)) return;

    final restored = <String, List<RoomInfo>>{};
    for (final peer in scopedPeers) {
      final cached = await _storage.loadRooms(peer.remoteEpk);
      if (!_owns(generation)) return;
      if (cached.isEmpty) continue;
      restored[toStandardB64(peer.remoteEpk)] = cached
          .map(
            (room) => RoomInfo(
              roomId: room.roomId,
              name: room.localName ?? room.name,
              cwd: room.cwd,
              startedAt: room.startedAt,
              model: room.model,
            ),
          )
          .toList();
    }
    if (!_owns(generation)) return;
    _roomsByPeer
      ..clear()
      ..addAll(restored);
    _roomsRestored = true;
    if (!_roomsController.isClosed) {
      _roomsController.add(_roomsSnapshot());
    }
  }

  Future<void> _persistRoomsForPeer(String peerKey, int generation) async {
    if (!_owns(generation)) return;
    final peers = await _storage.listPeers();
    if (!_owns(generation)) return;
    PeerRecord? match;
    for (final peer in peers) {
      if (toStandardB64(peer.remoteEpk) == peerKey) {
        match = peer;
        break;
      }
    }
    if (match == null) return;
    final list = List<RoomInfo>.of(
      _roomsByPeer[peerKey] ?? const <RoomInfo>[],
    );
    final existing = await _storage.loadRooms(match.remoteEpk);
    if (!_owns(generation)) return;
    final localById = {
      for (final room in existing)
        if (room.localName != null && room.localName!.isNotEmpty)
          room.roomId: room.localName!,
    };
    final persisted = list
        .map(
          (room) => PersistedRoom(
            roomId: room.roomId,
            name: room.name,
            cwd: room.cwd,
            startedAt: room.startedAt,
            localName: localById[room.roomId],
            model: room.model,
          ),
        )
        .toList();
    if (!_owns(generation)) return;
    await _storage.saveRooms(match.remoteEpk, persisted);
  }

  /// Plan-17 follow-up — long-press menu support. Override the
  /// display name of a single room locally (Pi never sees this).
  /// Reflects immediately in the rooms snapshot.
  Future<void> setRoomLocalName(String epk, String roomId, String? name) async {
    final key = toStandardB64(epk);
    final list = _roomsByPeer[key];
    if (list == null) return;
    final idx = list.indexWhere((r) => r.roomId == roomId);
    if (idx < 0) return;
    final old = list[idx];
    // Use copyWith so EVERY field (model, cwd, startedAt, …) is
    // preserved. The previous explicit constructor call dropped
    // `model`, which made the tile subtitle fall back to
    // "Last Paired: …" right after a rename — bug.
    list[idx] = old.copyWith(
      name: (name != null && name.isNotEmpty) ? name : old.name,
    );
    // Persist with localName so it survives cold start.
    final cached = await _storage.loadRooms(epk);
    final updated = cached
        .map((c) => c.roomId == roomId ? c.copyWith(localName: name) : c)
        .toList();
    await _storage.saveRooms(epk, updated);
    if (!_roomsController.isClosed) {
      _roomsController.add(_roomsSnapshot());
    }
  }

  /// Plan-17 follow-up — delete a cached room locally. Allowed whether
  /// the room is live or offline; a live room reappears when the relay
  /// re-announces it (next snapshot/announce), which is the documented
  /// behaviour surfaced in the delete confirmation.
  Future<void> deleteCachedRoom(String epk, String roomId) async {
    final key = toStandardB64(epk);
    final list = _roomsByPeer[key];
    if (list != null) {
      list.removeWhere((r) => r.roomId == roomId);
      if (list.isEmpty) _roomsByPeer.remove(key);
    }
    _liveRoomIds[key]?.remove(roomId);
    if (_liveRoomIds[key]?.isEmpty ?? true) _liveRoomIds.remove(key);
    final cached = await _storage.loadRooms(epk);
    final pruned = cached.where((c) => c.roomId != roomId).toList();
    await _storage.saveRooms(epk, pruned);
    if (!_roomsController.isClosed) {
      _roomsController.add(_roomsSnapshot());
    }
  }

  /// Plan 17 fix — legacy migration hook for peers paired before
  /// `PeerRecord.roomId` existed. When the relay tells us about rooms
  /// for the active peer, and that peer has no persisted roomId yet,
  /// we adopt the announced room as canonical:
  ///   1. Update `_activeRoomId` so outbound envelopes are routed.
  ///   2. Push the change down to the WS transport.
  ///   3. Persist the choice on the PeerRecord via storage so
  ///      subsequent app launches address (peer, room) from the start
  ///      and don't re-trigger discovery.
  void _maybeAdoptLegacyRoom(
    String peerKey,
    String discoveredRoom,
    int generation,
  ) {
    if (!_owns(generation)) return;
    final active = _activePeer;
    if (active == null) return;
    if (toStandardB64(active.remoteEpk) != peerKey) return;
    if (active.roomId != null) return;
    _activeRoomId = discoveredRoom;
    final cur = _status;
    if (cur is StatusOnline) {
      _propagateActiveRoom(discoveredRoom, cur.channel);
    }
    final updated = active.copyWith(roomId: discoveredRoom);
    _activePeer = updated;
    unawaited(
      _storage
          .savePeer(updated, intent: PeerSaveIntent.localMetadata)
          .then((_) {})
          .catchError((Object _, StackTrace _) {}),
    );
  }

  /// On (re)connect, re-send the last subscribe_presence so the relay
  /// pushes updates again for our current peer list. Plan 17: also
  /// subscribe to rooms for the same peer set — the relay pushes
  /// `room_announced` / `room_ended` / `rooms` (snapshot) the same way
  /// presence does. Single subscription covers all per-cwd sessions on
  /// every paired Mac.
  void _replaySubscriptions() {
    if (_subscribedEpks.isEmpty) return;
    final link = _controlLink;
    if (link == null) return;
    link.sendControl(subscribePresenceFrame(_subscribedEpks));
    link.sendControl(presenceCheckFrame(_subscribedEpks));
    link.sendControl(subscribeRoomsFrame(_subscribedEpks));
    link.sendControl(roomsCheckFrame(_subscribedEpks));
  }

  void _watchChannel(PeerRecord peer, IChannel ch, int generation) {
    _channelSub?.cancel();
    _channelSub = ch.serverMessages.listen(
      (_) {
        if (!_owns(generation)) return;
        final status = _status;
        if (status is! StatusOnline || !identical(status.channel, ch)) return;
        _missedPings = 0;
        _retryAttempt = 0;
      },
      onError: (_) => _onChannelLost(peer, ch, generation),
      onDone: () => _onChannelLost(peer, ch, generation),
    );
  }

  void _onChannelLost(PeerRecord peer, IChannel ch, int generation) {
    if (!_owns(generation)) return;
    final status = _status;
    if (status is! StatusOnline || !identical(status.channel, ch)) return;
    _cancelPing();
    _scheduleRetry(peer, generation);
  }

  void _scheduleRetry(PeerRecord peer, int generation) {
    if (!_owns(generation)) return;
    final delay = _backoffFor(_retryAttempt);
    _emit(StatusRetrying(nextRetry: delay, attempt: _retryAttempt));
    _retryTimer?.cancel();
    _retryTimer = Timer(delay, () {
      _retryTimer = null;
      if (!_owns(generation)) return;
      _retryAttempt++;
      unawaited(_connect(peer, generation));
    });
  }

  void _startPing(PeerRecord peer, IChannel ch, int generation) {
    _pingTimer = Timer.periodic(const Duration(seconds: 25), (_) async {
      if (!_owns(generation)) return;
      final status = _status;
      if (status is! StatusOnline || !identical(status.channel, ch)) return;
      // This protocol ping probes Pi liveness. The WebSocket transport owns
      // relay keep-alives, so missed Pi replies only age the active room out
      // of the live set; they do not force destructive command replay.
      _missedPings++;
      if (_missedPings == 3) {
        _markActiveRoomOffline();
      }
      try {
        await ch.send(Ping(id: _newId()));
      } catch (_) {
        if (!_owns(generation)) return;
        _cancelPing();
        _onChannelLost(peer, ch, generation);
      }
    });
  }

  /// Plan-18 follow-up — when the Pi stops responding to protocol
  /// Pings, mark its current cwd-room as offline locally so the UI
  /// reflects the degraded state. The WS↔relay stays up.
  void _markActiveRoomOffline() {
    final activeEpk = _activePeer?.remoteEpk;
    if (activeEpk == null) return;
    final key = toStandardB64(activeEpk);
    final live = _liveRoomIds[key];
    if (live == null || !live.contains(_activeRoomId)) return;
    live.remove(_activeRoomId);
    if (live.isEmpty) _liveRoomIds.remove(key);
    if (!_roomsController.isClosed) {
      _roomsController.add(_roomsSnapshot());
    }
  }

  void _cancelRetry() {
    _retryTimer?.cancel();
    _retryTimer = null;
  }

  void _cancelPing() {
    _pingTimer?.cancel();
    _pingTimer = null;
    _missedPings = 0;
  }

  void _emit(ConnectionStatus s) {
    // Plan-18 follow-up — when the connection-status flips ON or OFF
    // StatusOnline, every room's "live" answer changes too (see
    // `isRoomLive` gate). Re-emit the rooms snapshot so subscribers
    // (Home, Chat AppBar) re-evaluate dot color immediately, without
    // waiting for the relay's next push.
    final wasOnline = _status is StatusOnline;
    final nowOnline = s is StatusOnline;
    _status = s;
    if (!_statusController.isClosed) _statusController.add(s);
    if (wasOnline != nowOnline && !_roomsController.isClosed) {
      _roomsController.add(_roomsSnapshot());
    }
  }

  static int _idCounter = 0;
  static String _newId() => 'ping_${++_idCounter}';
}
