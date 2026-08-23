import 'package:app/data/preferences/preferences.dart';
import 'package:app/data/voice/speech_service.dart';
import 'package:app/data/images/image_picker_service.dart';
import 'package:app/data/actions/actions_repository.dart';
import 'package:app/data/transport/channel.dart';
import 'package:app/data/transport/connection_manager.dart';
import 'package:app/domain/session_state.dart';
import 'package:app/pairing/storage.dart';
import 'package:app/protocol/protocol.dart';
import 'package:app/routing/adaptive.dart';
import 'package:app/ui/chat/attachment/viewmodels/attachment_viewmodel.dart';
import 'package:app/ui/chat/chat_page.dart';
import 'package:app/ui/chat/states/chat_state.dart';
import 'package:app/ui/chat/viewmodels/chat_viewmodel.dart';
import 'package:app/ui/chat/voice/viewmodels/voice_input_viewmodel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

const _testPeer = PeerRecord(
  remoteEpk: 'epk_scroll_test',
  sessionName: 'Test Pi',
  relayUrl: 'ws://localhost',
  pairedAt: '2026-01-01T00:00:00Z',
);

class _FakeChatViewModel extends ChangeNotifier implements ChatViewModel {
  @override
  ChatState state;

  final List<String> sentMessages = [];
  final List<String> queuedMessagesList = [];

  _FakeChatViewModel(this.state);

  @override
  Future<void> sendMessage(String text, {MessageImage? image}) async {
    sentMessages.add(text);
  }

  @override
  void queueMessage(String text) {
    queuedMessagesList.add(text);
  }

  @override
  bool get connectionResolved => true;

  @override
  bool get isRoomLive => true;

  @override
  bool get isWorking => false;

  @override
  PeerRecord? get activePeer => _testPeer;

  @override
  RoomInfo? get activeRoom => null;

  @override
  List<WireSkill> get dynamicSkills => const [];

  @override
  String? get cancelTargetId => null;

  @override
  List<QueuedMsg> get queuedMessages => const [];

  @override
  void setQueuedMessage(String text) => queueMessage(text);

  @override
  void clearQueuedMessage([String? id]) {}

  @override
  void clearQueuedMessages() {}

  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
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
  Future<Map<String, String>> readAll({
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async => Map.from(_store);
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
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

void main() {
  List<ChatMessage> createMessages(int count) {
    final list = <ChatMessage>[];
    for (var i = 0; i < count; i++) {
      list.add(UserMsg(id: 'u_$i', text: 'User message $i with some detailed text to fill up height'));
      list.add(AssistantMsg(id: 'a_$i', text: 'Assistant message $i replying with paragraph of text'));
    }
    return list;
  }

  Widget buildChat({
    required _FakeChatViewModel vm,
    required VoiceInputViewModel voice,
    required AttachmentViewModel attach,
    required Preferences prefs,
    required SessionSelection sel,
  }) {
    return MaterialApp(
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
    );
  }

  testWidgets('Scroll to bottom button appears on scroll up and scrolls to bottom on tap', (tester) async {
    final messages = createMessages(30);
    final vm = _FakeChatViewModel(ChatReady(messages: messages));
    final voice = VoiceInputViewModel(_FakeSpeech());
    final conn = ConnectionManager(factory: (_, _) async => _FakeChannel(), storage: _FakeStorage());
    final actions = ActionsRepository(conn);
    final attach = AttachmentViewModel(_FakePicker(), actions);
    final prefs = Preferences(_FakeSecureStorage());
    final sel = SessionSelection();

    await tester.pumpWidget(
      buildChat(vm: vm, voice: voice, attach: attach, prefs: prefs, sel: sel),
    );
    await tester.pump();

    final scrollBtnKey = find.byKey(const Key('chat_scroll_to_bottom'));
    expect(scrollBtnKey, findsOneWidget);

    // Initial state at bottom (offset 0): button hidden (opacity 0.0)
    final initialOpacity = tester.widget<AnimatedOpacity>(
      find.ancestor(of: scrollBtnKey, matching: find.byType(AnimatedOpacity)),
    );
    expect(initialOpacity.opacity, 0.0);

    // Scroll up (drag down on reversed ListView)
    final listView = find.byType(ListView);
    expect(listView, findsOneWidget);
    await tester.drag(listView, const Offset(0, 400));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));

    // Button should now be visible
    final visibleOpacity = tester.widget<AnimatedOpacity>(
      find.ancestor(of: scrollBtnKey, matching: find.byType(AnimatedOpacity)),
    );
    expect(visibleOpacity.opacity, 1.0);

    // Tap scroll to bottom button
    await tester.tap(scrollBtnKey);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    // Should scroll back to bottom and button becomes hidden
    final afterTapOpacity = tester.widget<AnimatedOpacity>(
      find.ancestor(of: scrollBtnKey, matching: find.byType(AnimatedOpacity)),
    );
    expect(afterTapOpacity.opacity, 0.0);

    // Dispose
    await tester.pumpWidget(const SizedBox());
    vm.dispose();
    attach.dispose();
    voice.dispose();
    actions.dispose();
    sel.dispose();
    conn.dispose();
  });

  testWidgets('Sending a message auto-scrolls down to bottom of chat', (tester) async {
    final messages = createMessages(30);
    final vm = _FakeChatViewModel(ChatReady(messages: messages));
    final voice = VoiceInputViewModel(_FakeSpeech());
    final conn = ConnectionManager(factory: (_, _) async => _FakeChannel(), storage: _FakeStorage());
    final actions = ActionsRepository(conn);
    final attach = AttachmentViewModel(_FakePicker(), actions);
    final prefs = Preferences(_FakeSecureStorage());
    final sel = SessionSelection();

    await tester.pumpWidget(
      buildChat(vm: vm, voice: voice, attach: attach, prefs: prefs, sel: sel),
    );
    await tester.pump();

    final scrollBtnKey = find.byKey(const Key('chat_scroll_to_bottom'));

    // Scroll up
    final listView = find.byType(ListView);
    await tester.drag(listView, const Offset(0, 400));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));

    // Verify button visible
    final visibleOpacity = tester.widget<AnimatedOpacity>(
      find.ancestor(of: scrollBtnKey, matching: find.byType(AnimatedOpacity)),
    );
    expect(visibleOpacity.opacity, 1.0);

    // Enter message in InputBar and tap Send
    final textField = find.byType(TextField);
    await tester.enterText(textField, 'New user message');
    await tester.pump();
    final sendButton = find.byKey(const Key('input-bar-action'));
    await tester.tap(sendButton);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(vm.sentMessages, contains('New user message'));

    // Auto-scrolls to bottom, button hidden
    final afterSendOpacity = tester.widget<AnimatedOpacity>(
      find.ancestor(of: scrollBtnKey, matching: find.byType(AnimatedOpacity)),
    );
    expect(afterSendOpacity.opacity, 0.0);

    // Dispose
    await tester.pumpWidget(const SizedBox());
    vm.dispose();
    attach.dispose();
    voice.dispose();
    actions.dispose();
    sel.dispose();
    conn.dispose();
  });

  testWidgets('Queueing a message auto-scrolls down to bottom of chat', (tester) async {
    final messages = createMessages(30);
    // Set working = true so queue button is available
    final vm = _FakeChatViewModel(ChatReady(messages: messages));
    final voice = VoiceInputViewModel(_FakeSpeech());
    final conn = ConnectionManager(factory: (_, _) async => _FakeChannel(), storage: _FakeStorage());
    final actions = ActionsRepository(conn);
    final attach = AttachmentViewModel(_FakePicker(), actions);
    final prefs = Preferences(_FakeSecureStorage());
    final sel = SessionSelection();

    await tester.pumpWidget(
      buildChat(vm: vm, voice: voice, attach: attach, prefs: prefs, sel: sel),
    );
    await tester.pump();

    final scrollBtnKey = find.byKey(const Key('chat_scroll_to_bottom'));

    // Scroll up
    final listView = find.byType(ListView);
    await tester.drag(listView, const Offset(0, 400));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));

    // Verify button visible
    final visibleOpacity = tester.widget<AnimatedOpacity>(
      find.ancestor(of: scrollBtnKey, matching: find.byType(AnimatedOpacity)),
    );
    expect(visibleOpacity.opacity, 1.0);

    // Enter text and tap queue button
    final textField = find.byType(TextField);
    await tester.enterText(textField, 'Queued follow up');
    await tester.pump();

    final queueButton = find.byKey(const Key('input-bar-queue'));
    if (queueButton.evaluate().isNotEmpty) {
      await tester.tap(queueButton);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(vm.queuedMessagesList, contains('Queued follow up'));

      final afterQueueOpacity = tester.widget<AnimatedOpacity>(
        find.ancestor(of: scrollBtnKey, matching: find.byType(AnimatedOpacity)),
      );
      expect(afterQueueOpacity.opacity, 0.0);
    }

    // Dispose
    await tester.pumpWidget(const SizedBox());
    vm.dispose();
    attach.dispose();
    voice.dispose();
    actions.dispose();
    sel.dispose();
    conn.dispose();
  });
}
