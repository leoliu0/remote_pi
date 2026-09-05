// Plan/32 — ConnectionManager propagates `meta.working` from
// `room_announced` / `room_meta_updated` / `rooms` into RoomInfo.working and
// exposes it via `isRoomWorking`, so Home can show the blue "working" dot for
// EVERY subscribed room (not just the single connected one).

import 'dart:async';
import 'dart:typed_data';

import 'package:app/data/transport/channel.dart';
import 'package:app/data/transport/connection_manager.dart';
import 'package:app/pairing/storage.dart';
import 'package:app/protocol/protocol.dart';
import 'package:flutter_test/flutter_test.dart';

PeerRecord _fakePeer() => const PeerRecord(
      remoteEpk: 'epk_test',
      sessionName: 'pi',
      relayUrl: 'ws://localhost',
      pairedAt: '2026-01-01T00:00:00Z',
    );

class _FakeStorage extends PairingStorage {
  final List<PeerRecord> peers;
  _FakeStorage(this.peers);

  @override
  Future<List<PeerRecord>> listPeers() async => peers;

  @override
  Future<void> savePeer(PeerRecord r) async {}

  @override
  Future<void> saveRooms(String epk, List<PersistedRoom> rooms) async {}

  @override
  Future<List<PersistedRoom>> loadRooms(String epk) async => const [];

  @override
  Future<void> deleteRooms(String epk) async {}
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

  // Avoid analyzer "unused" on the import.
  // ignore: unused_element
  Uint8List _placeholder() => Uint8List(0);
}

Future<ConnectionManager> _connected(_ControllableChannel ch) async {
  final cm = ConnectionManager(
    factory: (_, _) async => ch,
    storage: _FakeStorage([_fakePeer()]),
    emitDebounce: Duration.zero,
    workingOffDebounce: Duration.zero,
  );
  await cm.connectTo(_fakePeer());
  await Future<void>.delayed(const Duration(milliseconds: 10));
  return cm;
}

void main() {
  group('ConnectionManager — Plan/32 working propagation', () {
    test('RoomAnnounced with working seeds RoomInfo.working + isRoomWorking',
        () async {
      final ch = _ControllableChannel();
      final cm = await _connected(ch);

      ch.pushControl(const RoomAnnounced(
        peer: 'epk_test',
        roomId: 'r1',
        startedAt: 1,
        working: true,
      ));
      await Future<void>.delayed(const Duration(milliseconds: 5));

      expect(cm.roomsFor('epk_test').single.working, isTrue);
      expect(cm.isRoomWorking('epk_test', 'r1'), isTrue);

      cm.dispose();
    });

    test('room_meta_updated flips working on then off', () async {
      final ch = _ControllableChannel();
      final cm = await _connected(ch);

      ch.pushControl(const RoomAnnounced(
        peer: 'epk_test',
        roomId: 'r1',
        startedAt: 1,
        model: 'claude-opus-4-8',
      ));
      await Future<void>.delayed(const Duration(milliseconds: 5));
      expect(cm.isRoomWorking('epk_test', 'r1'), isFalse);

      // turn_start → working=true
      ch.pushControl(const RoomMetaUpdated(
        peer: 'epk_test',
        roomId: 'r1',
        working: true,
        hasModel: false,
        hasThinking: false,
      ));
      await Future<void>.delayed(const Duration(milliseconds: 5));
      expect(cm.isRoomWorking('epk_test', 'r1'), isTrue);
      expect(cm.roomsFor('epk_test').single.model, 'claude-opus-4-8',
          reason: 'working-only update must NOT clobber model');

      // turn_end → working=false
      ch.pushControl(const RoomMetaUpdated(
        peer: 'epk_test',
        roomId: 'r1',
        working: false,
        hasModel: false,
        hasThinking: false,
      ));
      await Future<void>.delayed(const Duration(milliseconds: 5));
      expect(cm.isRoomWorking('epk_test', 'r1'), isFalse);

      cm.dispose();
    });

    test('model-only update preserves a previously-set working=true',
        () async {
      final ch = _ControllableChannel();
      final cm = await _connected(ch);

      ch.pushControl(const RoomAnnounced(
        peer: 'epk_test',
        roomId: 'r1',
        startedAt: 1,
        working: true,
      ));
      await Future<void>.delayed(const Duration(milliseconds: 5));

      // A model swap mid-turn: meta carries model only, working absent.
      ch.pushControl(const RoomMetaUpdated(
        peer: 'epk_test',
        roomId: 'r1',
        model: 'gpt-4o',
        hasModel: true,
        hasThinking: false,
      ));
      await Future<void>.delayed(const Duration(milliseconds: 5));

      expect(cm.isRoomWorking('epk_test', 'r1'), isTrue,
          reason: 'absent working in a meta update must not clear it');
      expect(cm.roomsFor('epk_test').single.model, 'gpt-4o');

      cm.dispose();
    });

    test('rooms snapshot carries working per room', () async {
      final ch = _ControllableChannel();
      final cm = await _connected(ch);

      ch.pushControl(const RoomsSnapshot(
        peer: 'epk_test',
        rooms: [
          RoomInfo(roomId: 'r1', startedAt: 1, working: true),
          RoomInfo(roomId: 'r2', startedAt: 1, working: false),
        ],
      ));
      await Future<void>.delayed(const Duration(milliseconds: 5));

      expect(cm.isRoomWorking('epk_test', 'r1'), isTrue);
      expect(cm.isRoomWorking('epk_test', 'r2'), isFalse);

      cm.dispose();
    });

    test('isRoomWorking is false when the WS is offline', () async {
      final ch = _ControllableChannel();
      final cm = await _connected(ch);

      ch.pushControl(const RoomAnnounced(
        peer: 'epk_test',
        roomId: 'r1',
        startedAt: 1,
        working: true,
      ));
      await Future<void>.delayed(const Duration(milliseconds: 5));
      expect(cm.isRoomWorking('epk_test', 'r1'), isTrue);

      // Dropping the connection → no fresh signal → report not-working.
      await cm.disconnect();
      expect(cm.isRoomWorking('epk_test', 'r1'), isFalse);

      cm.dispose();
    });

    test(
        'rapid working false/true updates within debounce window keep room working state continuously true without flapping',
        () async {
      final ch = _ControllableChannel();
      final cm = ConnectionManager(
        factory: (_, _) async => ch,
        storage: _FakeStorage([_fakePeer()]),
        emitDebounce: Duration.zero,
        workingOffDebounce: const Duration(milliseconds: 100),
      );
      await cm.boot();
      ch.pushControl(const RoomAnnounced(
        peer: 'epk_test',
        roomId: 'r1',
        startedAt: 1,
        working: true,
      ));
      await Future<void>.delayed(const Duration(milliseconds: 5));
      expect(cm.isRoomWorking('epk_test', 'r1'), isTrue);

      // Rapid intermediate tool finish: working=false arrives
      ch.pushControl(const RoomMetaUpdated(
        peer: 'epk_test',
        roomId: 'r1',
        working: false,
        hasModel: false,
        hasThinking: false,
      ));
      // Within 40ms (< 100ms debounce)
      await Future<void>.delayed(const Duration(milliseconds: 40));
      expect(cm.isRoomWorking('epk_test', 'r1'), isTrue,
          reason: 'must stay true during debounce window');

      // Next tool starts within window: working=true arrives
      ch.pushControl(const RoomMetaUpdated(
        peer: 'epk_test',
        roomId: 'r1',
        working: true,
        hasModel: false,
        hasThinking: false,
      ));
      await Future<void>.delayed(const Duration(milliseconds: 5));
      expect(cm.isRoomWorking('epk_test', 'r1'), isTrue);

      // Now turn ends completely and stays idle for 120ms (> 100ms debounce)
      ch.pushControl(const RoomMetaUpdated(
        peer: 'epk_test',
        roomId: 'r1',
        working: false,
        hasModel: false,
        hasThinking: false,
      ));
      await Future<void>.delayed(const Duration(milliseconds: 40));
      expect(cm.isRoomWorking('epk_test', 'r1'), isTrue,
          reason: 'still debouncing before window expires');

      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(cm.isRoomWorking('epk_test', 'r1'), isFalse,
          reason: 'cleanly commits off after debounce expires');

      cm.dispose();
    });
    test(
        'isRoomUnreadFinished is NOT set during intermediate tool debounce and only set when turn truly finishes',
        () async {
      final ch = _ControllableChannel();
      final cm = ConnectionManager(
        factory: (_, _) async => ch,
        storage: _FakeStorage([_fakePeer()]),
        emitDebounce: Duration.zero,
        workingOffDebounce: const Duration(milliseconds: 100),
      );
      await cm.boot();
      ch.pushControl(const RoomAnnounced(
        peer: 'epk_test',
        roomId: 'r1',
        startedAt: 1,
        working: true,
      ));
      await Future<void>.delayed(const Duration(milliseconds: 5));
      expect(cm.isRoomWorking('epk_test', 'r1'), isTrue);
      expect(cm.isRoomUnreadFinished('epk_test', 'r1'), isFalse);

      // Tool 1 ends -> working: false arrives
      ch.pushControl(const RoomMetaUpdated(
        peer: 'epk_test',
        roomId: 'r1',
        working: false,
        hasModel: false,
        hasThinking: false,
      ));
      await Future<void>.delayed(const Duration(milliseconds: 40));
      expect(cm.isRoomUnreadFinished('epk_test', 'r1'), isFalse,
          reason: 'must not mark Done during debounce');

      // Tool 2 starts within window
      ch.pushControl(const RoomMetaUpdated(
        peer: 'epk_test',
        roomId: 'r1',
        working: true,
        hasModel: false,
        hasThinking: false,
      ));
      await Future<void>.delayed(const Duration(milliseconds: 5));
      expect(cm.isRoomUnreadFinished('epk_test', 'r1'), isFalse);

      // Turn truly finishes -> working: false and window expires
      ch.pushControl(const RoomMetaUpdated(
        peer: 'epk_test',
        roomId: 'r1',
        working: false,
        hasModel: false,
        hasThinking: false,
      ));
      await Future<void>.delayed(const Duration(milliseconds: 40));
      expect(cm.isRoomUnreadFinished('epk_test', 'r1'), isFalse,
          reason: 'still not Done before debounce expires');

      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(cm.isRoomUnreadFinished('epk_test', 'r1'), isTrue,
          reason: 'marked Done only when turn truly ends');

      cm.dispose();
    });
  });
}
