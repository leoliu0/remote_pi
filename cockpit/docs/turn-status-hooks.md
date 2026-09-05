# Turn status — harness hooks

How Cockpit knows that an agent in a tab is working, finished the turn, or
needs a user action (spinner, badge, chime, OS notification).

Supported today: **Claude Code** and **Codex CLI** (0.147+).

## How it works

1. On boot, `bootstrapper.dart` runs each harness `HookInstaller`. They
   materialize the internal CLI at `~/.cockpit/bin/cockpit` and register
   `<cli> hook` on the harness config lifecycle events.
2. On each event, the harness runs `cockpit hook` with a JSON payload on stdin.
3. `cli/src/hook.rs` maps the event to a status (`working` / `waiting` / `idle`)
   and sends it to the app over a Unix socket (TCP + token on Windows).
4. Routing uses `COCKPIT_PANE_ID`, which the app injects into the tab PTY.
   An agent session opened **outside** Cockpit does not have that env, so the
   hook is a no-op. Natural gate: nothing to configure, nothing to turn off.

Why a socket and not OSC on the PTY: harnesses run hooks without a controlling
terminal, and writing to `/dev/tty` fails with `ENXIO`.

## Where each one installs

| Harness | File | Format |
|---|---|---|
| Claude Code | `~/.claude/settings.json` | `hooks.<Event>[]`, each item `{matcher, hooks:[{type, command}]}` |
| Codex CLI | `~/.codex/hooks.json` | same shape; **plus** a trust block in `~/.codex/config.toml` |

Both installers do an **idempotent append** of a marked entry (`_cockpit: v1`):
re-running removes our previous entry and re-adds it, never rewriting the list
(user, plugin, or iTerm2 hooks survive).

## Event mapping

| Event | Claude | Codex | Status |
|---|:--:|:--:|---|
| `UserPromptSubmit` | ✓ | ✓ | `working` (turn start) |
| `PreToolUse` | ✓ | ✓ | `working` — except Claude blocking tools (see below) |
| `PostToolUse` | ✓ | ✓ | `working` |
| `Notification` | ✓ | — | `waiting` / `idle` (text heuristic) |
| `PermissionRequest` | — | ✓ | `waiting` |
| `Stop` | ✓ | ✓ | `idle` |
| `SessionStart` / `SessionEnd` | ✓ | ✓ | `idle` |
| `SubagentStart` / `SubagentStop`, `PreCompact` / `PostCompact` | — | ✓ | **ignored**: not the tab's turn |

Two asymmetries that matter:

- **Claude**: tools that block waiting for the user (`AskUserQuestion`,
  `ExitPlanMode`) do not emit `Notification`. The last hook before the block is
  `PreToolUse`, so it becomes `waiting` for those two — otherwise the tab stays
  on an endless spinner, with no chime.
- **Codex**: approval has its own event (`PermissionRequest`), so there is no
  text heuristic and no `PreToolUse` special case. The Claude special case
  remains in the code and is inert here (those tools do not exist in Codex).

The envelope is almost the same in both (`hook_event_name`, `session_id`,
`transcript_path`, `cwd`, `tool_name`, `tool_input`, `permission_mode`). Codex
also sends `turn_id`, which the helper forwards as `tid`.

## Resuming the session (who owns the session-id)

The app persists the `session_id` from the hook in the layout, and on tab
restore types the command that reattaches the conversation. **The id alone does
not say which harness it belongs to**, and the commands differ:

| Harness | Resume command |
|---|---|
| Claude Code | `claude --resume <id>` |
| Codex CLI | `codex resume <id>` |

That is why the installer registers the hook command with `--harness <name>`
(`cockpit hook --harness codex`), the helper stamps the payload with `hn`, and
the layout stores `harness` next to `claude_sid`. Without the flag, the helper
assumes `claude` — what entries installed by earlier versions pass, and all of
those were Claude.

That was the first E2E bug: the app restored a Codex tab with
`claude --resume <codex id>` and Claude answered "No conversation found with
session ID".

## Codex trust gate

Codex **only runs a trusted hook**. Without trust it ignores the hook
**silently** — no warning, no log. Trust lives in `~/.codex/config.toml`:

```toml
[hooks.state."/Users/you/.codex/hooks.json:session_start:0:0"]
enabled = true
trusted_hash = "sha256:…"
```

- **Key**: `"<hooks.json path>:<event_snake>:<group index>:<handler index>"`.
- **Hash**: `sha256` (hex, prefixed `sha256:`) of the **canonical JSON** —
  sorted keys, no spaces — of the normalized handler identity:

  ```json
  {"event_name":"session_start","hooks":[{"async":false,"command":"…","timeout":600,"type":"command"}]}
  ```

  `timeout` is the **normalized** value: 600s for every event except
  `SessionEnd`, which defaults to 1s (cap 3s). Absent fields (`matcher`,
  `commandWindows`, `statusMessage`, `additionalContextLimit`) are omitted.
  Extra fields in the file — such as our `_cockpit` marker — are ignored on
  deserialization and **do not** affect the hash.

Because the hash is derived from config, not the binary, Cockpit computes and
writes trust at install time: the user does not need to approve anything by
hand. Same trust level we already assume when writing Claude's `settings.json`
— we install our helper, and only it. The block sits between delimiters
(`# >>> cockpit hooks` … `# <<< cockpit hooks`) and is regenerated on every
boot; the rest of `config.toml` is never touched.

Codex source reference: `codex-rs/hooks/src/engine/discovery.rs`
(`hook_hash`, `hook_key`) and `codex-rs/config/src/fingerprint.rs`
(`version_for_toml`).

### Known limitations

- **Group index is part of the key.** If the user adds their own hook *before*
  ours on the same event, our index shifts and trust no longer matches — the
  hook stops running, silently. The installer fixes this on the next boot,
  because it recomputes indices from the final file.
- **Hand-editing `hooks.json`** between boots has the same effect, and the same
  fix.
- If Codex changes the hash algorithm, the golden test in
  `test/data/codex_hook_installer_test.dart` breaks — those values were
  captured from a real session that ran the hooks without
  `--dangerously-bypass-hook-trust`.

## Code layout

```
cli/src/hook.rs                                   # event → status (harness-agnostic)
lib/app/cockpit/domain/contracts/hook_installer.dart
lib/app/cockpit/data/hooks/hook_installer_base.dart      # CLI + command (shared)
lib/app/cockpit/data/hooks/claude_hook_installer_impl.dart
lib/app/cockpit/data/hooks/codex_hook_installer_impl.dart
lib/app/bootstrapper.dart                         # runs both on boot, non-fatal
```
