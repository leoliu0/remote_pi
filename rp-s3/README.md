# rp-s3 — Remote Pi Downloads Server

Minimal HTTP server (Rust + axum) serving Cockpit installers and release manifests from a mounted volume directory.

## Routes

| Route | Behavior |
|---|---|
| `GET /healthz` | `200 ok` |
| `GET /downloads/<product>/...` | files from `DATA_DIR/<product>/...` |
| `PUT /upload/<product>/<file>` | writes manifest to volume (Bearer auth) |

### Manifest Upload

Only enabled when `UPLOAD_TOKEN` is set. Accepts `latest.json`, `SHA256SUMS`, and `*.xml` (Sparkle appcasts). Atomic writes (tmp + rename).

## Configuration

| Env | Default | Description |
|---|---|---|
| `DATA_DIR` | `/data` | Root directory served at `/downloads` |
| `PORT` | `8080` | HTTP port |
| `UPLOAD_TOKEN` | — | Enables `PUT /upload`; missing = endpoint disabled |
| `RUST_LOG` | `rp_s3=info,tower_http=info` | Log level |

## Running

```bash
# Local development
DATA_DIR=./data PORT=8080 cargo run

# Production via docker compose
docker compose pull && docker compose up -d
curl -fsS http://localhost:8080/healthz
```
