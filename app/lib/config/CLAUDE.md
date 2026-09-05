# Layer `config/`

## Purpose

Owns all application orchestration decisions: bootstrapping, dependency configuration (`auto_injector`), environments, keys, and global integrations. This layer knows all others — it is the only layer with this permission.

## Must Do

1. **Declare bindings**: all shared dependencies originate here via `injector.add...`. Repositories, services, ViewModels all pass through the registry.
2. **Use constructor references**: prefer `MyClass.new` so `AutoInjector` resolves parameters automatically.
3. **Isolate setup**: SDK initializations, logging, routes, and global themes live in clearly-named functions (`setupDependencies`, `disposeDependencies`).
4. **Rely on contracts**: use interfaces exposed by `domain/`, `data/` (services), and `ui/` (ViewModels) — do not embed business logic here.

## Must NOT Do

1. **Encode domain rules** — no business logic, calculations, or validations.
2. **Create manual singletons** — always use `AutoInjector` for lifecycle control.
3. **Import widgets or pages** — remain independent of UI (except type declarations for ViewModel registration).
4. **Execute direct network requests** — configure clients, but do not consume domain services directly.

## Structure

```
config/
├── dependencies.dart    # setupDependencies / disposeDependencies / ViewmodelProvider
└── utils/
    └── injector.dart    # CustomInjector — typed facade over auto_injector
```
