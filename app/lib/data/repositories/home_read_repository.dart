import 'package:app/data/local/records/session_index_record.dart';
import 'package:app/data/local/session_store.dart';
import 'package:app/domain/contracts/repository.dart';

/// Read-only projection of the durable cross-session Home index.
class HomeReadRepository extends Repository {
  HomeReadRepository(this._store);

  final SessionStore _store;

  Stream<List<SessionIndexRecord>> watchSessions() => _store.watchSessions();

  Map<String, SessionIndexRecord> snapshot() => <String, SessionIndexRecord>{
        for (final record in _store.sessions()) record.key: record,
      };
}
