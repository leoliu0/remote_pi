import 'dart:convert';
import 'dart:typed_data';

import 'package:cockpit/app/cockpit/data/db/db_connection_store_impl.dart';
import 'package:cockpit/app/cockpit/domain/contracts/remote_db_writer.dart';
import 'package:cockpit/app/cockpit/domain/entities/db_connection.dart';
import 'package:cockpit_remote/cockpit_remote.dart';

/// [RemoteDbWriter] sobre o `cockpit-server` do host (plano 62): definição de
/// conexão por `fs.write`, senha por `db.secretSet`.
///
/// Os dois canais são diferentes de propósito. A definição é um arquivo
/// versionado do workspace e vai pelo mesmo caminho que qualquer outro arquivo
/// do host; a senha nunca encosta no disco do repositório — vai pro cofre do
/// host, que é write-only visto daqui.
class RemoteDbWriterImpl implements RemoteDbWriter {
  RemoteDbWriterImpl(this._fileServiceProvider, this._dbServiceProvider);

  final Future<RemoteFileService> Function() _fileServiceProvider;
  final Future<RemoteDbService> Function() _dbServiceProvider;

  @override
  Future<void> saveConnections(
    String workspaceRoot,
    List<DbConnection> connections,
  ) async {
    final fs = await _fileServiceProvider();
    await fs.write(
      '$workspaceRoot/${DbConnectionStoreImpl.databasesRelativePath}',
      Uint8List.fromList(
        utf8.encode(DbConnectionStoreImpl.encodeDatabasesJson(connections)),
      ),
    );
  }

  @override
  Future<void> setSecret(
    String workspaceRoot,
    String connName,
    String value,
  ) async {
    final db = await _dbServiceProvider();
    await db.setSecret(
      workspaceRoot: workspaceRoot,
      connName: connName,
      value: value,
    );
  }

  @override
  Future<void> deleteSecret(String workspaceRoot, String connName) async {
    final db = await _dbServiceProvider();
    await db.deleteSecret(workspaceRoot: workspaceRoot, connName: connName);
  }
}
