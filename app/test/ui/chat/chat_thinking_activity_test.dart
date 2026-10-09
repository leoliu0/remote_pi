// ChatPage wiring: the "Show thinking traces" setting decides whether
// `<think>` renders (live and history), in EVERY tool-call display mode; the
// agent_activity panel sits between the message list and the input bar.

import 'package:app/data/actions/actions_repository.dart';
import 'package:app/data/images/image_picker_service.dart';
import 'package:app/data/local/app_database.dart';
import 'package:app/data/preferences/preferences.dart';
import 'package:app/data/transport/channel.dart';
import 'package:app/data/transport/connection_manager.dart';
import 'package:app/data/voice/speech_service.dart';
import 'package:app/domain/session_state.dart';
import 'package:app/pairing/storage.dart';
import 'package:app/protocol/protocol.dart';
import 'package:app/routing/adaptive.dart';
import 'package:app/ui/chat/attachment/viewmodels/attachment_viewmodel.dart';
import 'package:app/ui/chat/chat_page.dart';
import 'package:app/ui/chat/states/chat_state.dart';
import 'package:app/ui/chat/viewmodels/chat_viewmodel.dart';
import 'package:app/ui/chat/voice/viewmodels/voice_input_viewmodel.dart';
import 'package:app/ui/chat/widgets/input_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

const _peer = PeerRecord(
  remoteEpk: 'epk_thinking_test',
  sessionName: 'Test Pi',
  relayUrl: 'ws://localhost',
  pairedAt: '2026-01-01T00:00:00Z',
);

class _FakeChatViewModel extends ChangeNotifier implements ChatViewModel {
  @override
  ChatState state;

  _FakeChatViewModel(this.state);

  @override
  bool get connectionResolved => true;
  @override
  bool get isRoomLive => true;
  @override
  bool get isWorking => false;
  @override
  PeerRecord? get activePeer => _peer;
  @override
  RoomInfo? get activeRoom => null;
  @override
  List<WireSkill> get dynamicSkills => const [];
  @override
  String? get cancelTargetId => null;
  @override
  List<QueuedMsg> get queuedMessages => const [];

  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class _FakeSpeech implements SpeechService {
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class _FakePicker implements IImagePickerService {
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class _FakeChannel implements IChannel {
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class _FakeStorage extends PairingStorage {
  _FakeStorage() : super(AppDatabase.memory());
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

void main() {
  final cleanups = <void Function()>[];

  /// Unmounts the page and disposes its collaborators INSIDE the test body —
  /// ConnectionManager timers must be gone before the binding's
  /// pending-timer check (which runs before tearDowns).
  Future<void> unmount(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    for (final c in cleanups) {
      c();
    }
    cleanups.clear();
  }

  Future<void> pumpChat(
    WidgetTester tester, {
    required ChatState state,
    required Preferences prefs,
  }) async {
    final vm = _FakeChatViewModel(state);
    final voice = VoiceInputViewModel(_FakeSpeech());
    final conn = ConnectionManager(
      factory: (_, _) async => _FakeChannel(),
      storage: _FakeStorage(),
    );
    final actions = ActionsRepository(conn);
    final attach = AttachmentViewModel(_FakePicker(), actions);
    final sel = SessionSelection();
    cleanups.add(() {
      vm.dispose();
      attach.dispose();
      voice.dispose();
      actions.dispose();
      sel.dispose();
      conn.dispose();
    });
    await tester.pumpWidget(
      MaterialApp(
        home: MultiProvider(
          providers: [
            ChangeNotifierProvider<ChatViewModel>.value(value: vm),
            ChangeNotifierProvider<VoiceInputViewModel>.value(value: voice),
            ChangeNotifierProvider<AttachmentViewModel>.value(value: attach),
            ChangeNotifierProvider<Preferences>.value(value: prefs),
            ChangeNotifierProvider<SessionSelection>.value(value: sel),
          ],
          child: const ChatPage(
            initialTitle: 'Test Session',
            initialDevice: 'MacBook',
            initialOnline: true,
          ),
        ),
      ),
    );
    await tester.pump();
  }

  // History row with a closed trace + a live reply still inside an
  // unterminated <think>.
  const thinkingState = ChatReady(
    messages: [
      UserMsg(id: 'u1', text: 'which plan?'),
      AssistantMsg(id: 'a1', text: '<think>weigh options</think>\n\nPlan B.'),
      UserMsg(id: 'u2', text: 'and now?'),
    ],
    streaming: StreamingMessage(
      inReplyTo: 'u2',
      buffer: '<think>still weighing',
    ),
  );

  for (final display in ToolCallDisplay.values) {
    for (final show in [true, false]) {
      testWidgets(
        'tool display ${display.name}, thinking ${show ? 'ON' : 'OFF'}',
        (tester) async {
          final prefs = Preferences(AppDatabase.memory());
          await prefs.setToolCallDisplay(display);
          await prefs.setShowThinking(show);
          await pumpChat(tester, state: thinkingState, prefs: prefs);

          expect(find.textContaining('Plan B.'), findsOneWidget);
          expect(find.textContaining('<think>'), findsNothing);
          expect(
            find.byKey(const Key('thinking-block')),
            findsNWidgets(show ? 2 : 0),
            reason: 'history trace + live unterminated trace',
          );
          expect(
            find.text('weigh options'),
            show ? findsOneWidget : findsNothing,
          );
          expect(
            find.text('still weighing'),
            show ? findsOneWidget : findsNothing,
          );

          await unmount(tester);
        },
      );
    }
  }

  testWidgets('a trace-only reply is hidden when thinking is OFF', (
    tester,
  ) async {
    final prefs = Preferences(AppDatabase.memory());
    await prefs.setShowThinking(false);
    await pumpChat(
      tester,
      state: const ChatReady(
        messages: [
          UserMsg(id: 'u1', text: 'hi'),
          AssistantMsg(id: 'a1', text: '<think>only reasoning</think>'),
        ],
      ),
      prefs: prefs,
    );
    expect(find.textContaining('only reasoning'), findsNothing);
    await unmount(tester);
  });

  testWidgets('activity panel sits just above the input bar', (tester) async {
    final prefs = Preferences(AppDatabase.memory());
    await pumpChat(
      tester,
      state: ChatReady(
        messages: const [UserMsg(id: 'u1', text: 'go')],
        activity: [
          AgentActivityJob(
            id: 'bg_1',
            kind: AgentActivityKind.bash,
            label: 'sleep 20',
            command: 'sleep 20',
            status: AgentActivityStatus.running,
            startedAt: DateTime.now().millisecondsSinceEpoch,
          ),
        ],
      ),
      prefs: prefs,
    );
    final header = find.text('waiting on 1 job');
    expect(header, findsOneWidget);
    expect(find.textContaining('└─ bg_1 sleep 20 · '), findsOneWidget);
    final panelBottom = tester.getBottomLeft(
      find.byKey(const Key('activity-panel')),
    );
    final inputTop = tester.getTopLeft(find.byType(InputBar));
    expect(panelBottom.dy, lessThanOrEqualTo(inputTop.dy));
    expect(inputTop.dy - panelBottom.dy, lessThan(1));

    await unmount(tester);
  });

  testWidgets('no activity → no panel', (tester) async {
    final prefs = Preferences(AppDatabase.memory());
    await pumpChat(
      tester,
      state: const ChatReady(messages: [UserMsg(id: 'u1', text: 'go')]),
      prefs: prefs,
    );
    expect(find.byKey(const Key('activity-panel')), findsNothing);
    await unmount(tester);
  });
}
