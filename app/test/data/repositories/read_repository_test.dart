import 'package:app/data/local/app_database.dart';
import 'package:app/data/local/records/message_record.dart';
import 'package:app/data/local/records/runtime_record.dart';
import 'package:app/data/local/records/session_index_record.dart';
import 'package:app/data/local/session_store.dart';
import 'package:app/data/repositories/home_read_repository.dart';
import 'package:app/data/repositories/session_read_repository.dart';
import 'package:flutter_test/flutter_test.dart';

MessageRecord _message(int seq, String id, String text) => MessageRecord(
      id: id,
      seq: seq,
      role: MsgRole.user,
      text: text,
      ts: DateTime.fromMillisecondsSinceEpoch(seq + 1),
    );

void main() {
  late AppDatabase database;
  late SessionStore store;

  setUp(() {
    database = AppDatabase.memory();
    store = SessionStore(database);
  });

  tearDown(() {
    store.dispose();
    database.dispose();
  });

  test('watchMessages emits current ordered snapshot then committed updates',
      () async {
    store.upsertMessage('peer', 'main', _message(2, 'b', 'second'));
    store.upsertMessage('peer', 'main', _message(0, 'a', 'first'));
    final repository = SessionReadRepository(store);
    final emissions = <List<MessageRecord>>[];
    final sub = repository.watchMessages('peer', 'main').listen(emissions.add);
    addTearDown(sub.cancel);

    await Future<void>.delayed(Duration.zero);
    expect(emissions.single.map((message) => message.text), <String>[
      'first',
      'second',
    ]);

    store.upsertMessage('peer', 'main', _message(3, 'c', 'third'));
    await Future<void>.delayed(Duration.zero);
    expect(emissions.last.map((message) => message.text), <String>[
      'first',
      'second',
      'third',
    ]);
  });

  test('watchRuntime emits its safe default and committed updates', () async {
    final repository = SessionReadRepository(store);
    final emissions = <RuntimeRecord>[];
    final sub = repository.watchRuntime('peer', 'main').listen(emissions.add);
    addTearDown(sub.cancel);

    await Future<void>.delayed(Duration.zero);
    expect(emissions.single, const RuntimeRecord());

    store.putRuntime(
      'peer',
      'main',
      const RuntimeRecord(
        connection: RuntimeConnection.online,
        presence: RuntimePresence.alive,
      ),
    );
    await Future<void>.delayed(Duration.zero);
    expect(emissions.last.connection, RuntimeConnection.online);
    expect(emissions.last.presence, RuntimePresence.alive);
  });

  test('Home repository snapshot and stream use the durable session index',
      () async {
    final repository = HomeReadRepository(store);
    final emissions = <List<SessionIndexRecord>>[];
    final sub = repository.watchSessions().listen(emissions.add);
    addTearDown(sub.cancel);
    await Future<void>.delayed(Duration.zero);
    expect(emissions.single, isEmpty);

    const record = SessionIndexRecord(
      epk: 'peer',
      roomId: 'main',
      displayName: 'provider:model',
      status: SessionActivity.working,
    );
    store.upsertSession(record);
    await Future<void>.delayed(Duration.zero);

    expect(emissions.last, <SessionIndexRecord>[record]);
    expect(repository.snapshot(), <String, SessionIndexRecord>{
      'peer:main': record,
    });
  });
}
