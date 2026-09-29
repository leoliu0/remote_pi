import 'dart:async';
import 'dart:typed_data';

import 'package:app/config/dependencies.dart';
import 'package:app/data/local/app_database.dart';
import 'package:app/data/mesh/mesh_client.dart';
import 'package:app/data/mesh/mesh_sync_service.dart';
import 'package:app/data/preferences/preferences.dart';
import 'package:app/data/transport/connection_manager.dart';
import 'package:app/pairing/owner_identity_bridge.dart';
import 'package:app/pairing/storage.dart';
import 'package:app/routing/app_router.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_pi_identity/remote_pi_identity.dart';

const _restoredPeer = PeerRecord(
  remoteEpk: 'restored_epk',
  sessionName: 'Restored Pi',
  relayUrl: 'https://relay.example',
  pairedAt: '2026-09-29T00:00:00Z',
);

class _RouterStorage extends PairingStorage {
  _RouterStorage() : super(AppDatabase.memory());

  final List<PeerRecord> peers = [];

  @override
  Future<void> initialize({
    required Uint8List ownerPk,
    required String relayUrl,
  }) async {}

  @override
  Future<List<PeerRecord>> listPeers() async => List.of(peers);

  @override
  Future<List<PersistedRoom>> loadRooms(String epk) async => const [];
}

class _FailingStorage extends _RouterStorage {
  @override
  Future<void> initialize({
    required Uint8List ownerPk,
    required String relayUrl,
  }) async {
    throw StateError('storage reached after identity recovered');
  }
}

class _SpyConnection extends ConnectionManager {
  _SpyConnection(PairingStorage storage)
      : super(
          factory: (_, _) async => throw UnimplementedError(),
          storage: storage,
        );

  int bootCalls = 0;
  String? preferredEpk;

  @override
  Future<void> ensureCachedRoomsRestored() async {}

  @override
  Future<void> boot({String? preferredEpk}) async {
    bootCalls++;
    this.preferredEpk = preferredEpk;
  }

  @override
  Future<void> disconnect() async {}
}

class _HydratingMeshSync extends MeshSyncService {
  _HydratingMeshSync(
    OwnerIdentityBridge bridge,
    this.storage,
  ) : super(
          MeshClient(baseUrlProvider: () => 'https://relay.example'),
          bridge,
          storage,
        );

  final _RouterStorage storage;
  final synchronized = Completer<void>();

  @override
  Future<bool> synchronize() async {
    storage.peers
      ..clear()
      ..add(_restoredPeer);
    if (!synchronized.isCompleted) synchronized.complete();
    return true;
  }

  @override
  void startPolling({Duration interval = const Duration(seconds: 60)}) {}
}

class _CorruptMeshSync extends MeshSyncService {
  _CorruptMeshSync(
    OwnerIdentityBridge bridge,
    PairingStorage storage,
  ) : super(
          MeshClient(baseUrlProvider: () => 'https://relay.example'),
          bridge,
          storage,
        );

  int synchronizeCalls = 0;

  @override
  Future<bool> synchronize() async {
    synchronizeCalls++;
    lastProblem = MeshSyncProblem.corruptStoredSnapshot;
    notifyListeners();
    return false;
  }

  @override
  void startPolling({Duration interval = const Duration(seconds: 60)}) {}
}

class _RecoveringBridge extends OwnerIdentityBridge {
  _RecoveringBridge(PairingStorage storage)
      : _identity = OwnerIdentity(
          ownerPk: Uint8List(32),
          ownerSk: Uint8List(32),
        ),
        super(InMemoryOwnerIdentityStore(), storage);

  final OwnerIdentity _identity;
  int bootCalls = 0;

  @override
  Uint8List? get currentOwnerPk => bootCalls == 0 ? null : _identity.ownerPk;

  @override
  Future<OwnerIdentityBootResult> boot() async {
    bootCalls++;
    if (bootCalls == 1) return const SyncUnavailableResult();
    return IdentityReady(_identity, generated: false);
  }

  @override
  void startWatching({
    Future<void> Function()? onBeforeReset,
    required Future<void> Function() onReset,
  }) {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('boot reconnects after mesh hydration restores an empty local scope',
      () async {
    final storage = _RouterStorage();
    final connection = _SpyConnection(storage);
    final preferences = Preferences(AppDatabase.memory());
    await preferences.setOnboardingCompleted(true);
    final identity = OwnerIdentity(
      ownerPk: Uint8List(32),
      ownerSk: Uint8List(32),
    );
    final identityStore = InMemoryOwnerIdentityStore(initial: identity);
    final bridge = OwnerIdentityBridge(identityStore, storage);
    final mesh = _HydratingMeshSync(bridge, storage);

    final router = buildRouter(
      storage,
      connection,
      preferences,
      bridge,
      mesh,
    );
    await mesh.synchronized.future;
    await Future<void>.delayed(Duration.zero);

    expect(storage.peers, [_restoredPeer]);
    expect(connection.bootCalls, 1);
    expect(connection.preferredEpk, _restoredPeer.remoteEpk);

    router.dispose();
    mesh.dispose();
    bridge.dispose();
    identityStore.dispose();
    connection.dispose();
  });

  testWidgets('Check again reloads boot state after identity recovers',
      (tester) async {
    disposeDependencies();
    final storage = _FailingStorage();
    final connection = _SpyConnection(storage);
    final preferences = Preferences(AppDatabase.memory());
    final bridge = _RecoveringBridge(storage);
    final mesh = _HydratingMeshSync(bridge, storage);
    injector.addInstance<OwnerIdentityBridge>(bridge);
    injector.commit();

    final router = buildRouter(
      storage,
      connection,
      preferences,
      bridge,
      mesh,
    );
    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pump();
    await tester.pump();
    expect(find.text('Sync required'), findsOneWidget);

    await tester.tap(find.text('Check again'));
    await tester.pumpAndSettle();

    expect(bridge.bootCalls, greaterThanOrEqualTo(2));
    expect(find.byKey(const Key('storage-boot-error')), findsOneWidget);
    expect(find.text('Sync required'), findsNothing);

    router.dispose();
    mesh.dispose();
    bridge.dispose();
    connection.dispose();
    disposeDependencies();
  });

  testWidgets('corrupt membership snapshot shows recoverable sync error',
      (tester) async {
    final storage = _RouterStorage();
    final connection = _SpyConnection(storage);
    final preferences = Preferences(AppDatabase.memory());
    await preferences.setOnboardingCompleted(true);
    final identity = OwnerIdentity(
      ownerPk: Uint8List(32),
      ownerSk: Uint8List(32),
    );
    final identityStore = InMemoryOwnerIdentityStore(initial: identity);
    final bridge = OwnerIdentityBridge(identityStore, storage);
    final mesh = _CorruptMeshSync(bridge, storage);
    final router = buildRouter(
      storage,
      connection,
      preferences,
      bridge,
      mesh,
    );

    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pump();
    await tester.pump();

    expect(
      find.text("Pairing sync data couldn't be verified"),
      findsOneWidget,
    );
    expect(find.byKey(const Key('storage-boot-retry')), findsOneWidget);
    expect(mesh.synchronizeCalls, 1);

    await tester.tap(find.byKey(const Key('storage-boot-retry')));
    await tester.pump();
    await tester.pump();
    expect(mesh.synchronizeCalls, 2);
    expect(
      find.text("Pairing sync data couldn't be verified"),
      findsOneWidget,
    );

    router.dispose();
    mesh.dispose();
    bridge.dispose();
    identityStore.dispose();
    connection.dispose();
  });
}
