//! `cockpit hook` — helper invoked by agents during lifecycle hooks (Claude Code & Codex CLI).
//! Translates agent events into status transitions (working / waiting / idle) sent over socket.

use std::io::{Read, Write};

use serde_json::{json, Value};

use crate::util::env_non_empty;

/// Runs the hook handler. Always exits silently.
pub fn run(args: &[String]) -> ! {
    let _ = try_run(harness_from(args));
    std::process::exit(0)
}

/// Reads `--harness <name>` from arguments, defaulting to `claude`.
fn harness_from(args: &[String]) -> String {
    let mut it = args.iter();
    while let Some(a) = it.next() {
        if a == "--harness" {
            if let Some(v) = it.next() {
                if !v.trim().is_empty() {
                    return v.trim().to_string();
                }
            }
        } else if let Some(v) = a.strip_prefix("--harness=") {
            if !v.trim().is_empty() {
                return v.trim().to_string();
            }
        }
    }
    "claude".to_string()
}

fn try_run(harness: String) -> Option<()> {
    let pane_id = env_non_empty("COCKPIT_PANE_ID")?; // not inside a Cockpit session
    let sock = env_non_empty("COCKPIT_STATUS_SOCK");
    let port = env_non_empty("COCKPIT_STATUS_PORT").and_then(|p| p.parse::<u16>().ok());
    if sock.is_none() && port.is_none() {
        return None;
    }

    let mut raw = String::new();
    std::io::stdin().read_to_string(&mut raw).ok()?;
    if raw.trim().is_empty() {
        return None;
    }
    let decoded: Value = serde_json::from_str(&raw).ok()?;
    if !decoded.is_object() {
        return None;
    }

    let event = str_field(&decoded, "hook_event_name");
    let status = status_for(&event, &decoded)?; // unhandled event -> ignore

    let mut payload = json!({
        "paneId": pane_id,
        "st": status,
        // Raw event name for distinguishing turn start vs tool activity
        "ev": event,
        "sid": str_field(&decoded, "session_id"),
        "tx": str_field(&decoded, "transcript_path"),
        // Emitting harness name for session resumption
        "hn": harness,
    });
    // Pass turn_id when present (e.g. Codex)
    let turn = str_field(&decoded, "turn_id");
    if !turn.is_empty() {
        payload["tid"] = json!(turn);
    }
    // Status token for TCP transport authentication
    if let Ok(tok) = std::env::var("COCKPIT_STATUS_TOKEN") {
        payload["tok"] = json!(tok);
    }

    let mut line = payload.to_string();
    line.push('\n');

    #[cfg(unix)]
    if let Some(path) = sock.as_deref() {
        let mut s = std::os::unix::net::UnixStream::connect(path).ok()?;
        s.write_all(line.as_bytes()).ok()?;
        let _ = s.flush();
        return Some(());
    }
    #[cfg(not(unix))]
    let _ = sock.as_deref();

    let mut s = std::net::TcpStream::connect(("127.0.0.1", port?)).ok()?;
    s.write_all(line.as_bytes()).ok()?;
    let _ = s.flush();
    Some(())
}

/// Returns string field from JSON value, defaulting to `""`.
fn str_field(v: &Value, key: &str) -> String {
    match v.get(key) {
        Some(Value::String(s)) => s.clone(),
        Some(Value::Null) | None => String::new(),
        Some(other) => other.to_string(),
    }
}

/// Maps hook event to turn status, or `None` if the event should not change the indicator.
pub fn status_for(event: &str, json: &Value) -> Option<&'static str> {
    match event {
        "UserPromptSubmit" | "PostToolUse" => Some("working"),
        "PreToolUse" => {
            // Blocking tools (plan mode form, plan approval) do not emit `Notification`
            let tool = str_field(json, "tool_name");
            const BLOCKING: [&str; 2] = ["AskUserQuestion", "ExitPlanMode"];
            Some(if BLOCKING.contains(&tool.as_str()) {
                "waiting"
            } else {
                "working"
            })
        }
        "Notification" => {
            // Covers both "needs approval" and "idle waiting for input".
            let hint = format!(
                "{} {}",
                str_field(json, "notification_type"),
                str_field(json, "message")
            )
            .to_lowercase();
            Some(if hint.contains("idle") {
                "idle"
            } else {
                "waiting"
            })
        }
        // Codex: approval has its own event, no text heuristic.
        "PermissionRequest" => Some("waiting"),
        "Stop" | "SessionStart" | "SessionEnd" => Some("idle"),
        // Explicitly inert (Codex): subagent and compaction are not the tab's turn.
        "SubagentStart" | "SubagentStop" | "PreCompact" | "PostCompact" => None,
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn work_events() {
        assert_eq!(status_for("UserPromptSubmit", &json!({})), Some("working"));
        assert_eq!(status_for("PostToolUse", &json!({})), Some("working"));
    }

    #[test]
    fn blocking_pretooluse_becomes_waiting() {
        let blocking = json!({"tool_name": "AskUserQuestion"});
        assert_eq!(status_for("PreToolUse", &blocking), Some("waiting"));
        let plan = json!({"tool_name": "ExitPlanMode"});
        assert_eq!(status_for("PreToolUse", &plan), Some("waiting"));
        let common = json!({"tool_name": "Bash"});
        assert_eq!(status_for("PreToolUse", &common), Some("working"));
        // missing tool_name stays working
        assert_eq!(status_for("PreToolUse", &json!({})), Some("working"));
    }

    #[test]
    fn notification_distinguishes_idle_from_waiting() {
        let idle = json!({"message": "Claude is idle waiting for input"});
        assert_eq!(status_for("Notification", &idle), Some("idle"));
        let tipo_idle = json!({"notification_type": "IDLE"});
        assert_eq!(status_for("Notification", &tipo_idle), Some("idle"));
        let approval = json!({"message": "needs your approval"});
        assert_eq!(status_for("Notification", &approval), Some("waiting"));
    }

    #[test]
    fn turn_end_and_session_are_idle() {
        for ev in ["Stop", "SessionStart", "SessionEnd"] {
            assert_eq!(status_for(ev, &json!({})), Some("idle"));
        }
    }

    #[test]
    fn unknown_event_does_not_move_indicator() {
        assert_eq!(status_for("", &json!({})), None);
        assert_eq!(status_for("Whatever", &json!({})), None);
    }

    #[test]
    fn codex_permission_request_is_waiting() {
        // Real Codex payload: the event itself is enough; no text to interpret.
        let ev = json!({"hook_event_name": "PermissionRequest", "tool_name": "shell"});
        assert_eq!(status_for("PermissionRequest", &ev), Some("waiting"));
    }

    #[test]
    fn codex_subagent_and_compaction_are_inert() {
        for ev in [
            "SubagentStart",
            "SubagentStop",
            "PreCompact",
            "PostCompact",
        ] {
            assert_eq!(status_for(ev, &json!({})), None, "{ev} must not move the tab");
        }
    }

    #[test]
    fn codex_events_cover_the_turn_cycle() {
        // Sequence observed in a real `codex exec` session.
        let cycle = [
            ("SessionStart", "idle"),
            ("UserPromptSubmit", "working"),
            ("PreToolUse", "working"),
            ("PostToolUse", "working"),
            ("PermissionRequest", "waiting"),
            ("Stop", "idle"),
            ("SessionEnd", "idle"),
        ];
        for (ev, expected) in cycle {
            assert_eq!(status_for(ev, &json!({})), Some(expected), "event {ev}");
        }
    }

    #[test]
    fn harness_defaults_to_claude() {
        // Older entries (installed before the flag existed) only pass `hook`.
        assert_eq!(harness_from(&[]), "claude");
        assert_eq!(harness_from(&["--harness".into()]), "claude");
        assert_eq!(harness_from(&["--harness".into(), "  ".into()]), "claude");
    }

    #[test]
    fn harness_accepts_both_forms() {
        assert_eq!(
            harness_from(&["--harness".into(), "codex".into()]),
            "codex"
        );
        assert_eq!(harness_from(&["--harness=codex".into()]), "codex");
    }

    #[test]
    fn str_field_normalizes_missing_and_non_string() {
        assert_eq!(str_field(&json!({}), "x"), "");
        assert_eq!(str_field(&json!({"x": null}), "x"), "");
        assert_eq!(str_field(&json!({"x": "v"}), "x"), "v");
        assert_eq!(str_field(&json!({"x": 7}), "x"), "7");
    }
}
