# `.cockpit/tasks.json` — Task Run

Cockpit **Task Run** runs your project's build/dev commands (`npm run dev`,
`flutter run`, `go run`, `make`…) with streamed output, a visual lifecycle
(play/stop/restart), interactive keys, and "reload on save".

Two task sources coexist:

1. **Automatic detection** — when you open a project, cockpit reads manifests
   (`package.json` scripts, `pubspec.yaml`) and already shows tasks **with no
   config**.
2. **Manual** — this file, `.cockpit/tasks.json`, in the folder you open as
   workspace. Use it to customize, add tasks, or describe a **monorepo**.
   JSON tasks take **precedence** over detected ones with the same `id`.

> The executor is **generic**: it only knows `command`/`args`/`env`. There are
> no stack keys (flavor, dart-define, NODE_ENV) — those become `args`/`env`.

> **JSONC**: the file accepts **comments** (`//` and `/* */`) and **trailing
> commas**, same as VSCode `tasks.json`. They are stripped before parse.

## Where it lives

At the **workspace root** you open in cockpit. Discovery is literal (it does
not walk up the tree), so:

- Single-package project → open the package folder; `.cockpit/tasks.json` there.
- **Monorepo** → open the root; one `.cockpit/tasks.json` at the root drives
  subpackages via per-task `cwd` (see below).

## Example

```jsonc
{
  "tasks": [
    {
      "label": "run",
      "cwd": "app",                 // relative to the tasks.json folder
      "command": "flutter",
      "args": ["run"],
      "kind": "watch",
      "interactiveKeys": [
        { "key": "r", "label": "Hot reload", "icon": "refresh", "primary": true },
        { "key": "R", "label": "Hot restart", "icon": "restart", "primary": true },
        { "key": "q", "label": "Quit", "icon": "stop" }
      ],
      "watch": {
        "paths": ["lib", "assets"],
        "ignore": ["build", ".dart_tool"],
        "onChange": "Hot reload",   // = label of an interactiveKey, or "__restart__"
        "debounceMs": 300
      },
      "progressPatterns": [
        { "begin": "Performing hot reload", "end": "Reloaded .* in .*ms" }
      ],
      "profiles": [
        { "name": "default" },
        { "name": "web", "args": ["-d", "chrome"] }
      ]
    },
    {
      "label": "api",
      "cwd": "backend",             // monorepo: another subfolder
      "command": "dart",
      "args": ["run", "bin/server.dart"],
      "kind": "watch"
    }
  ]
}
```

## Fields

### Root

| Field   | Type     | Required | Description |
|---------|----------|----------|-------------|
| `tasks` | array    | yes      | Task list (see below). |
| `cwd`   | string   | no       | **Default** `cwd` for every task (DRY sugar). Each task can override. |

### Task

| Field              | Type     | Required | Default     | Description |
|--------------------|----------|----------|-------------|-------------|
| `label`            | string   | **yes**  | —           | Short name shown in the list. |
| `command`          | string   | **yes**  | —           | Base executable (e.g. `npm`, `flutter`). |
| `args`             | string[] | no       | `[]`        | Base args, before the profile. |
| `cwd`              | string   | no       | root/top    | Working directory, **relative to the `tasks.json` folder**. Omitted → inherit top-level `cwd`, else the root. Absolute also accepted. |
| `platforms`        | string \| string[] | no | all  | OSes where the task is **visible**: `macos`, `windows`, `linux`. Omitted → all. E.g. `"platforms": "windows"` or `["windows", "linux"]`. |
| `kind`             | string   | no       | `oneShot`   | `watch` (live process, e.g. dev-server) or `oneShot` (runs and exits). |
| `interactiveKeys`  | array    | no       | `[]`        | Keys sent to stdin (see below). |
| `watch`            | object   | no       | `null`      | "Reload on save" (see below). Omit for tools that already watch (Vite/Next). |
| `progressPatterns` | array    | no       | `[]`        | Begin/end regex for the `building↔running` badge. |
| `profiles`         | array    | no       | `[]`        | Run variants (see below). |
| `preview`          | bool/str | no       | `true`      | Auto-open the embedded browser: by default the **first** local URL in output (`http://localhost:…`) opens a browser tab (re-runs reuse the tab on the same origin). `false` turns it off; a string (`"http://localhost:8080"`) opens that fixed URL at start. Without webview on the platform (Linux), opens in the OS browser. |
| `previewOpen`      | string   | no       | `always`    | **When** the preview opens: `always` (start and restart), `start` (only on start — Restart and watcher restart do not reopen; a manual stop + start does) or `never`. Ignored if `preview` is `false`. |

> Cockpit generates the task `id` automatically (`json:<label>`); it overrides
> a detected task with the same `id`.

### `interactiveKeys[]`

Each item becomes a control on the task row (or in overflow). **No
`if (flutter)` in the app** — what exists comes from here.

| Field     | Type    | Required | Description |
|-----------|---------|----------|-------------|
| `key`     | string  | **yes**  | Sequence written to the PTY (e.g. `"r"`, `"R"`, `"q"`). |
| `label`   | string  | **yes**  | Friendly label (e.g. `"Hot reload"`). |
| `icon`    | string  | no       | Icon token: `refresh`, `restart`, `stop`, `bolt`. No icon → chip with the key. |
| `primary` | boolean | no (`false`) | `true` = pinned button on the row; `false` = secondary button. |

### `watch`

`flutter run` **does not** reload on save — that is an IDE plugin feature;
cockpit reimplements it via file watching. It stays **always on** while the
task with `watch` is alive.

| Field        | Type     | Required | Default | Description |
|--------------|----------|----------|---------|-------------|
| `paths`      | string[] | no       | `[]`    | Folders/files to watch (relative to `cwd`). Empty = everything. |
| `ignore`     | string[] | no       | `[]`    | Patterns to ignore (e.g. `build`, `.dart_tool`). Avoids loops. |
| `onChange`   | string   | **yes**  | —       | Action on change: the `label` of an `interactiveKey` (e.g. `"Hot reload"`) **or** `"__restart__"` (kill+relaunch). |
| `debounceMs` | number   | no       | `300`   | Debounce window (one save emits several events). |

### `progressPatterns[]`

Detect recompilation in output so the badge oscillates `building↔running`.

| Field   | Type   | Required | Description |
|---------|--------|----------|-------------|
| `begin` | string | **yes**  | Regex for "started recompiling". |
| `end`   | string | **yes**  | Regex for "back to idle". |

### `profiles[]`

Named run variants ("launch configs"). In the UI, a chip cycles profiles
before play; the subtitle shows the final command. Generic — Flutter flavor
and dart-define go in as `args`.

| Field  | Type               | Required | Description |
|--------|--------------------|----------|-------------|
| `name` | string             | **yes**  | Display name (e.g. `dev`, `prod`, `web`). Use unique names. |
| `args` | string[]           | no       | Args concatenated **after** the task `args`. |
| `env`  | object<string,str> | no       | Variables merged into the process environment. |

## Editor validation (JSON Schema)

There is a JSON Schema in [`docs/tasks.schema.json`](./tasks.schema.json). For
autocomplete/validation in the editor, reference it at the top of the file:

```jsonc
{ "$schema": "../cockpit/docs/tasks.schema.json", "tasks": [ ... ] }
```

(Cockpit ignores `$schema` at runtime — it is only for the editor.)

## Known limitations

- For arg values with spaces, use **separate items** in `args`
  (e.g. `["--dart-define", "MSG=hello world"]`).
- The output tab does not survive an app restart (the task dies with it).
