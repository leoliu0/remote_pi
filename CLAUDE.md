# Remote Pi — Orchestrator

You are at the **root** of the Remote Pi monorepo. This directory is exclusively for **planning and orchestration**.

## What to do here

- Read and write `plan/NN-<slug>.md` (e.g. `plan/03-protocol.md`)
- Discuss architecture, product decisions, and trade-offs
- Refine existing plans based on feedback
- Direct which subproject receives the next implementation

## What NOT to do here

- Do not edit subproject code directly from the root
- Do not run subproject build/test commands from the root without specifying subproject cwd
- When implementing features, dispatch to the target subproject pane/directory

## Structure

See [README.md](./README.md) for an overview and [plan/](./plan/) for architecture plans.

## Verification & Testing Protocol (mandatory)

1. **Regression test first:** For any bug fix, write the targeted failing
   unit test *first* that reproduces the exact defect. A fix without a
   regression test is incomplete.
2. **Real surface verification:** No change is "done" from tests alone. Every
   user-facing change must be exercised on its real surface and screenshot:
   - **Mobile (`app/`)** — install on `RemotePi_Pixel` emulator or live device,
     drive the real flow with `adb input`, screenshot every step.
   - **Web (`site/`)** — drive the page in the browser tool, screenshot,
     visually confirm.
   - **Desktop (`cockpit/`)** — `flutter test` + release build at minimum.
3. **Evidence & ledger:** Evidence lives in `review/screens/` (PNG) + dated
   rows in `review/TESTING.md`.

## Established Decisions

Before proposing a change of direction (architecture, pairing, scope, UI, security),
read [`plan/00-decisions.md`](./plan/00-decisions.md). That file records finalized decisions
from exploratory discussions and **should not be revisited without strong evidence**.

## Plan Conventions

- Sequential numbering: `01-bootstrap.md`, `02-ai-orchestration.md`, ...
- Each plan contains: Context, Expected structure, Steps with acceptance criteria, Definition of Done, Next plans
- Plans describe **what** + **how to verify**, not full source dumps
- Pseudocode or exact command invocations are welcome; actual implementation stays in the target subproject

## When to Promote a Plan to Implementation

When the plan has user approval and steps are concrete enough for an agent to execute,
dispatch to the target subproject with the plan as context.

## Subprojects

- `app/` — Flutter mobile client (iOS + Android)
- `pi-extension/` — Node/TypeScript daemon running on paired PCs
- `relay/` — Rust WebSocket relay and presence router
- `site/` — Next.js documentation and download site
- `cockpit/` — Flutter desktop app (macOS / Windows / Linux)
- `rp-s3/` — S3-compatible asset and update server (Rust)

## Workspace Panes

| Pane (title) | Subproject (cwd) |
|---|---|
| `App` | `app/` |
| `Relay` | `relay/` |
| `Extension` | `pi-extension/` |
| `Site` | `site/` |
| `Cockpit` | `cockpit/` |
| `Orchestrator` | monorepo root |

### Cockpit Dispatch

```bash
# By pane label or tab-id
scripts/cockpit-dispatch.sh Extension 03-ts-codec "Implement step 3 of plan/03-protocol.md"
scripts/cockpit-dispatch.sh --wait Extension 25-wave-x "..."
```

### cmux Dispatch (Legacy fallback)

```bash
scripts/cmux-dispatch.sh Extension 03-ts-codec "Implement step 3 of plan/03-protocol.md"
scripts/cmux-dispatch.sh --wait Extension 25-wave-x "..."
```
