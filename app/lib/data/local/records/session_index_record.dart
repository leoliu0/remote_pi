/// Plan/31 — per-session activity (#5: idle | working).
enum SessionActivity { idle, working }

/// Durable top-level index of sessions, so Home can query working/idle state
/// and the last-message projection without scanning message history.
class SessionIndexRecord {
  final String epk;
  final String roomId;
  final String displayName;
  final SessionActivity status;
  final DateTime? lastMessageAt;
  final String? lastMessagePreview;
  final DateTime? sessionStartedAt;

  const SessionIndexRecord({
    required this.epk,
    required this.roomId,
    this.displayName = '',
    this.status = SessionActivity.idle,
    this.lastMessageAt,
    this.lastMessagePreview,
    this.sessionStartedAt,
  });

  String get key => '$epk:$roomId';

  SessionIndexRecord copyWith({
    String? displayName,
    SessionActivity? status,
    DateTime? lastMessageAt,
    String? lastMessagePreview,
    DateTime? sessionStartedAt,
  }) => SessionIndexRecord(
    epk: epk,
    roomId: roomId,
    displayName: displayName ?? this.displayName,
    status: status ?? this.status,
    lastMessageAt: lastMessageAt ?? this.lastMessageAt,
    lastMessagePreview: lastMessagePreview ?? this.lastMessagePreview,
    sessionStartedAt: sessionStartedAt ?? this.sessionStartedAt,
  );

  Map<String, dynamic> toJson() => {
    'epk': epk,
    'room_id': roomId,
    'display_name': displayName,
    'status': status.name,
    'last_message_at': lastMessageAt?.millisecondsSinceEpoch,
    'last_message_preview': lastMessagePreview,
    'session_started_at': sessionStartedAt?.millisecondsSinceEpoch,
  };

  factory SessionIndexRecord.fromJson(Map<String, dynamic> j) {
    DateTime? ms(dynamic v) => v == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch((v as num).toInt());
    return SessionIndexRecord(
      epk: j['epk'] as String,
      roomId: j['room_id'] as String,
      displayName: (j['display_name'] as String?) ?? '',
      status: SessionActivity.values.firstWhere(
        (s) => s.name == j['status'],
        orElse: () => SessionActivity.idle,
      ),
      lastMessageAt: ms(j['last_message_at']),
      lastMessagePreview: j['last_message_preview'] as String?,
      sessionStartedAt: ms(j['session_started_at']),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is SessionIndexRecord &&
      other.epk == epk &&
      other.roomId == roomId &&
      other.displayName == displayName &&
      other.status == status &&
      other.lastMessageAt == lastMessageAt &&
      other.lastMessagePreview == lastMessagePreview &&
      other.sessionStartedAt == sessionStartedAt;

  @override
  int get hashCode => Object.hash(
    epk,
    roomId,
    displayName,
    status,
    lastMessageAt,
    lastMessagePreview,
    sessionStartedAt,
  );
}
