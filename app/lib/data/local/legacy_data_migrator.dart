import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:app/data/local/app_database.dart';
import 'package:app/data/local/records/message_record.dart';
import 'package:app/data/local/records/session_index_record.dart';
import 'package:app/data/transport/epk_encoding.dart';
import 'package:app/domain/session_state.dart' show ToolEventStatus;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:hive/hive.dart';
import 'package:path_provider/path_provider.dart';

/// Reads only the app-preference keys known to the legacy schema.
abstract interface class LegacyPreferencesSource {
  Future<Map<String, String>> read(Set<String> knownKeys);
}

/// Import-only adapter for the old Flutter secure-storage preference rows.
class SecureLegacyPreferencesSource implements LegacyPreferencesSource {
  SecureLegacyPreferencesSource([
    FlutterSecureStorage? storage,
  ]) : _storage = storage ?? const FlutterSecureStorage();

  static const Duration _readAllTimeout = Duration(seconds: 4);
  static const Duration _readTimeout = Duration(seconds: 2);

  final FlutterSecureStorage _storage;

  @override
  Future<Map<String, String>> read(Set<String> knownKeys) async {
    final enumerated = await _storage.readAll().timeout(_readAllTimeout);
    final result = <String, String>{
      for (final entry in enumerated.entries)
        if (knownKeys.contains(entry.key) ||
            entry.key.startsWith('prefs.draft.'))
          entry.key: entry.value,
    };

    final missing = knownKeys
        .where((key) => !result.containsKey(key))
        .toList(growable: false);
    final direct = await Future.wait(<Future<MapEntry<String, String?>>>[
      for (final key in missing)
        _storage
            .read(key: key)
            .timeout(_readTimeout)
            .then((value) => MapEntry<String, String?>(key, value)),
    ]);
    if (direct.any((entry) => entry.value != null)) {
      throw StateError(
        'Secure storage enumeration returned an incomplete result.',
      );
    }
    return result;
  }
}

/// Import-only reader for the former `rp_v2` Hive namespace.
class LegacyHiveSource {
  const LegacyHiveSource._({this.path});

  factory LegacyHiveSource.production() => const LegacyHiveSource._();

  factory LegacyHiveSource.forPath(String path) => LegacyHiveSource._(path: path);

  final String? path;

  Future<_LegacyHiveSnapshot> _read() async {
    final legacyPath = path ?? await _productionHivePath();
    Hive.init(legacyPath);

    final sessions = <SessionIndexRecord>[];
    final messages = <_LegacySessionMessages>[];
    final preferences = <String, String>{};
    final opened = <Box<dynamic>>[];
    try {
      if (await Hive.boxExists('sessions_index')) {
        final index = await Hive.openBox<dynamic>('sessions_index');
        opened.add(index);
        for (final key in index.keys) {
          final raw = index.get(key);
          if (raw is! Map) {
            throw FormatException(
              'sessions_index[$key] is not an object.',
            );
          }
          final record = _decodeSession(raw.cast<String, dynamic>());
          if ('$key' != record.key) {
            throw FormatException(
              'sessions_index[$key] identifies ${record.key}.',
            );
          }
          sessions.add(record);
        }
      }
      sessions.sort((a, b) => a.key.compareTo(b.key));
      await _rejectOrphanMessageBoxes(legacyPath, sessions);

      final openedMessageBoxes = <String>{};
      for (final session in sessions) {
        final boxName = _messageBoxName(session.epk, session.roomId);
        if (!openedMessageBoxes.add(boxName) ||
            !await Hive.boxExists(boxName)) {
          continue;
        }
        final box = await Hive.openBox<dynamic>(boxName);
        opened.add(box);
        final rows = <MessageRecord>[];
        for (final key in box.keys) {
          if (key is! num) {
            throw FormatException('$boxName has non-numeric key $key.');
          }
          final raw = box.get(key);
          if (raw is! Map) {
            throw FormatException('$boxName[$key] is not an object.');
          }
          final record = _decodeMessage(raw.cast<String, dynamic>());
          if (record.seq != key.toInt()) {
            throw FormatException(
              '$boxName[$key] contains sequence ${record.seq}.',
            );
          }
          rows.add(record);
        }
        rows.sort((a, b) => a.seq.compareTo(b.seq));
        messages.add(
          _LegacySessionMessages(session.epk, session.roomId, rows),
        );
      }

      if (await Hive.boxExists('app_prefs')) {
        final box = await Hive.openBox<dynamic>('app_prefs');
        opened.add(box);
        for (final key in box.keys) {
          final value = box.get(key);
          if (key is! String || value is! String) {
            throw FormatException('app_prefs[$key] is not a string row.');
          }
          preferences[key] = value;
        }
      }

      return _LegacyHiveSnapshot(sessions, messages, preferences);
    } finally {
      for (final box in opened.reversed) {
        if (box.isOpen) await box.close();
      }
    }
  }

  static SessionIndexRecord _decodeSession(Map<String, dynamic> json) {
    final status = json['status'];
    if (status is! String ||
        !SessionActivity.values.any((value) => value.name == status)) {
      throw FormatException('Unknown session activity: $status.');
    }
    return SessionIndexRecord.fromJson(json);
  }

  static MessageRecord _decodeMessage(Map<String, dynamic> json) {
    final role = json['role'];
    if (role is! String || !MsgRole.values.any((value) => value.name == role)) {
      throw FormatException('Unknown message role: $role.');
    }
    final tool = json['tool'];
    if (tool is Map) {
      final status = tool['status'];
      if (status is! String ||
          !ToolEventStatus.values.any((value) => value.name == status)) {
        throw FormatException('Unknown tool status: $status.');
      }
    }
    return MessageRecord.fromJson(json);
  }

  static String _messageBoxName(String epk, String roomId) =>
      'msgs_${toAppEpk(epk)}__$roomId';
  static Future<String> _productionHivePath() async {
    final directory = await getApplicationDocumentsDirectory();
    return '${directory.path}${Platform.pathSeparator}rp_v2';
  }

  static Future<void> _rejectOrphanMessageBoxes(
    String legacyPath,
    List<SessionIndexRecord> sessions,
  ) async {
    final directory = Directory(legacyPath);
    if (!await directory.exists()) return;
    final expected = <String>{
      for (final session in sessions)
        '${_messageBoxName(session.epk, session.roomId).toLowerCase()}.hive',
    };
    await for (final entity in directory.list(followLinks: false)) {
      if (entity is! File) continue;
      final separator = entity.path.lastIndexOf(Platform.pathSeparator);
      final rawName = entity.path.substring(separator + 1);
      final name = rawName.toLowerCase();
      if (!name.startsWith('msgs_') ||
          !name.endsWith('.hive') ||
          expected.contains(name)) {
        continue;
      }

      // The released New Session flow cleared the message box and removed its
      // index row, but Hive intentionally retained the empty file. That state
      // is safe to ignore; a non-empty orphan could contain the user's only
      // copy of history and must keep migration from committing.
      final boxName = rawName.substring(0, rawName.length - '.hive'.length);
      final orphan = await Hive.openBox<dynamic>(boxName);
      try {
        if (orphan.isNotEmpty) {
          throw FormatException(
            'Orphan legacy message box $name has no sessions_index row.',
          );
        }
      } finally {
        if (orphan.isOpen) await orphan.close();
      }
    }
  }

}

class LegacyImportReport {
  const LegacyImportReport({
    required this.alreadyCompleted,
    required this.sessionsImported,
    required this.messagesImported,
    required this.preferencesImported,
  });

  final bool alreadyCompleted;
  final int sessionsImported;
  final int messagesImported;
  final int preferencesImported;
}

class LegacyMigrationException implements Exception {
  const LegacyMigrationException({
    required this.source,
    required this.message,
    this.cause,
    this.stackTrace,
  });

  final String source;
  final String message;
  final Object? cause;
  final StackTrace? stackTrace;

  @override
  String toString() => 'LegacyMigrationException($source): $message';
}

class _MigrationCoordinator {
  Future<LegacyImportReport>? active;
  int? activeGeneration;
  int generation = 0;
}

/// One-time, transactional import of local data from pre-SQLite releases.
///
/// Legacy sources are never changed or deleted. The completion marker is
/// committed in the same transaction as imported and validated rows, so a
/// crash or write error retries from a clean destination on the next boot.
class LegacyDataMigrator {
  LegacyDataMigrator(
    this._database, {
    LegacyHiveSource? hiveSource,
    LegacyPreferencesSource? securePreferences,
    this.relayFileOverride,
    Future<String?> Function()? relayFileReader,
  })  : _hiveSource = hiveSource ?? LegacyHiveSource.production(),
        _securePreferences =
            securePreferences ?? SecureLegacyPreferencesSource(),
        _relayFileReader = relayFileReader;

  static const String markerSource = 'local.rp_v2_and_preferences';
  static const int sourceVersion = 1;
  static const Duration _migrationTimeout = Duration(seconds: 10);
  static final Expando<_MigrationCoordinator> _coordinators =
      Expando<_MigrationCoordinator>('legacy migration coordinator');
  static Future<void> _migrationTail = Future<void>.value();

  static const Set<String> _knownPreferenceKeys = <String>{
    'prefs.hide_tool_calls',
    'prefs.selected_peer_epk',
    'prefs.relay_url',
    'prefs.onboarding_completed',
    'prefs.theme_mode',
    'prefs.font_scale',
    'prefs.font_family',
    'prefs.tool_call_display',
    'prefs.draft.:main',
  };

  final AppDatabase _database;
  final LegacyHiveSource _hiveSource;
  final LegacyPreferencesSource _securePreferences;
  final File? relayFileOverride;
  final Future<String?> Function()? _relayFileReader;

  Future<LegacyImportReport> migrate() async {
    final coordinator =
        _coordinators[_database] ??= _MigrationCoordinator();
    final active = coordinator.active;
    if (active != null) return active;
    if (_isComplete()) return _completedReport();

    final generation = ++coordinator.generation;
    final operation = _migrationTail.then<LegacyImportReport>(
      (_) => _migrateAttempt(coordinator, generation),
    );
    _migrationTail = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    coordinator.activeGeneration = generation;
    final bounded = _boundedAttempt(coordinator, generation, operation);
    coordinator.active = bounded;
    return bounded;
  }

  Future<LegacyImportReport> _boundedAttempt(
    _MigrationCoordinator coordinator,
    int generation,
    Future<LegacyImportReport> operation,
  ) async {
    try {
      return await operation.timeout(_migrationTimeout);
    } on TimeoutException catch (error, stackTrace) {
      if (coordinator.generation == generation) coordinator.generation++;
      throw LegacyMigrationException(
        source: 'legacy migration timeout',
        message: 'Reading saved data exceeded the 10 second safety deadline.',
        cause: error,
        stackTrace: stackTrace,
      );
    } finally {
      if (coordinator.activeGeneration == generation) {
        coordinator.active = null;
        coordinator.activeGeneration = null;
      }
    }
  }

  Future<LegacyImportReport> _migrateAttempt(
    _MigrationCoordinator coordinator,
    int generation,
  ) async {
    _ensureCurrent(coordinator, generation);
    if (_isComplete()) return _completedReport();

    late final _LegacyHiveSnapshot hive;
    try {
      hive = await _hiveSource._read();
    } catch (error, stackTrace) {
      throw LegacyMigrationException(
        source: 'Hive rp_v2',
        message: 'Could not read every known legacy Hive row.',
        cause: error,
        stackTrace: stackTrace,
      );
    }
    _ensureCurrent(coordinator, generation);

    final secureKeys = <String>{
      ..._knownPreferenceKeys,
      for (final session in hive.sessions)
        'prefs.draft.${session.epk}:${session.roomId}',
    };
    late Map<String, String> secure;
    try {
      secure = await _securePreferences.read(secureKeys);
      _ensureCurrent(coordinator, generation);
      final selected = secure['prefs.selected_peer_epk'];
      if (selected != null && selected.isNotEmpty) {
        final selectedDraft = selected.contains(':')
            ? 'prefs.draft.$selected'
            : 'prefs.draft.$selected:main';
        if (!secure.containsKey(selectedDraft)) {
          secureKeys.add(selectedDraft);
          secure = await _securePreferences.read(secureKeys);
          _ensureCurrent(coordinator, generation);
        }
      }
    } catch (error, stackTrace) {
      throw LegacyMigrationException(
        source: 'secure preferences',
        message: 'Could not verify every known secure preference.',
        cause: error,
        stackTrace: stackTrace,
      );
    }

    late final String? fileRelay;
    try {
      fileRelay = await (_relayFileReader?.call() ?? _readRelayFile());
    } catch (error, stackTrace) {
      throw LegacyMigrationException(
        source: 'relay preference file',
        message: 'Could not read the legacy relay URL backup.',
        cause: error,
        stackTrace: stackTrace,
      );
    }
    _ensureCurrent(coordinator, generation);

    final preferences = _mergePreferences(
      hive.preferences,
      secure,
      fileRelay,
    );
    final fingerprint = _fingerprint(hive, preferences);
    final messageCount = hive.messages.fold<int>(
      0,
      (total, session) => total + session.rows.length,
    );
    final rowCount = hive.sessions.length + messageCount + preferences.length;

    try {
      var imported = false;
      _database.transaction<void>(() {
        _ensureCurrent(coordinator, generation);
        if (_isComplete()) return;
        _insertAndValidateSessions(hive.sessions);
        _insertAndValidateMessages(hive.messages);
        _insertAndValidatePreferences(preferences);
        _database.db.execute(
          '''
          INSERT INTO legacy_imports(
            source, source_version, completed_at_ms, row_count, fingerprint
          ) VALUES (?, ?, ?, ?, ?)
          ''',
          <Object?>[
            markerSource,
            sourceVersion,
            DateTime.now().millisecondsSinceEpoch,
            rowCount,
            fingerprint,
          ],
        );
        imported = true;
      });
      if (!imported) return _completedReport();
    } catch (error, stackTrace) {
      if (error is LegacyMigrationException) rethrow;
      throw LegacyMigrationException(
        source: 'SQLite legacy import',
        message: 'The import was rolled back and can be retried safely.',
        cause: error,
        stackTrace: stackTrace,
      );
    }

    return LegacyImportReport(
      alreadyCompleted: false,
      sessionsImported: hive.sessions.length,
      messagesImported: messageCount,
      preferencesImported: preferences.length,
    );
  }

  static void _ensureCurrent(
    _MigrationCoordinator coordinator,
    int generation,
  ) {
    if (coordinator.generation != generation) {
      throw StateError('Legacy migration attempt was superseded.');
    }
  }

  bool _isComplete() => _database.db.select(
        'SELECT 1 FROM legacy_imports WHERE source = ? LIMIT 1',
        <Object?>[markerSource],
      ).isNotEmpty;

  LegacyImportReport _completedReport() {
    final sessions = _database.db
        .select('SELECT COUNT(*) AS count FROM session_index')
        .single['count'] as int;
    final messages = _database.db
        .select('SELECT COUNT(*) AS count FROM messages')
        .single['count'] as int;
    final preferences = _database.db
        .select('SELECT COUNT(*) AS count FROM preferences')
        .single['count'] as int;
    return LegacyImportReport(
      alreadyCompleted: true,
      sessionsImported: sessions,
      messagesImported: messages,
      preferencesImported: preferences,
    );
  }

  Future<String?> _readRelayFile() async {
    final file = relayFileOverride ?? await _productionRelayFile();
    if (!await file.exists()) return null;
    final value = await file.readAsString();
    return value.isEmpty ? null : value;
  }

  static Future<File> _productionRelayFile() async {
    final directory = await getApplicationSupportDirectory().timeout(
      const Duration(seconds: 4),
    );
    return File(
      '${directory.path}${Platform.pathSeparator}relay_url.txt',
    );
  }

  static Map<String, String> _mergePreferences(
    Map<String, String> hive,
    Map<String, String> secure,
    String? fileRelay,
  ) {
    final merged = <String, String>{
      for (final entry in secure.entries)
        if (entry.key.startsWith('prefs.')) entry.key: entry.value,
    };

    String? hiveRelay;
    for (final entry in hive.entries) {
      if (entry.key == 'relay_url' || entry.key == 'prefs.relay_url') {
        if (entry.value.isNotEmpty) hiveRelay = entry.value;
      } else {
        // Historically only relay_url lived in app_prefs. Preserve any other
        // string row without overriding the secure-store value used at runtime.
        merged.putIfAbsent(entry.key, () => entry.value);
      }
    }

    final secureRelay = secure['prefs.relay_url'];
    final relay = fileRelay ?? hiveRelay ?? secureRelay;
    if (relay != null && relay.isNotEmpty) {
      merged['prefs.relay_url'] = relay;
    } else {
      merged.remove('prefs.relay_url');
    }
    return merged;
  }

  void _insertAndValidateSessions(List<SessionIndexRecord> sessions) {
    for (final record in sessions) {
      _database.db.execute(
        '''
        INSERT OR IGNORE INTO session_index(
          peer_epk, room_id, display_name, activity,
          last_message_at_ms, last_message_preview, session_started_at_ms
        ) VALUES (?, ?, ?, ?, ?, ?, ?)
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
      final row = _database.db.select(
        '''
        SELECT * FROM session_index
        WHERE peer_epk = ? AND room_id = ?
        ''',
        <Object?>[record.epk, record.roomId],
      ).single;
      final restored = SessionIndexRecord.fromJson(<String, dynamic>{
        'epk': row['peer_epk'],
        'room_id': row['room_id'],
        'display_name': row['display_name'],
        'status': row['activity'],
        'last_message_at': row['last_message_at_ms'],
        'last_message_preview': row['last_message_preview'],
        'session_started_at': row['session_started_at_ms'],
      });
      if (restored != record) {
        throw LegacyMigrationException(
          source: 'SQLite legacy import',
          message: 'Session ${record.key} conflicts with existing data.',
        );
      }
    }
  }

  void _insertAndValidateMessages(List<_LegacySessionMessages> sessions) {
    for (final session in sessions) {
      for (final record in session.rows) {
        final encoded = jsonEncode(record.toJson());
        _database.db.execute(
          '''
          INSERT OR IGNORE INTO messages(
            peer_epk, room_id, seq, protocol_id, role, payload_json
          ) VALUES (?, ?, ?, ?, ?, ?)
          ''',
          <Object?>[
            session.epk,
            session.roomId,
            record.seq,
            record.id,
            record.role.name,
            encoded,
          ],
        );
        final rows = _database.db.select(
          '''
          SELECT protocol_id, role, payload_json FROM messages
          WHERE peer_epk = ? AND room_id = ? AND seq = ?
          ''',
          <Object?>[session.epk, session.roomId, record.seq],
        );
        if (rows.length != 1 ||
            rows.single['protocol_id'] != record.id ||
            rows.single['role'] != record.role.name ||
            rows.single['payload_json'] != encoded) {
          throw LegacyMigrationException(
            source: 'SQLite legacy import',
            message: 'Message ${record.seq} in '
                '${session.epk}:${session.roomId} conflicts with existing data.',
          );
        }
      }
    }
  }

  void _insertAndValidatePreferences(Map<String, String> preferences) {
    for (final entry in preferences.entries) {
      _database.db.execute(
        'INSERT OR IGNORE INTO preferences(key, value) VALUES (?, ?)',
        <Object?>[entry.key, entry.value],
      );
      final value = _database.db.select(
        'SELECT value FROM preferences WHERE key = ?',
        <Object?>[entry.key],
      ).single['value'];
      if (value != entry.value) {
        throw LegacyMigrationException(
          source: 'SQLite legacy import',
          message: 'Preference ${entry.key} conflicts with existing data.',
        );
      }
    }
  }

  static String _fingerprint(
    _LegacyHiveSnapshot hive,
    Map<String, String> preferences,
  ) {
    final canonical = jsonEncode(<String, Object?>{
      'sessions': <Object?>[
        for (final session in hive.sessions) session.toJson(),
      ],
      'messages': <Object?>[
        for (final session in hive.messages)
          <String, Object?>{
            'epk': session.epk,
            'room_id': session.roomId,
            'rows': <Object?>[
              for (final row in session.rows) row.toJson(),
            ],
          },
      ],
      'preferences': <String, String>{
        for (final key in (preferences.keys.toList()..sort()))
          key: preferences[key]!,
      },
    });
    var hash = 0xcbf29ce484222325;
    for (final byte in utf8.encode(canonical)) {
      hash ^= byte;
      hash = (hash * 0x100000001b3) & 0xffffffffffffffff;
    }
    return hash.toRadixString(16).padLeft(16, '0');
  }
}

class _LegacyHiveSnapshot {
  const _LegacyHiveSnapshot(this.sessions, this.messages, this.preferences);

  final List<SessionIndexRecord> sessions;
  final List<_LegacySessionMessages> messages;
  final Map<String, String> preferences;
}

class _LegacySessionMessages {
  const _LegacySessionMessages(this.epk, this.roomId, this.rows);

  final String epk;
  final String roomId;
  final List<MessageRecord> rows;
}
