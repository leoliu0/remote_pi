# remote_pi_identity

Owner-key Ed25519 identity synced across devices of the same human via
platform-native key sync — **iCloud Keychain** on iOS, **Block Store**
on Android.

Internal plugin for the Remote Pi monorepo. Not published to pub.dev.

## Scope

This plugin owns exactly one job: persist a single Owner Ed25519
keypair (64 bytes — `ownerPk || ownerSk`) into the synced key-storage
surface of the current platform, and expose changes back to Dart
through a Stream.

It does **not** generate the keypair, do any crypto, talk to the
relay, or know what a paired peer is. The blob is opaque bytes —
encoding and decoding live in [`OwnerIdentity.toBlob` /
`fromBlob`](lib/src/owner_identity.dart) and the format is fixed at 64
bytes.

### Out of scope

The following responsibilities belong to higher layers (the app + the
Pi extension + the relay), not to this plugin:

- **Paired-peer list.** Which Pis the human has paired with — including
  `remote_epk`, relay URL, room id, nickname — lives in the app's local
  storage (and eventually in a separate synced surface if mesh state
  ever needs to roam between devices).
- **Mesh versioning.** Whatever protocol decides "this device has a
  newer view of the peer list" is the mesh layer's problem, not this
  plugin's.
- **Revocation propagation.** Wiping the owner identity here only wipes
  the local synced surface for that account; telling the relay to drop
  presence, telling other devices to forget the key, telling paired Pis
  to revoke — all that is orchestrated outside this plugin.

The 64-byte blob has no version field on purpose — there is nothing to
migrate. If a different schema ever becomes necessary, that's a new
plugin (or a new method-channel surface), not an upgrade path here.

## Platform requirements

| Platform | Min version | Sync surface | What you need on the device |
|---|---|---|---|
| iOS | **26.0** | iCloud Keychain (`kSecAttrSynchronizable=true`) | Signed into iCloud + iCloud Keychain enabled |
| Android | **API 34** (Android 14) | Block Store (`setShouldBackupToCloud(true)`) | Google account + Google Backup on + lock screen set |

On iOS the plugin uses a generic-password Keychain item; on Android it
uses Google Play Services Block Store
(`play-services-auth-blockstore:16.4.0`). Neither side touches a
hardware-backed key — the blob is opaque bytes so it can travel
through the iCloud / Google Backup pipelines.

## Quick start

```dart
import 'package:remote_pi_identity/remote_pi_identity.dart';

final store = MethodChannelOwnerIdentityStore();

if (!await store.isSyncAvailable()) {
  // Show platform-specific config instructions (e.g. "turn on iCloud
  // Keychain" / "turn on Google Backup"). Do NOT generate a local-only
  // identity as fallback — that creates silent divergence with sync.
  return;
}

final existing = await store.load();
if (existing == null) {
  // First run: generate a keypair with your crypto library of choice
  // (the example uses package:cryptography) and persist it.
  await store.save(OwnerIdentity(ownerPk: pk, ownerSk: sk));
}

// React to sync arrivals (iOS) or restore-to-new-device (Android).
store.watch().listen((identity) {
  // Update your in-memory caches.
});
```

See [`example/lib/main.dart`](example/lib/main.dart) for a full demo
covering generate / load / watch / delete / `isSyncAvailable`.

## API

The package surface lives in
[`lib/remote_pi_identity.dart`](lib/remote_pi_identity.dart):

```dart
class OwnerIdentity {
  final Uint8List ownerPk;    // 32 bytes
  final Uint8List ownerSk;    // 32 bytes
  Uint8List toBlob();         // 64 bytes: pk || sk
  static OwnerIdentity fromBlob(Uint8List blob);  // throws if length != 64
}

abstract class OwnerIdentityStore {
  Future<OwnerIdentity?> load();
  Future<void> save(OwnerIdentity identity);
  Stream<OwnerIdentity> watch();
  Future<void> delete();
  Future<bool> isSyncAvailable();
}
```

Concrete implementations:

- `MethodChannelOwnerIdentityStore` — production, talks to iOS/Android.
- `InMemoryOwnerIdentityStore` — for tests and fakes.

Errors come back as a sealed `IdentityStoreError`:

- `SyncUnavailable(reason)` — iCloud Keychain / Google Backup is off.
  The recommended UX is to block first-run with a platform-specific
  instruction (see plan/23 § "Behavior without sync available").
- `PlatformFailure(code, message)` — anything else from the native
  side. Treat as fatal.

## Known limitations

- **Android has no live sync.** Block Store only propagates on
  restore-to-new-device — it has no "value changed" callback. If you
  need iPhone + iPad-style simultaneous live sync, use iOS for now;
  Android live sync is tracked in `plan/26-android-live-sync.md`.
- **No cross-ecosystem sync.** iOS devices sync among themselves;
  Android devices sync among themselves. There is no path between the
  two. An export-to-mnemonic plan (`plan/24-key-recovery-export.md`)
  may eventually bridge this.
- **No revoke per device.** Revoking the owner key wipes the local
  synced surface for the human. Per-device granularity is tracked in
  `plan/25-per-device-identity.md`.

## Layout

```
remote_pi_identity/
├── lib/
│   ├── remote_pi_identity.dart    # public barrel
│   └── src/
│       ├── owner_identity.dart    # 64-byte OwnerIdentity (pk||sk)
│       ├── owner_identity_store.dart  # abstract interface + errors
│       ├── method_channel_store.dart  # production impl (iOS/Android)
│       └── in_memory_store.dart       # test / fake impl
├── ios/Classes/
│   ├── RemotePiIdentityPlugin.swift
│   └── KeychainSyncStore.swift
├── android/src/main/kotlin/dev/remotepi/identity/
│   ├── RemotePiIdentityPlugin.kt
│   └── BlockStoreStore.kt
├── example/                       # demo app
└── test/                          # serialization + in-memory tests
```

## Channels (for native debugging)

- Method channel: `remote_pi_identity`
- Event channel:  `remote_pi_identity/events`

The Dart side passes the serialized 64-byte blob as `Uint8List`; the
native side stores/retrieves bytes without inspecting them.

## See also

- `plan/23-owner-key-sync.md` — full design rationale and roadmap.
- `plan/00-decisions.md` — fixed monorepo-wide decisions.
