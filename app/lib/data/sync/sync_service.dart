// SyncService is the single writer of the local session store.
//
// Streaming remains in memory: AgentChunk deltas are coalesced into
// [StreamingMessage], and only finalized assistant segments are committed.
import 'dart:async';
import 'dart:math' as math;

import 'package:app/data/local/session_store.dart';
import 'package:app/data/local/records/message_record.dart';
import 'package:app/data/local/records/runtime_record.dart';
import 'package:app/data/local/records/session_index_record.dart';
import 'package:app/data/sync/sync_events.dart';
import 'package:app/data/transport/connection_manager.dart';
import 'package:app/domain/contracts/service.dart';
import 'package:app/domain/session_state.dart';
import 'package:app/protocol/protocol.dart';
import 'package:app/protocol/uuid7.dart';
import 'package:flutter/foundation.dart';

class SyncService extends Service {
  final ConnectionManager _conn;
  final SessionStore _store;

  StreamSubscription<ConnectionStatus>? _connSub;
  StreamSubscription<ServerMessage>? _msgSub;
  StreamSubscription<Map<String, List<RoomInfo>>>? _roomsSub;
  StreamSubscription<Map<String, PresenceState>>? _presenceSub;

  // Active session being written (follows ConnectionManager).
  String? _activeEpk;
  String _activeRoomId = 'main';

  // In-memory dedupe + ordering for the active session. Rebuilt on [activate].
  // Key = `<role>:<id>` so a user row and assistant reply sharing a protocol
  // ID remain distinct.
  final Map<String, int> _idToSeq = {};
  int _nextSeq = 0;
  bool _indexLoaded = false;

  // Serialize mutations so concurrent channel events remain ordered.
  Future<void> _writeChain = Future<void>.value();

  // Streaming — in-memory only (#7).
  final StringBuffer _chunkBuffer = StringBuffer();
  String _chunkReplyTo = '';
  Timer? _flushTimer;
  StreamingMessage? _streaming;
  final StreamController<StreamingMessage?> _streamingController =
      StreamController<StreamingMessage?>.broadcast();

  final StreamController<SessionEvent> _eventController =
      StreamController<SessionEvent>.broadcast();

  // Plan/57 — transient interactive extension prompts (ask_user via pi-ask).
  // Never persisted (live UI requests, not chat history); surfaced to the
  // ChatViewModel, which opens a full-screen modal.
  final StreamController<ExtensionUiRequest> _extensionUiController =
      StreamController<ExtensionUiRequest>.broadcast();

  List<QueuedMsg> _queuedMessages = const [];
  final StreamController<List<QueuedMsg>> _queuedController =
      StreamController<List<QueuedMsg>>.broadcast();

  bool _pendingSyncRequest = false;
  Timer? _syncDebounce;

  // Whether the active session's agent is currently producing a reply. Spans
  // the WHOLE turn (send/echo → agent_done), not just the token-streaming
  // window — restoring the old broad "working" signal. Mirrored into the
  // session index (durable, for Home) and exposed in-memory for the chat pill.
  bool _working = false;
  bool _sawRemoteWorking = false;
  bool _turnEnded = false;
  // Live reply identity is captured before any asynchronous store write. Keep
  // it through idle: agent_message can follow agent_done's working-off timer.
  String? _assistantReplyTo;
  String? _lastFinalizedSegmentId;
  int _finalizedSegmentsCount = 0;
  Timer? _workingOffDebounce;
  final Set<String> _openToolIds = {};
  // target while working. Null when idle.
  String? _workingReplyTo;
  final StreamController<bool> _workingController =
      StreamController<bool>.broadcast();

  // Plan/32 safety net — if the relay never echoes a sent message back, the
  // optimistic `pending:true` bubble would spin forever. After this window we
  // remove the bubble SILENTLY (no "failed" state, no spinner). The real fix
  // lives in the relay; this is the app-side backstop. Per-message (`id`)
  // timers are armed only when a send is actually attempted online, and
  // cancelled on echo, user-cancel, session switch, and dispose.
  final Duration pendingSendTimeout;
  final Map<String, Timer> _pendingSendTimers = {};

  SyncService(
    this._conn,
    this._store, {
    this.pendingSendTimeout = const Duration(seconds: 20),
  }) {
    _connSub = _conn.statusStream.listen(_onStatus);
    _roomsSub = _conn.roomsStream.listen((_) {
      _writeRuntime();
      _syncTurnStateFromRoomMeta();
    });
    _presenceSub = _conn.presenceStream.listen((_) => _writeRuntime());
    _onStatus(_conn.status); // replay current
  }

  // ---------------------------------------------------------------------------
  // Public surface (commands + in-memory streams)
  // ---------------------------------------------------------------------------

  StreamingMessage? get streaming => _streaming;
  Stream<StreamingMessage?> get streamingStream => _streamingController.stream;
  Stream<SessionEvent> get events => _eventController.stream;

  /// Plan/57 — stream of interactive extension_ui_request prompts (ask_user
  /// via pi-ask). Transient: not written to the DB; the ChatViewModel renders
  /// a full-screen modal and replies via [respondExtensionUi].
  Stream<ExtensionUiRequest> get extensionUiRequestStream =>
      _extensionUiController.stream;
  List<QueuedMsg> get queuedMessages => _queuedMessages;
  String? get queuedText =>
      _queuedMessages.isEmpty ? null : _queuedMessages.first.text;
  Stream<List<QueuedMsg>> get queuedStream => _queuedController.stream;
  final _skillsController = StreamController<List<WireSkill>>.broadcast();
  List<WireSkill> _dynamicSkills = const [];
  Stream<List<WireSkill>> get dynamicSkillsStream => _skillsController.stream;
  List<WireSkill> get dynamicSkills => _dynamicSkills;

  /// True while the active session's agent is producing a reply (whole turn).
  bool get isWorking => _working;
  Stream<bool> get workingStream => _workingController.stream;

  /// `cancel` target for the in-flight reply (null when idle).
  String? get workingReplyTo => _workingReplyTo;

  String? get activeEpk => _activeEpk;
  String get activeRoomId => _activeRoomId;

  /// Bind the writer to a (peer, room) and rebuild the in-memory dedupe/order
  /// index. Called by chat mount/switch and the first online status.
  Future<void> activate(String epk, String roomId) async {
    final room = roomId.isEmpty ? 'main' : roomId;
    if (_activeEpk == epk && _activeRoomId == room && _indexLoaded) return;
    // Genuine session switch: drop the in-memory turn state so the
    // PREVIOUS session's streaming buffer + whole-turn working flag can't
    // bleed into the next chat (the bug where chat 2 looked "working"
    // because chat 1 was mid-turn). We deliberately do NOT clear the
    // durable session index — the previous room may still be running on
    // the Pi, and Home keeps showing it via the relay's per-room
    // `meta.working` broadcast.
    _resetTurnState();
    _indexLoaded = false;
    _activeEpk = epk;
    _activeRoomId = room;
    await _loadIndex();
    _writeRuntime();
  }

  /// Clears the in-memory streaming buffer + whole-turn working flag
  /// (emitting the cleared state so listeners update) WITHOUT touching the
  /// durable session index. Used on a session switch — see [activate].
  void _resetTurnState() {
    _flushTimer?.cancel();
    _flushTimer = null;
    _chunkBuffer.clear();
    _chunkReplyTo = '';
    _workingReplyTo = null;
    _sawRemoteWorking = false;
    _openToolIds.clear();
    _turnEnded = false;
    _assistantReplyTo = null;
    _lastFinalizedSegmentId = null;
    _finalizedSegmentsCount = 0;
    _workingOffDebounce?.cancel();
    _setQueuedMessages(const []);
    // This session's optimistic sends will no longer receive a matching echo
    // to confirm, so drop their backstops before stale timers can fire.
    _cancelAllSendTimers();
    if (_streaming != null) _emitStreaming(null);
    if (_working) {
      _working = false;
      if (!_workingController.isClosed) _workingController.add(false);
    }
  }

  Future<void> sendMessage(
    String text, {
    MessageImage? image,
    UserMessageStreamingBehavior? streamingBehavior,
  }) async {
    final epk = _activeEpk;
    final id = _newId();
    final now = DateTime.now();
    final isSteer = streamingBehavior == UserMessageStreamingBehavior.steer;
    if (isSteer && (_streaming?.buffer.isNotEmpty ?? false)) {
      final inReplyTo = _streaming!.inReplyTo;
      _finalizeSegment();
      _emitStreaming(StreamingMessage(inReplyTo: inReplyTo));
    }
    // Optimistic pending row (#defaults: optimistic + dedupe by id).
    if (epk != null) {
      await _upsert(
        MsgRole.user,
        id,
        (seq, _) => MessageRecord(
          id: id,
          seq: seq,
          role: MsgRole.user,
          text: text,
          image: image,
          ts: now,
          pending: true,
          steering: isSteer,
        ),
      );
      if (!isSteer) {
        _clearSteeringLabels();
        _setWorking(true, preview: _preview(text, image), replyTo: id);
      }
      // Arm the no-echo backstop for this row. The timeout is keyed off the
      // row's `ts`, NOT online-ness: an offline "held pending" send is reaped
      // 20s after its ts too, and ANY pending row is re-armed on session load
      // (see _loadIndex). So a quick session-switch or an app restart still
      // reaps a stale bubble instead of letting it spin "sending…" forever.
      _armSendTimeout(id, now);
    }
    final ch = _conn.channel;
    if (ch == null) {
      debugPrint(
        '[msg-send] id=$id (offline → held pending, reaped in '
        '${pendingSendTimeout.inSeconds}s)',
      );
      return;
    }
    // Seed an EMPTY streaming buffer so the blinking cursor shows during the
    // "thinking" gap before the first agent_chunk (pre-31 behavior). In-memory
    // only (#7) — never written to the DB. agent_chunk appends; agent_done
    // clears it (even for a text-less, tool-only turn).
    // Steering messages should not create a new cursor, because they do not
    // start a fresh assistant turn.
    if (!isSteer) {
      _emitStreaming(StreamingMessage(inReplyTo: id));
    }
    debugPrint('[msg-send] id=$id text=${_preview(text, image)}');
    await ch.send(
      UserMessage(
        id: id,
        text: text,
        streamingBehavior: streamingBehavior,
        images: image == null
            ? null
            : [WireImage(data: image.data, mime: image.mime)],
      ),
    );
  }

  /// Arm (or re-arm) the silent no-echo backstop for a pending row, keyed by
  /// `id`. The window is the time REMAINING relative to the row's [ts], so a
  /// row loaded from disk already past [pendingSendTimeout] fires immediately
  /// (floored at zero). Idempotent — cancels any existing timer for `id`.
  void _armSendTimeout(String id, DateTime ts) {
    _pendingSendTimers.remove(id)?.cancel();
    final remaining = pendingSendTimeout - DateTime.now().difference(ts);
    _pendingSendTimers[id] = Timer(
      remaining > Duration.zero ? remaining : Duration.zero,
      () => _onSendTimeout(id),
    );
  }

  /// No echo arrived within [pendingSendTimeout]: drop the optimistic bubble
  /// silently and unwind only the turn state that belongs to THIS `id`.
  void _onSendTimeout(String id) {
    _pendingSendTimers.remove(id);
    // ignore: discarded_futures
    _removeById(id);
    // Clear the thinking cursor only if it's seeded for this message.
    if (_streaming?.inReplyTo == id) _emitStreaming(null);
    // Clear working ONLY if this id owns it — never knock down a turn that a
    // different (echoed) message is already driving.
    if (_workingReplyTo == id) _setWorking(false);
    debugPrint(
      '[msg-timeout] id=$id removed (no echo in '
      '${pendingSendTimeout.inSeconds}s)',
    );
  }

  void _cancelAllSendTimers() {
    for (final t in _pendingSendTimers.values) {
      t.cancel();
    }
    _pendingSendTimers.clear();
  }

  /// Test seam — number of armed no-echo timers (asserts no leak on reset).
  @visibleForTesting
  int get debugPendingSendTimerCount => _pendingSendTimers.length;

  Future<void> queueMessage(String text) async {
    final ch = _conn.channel;
    if (ch == null) return;
    final trimmed = text.trim();
    if (trimmed.isEmpty) return;
    final id = _newId();
    _setQueuedMessages([
      ..._queuedMessages,
      QueuedMsg(
        id: id,
        text: trimmed,
        editable: true,
        createdAt: DateTime.now(),
      ),
    ]);
    await ch.send(QueuedMessageSet(id: id, text: trimmed));
  }

  Future<void> setQueuedMessage(String text) => queueMessage(text);

  Future<void> clearQueuedMessage([String? targetId]) async {
    if (targetId == null) {
      _setQueuedMessages(const []);
    } else {
      _setQueuedMessages([
        for (final item in _queuedMessages)
          if (item.id != targetId) item,
      ]);
    }
    final ch = _conn.channel;
    if (ch == null) return;
    await ch.send(QueuedMessageClear(id: _newId(), targetId: targetId));
  }

  Future<void> clearQueuedMessages() => clearQueuedMessage();

  Future<void> cancel(String targetId) async {
    // User-driven cancel of this message → disarm its no-echo backstop too.
    _pendingSendTimers.remove(targetId)?.cancel();
    final ch = _conn.channel;
    if (ch == null) return;
    await ch.send(Cancel(id: _newId(), targetId: targetId));
  }

  /// Plan/57 — respond to an interactive extension_ui_request (ask_user).
  /// The ChatViewModel builds the [ExtensionUiResponse] (value/confirmed/
  /// cancelled + optional `ask` envelope); the SyncService just ships it.
  /// Returns false when there is no live channel or the send fails so the
  /// caller can surface a retryable failure immediately instead of waiting on
  /// the sheet's 25s backstop.
  Future<bool> respondExtensionUi(ExtensionUiResponse resp) async {
    final ch = _conn.channel;
    if (ch == null) return false;
    try {
      await ch.send(resp);
      return true;
    } catch (error) {
      debugPrint('[extension-ui] failed to send response: $error');
      return false;
    }
  }

  Future<void> approveTool(String toolCallId, ApproveDecision decision) async {
    final ch = _conn.channel;
    if (ch == null) return;
    await ch.send(
      ApproveTool(id: _newId(), toolCallId: toolCallId, decision: decision),
    );
    await _upsert(MsgRole.tool, toolCallId, (seq, existing) {
      final base =
          existing?.tool ??
          ToolEventData(toolCallId: toolCallId, tool: 'unknown');
      return (existing ??
              MessageRecord(
                id: toolCallId,
                seq: seq,
                role: MsgRole.tool,
                ts: DateTime.now(),
              ))
          .copyWith(
            tool: base.copyWith(
              status: decision == ApproveDecision.allow
                  ? ToolEventStatus.allowed
                  : ToolEventStatus.denied,
            ),
          );
    });
  }

  void requestSync() {
    final ch = _conn.channel;
    if (ch == null || _activeEpk == null) {
      _pendingSyncRequest = true;
      return;
    }
    _pendingSyncRequest = false;
    ch.send(SessionSync(id: _newId()));
  }

  /// Plan/28 — `session_new` acked: wipe the active session's rows + index.
  Future<void> clearActiveSession() async {
    final epk = _activeEpk;
    if (epk == null) return;
    final room = _activeRoomId;
    // Session wiped → any optimistic sends/streaming/working state are moot.
    _cancelAllSendTimers();
    _discardStreamingState();
    _assistantReplyTo = null;
    _lastFinalizedSegmentId = null;
    _finalizedSegmentsCount = 0;
    _setQueuedMessages(const []);
    _setWorking(false);
    await _enqueue(() async {
      if (_activeEpk != epk || _activeRoomId != room) return;
      _store.clearSession(epk, room);
      _idToSeq.clear();
      _nextSeq = 0;
      _indexLoaded = true;
    });
  }

  // ---------------------------------------------------------------------------
  // Channel → DB
  // ---------------------------------------------------------------------------

  void _onStatus(ConnectionStatus s) {
    _msgSub?.cancel();
    _msgSub = null;
    if (s is StatusOnline) {
      // Plan/32f — bind this stream's writes to the PEER that owns the
      // channel RIGHT NOW. After a `switchTo`, a late frame from the OLD
      // peer's session rows: `_activeEpk` has already moved (chat calls
      // `activate()` before `switchTo`), so a straggler chat-1 frame would
      // otherwise be written to chat 2 until its history is reapplied.
      // Capture the origin epk here and drop frames no longer active.
      //
      // We gate on epk only — NOT room: rooms of the same peer share one
      // channel and `_onStatus` doesn't re-fire on a same-peer room switch
      // (the transport already demuxes by room), so a room gate would wrongly
      // drop everything after switching cwds on the same Mac.
      final originEpk = _conn.activePeer?.remoteEpk;
      _msgSub = s.channel.serverMessages.listen(
        (msg) => _onServerMessage(msg, originEpk),
        onError: (Object _, StackTrace _) {},
      );
      // ignore: discarded_futures
      _onlineActivated();
    }
    _writeRuntime();
  }

  Future<void> _onlineActivated() async {
    final peer = _conn.activePeer;
    if (peer != null && _activeEpk == null) {
      await activate(peer.remoteEpk, _conn.activeRoomId);
    }
    _syncDebounce?.cancel();
    _syncDebounce = Timer(const Duration(milliseconds: 200), requestSync);
    if (_pendingSyncRequest) requestSync();
  }

  void _onServerMessage(ServerMessage msg, [String? originEpk]) {
    // Plan/32f — drop frames from a peer whose channel is no longer the active
    // session (a stale connection still draining after `switchTo`). Without
    // this, a straggler write targets `_activeEpk` — which already points at
    // the NEW chat — and bleeds the old session's messages into its rows.
    // Only gate when BOTH origin and active are set and differ: pre-bind
    // (`_activeEpk == null`, cold boot before `activate`) must still flow, and
    // direct test calls without an origin aren't gated.
    if (originEpk != null && _activeEpk != null && originEpk != _activeEpk) {
      return;
    }
    switch (msg) {
      case AgentChunk(:final inReplyTo, :final delta):
        _trackAssistantTurn(inReplyTo);
        _workingOffDebounce?.cancel();
        _chunkBuffer.write(delta);
        _chunkReplyTo = inReplyTo;
        _flushTimer?.cancel();
        _flushTimer = Timer(const Duration(milliseconds: 16), _flushChunks);
        _setWorking(true, replyTo: inReplyTo);
      case AgentDone(:final inReplyTo):
        _trackAssistantTurn(inReplyTo);
        // Finalize whatever text accumulated since the last tool boundary.
        final text = _finalizeSegment();
        _clearSteeringLabel(inReplyTo);
        _turnEnded = true;
        if (_openToolIds.isEmpty) {
          _scheduleWorkingOff(preview: text.isEmpty ? null : text);
        }
      case AgentMessage(:final inReplyTo, :final text):
        _trackAssistantTurn(inReplyTo);
        // Also drain buffered chunks when the complete message arrives without
        // agent_done. Its upsert is queued after the segment write below.
        _finalizeSegment();
        // Live finalize writes individual `agent_<uuid>` rows per segment.
        // If multiple text segments were already finalized during this turn
        // (e.g. before and after tool calls), AgentMessage carries the full
        // concatenated turn text — overwriting the latest segment would duplicate
        // earlier segments into the last bubble. Only update if single or zero segments.
        if (_finalizedSegmentsCount > 1) {
          break;
        }
        final targetId = _lastFinalizedSegmentId ??= 'agent_${uuid7()}';
        _finalizedSegmentsCount = 1;
        // Both writes use the same synchronously captured ID; _enqueue makes
        // the authoritative update observe the preceding segment insertion.
        // ignore: discarded_futures
        _upsert(
          MsgRole.assistant,
          targetId,
          (seq, existing) =>
              existing != null
                  ? existing.copyWith(text: text)
                  : MessageRecord(
                      id: targetId,
                      seq: seq,
                      role: MsgRole.assistant,
                      text: text,
                      ts: DateTime.now(),
                    ),
        );
      case QueuedMessageState(:final items):
        _setQueuedMessages([
          for (final item in items)
            QueuedMsg(
              id: item.id,
              text: item.text,
              editable: item.editable,
              createdAt: item.createdAt,
            ),
        ]);

      case SteerConsumed(:final id):
        _clearSteeringLabel(id);

      case UserInput(
        :final id,
        :final text,
        :final image,
        :final streamingBehavior,
      ):
        // Echo dedupes against the optimistic row (same id): confirm it
        // (pending=false) or insert as confirmed (foreign device).
        debugPrint('[msg-echo] id=$id');
        // Echo arrived → the send landed; disarm the no-echo backstop.
        _pendingSendTimers.remove(id)?.cancel();
        if (_queuedMessages.any((item) => item.id == id)) {
          _setQueuedMessages([
            for (final item in _queuedMessages)
              if (item.id != id) item,
          ]);
        }
        // ignore: discarded_futures
        _upsertUserEcho(
          id,
          text,
          image == null
              ? null
              : MessageImage(data: image.data, mime: image.mime),
        );
        // Steering input should not start/replace the working turn bubble.
        if (streamingBehavior == UserMessageStreamingBehavior.steer) {
          _setActivity(SessionActivity.working, preview: text);
        } else {
          _setWorking(true, preview: text, replyTo: id);
          // Show the thinking cursor for this turn (foreign-device echo, or the
          // local echo when the send-seed was already cleared). Guarded so it
          // never wipes a buffer that's already accumulating for this id.
          if (_streaming?.inReplyTo != id) {
            _emitStreaming(StreamingMessage(inReplyTo: id));
          }
        }

      case ToolRequest(:final toolCallId, :final tool, :final args):
        // Sequential ordering: close the current text segment as its own row
        // BEFORE the tool, so "narration → command → narration" renders in
        // order instead of all text landing after the commands.
        _workingOffDebounce?.cancel();
        _finalizeSegment();
        _openToolIds.add(toolCallId);
        _turnEnded = false;
        _setWorking(true);
        // ignore: discarded_futures
        _upsert(
          MsgRole.tool,
          toolCallId,
          (seq, existing) =>
              existing ??
              MessageRecord(
                id: toolCallId,
                seq: seq,
                role: MsgRole.tool,
                ts: DateTime.now(),
                tool: ToolEventData(
                  toolCallId: toolCallId,
                  tool: tool,
                  args: args,
                ),
              ),
        );

      case ToolResult(:final toolCallId, :final result, :final error):
        _openToolIds.remove(toolCallId);
        // ignore: discarded_futures
        _upsert(MsgRole.tool, toolCallId, (seq, existing) {
          final base =
              existing?.tool ??
              ToolEventData(toolCallId: toolCallId, tool: 'unknown');
          return (existing ??
                  MessageRecord(
                    id: toolCallId,
                    seq: seq,
                    role: MsgRole.tool,
                    ts: DateTime.now(),
                  ))
              .copyWith(
                tool: base.copyWith(
                  status: error != null
                      ? ToolEventStatus.failed
                      : ToolEventStatus.completed,
                  result: result,
                  error: error,
                ),
              );
        });
        if (_openToolIds.isEmpty && _turnEnded) {
          _scheduleWorkingOff();
        }

      case Cancelled(:final targetId):
        _pendingSendTimers.remove(targetId)?.cancel();
        _workingOffDebounce?.cancel();
        _discardStreamingState();
        // Cancel is stop-generation, not delete-history. Only drop a local
        // optimistic row that never got confirmed by the Pi echo; preserve
        // confirmed user/tool rows as the audit trail of what happened.
        // ignore: discarded_futures
        _removePendingById(targetId);
        _clearSteeringLabels();
        _openToolIds.clear();
        _turnEnded = false;
        _setWorking(false);

      case Bye(:final rawReason):
        if (!_eventController.isClosed) {
          _eventController.add(PeerWentOffline(rawReason));
        }
        _clearSteeringLabels();
        _setWorking(false);
        final peer = _conn.activePeer;
        if (peer != null) {
          // ignore: discarded_futures
          _conn.switchTo(peer);
        }

      case SessionHistory():
        // ignore: discarded_futures
        _applyHistory(msg);

      case ErrorMessage(:final code, :final message):
        if (code.contains('unknown_peer')) {
          if (!_eventController.isClosed) {
            _eventController.add(const PairingRevoked());
          }
          break;
        }
        _discardStreamingState();
        _clearSteeringLabels();
        _setWorking(false);
        // ignore: discarded_futures
        _upsert(
          MsgRole.assistant,
          _newId(),
          (seq, _) => MessageRecord(
            id: 'err_$seq',
            seq: seq,
            role: MsgRole.assistant,
            text: '⚠ $code: $message',
            ts: DateTime.now(),
          ),
        );

      case Compaction(:final summary, :final tokensBefore, :final ts):
        _writeCompaction(summary, tokensBefore, ts);

      case ExtensionUiRequest():
        // Plan/57 — transient interactive prompt (ask_user via pi-ask).
        // Surface to the UI; never persist (it's a live request, not history).
        _extensionUiController.add(msg);
        break;
      case Pong():
      case PairOk():
      case PairError():
      case ActionOk():
      case ActionError():
      case ModelsList():
        break;
      case SkillsList(:final skills):
        _dynamicSkills = skills;
        if (!_skillsController.isClosed) {
          _skillsController.add(skills);
        }
        break;
    }
  }

  /// Plan/32 — persist a compaction as a system row so it renders a system
  /// bubble in the chat and survives a re-sync. Keyed by `ts` when present so
  /// the live message and its history replay collapse to one row.
  void _writeCompaction(String summary, int? tokensBefore, int? ts) {
    final id = 'compaction_${ts ?? uuid7()}';
    final when = ts != null
        ? DateTime.fromMillisecondsSinceEpoch(ts)
        : DateTime.now();
    // ignore: discarded_futures
    _upsert(
      MsgRole.compaction,
      id,
      (seq, existing) =>
          existing ??
          MessageRecord(
            id: id,
            seq: seq,
            role: MsgRole.compaction,
            text: summary,
            tokensBefore: tokensBefore,
            ts: when,
          ),
    );
  }

  Future<void> _applyHistory(SessionHistory h) async {
    final epk = _activeEpk;
    if (epk == null) return;
    final room = _activeRoomId;
    final rows = _convertHistory(h.events);
    final historyIds = {for (final r in rows) _key(r.role, r.id)};
    await _enqueue(() async {
      final existingRows = _store.messages(epk, room);
      if (rows.isEmpty && existingRows.isNotEmpty) {
        // An empty remote response can mean the Pi buffer is not ready. It is
        // never evidence that durable local history should be erased.
        return;
      }
      // Preserve pending/steering user rows that the Pi has not unified into
      // authoritative history yet.
      final preserved = <MessageRecord>[];
      for (final record in existingRows) {
        if (record.role == MsgRole.user &&
            (record.pending || record.steering) &&
            !historyIds.contains(_key(record.role, record.id)) &&
            !rows.any(
              (history) =>
                  history.role == MsgRole.user &&
                  history.text == record.text,
            )) {
          preserved.add(record);
        }
      }
      final desired = <MessageRecord>[
        for (var i = 0; i < rows.length; i++) rows[i].copyWith(seq: i),
        for (var i = 0; i < preserved.length; i++)
          preserved[i].copyWith(seq: rows.length + i),
      ];
      // SQLite reconciliation is atomic and emits once after commit. An
      // identical replay performs no writes and therefore no UI rebuild.
      _store.replaceMessages(epk, room, desired);
      if (_activeEpk == epk && _activeRoomId == room) {
        _idToSeq
          ..clear()
          ..addEntries([
            for (final record in desired)
              MapEntry(_key(record.role, record.id), record.seq),
          ]);
        _nextSeq = desired.length;
        _indexLoaded = true;
      }
    });
    if (_activeEpk == epk && _activeRoomId == room) {
      final started = h.sessionStartedAt;
      _updateIndex(
        (cur) => cur.copyWith(
          sessionStartedAt: DateTime.fromMillisecondsSinceEpoch(started),
        ),
      );
    }
  }

  List<MessageRecord> _convertHistory(List<SessionHistoryEvent> events) {
    final out = <MessageRecord>[];
    var seq = 0;
    for (final e in events) {
      switch (e) {
        case UserInputEvt(:final id, :final text, :final image):
          out.add(
            MessageRecord(
              id: id,
              seq: seq++,
              role: MsgRole.user,
              text: text,
              image: image == null
                  ? null
                  : MessageImage(data: image.data, mime: image.mime),
              ts: DateTime.fromMillisecondsSinceEpoch(e.ts),
            ),
          );
        case AgentMessageEvt(:final text):
          out.add(
            MessageRecord(
              id: 'agent_${e.ts}_$seq',
              seq: seq++,
              role: MsgRole.assistant,
              text: text,
              ts: DateTime.fromMillisecondsSinceEpoch(e.ts),
            ),
          );
        case ToolRequestEvt(:final toolCallId, :final tool, :final args):
          out.add(
            MessageRecord(
              id: toolCallId,
              seq: seq++,
              role: MsgRole.tool,
              ts: DateTime.fromMillisecondsSinceEpoch(e.ts),
              tool: ToolEventData(
                toolCallId: toolCallId,
                tool: tool,
                args: args,
              ),
            ),
          );
        case ToolResultEvt(:final toolCallId, :final result, :final error):
          final idx = out.lastIndexWhere(
            (m) => m.role == MsgRole.tool && m.tool?.toolCallId == toolCallId,
          );
          final status = error != null
              ? ToolEventStatus.failed
              : ToolEventStatus.completed;
          if (idx >= 0) {
            out[idx] = out[idx].copyWith(
              tool: out[idx].tool!.copyWith(
                status: status,
                result: result,
                error: error,
              ),
            );
          } else {
            out.add(
              MessageRecord(
                id: toolCallId,
                seq: seq++,
                role: MsgRole.tool,
                ts: DateTime.fromMillisecondsSinceEpoch(e.ts),
                tool: ToolEventData(
                  toolCallId: toolCallId,
                  tool: 'unknown',
                  status: status,
                  result: result,
                  error: error,
                ),
              ),
            );
          }
        case CompactionEvt(:final summary, :final tokensBefore):
          out.add(
            MessageRecord(
              id: 'compaction_${e.ts}',
              seq: seq++,
              role: MsgRole.compaction,
              text: summary,
              tokensBefore: tokensBefore,
              ts: DateTime.fromMillisecondsSinceEpoch(e.ts),
            ),
          );
      }
    }
    return out;
  }

  // ---------------------------------------------------------------------------
  // Store write helpers (all serialized through _enqueue)
  // ---------------------------------------------------------------------------

  String _key(MsgRole role, String id) => '${role.name}:$id';


  Future<void> _loadIndex() {
    final epk = _activeEpk;
    if (epk == null) return Future<void>.value();
    final room = _activeRoomId;
    return _enqueue(() async {
      if (_activeEpk != epk || _activeRoomId != room) return;
      final rows = _store.messages(epk, room);
      _idToSeq.clear();
      _nextSeq = 0;
      var hadSteering = false;
      for (final record in rows) {
        _idToSeq[_key(record.role, record.id)] = record.seq;
        _nextSeq = math.max(_nextSeq, record.seq + 1);
        // Re-arm the no-echo backstop for pending rows after a restart/session
        // switch. A stale timestamp fires immediately.
        if (record.role == MsgRole.user && record.pending) {
          _armSendTimeout(record.id, record.ts);
        }
        hadSteering =
            hadSteering ||
            (record.role == MsgRole.user && record.steering);
      }
      _indexLoaded = true;
      if (hadSteering) _store.clearSteeringLabels(epk, room);
    });
  }

  Future<void> _upsert(
    MsgRole role,
    String id,
    MessageRecord Function(int seq, MessageRecord? existing) build,
  ) {
    final epk = _activeEpk;
    if (epk == null) return Future<void>.value();
    final room = _activeRoomId;
    return _enqueue(() async {
      if (_activeEpk != epk || _activeRoomId != room) return;
      final mapKey = _key(role, id);
      final existingSeq = _idToSeq[mapKey];
      if (existingSeq != null) {
        final existing = _store.messageAt(epk, room, existingSeq);
        if (existing == null) {
          _idToSeq.remove(mapKey);
          return;
        }
        _store.upsertMessage(epk, room, build(existingSeq, existing));
      } else {
        final seq = _nextSeq++;
        _store.upsertMessage(epk, room, build(seq, null));
        _idToSeq[mapKey] = seq;
      }
    });
  }

  Future<void> _removeById(String id) {
    final epk = _activeEpk;
    if (epk == null) return Future<void>.value();
    final room = _activeRoomId;
    return _enqueue(() async {
      if (_activeEpk != epk || _activeRoomId != room) return;
      for (final role in MsgRole.values) {
        final seq = _idToSeq.remove(_key(role, id));
        if (seq != null) _store.deleteMessage(epk, room, seq);
      }
    });
  }

  void _clearSteeringLabel(String id) {
    final epk = _activeEpk;
    if (epk == null) return;
    final room = _activeRoomId;
    // ignore: discarded_futures
    _enqueue(() async {
      if (_activeEpk != epk || _activeRoomId != room) return;
      _store.clearSteeringLabels(epk, room, id: id);
    });
  }

  void _clearSteeringLabels() {
    final epk = _activeEpk;
    if (epk == null) return;
    final room = _activeRoomId;
    // ignore: discarded_futures
    _enqueue(() async {
      if (_activeEpk != epk || _activeRoomId != room) return;
      _store.clearSteeringLabels(epk, room);
    });
  }

  Future<void> _removePendingById(String id) {
    final epk = _activeEpk;
    if (epk == null) return Future<void>.value();
    final room = _activeRoomId;
    return _enqueue(() async {
      if (_activeEpk != epk || _activeRoomId != room) return;
      for (final role in MsgRole.values) {
        final key = _key(role, id);
        final seq = _idToSeq[key];
        if (seq == null) continue;
        final existing = _store.messageAt(epk, room, seq);
        if (existing == null) {
          _idToSeq.remove(key);
          continue;
        }
        if (!existing.pending) continue;
        _idToSeq.remove(key);
        _store.deleteMessage(epk, room, seq);
      }
    });
  }

  void _setActivity(SessionActivity status, {String? preview}) {
    _updateIndex(
      (cur) => cur.copyWith(
        status: status,
        lastMessageAt: preview != null ? DateTime.now() : null,
        lastMessagePreview: preview,
      ),
    );
  }

  void _setQueuedMessages(List<QueuedMsg> items) {
    final next = List<QueuedMsg>.unmodifiable(items);
    if (_queuedMessages == next) return;
    _queuedMessages = next;
    if (!_queuedController.isClosed) _queuedController.add(next);
  }

  /// Single source of "the active session is working". Drives the in-memory
  /// flag/stream (chat pill) AND the durable session index (Home dot).

  void _syncTurnStateFromRoomMeta() {
    final epk = _activeEpk;
    if (epk == null) return;
    final remoteWorking = _conn.isRoomWorking(epk, _activeRoomId);
    if (remoteWorking) {
      _workingOffDebounce?.cancel();
      _sawRemoteWorking = true;
      _setWorking(true);
      return;
    }
    // An open tool outranks "not working" while we have no authoritative
    // signal (offline, room not in the relay's live set). A live room the
    // relay reports idle has finished its turn: the tool_result/agent_done
    // were lost (e.g. phone offline mid-tool), so keeping the tool open
    // would pin the chat on "working" forever.
    if (_openToolIds.isNotEmpty) {
      if (!_conn.isRoomLive(epk, _activeRoomId)) return;
      _openToolIds.clear();
      _turnEnded = true;
    }
    if (_sawRemoteWorking || _working) {
      _workingOffDebounce?.cancel();
      _discardStreamingState();
      _setWorking(false);
    }
    _sawRemoteWorking = false;
  }

  void _scheduleWorkingOff({String? preview}) {
    _workingOffDebounce?.cancel();
    _workingOffDebounce = Timer(const Duration(milliseconds: 100), () {
      if (_openToolIds.isEmpty && _turnEnded) {
        _setWorking(false, preview: preview);
      }
    });
  }

  void _setWorking(bool on, {String? preview, String? replyTo}) {
    _setActivity(
      on ? SessionActivity.working : SessionActivity.idle,
      preview: preview,
    );
    // Snapshot nullable field once; Dart won't promote mutable fields safely.
    final epk = _activeEpk;
    if (epk != null) {
      _conn.markRoomWorking(epk, _activeRoomId, on);
    }
    if (on) {
      if (replyTo != null) _workingReplyTo = replyTo;
    } else {
      _workingReplyTo = null;
      _sawRemoteWorking = false;
    }
    _working = on;
    if (!_workingController.isClosed) _workingController.add(on);
  }

  void _updateIndex(SessionIndexRecord Function(SessionIndexRecord cur) build) {
    final epk = _activeEpk;
    if (epk == null) return;
    final room = _activeRoomId;
    // ignore: discarded_futures
    _enqueue(() async {
      final current =
          _store.session(epk, room) ??
          SessionIndexRecord(epk: epk, roomId: room);
      _store.upsertSession(build(current));
    });
  }

  void _writeRuntime() {
    final epk = _activeEpk;
    if (epk == null) return;
    final room = _activeRoomId;
    final status = _conn.status;
    final connection = switch (status) {
      StatusOnline() => RuntimeConnection.online,
      StatusConnecting() => RuntimeConnection.connecting,
      StatusRetrying() => RuntimeConnection.retrying,
      StatusOffline() => RuntimeConnection.offline,
      StatusNoPeer() => RuntimeConnection.connecting,
    };
    final presence =
        (status is StatusOnline && _conn.isRoomLive(epk, room))
        ? RuntimePresence.alive
        : (status is StatusOnline
              ? RuntimePresence.stale
              : RuntimePresence.unknown);
    // ignore: discarded_futures
    _enqueue(() async {
      _store.putRuntime(
        epk,
        room,
        RuntimeRecord(connection: connection, presence: presence),
      );
    });
  }

  // ---------------------------------------------------------------------------
  // Streaming (in-memory only)
  // ---------------------------------------------------------------------------

  void _trackAssistantTurn(String inReplyTo) {
    if (_assistantReplyTo == inReplyTo) return;
    // A new reply must not inherit either buffered text or the segment count
    // of a prior turn, even when no idle transition occurred between them.
    _finalizeSegment();
    _assistantReplyTo = inReplyTo;
    _lastFinalizedSegmentId = null;
    _finalizedSegmentsCount = 0;
    _turnEnded = false;
  }

  void _flushChunks() {
    if (_chunkBuffer.isEmpty) return;
    final delta = _chunkBuffer.toString();
    _chunkBuffer.clear();
    final cur = _streaming;
    if (cur != null && cur.inReplyTo == _chunkReplyTo) {
      _emitStreaming(cur.appendDelta(delta));
    } else {
      _emitStreaming(StreamingMessage(inReplyTo: _chunkReplyTo, buffer: delta));
    }
  }

  /// Persist the accumulated streaming text as a standalone assistant row
  /// (unique id, in chronological seq order) and clear the live cursor.
  /// Called at every tool boundary AND on agent_done so text/tool/text
  /// renders sequentially. No-op (just clears the cursor) when there's no
  /// text — so a tool-only or empty turn never leaves a blank bubble.
  /// Returns the finalized text (empty if none).
  String _finalizeSegment() {
    // Drain any coalesced delta still sitting in the 16ms buffer.
    _flushTimer?.cancel();
    _flushTimer = null;
    if (_chunkBuffer.isNotEmpty) {
      final delta = _chunkBuffer.toString();
      _chunkBuffer.clear();
      final cur = _streaming;
      _streaming = (cur != null && cur.inReplyTo == _chunkReplyTo)
          ? cur.appendDelta(delta)
          : StreamingMessage(inReplyTo: _chunkReplyTo, buffer: delta);
    }
    final text = _streaming?.buffer ?? '';
    if (text.isNotEmpty) {
      _finalizedSegmentsCount++;
      final id = 'agent_${uuid7()}';
      _lastFinalizedSegmentId = id;
      // ignore: discarded_futures
      _upsert(
        MsgRole.assistant,
        id,
        (seq, _) => MessageRecord(
          id: id,
          seq: seq,
          role: MsgRole.assistant,
          text: text,
          ts: DateTime.now(),
        ),
      );
    }
    _chunkReplyTo = '';
    _emitStreaming(null);
    return text;
  }

  void _discardStreamingState() {
    _flushTimer?.cancel();
    _flushTimer = null;
    _chunkBuffer.clear();
    _chunkReplyTo = '';
    _emitStreaming(null);
  }


  Future<void> _upsertUserEcho(
    String id,
    String text,
    MessageImage? image,
  ) {
    final epk = _activeEpk;
    if (epk == null) return Future<void>.value();
    final room = _activeRoomId;
    return _enqueue(() async {
      if (_activeEpk != epk || _activeRoomId != room) return;
      final mapKey = _key(MsgRole.user, id);
      var existingSeq = _idToSeq[mapKey];

      // Search for an optimistic/sync user row with identical text.
      if (existingSeq == null) {
        for (final entry in _idToSeq.entries) {
          if (!entry.key.startsWith('${MsgRole.user.name}:')) continue;
          final record = _store.messageAt(epk, room, entry.value);
          if (record == null ||
              record.role != MsgRole.user ||
              record.text != text) {
            continue;
          }
          if (record.pending ||
              entry.key.startsWith('${MsgRole.user.name}:sync_') ||
              entry.value == _nextSeq - 1) {
            existingSeq = entry.value;
            _idToSeq[mapKey] = existingSeq;
            break;
          }
        }
      }

      if (existingSeq != null) {
        final existing = _store.messageAt(epk, room, existingSeq);
        if (existing != null) {
          _store.upsertMessage(
            epk,
            room,
            existing.copyWith(pending: false),
          );
        }
      } else {
        final seq = _nextSeq++;
        _store.upsertMessage(
          epk,
          room,
          MessageRecord(
            id: id,
            seq: seq,
            role: MsgRole.user,
            text: text,
            image: image,
            ts: DateTime.now(),
          ),
        );
        _idToSeq[mapKey] = seq;
      }
    });
  }
  void _emitStreaming(StreamingMessage? s) {
    _streaming = s;
    if (!_streamingController.isClosed) _streamingController.add(s);
  }

  // ---------------------------------------------------------------------------

  Future<void> _enqueue(Future<void> Function() op) {
    final next = _writeChain.then((_) => op());
    _writeChain = next.catchError((Object _, StackTrace _) {});
    return next;
  }


  static String _preview(String text, MessageImage? image) {
    if (text.isEmpty && image != null) return '📷 Image';
    return text.length <= 80 ? text : '${text.substring(0, 80)}…';
  }

  static String _newId() => 'cli_${uuid7()}';

  @override
  void dispose() {
    _flushTimer?.cancel();
    _syncDebounce?.cancel();
    _skillsController.close();
    _cancelAllSendTimers();
    _connSub?.cancel();
    _msgSub?.cancel();
    _roomsSub?.cancel();
    _presenceSub?.cancel();
    _streamingController.close();
    _eventController.close();
    _extensionUiController.close();
    _workingController.close();
    _queuedController.close();
  }
}
