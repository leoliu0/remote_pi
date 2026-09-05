# Remote Pi — Cockpit (Flutter Desktop)

Desktop client (macOS, Windows, Linux) for Remote Pi. Multi-pane GUI over the Pi engine: projects on the left, agent terminals in the center, file tree on the right.

## Stack

- Flutter desktop / Dart
- Platforms: macOS, Windows, Linux
- DI, routing, state: `flutter_modular` (v7)
- UI state: `context.watch/read/select`, `Consumer`/`Selector`
- Typed results: `Result<T, E>`
- i18n: `slang` (en, pt-BR, es)
- Terminal engines: `libghostty` (Ghostty) + `plugins/cockpit_pty/` (native PTY)
- Markdown: `gpt_markdown`
- Syntax highlighting: `highlight`

## Commands

- `flutter pub get` — install dependencies
- `flutter analyze` — static lint analysis
- `flutter test` — unit and widget tests
- `flutter run -d macos` (or windows / linux) — launch desktop app
- `dart format .` — format codebase
- `flutter build macos` — production build

## Architecture — Vertical Feature Slices

All application code lives in `lib/app/`. Each feature is self-contained with its own `domain/`, `data/`, and `ui/` directories and a `<feature>_module.dart`. Shared kernel code lives in `app/core/`.

## Conventions

- **Naming**: `snake_case.dart` files, `PascalCase` classes/widgets
- **Imports**: relative within feature; `package:cockpit/...` across modules
- **Scroll**: `ClampingScrollPhysics` application-wide
- **ViewModels**: page-scoped `ChangeNotifier` bound in module route providers
- **i18n**: all user-facing strings must use `context.t` translations
