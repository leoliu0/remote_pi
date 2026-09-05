# Layer `routing/`

## Purpose

Coordinates application routes, connecting paths to pages and navigation flows without leaking UI or domain logic. Houses `GoRouter`, defines guards, and ensures consistency between declared routes and actual navigation.

## Must Do

1. **Centralize paths** — maintain constants to avoid magic strings and simplify refactors.
2. **Define navigation topology** — routes, shells, and redirects live here.
3. **Delegate page construction** — each route instantiates the corresponding root widget from `ui/`.
4. **Apply guards** — authentication, identity, and onboarding checks encapsulated in redirect/route guards.
5. **Inject ViewModels into the tree** — `ViewmodelProvider` composition happens in `app_router.dart`.

## Must NOT Do

1. **Access stores or services directly** — domain logic stays in `domain/` and UI consumes via ViewModels.
2. **Create global side effects** — no background jobs or tracking initialized here; navigation only.
3. **Duplicate route declarations** — all path adjustments pass through `routing/`.

## Structure

```
routing/
├── adaptive.dart       # Responsive layout breakpoints and wide/narrow helpers
└── app_router.dart     # GoRouter configuration and route definitions
```
