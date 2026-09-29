import 'package:app/data/local/records/message_record.dart';
import 'package:app/data/local/records/runtime_record.dart';
import 'package:app/data/local/records/session_index_record.dart';
import 'package:app/domain/session_state.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('record round-trips', () {
    test('user message keeps stable ID, image, pending, and steering fields', () {
      final original = MessageRecord(
        id: 'u1',
        seq: 3,
        role: MsgRole.user,
        text: 'hello',
        image: const MessageImage(data: 'QUJD', mime: 'image/jpeg'),
        ts: DateTime.fromMillisecondsSinceEpoch(1700),
        pending: true,
        steering: true,
      );

      final restored = MessageRecord.fromJson(original.toJson());
      expect(restored.toJson(), original.toJson());
      final projected = restored.toChatMessage() as UserMsg;
      expect(projected.status, UserMsgStatus.pending);
      expect(projected.steering, isTrue);
      expect(projected.image?.data, 'QUJD');
    });

    test('tool message keeps arbitrary args/result and error metadata', () {
      final original = MessageRecord(
        id: 't1',
        seq: 4,
        role: MsgRole.tool,
        ts: DateTime.fromMillisecondsSinceEpoch(1800),
        tool: const ToolEventData(
          toolCallId: 't1',
          tool: 'bash',
          args: <String, Object?>{
            'command': 'printf ok',
            'nested': <Object?>[1, true, null],
          },
          status: ToolEventStatus.completed,
          result: <String, Object?>{'stdout': 'ok'},
          error: 'non-fatal detail',
        ),
      );

      final restored = MessageRecord.fromJson(original.toJson());
      expect(restored.toJson(), original.toJson());
      expect(restored.tool?.args, original.tool?.args);
      expect(restored.tool?.result, original.tool?.result);
    });

    test('compaction keeps reclaimed token count', () {
      final original = MessageRecord(
        id: 'c1',
        seq: 5,
        role: MsgRole.compaction,
        text: 'summary',
        ts: DateTime.fromMillisecondsSinceEpoch(1900),
        tokensBefore: 9001,
      );
      expect(
        MessageRecord.fromJson(original.toJson()).toJson(),
        original.toJson(),
      );
    });

    test('session index keeps every Home projection field', () {
      final original = SessionIndexRecord(
        epk: 'peer',
        roomId: 'room',
        displayName: 'provider:model',
        status: SessionActivity.working,
        lastMessageAt: DateTime.fromMillisecondsSinceEpoch(2000),
        lastMessagePreview: 'preview',
        sessionStartedAt: DateTime.fromMillisecondsSinceEpoch(1000),
      );
      expect(SessionIndexRecord.fromJson(original.toJson()), original);
    });

    test('runtime record keeps connection and presence', () {
      const original = RuntimeRecord(
        connection: RuntimeConnection.retrying,
        presence: RuntimePresence.stale,
      );
      expect(RuntimeRecord.fromJson(original.toJson()), original);
    });
  });
}
