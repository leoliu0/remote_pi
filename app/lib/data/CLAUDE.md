# Layer `data/`

## Purpose

Translates `domain/` contracts into calls to external integrations (network, database, platform), applying caches, mappers, and specialized repositories. This layer forms the boundary between pure business rules and I/O.

## Must Do

1. **Implement domain contracts**: each interface declared in `domain/repositories/` or `domain/services/` has its concrete implementation here.
2. **Translate DTOs**: adapters/mappers convert transport models (JSON, database rows) into domain entities and vice versa.
3. **Orchestrate multiple data sources**: combine local cache, remote API, storage, exposing a clean API to use cases.
4. **Propagate contextualized errors**: catch technical exceptions from integrations and convert them into understandable domain errors.
5. **Keep contracts explicit**: interfaces live in `domain/`, implementations live here (never the reverse).

## Must NOT Do

1. **Implement business rules** — domain decisions (validations, calculations, policies) remain in `domain/`.
2. **Consume UI** — zero imports of `ui/`, `widgets`, or `BuildContext`.
3. **Access dependency injector directly** outside setup — instances are injected via `config/dependencies.dart`.
4. **Duplicate infrastructure logic** — HTTP, WebSocket, and storage clients stay encapsulated in `data/services/`.

## Structure

```
data/
├── local/            # Local storage (boxes, disk cache)
├── mesh/             # Mesh sync clients and models
├── preferences/      # App preferences persistence
├── repositories/     # Domain repository implementations
├── sync/             # Real-time state synchronization
└── transport/        # WebSocket / channel transports
```
