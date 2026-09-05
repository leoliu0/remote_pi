# Remote Pi — App (Flutter)

Mobile client (iOS + Android) for Remote Pi. QR code pairing, Pi session listing,
streaming chat, and approval cards for tool calls.

## Stack

- Flutter 3.41+ / Dart 3.11+
- Platforms: iOS, Android
- State management: `ChangeNotifier` + `provider` (reactive ViewModels)
- DI: `auto_injector` (registry in `lib/config/`)
- Routing: `go_router`
- Typed results: `Result<T, E>` (explicit success/failure)
- Cryptography: libsodium / Ed25519 bindings
- WebSocket: `web_socket_channel` / `IOWebSocketChannel`

## Commands

- `flutter pub get` — install dependencies
- `flutter analyze` — static lint analysis (zero issues)
- `flutter test` — unit & widget tests
- `flutter run` — launch on connected device / simulator
- `dart format .` — format codebase
- `flutter build apk --release` — release APK build

## Layer Architecture

`lib/` is organized into strict architectural layers:

```
lib/
├── main.dart
├── config/          # Bootstrap, DI, environment, global setup  → config/CLAUDE.md
│   └── utils/       # Shared utility helpers
├── domain/          # Entities, use cases, validators          → domain/CLAUDE.md
├── data/            # Repositories, adapters, APIs              → data/CLAUDE.md
├── routing/         # GoRouter, paths, navigation guards       → routing/CLAUDE.md
└── ui/              # Pages + ViewModels per feature           → ui/CLAUDE.md
    └── <feature>/
        ├── states/
        ├── viewmodels/
        ├── widgets/
        └── <feature>_page.dart
```

Dependency flow rule:

```
ui ──► domain ◄── data
        ▲
        │
     config (injects everything)
     routing (composes routes + ViewModels)
```

- `domain/` does NOT import from `data/`, `ui/`, `routing/`, `config/`.
- `data/` imports contracts from `domain/`, never from `ui/`.
- `ui/` consumes `domain/` via ViewModels — never calls `data/` directly.
- `config/` wires all bindings across layers.

## Conventions

- **Naming**: `snake_case.dart` files, `PascalCase` classes/widgets
- **Imports**: relative within the same feature; absolute `package:app/...` across features/layers
- **Async**: prefer typed `Future`/`Stream`
- **Errors**: typed results or exceptions; never generic unhandled catches in production
- **ViewModels**: registered in `config/` and injected via Provider; pages access via `context.watch/read/select`

## Critical Rule: `BuildContext` Across Async Gaps

Always guard `context` access after `await`:

```dart
final result = await viewModel.doSomething();
if (!mounted) return;
context.useContextSomehow();
```
