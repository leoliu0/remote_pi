// ChatPage wiring for omp plan mode: a pending request with a `plan` envelope
// renders the plan review sheet (not the generic prompt sheet), and the input
// bar's plan button follows ChatReady.planState and dispatches through
// ChatViewModel.setPlanMode.

import 'dart:convert';

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
import 'package:app/ui/chat/widgets/extension_ui_sheet.dart';
import 'package:app/ui/chat/widgets/plan_review_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import '../../protocol/plan_capture_fixtures.dart';

const _peer = PeerRecord(
  remoteEpk: 'epk_plan_test',
  sessionName: 'Test Pi',
  relayUrl: 'ws://localhost',
  pairedAt: '2026-01-01T00:00:00Z',
);

class _FakeChatViewModel extends ChangeNotifier implements ChatViewModel {
  @override
  ChatState state;

  _FakeChatViewModel(this.state);

  final List<PlanModeAction> planModes = [];

  @override
  Future<void> setPlanMode(PlanModeAction action) async =>
      planModes.add(action);

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

ServerMessage _frame(String json) =>
    ServerMessage.fromJson(jsonDecode(json) as Map<String, dynamic>);

void main() {
  final cleanups = <void Function()>[];

  Future<void> unmount(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    for (final c in cleanups) {
      c();
    }
    cleanups.clear();
  }

  Future<_FakeChatViewModel> pumpChat(
    WidgetTester tester,
    ChatState state,
  ) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.reset);
    final prefs = Preferences(AppDatabase.memory());
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
    return vm;
  }

  testWidgets('a plan review request renders the plan review sheet', (
    tester,
  ) async {
    await pumpChat(
      tester,
      ChatReady(
        messages: const [],
        pendingUiRequest:
            _frame(kPlanReviewRequestFrame) as ExtensionUiRequest,
      ),
    );

    expect(find.byType(PlanReviewSheet), findsOneWidget);
    expect(find.byType(ExtensionUiSheet), findsNothing);
    expect(find.text('Plan ready for review'), findsOneWidget);
    expect(
      find.byKey(const Key('plan-review-option-approve_execute')),
      findsOneWidget,
    );

    await unmount(tester);
  });

  testWidgets('plan_state drives the plan button and its plan_mode sends', (
    tester,
  ) async {
    final vm = await pumpChat(
      tester,
      ChatReady(
        messages: const [],
        planState: _frame(kPlanStateReviewFrame) as PlanState,
      ),
    );
    final planButton = find.byKey(const Key('input-bar-plan-mode'));
    expect(
      tester.widget<IconButton>(planButton).tooltip,
      'Plan ready for review — tap to review',
    );

    await tester.tap(planButton);
    await tester.pump();
    expect(vm.planModes, [PlanModeAction.review]);

    await unmount(tester);
  });

  testWidgets('no plan_state → the plan button shows plain plan mode', (
    tester,
  ) async {
    await pumpChat(tester, const ChatReady(messages: []));
    expect(
      tester
          .widget<IconButton>(find.byKey(const Key('input-bar-plan-mode')))
          .tooltip,
      'Plan mode',
    );
    await unmount(tester);
  });
}
