import '../entities/db_connection.dart';

/// Escrita da configuração de banco de um workspace **remoto** (plano 62).
///
/// A leitura já existia (`loadRemoteConnections`, via `fs.read`); a escrita
/// não, e por isso salvar uma conexão num workspace remoto era impossível: o
/// `DatabaseViewModel` chamava o store LOCAL com a raiz do host, e o
/// `File('<caminho do host>/.cockpit/databases.json').parent.create()`
/// estourava no disco do cliente antes de qualquer coisa ser gravada.
///
/// O segredo é **write-only** por contrato: dá pra gravar e apagar, nunca ler
/// de volta. Quem lê é o servidor do host, na hora de abrir a conexão.
abstract interface class RemoteDbWriter {
  /// Regrava o `databases.json` do workspace **no host**.
  Future<void> saveConnections(
    String workspaceRoot,
    List<DbConnection> connections,
  );

  /// Guarda a senha de [connName] no cofre **do host**.
  Future<void> setSecret(
    String workspaceRoot,
    String connName,
    String value,
  );

  /// Apaga a senha de [connName] no cofre do host (conexão removida, renomeada
  /// ou com `savePassword` desligado).
  Future<void> deleteSecret(String workspaceRoot, String connName);
}
