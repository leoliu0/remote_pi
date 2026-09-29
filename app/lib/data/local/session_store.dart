import 'dart:async';
import 'dart:convert';

import 'package:app/data/local/app_database.dart';
import 'package:app/data/local/records/message_record.dart';
import 'package:app/data/local/records/runtime_record.dart';
import 'package:app/data/local/records/session_index_record.dart';
import 'package:sqlite3/sqlite3.dart' show Row;

/// Typed SQLite boundary for session index, finalized history, and volatile
/// connection state. Callers never emulate Hive box operations.
class SessionStore {
  SessionStore(this._database);

  final AppDatabase _database;
  final StreamController<_SessionKey> _messageChanges =
      StreamController<_SessionKey>.broadcast(sync: true);
  final StreamController<_SessionKey> _runtimeChanges =
      StreamController<_SessionKey>.broadcast(sync: true);
  final StreamController<void> _sessionChanges =
      StreamController<void>.broadcast(sync: true);
  bool _disposed = false;

  List<MessageRecord> messages(String epk, String roomId) {
    _ensureOpen();
    return <MessageRecord>[
      for (final row in _database.db.select(
        '''
        SELECT seq, protocol_id, role, payload_json
        FROM messages
        WHERE peer_epk = ? AND room_id = ?
        ORDER BY seq
        ''',
        <Object?>[epk, roomId],
      ))
        _messageFromRow(row),
    ];
  }

  MessageRecord? messageAt(String epk, String roomId, int seq) {
    _ensureOpen();
    final rows = _database.db.select(
      '''
      SELECT seq, protocol_id, role, payload_json
      FROM messages
      WHERE peer_epk = ? AND room_id = ? AND seq = ?
      ''',
      <Object?>[epk, roomId, seq],
    );
    return rows.isEmpty ? null : _messageFromRow(rows.single);
  }


  bool _hasMessages(String epk, String roomId) {
    _ensureOpen();
    return _database.db.select(
      '''
      SELECT 1 FROM messages
      WHERE peer_epk = ? AND room_id = ?
      LIMIT 1
      ''',
      <Object?>[epk, roomId],
    ).isNotEmpty;
  }

  /// Inserts or updates one row. The protocol identity is unique only within
  /// `(peer, room, role)`, allowing user and assistant rows to share an ID.
  bool upsertMessage(String epk, String roomId, MessageRecord record) {
    _ensureOpen();
    _validateMessage(record);
    final encoded = jsonEncode(record.toJson());
    final existing = _database.db.select(
      '''
      SELECT seq, protocol_id, role, payload_json
      FROM messages
      WHERE peer_epk = ? AND room_id = ? AND role = ? AND protocol_id = ?
      ''',
      <Object?>[epk, roomId, record.role.name, record.id],
    );
    for (final row in existing) {
      _messageFromRow(row);
    }
    if (existing.length == 1 &&
        existing.single['seq'] == record.seq &&
        existing.single['payload_json'] == encoded) {
      return false;
    }

    _database.transaction<void>(() {
      _database.db.execute(
        '''
        DELETE FROM messages
        WHERE peer_epk = ? AND room_id = ? AND role = ? AND protocol_id = ?
          AND seq <> ?
        ''',
        <Object?>[epk, roomId, record.role.name, record.id, record.seq],
      );
      _database.db.execute(
        '''
        INSERT INTO messages(
          peer_epk, room_id, seq, protocol_id, role, payload_json
        ) VALUES (?, ?, ?, ?, ?, ?)
        ON CONFLICT(peer_epk, room_id, seq) DO UPDATE SET
          protocol_id = excluded.protocol_id,
          role = excluded.role,
          payload_json = excluded.payload_json
        ''',
        <Object?>[
          epk,
          roomId,
          record.seq,
          record.id,
          record.role.name,
          encoded,
        ],
      );
      _notifyMessagesAfterCommit(epk, roomId);
    });
    return true;
  }

  bool deleteMessage(String epk, String roomId, int seq) {
    _ensureOpen();
    if (messageAt(epk, roomId, seq) == null) return false;
    _database.transaction<void>(() {
      _database.db.execute(
        '''
        DELETE FROM messages
        WHERE peer_epk = ? AND room_id = ? AND seq = ?
        ''',
        <Object?>[epk, roomId, seq],
      );
      _notifyMessagesAfterCommit(epk, roomId);
    });
    return true;
  }

  /// Atomically reconciles a complete session history. An identical replay is
  /// a no-op and emits nothing; a changed replay is visible only after commit.
  bool replaceMessages(
    String epk,
    String roomId,
    List<MessageRecord> desired,
  ) {
    _ensureOpen();
    _validateMessages(desired);
    final encodedDesired = <String>[
      for (final record in desired) jsonEncode(record.toJson()),
    ];
    final current = _database.db.select(
      '''
      SELECT seq, protocol_id, role, payload_json
      FROM messages
      WHERE peer_epk = ? AND room_id = ?
      ORDER BY seq
      ''',
      <Object?>[epk, roomId],
    );
    var identical = current.length == desired.length;
    for (var i = 0; i < current.length; i++) {
      final row = current[i];
      _messageFromRow(row); // Surface corruption instead of overwriting it.
      final payload = row['payload_json'] as String;
      if (identical &&
          (current[i]['seq'] != desired[i].seq ||
              payload != encodedDesired[i])) {
        identical = false;
      }
    }
    if (identical) return false;

    _database.transaction<void>(() {
      _database.db.execute(
        'DELETE FROM messages WHERE peer_epk = ? AND room_id = ?',
        <Object?>[epk, roomId],
      );
      final insert = _database.db.prepare('''
        INSERT INTO messages(
          peer_epk, room_id, seq, protocol_id, role, payload_json
        ) VALUES (?, ?, ?, ?, ?, ?)
      ''');
      try {
        for (var i = 0; i < desired.length; i++) {
          final record = desired[i];
          insert.execute(<Object?>[
            epk,
            roomId,
            record.seq,
            record.id,
            record.role.name,
            encodedDesired[i],
          ]);
        }
      } finally {
        insert.dispose();
      }
      _notifyMessagesAfterCommit(epk, roomId);
    });
    return true;
  }

  /// Clears message rows and their durable Home index as one visible mutation.
  bool clearSession(String epk, String roomId) {
    _ensureOpen();
    final hadMessages = _hasMessages(epk, roomId);
    final hadSession = session(epk, roomId) != null;
    if (!hadMessages && !hadSession) return false;

    _database.transaction<void>(() {
      _database.db.execute(
        'DELETE FROM messages WHERE peer_epk = ? AND room_id = ?',
        <Object?>[epk, roomId],
      );
      _database.db.execute(
        'DELETE FROM session_index WHERE peer_epk = ? AND room_id = ?',
        <Object?>[epk, roomId],
      );
      if (hadMessages) _notifyMessagesAfterCommit(epk, roomId);
      if (hadSession) _notifySessionsAfterCommit();
    });
    return true;
  }

  /// Clears transient steering labels in one transaction and one notification.
  bool clearSteeringLabels(String epk, String roomId, {String? id}) {
    final current = messages(epk, roomId);
    final desired = <MessageRecord>[];
    var changed = false;
    for (final record in current) {
      if (record.role == MsgRole.user &&
          record.steering &&
          (id == null || record.id == id)) {
        desired.add(record.copyWith(steering: false));
        changed = true;
      } else {
        desired.add(record);
      }
    }
    return changed && replaceMessages(epk, roomId, desired);
  }

  Stream<List<MessageRecord>> watchMessages(String epk, String roomId) {
    _ensureOpen();
    final key = _SessionKey(epk, roomId);
    StreamSubscription<_SessionKey>? subscription;
    late final StreamController<List<MessageRecord>> controller;
    controller = StreamController<List<MessageRecord>>(
      onListen: () {
        subscription = _messageChanges.stream
            .where((changed) => changed == key)
            .listen(
              (_) {
                if (!controller.isClosed) {
                  controller.add(messages(epk, roomId));
                }
              },
              onDone: () {
                if (!controller.isClosed) controller.close();
              },
            );
        if (!controller.isClosed) controller.add(messages(epk, roomId));
      },
      onCancel: () => subscription?.cancel(),
    );
    return controller.stream;
  }

  SessionIndexRecord? session(String epk, String roomId) {
    _ensureOpen();
    final rows = _database.db.select(
      '''
      SELECT * FROM session_index
      WHERE peer_epk = ? AND room_id = ?
      ''',
      <Object?>[epk, roomId],
    );
    return rows.isEmpty ? null : _sessionFromRow(rows.single);
  }

  List<SessionIndexRecord> sessions() {
    _ensureOpen();
    return <SessionIndexRecord>[
      for (final row in _database.db.select('''
        SELECT * FROM session_index
        ORDER BY COALESCE(last_message_at_ms, 0) DESC, peer_epk, room_id
      '''))
        _sessionFromRow(row),
    ];
  }

  bool upsertSession(SessionIndexRecord record) {
    _ensureOpen();
    if (session(record.epk, record.roomId) == record) return false;
    _database.transaction<void>(() {
      _database.db.execute(
        '''
        INSERT INTO session_index(
          peer_epk, room_id, display_name, activity,
          last_message_at_ms, last_message_preview, session_started_at_ms
        ) VALUES (?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(peer_epk, room_id) DO UPDATE SET
          display_name = excluded.display_name,
          activity = excluded.activity,
          last_message_at_ms = excluded.last_message_at_ms,
          last_message_preview = excluded.last_message_preview,
          session_started_at_ms = excluded.session_started_at_ms
        ''',
        <Object?>[
          record.epk,
          record.roomId,
          record.displayName,
          record.status.name,
          record.lastMessageAt?.millisecondsSinceEpoch,
          record.lastMessagePreview,
          record.sessionStartedAt?.millisecondsSinceEpoch,
        ],
      );
      _notifySessionsAfterCommit();
    });
    return true;
  }


  Stream<List<SessionIndexRecord>> watchSessions() {
    _ensureOpen();
    StreamSubscription<void>? subscription;
    late final StreamController<List<SessionIndexRecord>> controller;
    controller = StreamController<List<SessionIndexRecord>>(
      onListen: () {
        subscription = _sessionChanges.stream.listen(
          (_) {
            if (!controller.isClosed) controller.add(sessions());
          },
          onDone: () {
            if (!controller.isClosed) controller.close();
          },
        );
        if (!controller.isClosed) controller.add(sessions());
      },
      onCancel: () => subscription?.cancel(),
    );
    return controller.stream;
  }

  RuntimeRecord runtime(String epk, String roomId) {
    _ensureOpen();
    final rows = _database.db.select(
      '''
      SELECT connection, presence FROM runtime_sessions
      WHERE peer_epk = ? AND room_id = ?
      ''',
      <Object?>[epk, roomId],
    );
    if (rows.isEmpty) return const RuntimeRecord();
    return RuntimeRecord.fromJson(<String, dynamic>{
      'connection': rows.single['connection'],
      'presence': rows.single['presence'],
    });
  }

  bool putRuntime(String epk, String roomId, RuntimeRecord record) {
    _ensureOpen();
    if (runtime(epk, roomId) == record) return false;
    _database.transaction<void>(() {
      _database.db.execute(
        '''
        INSERT INTO runtime_sessions(peer_epk, room_id, connection, presence)
        VALUES (?, ?, ?, ?)
        ON CONFLICT(peer_epk, room_id) DO UPDATE SET
          connection = excluded.connection,
          presence = excluded.presence
        ''',
        <Object?>[
          epk,
          roomId,
          record.connection.name,
          record.presence.name,
        ],
      );
      _database.afterCommit(() {
        if (!_runtimeChanges.isClosed) {
          _runtimeChanges.add(_SessionKey(epk, roomId));
        }
      });
    });
    return true;
  }

  Stream<RuntimeRecord> watchRuntime(String epk, String roomId) {
    _ensureOpen();
    final key = _SessionKey(epk, roomId);
    StreamSubscription<_SessionKey>? subscription;
    late final StreamController<RuntimeRecord> controller;
    controller = StreamController<RuntimeRecord>(
      onListen: () {
        subscription = _runtimeChanges.stream
            .where((changed) => changed == key)
            .listen(
              (_) {
                if (!controller.isClosed) {
                  controller.add(runtime(epk, roomId));
                }
              },
              onDone: () {
                if (!controller.isClosed) controller.close();
              },
            );
        if (!controller.isClosed) controller.add(runtime(epk, roomId));
      },
      onCancel: () => subscription?.cancel(),
    );
    return controller.stream;
  }

  void _notifyMessagesAfterCommit(String epk, String roomId) {
    _database.afterCommit(() {
      if (!_messageChanges.isClosed) {
        _messageChanges.add(_SessionKey(epk, roomId));
      }
    });
  }

  void _notifySessionsAfterCommit() {
    _database.afterCommit(() {
      if (!_sessionChanges.isClosed) _sessionChanges.add(null);
    });
  }

  static MessageRecord _decodeMessage(String encoded) {
    final decoded = jsonDecode(encoded);
    if (decoded is! Map) {
      throw const FormatException('Stored message payload is not an object.');
    }
    return MessageRecord.fromJson(decoded.cast<String, dynamic>());
  }

  static MessageRecord _messageFromRow(Row row) {
    final payload = row['payload_json'];
    if (payload is! String) {
      throw const FormatException('Stored message payload is not text.');
    }
    final record = _decodeMessage(payload);
    if (row['seq'] != record.seq ||
        row['protocol_id'] != record.id ||
        row['role'] != record.role.name) {
      throw const FormatException(
        'Stored message metadata does not match its payload.',
      );
    }
    return record;
  }

  static SessionIndexRecord _sessionFromRow(Row row) =>
      SessionIndexRecord.fromJson(<String, dynamic>{
        'epk': row['peer_epk'],
        'room_id': row['room_id'],
        'display_name': row['display_name'],
        'status': row['activity'],
        'last_message_at': row['last_message_at_ms'],
        'last_message_preview': row['last_message_preview'],
        'session_started_at': row['session_started_at_ms'],
      });


  static void _validateMessage(MessageRecord record) {
    if (record.seq < 0) {
      throw ArgumentError.value(record.seq, 'record.seq', 'must be non-negative');
    }
    if (record.id.isEmpty) {
      throw ArgumentError.value(record.id, 'record.id', 'must not be empty');
    }
  }

  static void _validateMessages(List<MessageRecord> records) {
    final sequences = <int>{};
    final identities = <String>{};
    for (final record in records) {
      _validateMessage(record);
      if (!sequences.add(record.seq)) {
        throw ArgumentError('Duplicate message sequence ${record.seq}.');
      }
      final identity = '${record.role.name}\u0000${record.id}';
      if (!identities.add(identity)) {
        throw ArgumentError(
          'Duplicate message identity ${record.role.name}:${record.id}.',
        );
      }
    }
  }

  void _ensureOpen() {
    if (_disposed) throw StateError('SessionStore has been disposed.');
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _messageChanges.close();
    _runtimeChanges.close();
    _sessionChanges.close();
  }
}

class _SessionKey {
  const _SessionKey(this.epk, this.roomId);

  final String epk;
  final String roomId;

  @override
  bool operator ==(Object other) =>
      other is _SessionKey && other.epk == epk && other.roomId == roomId;

  @override
  int get hashCode => Object.hash(epk, roomId);
}
