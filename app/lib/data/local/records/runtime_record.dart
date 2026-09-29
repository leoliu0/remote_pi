/// Volatile runtime state. SQLite rows are deleted on every database open, so
/// stale online/presence can never survive process death. These reduced enums
/// omit live channel objects carried by the richer connection status types.
enum RuntimeConnection { connecting, online, offline, retrying }

enum RuntimePresence { alive, stale, unknown }

class RuntimeRecord {
  final RuntimeConnection connection;
  final RuntimePresence presence;

  const RuntimeRecord({
    this.connection = RuntimeConnection.connecting,
    this.presence = RuntimePresence.unknown,
  });

  RuntimeRecord copyWith({
    RuntimeConnection? connection,
    RuntimePresence? presence,
  }) => RuntimeRecord(
    connection: connection ?? this.connection,
    presence: presence ?? this.presence,
  );

  Map<String, dynamic> toJson() => {
    'connection': connection.name,
    'presence': presence.name,
  };

  factory RuntimeRecord.fromJson(Map<String, dynamic> j) => RuntimeRecord(
    connection: RuntimeConnection.values.firstWhere(
      (c) => c.name == j['connection'],
      orElse: () => RuntimeConnection.connecting,
    ),
    presence: RuntimePresence.values.firstWhere(
      (p) => p.name == j['presence'],
      orElse: () => RuntimePresence.unknown,
    ),
  );

  @override
  bool operator ==(Object other) =>
      other is RuntimeRecord &&
      other.connection == connection &&
      other.presence == presence;

  @override
  int get hashCode => Object.hash(connection, presence);
}
