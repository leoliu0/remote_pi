// Types for outer envelope parsing
#![allow(dead_code)]

use std::sync::OnceLock;

use serde::{Deserialize, Serialize};

fn default_room() -> String {
    "main".to_string()
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct OuterEnvelope {
    pub peer: String,
    /// Optional sub-channel (plano 17). Absent in legacy frames → "main".
    #[serde(default = "default_room")]
    pub room: String,
    pub ct: String, // base64 — nunca decodificado aqui
}

/// Environment variable name overriding outer envelope payload ceiling (integer in MiB).
pub const MAX_CT_ENV: &str = "RELAY_MAX_CT_MIB";

/// Default ceiling: 4 MiB base64-decoded payload.
pub const DEFAULT_MAX_CT_MIB: usize = 4;

/// Effective ceiling in bytes. Read once from [`MAX_CT_ENV`] and cached.
/// Falls back to 4 MiB default on missing or invalid value.
pub fn max_ct_bytes() -> usize {
    static MAX_CT_BYTES: OnceLock<usize> = OnceLock::new();
    *MAX_CT_BYTES.get_or_init(|| {
        let mib = std::env::var(MAX_CT_ENV)
            .ok()
            .and_then(|s| s.trim().parse::<usize>().ok())
            .filter(|&n| n > 0)
            .unwrap_or(DEFAULT_MAX_CT_MIB);
        mib * 1024 * 1024
    })
}

#[derive(Debug, thiserror::Error)]
pub enum ParseError {
    #[error("invalid json: {0}")]
    InvalidJson(#[from] serde_json::Error),
    #[error("payload too large: {0} bytes (max {1})")]
    TooLarge(usize, usize),
}

/// Parses a JSONL line into an outer envelope and validates `ct` size
/// against the configured ceiling ([`max_ct_bytes`]).
pub fn parse_line(line: &str) -> Result<OuterEnvelope, ParseError> {
    parse_line_with_max(line, max_ct_bytes())
}

/// Testable core of [`parse_line`] with injected ceiling.
fn parse_line_with_max(line: &str, max_ct_bytes: usize) -> Result<OuterEnvelope, ParseError> {
    let env: OuterEnvelope = serde_json::from_str(line)?;
    let estimated = env.ct.len() * 3 / 4;
    if estimated > max_ct_bytes {
        return Err(ParseError::TooLarge(estimated, max_ct_bytes));
    }
    Ok(env)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_minimal_envelope() {
        let line = r#"{"peer":"abc","ct":"AAA="}"#;
        let env = parse_line(line).unwrap();
        assert_eq!(env.peer, "abc");
        assert_eq!(env.room, "main"); // defaults to "main" when absent
        assert_eq!(env.ct, "AAA=");
    }

    #[test]
    fn parses_envelope_with_room() {
        let line = r#"{"peer":"abc","room":"aB12CD34eF56","ct":"AAA="}"#;
        let env = parse_line(line).unwrap();
        assert_eq!(env.room, "aB12CD34eF56");
    }

    #[test]
    fn rejects_too_large() {
        // 12 MiB payload exceeds 4 MiB default ceiling.
        let big = "A".repeat(12 * 1024 * 1024);
        let line = format!(r#"{{"peer":"abc","ct":"{}"}}"#, big);
        assert!(matches!(parse_line(&line), Err(ParseError::TooLarge(..))));
    }

    #[test]
    fn accepts_two_mb_payload_under_default() {
        // ~2.25 MiB estimated payload passes under 4 MiB default.
        let img = "A".repeat(3 * 1024 * 1024);
        let line = format!(r#"{{"peer":"abc","ct":"{}"}}"#, img);
        let env = parse_line(&line).expect("≈2 MB payload must pass under 4 MiB default");
        assert_eq!(env.peer, "abc");
    }

    #[test]
    fn default_max_ct_bytes_is_four_mib() {
        // Without RELAY_MAX_CT_MIB in test env, effective ceiling is 4 MiB.
        assert_eq!(max_ct_bytes(), DEFAULT_MAX_CT_MIB * 1024 * 1024);
        assert_eq!(max_ct_bytes(), 4 * 1024 * 1024);
    }

    #[test]
    fn injected_max_overrides_limit() {
        // Testable override via core function with injected ceiling.
        let payload = "A".repeat(3 * 1024 * 1024);
        let line = format!(r#"{{"peer":"abc","ct":"{}"}}"#, payload);

        assert!(matches!(
            parse_line_with_max(&line, 1024 * 1024),
            Err(ParseError::TooLarge(..))
        ));
        assert!(parse_line_with_max(&line, 4 * 1024 * 1024).is_ok());
    }

    #[test]
    fn rejects_invalid_json() {
        assert!(matches!(
            parse_line("not json at all"),
            Err(ParseError::InvalidJson(_))
        ));
    }
}
