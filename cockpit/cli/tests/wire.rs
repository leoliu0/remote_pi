//! Wire integration tests: spawns a mock socket server, runs the actual binary
//! against it, and verifies the incoming requests and command output.

#![cfg(unix)]

use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixListener;
use std::process::Command;

use serde_json::Value;
use std::sync::atomic::{AtomicU64, Ordering};

/// Creates a unique temporary directory for concurrent test execution.
fn unique_dir(prefix: &str) -> std::path::PathBuf {
    static SEQ: AtomicU64 = AtomicU64::new(0);
    std::env::temp_dir().join(format!(
        "{prefix}-{}-{}",
        std::process::id(),
        SEQ.fetch_add(1, Ordering::Relaxed)
    ))
}

/// Spawns a socket listener on a temporary path, runs `cockpit <args>`, and
/// returns `(received_request, stdout, stderr, exit_code)`.
fn run_against_fake_app(args: &[&str], response: &str) -> (Value, String, String, i32) {
    let dir = unique_dir("cockpit-wire");
    std::fs::create_dir_all(&dir).unwrap();
    let sock_path = dir.join("status.sock");
    let listener = UnixListener::bind(&sock_path).unwrap();

    let response = response.to_string();
    let server = std::thread::spawn(move || {
        let (stream, _) = listener.accept().unwrap();
        let mut reader = BufReader::new(stream);
        let mut line = String::new();
        reader.read_line(&mut line).unwrap();
        let mut stream = reader.into_inner();
        stream.write_all(response.as_bytes()).unwrap();
        stream.write_all(b"\n").unwrap();
        stream.flush().unwrap();
        drop(stream); // close -> client sees EOF
        line
    });

    let out = Command::new(env!("CARGO_BIN_EXE_cockpit"))
        .args(args)
        .env("COCKPIT_STATUS_SOCK", &sock_path)
        .env("COCKPIT_TAB_ID", "t7")
        .env_remove("COCKPIT_STATUS_PORT")
        .env_remove("COCKPIT_STATUS_TOKEN")
        .output()
        .unwrap();

    let request_line = server.join().unwrap();
    let _ = std::fs::remove_dir_all(&dir);
    (
        serde_json::from_str(&request_line).expect("request is not JSON"),
        String::from_utf8_lossy(&out.stdout).into_owned(),
        String::from_utf8_lossy(&out.stderr).into_owned(),
        out.status.code().unwrap_or(-1),
    )
}

#[test]
fn send_sends_base64_text_with_type_cmd() {
    let (req, _, _, code) = run_against_fake_app(&["send", "hello", "world"], r#"{"ok":true}"#);
    assert_eq!(req["type"], "cmd");
    assert_eq!(req["cmd"], "write");
    assert_eq!(
        req["tabId"], "t7",
        "falls back to COCKPIT_TAB_ID when --tab-id is omitted"
    );
    // "hello world" in base64
    assert_eq!(req["args"]["data"], "aGVsbG8gd29ybGQ=");
    assert_eq!(code, 0);
}

#[test]
fn send_key_resolves_named_keys() {
    let (req, _, _, code) = run_against_fake_app(&["send-key", "C-c", "Enter"], r#"{"ok":true}"#);
    // \x03\r
    assert_eq!(req["args"]["data"], "Aw0=");
    assert_eq!(code, 0);
}

#[test]
fn explicit_tab_id_overrides_env() {
    let (req, _, _, _) = run_against_fake_app(&["send", "--tab-id", "t99", "oi"], r#"{"ok":true}"#);
    assert_eq!(req["tabId"], "t99");
}

#[test]
fn list_tabs_uses_wire_command_and_formats() {
    let resp = r#"{"ok":true,"data":[
        {"id":"t1","kind":"terminal","title":"zsh","workspacePath":"/x/remote_pi","working":true}
    ]}"#;
    let (req, stdout, _, code) = run_against_fake_app(&["list-tabs"], resp);
    assert_eq!(req["cmd"], "list-panes", "wire command remains list-panes");
    assert!(stdout.starts_with("● t1"), "{stdout}");
    assert!(stdout.contains("remote_pi"), "{stdout}");
    assert_eq!(code, 0);
}

#[test]
fn empty_list_prints_none() {
    let (_, stdout, _, code) = run_against_fake_app(&["list-tabs"], r#"{"ok":true,"data":[]}"#);
    assert_eq!(stdout, "(none)\n");
    assert_eq!(code, 0);
}

#[test]
fn read_tab_decodes_base64_and_warns_truncation() {
    // "linha1\nlinha2" em base64
    let resp = r#"{"ok":true,"data":{"text":"bGluaGExCmxpbmhhMg==","truncated":true}}"#;
    let (req, stdout, stderr, code) = run_against_fake_app(&["read-tab", "--lines", "5"], resp);
    assert_eq!(req["cmd"], "read-pane");
    assert_eq!(req["args"]["lines"], 5);
    assert_eq!(stdout, "linha1\nlinha2\n");
    assert!(stderr.contains("output truncated"), "{stderr}");
    assert_eq!(code, 0);
}

#[test]
fn app_error_maps_to_exit_1_on_stderr() {
    let (_, stdout, stderr, code) =
        run_against_fake_app(&["list-tabs"], r#"{"ok":false,"error":"boom"}"#);
    assert_eq!(stdout, "");
    assert_eq!(stderr, "cockpit: boom\n");
    assert_eq!(code, 1);
}

#[test]
fn db_query_builds_args_and_prints_json_contract() {
    let resp = r#"{"ok":true,"data":{"rowCount":1}}"#;
    let (req, stdout, _, code) = run_against_fake_app(
        &[
            "db", "query", "--db", "dev", "--sql", "SELECT 1", "--limit", "10",
        ],
        resp,
    );
    assert_eq!(req["cmd"], "db-query");
    assert_eq!(req["args"]["db"], "dev");
    assert_eq!(req["args"]["sql"], "SELECT 1");
    assert_eq!(req["args"]["limit"], "10");
    assert_eq!(stdout, "{\"ok\":{\"rowCount\":1}}\n");
    assert_eq!(code, 0);
}

#[test]
fn db_known_error_maps_to_structured_kind() {
    let resp = r#"{"ok":false,"error":"read_only_connection: agents are read-only here"}"#;
    let (_, stdout, _, code) = run_against_fake_app(&["db", "list"], resp);
    let parsed: Value = serde_json::from_str(stdout.trim()).unwrap();
    assert_eq!(parsed["error"]["kind"], "read_only_connection");
    assert_eq!(parsed["error"]["message"], "agents are read-only here");
    assert_eq!(code, 1, "db errors exit with code 1");
}

#[test]
fn db_unknown_error_falls_back_to_generic_kind() {
    let resp = r#"{"ok":false,"error":"algo inesperado"}"#;
    let (_, stdout, _, code) = run_against_fake_app(&["db", "list"], resp);
    let parsed: Value = serde_json::from_str(stdout.trim()).unwrap();
    assert_eq!(parsed["error"]["kind"], "error");
    assert_eq!(parsed["error"]["message"], "algo inesperado");
    assert_eq!(code, 1);
}

#[test]
fn redis_sends_command_parts() {
    let (req, _, _, _) = run_against_fake_app(
        &["redis", "--db", "cache", "GET", "session:42"],
        r#"{"ok":true,"data":"v"}"#,
    );
    assert_eq!(req["cmd"], "redis-cmd");
    assert_eq!(req["args"]["db"], "cache");
    assert_eq!(req["args"]["parts"][0], "GET");
    assert_eq!(req["args"]["parts"][1], "session:42");
}

#[test]
fn mongo_browse_sends_collection_and_database() {
    let (req, _, _, _) = run_against_fake_app(
        &[
            "mongo",
            "browse",
            "--db",
            "app",
            "--database",
            "prod",
            "users",
            "--filter",
            "{}",
        ],
        r#"{"ok":true,"data":null}"#,
    );
    assert_eq!(req["cmd"], "mongo-browse");
    assert_eq!(req["args"]["collection"], "users");
    assert_eq!(req["args"]["database"], "prod");
    assert_eq!(req["args"]["filter"], "{}");
}

#[test]
fn browse_sends_url_on_wire() {
    let (req, stdout, _, code) = run_against_fake_app(
        &["browse", "http://localhost:3000"],
        r#"{"ok":true,"data":{"mode":"inline","url":"http://localhost:3000"}}"#,
    );
    assert_eq!(req["cmd"], "browse");
    assert_eq!(req["args"]["url"], "http://localhost:3000");
    assert_eq!(stdout, "ok\n");
    assert_eq!(code, 0);
}

#[test]
fn browse_json_echoes_data() {
    let (_, stdout, _, _) = run_against_fake_app(
        &["browse", "--json", "http://localhost:3000"],
        r#"{"ok":true,"data":{"mode":"system","url":"http://localhost:3000"}}"#,
    );
    let parsed: Value = serde_json::from_str(stdout.trim()).unwrap();
    assert_eq!(parsed["mode"], "system");
}

#[test]
fn close_tab_sem_alvo_nao_manda_target() {
    // Sem posicional o app cai na própria tab ($COCKPIT_TAB_ID) — mandar
    // `target` vazio faria o app tentar resolvê-lo como label.
    let (req, stdout, _, code) =
        run_against_fake_app(&["close-tab"], r#"{"ok":true,"data":{"tabId":"t7"}}"#);
    assert_eq!(req["cmd"], "close-tab");
    assert!(req["args"].get("target").is_none(), "{:?}", req["args"]);
    assert_eq!(stdout, "t7\n");
    assert_eq!(code, 0);
}

#[test]
fn close_tab_aceita_label_ou_id_posicional() {
    let (req, _, _, _) = run_against_fake_app(
        &["close-tab", "Extension"],
        r#"{"ok":true,"data":{"tabId":"t3"}}"#,
    );
    assert_eq!(req["cmd"], "close-tab");
    assert_eq!(req["args"]["target"], "Extension");
}

#[test]
fn close_tab_json_ecoa_o_data() {
    let (_, stdout, _, _) = run_against_fake_app(
        &["close-tab", "--json", "t3"],
        r#"{"ok":true,"data":{"tabId":"t3"}}"#,
    );
    let parsed: Value = serde_json::from_str(stdout.trim()).unwrap();
    assert_eq!(parsed["tabId"], "t3");
}

#[test]
fn close_tab_propaga_erro_do_app() {
    let (_, _, stderr, code) = run_against_fake_app(
        &["close-tab", "nope"],
        r#"{"ok":false,"error":"no tab with id or label \"nope\""}"#,
    );
    assert_eq!(code, 1);
    assert!(stderr.contains("nope"), "{stderr}");
}

#[test]
fn open_resolves_relative_path_to_absolute() {
    let (req, _, _, _) = run_against_fake_app(&["open", "arquivo.txt"], r#"{"ok":true}"#);
    assert_eq!(req["cmd"], "open");
    let path = req["args"]["path"].as_str().unwrap();
    assert!(path.starts_with('/'), "esperava absoluto, veio {path}");
    assert!(path.ends_with("/arquivo.txt"), "{path}");
}

#[test]
fn bare_file_is_shortcut_for_open() {
    let (req, _, _, _) = run_against_fake_app(&["/tmp/nota.md"], r#"{"ok":true}"#);
    assert_eq!(req["cmd"], "open");
    assert_eq!(req["args"]["path"], "/tmp/nota.md");
}

#[test]
fn hook_reports_status_over_same_socket() {
    // Hook reads event from stdin; exercises full path.
    let dir = unique_dir("cockpit-hook");
    std::fs::create_dir_all(&dir).unwrap();
    let sock_path = dir.join("status.sock");
    let listener = UnixListener::bind(&sock_path).unwrap();
    let server = std::thread::spawn(move || {
        let (stream, _) = listener.accept().unwrap();
        let mut line = String::new();
        BufReader::new(stream).read_line(&mut line).unwrap();
        line
    });

    let mut child = Command::new(env!("CARGO_BIN_EXE_cockpit"))
        .arg("hook")
        .env("COCKPIT_STATUS_SOCK", &sock_path)
        .env("COCKPIT_PANE_ID", "t3")
        .stdin(std::process::Stdio::piped())
        .stdout(std::process::Stdio::piped())
        .spawn()
        .unwrap();
    child
        .stdin
        .as_mut()
        .unwrap()
        .write_all(br#"{"hook_event_name":"Stop","session_id":"s1"}"#)
        .unwrap();
    let out = child.wait_with_output().unwrap();

    let line = server.join().unwrap();
    let _ = std::fs::remove_dir_all(&dir);
    let req: Value = serde_json::from_str(&line).unwrap();
    assert_eq!(req["paneId"], "t3");
    assert_eq!(req["st"], "idle");
    assert_eq!(req["ev"], "Stop");
    assert_eq!(req["sid"], "s1");
    assert!(req.get("type").is_none(), "hook does not send type:cmd");
    assert!(out.stdout.is_empty(), "hook never writes to stdout");
    assert_eq!(out.status.code(), Some(0));
}

#[test]
fn hook_outside_cockpit_is_silent_noop() {
    let out = Command::new(env!("CARGO_BIN_EXE_cockpit"))
        .arg("hook")
        .env_remove("COCKPIT_PANE_ID")
        .env_remove("COCKPIT_STATUS_SOCK")
        .env_remove("COCKPIT_STATUS_PORT")
        .stdin(std::process::Stdio::null())
        .output()
        .unwrap();
    assert_eq!(out.status.code(), Some(0));
    assert!(out.stdout.is_empty());
    assert!(out.stderr.is_empty());
}

#[test]
fn send_with_enter_sends_return_in_second_write() {
    // Enter is sent in a SEPARATE write so TUIs distinguish typed input from paste blocks.
    // If this is collapsed into a single write, the test must fail.
    let dir = unique_dir("cockpit-enter");
    std::fs::create_dir_all(&dir).unwrap();
    let sock_path = dir.join("status.sock");
    let listener = UnixListener::bind(&sock_path).unwrap();

    let server = std::thread::spawn(move || {
        let mut requests = Vec::new();
        for _ in 0..2 {
            let (stream, _) = listener.accept().unwrap();
            let mut reader = BufReader::new(stream);
            let mut line = String::new();
            reader.read_line(&mut line).unwrap();
            let mut stream = reader.into_inner();
            stream.write_all(b"{\"ok\":true}\n").unwrap();
            stream.flush().unwrap();
            drop(stream);
            requests.push(line);
        }
        requests
    });

    let out = Command::new(env!("CARGO_BIN_EXE_cockpit"))
        .args(["send", "--tab-id", "t4", "--enter", "npm", "test"])
        .env("COCKPIT_STATUS_SOCK", &sock_path)
        .output()
        .unwrap();

    let requests = server.join().unwrap();
    let _ = std::fs::remove_dir_all(&dir);
    assert_eq!(
        requests.len(),
        2,
        "esperava texto e Enter em escritas separadas"
    );

    let texto: Value = serde_json::from_str(&requests[0]).unwrap();
    assert_eq!(texto["cmd"], "write");
    assert_eq!(texto["tabId"], "t4");
    // "npm test" (the flag must not leak into typed text)
    assert_eq!(texto["args"]["data"], "bnBtIHRlc3Q=");

    let enter: Value = serde_json::from_str(&requests[1]).unwrap();
    assert_eq!(enter["tabId"], "t4", "o Enter vai pra MESMA aba");
    assert_eq!(enter["args"]["data"], "DQ==", "\\r isolado");
    assert_eq!(out.status.code(), Some(0));
}

#[test]
fn send_without_enter_makes_single_write() {
    let (req, _, _, code) = run_against_fake_app(&["send", "ls"], r#"{"ok":true}"#);
    assert_eq!(req["args"]["data"], "bHM=", "no trailing \\r glued onto the text");
    assert_eq!(code, 0);
}

#[test]
fn focused_sends_sentinel_for_app_to_resolve() {
    // The app resolves which tab is focused; CLI just sends `@focused`.
    // External tools (voice dictation) do not need to discover or copy a tab id.
    // No `--enter` here on purpose: the helper accepts ONE connection, and Enter
    // is a second write (covered by `send_with_enter_sends_return_in_second_write`).
    let (req, _, _, code) = run_against_fake_app(&["send", "--focused", "oi"], r#"{"ok":true}"#);
    assert_eq!(req["tabId"], "@focused");
    assert_eq!(code, 0);
}

#[test]
fn focused_ignores_env_tab_id() {
    // Helper sets COCKPIT_TAB_ID; --focused must win so text goes to the focused tab.
    let (req, _, _, _) = run_against_fake_app(&["send", "--focused", "oi"], r#"{"ok":true}"#);
    assert_ne!(req["tabId"], "t7");
    assert_eq!(req["tabId"], "@focused");
}

#[test]
fn finds_well_known_socket_without_env() {
    // External-tool case: no inherited env. CLI falls back to ~/.cockpit/status.sock.
    // HOME is pointed at temp so this does not depend on a real app running.
    let dir = unique_dir("cockpit-discovery");
    std::fs::create_dir_all(dir.join(".cockpit")).unwrap();
    let sock_path = dir.join(".cockpit/status.sock");
    let listener = UnixListener::bind(&sock_path).unwrap();
    let server = std::thread::spawn(move || {
        let (stream, _) = listener.accept().unwrap();
        let mut reader = BufReader::new(stream);
        let mut line = String::new();
        reader.read_line(&mut line).unwrap();
        let mut stream = reader.into_inner();
        stream.write_all(b"{\"ok\":true}\n").unwrap();
        stream.flush().unwrap();
        drop(stream);
        line
    });

    let out = Command::new(env!("CARGO_BIN_EXE_cockpit"))
        .args(["send", "--focused", "ditado"])
        .env("HOME", &dir)
        .env_remove("COCKPIT_STATUS_SOCK")
        .env_remove("COCKPIT_STATUS_PORT")
        .env_remove("COCKPIT_TAB_ID")
        .env_remove("COCKPIT_PANE_ID")
        .output()
        .unwrap();

    let line = server.join().unwrap();
    let _ = std::fs::remove_dir_all(&dir);
    let req: Value = serde_json::from_str(&line).unwrap();
    assert_eq!(req["cmd"], "write");
    assert_eq!(req["tabId"], "@focused");
    assert_eq!(
        out.status.code(),
        Some(0),
        "stderr: {}",
        String::from_utf8_lossy(&out.stderr)
    );
}

#[test]
fn without_app_fails_with_exit_3() {
    let dir = unique_dir("cockpit-noapp");
    std::fs::create_dir_all(&dir).unwrap();
    let out = Command::new(env!("CARGO_BIN_EXE_cockpit"))
        .args(["list-tabs"])
        .env("HOME", &dir)
        .env_remove("COCKPIT_STATUS_SOCK")
        .env_remove("COCKPIT_STATUS_PORT")
        .output()
        .unwrap();
    let _ = std::fs::remove_dir_all(&dir);
    assert_eq!(out.status.code(), Some(3));
    assert!(
        String::from_utf8_lossy(&out.stderr).contains("Is the app running?"),
        "stderr: {}",
        String::from_utf8_lossy(&out.stderr)
    );
}
