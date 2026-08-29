// O segredo do banco mora no HOST (plano 62): o cliente manda a conexão sem
// senha e é o servidor que a resolve do cofre daqui. Estes testes cobrem esse
// ponto de junção — o único lugar em que a senha entra no fluxo.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cockpit_core/cockpit_core.dart';
import 'package:cockpit_protocol/cockpit_protocol.dart';
import 'package:cockpit_server/cockpit_server.dart';
import 'package:test/test.dart';

void main() {
  late Directory dir;
  late String path;
  late DbSecretStore secrets;
  late _SpyDb db;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('cockpit-db-secret');
    path = '${dir.path}/s.sock';
    secrets = DbSecretStore(path: '${dir.path}/db-secrets.json');
    db = _SpyDb();
    LocalEndpoint.debugForceTcp = true;
  });
  tearDown(() {
    LocalEndpoint.debugForceTcp = null;
    dir.deleteSync(recursive: true);
  });

  Future<_TestClient> boot() async {
    final server = RemoteServer(
      _FakeTerminals(),
      _Fake(),
      _Fake(),
      db,
      dbSecrets: secrets,
    );
    await server.bind(path);
    addTearDown(server.close);
    return _connectClient(path);
  }

  /// Conexão como o cliente a manda quando o segredo está guardado no host:
  /// SEM senha, e com as duas metades da chave.
  Map<String, Object?> storedConn() => {
    'engine': 'postgres',
    'url': 'postgres://user@db.internal:5432/app',
    'workspaceRoot': '/srv/proj',
    'connName': 'dev-local',
    'storedSecret': true,
  };

  test('o servidor preenche a senha a partir do cofre do host', () async {
    secrets.write('/srv/proj', 'dev-local', 's3cr3t');
    final client = await boot();

    final reply = await _call(client, 'db.query', {
      'conn': storedConn(),
      'sql': 'select 1',
    });

    expect(reply.ok, isTrue);
    // A senha NÃO veio no fio; quem a colocou no descritor foi o servidor.
    expect(db.seen.single.password, 's3cr3t');
  });

  test(
    'sem segredo no host, responde password_required em vez de tentar conectar',
    () async {
      final client = await boot();

      final reply = await _call(client, 'db.query', {
        'conn': storedConn(),
        'sql': 'select 1',
      });

      expect(reply.ok, isFalse);
      expect(reply.code, DbErrorKind.passwordRequired.name);
      // Conectar sem senha produziria um erro do banco que não diz o que fazer.
      expect(db.seen, isEmpty);
    },
  );

  test('conexão sem segredo guardado passa intacta', () async {
    // `savePassword` desligado: a senha (se houver) vem embutida pelo cliente,
    // e o cofre do host não tem nada a dizer.
    secrets.write('/srv/proj', 'dev-local', 'nao-deve-ser-usada');
    final client = await boot();

    await _call(client, 'db.query', {
      'conn': {...storedConn(), 'storedSecret': false, 'password': 'da-url'},
      'sql': 'select 1',
    });

    expect(db.seen.single.password, 'da-url');
  });

  test('db.secretSet grava e db.secretDelete apaga', () async {
    final client = await boot();

    final set = await _call(client, 'db.secretSet', {
      'root': '/srv/proj',
      'conn': 'dev-local',
      'value': 'nova',
    });
    expect(set.ok, isTrue);
    expect(secrets.read('/srv/proj', 'dev-local'), 'nova');

    final del = await _call(client, 'db.secretDelete', {
      'root': '/srv/proj',
      'conn': 'dev-local',
    });
    expect(del.ok, isTrue);
    expect(secrets.read('/srv/proj', 'dev-local'), isNull);
  });

  test('não existe db.secretGet — o segredo não volta pelo protocolo', () async {
    secrets.write('/srv/proj', 'dev-local', 's3cr3t');
    final client = await boot();

    final reply = await _call(client, 'db.secretGet', {
      'root': '/srv/proj',
      'conn': 'dev-local',
    });

    expect(reply.ok, isFalse, reason: 'ler segredo não pode ser um método');
  });
}

Future<RpcResponse> _call(
  _TestClient client,
  String method,
  Map<String, Object?> params,
) async {
  const rid = 1;
  final reply = client.messages.firstWhere(
    (m) => m is RpcResponse && m.rid == rid,
  );
  client.send(RpcRequest(rid: rid, method: method, params: params));
  return await reply.timeout(const Duration(seconds: 5)) as RpcResponse;
}

/// [DbService] que só registra o descritor recebido — o que interessa aqui é
/// COM QUE senha o servidor chamaria o driver, não o resultado da query.
class _SpyDb implements DbService {
  final seen = <RemoteDbConnDescriptor>[];

  @override
  Future<Map<String, Object?>> query(
    RemoteDbConnDescriptor conn,
    String sql, {
    int limit = 200,
    bool dml = false,
  }) async {
    seen.add(conn);
    return {'columns': <Object?>[], 'rows': <Object?>[]};
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

Future<_TestClient> _connectClient(String path) async {
  final endpoint = await LocalEndpoint.connect(path);
  final socket = endpoint.socket;
  addTearDown(socket.destroy);
  final messages = StreamController<RemoteMessage>.broadcast();
  const RemoteMessageCodec().decodeStream(socket).listen(messages.add);
  final ack = messages.stream.first;
  socket.add(
    utf8.encode(
      const RemoteMessageCodec().encode(
        Hello(
          version: protocolVersion,
          client: 'test',
          token: endpoint.token,
          local: false,
        ),
      ),
    ),
  );
  await ack.timeout(const Duration(seconds: 5));
  return _TestClient(socket, messages.stream);
}

class _TestClient {
  _TestClient(this._socket, this.messages);
  final Socket _socket;
  final Stream<RemoteMessage> messages;

  void send(RemoteMessage m) =>
      _socket.add(utf8.encode(const RemoteMessageCodec().encode(m)));
}

class _FakeTerminals implements TerminalService {
  @override
  Future<void> dispose() async {}
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

class _Fake implements FileService, GitService {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}
