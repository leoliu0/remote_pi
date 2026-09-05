# Remote Pi — Relay (Rust)

WebSocket relay server that authenticates connections by `peer_id`, routes App↔Pi traffic,
authorizes and forwards Pi→Pi envelopes, and stores Owner-signed membership metadata in SQLite.

## Stack

- Rust 1.94+ (2024 edition)
- Runtime: `tokio` (full features)
- WebSocket: `tokio-tungstenite`
- Serialization: `serde` + `serde_json`
- Logging: `tracing` + `tracing-subscriber` (no `println!`)

## Commands

- `cargo build` — dev build
- `cargo build --release` — release build
- `cargo run` — run locally
- `cargo clippy -- -D warnings` — strict linting
- `cargo fmt` — formatting
- `cargo test` — tests

## Conventions

- **Errors**: `anyhow::Result<()>` in `main`, `thiserror::Error` in internal libs
- **Async**: `tokio::spawn` / `tokio::select!`, no raw `std::thread`
- **Logging**: spans with `tracing::info_span!` in handlers, `info!`/`warn!`/`error!`
- **No `unwrap()`** in production code. Use `?` and propagate errors
- **No unnecessary `clone()`** — pass references where possible

## Security and Content Policy

- In App↔Pi traffic, outer `ct` remains opaque and is never decoded.
- Pi→Pi `pi_envelope` and signed membership are parsed in memory only as needed for routing and authorization.
- No envelope bodies, key material, or signatures may be logged or persisted as message payloads.
- SQLite persistence is strictly limited to Owner-signed membership metadata; message traffic is never persisted.
