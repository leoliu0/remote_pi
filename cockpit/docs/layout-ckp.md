# `*.ckp` — Pane orchestration layouts

A `.ckp` file is versionable YAML that describes which terminals to open in a
Cockpit workspace — the equivalent of a tmuxinator layout. One file = one
layout; the layout name is the file name (`dev.ckp` → layout "dev").

Three ways to apply:

1. **GUI** — right-click the `.ckp` file in the tree → **Open layout**.
2. **Internal CLI** — `cockpit orchestrate dev.ckp` (from inside a tab).
3. **Worktree autorun** — `autorun: worktree` in the file: creating a worktree
   of the workspace applies the layout automatically (the worktree starts empty,
   so geometry lands exactly).

## Example

```yaml
# dev.ckp — at the project root (any folder works; cwd is relative to it)
autorun: worktree        # optional
panes:
  - name: Frontend       # required, unique — becomes the tab's stable label
    cwd: frontend        # relative to this file, ALWAYS with "/"
    command: claude      # optional: typed into the shell after open
  - name: Backend
    cwd: backend
    split: right         # tab (default) | right (side by side) | down (stack)
    command: npm run dev
  - name: Sign
    cwd: .
    command: ./sign.sh
    platforms: [macos]   # optional: macos | windows | linux (string or list)
```

## Fields

### Root

| Field     | Type   | Required | Description |
|-----------|--------|----------|-------------|
| `panes`   | array  | **yes**  | Panes, in creation order. |
| `autorun` | string | no       | Only `worktree`: apply when creating a workspace worktree. With **2+** autorun files at the root, none run (ambiguity is never guessed). |

### `panes[]`

| Field       | Type               | Required | Default | Description |
|-------------|--------------------|----------|---------|-------------|
| `name`      | string             | **yes**  | —       | Unique (case-insensitive). Becomes the tab's manual label and is the merge key. |
| `cwd`       | string             | no       | `.`     | **Relative to the file's folder**, `/` only. Absolutes and `\` are rejected (macOS/Linux/Windows portability). |
| `split`     | string             | no       | `tab`   | Where it opens, relative to the **previously created pane**: `tab` (tab in the same pane), `right`, `down`. |
| `command`   | string             | no       | —       | Command typed into the terminal (run by the tab's shell; resolved via the machine PATH). |
| `platforms` | string \| string[] | no       | all     | `macos`/`windows`/`linux` — same semantics as `platforms` in tasks.json. |

## Application semantics (idempotent merge)

- A pane whose `name` already exists as a tab label/title in the workspace is
  **skipped** — applying the layout twice is a no-op. Nothing is ever closed.
- `split` anchors on the pane **created earlier in this run**; if the previous
  one was skipped by merge, the next opens as a normal tab (perfect geometry
  only in an empty workspace — the worktree/autorun case).
- Missing `cwd` or invalid YAML → readable error (dialog in GUI, stderr in
  CLI); nothing is applied past the pane that failed.
- `command` is typed ~700ms after the tab opens (time for the shell to finish
  booting) with Enter at the end.

## Editor

Cockpit treats `.ckp` as YAML (highlight) and shows the Cockpit logo as the
file icon in the tree.
