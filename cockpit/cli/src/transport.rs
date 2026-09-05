//! Transport layer: single request per connection, single JSON line per direction.
//! Uses local Unix socket on POSIX, TCP loopback with token on Windows.

use std::io::{Read, Write};
use std::time::Duration;

use serde_json::{json, Value};

use crate::util::{die, env_non_empty};

/// Active connection to the app, abstracting Unix vs TCP streams.
enum Conn {
    #[cfg(unix)]
    Unix(std::os::unix::net::UnixStream),
    Tcp(std::net::TcpStream),
}

impl Conn {
    fn set_read_timeout(&self, dur: Duration) -> std::io::Result<()> {
        match self {
            #[cfg(unix)]
            Conn::Unix(s) => s.set_read_timeout(Some(dur)),
            Conn::Tcp(s) => s.set_read_timeout(Some(dur)),
        }
    }
}

impl Read for Conn {
    fn read(&mut self, buf: &mut [u8]) -> std::io::Result<usize> {
        match self {
            #[cfg(unix)]
            Conn::Unix(s) => s.read(buf),
            Conn::Tcp(s) => s.read(buf),
        }
    }
}

impl Write for Conn {
    fn write(&mut self, buf: &[u8]) -> std::io::Result<usize> {
        match self {
            #[cfg(unix)]
            Conn::Unix(s) => s.write(buf),
            Conn::Tcp(s) => s.write(buf),
        }
    }
    fn flush(&mut self) -> std::io::Result<()> {
        match self {
            #[cfg(unix)]
            Conn::Unix(s) => s.flush(),
            Conn::Tcp(s) => s.flush(),
        }
    }
}

/// Connects to the app over platform transport.
const FLAVOR: Option<&str> = option_env!("COCKPIT_FLAVOR");

/// Candidate sockets to probe in priority order.
#[cfg(unix)]
fn candidate_sockets() -> Vec<String> {
    let mut out = Vec::new();
    if let Some(path) = env_non_empty("COCKPIT_STATUS_SOCK") {
        out.push(path);
    }
    if let Some(home) = crate::util::home_dir() {
        let release = format!("{home}/.cockpit/status.sock");
        let debug = format!("{home}/.cockpit/status-debug.sock");
        if FLAVOR == Some("debug") {
            out.push(debug);
            out.push(release);
        } else {
            out.push(release);
            out.push(debug);
        }
    }
    out
}

fn connect() -> Result<Option<Conn>, String> {
    let port = env_non_empty("COCKPIT_STATUS_PORT").and_then(|p| p.parse::<u16>().ok());

    #[cfg(unix)]
    {
        let candidates = candidate_sockets();
        let mut last_err: Option<String> = None;
        for path in &candidates {
            // Orphan socket exists on disk but refuses connection -> check connect result
            match std::os::unix::net::UnixStream::connect(path) {
                Ok(s) => return Ok(Some(Conn::Unix(s))),
                Err(e) => last_err = Some(e.to_string()),
            }
        }
        if port.is_none() {
            return match last_err {
                Some(e) => Err(e),
                None => Ok(None),
            };
        }
    }

    if let Some(port) = port {
        return std::net::TcpStream::connect(("127.0.0.1", port))
            .map(|s| Some(Conn::Tcp(s)))
            .map_err(|e| e.to_string());
    }
    Ok(None)
}

/// Returns `true` when a transport path to the app is configured.
pub fn transport_configured() -> bool {
    if env_non_empty("COCKPIT_STATUS_SOCK").is_some()
        || env_non_empty("COCKPIT_STATUS_PORT")
            .and_then(|p| p.parse::<u16>().ok())
            .is_some()
    {
        return true;
    }
    #[cfg(unix)]
    {
        candidate_sockets()
            .iter()
            .any(|p| std::path::Path::new(p).exists())
    }
    #[cfg(not(unix))]
    false
}

/// Sends a request and returns the decoded JSON response.
pub fn request(mut req: Value, timeout: Duration) -> Value {
    if !transport_configured() {
        die(
            "cockpit: no Cockpit app to talk to (COCKPIT_STATUS_SOCK is unset and \
no socket found in ~/.cockpit). Is the app running?",
            3,
        );
    }
    req["type"] = json!("cmd");
    if let Ok(tok) = std::env::var("COCKPIT_STATUS_TOKEN") {
        req["tok"] = json!(tok);
    }

    let mut conn = match connect() {
        Ok(Some(c)) => c,
        Ok(None) => die(
            "cockpit: not inside a Cockpit terminal (COCKPIT_STATUS_SOCK is unset)",
            3,
        ),
        Err(e) => die(&format!("cockpit: could not connect to app: {e}"), 3),
    };
    let _ = conn.set_read_timeout(timeout);

    let mut payload = req.to_string();
    payload.push('\n');
    if let Err(e) = conn
        .write_all(payload.as_bytes())
        .and_then(|_| conn.flush())
    {
        die(&format!("cockpit: could not connect to app: {e}"), 3);
    }

    // Server responds with a single line and closes. Read until EOF so a held-open connection still completes.
    let mut buf: Vec<u8> = Vec::with_capacity(4096);
    let mut chunk = [0u8; 4096];
    loop {
        match conn.read(&mut chunk) {
            Ok(0) => break,
            Ok(n) => {
                buf.extend_from_slice(&chunk[..n]);
                if buf.contains(&b'\n') {
                    break;
                }
            }
            Err(_) => break, // timeout or error: treat as missing response
        }
    }

    let raw = String::from_utf8_lossy(&buf);
    let line = raw.trim();
    if line.is_empty() {
        return json!({"ok": false, "error": "no response from app"});
    }
    match serde_json::from_str::<Value>(line) {
        Ok(v) if v.is_object() => v,
        Ok(_) => json!({"ok": false, "error": "malformed response"}),
        Err(_) => json!({"ok": false, "error": "malformed response"}),
    }
}

/// `resp["ok"] == true`. Emite no **stderr** o aviso que a resposta trouxer.
///
/// Aviso vai pro stderr de propósito: o stdout dos comandos de banco é uma
/// linha JSON que agentes parseiam, e sujá-la quebraria o contrato. Hoje o
/// único caso é `--workspace` mirando outra máquina — a execução está certa,
/// mas o resultado tem cara de ser da máquina onde o comando foi digitado.
pub fn is_ok(resp: &Value) -> bool {
    if let Some(Value::String(w)) = resp.get("warning") {
        eprintln!("cockpit: {w}");
    }
    resp.get("ok") == Some(&Value::Bool(true))
}

/// Returns error message from response.
pub fn error_text(resp: &Value) -> String {
    match resp.get("error") {
        Some(Value::String(s)) => s.clone(),
        Some(other) => other.to_string(),
        None => "failed".to_string(),
    }
}

/// Exits with response error (exit code 1).
pub fn fail_with(resp: &Value) -> ! {
    die(&format!("cockpit: {}", error_text(resp)), 1)
}
