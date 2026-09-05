# Windows host — prepare the machine

How to make a Windows machine ready to be a Cockpit **host**. On the other
side, the client can be macOS, Linux, Windows, or iPad.

Product prerequisite: **Cockpit desktop must be installed on the host**.
The remote server is installed by copying the `cockpit-server-bundle` the app
already leaves on the machine — no binary travels over SSH. Without Cockpit
installed there, the client fails with "Windows but Cockpit is not installed".

## 1. Enable the SSH server

OpenSSH Server is an optional Windows feature. In PowerShell **as
administrator**:

```powershell
Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0
Set-Service -Name sshd -StartupType Automatic
Start-Service sshd
```

Check:

```powershell
Get-Service sshd            # should be Running
Get-NetTCPConnection -LocalPort 22 -State Listen
```

> You do not need to change `DefaultShell` to PowerShell. Cockpit invokes
> `powershell -NoProfile -EncodedCommand` explicitly, so the default `cmd.exe`
> is enough — and it works on a fresh install.

## 2. Install the public key — the gotcha

This is the most common error, and it **fails silently**.

Windows `sshd_config` ends with:

```
Match Group administrators
       AuthorizedKeysFile __PROGRAMDATA__/ssh/administrators_authorized_keys
```

So if the account is an **administrator** — the normal case on a personal
machine — OpenSSH **ignores** `~/.ssh/authorized_keys` and only reads
`C:\ProgramData\ssh\administrators_authorized_keys`. A key placed in the
"obvious" location is simply never considered, and the other side sees a
generic `Permission denied (publickey)`.

Find which group the account belongs to:

```powershell
net localgroup Administrators   # or "Administradores", depending on locale
```

### Administrator account

```powershell
# in PowerShell AS ADMINISTRATOR
$key = 'ssh-ed25519 AAAA... comment'
Add-Content -Path C:\ProgramData\ssh\administrators_authorized_keys -Value $key
```

### Regular account

```powershell
Add-Content -Path "$env:USERPROFILE\.ssh\authorized_keys" -Value $key
```

## 3. Fix the ACL — the second silence

OpenSSH **refuses** the keys file if it is readable by anyone besides `SYSTEM`
and `Administrators`, and it also does not tell the client: authentication
just fails as if the key did not exist. The default inheritance on
`C:\ProgramData` usually includes `Authenticated Users`, so the fix is almost
always needed:

```powershell
# in PowerShell AS ADMINISTRATOR — SIDs, not names: names are localized
icacls C:\ProgramData\ssh\administrators_authorized_keys `
  /inheritance:r /grant "*S-1-5-18:(F)" /grant "*S-1-5-32-544:(F)"
```

Check — the list must have **only** those two entries:

```powershell
icacls C:\ProgramData\ssh\administrators_authorized_keys
```

> Literal SIDs (`*S-1-5-18` = SYSTEM, `*S-1-5-32-544` = Administrators)
> avoid `icacls` failing to recognize `BUILTIN\Administradores` on a
> Portuguese Windows.

## 4. End-to-end check

From the client machine:

```bash
ssh -o BatchMode=yes user@host "echo OK"
```

`BatchMode=yes` is the same mode Cockpit uses: it forbids any interactive
prompt, so if it falls back to a password prompt the key is **not** being
accepted — go back to steps 2 and 3.

## 5. Diagnosis when it does not work

| Symptom | Likely cause |
|---|---|
| `Permission denied (publickey)` | Key in the wrong file (step 2) or loose ACL (step 3) |
| `Connection refused` | `sshd` stopped, or firewall blocking 22 |
| Asks for a password even with a key | Same as the first case — the key is being ignored |
| Connects, but Cockpit says it did not find Cockpit on the host | The app is not installed on the host (see prerequisite at the top) |

Server log, when nothing else explains it:

```powershell
Get-WinEvent -LogName 'OpenSSH/Operational' -MaxEvents 30 |
  Format-List TimeCreated, Message
```

## Architecture notes (why it is this way)

- **The server listens on loopback, never on the network.** On Windows
  `dart:io` has no UNIX socket, so `cockpit-server` listens on an ephemeral
  loopback TCP port and announces port + token in a rendezvous file
  (`~/.cockpit/cockpit-server.sock`, which there is JSON, not a socket).
  Outside access is always through the SSH tunnel — the port is not exposed.
- **The token exists because loopback does not protect.** A loopback port
  accepts a connection from any process on the machine, while a UNIX socket
  is already protected by `~/.cockpit` permissions. The token travels in the
  handshake and the server refuses without it.
- **The server is started by WMI, not `Start-Process`.** The `sshd` session
  on Windows runs inside a Job Object with kill-on-close: every child process
  dies when the SSH session ends — there is no `nohup` there. `Win32_Process.Create`
  has `WmiPrvSE` create the process outside that job, so it survives. Side
  effect: the server runs in **session 0**.
