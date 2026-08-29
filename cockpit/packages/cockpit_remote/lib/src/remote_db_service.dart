import 'package:cockpit_core/cockpit_core.dart';

import 'remote_connection.dart';

/// [DbService] via protocolo (plano 58, Wave 4): manda o descritor de conexão
/// + SQL ao servidor, que executa no host e devolve o resultado já-JSON.
class RemoteDbService implements DbService {
  RemoteDbService(this._connection);

  final RemoteConnection _connection;

  @override
  Future<Map<String, Object?>> query(
    RemoteDbConnDescriptor conn,
    String sql, {
    int limit = 200,
    bool dml = false,
  }) async {
    try {
      final data = await _connection.call('db.query', {
        'conn': conn.toJson(),
        'sql': sql,
        'limit': limit,
        'dml': dml,
      });
      return (data as Map).cast<String, Object?>();
    } on RemoteRpcException catch (e) {
      throw _mapError(e);
    }
  }

  @override
  Future<Object?> redis(RemoteDbConnDescriptor conn, List<String> parts) async {
    try {
      return await _connection.call('db.redis', {
        'conn': conn.toJson(),
        'parts': parts,
      });
    } on RemoteRpcException catch (e) {
      throw _mapError(e);
    }
  }

  @override
  Future<List<Object?>> redisMany(
    RemoteDbConnDescriptor conn,
    List<List<String>> commands,
  ) async {
    try {
      final data = await _connection.call('db.redisMany', {
        'conn': conn.toJson(),
        'commands': commands,
      });
      return (data as List).cast<Object?>();
    } on RemoteRpcException catch (e) {
      throw _mapError(e);
    }
  }

  @override
  Future<Object?> mongo(
    RemoteDbConnDescriptor conn,
    Map<String, Object?> command, {
    String? database,
  }) async {
    try {
      return await _connection.call('db.mongo', {
        'conn': conn.toJson(),
        'command': command,
        'database': ?database,
      });
    } on RemoteRpcException catch (e) {
      throw _mapError(e);
    }
  }

  /// Grava a senha da conexão **no cofre do host** (plano 62). Write-only por
  /// contrato: não existe leitura de volta, nem aqui nem no protocolo.
  Future<void> setSecret({
    required String workspaceRoot,
    required String connName,
    required String value,
  }) async {
    try {
      await _connection.call('db.secretSet', {
        'root': workspaceRoot,
        'conn': connName,
        'value': value,
      });
    } on RemoteRpcException catch (e) {
      throw _mapError(e);
    }
  }

  /// Apaga a senha da conexão no cofre do host (conexão removida, renomeada,
  /// ou `savePassword` desligado).
  Future<void> deleteSecret({
    required String workspaceRoot,
    required String connName,
  }) async {
    try {
      await _connection.call('db.secretDelete', {
        'root': workspaceRoot,
        'conn': connName,
      });
    } on RemoteRpcException catch (e) {
      throw _mapError(e);
    }
  }

  DbServiceException _mapError(RemoteRpcException e) => DbServiceException(
    DbErrorKind.values.asNameMap()[e.code] ?? DbErrorKind.queryFailed,
    e.detail,
  );
}
