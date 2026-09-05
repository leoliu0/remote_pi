import 'dart:async';
import 'dart:typed_data';

import 'package:app/data/preferences/preferences.dart';
import 'package:app/data/transport/connection_manager.dart';
import 'package:app/data/transport/peer_channel.dart';
import 'package:app/data/transport/relay_config.dart';
import 'package:app/pairing/pair_request_flow.dart';
import 'package:app/pairing/storage.dart';
import 'package:app/ui/settings/states/settings_state.dart';
import 'package:app/ui/settings/viewmodels/settings_viewmodel.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

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
  _FakeStorage(this.peers);

  @override
  Future<List<PeerRecord>> listPeers() async => List.of(peers);

  @override
  Future<void> savePeer(PeerRecord r) async {
    peers = [r, ...peers.where((p) => p.remoteEpk != r.remoteEpk)];
  }

  @override
  Future<void> deletePeer(String epk) async {
    peers = peers.where((p) => p.remoteEpk != epk).toList();
  }

  @override
  Future<void> deletePeerSilent(String epk) async {
    peers = peers.where((p) => p.remoteEpk != epk).toList();
  }
}

class _FakeSecureStorage implements FlutterSecureStorage {
  final Map<String, String> _store = {};
  @override
  Future<String?> read({
    required String key,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async => _store[key];
  @override
  Future<void> write({
    required String key,
    required String? value,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    if (value == null) {
      _store.remove(key);
    } else {
      _store[key] = value;
    }
  }
  @override
  Future<void> delete({
    required String key,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async => _store.remove(key);
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

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
      final prefs = Preferences(_FakeSecureStorage());
      final vm = SettingsViewModel(storage, prefs, _conn(storage: storage));
      expect(vm.state, isA<SettingsLoading>());
      vm.dispose();
    });

    test('empty storage → SettingsNoPeer', () async {
      final storage = _FakeStorage([]);
      final prefs = Preferences(_FakeSecureStorage());
      final vm = SettingsViewModel(storage, prefs, _conn(storage: storage));
      await Future<void>.delayed(Duration.zero);
      expect(vm.state, isA<SettingsNoPeer>());
      vm.dispose();
    });

    test('peers loaded → SettingsList', () async {
      final storage = _FakeStorage([_peerA()]);
      final prefs = Preferences(_FakeSecureStorage());
      final vm = SettingsViewModel(storage, prefs, _conn(storage: storage));
      await Future<void>.delayed(Duration.zero);

      final s = vm.state as SettingsList;
      expect(s.peers.single.remoteEpk, 'epk_A');

      vm.dispose();
    });

    test('revoke deletes peer + clears selectedPeerEpk if it matched',
        () async {
      final storage = _FakeStorage([_peerA()]);
      final prefs = Preferences(_FakeSecureStorage());
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
      final prefs = Preferences(_FakeSecureStorage());
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
      final prefs = Preferences(_FakeSecureStorage());
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
      final prefs = Preferences(_FakeSecureStorage());
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
      final prefs = Preferences(_FakeSecureStorage());
      final vm = SettingsViewModel(storage, prefs, _conn(storage: storage));
      await Future<void>.delayed(Duration.zero);

      await vm.setNickname('epk_A', '   ');
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect((vm.state as SettingsList).peers.single.nickname, isNull);

      vm.dispose();
    });

    test('setNickname is a no-op for unknown epk', () async {
      final storage = _FakeStorage([_peerA()]);
      final prefs = Preferences(_FakeSecureStorage());
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
      final prefs = Preferences(_FakeSecureStorage());
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
        final prefs = Preferences(_FakeSecureStorage());
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
        final prefs = Preferences(_FakeSecureStorage());
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
        final prefs = Preferences(_FakeSecureStorage());
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
        final prefs = Preferences(_FakeSecureStorage());
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
        final prefs = Preferences(_FakeSecureStorage());
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
      final prefs = Preferences(_FakeSecureStorage());
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
  });
}
