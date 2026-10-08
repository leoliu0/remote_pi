import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:app/data/local/app_database.dart';
import 'package:app/data/mesh/mesh_client.dart';
import 'package:app/data/mesh/mesh_sync_service.dart';
import 'package:app/data/preferences/preferences.dart';
import 'package:app/data/transport/connection_manager.dart';
import 'package:app/data/transport/peer_channel.dart';
import 'package:app/data/transport/relay_config.dart';
import 'package:app/pairing/owner_identity_bridge.dart';
import 'package:app/pairing/pair_request_flow.dart';
import 'package:app/pairing/storage.dart';
import 'package:app/ui/settings/states/settings_state.dart';
import 'package:app/ui/settings/viewmodels/settings_viewmodel.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_pi_identity/remote_pi_identity.dart';

class _NoopTransport implements PeerTransport {
  @override Future<void> send(Uint8List data) async {}
  @override Future<Uint8List> receive() => Completer<Uint8List>().future;
  @override Future<void> close() async {}
}

PlainPeerChannel _channel() => PlainPeerChannel(transport: _NoopTransport());

ConnectionManager _conn({_FakeStorage? storage}) {
  return ConnectionManager(
    factory: (_, _) async => _channel(),
    storage: storage ?? _FakeStorage([]),
  );
}

class _FakeStorage extends PairingStorage {
  List<PeerRecord> peers;
  _FakeStorage(this.peers) : super(AppDatabase.memory());

  @override
  Future<List<PeerRecord>> listPeers() async => List.of(peers);

  @override
  Future<void> savePeer(
    PeerRecord r, {
    required PeerSaveIntent intent,
  }) async {
    peers = [r, ...peers.where((p) => p.remoteEpk != r.remoteEpk)];
  }

  @override
  Future<void> deletePeer(String epk) async {
    peers = peers.where((p) => p.remoteEpk != epk).toList();
  }

  @override
  Future<List<PersistedRoom>> loadRooms(String epk) async => const [];

  @override
  Future<void> saveRooms(String epk, List<PersistedRoom> rooms) async {}

}

class _RelayStorage extends _FakeStorage {
  _RelayStorage(super.peers);

  @override
  Future<void> initialize({
    required Uint8List ownerPk,
    required String relayUrl,
  }) async {}
}

class _RelayConnection extends ConnectionManager {
  _RelayConnection(this.storage)
      : super(
          factory: (_, _) async => throw UnimplementedError(),
          storage: storage,
        );

  final _RelayStorage storage;
  final List<int> peerCountsAtReconnect = [];

  @override
  Future<void> reconnect({String? preferredEpk}) async {
    peerCountsAtReconnect.add(storage.peers.length);
  }
}

class _RelayMeshSync extends MeshSyncService {
  _RelayMeshSync(
    OwnerIdentityBridge bridge,
    this.storage,
  ) : super(
          MeshClient(baseUrlProvider: () => 'https://custom.example'),
          bridge,
          storage,
        );

  final _RelayStorage storage;
  final synchronized = Completer<void>();

  @override
  Future<bool> synchronize() async {
    storage.peers = [_peerA()];
    if (!synchronized.isCompleted) synchronized.complete();
    return true;
  }
}

Preferences _preferences() => Preferences(AppDatabase.memory());

PeerRecord _peerA() => const PeerRecord(
  remoteEpk: 'epk_A',
  sessionName: 'Pi A',
  relayUrl: 'ws://localhost',
  pairedAt: '2026-01-01T00:00:00Z',
);

void main() {
  group('SettingsViewModel', () {
    test('initial state is SettingsLoading', () {
      final storage = _FakeStorage([_peerA()]);
      final prefs = _preferences();
      final vm = SettingsViewModel(storage, prefs, _conn(storage: storage));
      expect(vm.state, isA<SettingsLoading>());
      vm.dispose();
    });

    test('empty storage → SettingsNoPeer', () async {
      final storage = _FakeStorage([]);
      final prefs = _preferences();
      final vm = SettingsViewModel(storage, prefs, _conn(storage: storage));
      await Future<void>.delayed(Duration.zero);
      expect(vm.state, isA<SettingsNoPeer>());
      vm.dispose();
    });

    test('peers loaded → SettingsList', () async {
      final storage = _FakeStorage([_peerA()]);
      final prefs = _preferences();
      final vm = SettingsViewModel(storage, prefs, _conn(storage: storage));
      await Future<void>.delayed(Duration.zero);

      final s = vm.state as SettingsList;
      expect(s.peers.single.remoteEpk, 'epk_A');

      vm.dispose();
    });

    test('revoke deletes peer + clears selectedPeerEpk if it matched',
        () async {
      final storage = _FakeStorage([_peerA()]);
      final prefs = _preferences();
      await prefs.setSelectedPeerEpk('epk_A');

      final vm = SettingsViewModel(storage, prefs, _conn(storage: storage));
      await Future<void>.delayed(Duration.zero);

      await vm.revoke('epk_A');
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(storage.peers, isEmpty);
      expect(prefs.selectedPeerEpk, isNull);
      expect(vm.state, isA<SettingsNoPeer>());

      vm.dispose();
    });

    test('revoke does NOT touch selectedPeerEpk if different', () async {
      final storage = _FakeStorage([_peerA()]);
      final prefs = _preferences();
      await prefs.setSelectedPeerEpk('epk_other');

      final vm = SettingsViewModel(storage, prefs, _conn(storage: storage));
      await Future<void>.delayed(Duration.zero);

      await vm.revoke('epk_A');
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(prefs.selectedPeerEpk, 'epk_other');

      vm.dispose();
    });

    test('setNickname updates state and storage', () async {
      final storage = _FakeStorage([_peerA()]);
      final prefs = _preferences();
      final vm = SettingsViewModel(storage, prefs, _conn(storage: storage));
      await Future<void>.delayed(Duration.zero);

      await vm.setNickname('epk_A', 'Casa');
      await Future<void>.delayed(const Duration(milliseconds: 20));

      final s = vm.state as SettingsList;
      expect(s.peers.single.nickname, 'Casa');
      expect(storage.peers.single.nickname, 'Casa');

      vm.dispose();
    });

    test('setNickname with null clears the nickname', () async {
      final storage = _FakeStorage([
        _peerA().copyWith(nickname: 'Casa'),
      ]);
      final prefs = _preferences();
      final vm = SettingsViewModel(storage, prefs, _conn(storage: storage));
      await Future<void>.delayed(Duration.zero);

      await vm.setNickname('epk_A', null);
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect((vm.state as SettingsList).peers.single.nickname, isNull);
      expect(storage.peers.single.nickname, isNull);

      vm.dispose();
    });

    test('setNickname with whitespace clears the nickname', () async {
      final storage = _FakeStorage([
        _peerA().copyWith(nickname: 'Casa'),
      ]);
      final prefs = _preferences();
      final vm = SettingsViewModel(storage, prefs, _conn(storage: storage));
      await Future<void>.delayed(Duration.zero);

      await vm.setNickname('epk_A', '   ');
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect((vm.state as SettingsList).peers.single.nickname, isNull);

      vm.dispose();
    });

    test('setNickname is a no-op for unknown epk', () async {
      final storage = _FakeStorage([_peerA()]);
      final prefs = _preferences();
      final vm = SettingsViewModel(storage, prefs, _conn(storage: storage));
      await Future<void>.delayed(Duration.zero);

      await vm.setNickname('epk_does_not_exist', 'Casa');
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(storage.peers.single.nickname, isNull);

      vm.dispose();
    });
  });

  group('SettingsViewModel — plan 14 relay config', () {
    test('saveRelayUrl with valid URL persists override + returns null',
        () async {
      final prefs = _preferences();
      final vm = SettingsViewModel(_FakeStorage([]), prefs, _conn());
      await Future<void>.delayed(Duration.zero);

      final err = await vm.saveRelayUrl('https://custom.example');
      expect(err, isNull);
      expect(prefs.relayUrl, 'https://custom.example');
      expect(vm.effectiveRelayUrl, 'https://custom.example');

      vm.dispose();
    });

    test(
      'saveRelayUrl with invalid URL returns error and does NOT persist',
      () async {
        final prefs = _preferences();
        final vm = SettingsViewModel(_FakeStorage([]), prefs, _conn());
        await Future<void>.delayed(Duration.zero);

        final err = await vm.saveRelayUrl('ftp://not-a-url');
        expect(err, isNotNull);
        expect(prefs.relayUrl, isNull);

        vm.dispose();
      },
    );

    test(
      'saveRelayUrl normalizes ws(s):// to http(s):// before persisting',
      () async {
        final prefs = _preferences();
        final vm = SettingsViewModel(_FakeStorage([]), prefs, _conn());
        await Future<void>.delayed(Duration.zero);

        final wssErr = await vm.saveRelayUrl('wss://relay.example');
        expect(wssErr, isNull);
        expect(prefs.relayUrl, 'https://relay.example');

        final wsErr = await vm.saveRelayUrl('ws://localhost:8787');
        expect(wsErr, isNull);
        expect(prefs.relayUrl, 'http://localhost:8787');

        vm.dispose();
      },
    );

    test(
      'saveRelayUrl auto-prefixes http:// when the scheme is missing',
      () async {
        final prefs = _preferences();
        final vm = SettingsViewModel(_FakeStorage([]), prefs, _conn());
        await Future<void>.delayed(Duration.zero);

        final err = await vm.saveRelayUrl('192.168.1.10:8787/');
        expect(err, isNull);
        expect(prefs.relayUrl, 'http://192.168.1.10:8787');

        vm.dispose();
      },
    );

    test(
      'saveRelayUrl with empty / blank / null resets to the default '
      'relay and clears the existing override',
      () async {
        final prefs = _preferences();
        await prefs.setRelayUrl('https://x.example');
        final vm = SettingsViewModel(_FakeStorage([]), prefs, _conn());
        await Future<void>.delayed(Duration.zero);

        // Empty → override cleared, back on the default endpoint.
        final emptyErr = await vm.saveRelayUrl('');
        expect(emptyErr, isNull);
        expect(prefs.relayUrl, isNull);
        expect(vm.effectiveRelayUrl, kDefaultRelayUrl);

        await prefs.setRelayUrl('https://x.example');

        // Whitespace-only → same (trimmed to empty).
        final blankErr = await vm.saveRelayUrl('   ');
        expect(blankErr, isNull);
        expect(prefs.relayUrl, isNull);

        await prefs.setRelayUrl('https://x.example');

        // null → same.
        final nullErr = await vm.saveRelayUrl(null);
        expect(nullErr, isNull);
        expect(prefs.relayUrl, isNull);

        vm.dispose();
      },
    );

    test(
      'relayUrlOverride defaults to kDefaultRelayUrl (pre-fill for the '
      '"use default" button) and reflects a saved override',
      () async {
        final prefs = _preferences();
        final vm = SettingsViewModel(_FakeStorage([]), prefs, _conn());
        await Future<void>.delayed(Duration.zero);

        // No override yet → the field pre-fills with the default endpoint.
        expect(vm.relayUrlOverride, kDefaultRelayUrl);
        expect(vm.effectiveRelayUrl, kDefaultRelayUrl);

        // Saving the default URL explicitly is valid (what the button does).
        final err = await vm.saveRelayUrl(kDefaultRelayUrl);
        expect(err, isNull);
        expect(vm.relayUrlOverride, kDefaultRelayUrl);
        expect(prefs.relayUrl, kDefaultRelayUrl);

        vm.dispose();
      },
    );

    test('saveRelayUrl reconnects so the new relay is used immediately',
        () async {
      final storage = _FakeStorage([_peerA()]);
      final conn = _conn(storage: storage);
      final prefs = _preferences();
      await prefs.setSelectedPeerEpk('epk_A');
      final vm = SettingsViewModel(storage, prefs, conn);
      await Future<void>.delayed(Duration.zero);

      final err = await vm.saveRelayUrl(
        'https://custom.example',
        alwaysReconnect: true,
      );
      expect(err, isNull);
      expect(prefs.relayUrl, 'https://custom.example');
      // Reconnect runs in the background (Save must not block on the WS
      // dial) — let the fake connect land, then assert it left NoPeer.
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(conn.status, isNot(isA<StatusNoPeer>()));

      vm.dispose();
      conn.dispose();
    });

    test('relay change reconnects after mesh hydration restores peers',
        () async {
      final storage = _RelayStorage([]);
      final prefs = _preferences();
      final identityStore = InMemoryOwnerIdentityStore();
      final bridge = OwnerIdentityBridge(identityStore, storage);
      await bridge.boot();
      final mesh = _RelayMeshSync(bridge, storage);
      final conn = _RelayConnection(storage);
      final vm = SettingsViewModel(storage, prefs, conn, mesh, bridge);

      final error = await vm.saveRelayUrl(
        'https://custom.example',
        alwaysReconnect: true,
      );
      expect(error, isNull);
      await mesh.synchronized.future;
      await Future<void>.delayed(Duration.zero);

      expect(storage.peers, [_peerA()]);
      expect(conn.peerCountsAtReconnect, isNotEmpty);
      expect(conn.peerCountsAtReconnect.last, 1);

      vm.dispose();
      mesh.dispose();
      bridge.dispose();
      identityStore.dispose();
      conn.dispose();
    });
  });

  group('SettingsViewModel — web sign-in link', () {
    test('is null without a booted Owner identity', () {
      final storage = _FakeStorage([]);
      final vm = SettingsViewModel(storage, _preferences(), _conn());
      expect(vm.webSignInLink, isNull);
      vm.dispose();
    });

    test('carries the Owner seed and the current relay URL', () async {
      final storage = _FakeStorage([]);
      final prefs = _preferences();
      await prefs.setRelayUrl('https://custom.example');
      final identityStore = InMemoryOwnerIdentityStore();
      final bridge = OwnerIdentityBridge(identityStore, storage);
      await bridge.boot();
      final vm = SettingsViewModel(storage, prefs, _conn(), null, bridge);

      final link = vm.webSignInLink!;
      final params = Uri.splitQueryString(Uri.parse(link).fragment);
      expect(link, contains('/web#k='));
      expect(
        base64Url.decode('${params['k']}='),
        bridge.currentIdentity!.ownerSk,
      );
      expect(params['r'], 'https://custom.example');

      vm.dispose();
      bridge.dispose();
      identityStore.dispose();
    });
  });
}
