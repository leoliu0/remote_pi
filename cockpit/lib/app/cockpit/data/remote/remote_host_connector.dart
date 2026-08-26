import 'dart:async';
import 'dart:io';

import 'package:cockpit/app/cockpit/data/remote/dartssh_host_connection.dart';
import 'package:cockpit/app/cockpit/data/remote/ssh_channel_duplex.dart';
import 'package:cockpit/app/cockpit/data/remote/ssh_known_hosts.dart';
import 'package:cockpit/app/cockpit/data/remote/ssh_tunnel.dart';
import 'package:cockpit/app/cockpit/domain/contracts/ssh_tunnel.dart'
    show HostKeyPrompt, HostKeyVerdict;
import 'package:cockpit/app/cockpit/domain/entities/remote_host.dart';
import 'package:cockpit/app/core/utils/platform_kind.dart';
import 'package:cockpit_core/cockpit_core.dart';
import 'package:cockpit_remote/cockpit_remote.dart';

/// Estado observável da conexão com um host (badge/telas da UI, plano 58).
enum RemoteHostPhase {
  idle,
  openingTunnel,
  installingServer,
  connecting,
  connected,
  reconnecting,
  failed,
}

/// Falha tipada da abertura (a frase nasce na UI via context.t; `detail` é
/// texto cru de terceiros: stderr do ssh, mensagem de socket).
enum RemoteHostErrorKind {
  sshUnreachable,
  serverInstallFailed,
  versionMismatch,
  protocol,

  /// Host nunca visto e o humano não confiou na chave (recusou, ou não havia
  /// ninguém pra perguntar). Antes disto o `ssh` só dizia `Host key
  /// verification failed` e não havia caminho nenhum pela GUI.
  hostKeyUnknown,

  /// O host apresenta chave diferente da que está no `known_hosts`. Não existe
  /// aceite inline: ou é troca legítima de servidor (o usuário edita o
  /// known_hosts) ou é ataque.
  hostKeyChanged,
}

class RemoteHostException implements Exception {
  const RemoteHostException(this.kind, [this.detail]);
  final RemoteHostErrorKind kind;
  final String? detail;

  @override
  String toString() => 'RemoteHostException(${kind.name}: $detail)';
}

/// Conecta a um [RemoteHost] via túnel SSH e entrega o [TerminalService]
/// remoto daquele host (plano 58, Wave 2).
///
/// Fluxo de abertura (as fases alimentam o loading progressivo da UI):
/// 1. túnel SSH pro socket do cockpit-server remoto;
/// 2. conexão + handshake; se o servidor não existe lá, **bootstrap pelo
///    próprio SSH** (Install server): sobe binário + dylib do bundle local e
///    inicia o servidor remoto;
/// 3. serviço pronto. Queda do túnel → [phase] = reconnecting e retry com
///    backoff; sessões sobrevivem no servidor remoto (semântica tmux).
class RemoteHostConnector {
  RemoteHostConnector(
    this.host, {
    required this.localServerBinaryResolver,
    this.passwordResolver,
    this.hostKeyPrompt,
    this.knownHosts = const SshKnownHosts(),
  });

  final RemoteHost host;

  /// Resolve o binário local do cockpit-server (o mesmo do sidecar) usado como
  /// fonte do bootstrap, para a arquitetura pedida (`arm64` | `x64`). Quem
  /// manda é o `uname -sm` DO HOST, não a arquitetura desta máquina: um bundle
  /// macOS traz as duas fatias, e mandar a errada instalava um binário que o
  /// host não executa — falha que só aparecia como "não conectou".
  final String? Function({String? arch}) localServerBinaryResolver;

  /// Resolve a senha SSH do host (auth por senha), lida do Keychain sob
  /// demanda. `null` = auth por chave (default). Plano 60, Wave C.
  final Future<String?> Function()? passwordResolver;

  /// Pergunta ao humano se confia na host key de um destino novo (TOFU),
  /// mostrando o fingerprint. `null` = ninguém pra perguntar (testes, CLI) →
  /// host novo falha com [RemoteHostErrorKind.hostKeyUnknown] em vez de ser
  /// aceito em silêncio.
  final HostKeyPrompt? hostKeyPrompt;

  /// Acesso ao `known_hosts` do usuário (injetável nos testes).
  final SshKnownHosts knownHosts;

  SshTunnel? _tunnel;
  DartSshHostConnection? _dartConn;

  /// Status de turno (spinner/chime) vindo do host pelo protocolo (Wave G).
  /// Reassina a cada (re)conexão; broadcast pra o controller repassar à VM.
  final _turnStatus = StreamController<RemoteTurnStatus>.broadcast();
  StreamSubscription<RemoteTurnStatus>? _turnSub;
  Stream<RemoteTurnStatus> get turnStatus => _turnStatus.stream;

  /// Comandos da CLI `cockpit` rodando no host, encaminhados pelo servidor.
  /// Mesmo caminho do [turnStatus]: reassina a cada (re)conexão.
  final _cliCommands = StreamController<RemoteCliCommand>.broadcast();
  StreamSubscription<RemoteCliCommand>? _cliSub;
  Stream<RemoteCliCommand> get cliCommands => _cliCommands.stream;

  void _bindTurnStatus() {
    _turnSub?.cancel();
    _turnSub = _service?.turnStatus.listen(_turnStatus.add);
    _cliSub?.cancel();
    _cliSub = _service?.cliCommands.listen(_cliCommands.add);
  }

  /// Senha resolvida na abertura atual (auth por senha); só em memória.
  String? _password;
  RemoteConnection? _connection;
  RemoteTerminalService? _service;
  Future<RemoteTerminalService>? _inflight;

  final StreamController<RemoteHostPhase> _phases =
      StreamController.broadcast();
  RemoteHostPhase phase = RemoteHostPhase.idle;

  Stream<RemoteHostPhase> get phases => _phases.stream;

  void _setPhase(RemoteHostPhase value) {
    phase = value;
    _phases.add(value);
  }

  /// Serviço de terminais do host, abrindo (ou reabrindo) a conexão se
  /// preciso. Lança [RemoteHostException] tipada em falha de abertura.
  Future<RemoteTerminalService> ensure() {
    final connection = _connection;
    if (connection != null && connection.isOpen) {
      return Future.value(_service!);
    }
    return _inflight ??= _open()
        .then((service) {
          // TODA reabertura bem-sucedida anuncia o serviço novo — não só a que
          // vem do retry/botão. Os gateways de terminal dependem deste evento
          // pra trocar o serviço e re-anexar; quando ele só saía pelo caminho
          // do retry, uma reconexão disparada por qualquer outra ação deixava as
          // abas presas ao serviço morto (teclado mudo).
          _retryStep = 0;
          if (!_disposed) _reconnected.add(service);
          return service;
        })
        .catchError((Object e) {
          // Falha de ABERTURA (host offline, SSH recusado, server ausente)
          // também entra no ciclo de retry. Sem isto, só a queda de um túnel já
          // estabelecido reagendava — e o caso mais comum, tentar abrir um host
          // que está fora do ar, ficava parado em `failed` para sempre.
          _scheduleRetry();
          throw e;
        })
        .whenComplete(() => _inflight = null);
  }

  /// Serviço de arquivos do host (mesma conexão dos terminais). Conecta se
  /// preciso; usado pelo picker de pasta remota.
  Future<RemoteFileService> fileService() async {
    await ensure();
    return RemoteFileService(_connection!);
  }

  /// Serviço git do host (mesma conexão). Conecta se preciso.
  Future<RemoteGitService> gitService() async {
    await ensure();
    return RemoteGitService(_connection!);
  }

  /// Serviço de DB do host (mesma conexão). Conecta se preciso.
  Future<RemoteDbService> dbService() async {
    await ensure();
    return RemoteDbService(_connection!);
  }

  Future<RemoteTerminalService> _open() async {
    _setPhase(
      phase == RemoteHostPhase.connected
          ? RemoteHostPhase.reconnecting
          : RemoteHostPhase.openingTunnel,
    );
    // Senha (auth por senha) lida do Keychain uma vez por abertura; null =
    // auth por chave. Guardada só em memória, pro bootstrap reusar.
    _password = await passwordResolver?.call();
    // Mobile (plano 59): transporte dartssh2 (Dart puro), sem binário `ssh` nem
    // bootstrap (decisão D — não instala server). Desktop segue no system-ssh.
    if (isMobilePlatform) return _openMobile();
    // Host key ANTES do túnel: com `BatchMode=yes` o ssh não pode perguntar
    // nada, então um destino novo morria em "Host key verification failed" sem
    // caminho pela GUI. Aqui o humano vê o fingerprint e decide.
    await _ensureHostKeyTrusted();
    final SshTunnel tunnel;
    try {
      tunnel = await SshTunnel.open(
        target: host.sshTarget,
        port: host.port,
        password: _password,
        identityFile: host.effectiveIdentityFile,
      );
    } on SshTunnelException catch (e) {
      _setPhase(RemoteHostPhase.failed);
      // "Host key verification failed" não é host inalcançável: a máquina
      // respondeu, o que falhou foi a confiança. Distinguir importa porque a
      // ação do usuário é outra (conferir o fingerprint, não ligar a máquina).
      if (e.detail.contains('Host key verification failed')) {
        throw RemoteHostException(await _classifyHostKeyFailure(), e.detail);
      }
      throw RemoteHostException(RemoteHostErrorKind.sshUnreachable, e.detail);
    }
    _tunnel = tunnel;
    unawaited(tunnel.closed.then((_) => _onTunnelClosed()));

    _setPhase(RemoteHostPhase.connecting);
    var connection = await _tryProtocol(tunnel);
    if (connection == null) {
      // Servidor ausente/parado no host: bootstrap pelo próprio SSH.
      _setPhase(RemoteHostPhase.installingServer);
      await _installAndStartServer();
      connection = await _tryProtocol(tunnel, attempts: 20);
      if (connection == null) {
        _setPhase(RemoteHostPhase.failed);
        throw const RemoteHostException(
          RemoteHostErrorKind.serverInstallFailed,
        );
      }
    }
    _connection = connection;
    _service = RemoteTerminalService(connection);
    _bindTurnStatus();
    _setPhase(RemoteHostPhase.connected);
    return _service!;
  }

  /// Abertura no mobile: conecta via dartssh2, resolve `$HOME` do host e
  /// encaminha pro socket UNIX remoto. Sem bootstrap — se o server não está lá,
  /// falha com erro claro (o mobile não instala server, decisão D).
  Future<void> _ensureHostKeyTrusted() async {
    // Auth por senha já roda com `accept-new` no ssh (o canal de senha é o
    // próprio aceite); não duplicamos a pergunta.
    if (_password != null) return;
    final status = await knownHosts.lookup(host.host, host.port);
    if (status != SshHostKeyStatus.unknown) return;

    final keys = await knownHosts.scan(host.host, host.port);
    // Ninguém respondeu ao scan: não é problema de confiança, é host fora do
    // ar — deixa o ssh falhar e reportar o motivo real.
    if (keys.isEmpty) return;
    final prompt = hostKeyPrompt;
    final fingerprint = await knownHosts.fingerprintOf(keys);
    if (prompt == null || fingerprint == null) {
      _setPhase(RemoteHostPhase.failed);
      throw const RemoteHostException(RemoteHostErrorKind.hostKeyUnknown);
    }
    final verdict = await prompt(
      SshKnownHosts.targetOf(host.host, host.port),
      fingerprint,
    );
    if (verdict != HostKeyVerdict.trust) {
      _setPhase(RemoteHostPhase.failed);
      throw const RemoteHostException(RemoteHostErrorKind.hostKeyUnknown);
    }
    await knownHosts.trust(keys);
  }

  /// `Host key verification failed` COM entrada no `known_hosts` significa
  /// chave trocada — o caso que nunca se aceita inline. Sem entrada, é host
  /// novo que o passo de confiança não cobriu (scan sem resposta).
  Future<RemoteHostErrorKind> _classifyHostKeyFailure() async {
    final status = await knownHosts.lookup(host.host, host.port);
    return status == SshHostKeyStatus.known
        ? RemoteHostErrorKind.hostKeyChanged
        : RemoteHostErrorKind.hostKeyUnknown;
  }

  Future<RemoteTerminalService> _openMobile() async {
    // sshTarget é `user@host` (sem porta); a porta vive em host.port.
    if (host.user.isEmpty || host.host.isEmpty) {
      _setPhase(RemoteHostPhase.failed);
      throw const RemoteHostException(
        RemoteHostErrorKind.sshUnreachable,
        'ssh_target_no_user',
      );
    }
    final endpoint = SshEndpoint(host.user, host.host, host.port);
    final conn = DartSshHostConnection(endpoint, password: _password);
    try {
      await conn.connect();
    } on DartSshException catch (e) {
      _setPhase(RemoteHostPhase.failed);
      throw RemoteHostException(
        RemoteHostErrorKind.sshUnreachable,
        e.detail ?? e.code,
      );
    }
    _dartConn = conn;
    unawaited(conn.done.then((_) => _onTunnelClosed()));

    _setPhase(RemoteHostPhase.connecting);
    try {
      final home = await conn.run(r'printf %s "$HOME"');
      final remoteSocket = '$home/.cockpit/cockpit-server.sock';
      final channel = await conn.forwardUnix(remoteSocket);
      final connection = await RemoteConnection.connectOn(
        SshChannelDuplex(channel),
        clientName: 'cockpit-ipad',
      );
      _connection = connection;
      _service = RemoteTerminalService(connection);
      _bindTurnStatus();
      _setPhase(RemoteHostPhase.connected);
      return _service!;
    } on TerminalException catch (e) {
      _setPhase(RemoteHostPhase.failed);
      if (e.detail == 'version_mismatch') {
        throw const RemoteHostException(RemoteHostErrorKind.versionMismatch);
      }
      // Server ausente no host: mobile não instala (decisão D).
      throw RemoteHostException(
        RemoteHostErrorKind.serverInstallFailed,
        e.detail,
      );
    } catch (e) {
      _setPhase(RemoteHostPhase.failed);
      throw RemoteHostException(RemoteHostErrorKind.protocol, '$e');
    }
  }

  Future<RemoteConnection?> _tryProtocol(
    SshTunnel tunnel, {
    int attempts = 1,
  }) async {
    for (var i = 0; i < attempts; i++) {
      if (i > 0) {
        await Future<void>.delayed(Duration(milliseconds: 100 + i * 50));
      }
      try {
        // PONTA LOCAL de um `ssh -L`, não um endpoint anunciado pelo servidor:
        // não há arquivo de rendezvous nem token a resolver aqui, e o servidor
        // do outro lado é remoto (nada de `local: true`). Socket UNIX no POSIX;
        // no Windows, a porta de loopback do forward — ver [SshTunnel.localPort].
        final port = tunnel.localPort;
        return await RemoteConnection.connectOn(
          port != null
              ? SocketRemoteDuplex(
                  await Socket.connect(InternetAddress.loopbackIPv4, port),
                )
              : await SocketRemoteDuplex.connectUnix(tunnel.localSocketPath),
          clientName: 'cockpit-gui-ssh',
        );
      } on TerminalException catch (e) {
        // Handshake respondeu com erro = servidor existe mas incompatível.
        if (e.detail == 'version_mismatch') {
          _setPhase(RemoteHostPhase.failed);
          throw RemoteHostException(RemoteHostErrorKind.versionMismatch);
        }
        // protocol/transport → servidor provavelmente ausente; tenta de novo.
      } catch (_) {
        // socket remoto sem listener; segue pro retry/bootstrap.
      }
    }
    return null;
  }

  /// "Install server": sobe binário + dylib pelo canal SSH (stdin → arquivo,
  /// sem depender de scp/rsync no host) e inicia o servidor remoto no socket
  /// padrão.
  ///
  /// `--exit-on-idle 120` + `--idle-keeps-sessions`: o servidor encerra sozinho
  /// ~2min depois que ninguém mais o usa (sem órfão no host), MAS nunca enquanto
  /// houver sessão viva. Sem a segunda flag, dois minutos de desconexão matavam
  /// o que estivesse rodando lá — um agente aberto, um build, um vim — que é o
  /// oposto da promessa de retomar de onde parou. Persistência 24/7 gerida por
  /// launchd/systemd fica pra Wave 3.
  ///
  /// Servidor antigo no host ignora a flag desconhecida (o parser dele busca
  /// por índice), então a instalação segue funcionando; só não ganha o
  /// comportamento novo até ser reinstalado.
  static const _remoteIdleSeconds = 120;

  /// Caminho do servidor no host (sempre o mesmo layout, qualquer plataforma).
  static const _remoteServerBin = r'$HOME/.cockpit/server/bin/cockpit-server';
  Future<void> _installAndStartServer() async {
    // Plataforma do HOST decide tudo: qual fatia enviar e o nome da lib do
    // PTY. `uname -sm` → "Darwin arm64", "Linux x86_64", ...
    final (unameCode, uname, unameErr) = await SshTunnel.capture(
      host.sshTarget,
      'uname -sm',
      port: host.port,
      password: _password,
      identityFile: host.effectiveIdentityFile,
    );
    if (unameCode != 0) {
      throw RemoteHostException(
        RemoteHostErrorKind.serverInstallFailed,
        unameErr.isEmpty ? 'uname failed' : unameErr,
      );
    }
    // Servidor JÁ instalado no host: só falta subir. Isto é o que permite um
    // cliente Windows reusar o servidor de um Mac (o binário está lá desde a
    // instalação feita por outro cliente) — empurrar um exe de Windows pra um
    // Mac nunca funcionaria, mas iniciar o que já existe funciona igual.
    final (probeCode, probeOut, _) = await SshTunnel.capture(
      host.sshTarget,
      'test -x $_remoteServerBin && echo yes || echo no',
      port: host.port,
      password: _password,
      identityFile: host.effectiveIdentityFile,
    );
    final alreadyInstalled = probeCode == 0 && probeOut.endsWith('yes');

    final parts = uname.split(RegExp(r'\s+'));
    final remoteOs = parts.isEmpty ? '' : parts.first.toLowerCase();
    final remoteMachine = parts.length > 1 ? parts[1].toLowerCase() : '';
    final remoteArch =
        remoteMachine.contains('arm') || remoteMachine == 'aarch64'
        ? 'arm64'
        : 'x64';
    // Cross-OS não tem como funcionar: o bundle local só traz binário desta
    // plataforma. Antes o Mach-O do macOS era empurrado pra qualquer host e o
    // servidor morria no `nohup` sem deixar rastro.
    final localOs = Platform.isMacOS
        ? 'darwin'
        : Platform.isLinux
        ? 'linux'
        : 'windows';
    // Instalar exige binário DESTA plataforma pro host; iniciar, não.
    if (!alreadyInstalled && remoteOs != localOs) {
      throw RemoteHostException(
        RemoteHostErrorKind.serverInstallFailed,
        'host runs $remoteOs; this build only ships a $localOs cockpit-server',
      );
    }

    final binary = alreadyInstalled
        ? null
        : localServerBinaryResolver(arch: remoteArch);
    if (!alreadyInstalled && binary == null) {
      throw RemoteHostException(
        RemoteHostErrorKind.serverInstallFailed,
        'local cockpit-server binary not found for $remoteOs/$remoteArch',
      );
    }
    // Bundle: <root>/bin/cockpit-server + <root>/lib/*.dylib (anaki + pty). O
    // exe resolve as dylibs em @executable_path/../lib, então preservamos o
    // layout no host (~/.cockpit/server/{bin,lib}).
    final bundleRoot = binary == null ? null : File(binary).parent.parent.path;
    final ptyLib = remoteOs == 'darwin'
        ? 'libcockpit_pty.dylib'
        : 'libcockpit_pty.so';

    Future<void> push(String local, String remote) async {
      final bytes = await File(local).readAsBytes();
      final (code, stderrText) = await SshTunnel.run(
        host.sshTarget,
        'mkdir -p ~/.cockpit/server/bin ~/.cockpit/server/lib && '
        'cat > $remote && chmod +x $remote',
        stdinBytes: bytes,
        port: host.port,
        password: _password,
        identityFile: host.effectiveIdentityFile,
      );
      if (code != 0) {
        throw RemoteHostException(
          RemoteHostErrorKind.serverInstallFailed,
          stderrText,
        );
      }
    }

    // Instalação (só quando o host ainda não tem o servidor). Com ele já lá,
    // pula direto pro start — é o que deixa um cliente de OUTRO sistema
    // (Windows falando com um Mac) reusar o que outro cliente instalou.
    if (bundleRoot != null && binary != null) {
      final libDir = Directory('$bundleRoot/lib');
      // Nome SEM sufixo de arquitetura no host: lá o bundle é de uma
      // arquitetura só, e é assim que o servidor se acha (_besideServer).
      await push(binary, '~/.cockpit/server/bin/cockpit-server');
      if (libDir.existsSync()) {
        for (final f in libDir.listSync().whereType<File>()) {
          if (!f.path.endsWith('.dylib') && !f.path.endsWith('.so')) continue;
          await push(
            f.path,
            '~/.cockpit/server/lib/${f.uri.pathSegments.last}',
          );
        }
      }
      // A lib do PTY nem sempre mora em lib/: no bundle do Linux ela é copiada
      // AO LADO do exe (CMakeLists, 2º candidato do openPtyDylib). Sem esta
      // busca extra, um cliente Linux instalava um servidor sem PTY algum — e
      // o servidor resolve a lib no ARRANQUE, então ele nem subia no host.
      if (!File('$bundleRoot/lib/$ptyLib').existsSync()) {
        final besideExe = File('$bundleRoot/bin/$ptyLib');
        if (besideExe.existsSync()) {
          await push(besideExe.path, '~/.cockpit/server/lib/$ptyLib');
        }
      }
      // CLI `cockpit` ao lado do server (plano 60, Wave G): o server a acha
      // via _besideServer e instala o hook do agente no ~/.claude do host. Só
      // se estiver no bundle local (build_server.sh a embarca).
      final cliLocal = File('$bundleRoot/bin/cockpit');
      if (cliLocal.existsSync()) {
        await push(cliLocal.path, '~/.cockpit/server/bin/cockpit');
      }
    }

    const logPath = r'$HOME/.cockpit/server-boot.log';
    final (code, stderrText) = await SshTunnel.run(
      host.sshTarget,
      // nohup + redirects: o servidor sobrevive ao fim desta sessão ssh. O pty
      // vem do ../lib do bundle; o anaki resolve por rpath. A saída vai pra um
      // LOG, não pro /dev/null: um servidor que morre no arranque (binário da
      // arquitetura errada, dylib faltando) precisa deixar rastro — sem isso o
      // `echo started` saía 0 e a falha chegava na UI como silêncio.
      'COCKPIT_PTY_DYLIB=\$HOME/.cockpit/server/lib/$ptyLib '
      'nohup $_remoteServerBin '
      '--socket \$HOME/.cockpit/cockpit-server.sock '
      '--exit-on-idle $_remoteIdleSeconds '
      '--idle-keeps-sessions '
      '>$logPath 2>&1 & echo started',
      port: host.port,
      password: _password,
      identityFile: host.effectiveIdentityFile,
    );
    if (code != 0) {
      throw RemoteHostException(
        RemoteHostErrorKind.serverInstallFailed,
        stderrText,
      );
    }
    await _assertServerAlive(logPath);
  }

  /// Confirma que o servidor recém-iniciado está de pé no host, e falha com o
  /// log dele quando não está. O `nohup ... &` sempre sai 0 — sem esta
  /// checagem, um binário inválido virava "conexão que não completa".
  Future<void> _assertServerAlive(String logPath) async {
    for (var attempt = 0; attempt < 10; attempt++) {
      await Future<void>.delayed(Duration(milliseconds: 150 + attempt * 100));
      final (code, out, _) = await SshTunnel.capture(
        host.sshTarget,
        'test -S $_remoteSocketPath && echo up || echo down',
        port: host.port,
        password: _password,
        identityFile: host.effectiveIdentityFile,
      );
      if (code == 0 && out.endsWith('up')) return;
    }
    final (_, log, _) = await SshTunnel.capture(
      host.sshTarget,
      'tail -c 2000 $logPath 2>/dev/null || true',
      port: host.port,
      password: _password,
      identityFile: host.effectiveIdentityFile,
    );
    throw RemoteHostException(
      RemoteHostErrorKind.serverInstallFailed,
      log.isEmpty ? 'server did not start on the host' : log,
    );
  }

  static const _remoteSocketPath = r'$HOME/.cockpit/cockpit-server.sock';

  // --- Reconexão automática -------------------------------------------------
  //
  // Backoff crescente que NUNCA desiste (decisão do usuário): 1s, 2s, 4s, 8s,
  // 15s e daí 30s fixo. O teto no intervalo (e não no número de tentativas) é
  // o que mantém "insiste pra sempre" sem martelar a rede — num iPad, um socket
  // a cada 30s é desprezível perto de tentar a cada segundo.
  static const List<Duration> _backoff = <Duration>[
    Duration(seconds: 1),
    Duration(seconds: 2),
    Duration(seconds: 4),
    Duration(seconds: 8),
    Duration(seconds: 15),
    Duration(seconds: 30),
  ];

  Timer? _retryTimer;
  int _retryStep = 0;
  bool _disposed = false;

  /// Emite quando a conexão é REFEITA — os gateways de terminal usam pra
  /// re-anexar suas sessões (o serviço é outro objeto após reabrir).
  final _reconnected = StreamController<RemoteTerminalService>.broadcast();
  Stream<RemoteTerminalService> get reconnected => _reconnected.stream;

  void _onTunnelClosed() {
    if (_disposed || _aborting) return;
    if (phase == RemoteHostPhase.connected) {
      _setPhase(RemoteHostPhase.reconnecting);
    }
    _scheduleRetry();
  }

  void _scheduleRetry() {
    if (_disposed || _retryTimer != null) return;
    final delay = _backoff[_retryStep.clamp(0, _backoff.length - 1)];
    if (_retryStep < _backoff.length - 1) _retryStep++;
    _retryTimer = Timer(delay, () {
      _retryTimer = null;
      _attemptReconnect();
    });
  }

  Future<void> _attemptReconnect() async {
    if (_disposed) return;
    final connection = _connection;
    if (connection != null && connection.isOpen) return;
    try {
      // `ensure()` dedup pelo `_inflight`, então tentativa concorrente com uma
      // ação do usuário não abre dois túneis. Quem anuncia o serviço novo (e
      // zera o backoff) é o próprio `ensure`, para valer em qualquer caminho.
      await ensure();
    } on Object {
      // Falhou de novo: reagenda. A fase já foi pra failed dentro de _open().
      if (!_disposed) {
        _setPhase(RemoteHostPhase.reconnecting);
        _scheduleRetry();
      }
    }
  }

  /// Reconecta AGORA (botão da UI): descarta o backoff acumulado, **aborta a
  /// tentativa em curso** e abre uma nova. Sem efeito se a conexão está viva.
  ///
  /// O abort é o que faz o botão ter efeito de verdade. Sem ele, `ensure()`
  /// devolvia o `_inflight` — e com o host fora do ar há quase sempre uma
  /// abertura em voo (o retry automático dispara a cada 1-30s e cada tentativa
  /// leva até 15s pra estourar), então o clique só pegava carona numa tentativa
  /// já pendurada: da UI, parecia que o botão não fazia nada.
  Future<void> reconnectNow() async {
    if (_disposed) return;
    _retryTimer?.cancel();
    _retryTimer = null;
    _retryStep = 0;
    // Feedback imediato: o abort abaixo pode levar um instante (fechar socket,
    // esperar a tentativa pendurada morrer) e o clique não pode parecer inerte.
    _setPhase(RemoteHostPhase.openingTunnel);
    await _abortCurrentAttempt();
    if (_disposed) return;
    await _attemptReconnect();
  }

  /// Derruba conexão/transporte/tentativa atuais para que a próxima abertura
  /// comece do zero. Fechar o transporte faz a tentativa pendurada estourar na
  /// hora, em vez de esperar o timeout.
  Future<void> _abortCurrentAttempt() async {
    final inflight = _inflight;
    final connection = _connection;
    final tunnel = _tunnel;
    final dartConn = _dartConn;
    _connection = null;
    _service = null;
    _tunnel = null;
    _dartConn = null;
    // O fechamento é NOSSO, deliberado: o `closed`/`done` do transporte vai
    // disparar [_onTunnelClosed], que agendaria um retry concorrente com o que
    // este método está prestes a fazer.
    _aborting = true;
    try {
      await connection?.close();
    } on Object {
      // já morto.
    }
    try {
      await tunnel?.close();
    } on Object {
      // já morto.
    }
    try {
      await dartConn?.close();
    } on Object {
      // já morto.
    }
    if (inflight != null) {
      try {
        await inflight;
      } on Object {
        // a tentativa abortada falha — é o esperado.
      }
    }
    _aborting = false;
  }

  /// Fechamento provocado por nós ([_abortCurrentAttempt]) não deve agendar
  /// retry: quem abortou já vai reabrir.
  bool _aborting = false;

  Future<void> dispose() async {
    _disposed = true;
    _retryTimer?.cancel();
    _retryTimer = null;
    await _reconnected.close();
    await _turnSub?.cancel();
    await _turnStatus.close();
    await _cliSub?.cancel();
    await _cliCommands.close();
    await _connection?.close();
    await _tunnel?.close();
    await _dartConn?.close();
    _connection = null;
    _service = null;
    await _phases.close();
  }
}
