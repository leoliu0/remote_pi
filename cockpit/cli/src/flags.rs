//! Common flag parser for CLI commands.
use crate::util::die;

#[derive(Debug, Default, PartialEq)]
pub struct Flags {
    pub positionals: Vec<String>,
    pub tab_id: Option<String>,
    pub json: bool,
    pub force: bool,
    pub lines: Option<u64>,
    pub offset: Option<u64>,
    pub from_start: bool,
    /// `--enter`: used by `send` to send trailing newline as a separate write.
    pub enter: bool,
    /// `--focused`: targets currently focused tab (`@focused` sentinel).
    pub focused: bool,
}

/// Sentinel replaced by the app with the focused tab ID.
pub const FOCUSED: &str = "@focused";

fn int_value(flag: &str, raw: &str) -> u64 {
    match raw.parse::<u64>() {
        Ok(v) => v,
        Err(_) => die(
            &format!("cockpit: {flag} requires a non-negative integer"),
            2,
        ),
    }
}

impl Flags {
    pub fn parse(args: &[String]) -> Flags {
        let mut f = Flags::default();
        let mut i = 0usize;
        while i < args.len() {
            let a = args[i].as_str();
            if a == "--lines" || a == "-n" {
                if i + 1 >= args.len() {
                    die("cockpit: --lines requires a value", 2);
                }
                i += 1;
                f.lines = Some(int_value("--lines", &args[i]));
            } else if let Some(v) = a.strip_prefix("--lines=") {
                f.lines = Some(int_value("--lines", v));
            } else if a == "--offset" {
                if i + 1 >= args.len() {
                    die("cockpit: --offset requires a value", 2);
                }
                i += 1;
                f.offset = Some(int_value("--offset", &args[i]));
            } else if let Some(v) = a.strip_prefix("--offset=") {
                f.offset = Some(int_value("--offset", v));
            } else if a == "--from-start" {
                f.from_start = true;
            } else if a == "--tab-id" || a == "-t" {
                if i + 1 >= args.len() {
                    die("cockpit: --tab-id requires a value", 2);
                }
                i += 1;
                f.tab_id = Some(args[i].clone());
            } else if let Some(v) = a.strip_prefix("--tab-id=") {
                f.tab_id = Some(v.to_string());
            } else if a == "--enter" {
                f.enter = true;
            } else if a == "--focused" {
                f.focused = true;
            } else if a == "--json" {
                f.json = true;
            } else if a == "--force" || a == "-f" {
                f.force = true;
            } else if a == "--" {
                f.positionals.extend(args[i + 1..].iter().cloned());
                break;
            } else {
                f.positionals.push(a.to_string());
            }
            i += 1;
        }
        f
    }

    /// Effective target in priority order: `--focused`, `--tab-id`, emitting tab.
    pub fn effective_tab_id(&self) -> Option<String> {
        if self.focused {
            return Some(FOCUSED.to_string());
        }
        self.tab_id.clone().or_else(crate::util::self_tab_id)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn v(args: &[&str]) -> Vec<String> {
        args.iter().map(|s| s.to_string()).collect()
    }

    #[test]
    fn positionals_and_tab_id() {
        let f = Flags::parse(&v(&["--tab-id", "t3", "hello", "world"]));
        assert_eq!(f.tab_id.as_deref(), Some("t3"));
        assert_eq!(f.positionals, vec!["hello", "world"]);
    }

    #[test]
    fn equals_form() {
        let f = Flags::parse(&v(&["--tab-id=t9", "--lines=25", "--offset=5"]));
        assert_eq!(f.tab_id.as_deref(), Some("t9"));
        assert_eq!(f.lines, Some(25));
        assert_eq!(f.offset, Some(5));
    }

    #[test]
    fn short_aliases() {
        let f = Flags::parse(&v(&["-t", "t1", "-n", "10", "-f"]));
        assert_eq!(f.tab_id.as_deref(), Some("t1"));
        assert_eq!(f.lines, Some(10));
        assert!(f.force);
    }

    #[test]
    fn separator_sends_rest_to_positionals() {
        let f = Flags::parse(&v(&["--json", "--", "--not-a-flag", "-x"]));
        assert!(f.json);
        assert_eq!(f.positionals, vec!["--not-a-flag", "-x"]);
    }

    #[test]
    fn focused_overrides_tab_id_and_env() {
        let f = Flags::parse(&v(&["--focused", "--tab-id", "t1", "hi"]));
        assert_eq!(f.effective_tab_id().as_deref(), Some(FOCUSED));
        assert_eq!(f.positionals, vec!["hi"], "flag is not treated as text");
    }

    #[test]
    fn enter_does_not_leak_into_positionals() {
        let f = Flags::parse(&v(&["--enter", "npm", "test"]));
        assert!(f.enter);
        assert_eq!(f.positionals, vec!["npm", "test"], "text stays clean");
        assert!(!Flags::parse(&v(&["npm", "test"])).enter);
    }

    #[test]
    fn from_start_and_json() {
        let f = Flags::parse(&v(&["--from-start", "--json"]));
        assert!(f.from_start);
        assert!(f.json);
    }
}
