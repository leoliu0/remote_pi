import 'package:app/data/local/records/message_record.dart';
import 'package:app/data/local/records/runtime_record.dart';
import 'package:app/data/local/session_store.dart';
import 'package:app/domain/contracts/repository.dart';

/// Read-only projection of one session's committed SQLite rows.
class SessionReadRepository extends Repository {
  SessionReadRepository(this._store);

  final SessionStore _store;

  Stream<List<MessageRecord>> watchMessages(String epk, String roomId) =>
      _store.watchMessages(epk, roomId);

  Stream<RuntimeRecord> watchRuntime(String epk, String roomId) =>
      _store.watchRuntime(epk, roomId);
}
