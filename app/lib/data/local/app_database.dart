import 'dart:async';

import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/sqlite3.dart';

/// Process-wide SQLite database for ordinary app metadata and chat history.
///
/// Initialization is explicit: [instance] never substitutes an in-memory
/// database when durable storage failed to open. Call [initialize] once before
/// constructing repositories.
class AppDatabase {
  AppDatabase._(this._db) {
    _configure();
    _createCoreSchema();
    _resetRuntime();
  }

  static const int coreSchemaVersion = 1;
  static const String fileName = 'remote_pi.sqlite';

  static const Duration _initializationTimeout = Duration(seconds: 10);
  static AppDatabase? _instance;
  static Future<void>? _initializing;
  static int _initializationGeneration = 0;

  final Database _db;
  final List<List<void Function()>> _afterCommitFrames =
      <List<void Function()>>[];
  int _transactionDepth = 0;
  int _savepointSequence = 0;
  bool _disposed = false;

  /// Opens the durable app-private database and initializes the common schema.
  /// Concurrent calls share one bounded attempt. A timeout invalidates that
  /// attempt so Retry can start cleanly; a late handle is never installed.
  static Future<void> initialize() {
    if (_instance != null) return Future<void>.value();
    final existing = _initializing;
    if (existing != null) return existing;

    final generation = ++_initializationGeneration;
    late final Future<void> attempt;
    attempt = _initializeAttempt(generation).whenComplete(() {
      if (identical(_initializing, attempt)) _initializing = null;
    });
    _initializing = attempt;
    return attempt;
  }

  static Future<void> _initializeAttempt(int generation) async {
    final opening = _openProduction(generation);
    try {
      final opened = await opening.timeout(_initializationTimeout);
      if (generation != _initializationGeneration) {
        opened.dispose();
        throw StateError('AppDatabase initialization was superseded.');
      }
      if (_instance != null) {
        opened.dispose();
        return;
      }
      _instance = opened;
    } on TimeoutException {
      if (generation == _initializationGeneration) {
        _initializationGeneration++;
      }
      // Future.timeout cannot cancel a platform lookup. Dispose a database if
      // that source still manages to finish after this attempt was rejected.
      unawaited(
        opening.then<void>(
          (opened) => opened.dispose(),
          onError: (Object _, StackTrace _) {},
        ),
      );
      rethrow;
    } catch (_) {
      if (generation == _initializationGeneration) {
        _initializationGeneration++;
      }
      rethrow;
    }
  }

  static Future<AppDatabase> _openProduction(int generation) async {
    final directory = await getApplicationSupportDirectory();
    await directory.create(recursive: true);
    if (generation != _initializationGeneration) {
      throw StateError('AppDatabase initialization was superseded.');
    }
    final path = '${directory.path}${Platform.pathSeparator}$fileName';
    Database? raw;
    try {
      raw = sqlite3.open(path);
      return AppDatabase._(raw);
    } catch (_) {
      raw?.dispose();
      rethrow;
    }
  }

  /// Initialized production singleton.
  ///
  /// Throws rather than hiding an initialization/open failure behind an empty
  /// store, because an empty fallback would look like user data loss.
  static AppDatabase get instance {
    final value = _instance;
    if (value == null) {
      throw StateError(
        'AppDatabase has not been initialized. Call AppDatabase.initialize() '
        'before reading AppDatabase.instance.',
      );
    }
    return value;
  }

  /// Fully initialized isolated in-memory database for unit tests.
  factory AppDatabase.memory() => AppDatabase._(sqlite3.openInMemory());

  /// Fully initialized durable database at a test-owned path.
  ///
  /// This exercises close/reopen and boot-time runtime reset without replacing
  /// the production singleton.
  factory AppDatabase.openForTest(String path) =>
      AppDatabase._(sqlite3.open(path));

  /// Raw handle for repository internals and independently owned schemas.
  Database get db {
    _ensureOpen();
    return _db;
  }

  bool get inTransaction => _transactionDepth != 0;

  /// Runs a synchronous transaction.
  ///
  /// The outer scope uses `BEGIN IMMEDIATE`; nested scopes use SQLite
  /// savepoints, so an inner failure can be caught without poisoning the outer
  /// unit. Asynchronous callbacks are intentionally unsupported.
  T transaction<T>(T Function() body) {
    _ensureOpen();
    final outermost = _transactionDepth == 0;
    final savepoint = 'app_db_sp_${_savepointSequence++}';
    if (outermost) {
      _db.execute('BEGIN IMMEDIATE');
    } else {
      _db.execute('SAVEPOINT $savepoint');
    }

    final callbacks = <void Function()>[];
    _afterCommitFrames.add(callbacks);
    _transactionDepth++;

    late T result;
    try {
      result = body();
      if (result is Future) {
        throw StateError(
          'AppDatabase.transaction callbacks must be synchronous.',
        );
      }
      if (outermost) {
        _db.execute('COMMIT');
      } else {
        _db.execute('RELEASE SAVEPOINT $savepoint');
      }
    } catch (_) {
      _afterCommitFrames.removeLast();
      _transactionDepth--;
      try {
        if (outermost) {
          _db.execute('ROLLBACK');
        } else {
          _db.execute('ROLLBACK TO SAVEPOINT $savepoint');
          _db.execute('RELEASE SAVEPOINT $savepoint');
        }
      } catch (_) {
        // Preserve the original body/commit exception.
      }
      rethrow;
    }

    _afterCommitFrames.removeLast();
    _transactionDepth--;
    if (outermost) {
      for (final callback in callbacks) {
        callback();
      }
    } else {
      _afterCommitFrames.last.addAll(callbacks);
    }
    return result;
  }

  /// Schedules repository notifications after the outer transaction commits.
  /// Outside a transaction the callback runs immediately.
  void afterCommit(void Function() callback) {
    _ensureOpen();
    if (_afterCommitFrames.isEmpty) {
      callback();
    } else {
      _afterCommitFrames.last.add(callback);
    }
  }

  void _configure() {
    _db.execute('PRAGMA foreign_keys = ON');
    _db.execute('PRAGMA busy_timeout = 5000');
    // In-memory SQLite keeps its `memory` journal mode; durable databases use
    // WAL where supported. The returned mode does not affect correctness.
    _db.execute('PRAGMA journal_mode = WAL');
    _db.execute('PRAGMA synchronous = NORMAL');
  }

  void _createCoreSchema() {
    transaction<void>(() {
      _db.execute('''
        CREATE TABLE IF NOT EXISTS schema_metadata (
          key TEXT PRIMARY KEY NOT NULL,
          value TEXT NOT NULL
        )
      ''');

      final versionRows = _db.select(
        "SELECT value FROM schema_metadata WHERE key = 'core.schema_version'",
      );
      if (versionRows.isNotEmpty) {
        final stored = int.tryParse(versionRows.single['value'] as String);
        if (stored == null || stored > coreSchemaVersion) {
          throw StateError(
            'Unsupported core database schema version: '
            '${versionRows.single['value']}',
          );
        }
      }

      _db.execute('''
        CREATE TABLE IF NOT EXISTS legacy_imports (
          source TEXT PRIMARY KEY NOT NULL,
          source_version INTEGER NOT NULL,
          completed_at_ms INTEGER NOT NULL,
          row_count INTEGER NOT NULL,
          fingerprint TEXT NOT NULL
        )
      ''');
      _db.execute('''
        CREATE TABLE IF NOT EXISTS session_index (
          peer_epk TEXT NOT NULL,
          room_id TEXT NOT NULL,
          display_name TEXT NOT NULL DEFAULT '',
          activity TEXT NOT NULL CHECK(activity IN ('idle', 'working')),
          last_message_at_ms INTEGER,
          last_message_preview TEXT,
          session_started_at_ms INTEGER,
          PRIMARY KEY(peer_epk, room_id)
        )
      ''');
      _db.execute('''
        CREATE TABLE IF NOT EXISTS messages (
          peer_epk TEXT NOT NULL,
          room_id TEXT NOT NULL,
          seq INTEGER NOT NULL CHECK(seq >= 0),
          protocol_id TEXT NOT NULL,
          role TEXT NOT NULL CHECK(
            role IN ('user', 'assistant', 'tool', 'compaction')
          ),
          payload_json TEXT NOT NULL,
          PRIMARY KEY(peer_epk, room_id, seq),
          UNIQUE(peer_epk, room_id, role, protocol_id)
        )
      ''');
      _db.execute('''
        CREATE INDEX IF NOT EXISTS messages_session_identity
        ON messages(peer_epk, room_id, role, protocol_id)
      ''');
      _db.execute('''
        CREATE TABLE IF NOT EXISTS runtime_sessions (
          peer_epk TEXT NOT NULL,
          room_id TEXT NOT NULL,
          connection TEXT NOT NULL CHECK(
            connection IN ('connecting', 'online', 'offline', 'retrying')
          ),
          presence TEXT NOT NULL CHECK(
            presence IN ('alive', 'stale', 'unknown')
          ),
          PRIMARY KEY(peer_epk, room_id)
        )
      ''');
      _db.execute('''
        CREATE TABLE IF NOT EXISTS preferences (
          key TEXT PRIMARY KEY NOT NULL,
          value TEXT NOT NULL
        )
      ''');
      _db.execute(
        '''
        INSERT INTO schema_metadata(key, value)
        VALUES ('core.schema_version', ?)
        ON CONFLICT(key) DO UPDATE SET value = excluded.value
        ''',
        <Object?>['$coreSchemaVersion'],
      );
    });
  }

  void _resetRuntime() {
    transaction<void>(() {
      _db.execute('DELETE FROM runtime_sessions');
    });
  }

  void _ensureOpen() {
    if (_disposed) throw StateError('AppDatabase has been disposed.');
  }

  void dispose() {
    if (_disposed) return;
    if (_transactionDepth != 0) {
      throw StateError('Cannot dispose AppDatabase during a transaction.');
    }
    _disposed = true;
    _db.dispose();
    if (identical(_instance, this)) _instance = null;
  }
}
