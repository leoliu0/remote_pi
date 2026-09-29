import 'package:app/data/local/app_database.dart';
import 'package:app/data/preferences/preferences.dart';
import 'package:app/ui/chat/widgets/input_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';



void main() {
  group('Preferences draft management', () {
    test('getDraft returns empty string by default', () {
      final prefs = Preferences(AppDatabase.memory());
      expect(prefs.getDraft('peer1', 'room1'), '');
    });

    test('setDraft saves per peer and room, clearDraft removes it', () {
      final prefs = Preferences(AppDatabase.memory());
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

    test('load() hydrates drafts from SQLite', () async {
      final database = AppDatabase.memory();
      Preferences(database).setDraft(
        'peerX',
        'roomY',
        'persisted draft message',
      );

      final prefs = Preferences(database);
      await prefs.load();

      expect(prefs.getDraft('peerX', 'roomY'), 'persisted draft message');
      database.dispose();
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
