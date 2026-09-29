# Plan 64 — Android transactional storage and synchronization

Approved: 2026-09-29. Implementation dispatched to `app/`.

## Context

User approved redesigning and implementing storage and synchronization after confirming Android UI + Linux terminal only. This is the implementation subset of plan 63, not approval for new enrollment protocol, cryptographic identity changes, a native UI rewrite, or a Linux graphical client.

The 1.2.40 secure-storage index workaround repaired visible pairing recovery. The next design separates ordinary durable records from secrets and gives local mutations and remote snapshots explicit transactional semantics. Native enumeration failure remains unmeasured; no claim that Flutter/Hive itself caused it.

## Expected structure

- `app/lib/data/local/app_database.dart`: SQLite connection, schema, rollback-capable synchronous transactions, production and isolated test lifetimes.
- `app/lib/data/local/`: typed row stores and non-destructive Hive import.
- `app/lib/data/repositories/` and `data/sync/`: finalized history and session projection using SQLite; incremental notifications only after commit.
- `app/lib/data/preferences/`: ordinary settings in SQLite; secure/file/Hive readers only for migration.
- `app/lib/pairing/`: peers/rooms, legacy import, durable membership operation journal. Signing keys remain in the existing native identity store.
- `app/lib/data/mesh/`: verified snapshots plus durable intent, serialized network publication and conflict reconciliation.
- `app/lib/main.dart`, configuration, routing and transport: coherent bootstrap, recoverable storage errors, cached offline UI and stale connection rejection.

Use `sqlite3` with the Android native library dependency, without schema code-generation or a new state-management framework. Reject silent in-memory fallback on production storage failure. Migration must finish before dependent repositories are exposed.

## Steps with acceptance criteria

### 1. Transactional persistence and import

- Migrate peer/index/room secure-store records; Hive `rp_v2` session index, finalized messages and preferences; legacy relay URL precedence and selected room/drafts.
- Canonicalize public peer keys while preserving every persisted record field and exact provider/model identifiers.
- Commit migration marker only after validated import; preserve original data. Failed reads and interrupted import must not silently mark migration complete or return an empty inventory.
- Keep transient streaming in memory and reset online/runtime state on restart. No active dual-write or Hive emulation shim.
- Acceptance: targeted import/reopen/rollback tests; offline cold start retains devices, rooms, history and settings; no re-pairing or private-key replacement.

### 2. Explicit membership synchronization

- Atomically record enrollment/nickname/revoke intent with its local projection. Do not turn room/model metadata updates into new enrollment.
- Persist verified snapshot and revision separately from pending operations, scoped by owner and normalized relay.
- Conflict: fetch verified base, replay pending intent; never union every cached peer. ACK deletes only the captured operations. Signature, scope and revision validation precedes application.
- Serialize apply/publication. Boot, reconnect and foreground polling resume pending work. Network/read failure never becomes an empty publication; real remote revocations remain effective.
- Acceptance: restart retains pending work; enrollment survives conflict; unrelated revoked device stays revoked; nickname saved during publication survives ACK; stale response from old owner/relay cannot mutate active state.

### 3. Bootstrap and connection integration

- Initialize one database and complete migration before assembling the application graph. On failure show a retryable recovery screen, not a half-initialized Home/onboarding view.
- Display cached Home/history independent of remote availability. Identity unavailability must not erase local records.
- Invalidate callbacks from replaced connection attempts; preserve room targeting and existing terminal command behavior. Never blindly replay an uncertain destructive action.
- Acceptance: storage failure retry, disconnected boot, changed relay and overlapping connection attempts have targeted behavior regressions; all affected callers migrate.

### 4. Verification and release

- Write regression tests before production fixes. Run changed suites and static analysis after parallel edits settle; then full suite.
- Build a signed APK with existing package ID/certificate and incremented versionCode. Verify the same source revision used by tests.
- Install over 1.2.40 on the USB Samsung without clearing data. Observe saved peers and history; force-stop/relaunch; offline cached browsing and reconnect; route a harmless command through a controlled real Linux terminal session.
- Record actual observations/screenshots in `review/TESTING.md`; do not claim a locked/disconnected phone was verified. Never uninstall to bypass migration.

## Definition of Done

All steps above implemented and verified, affected callers/tests/docs updated, old runtime persistence removed, keys and user data preserved. Any external verification blocker must be explicit; unit tests alone do not establish successful phone migration.

## Next plans

Personal-workspace enrollment and any native Android framework rewrite remain separate proposals. Do not modify relay authentication or Linux runtime architecture as part of this implementation.
