# Layer `domain/`

## Purpose

Encapsulates pure business knowledge. Models, use cases, and validators with deterministic rules live here, **independent of UI, database, or network**. This layer is the core — other layers depend on it; it depends on none.

## Must Do

1. **Model entities and value objects** with immutability and consistent equality (`==` / `hashCode`).
2. **Orchestrate rules via Use Cases**: each `*UseCase` exposes a single domain operation and delegates integrations to contracts (`repositories/`, `services/`).
3. **Validate invariants** with typed exceptions (`ValidationException`, `DomainException`).
4. **Maintain purity**: predictable synchronous or asynchronous code, without side effects beyond contract invocations.
5. **Expose contracts**: abstract interfaces for repositories and services live here — concrete implementations live in `data/`.

## Must NOT Do

1. **Import Flutter UI** — no `BuildContext`, widgets, `Material`, or `Cupertino`. Pure Dart only.
2. **Access infrastructure directly** — databases, HTTP, and platform channels belong in `data/`.
3. **Store global mutable state** — avoid stateful singletons.
4. **Duplicate logic** — reuse existing models and validators.

## Structure

```
domain/
├── contracts/          # Low-level interfaces (clients, gateways)
├── entities/           # Objects with identity and lifecycle
├── repositories/       # Repository interfaces
├── services/           # Domain service interfaces
├── usecases/           # Unitary operations (1 verb each)
└── value_objects/      # Immutable values without identity (e.g. SemVer)
```
