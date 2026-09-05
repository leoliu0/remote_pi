//! Shared helpers: environment, path resolution, and column formatting.

use std::path::Path;

/// Returns current tab ID from `COCKPIT_TAB_ID` with fallback to `COCKPIT_PANE_ID`.
pub fn self_tab_id() -> Option<String> {
    env_non_empty("COCKPIT_TAB_ID").or_else(|| env_non_empty("COCKPIT_PANE_ID"))
}

/// Reads environment variable, treating empty string as absent.
pub fn env_non_empty(key: &str) -> Option<String> {
    match std::env::var(key) {
        Ok(v) if !v.is_empty() => Some(v),
        _ => None,
    }
}

/// Prints message to stderr and exits with given code.
pub fn die(msg: &str, code: i32) -> ! {
    eprintln!("{msg}");
    std::process::exit(code)
}

/// Expands `~` and resolves relative paths against current working directory.
pub fn resolve_path(path: &str) -> String {
    let mut p = path.to_string();
    if p == "~" || p.starts_with("~/") {
        if let Some(home) = home_dir() {
            p = if p == "~" {
                home
            } else {
                format!("{home}/{}", &p[2..])
            };
        }
    }
    let candidate = Path::new(&p);
    if candidate.is_absolute() {
        return p;
    }
    match std::env::current_dir() {
        Ok(cwd) => cwd.join(&p).to_string_lossy().into_owned(),
        Err(_) => p,
    }
}

/// Returns home directory path (`HOME` on POSIX, `USERPROFILE` on Windows).
pub fn home_dir() -> Option<String> {
    env_non_empty("HOME").or_else(|| env_non_empty("USERPROFILE"))
}

/// Right-pads string with spaces up to [n] characters without truncating.
pub fn pad(s: &str, n: usize) -> String {
    let len = s.chars().count();
    if len >= n {
        s.to_string()
    } else {
        let mut out = String::with_capacity(s.len() + (n - len));
        out.push_str(s);
        out.extend(std::iter::repeat(' ').take(n - len));
        out
    }
}

/// Returns the last path segment, handling both `/` and `\` separators.
pub fn basename(path: &str) -> String {
    let parts: Vec<&str> = if cfg!(windows) {
        path.split(['/', '\\']).filter(|p| !p.is_empty()).collect()
    } else {
        path.split('/').filter(|p| !p.is_empty()).collect()
    };
    match parts.last() {
        Some(last) => (*last).to_string(),
        None => path.to_string(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn pad_preenche_e_nunca_trunca() {
        assert_eq!(pad("ab", 5), "ab   ");
        assert_eq!(pad("abcdef", 3), "abcdef");
        assert_eq!(pad("", 2), "  ");
    }

    #[test]
    fn basename_ignora_barras_finais() {
        assert_eq!(basename("/a/b/c"), "c");
        assert_eq!(basename("/a/b/c/"), "c");
        assert_eq!(basename("solo"), "solo");
    }

    #[test]
    fn resolve_path_mantem_absoluto_intacto() {
        assert_eq!(resolve_path("/tmp/x"), "/tmp/x");
    }

    #[test]
    fn resolve_path_expande_til() {
        let home = home_dir().expect("HOME");
        assert_eq!(resolve_path("~"), home);
        assert_eq!(resolve_path("~/a"), format!("{home}/a"));
    }
}
