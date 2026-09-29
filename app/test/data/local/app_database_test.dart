import 'dart:io';

import 'package:app/data/local/app_database.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('AppDatabase', () {
    test('creates the shared core schema', () {
      final database = AppDatabase.memory();
      addTearDown(database.dispose);

      final tables = database.db
          .select(
            "SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name",
          )
          .map((row) => row['name'] as String)
          .toSet();

      expect(
        tables,
        containsAll(<String>{
          'schema_metadata',
          'legacy_imports',
          'session_index',
          'messages',
          'runtime_sessions',
          'preferences',
        }),
      );
      expect(
        database.db.select(
          "SELECT value FROM schema_metadata WHERE key = 'core.schema_version'",
        ).single['value'],
        '1',
      );
    });

    test('rolls back an outer transaction and drops its notifications', () {
      final database = AppDatabase.memory();
      addTearDown(database.dispose);
      var notifications = 0;

      expect(
        () => database.transaction<void>(() {
          database.db.execute(
            'INSERT INTO preferences(key, value) VALUES (?, ?)',
            <Object?>['answer', '42'],
          );
          database.afterCommit(() => notifications++);
          throw StateError('abort');
        }),
        throwsStateError,
      );

      expect(
        database.db.select(
          'SELECT value FROM preferences WHERE key = ?',
          <Object?>['answer'],
        ),
        isEmpty,
      );
      expect(notifications, 0);
    });

    test('nested rollback is isolated and only committed callbacks run', () {
      final database = AppDatabase.memory();
      addTearDown(database.dispose);
      final notifications = <String>[];

      database.transaction<void>(() {
        database.db.execute(
          'INSERT INTO preferences(key, value) VALUES (?, ?)',
          <Object?>['outer', 'kept'],
        );
        database.afterCommit(() => notifications.add('outer'));

        try {
          database.transaction<void>(() {
            database.db.execute(
              'INSERT INTO preferences(key, value) VALUES (?, ?)',
              <Object?>['inner', 'rolled-back'],
            );
            database.afterCommit(() => notifications.add('inner'));
            throw StateError('inner abort');
          });
        } on StateError {
          // The outer unit deliberately continues after the savepoint rollback.
        }

        expect(notifications, isEmpty);
      });

      expect(
        database.db.select('SELECT key FROM preferences ORDER BY key')
            .map((row) => row['key']),
        <Object?>['outer'],
      );
      expect(notifications, <String>['outer']);
    });

    test('successful nested callbacks wait for the outer commit', () {
      final database = AppDatabase.memory();
      addTearDown(database.dispose);
      final notifications = <String>[];

      database.transaction<void>(() {
        database.afterCommit(() => notifications.add('outer'));
        database.transaction<void>(() {
          database.afterCommit(() => notifications.add('inner'));
        });
        expect(notifications, isEmpty);
      });

      expect(notifications, <String>['outer', 'inner']);
    });

    test('rejects asynchronous transaction callbacks and rolls them back', () {
      final database = AppDatabase.memory();
      addTearDown(database.dispose);

      expect(
        () => database.transaction<Future<void>>(() async {
          database.db.execute(
            'INSERT INTO preferences(key, value) VALUES (?, ?)',
            <Object?>['async', 'unsafe'],
          );
        }),
        throwsStateError,
      );
      expect(
        database.db.select(
          'SELECT value FROM preferences WHERE key = ?',
          <Object?>['async'],
        ),
        isEmpty,
      );
    });

    test('a durable reopen keeps rows but resets volatile runtime', () {
      final dir = Directory.systemTemp.createTempSync('rp_sqlite_reopen_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final path = '${dir.path}/remote_pi.sqlite';

      final first = AppDatabase.openForTest(path);
      first.db.execute(
        'INSERT INTO preferences(key, value) VALUES (?, ?)',
        <Object?>['durable', 'yes'],
      );
      first.db.execute(
        'INSERT INTO runtime_sessions(peer_epk, room_id, connection, presence) '
        'VALUES (?, ?, ?, ?)',
        <Object?>['peer', 'main', 'online', 'alive'],
      );
      first.dispose();

      final reopened = AppDatabase.openForTest(path);
      addTearDown(reopened.dispose);
      expect(
        reopened.db.select(
          'SELECT value FROM preferences WHERE key = ?',
          <Object?>['durable'],
        ).single['value'],
        'yes',
      );
      expect(reopened.db.select('SELECT * FROM runtime_sessions'), isEmpty);
    });
  });
}
