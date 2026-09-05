// Plan/delete-button — every tile exposes a visible delete affordance.
// Tap target must not swallow the row tap (it routes to the delete flow,
// not to opening the session).
import 'package:app/pairing/storage.dart';
import 'package:app/protocol/protocol.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:app/ui/home/widgets/session_tile.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

PeerRecord _peer() => const PeerRecord(
      remoteEpk: 'epk_A',
      sessionName: 'Mac',
      relayUrl: 'https://relay.example.com',
      pairedAt: '2026-01-01T00:00:00Z',
    );

Widget _wrap(Widget child) => MaterialApp(
      theme: buildDarkTheme(),
      home: Scaffold(body: child),
    );

void main() {
  testWidgets('renders a delete button that fires onDelete, not onOpen',
      (tester) async {
    var opened = 0;
    var deleted = 0;
    await tester.pumpWidget(
      _wrap(
        SessionTile(
          peer: _peer(),
          isLive: true,
          room: const RoomInfo(roomId: 'r1', startedAt: 1, cwd: '/x'),
          onOpen: () => opened++,
          onDelete: () => deleted++,
        ),
      ),
    );

    final btn = find.byTooltip('Delete session');
    expect(btn, findsOneWidget);

    await tester.tap(btn);
    await tester.pump();
    expect(deleted, 1);
    expect(opened, 0);
  });

  testWidgets('no delete button when onDelete is null', (tester) async {
    await tester.pumpWidget(
      _wrap(
        SessionTile(
          peer: _peer(),
          isLive: true,
          room: const RoomInfo(roomId: 'r1', startedAt: 1, cwd: '/x'),
          onOpen: () {},
        ),
      ),
    );
    expect(find.byTooltip('Delete session'), findsNothing);
  });

  testWidgets('subtitle shows model · thinking when both are known',
      (tester) async {
    await tester.pumpWidget(
      _wrap(
        SessionTile(
          peer: _peer(),
          isLive: true,
          room: const RoomInfo(
            roomId: 'r1',
            startedAt: 1,
            cwd: '/x',
            model: 'Gemini 2.5 Pro',
            thinking: ThinkingLevel.high,
          ),
          onOpen: () {},
        ),
      ),
    );
    expect(find.text('Gemini 2.5 Pro · high'), findsOneWidget);
  });

  testWidgets('subtitle falls back to model when thinking is unknown',
      (tester) async {
    await tester.pumpWidget(
      _wrap(
        SessionTile(
          peer: _peer(),
          isLive: true,
          room: const RoomInfo(
            roomId: 'r1',
            startedAt: 1,
            cwd: '/x',
            model: 'Gemini 2.5 Pro',
          ),
          onOpen: () {},
        ),
      ),
    );
    expect(find.text('Gemini 2.5 Pro'), findsOneWidget);
  });

  testWidgets('xhigh thinking labels as xhigh and normalizes raw model id', (tester) async {
    await tester.pumpWidget(
      _wrap(
        SessionTile(
          peer: _peer(),
          isLive: true,
          room: const RoomInfo(
            roomId: 'r1',
            startedAt: 1,
            cwd: '/x',
            model: 'gpt-4o',
            thinking: ThinkingLevel.xhigh,
          ),
          onOpen: () {},
        ),
      ),
    );
    expect(find.text('GPT 4o · xhigh'), findsOneWidget);
  });

  test('formatModelName handles various model id formats', () {
    expect(formatModelName('gemini-3.8-flash'), 'Gemini 3.8 Flash');
    expect(formatModelName('Gemini 3.8 Flash'), 'Gemini 3.8 Flash');
    expect(formatModelName('qwen3.8-flash'), 'Qwen 3.8 Flash');
    expect(formatModelName('qwen3.8-max'), 'Qwen 3.8 Max');
    expect(formatModelName('claude-3-7-sonnet'), 'Claude 3 7 Sonnet');
    expect(formatModelName('google/gemini-2.5-pro'), 'Gemini 2.5 Pro');
  });
}
