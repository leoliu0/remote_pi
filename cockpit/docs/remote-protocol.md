# Cockpit Remote protocol (v1, Wave 0 draft)

Client ↔ `cockpit-server` protocol. This wave covers the **handshake** and the
**Terminals** domain; files, git, and databases come in later waves with the
same envelope.

Messages are Dart classes in `packages/cockpit_protocol` — the same class
serializes and deserializes on both sides of the wire. This document describes
the on-wire format for debugging and for future clients.

## Transport

- **Framing**: JSONL — one JSON object per line (`\n`), UTF-8. Dispatch is
  per line, never on `onDone` (lesson from the internal CLI socket: waiting
  on `onDone` deadlocks request/response).
- **Channel**: local socket. On POSIX it is a UDS at the announced path; **on
  Windows it is TCP on loopback**, because `dart:io` does not implement UNIX
  sockets there — bind blew up and the app fell back to in-process PTY. The
  announced path now holds a JSON **rendezvous file**
  (`{"v":1,"port":…,"token":…}`), which plays the inode's role: that is how a
  client discovers an already-running server and adopts it. Remote = the SAME
  socket tunneled over SSH (Wave 2); the protocol does not change. The server
  never listens on a routable network port.
- **PTY bytes**: base64 in field `d`. (Future-wave optimization candidate:
  binary frame; only if a benchmark asks for it.)
- **Auth**: none on a channel where reaching it is already a credential
  (filesystem permission on the UDS; SSH login on the tunnel). That does not
  hold for loopback TCP: any process on the machine can connect, so `hello`
  carries a **token** (`tok`) that only whoever reads the rendezvous file
  knows, and the server refuses the handshake without it.

## Envelope

```json
{"t": "<type>", ...fields}
```

Common fields: `id` = PTY session id; `d` = base64 payload; `off` = absolute
byte offset of the session stream since spawn.

## Handshake

The client opens the connection and sends `hello`; the server replies
`hello.ack` or `err{code: version_mismatch}` and closes. Every message before
`hello` is rejected with `err{code: handshake_required}`.

| Direction | Message | Fields |
|---|---|---|
| C→S | `hello` | `v` (int, protocol version), `client` (name/version), `tok` (optional), `loc` (optional) |
| S→C | `hello.ack` | `v`, `server` (binary version) |

`tok` is the rendezvous-file token, required where transport is loopback TCP
(Windows) and absent over UDS/SSH tunnel; a wrong token replies
`err{code: invalid_token}` and closes.

`loc: true` means "I am on the same machine as you" (sidecar), and is not
derivable from transport — the near end of `ssh -L` is also a local socket,
and there the server is remote. It changes one thing: PTYs of a local client
keep the `COCKPIT_STATUS_SOCK` the client injected, because that socket is
the path for the internal CLI (`cockpit send`, `list-tabs`, `db`) as well as
turn status. For a remote client the server swaps that address for its own
receiver (the client's socket is unreachable from the host), also removing
the other transport's keys — the hook reads `COCKPIT_STATUS_SOCK` before
port+token, and a leftover from the client would win over the right address.

`v` is compared by equality at this stage. Incompatible → the client offers
"Update server" (bootstrap over the tunnel, Wave 2).

## Terminals domain

Model: **sessions belong to the server**, not to the connection. Detach (or
a dropped connection) does not kill the session; reattach recovers the
retained scrollback (raw-byte ring buffer, default 4 MiB per session) and
continues live. The emulator (Ghostty) lives on the client; the server does
not interpret the bytes.

| Direction | Message | Fields | Reply |
|---|---|---|---|
| C→S | `pty.open` | `cmd`, `args[]`, `cwd?`, `env{}?`, `rows`, `cols` | `pty.opened{id, pid}` or `err` |
| C→S | `pty.list` | — | `pty.sessions{sessions[]}` (`{id,pid,cmd,rows,cols,len,exit?}`) |
| C→S | `pty.attach` | `id`, `from` (offset; 0 = replay retained) | stream of `pty.output` + `pty.exited` |
| C→S | `pty.detach` | `id` | (nothing; session stays alive) |
| C→S | `pty.input` | `id`, `d` | — |
| C→S | `pty.resize` | `id`, `rows`, `cols` | — |
| C→S | `pty.kill` | `id` | — (kills the process AND discards the session) |
| S→C | `pty.output` | `id`, `off`, `d` | — |
| S→C | `pty.exited` | `id`, `code` | — (scrollback stays attachable until `pty.kill`) |

Offset semantics: `off` is the absolute position of the chunk's first byte in
the session's total stream. On attach with `from` earlier than retained, the
first chunk arrives with `off` greater than requested — the client knows it
lost the start. Replay never duplicates or drops bytes relative to live (the
server filters by offset at the replay→live seam).

## Errors

```json
{"t": "err", "code": "<stable code>", "detail": "<raw text>", "id": "<session>?"}
```

Current codes: `handshake_required`, `version_mismatch`, `bad_message`,
`session_not_found`, `spawn_failed`, `internal`. `code` is contract (the UI
translates by enum); `detail` is third-party text (errno etc.), shown raw.

## Domínio Bancos de dados — segredos (plano 62)

Query, schema e comandos NoSQL executam **no host** (`db.query`, `db.redis`,
`db.redisMany`, `db.mongo`), e o descritor de conexão viaja em `params.conn`.

A senha **não** viaja junto. O cofre de senhas é do host — arquivo `0600` em
`~/.cockpit/db-secrets.json`, chaveado por `(raiz do workspace, nome da
conexão)` — e o cliente o alimenta por dois métodos **write-only**:

| Método | `params` | Efeito |
|---|---|---|
| `db.secretSet` | `root`, `conn`, `value` | grava/substitui a senha da conexão |
| `db.secretDelete` | `root`, `conn` | apaga a senha da conexão |
| `db.secretRename` | `root`, `from`, `to` | move a senha para o nome novo |
| `db.hostKeyTrust` | `endpoint`, `fingerprint` | confia numa host key de bastion |

`db.secretSet`/`db.secretDelete` aceitam `kind`: `password` (default) ou
`sshPassphrase` — a passphrase da chave do túnel é segredo distinto da senha do
banco, e a conexão pode ter um sem o outro.

`db.secretRename` existe porque o cliente não pode ler o segredo para regravá-lo
sob outro nome: sem ele, renomear uma conexão apagava a senha e o usuário só
descobria na query seguinte.

O conteúdo é cifrado com AES-GCM e chave fixa do produto (modelo do DBeaver).
É **ofuscação deliberada**: tira o segredo do texto claro em disco, cobrindo
vazamento acidental (backup, pasta sincronizada, `grep`, print de tela). Não
defende de quem executa como o dono da conta — a chave está no binário, e não
poderia ser diferente num servidor que sobe por SSH sem humano presente. Cofre
em claro (formato anterior) continua sendo lido; a escrita seguinte o regrava
cifrado, então não há passo de migração.

**Um cofre por máquina.** O mesmo arquivo é usado pelo app quando o workspace é
LOCAL: a chave é derivada da raiz do workspace (nunca do `workspaceId`, que é
gerado por máquina), então digitar a senha sentado no host ou a partir de um
cliente remoto grava na MESMA entrada. Era o contrário antes, e a senha
digitada no host não valia para cliente nenhum — o `cockpit-server` é headless
e nunca teve como ler o cofre do SO. O que ficou lá migra sozinho na primeira
leitura.


**Não existe `db.secretGet`, e isso é contrato, não omissão**: o cliente grava
e apaga, nunca relê. Quem lê é o servidor, ao montar a conexão.

Campos do descritor que fecham o desenho:

| Campo | Significado |
|---|---|
| `workspaceRoot` | raiz do workspace no host — primeira metade da chave do segredo |
| `connName` | nome da conexão — segunda metade |
| `storedSecret` | `true` = a senha está no cofre do host; `password` vai ausente e o servidor resolve |
| `password` | só quando `storedSecret` é `false` (conexão que optou por não guardar segredo) |

Com `storedSecret: true` e nada no cofre do host, o servidor responde
`password_required` em vez de tentar conectar sem senha — o erro do banco
("authentication failed") mandaria o usuário investigar a coisa errada. O caso
típico é conexão cadastrada antes deste plano, cuja senha ficou no cofre do
cliente que a criou.

### Túnel SSH da conexão (plano 62, onda 2)

O descritor carrega o bloco `ssh` da conexão e **quem abre o túnel é o host** —
ele é quem alcança o bastion e quem tem a chave privada. Antes o bloco não
viajava, o host recebia `host:porta` cru e discava direto: conexão com bastion
não funcionava a partir de cliente remoto.

- **Chave e passphrase são as do host.** `keyPath` resolve contra o `~` de lá; a
  passphrase sai do mesmo cofre da senha, sob `kind: sshPassphrase`.
- **Mongo vai por SOCKS**, os demais por port-forward — num replica set o driver
  descobre os membros e passa a discar os hostnames reais, furando porta fixa.
- **Host key**: o servidor não pergunta nada. Chave desconhecida vira
  `ssh_tunnel_failed` com detail `<kind>|<mensagem>`, e a mensagem traz o
  fingerprint. O cliente mostra o diálogo que já tem e confia via
  `db.hostKeyTrust` — decisão do humano no cliente, estado no host, o mesmo
  idioma do cofre. Consequência aceita: a primeira conexão a um bastion novo
  falha uma vez, de propósito.

## Open (for later waves)

- Output backpressure/coalescing on the wire (integrate with
  `pty_output_scheduler` in `docs/terminal-output-flow-control.md`).
- Resize with N attached clients (tmux policy to decide).
- Binary frame for `pty.output` if a benchmark points at base64.
- Envelopes for Files, Git, and Databases domains.
