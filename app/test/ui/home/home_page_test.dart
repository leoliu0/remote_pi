import 'dart:async';
import 'dart:typed_data';

import 'package:app/data/preferences/preferences.dart';
import 'package:app/data/transport/channel.dart';
import 'package:app/data/transport/connection_manager.dart';
import 'package:app/data/transport/peer_channel.dart';
import 'package:app/domain/contracts/dismissed_update_store.dart';
import 'package:app/domain/contracts/update_checker.dart';
import 'package:app/domain/contracts/url_opener.dart';
import 'package:app/domain/entities/update_info.dart';
import 'package:app/pairing/pair_request_flow.dart';
import 'package:app/pairing/storage.dart';
import 'package:app/protocol/protocol.dart';
import 'package:app/routing/adaptive.dart';
import 'package:app/ui/home/home_page.dart';
import 'package:app/ui/home/viewmodels/home_viewmodel.dart';
import 'package:app/ui/update/viewmodels/update_banner_viewmodel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

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

  final Map<String, List<PersistedRoom>> _rooms = {};
  @override
  Future<void> saveRooms(String epk, List<PersistedRoom> rooms) async {
    _rooms[epk] = rooms;
  }

  @override
  Future<List<PersistedRoom>> loadRooms(String epk) async =>
      _rooms[epk] ?? const [];

  @override
  Future<void> deleteRooms(String epk) async {
    _rooms.remove(epk);
  }
}

class _GateStorage extends _FakeStorage {
  _GateStorage(super.peers);
  final Completer<void> gate = Completer<void>();

  @override
  Future<List<PeerRecord>> listPeers() async {
    await gate.future;
    return super.listPeers();
  }
}

class _FakeSecureStorage implements FlutterSecureStorage {
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class _NoopTransport implements PeerTransport {
  @override
  Future<void> send(Uint8List data) async {}
  @override
  Future<Uint8List> receive() => Completer<Uint8List>().future;
  @override
  Future<void> close() async {}
}
class _ControllableChannel implements IChannel, IControlLink {
  final _serverCtrl = StreamController<ServerMessage>.broadcast();
  final _controlCtrl = StreamController<ControlInbound>.broadcast();

  @override
  Stream<ServerMessage> get serverMessages => _serverCtrl.stream;
  @override
  Stream<ControlInbound> get controlFrames => _controlCtrl.stream;
  @override
  Future<void> send(ClientMessage msg) async {}
  @override
  void sendControl(Map<String, dynamic> json) {}
  @override
  Future<void> close() async {
    await _serverCtrl.close();
    await _controlCtrl.close();
  }

  void pushControl(ControlInbound m) => _controlCtrl.add(m);
}

class _NoChecker implements UpdateChecker {
  @override
  Future<UpdateInfo?> fetchLatest() async => null;
}

class _NoDismissed implements DismissedUpdateStore {
  @override
  Future<String?> dismissedVersion() async => null;
  @override
  Future<void> dismiss(String version) async {}
}

class _NoOpener implements UrlOpener {
  @override
  Future<bool> open(String url) async => true;
}

const _peerA = PeerRecord(
  remoteEpk: 'epk_A',
  sessionName: 'Pi A',
  relayUrl: 'ws://localhost',
  pairedAt: '2026-01-01T00:00:00Z',
);

Widget _home({
  required HomeViewModel vm,
  required UpdateBannerViewModel banner,
}) {
  return MultiProvider(
    providers: [
      ChangeNotifierProvider<HomeViewModel>.value(value: vm),
      ChangeNotifierProvider<ShellLayout>.value(value: ShellLayout()),
      ChangeNotifierProvider<SessionSelection>.value(value: SessionSelection()),
      ChangeNotifierProvider<UpdateBannerViewModel>.value(value: banner),
    ],
    child: const MaterialApp(home: HomePage()),
  );
}

UpdateBannerViewModel _banner() => UpdateBannerViewModel(
  _NoChecker(),
  _NoDismissed(),
  _NoOpener(),
  currentVersion: '1.0.0',
  enabled: false,
);

void main() {
  testWidgets('HomeLoading never shows "No sessions online"', (tester) async {
    final storage = _GateStorage([_peerA]);
    final conn = ConnectionManager(
      factory: (_, _) async => PlainPeerChannel(transport: _NoopTransport()),
      storage: storage,
      emitDebounce: Duration.zero,
    );
    final vm = HomeViewModel(storage, Preferences(_FakeSecureStorage()), conn);
    final banner = _banner();

    await tester.pumpWidget(_home(vm: vm, banner: banner));

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.text('No sessions online'), findsNothing);
    expect(find.text('Nothing here…'), findsNothing);

    storage.gate.complete();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 20));

    vm.dispose();
    banner.dispose();
    conn.dispose();
  });

  testWidgets(
    'Online tab with only cached rooms shows "No sessions online"',
    (tester) async {
      final ch = _ControllableChannel();
      final storage = _FakeStorage([_peerA]);
      final conn = ConnectionManager(
        factory: (_, _) async => ch,
        storage: storage,
        emitDebounce: Duration.zero,
      );
      final vm = HomeViewModel(storage, Preferences(_FakeSecureStorage()), conn);
      final banner = _banner();
      await conn.connectTo(_peerA);
      await tester.pump(const Duration(milliseconds: 10));

      ch.pushControl(
        const RoomAnnounced(peer: 'epk_A', roomId: 'r1', startedAt: 1),
      );
      ch.pushControl(const RoomEnded(peer: 'epk_A', roomId: 'r1', sinceTs: 2));
      await tester.pump(const Duration(milliseconds: 10));

      await tester.pumpWidget(_home(vm: vm, banner: banner));
      await tester.pump();

      expect(find.text('No sessions online'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);

      vm.dispose();
      banner.dispose();
      await conn.disconnect();
      conn.dispose();
    },
  );

  testWidgets(
    'dropping the relay does not flash "No sessions online"',
    (tester) async {
      final ch = _ControllableChannel();
      final storage = _FakeStorage([_peerA]);
      final conn = ConnectionManager(
        factory: (_, _) async => ch,
        storage: storage,
        emitDebounce: Duration.zero,
      );
      final vm = HomeViewModel(storage, Preferences(_FakeSecureStorage()), conn);
      final banner = _banner();
      await conn.connectTo(_peerA);
      await tester.pump(const Duration(milliseconds: 10));

      ch.pushControl(
        const RoomAnnounced(peer: 'epk_A', roomId: 'r1', startedAt: 1),
      );
      await tester.pump(const Duration(milliseconds: 10));
      await conn.disconnect();
      await tester.pump(const Duration(milliseconds: 10));

      await tester.pumpWidget(_home(vm: vm, banner: banner));
      await tester.pump();

      expect(find.text('No sessions online'), findsNothing);
      expect(find.text('Pi A'), findsWidgets);

      vm.dispose();
      banner.dispose();
      conn.dispose();
    },
  );
}
