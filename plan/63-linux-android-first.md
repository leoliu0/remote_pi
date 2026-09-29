# Plan 63 — Linux/Android-first Remote Pi

Status: **Storage and synchronization redesign approved for implementation on 2026-09-29.** Android UI + Linux terminal only. Framework replacement, new enrollment protocol, and platform identity redesign remain proposals; see plan 64 for the implementation boundary.
Date: 2026-09-29

## Context

The user wants to consider rewriting this fork for Linux and Android, with a plan first. The daily workflow is Android controlling agents on Linux through the user's own relay. The earlier request for automatic discovery without repeatedly pairing individual PCs is part of this proposal.

**Recommendation: rebuild the Android client data/connection core in stages, retain Flutter initially for existing UI reuse, and retain the existing Rust relay and TypeScript Pi/OMP integration.** No Linux graphical client. Do not rewrite the relay, agent runtime, and mobile UI simultaneously.

Confirmed scope (2026-09-29): the user uses **only the terminal on Linux**. Android is the only client UI in this proposal; Linux runs the existing interactive Pi/OMP terminal integration. Headless/systemd operation remains optional, not a prerequisite. Cockpit and Linux desktop UI are out of scope.

### Evidence and limits

- `review/TESTING.md`, 2026-09-29: Pi acknowledged pairing, then Android showed no pairings after Save. The patched 1.2.40 build recovered six sessions and retained them after force-stop/relaunch. The exact native cause of bulk secure-storage enumeration failure was **not measured**; this does not establish that Flutter caused the defect.
- `app/lib/pairing/storage.dart`: peer metadata currently lives in secure storage, with an added index, in-memory cache, and unresolved-key bookkeeping. These are ordinary database records, not private keys.
- `app/lib/data/mesh/mesh_sync_service.dart`: local writes, network publication, conflict handling, and remote membership replacement need explicit ownership and conflict semantics.
- `app/lib/routing/app_router.dart`: boot coordinates preferences, identity, mesh fetches, peer loading, and connection start. A UI boot should not require every remote dependency to respond.
- `app/pubspec.yaml`: existing Flutter client uses Hive, secure storage, a custom identity plugin, and Provider/ViewModel conventions. Retain usable views, renderers, and tests rather than rebuilding them without evidence.
- `app/packages/remote_pi_identity/pubspec.yaml`: identity plugin declares Android and iOS. No Linux Flutter identity backend or runner is needed for the confirmed terminal-only Linux scope.
- `pi-extension/README.md` and `pi-extension/docs/daemon.md`: systemd user-service support already exists. Extend and verify it; do not introduce a competing host daemon.
- Phone configuration is `http://178.157.59.181:3000`; both port 80 and 3000 served the same mesh snapshot during diagnosis. Keep one explicit configured endpoint. No automatic fallback to the community relay.

### Existing decisions being retained or proposed for revision

Read `plan/00-decisions.md` before implementation. This proposal does not modify that decision ledger.

| Existing decision | Proposal |
|---|---|
| Flutter and existing Provider/ViewModel pattern | Retain; no simultaneous state-management framework migration. |
| Pair once, persist identity, authenticate connections | Retain; simplify owner/workspace enrollment instead of removing authorization. |
| Cockpit terminal-first integration | Retain; no new dependence on `pi --mode rpc` as Cockpit's engine. |
| Plan 31 row-level local state, Hive retained pending evidence | Retain row-level writer/read-repository split. Propose SQLite for transactional metadata and cross-table invariants; approve only after migration/failure prototype. Hive itself is not established as faulty. |
| Cloud-synced owner identity | Propose local identity as mandatory capability, cloud synchronization as optional recovery. Requires explicit approval and key-format compatibility proof. |
| iOS/macOS/Windows support | Not acceptance targets for this fork's rewrite. Do not delete their existing implementations without a separate scope decision. |

## Technology choice

| Option | Benefit | Cost / decision |
|---|---|---|
| **Flutter + rebuilt core + small Kotlin platform adapter** | Reuses existing Android screens, renderers, and protocol work | **Lowest-migration-risk recommendation.** Shared desktop UI is no longer a reason to choose Flutter. |
| Kotlin/Jetpack Compose Android + existing Linux terminal integration | Native Android UI/lifecycle; no cross-platform UI requirement | Viable full-rewrite alternative. Requires migrating every renderer and interaction; choose explicitly before implementation, not as an assumed fix for storage bugs. |
| Compose Multiplatform or Tauri | Cross-platform UI | Not selected: Linux has no graphical client requirement; additional desktop/runtime work provides no benefit to this scope. |

The framework gate is a runnable Android slice connected to a real Linux terminal session. Compare native Kotlin/Compose against retaining Flutter using the same persistence, lifecycle, rendering, and feature-parity criteria. Retaining Flutter minimizes migration; native Kotlin aligns with an Android-only rewrite. The user has confirmed platform scope, not selected a new framework.

## Target behavior

1. Open app: show saved PCs/sessions immediately, even offline. Clearly distinguish empty, unreadable local data, disconnected relay, and connected-but-no-live-sessions.
2. Enroll into the personal workspace once; subsequently discover all **authorized** PCs and their sessions automatically. No per-session QR, no repeated pairing after process death or updates.
3. Stop/restart/reconnect operations do not erase peers or history. Session restart resumes the same conversation; New session remains a separate action.
4. Android resumes cleanly after backgrounding, Doze, network changes, and process death. No claim of an immortal background WebSocket.
5. Linux remains terminal-first: Android messages, steering, cancellation, and session restart affect the same interactive Pi/OMP session. No desktop app or daemon is required; preserve optional existing systemd operation.
6. Model selection preserves exact provider/model identity, including the distinction between OpenAI API and Codex subscription routes.

## Architecture

### Durable state

Proposed SQLite database, accessed through typed repositories (evaluate Drift in the prototype):

- `relay_profiles`: explicit endpoint, workspace identifier, selected profile.
- `devices`: canonical public-key identity, label, enrollment status, timestamps.
- `sessions`: device + room identity, labels, durable last-seen metadata.
- `messages`: stable protocol ID scoped to session, durable order, finalized content.
- `pending_membership_changes`: intentional enroll/rename/revoke operations and base revision.
- `sync_state`: verified membership version and supported replay cursors.
- `schema_metadata`: migration version and completion marker.

These are proposed logical tables, not a demand for a new persistence framework per feature. Use database transactions for peer/session/index updates. One repository writer owns persistence. UI reads repository snapshots/streams, never the credential store directly. Keep transient token streaming in memory and commit finalized messages; do not rewrite full history on each token.

**Secrets separate from metadata:** credential storage holds only key material/credential references. Preserve the current Ed25519 public identity and wire signatures. On Android, use an Android Keystore-backed wrapping key for the existing serialized signing secret unless compatible non-exportable Ed25519 support is proven on the target range. On Linux, support Secret Service; headless protected-file storage must be explicit (0700 directory, 0600 file), never a silent new identity when a keyring is unavailable. Never require Google backup or iCloud availability to list local sessions.

Database files are app-private and may contain sensitive chat content; they are not E2E protection. Document backup/exclusion and deletion behavior. No private key/token in normal database rows, logs, or screenshots.

### Connection and synchronization

A single connection coordinator owns sockets and cancellation:

`offline -> connecting -> authenticating -> synchronizing -> online`

Failures transition to a visible retryable error or explicit authorization error. A new connection attempt invalidates older callbacks. Changing relay/identity cancels the old attempt. Bound operation waits without converting failures to an empty peer inventory. Show cached data while connecting.

Membership rules:

- Local pending operations remain separate from the last verified server snapshot.
- Conflict: fetch a verified revision, reapply explicit pending operations, then publish. **Do not union every cached peer back into membership**: that can resurrect a remotely revoked device.
- Serialize writes/publications. Acknowledgment clears only operations included in that publication, not a later nickname save.
- A stale/out-of-order response cannot overwrite a newer revision or a different owner's state.
- Failed reads/network timeouts never mean “delete all devices.” Genuine signed revocations still take effect.

Delivery rules:

- Use existing stable message IDs and protocol support; deduplicate echoes/replays by session and ID.
- Do not promise exactly-once remote execution without host-side deduplication.
- Never automatically resend an unacknowledged destructive command after reconnect. Show uncertain status and require an explicit retry where the existing protocol cannot resolve it.

### Personal-relay enrollment and automatic discovery

No community-relay dependency. The server profile is user-configured once and visible in Settings.

The requested convenience is **no repeated QR pairing**, not necessarily anonymous access. Recommended flow: an owner-authorized Linux CLI provisions a client using a short-lived, single-use invite (paste/link or USB-assisted provisioning). Additional PCs enroll into the same workspace once; subsequent session discovery is automatic. Device credentials are independently revocable. Invitations and roster membership must prove authorization, not merely possession of an arbitrary self-generated public key.

This is a protocol/design change, not a client-only toggle. Before implementation, specify how current owner-signed mesh membership and Pi endpoint pairing checks recognize each enrolled device; retain legacy pairing only during the bounded migration window. Do not distribute the same owner private key to every new device as a shortcut.

The current HTTP endpoint offers no transport confidentiality and differs from the TLS requirement in `plan/00-decisions.md`. Preserve that requirement for the rewrite: HTTPS/WSS on the personal relay before provisioning credentials over a public network. A VPN-only transport alternative requires an explicit decision; it must not silently weaken the recorded policy. A public IP used by one person is still reachable by other people. Unauthenticated “any connection controls everything” is **not included** in this proposal; an isolated-network mode would require a separate explicit decision.

### Platform behavior

**Android:** native adapter only for key wrapping, lifecycle/network signals, and required OS integrations. Foreground reconnect is mandatory. Default background behavior accepts socket suspension and resyncs on return; persistent background monitoring/foreground service is a separate opt-in with notification and battery testing, not a hidden default. Camera denied, Google services unavailable, and owner-key temporarily locked must have usable explicit states.

**Linux host:** reuse existing systemd user supervisor and CLI. Verify start, status, logs, stop, intentional restart, crash recovery, PATH changes, and user logout. Linger is opt-in. Never mint a replacement machine identity because the graphical keyring is absent in the service environment.


## Expected structure

Preserve the monorepo. Proposed new paths below do not exist yet:

```text
app/
  lib/data/local/             transactional store, schema, migrations
  lib/data/repositories/      device/session/message readers and command boundary
  lib/data/transport/         connection lifecycle and wire adapter
  lib/data/mesh/              verified snapshots + pending membership operations
  lib/pairing/                enrollment orchestration, not metadata database
  lib/ui/                     retain working Android screens
  packages/remote_pi_identity/ Android identity implementation
pi-extension/                reuse host integration, CLI, systemd supervision
relay/                       reuse routing; authorized enrollment additions if approved
cockpit/                     unchanged IDE/terminal product
```

Extract a shared Dart package only if a second actual consumer needs it. No generic plugin architecture, extra daemon, or universal event bus for this rewrite.

## Steps with acceptance criteria

### 0. Freeze the scope and capture the baseline

- Platform scope confirmed: Android UI + Linux terminal only. Approve the framework/storage/enrollment changes separately.
- Inventory all current user-visible functions: history, streaming, tool/diff/math rendering, image/voice input, steer/queue/edit/cancel, ask-user forms, goal/loop/plan controls, model/thinking, compact/new/restart/quit, multiple rooms, labels, update installation.
- Record cold-start, cached Home render, foreground reconnect, long-history scrolling, and Android battery behavior on the user's phone and one Linux machine.
- **Acceptance:** explicit parity checklist and measurements; no existing feature silently dropped. Known regressions become failing tests before production changes.

### 1. Prove the platform and persistence slice

- Build one real Android session-list slice connected to an existing interactive Linux Pi/OMP session.
- Prototype transactional peer storage, secure key loading, and legacy import without changing relay protocol.
- Inject process kill during import/save; simulate unavailable keyring and partial storage reads.
- **Acceptance:** saved devices remain after cold start; failure is not displayed as an empty list; identical signing identity survives import; missing Google services is not a startup blocker. SQLite/framework choice approved only after these results.

### 2. Replace durable storage with a transactional cutover

- Migrate secure-storage peer/index records, Hive session/history data, and relay preferences into the new store. Normalize peer-key representation once at the boundary.
- Import idempotently into a new database; validate counts, identities, room IDs, timestamps, nicknames, selected room, and history before marking migration complete.
- Keep old data untouched until successful cutover. New runtime writes only the new store; no indefinite dual-write or stacked fallback chains.
- **Acceptance:** fixtures from 1.2.38 and 1.2.40 upgrade without clearing app data or re-pairing; interrupted migration resumes; read failure preserves source records; unknown/corrupt records surface a recovery state rather than disappearing.

### 3. Replace connection/sync ownership

- Introduce one coordinator and explicit pending membership operations; adapt existing repositories/ViewModels rather than rebuilding all UI.
- Exercise reconnect, stale responses, concurrent save/revoke, relay switching, owner-key availability, and multi-room routing.
- **Acceptance:** no cross-room delivery, duplicate sends, revived revoked devices, or lost nickname changes; offline data remains browsable. Target cached Home within 1 second and foreground reconnect within 5 seconds on a healthy network, measured separately from server outage time.

### 4. Implement approved personal-workspace enrollment

- Coordinate `relay/`, `pi-extension/`, and `app/` against a written authorization and versioning contract.
- Ship owner-approved one-time provisioning; discover authorized PCs/sessions automatically thereafter.
- Upgrade relay/host before depending on new client capabilities; reject unsupported combinations explicitly.
- **Acceptance:** provision a phone and two Linux hosts, restart all three, discover sessions without new QR scans; expired/reused invites and unrelated clients fail; device revocation actually prevents commands at the receiving host.

### 5. Finish Android and Linux ergonomics

- Android: process-death recovery, Wi-Fi/mobile transitions, background/resume, permissions, keyboard/IME, large text, share/file input.
- Linux terminal: preserve interactive input, draft restoration, steering, cancellation, and `/restart` semantics. Verify optional systemd operation only where affected; do not make it the default interaction model.
- Preserve the full step-0 feature checklist.
- **Acceptance:** real Samsung phone screenshots plus observed Linux terminal behavior: send from phone, see the intended terminal session execute, cancel a running turn, and restart into the same conversation. No Linux desktop build or Cockpit work.

### 6. Release, verify, and retire replaced paths

- Android: retain package ID and signing certificate; strictly increasing versionCode; install over current app without uninstalling. Linux: reproducible native build instructions plus agreed distribution artifact; no Docker requirement for local development.
- Require tests and static analysis before publication; document pinned Flutter/Dart/JDK/Android SDK/native Linux dependencies.
- Capture screenshots and dated rows in `review/TESTING.md` for upgrade, Home, chat, offline, restart, and reconnect.
- **Acceptance:** no data loss, no new pairing on ordinary upgrade, release artifacts tied to tested commit and verified signatures/checksums. Downgrade is not an assumed rollback: preserve a backup and prove restore with compatible binaries before promising it.
- Remove obsolete runtime paths after cutover; keep only required versioned import readers for supported upgrades. No second active implementation or permanent compatibility shims.

## Definition of Done

- Approved platform scope and every baseline feature delivered or explicitly excluded by the user.
- Client boot/listing is independent of relay reachability and bulk credential enumeration.
- Durable metadata transactions and secret handling have separate responsibilities.
- Existing identities, devices, rooms, and history survive in-place upgrade and process death.
- Automatic discovery works for authorized workspace devices; revoked/unknown devices cannot control agents.
- Android foreground/background behavior is documented and observed; commands reach the correct live Linux terminal session without requiring a GUI or daemon.
- Real-device regression evidence and build artifacts are recorded; tests alone are not completion.

## Next plans

After approval, split into executable plans for (1) Android framework choice and local database/identity migration, (2) connection and membership state machine, and (3) personal-workspace enrollment contract with Linux terminal verification. Record approved changes in `plan/00-decisions.md` with this proposal and measured evidence as references. Dispatch implementation to each target subproject; root remains planning/orchestration only.
