//! `cockpit` — internal CLI for Cockpit and agent lifecycle hook helper.
//! Communicates with the Cockpit desktop app over local socket.

mod commands;
mod flags;
mod hook;
mod keys;
mod transport;
mod util;

/// CLI version string.
const VERSION: &str = concat!(env!("CARGO_PKG_VERSION"), "r");

const HELP: &str = include_str!("../text/help.txt");

fn main() {
    let argv: Vec<String> = std::env::args().skip(1).collect();
    if argv.is_empty() {
        eprint!("{HELP}");
        std::process::exit(2);
    }
    let first = argv[0].as_str();
    if first == "--help" || first == "-h" || first == "help" {
        print!("{HELP}");
        std::process::exit(0);
    }
    if first == "--version" || first == "-v" {
        println!("cockpit {VERSION}");
        std::process::exit(0);
    }

    let args = &argv[1..];
    match first {
        // Lifecycle hook helper for agents (Claude Code / Codex CLI)
        "hook" => hook::run(args),
        "send" => commands::send(args),
        "send-key" | "send-keys" => commands::send_key(args),
        "open" => commands::open(args),
        // Stable wire command 'list-panes' with 'list-tabs' surface alias
        "list-tabs" | "list-panes" => commands::list("list-panes", args),
        "list-workspaces" => commands::list("list-workspaces", args),
        "list-tasks" => commands::list("list-tasks", args),
        "read-tab" | "read-pane" => commands::read("read-pane", args),
        "read-task" => commands::read("read-task", args),
        "db" => commands::db(args),
        "http" => commands::http(args),
        "redis" => commands::redis(args),
        "mongo" => commands::mongo(args),
        "new-tab" => commands::new_tab(args),
        "close-tab" => commands::close_tab(args),
        "browse" => commands::browse_url(args),
        "orchestrate" => commands::orchestrate(args),
        "install-skill" => commands::install_skill(args),
        // Shortcut: `cockpit <file>` opens file directly
        _ => commands::open(&argv),
    }
}
