# Plan — turn status for Codex CLI

Extend the tab turn indicator (spinner / badge / chime / notification), today
exclusive to Claude Code, to **Codex CLI** sessions.

> **Status: implemented (2026-08-11), pending in-app E2E.** Waves 0–4 are
> closed; what remains is running the real app and seeing the four states on
> a tab (that is what the user will test). Reference docs for the final
> result live in [`turn-status-hooks.md`](turn-status-hooks.md) — this file
> stays as a record of the path taken and the investigation findings.

## Context

Cockpit already knows when an agent is working, finished the turn, or needs
user action. The mechanism (see `project_cockpit_claude_turn_status`):

1. `ClaudeHookInstallerImpl` materializes the internal CLI in `~/.cockpit/bin/`
   and idempotently appends a marked entry (`_cockpit: v1`) on each event in
   `~/.claude/settings.json`, without touching the user's hooks.
2. Claude runs `<cli> hook` on each event, passing JSON on stdin.
3. `cli/src/hook.rs` maps the event to a status (`working` / `waiting` / `idle`)
   and sends it to the app over a Unix socket (TCP + token on Windows), routing
   by the `COCKPIT_PANE_ID` env the app injects into the tab PTY.
4. An agent session outside Cockpit does not have those envs → the hook is a
   no-op. Natural gate, no configuration.

Codex CLI 0.147.0 gained a hooks system **mirrored on Claude Code's**, which
makes the extension mostly reuse.

### What was found in the binary (0.147.0)

- `codex features list` → `hooks · stable · true`. On by default, no flag.
- Events (same names as Claude, PascalCase in the config file):
  `PreToolUse`, `PermissionRequest`, `PostToolUse`, `PreCompact`, `PostCompact`,
  `SessionStart`, `SessionEnd`, `UserPromptSubmit`, `SubagentStart`,
  `SubagentStop`, `Stop`.
- Input envelope (embedded schemas, e.g. `post-tool-use.command.input`):
  `hook_event_name`, `session_id`, `transcript_path`, `cwd`, `model`,
  `permission_mode`, `tool_name`, `tool_input`, `tool_response`, `tool_use_id`,
  plus a `turn_id` that Claude does not send.
- Config in `hooks.json` (global under `~/.codex/`, project-local under
  `.codex/`), same shape `{ matcher, hooks: [{ type, command, timeout }] }`.
  Possible handlers: `command` | `prompt` | `agent` — we use `command`.
- There is `hooks.state` with `enabled` / `trusted_hash`: a **trust gate**
  over hooks. That was the plan's main unknown; Wave 0 resolved it (see
  "Wave 0 result" below).
- The legacy `notify` (`agent-turn-complete`) still exists, but only covers
  turn end. It remains plan B if the trust gate made hooks unusable.

### Event → status mapping

| Codex event | Status | Note |
|---|---|---|
| `UserPromptSubmit` | `working` | turn start |
| `PreToolUse` / `PostToolUse` | `working` | mid-turn activity |
| `PermissionRequest` | `waiting` | **better than Claude**: explicit event, no text heuristic |
| `Stop` | `idle` | turn end (chime/notification) |
| `SessionStart` / `SessionEnd` | `idle` | also binds tab → session |
| `SubagentStart` / `SubagentStop` | — | ignored in v1 (subagent must not move the tab indicator) |
| `PreCompact` / `PostCompact` | — | ignored |

The blocking `PreToolUse` special case (`AskUserQuestion` / `ExitPlanMode` →
`waiting`) **has no equivalent here**: in Codex approval has its own event.
Do not replicate the heuristic.

## Expected layout

```
cli/src/hook.rs                     # status_for gains Codex events
lib/app/cockpit/domain/contracts/
  hook_installer.dart               # generic contract (renames claude_hook_installer)
lib/app/cockpit/data/hooks/
  hook_installer_base.dart          # CLI materialization + idempotent append
  claude_hook_installer_impl.dart   # target ~/.claude/settings.json
  codex_hook_installer_impl.dart    # target ~/.codex/hooks.json
lib/app/bootstrapper.dart           # installs both on boot
```

## Waves

### Wave 0 — Spike: confirm format and trust gate

Before writing production code, prove the path by hand.

1. Write a `~/.codex/hooks.json` pointing at a script that `cat`s stdin into
   a file, registered on `UserPromptSubmit`, `PermissionRequest`, `Stop`,
   `SessionStart`, `SessionEnd`.
2. Run a short `codex exec` in a test directory.
3. Capture: real config file path, exact accepted JSON shape, raw payload of
   each event, and **whether Codex asked for a trust confirmation**
   (`trusted_hash`).

**Accept**: a commit-able example file in `docs/` with a working `hooks.json`
and a real payload for each of the 5 events. Written answer to: does the
trust gate block out-of-band install? If so, what is the flow (approve once,
precompute the hash, or env var)?

**Gate**: if the trust gate requires interaction on every file change,
reassess before later waves — possibly fall back to legacy `notify` (smaller
coverage: turn end only) and document the limitation.

#### Wave 0 result

Better than expected: **trust is precomputable**, plan B was not needed.

- File: `~/.codex/hooks.json` (only the `CODEX_HOME` root; `~/.codex/hooks/`
  is not read). Same shape as Claude, events in PascalCase.
- Without trust, the hook is ignored **silently** — no warning, no log. That
  is what made the first attempt look like "wrong format".
- Trust lives in `[hooks.state."<path>:<event_snake>:<group>:<handler>"]` in
  `config.toml`, with `trusted_hash = "sha256:…"` over the canonical JSON of
  the normalized handler identity. Because it is derived from config, not the
  binary, we compute and write it together — no user interaction.
- Extra handler fields (our `_cockpit` marker) are ignored by the parser and
  **do not** enter the hash.
- Cycle observed in a real session: `SessionStart` → `UserPromptSubmit` →
  `PreToolUse` (`tool_name: "Bash"`) → `PostToolUse` → `Stop` → `SessionEnd`.

Algorithm details and limitations in
[`turn-status-hooks.md`](turn-status-hooks.md).

### Wave 1 — CLI: `status_for` understands Codex events

`cli/src/hook.rs` is harness-agnostic: it reads `hook_event_name` and routes
via env. Changes:

1. `PermissionRequest` → `waiting`.
2. `SubagentStart` / `SubagentStop` / `PreCompact` / `PostCompact` → `None`
   (explicit, with a test, so they do not move the indicator).
3. Keep the blocking `PreToolUse` special case as-is (it is Claude's; in Codex
   `tool_name` does not match `AskUserQuestion`/`ExitPlanMode`, so it is inert).
4. Forward `turn_id` in the payload when present — the app today uses `ev`/`sid`
   to drop out-of-order `working`, and `turn_id` makes that more precise
   (optional in v1: transport only, do not consume).

**Accept**: unit tests in `hook.rs` covering the new events; `cargo test`
green. The Claude hook keeps current behavior (no existing test changes).

### Wave 2 — Generic installer

`ClaudeHookInstallerImpl` already contains everything Codex needs: CLI
materialization (`_ensureCli`, `_sameContent`, `_chmodExec`), command
resolution (`_resolveHookCommand`, `_shellQuote`, `_hookPath` with Windows
normal slashes) and the marked idempotent append (`_isOurs`).

1. Extract the common part into a base, leaving in subclasses only: config
   file path, event list, and the key where hooks live (`hooks` in both
   cases, to confirm via the spike).
2. `CodexHookInstallerImpl` writes `~/.codex/hooks.json` with events:
   `UserPromptSubmit`, `PreToolUse`, `PostToolUse`, `PermissionRequest`, `Stop`,
   `SessionStart`, `SessionEnd`.
3. Keep current guarantees: never rewrite the user's hook list, remove our
   previous entry before re-adding, tolerate a missing or unreadable file
   without crashing boot.
4. Rename the contract to `HookInstaller` (keep `ClaudeHookInstaller` as an
   alias if anything external depends on the name).

**Accept**: running the app twice in a row does not duplicate entries in
either file; pre-existing user hooks in `~/.codex/hooks.json` survive;
without `~/.codex/`, Codex install fails silently and Claude install
continues normally.

### Wave 3 — Wire on boot and E2E

1. `bootstrapper.dart` calls both installers (failure of one does not block
   the other).
2. Manual E2E, with a `.debug` build (isolated bundle id,
   `project_cockpit_debug_flavor` memory): open a tab, run `codex`, send a
   prompt that uses a tool and asks for approval, and check the tab: spinner
   on send, "needs action" badge on approval, chime/notification at turn end,
   clean indicator on exit.
3. Confirm that a `codex` session **outside** Cockpit emits nothing (env gate).

**Accept**: the four states observed in a real Codex session, and Claude with
no regression on the same build.

### Wave 4 — Documentation

1. Section in cockpit `CLAUDE.md` (or in `docs/`) describing that turn status
   covers Claude Code **and** Codex CLI, and where each config file lives.
2. CHANGELOG note in the release that ships this (English, user-facing).

## Definition of Done

- [x] Wave 0: `hooks.json` validated + real payloads captured
- [x] Wave 0: written answer on the trust gate (`trusted_hash`)
- [x] Wave 1: `status_for` covers Codex events, with tests
- [x] Wave 2: generic installer + `CodexHookInstallerImpl`, idempotent
- [x] Wave 3: install on boot
- [ ] Wave 3: E2E of the four states on an app tab **(to test)**
- [ ] Wave 3: Codex session outside Cockpit does not emit status **(to test)**
- [x] Wave 4: docs (`turn-status-hooks.md`)
- [ ] Wave 4: CHANGELOG — the section is written at `/deploy` (the guard
      rejects `## [Unreleased]` at the top, so it cannot be done here)

### What remains for the manual test

`PermissionRequest` did not appear in the captures because `codex exec` runs
with approval off. It is the event that becomes the "needs action" badge, so
it is worth checking explicitly: in a tab, with Codex in interactive mode,
ask for something that requires approval and see the tab move to `waiting`
(badge + chime).

## Out of scope

- Codex subagents moving the tab indicator (main session only).
- Using Codex `prompt` / `agent` handlers — `command` only.
- Blocking or changing agent behavior via the hook (ours is a pure observer:
  never writes to stdout, never fails loudly).
- Other harnesses (`pi`, Gemini CLI): the generic installer opens the path,
  but each one needs its own investigation.
