import 'package:app/data/preferences/preferences.dart';
import 'package:app/ui/chat/widgets/input_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

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
    if (value != null) {
      _store[key] = value;
    } else {
      _store.remove(key);
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
  }) async {
    _store.remove(key);
  }

  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

void main() {
  group('Preferences draft management', () {
    test('getDraft returns empty string by default', () {
      final prefs = Preferences(_FakeSecureStorage());
      expect(prefs.getDraft('peer1', 'room1'), '');
    });

    test('setDraft saves per peer and room, clearDraft removes it', () {
      final prefs = Preferences(_FakeSecureStorage());
      prefs.setDraft('peerA', 'room1', 'draft for A1');
      prefs.setDraft('peerA', 'room2', 'draft for A2');
      prefs.setDraft('peerB', 'room1', 'draft for B1');

      expect(prefs.getDraft('peerA', 'room1'), 'draft for A1');
      expect(prefs.getDraft('peerA', 'room2'), 'draft for A2');
      expect(prefs.getDraft('peerB', 'room1'), 'draft for B1');

      prefs.clearDraft('peerA', 'room1');
      expect(prefs.getDraft('peerA', 'room1'), '');
      expect(prefs.getDraft('peerA', 'room2'), 'draft for A2');
    });

    test('load() hydrates drafts from secure storage', () async {
      final storage = _FakeSecureStorage();
      await storage.write(
        key: 'prefs.draft.peerX:roomY',
        value: 'persisted draft message',
      );

      final prefs = Preferences(storage);
      await prefs.load();

      expect(prefs.getDraft('peerX', 'roomY'), 'persisted draft message');
    });
  });

  group('InputBar draft support', () {
    testWidgets('populates initialText and sets cursor at the end', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: InputBar(
              initialText: 'Hello saved draft',
              onSend: (_) {},
            ),
          ),
        ),
      );
      await tester.pump();

      expect(find.text('Hello saved draft'), findsOneWidget);

      final textField = tester.widget<TextField>(find.byType(TextField));
      expect(textField.controller?.selection.baseOffset, 'Hello saved draft'.length);
    });

    testWidgets('fires onDraftChanged as user types', (tester) async {
      final drafts = <String>[];

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: InputBar(
              initialText: '',
              onDraftChanged: (text) => drafts.add(text),
              onSend: (_) {},
            ),
          ),
        ),
      );
      await tester.pump();

      await tester.enterText(find.byType(TextField), 'typing a message');
      await tester.pump();

      expect(drafts.last, 'typing a message');
    });

    testWidgets('submitting clears the draft and invokes onSend', (
      tester,
    ) async {
      final drafts = <String>[];
      String? sentText;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: InputBar(
              initialText: 'ready to send',
              onDraftChanged: (text) => drafts.add(text),
              onSend: (text) => sentText = text,
            ),
          ),
        ),
      );
      await tester.pump();
      // Tap send button
      await tester.tap(find.byKey(const Key('input-bar-action')));
      await tester.pump();
      expect(sentText, 'ready to send');
      expect(drafts.last, '');
      expect(find.text('ready to send'), findsNothing);
    });

    testWidgets('didUpdateWidget updates controller when initialText changes', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: InputBar(
              initialText: 'draft A',
              onSend: (_) {},
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.text('draft A'), findsOneWidget);

      // Update with new initialText (e.g. session switched)
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: InputBar(
              initialText: 'draft B',
              onSend: (_) {},
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.text('draft B'), findsOneWidget);
      expect(find.text('draft A'), findsNothing);
    });

    testWidgets('queueing a message clears the composer text and draft', (
      tester,
    ) async {
      final drafts = <String>[];
      String? queuedText;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: InputBar(
              initialText: 'follow up idea',
              streaming: true,
              onDraftChanged: (text) => drafts.add(text),
              onSetQueued: (text) => queuedText = text,
              onSend: (_) {},
            ),
          ),
        ),
      );
      await tester.pump();

      await tester.tap(find.byKey(const Key('input-bar-queue')));
      await tester.pump();

      expect(queuedText, 'follow up idea');
      expect(drafts.last, '');
      expect(find.text('follow up idea'), findsNothing);
    });
  });
}
