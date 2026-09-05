# Layer `ui/`

## Purpose

Delivers the visual and interactive user experience, consuming ViewModels and use cases to reflect application state per feature.

## Must Do

1. **Organize by feature** — each folder represents a complete flow (page, states, viewmodels, widgets).
2. **Delegate business logic** — ViewModels call use cases and interpret results for the screen state.
3. **React via `ChangeNotifier` + `Consumer`** — keep the UI → ViewModel → UseCase → ViewModel → UI cycle clean and unidirectional.
4. **Build small widgets** — prefer `StatelessWidget`, with `widgets.dart` exporting feature components.
5. **Apply consistent visual language** — all theme styles (colors, typography) live in `core/themes/themes.dart`. Read via `context.colors.<token>` and `context.typo.<style>`.
6. **Consume ViewModels via Provider** — always via `context.watch<T>()`, `context.read<T>()`, or `context.select<T, R>()`. Never instantiate ViewModels directly in pages.
7. **Register ViewModels in `config/dependencies.dart`** using `_injector.addViewModel<T>(T.new)`.
8. **Add `ViewmodelProvider<T>()` in `routing/app_router.dart`** on the corresponding route definition.

## ViewModel — State Base Class

All ViewModels extend `ViewModel<T>`, a `ChangeNotifier` with a single immutable state field and an `emit` method. State is modeled as a sealed class in `states/`.

## Critical Rule: `BuildContext` Across Async Operations

Never access `context` after async gaps without mounting checks:

```dart
final result = await viewModel.doSomething();
if (!mounted) return;
context.useContextSomehow();
```

## Structure per Feature

```
feature/
├── states/              # sealed class modeling screen states
│   └── feature_state.dart
├── viewmodels/          # ViewModels managing state
│   └── feature_viewmodel.dart
├── widgets/             # Local feature widgets
│   ├── widgets.dart     # Barrel file
│   └── feature_widget.dart
└── feature_page.dart    # Main screen entry point
```
