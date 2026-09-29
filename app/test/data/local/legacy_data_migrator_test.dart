import 'dart:io';

import 'package:app/data/local/app_database.dart';
import 'package:app/data/local/legacy_data_migrator.dart';
import 'package:app/data/local/records/message_record.dart';
import 'package:app/data/local/records/runtime_record.dart';
import 'package:app/data/local/records/session_index_record.dart';
import 'package:app/data/local/session_store.dart';
import 'package:app/data/transport/epk_encoding.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

class _FakeLegacyPreferences implements LegacyPreferencesSource {
  _FakeLegacyPreferences(this.values, {this.error});

  final Map<String, String> values;
  final Object? error;
  final List<Set<String>> requestedKeys = <Set<String>>[];

  @override
  Future<Map<String, String>> read(Set<String> knownKeys) async {
    requestedKeys.add(Set<String>.from(knownKeys));
    if (error case final error?) throw error;
    return <String, String>{
      for (final entry in values.entries)
        if (knownKeys.contains(entry.key) || entry.key.startsWith('prefs.draft.'))
          entry.key: entry.value,
    };
  }
}

class _EnumeratedStorage implements FlutterSecureStorage {
  _EnumeratedStorage(this.values);

  final Map<String, String> values;

  @override
  Future<String?> read({
    required String key,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async =>
      values[key];

  @override
  Future<Map<String, String>> readAll({
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async =>
      Map<String, String>.from(values);

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}

class _ReadAllFailingStorage implements FlutterSecureStorage {
  _ReadAllFailingStorage(this.values);

  final Map<String, String> values;

  @override
  Future<String?> read({
    required String key,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async =>
      values[key];

  @override
  Future<Map<String, String>> readAll({
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async =>
      throw StateError('secure storage enumeration failed');

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}

MessageRecord _legacyMessage(int seq, String id, String text) => MessageRecord(
      id: id,
      seq: seq,
      role: MsgRole.user,
      text: text,
      ts: DateTime.fromMillisecondsSinceEpoch(1700000000000 + seq),
    );

Future<void> _seedHive(
  String path, {
  String epk = 'cGVlcg',
  List<Object?> messages = const <Object?>[],
  Object? index,
  Map<String, Object?> appPreferences = const <String, Object?>{},
}) async {
  Hive.init(path);
  final indexBox = await Hive.openBox<dynamic>('sessions_index');
  await indexBox.put(
    '$epk:main',
    index ??
        SessionIndexRecord(
          epk: epk,
          roomId: 'main',
          displayName: 'provider:model',
          status: SessionActivity.idle,
        ).toJson(),
  );
  final messagesBox = await Hive.openBox<dynamic>(
    'msgs_${toAppEpk(epk)}__main',
  );
  for (var i = 0; i < messages.length; i++) {
    await messagesBox.put(i, messages[i]);
  }
  final preferences = await Hive.openBox<dynamic>('app_prefs');
  for (final entry in appPreferences.entries) {
    await preferences.put(entry.key, entry.value);
  }
  await Hive.close();
}

void main() {
  group('LegacyDataMigrator', () {
    late Directory legacyDirectory;
    late Directory supportDirectory;
    late AppDatabase database;
    late SessionStore store;

    setUp(() {
      legacyDirectory = Directory.systemTemp.createTempSync('rp_hive_legacy_');
      supportDirectory = Directory.systemTemp.createTempSync('rp_support_');
      database = AppDatabase.memory();
      store = SessionStore(database);
    });

    tearDown(() async {
      store.dispose();
      database.dispose();
      await Hive.close();
      legacyDirectory.deleteSync(recursive: true);
      supportDirectory.deleteSync(recursive: true);
    });
    test('secure adapter imports app preferences without private rows',
        () async {
      final source = SecureLegacyPreferencesSource(
        _EnumeratedStorage(<String, String>{
          'prefs.relay_url': 'https://direct.example',
          'prefs.font_scale': 'standard',
          'pairing.secret': 'must-not-import',
        }),
      );

      final values = await source.read(<String>{
        'prefs.relay_url',
        'prefs.font_scale',
      });
      expect(values, <String, String>{
        'prefs.relay_url': 'https://direct.example',
        'prefs.font_scale': 'standard',
      });
    });


    test('imports Hive history/index and secure/file preferences exactly once',
        () async {
      const epk = 'cGVlcitpZD0';
      final first = _legacyMessage(0, 'stable-1', 'first');
      final second = _legacyMessage(1, 'stable-2', 'second');
      await _seedHive(
        legacyDirectory.path,
        epk: epk,
        messages: <Object?>[first.toJson(), second.toJson()],
        appPreferences: const <String, Object?>{
          'relay_url': 'https://hive.example',
          'prefs.theme_mode': 'light',
        },
      );
      Hive.init(legacyDirectory.path);
      final legacyRuntime = await Hive.openBox<dynamic>('runtime');
      await legacyRuntime.put(
        '$epk:main',
        const RuntimeRecord(
          connection: RuntimeConnection.online,
          presence: RuntimePresence.alive,
        ).toJson(),
      );
      await Hive.close();
      final relayFile = File('${supportDirectory.path}/relay_url.txt')
        ..writeAsStringSync('https://file.example', flush: true);
      final secure = _FakeLegacyPreferences(<String, String>{
        'prefs.relay_url': 'https://secure.example',
        'prefs.selected_peer_epk': '$epk:main',
        'prefs.font_scale': 'standard',
        'prefs.draft.$epk:main': 'unfinished',
      });
      final migrator = LegacyDataMigrator(
        database,
        hiveSource: LegacyHiveSource.forPath(legacyDirectory.path),
        securePreferences: secure,
        relayFileOverride: relayFile,
      );

      final report = await migrator.migrate();

      expect(report.alreadyCompleted, isFalse);
      expect(report.sessionsImported, 1);
      expect(report.messagesImported, 2);
      expect(
        secure.requestedKeys.first,
        contains('prefs.draft.$epk:main'),
      );
      expect(store.session(epk, 'main')?.displayName, 'provider:model');
      expect(
        store.messages(epk, 'main').map((row) => row.toJson()),
        <Map<String, dynamic>>[first.toJson(), second.toJson()],
      );
      expect(
        store.runtime(epk, 'main'),
        const RuntimeRecord(),
        reason: 'legacy online state must never become durable SQLite state',
      );
      final preferences = <String, Object?>{
        for (final row in database.db.select(
          'SELECT key, value FROM preferences ORDER BY key',
        ))
          row['key'] as String: row['value'],
      };
      expect(preferences['prefs.relay_url'], 'https://file.example');
      expect(preferences['prefs.theme_mode'], 'light');
      expect(preferences['prefs.font_scale'], 'standard');
      expect(preferences['prefs.draft.$epk:main'], 'unfinished');
      expect(
        database.db.select('SELECT * FROM legacy_imports'),
        hasLength(1),
      );

      // A committed marker makes retries no-ops and never lets stale legacy
      // values overwrite a post-cutover SQLite change.
      database.db.execute(
        'UPDATE preferences SET value = ? WHERE key = ?',
        <Object?>['dark', 'prefs.theme_mode'],
      );
      final secondReport = await migrator.migrate();
      expect(secondReport.alreadyCompleted, isTrue);
      expect(
        database.db.select(
          'SELECT value FROM preferences WHERE key = ?',
          <Object?>['prefs.theme_mode'],
        ).single['value'],
        'dark',
      );

      // Import is non-destructive: all legacy rows and the relay backup remain.
      Hive.init(legacyDirectory.path);
      final legacyIndex = await Hive.openBox<dynamic>('sessions_index');
      final legacyMessages = await Hive.openBox<dynamic>(
        'msgs_${toAppEpk(epk)}__main',
      );
      final retainedRuntime = await Hive.openBox<dynamic>('runtime');
      expect(legacyIndex.get('$epk:main'), isNotNull);
      expect(legacyMessages.length, 2);
      expect(retainedRuntime.get('$epk:main'), isNotNull);
      expect(relayFile.readAsStringSync(), 'https://file.example');
    });

    test('a write interruption rolls back every row and is retry-safe',
        () async {
      final rows = <MessageRecord>[
        _legacyMessage(0, 'one', 'first'),
        _legacyMessage(1, 'two', 'second'),
      ];
      await _seedHive(
        legacyDirectory.path,
        messages: rows.map((row) => row.toJson()).toList(),
      );
      final migrator = LegacyDataMigrator(
        database,
        hiveSource: LegacyHiveSource.forPath(legacyDirectory.path),
        securePreferences: _FakeLegacyPreferences(<String, String>{}),
        relayFileOverride: File('${supportDirectory.path}/missing.txt'),
      );
      database.db.execute('''
        CREATE TRIGGER interrupt_legacy_import
        BEFORE INSERT ON messages
        WHEN NEW.seq = 1
        BEGIN
          SELECT RAISE(ABORT, 'simulated interruption');
        END
      ''');

      await expectLater(
        migrator.migrate(),
        throwsA(isA<LegacyMigrationException>()),
      );
      expect(database.db.select('SELECT * FROM session_index'), isEmpty);
      expect(database.db.select('SELECT * FROM messages'), isEmpty);
      expect(database.db.select('SELECT * FROM legacy_imports'), isEmpty);

      database.db.execute('DROP TRIGGER interrupt_legacy_import');
      final retried = await migrator.migrate();
      expect(retried.alreadyCompleted, isFalse);
      expect(store.messages('cGVlcg', 'main'), hasLength(2));
      expect(database.db.select('SELECT * FROM legacy_imports'), hasLength(1));
    });

    test('a corrupt known Hive row is an error, never an empty import',
        () async {
      await _seedHive(
        legacyDirectory.path,
        messages: const <Object?>['not-a-message-map'],
      );
      final migrator = LegacyDataMigrator(
        database,
        hiveSource: LegacyHiveSource.forPath(legacyDirectory.path),
        securePreferences: _FakeLegacyPreferences(<String, String>{}),
        relayFileOverride: File('${supportDirectory.path}/missing.txt'),
      );

      await expectLater(
        migrator.migrate(),
        throwsA(
          isA<LegacyMigrationException>().having(
            (error) => error.source,
            'source',
            contains('Hive'),
          ),
        ),
      );
      expect(database.db.select('SELECT * FROM messages'), isEmpty);
      expect(database.db.select('SELECT * FROM legacy_imports'), isEmpty);

      Hive.init(legacyDirectory.path);
      final source = await Hive.openBox<dynamic>('msgs_cGVlcg__main');
      expect(source.get(0), 'not-a-message-map');
    });

    test('an orphan message box is an error, not an empty successful import',
        () async {
      Hive.init(legacyDirectory.path);
      final orphan = await Hive.openBox<dynamic>('msgs_orphan__main');
      await orphan.put(0, _legacyMessage(0, 'orphan', 'keep me').toJson());
      await Hive.close();
      final migrator = LegacyDataMigrator(
        database,
        hiveSource: LegacyHiveSource.forPath(legacyDirectory.path),
        securePreferences: _FakeLegacyPreferences(<String, String>{}),
        relayFileOverride: File('${supportDirectory.path}/missing.txt'),
      );

      await expectLater(
        migrator.migrate(),
        throwsA(isA<LegacyMigrationException>()),
      );
      expect(database.db.select('SELECT * FROM messages'), isEmpty);
      expect(database.db.select('SELECT * FROM legacy_imports'), isEmpty);
      expect(
        File('${legacyDirectory.path}/msgs_orphan__main.hive').existsSync(),
        isTrue,
      );
    });

    test(
        'empty orphan message file left by New Session does not block migration',
        () async {
      const epk = 'cGVlcg';
      await _seedHive(
        legacyDirectory.path,
        epk: epk,
        messages: <Object?>[
          _legacyMessage(0, 'cleared', 'removed by New Session').toJson(),
        ],
      );
      Hive.init(legacyDirectory.path);
      final legacyIndex = await Hive.openBox<dynamic>('sessions_index');
      final clearedMessages = await Hive.openBox<dynamic>(
        'msgs_${toAppEpk(epk)}__main',
      );
      await clearedMessages.clear();
      await legacyIndex.delete('$epk:main');
      await Hive.close();
      final clearedBoxFileName =
          'msgs_${toAppEpk(epk)}__main.hive'.toLowerCase();
      final clearedFile = File(
        '${legacyDirectory.path}/$clearedBoxFileName',
      );
      expect(clearedFile.existsSync(), isTrue);

      final report = await LegacyDataMigrator(
        database,
        hiveSource: LegacyHiveSource.forPath(legacyDirectory.path),
        securePreferences: _FakeLegacyPreferences(<String, String>{}),
        relayFileOverride: File('${supportDirectory.path}/missing.txt'),
      ).migrate();

      expect(report.sessionsImported, 0);
      expect(report.messagesImported, 0);
      expect(database.db.select('SELECT * FROM legacy_imports'), hasLength(1));
      expect(clearedFile.existsSync(), isTrue);
    });

    test('secure preference read failure is surfaced and leaves no marker',
        () async {
      final migrator = LegacyDataMigrator(
        database,
        hiveSource: LegacyHiveSource.forPath(legacyDirectory.path),
        securePreferences: _FakeLegacyPreferences(
          <String, String>{},
          error: StateError('keystore unavailable'),
        ),
        relayFileOverride: File('${supportDirectory.path}/missing.txt'),
      );

      await expectLater(
        migrator.migrate(),
        throwsA(
          isA<LegacyMigrationException>().having(
            (error) => error.source,
            'source',
            contains('preferences'),
          ),
        ),
      );
      expect(database.db.select('SELECT * FROM preferences'), isEmpty);
      expect(database.db.select('SELECT * FROM legacy_imports'), isEmpty);
    });

    test(
        'readAll failure with an unenumerated draft withholds completion marker',
        () async {
      const orphanDraftKey = 'prefs.draft.cleared-peer:offline-room';
      final legacyStorage = _ReadAllFailingStorage(<String, String>{
        'prefs.relay_url': 'https://still-readable.example',
        orphanDraftKey: 'unfinished work',
      });
      final migrator = LegacyDataMigrator(
        database,
        hiveSource: LegacyHiveSource.forPath(legacyDirectory.path),
        securePreferences: SecureLegacyPreferencesSource(legacyStorage),
        relayFileOverride: File('${supportDirectory.path}/missing.txt'),
      );

      await expectLater(
        migrator.migrate(),
        throwsA(
          isA<LegacyMigrationException>().having(
            (error) => error.source,
            'source',
            contains('preferences'),
          ),
        ),
      );
      expect(database.db.select('SELECT * FROM preferences'), isEmpty);
      expect(database.db.select('SELECT * FROM legacy_imports'), isEmpty);
      expect(legacyStorage.values[orphanDraftKey], 'unfinished work');
    });

    test('an unreadable relay backup is surfaced without deleting it',
        () async {
      final relayFile = File('${supportDirectory.path}/relay_url.txt')
        ..writeAsStringSync('https://keep.example', flush: true);
      final migrator = LegacyDataMigrator(
        database,
        hiveSource: LegacyHiveSource.forPath(legacyDirectory.path),
        securePreferences: _FakeLegacyPreferences(<String, String>{}),
        relayFileOverride: relayFile,
        relayFileReader: () => Future<String?>.error(
          const FileSystemException('simulated unreadable backup'),
        ),
      );

      await expectLater(
        migrator.migrate(),
        throwsA(isA<LegacyMigrationException>()),
      );
      expect(relayFile.readAsStringSync(), 'https://keep.example');
      expect(database.db.select('SELECT * FROM legacy_imports'), isEmpty);
    });
  });
}
