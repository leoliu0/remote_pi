import 'dart:convert';

import 'dart:io';

import 'package:app/data/local/app_database.dart';
import 'package:app/data/local/records/message_record.dart';
import 'package:app/data/local/records/runtime_record.dart';
import 'package:app/data/local/records/session_index_record.dart';
import 'package:app/data/local/session_store.dart';
import 'package:app/domain/session_state.dart';
import 'package:flutter_test/flutter_test.dart';

MessageRecord _message({
  required String id,
  required int seq,
  MsgRole role = MsgRole.user,
  String text = 'hello',
}) =>
    MessageRecord(
      id: id,
      seq: seq,
      role: role,
      text: text,
      image: role == MsgRole.user
          ? const MessageImage(data: 'QUJD', mime: 'image/jpeg')
          : null,
      tool: role == MsgRole.tool
          ? const ToolEventData(
              toolCallId: 'tool-1',
              tool: 'bash',
              args: <String, Object?>{'command': 'pwd'},
              status: ToolEventStatus.completed,
              result: <String, Object?>{'stdout': '/tmp'},
            )
          : null,
      ts: DateTime.fromMillisecondsSinceEpoch(1700000000000 + seq),
      pending: role == MsgRole.user,
      steering: role == MsgRole.user,
      tokensBefore: role == MsgRole.compaction ? 123 : null,
    );

void main() {
  group('SessionStore', () {
    test('reopen preserves stable scoped IDs and every rendered field', () {
      final dir = Directory.systemTemp.createTempSync('rp_store_reopen_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final path = '${dir.path}/remote_pi.sqlite';

      final firstDb = AppDatabase.openForTest(path);
      final first = SessionStore(firstDb);
      final rows = <MessageRecord>[
        _message(id: 'shared-id', seq: 0),
        _message(
          id: 'shared-id',
          seq: 1,
          role: MsgRole.assistant,
          text: 'answer',
        ),
        _message(id: 'tool-id', seq: 2, role: MsgRole.tool, text: ''),
        _message(
          id: 'compact-id',
          seq: 3,
          role: MsgRole.compaction,
          text: 'summary',
        ),
      ];
      final expectedSession = SessionIndexRecord(
        epk: 'peer+/=',
        roomId: 'room:one',
        displayName: 'provider:model',
        status: SessionActivity.working,
        lastMessageAt: DateTime.fromMillisecondsSinceEpoch(1700000000123),
        lastMessagePreview: 'answer',
        sessionStartedAt: DateTime.fromMillisecondsSinceEpoch(1699999999000),
      );
      first.replaceMessages('peer+/=', 'room:one', rows);
      first.upsertSession(expectedSession);
      first.dispose();
      firstDb.dispose();

      final reopenedDb = AppDatabase.openForTest(path);
      final reopened = SessionStore(reopenedDb);
      addTearDown(reopened.dispose);
      addTearDown(reopenedDb.dispose);

      expect(
        reopened.messages('peer+/=', 'room:one').map((row) => row.toJson()),
        rows.map((row) => row.toJson()),
      );
      expect(
        reopened.session('peer+/=', 'room:one'),
        expectedSession,
      );
      expect(reopened.messages('peer+/=', 'other-room'), isEmpty);
      expect(reopened.messages('other-peer', 'room:one'), isEmpty);
    });

    test('same protocol ID is unique per session and role, not globally', () {
      final database = AppDatabase.memory();
      final store = SessionStore(database);
      addTearDown(store.dispose);
      addTearDown(database.dispose);

      store.upsertMessage('peer-a', 'main', _message(id: 'id-1', seq: 0));
      store.upsertMessage(
        'peer-a',
        'main',
        _message(
          id: 'id-1',
          seq: 1,
          role: MsgRole.assistant,
          text: 'reply',
        ),
      );
      store.upsertMessage(
        'peer-b',
        'main',
        _message(id: 'id-1', seq: 0, text: 'other session'),
      );
      store.upsertMessage(
        'peer-a',
        'main',
        _message(id: 'id-1', seq: 4, text: 'updated'),
      );

      final first = store.messages('peer-a', 'main');
      expect(first, hasLength(2));
      expect(first.map((row) => row.role), <MsgRole>[
        MsgRole.assistant,
        MsgRole.user,
      ]);
      expect(first.singleWhere((row) => row.role == MsgRole.user).seq, 4);
      expect(
        store.messages('peer-b', 'main').single.text,
        'other session',
      );
    });

    test('message notifications happen after commit and never on rollback', () async {
      final database = AppDatabase.memory();
      final store = SessionStore(database);
      addTearDown(store.dispose);
      addTearDown(database.dispose);
      final snapshots = <List<MessageRecord>>[];
      final sub = store.watchMessages('peer', 'main').listen(snapshots.add);
      addTearDown(sub.cancel);
      await Future<void>.delayed(Duration.zero);
      expect(snapshots, <List<MessageRecord>>[<MessageRecord>[]]);

      expect(
        () => database.transaction<void>(() {
          store.upsertMessage('peer', 'main', _message(id: 'rolled', seq: 0));
          expect(snapshots, hasLength(1));
          throw StateError('rollback');
        }),
        throwsStateError,
      );
      await Future<void>.delayed(Duration.zero);
      expect(snapshots, hasLength(1));
      expect(store.messages('peer', 'main'), isEmpty);

      database.transaction<void>(() {
        store.upsertMessage('peer', 'main', _message(id: 'kept', seq: 0));
        expect(snapshots, hasLength(1));
      });
      await Future<void>.delayed(Duration.zero);
      expect(snapshots, hasLength(2));
      expect(snapshots.last.single.id, 'kept');
    });

    test('identical history reconciliation performs no write or notification',
        () async {
      final database = AppDatabase.memory();
      final store = SessionStore(database);
      addTearDown(store.dispose);
      addTearDown(database.dispose);
      final row = _message(id: 'same', seq: 0);
      store.replaceMessages('peer', 'main', <MessageRecord>[row]);

      var emissions = 0;
      final sub = store
          .watchMessages('peer', 'main')
          .listen((_) => emissions++);
      addTearDown(sub.cancel);
      await Future<void>.delayed(Duration.zero);
      expect(emissions, 1);

      expect(
        store.replaceMessages('peer', 'main', <MessageRecord>[row]),
        isFalse,
      );
      await Future<void>.delayed(Duration.zero);
      expect(emissions, 1);
    });

    test('a corrupt durable message surfaces instead of looking empty', () {
      final database = AppDatabase.memory();
      final store = SessionStore(database);
      addTearDown(store.dispose);
      addTearDown(database.dispose);
      database.db.execute(
        '''
        INSERT INTO messages(
          peer_epk, room_id, seq, protocol_id, role, payload_json
        ) VALUES (?, ?, ?, ?, ?, ?)
        ''',
        <Object?>['peer', 'main', 0, 'broken', 'user', '{'],
      );

      expect(() => store.messages('peer', 'main'), throwsFormatException);
      expect(
        database.db.select('SELECT * FROM messages'),
        hasLength(1),
        reason: 'a failed read must not delete or replace the source row',
      );
    });

    test('message metadata corruption is surfaced and never overwritten', () {
      final database = AppDatabase.memory();
      final store = SessionStore(database);
      addTearDown(store.dispose);
      addTearDown(database.dispose);
      final payload = jsonEncode(_message(id: 'payload-id', seq: 0).toJson());
      database.db.execute(
        '''
        INSERT INTO messages(
          peer_epk, room_id, seq, protocol_id, role, payload_json
        ) VALUES (?, ?, ?, ?, ?, ?)
        ''',
        <Object?>['peer', 'main', 0, 'metadata-id', 'user', payload],
      );

      expect(() => store.messages('peer', 'main'), throwsFormatException);
      expect(
        () => store.upsertMessage(
          'peer',
          'main',
          _message(id: 'metadata-id', seq: 0),
        ),
        throwsFormatException,
      );
      expect(
        database.db
            .select('SELECT payload_json FROM messages')
            .single['payload_json'],
        payload,
      );
    });

    test('runtime is observable in-process and absent after reopen', () async {
      final dir = Directory.systemTemp.createTempSync('rp_runtime_reset_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final path = '${dir.path}/remote_pi.sqlite';
      final firstDb = AppDatabase.openForTest(path);
      final first = SessionStore(firstDb);
      final seen = <RuntimeRecord>[];
      final sub = first.watchRuntime('peer', 'main').listen(seen.add);
      await Future<void>.delayed(Duration.zero);
      expect(seen.single, const RuntimeRecord());

      first.putRuntime(
        'peer',
        'main',
        const RuntimeRecord(
          connection: RuntimeConnection.online,
          presence: RuntimePresence.alive,
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(seen.last.connection, RuntimeConnection.online);
      await sub.cancel();
      first.dispose();
      firstDb.dispose();

      final reopenedDb = AppDatabase.openForTest(path);
      final reopened = SessionStore(reopenedDb);
      addTearDown(reopened.dispose);
      addTearDown(reopenedDb.dispose);
      expect(reopened.runtime('peer', 'main'), const RuntimeRecord());
    });
  });
}
