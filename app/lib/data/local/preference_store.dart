import 'package:app/data/local/app_database.dart';

/// Typed key/value boundary for non-secret app preferences.
class PreferenceStore {
  const PreferenceStore(this._database);

  final AppDatabase _database;

  String? get(String key) {
    final rows = _database.db.select(
      'SELECT value FROM preferences WHERE key = ?',
      <Object?>[key],
    );
    return rows.isEmpty ? null : rows.single['value'] as String;
  }

  Map<String, String> all() => <String, String>{
        for (final row in _database.db.select(
          'SELECT key, value FROM preferences ORDER BY key',
        ))
          row['key'] as String: row['value'] as String,
      };

  bool put(String key, String value) {
    if (get(key) == value) return false;
    _database.transaction<void>(() {
      _database.db.execute(
        '''
        INSERT INTO preferences(key, value) VALUES (?, ?)
        ON CONFLICT(key) DO UPDATE SET value = excluded.value
        ''',
        <Object?>[key, value],
      );
    });
    return true;
  }

  bool putAll(Map<String, String> values) {
    final changed = <MapEntry<String, String>>[
      for (final entry in values.entries)
        if (get(entry.key) != entry.value) entry,
    ];
    if (changed.isEmpty) return false;
    _database.transaction<void>(() {
      final statement = _database.db.prepare('''
        INSERT INTO preferences(key, value) VALUES (?, ?)
        ON CONFLICT(key) DO UPDATE SET value = excluded.value
      ''');
      try {
        for (final entry in changed) {
          statement.execute(<Object?>[entry.key, entry.value]);
        }
      } finally {
        statement.dispose();
      }
    });
    return true;
  }

  bool delete(String key) {
    if (get(key) == null) return false;
    _database.transaction<void>(() {
      _database.db.execute(
        'DELETE FROM preferences WHERE key = ?',
        <Object?>[key],
      );
    });
    return true;
  }

}
