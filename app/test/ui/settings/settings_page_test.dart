// Regression guards for the Settings page:
// - the Display section's five-segment Text size control must fit on a phone
//   (~360 logical px wide) and tapping a segment must persist AppFontScale;
// - "Sign in on web" must warn before revealing the owner-key link.
import 'dart:async';

import 'package:app/data/local/app_database.dart';
import 'package:app/data/preferences/preferences.dart';
import 'package:app/data/transport/connection_manager.dart';
import 'package:app/data/transport/peer_channel.dart';
import 'package:app/pairing/owner_identity_bridge.dart';
import 'package:app/pairing/pair_request_flow.dart';
import 'package:app/pairing/storage.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:app/ui/settings/settings_page.dart';
import 'package:app/ui/settings/viewmodels/settings_viewmodel.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:remote_pi_identity/remote_pi_identity.dart';

class _NoopTransport implements PeerTransport {
  @override
  Future<void> send(Uint8List data) async {}
  @override
  Future<Uint8List> receive() => Completer<Uint8List>().future;
  @override
  Future<void> close() async {}
}

class _FakeStorage extends PairingStorage {
  _FakeStorage() : super(AppDatabase.memory());
  @override
  Future<List<PeerRecord>> listPeers() async => const [];
}

Preferences _preferences() => Preferences(AppDatabase.memory());

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'Text size control fits phone width and tapping a segment persists it',
    (tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final prefs = _preferences();
      await prefs.load();
      final conn = ConnectionManager(
        factory: (_, _) async =>
            PlainPeerChannel(transport: _NoopTransport()),
        storage: _FakeStorage(),
      );
      final vm = SettingsViewModel(_FakeStorage(), prefs, conn);
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<Preferences>.value(value: prefs),
            ChangeNotifierProvider<SettingsViewModel>.value(value: vm),
          ],
          // Mirror main.dart: Consumer rebuilds MaterialApp on prefs
          // changes and the whole app runs under the user's TextScaler,
          // so the Settings page must not overflow at any scale.
          child: Consumer<Preferences>(
            builder: (context, p, _) => MaterialApp(
              theme: buildDarkTheme(),
              home: const SettingsPage(),
              builder: (context, child) {
                if (child == null) return const SizedBox.shrink();
                final media = MediaQuery.of(context);
                return MediaQuery(
                  data: media.copyWith(
                    textScaler: TextScaler.linear(p.fontScale.factor),
                  ),
                  child: child,
                );
              },
            ),
          ),
        ),
      );
      // pump(), not pumpAndSettle(): the loading state hosts an indeterminate
      // spinner whose animation never ends.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      // A RenderFlex overflow would have failed the test during pump.
      final control = find.byWidgetPredicate(
        (w) => w is SegmentedButton<AppFontScale>,
      );
      expect(control, findsOneWidget);

      // Every option label is on screen — none clipped off the right edge.
      for (final scale in AppFontScale.values) {
        expect(find.text(scale.label), findsOneWidget);
      }

      await tester.tap(find.text('Small'));
      await tester.pump();
      expect(prefs.fontScale, AppFontScale.small);

      await tester.tap(find.text('XXL'));
      await tester.pump();
      expect(prefs.fontScale, AppFontScale.huge);
      // Render at XXL (1.45x) — an overflow here throws during pump.
      await tester.pump(const Duration(milliseconds: 50));
      for (final scale in AppFontScale.values) {
        expect(find.text(scale.label), findsOneWidget);
      }

      // And back down from XXL — the control must stay tappable.
      await tester.tap(find.text('Small'));
      await tester.pump(const Duration(milliseconds: 50));
      expect(prefs.fontScale, AppFontScale.small);
      vm.dispose();
      conn.dispose();
      prefs.dispose();
    },
  );

  testWidgets(
    'Text size control still fits at 320px (small phones)',
    (tester) async {
      tester.view.physicalSize = const Size(320, 700);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final prefs = _preferences();
      await prefs.load();
      await prefs.setFontScale(AppFontScale.huge); // worst case: 1.45x
      final conn = ConnectionManager(
        factory: (_, _) async =>
            PlainPeerChannel(transport: _NoopTransport()),
        storage: _FakeStorage(),
      );
      final vm = SettingsViewModel(_FakeStorage(), prefs, conn);

      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<Preferences>.value(value: prefs),
            ChangeNotifierProvider<SettingsViewModel>.value(value: vm),
          ],
          child: Consumer<Preferences>(
            builder: (context, p, _) => MaterialApp(
              theme: buildDarkTheme(),
              home: const SettingsPage(),
              builder: (context, child) {
                if (child == null) return const SizedBox.shrink();
                final media = MediaQuery.of(context);
                return MediaQuery(
                  data: media.copyWith(
                    textScaler: TextScaler.linear(p.fontScale.factor),
                  ),
                  child: child,
                );
              },
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      // All five labels reachable even at 320px × 1.45 — an overflow
      // would have thrown during pump and clipped the right segments.
      for (final scale in AppFontScale.values) {
        expect(find.text(scale.label), findsOneWidget);
      }

      vm.dispose();
      conn.dispose();
      prefs.dispose();
    },
  );

  testWidgets(
    'Sign in on web warns first, then shows the link as QR + copy',
    (tester) async {
      tester.view.physicalSize = const Size(400, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final copied = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied.add((call.arguments as Map)['text'] as String);
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.platform, null),
      );

      final prefs = _preferences();
      await prefs.load();
      final storage = _FakeStorage();
      final identityStore = InMemoryOwnerIdentityStore();
      final bridge = OwnerIdentityBridge(identityStore, storage);
      await tester.runAsync(bridge.boot);
      final conn = ConnectionManager(
        factory: (_, _) async =>
            PlainPeerChannel(transport: _NoopTransport()),
        storage: storage,
      );
      final vm = SettingsViewModel(storage, prefs, conn, null, bridge);
      final expected = vm.webSignInLink!;

      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<Preferences>.value(value: prefs),
            ChangeNotifierProvider<SettingsViewModel>.value(value: vm),
          ],
          child: MaterialApp(
            theme: buildDarkTheme(),
            home: const SettingsPage(),
          ),
        ),
      );
      await tester.pump();

      await tester.tap(find.text('Sign in on web'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(
        find.text(
          'This link gives full control of your PCs. '
          'Only open it on your own browser.',
        ),
        findsOneWidget,
      );

      // Cancel reveals nothing.
      await tester.tap(find.text('Cancel'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(QrImageView), findsNothing);

      await tester.tap(find.text('Sign in on web'));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.text('Continue'));
      // The sheet route starts once the dialog's future resolves; let its
      // entrance animation finish before tapping inside it.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));

      expect(find.byType(QrImageView), findsOneWidget);
      expect(find.text(expected), findsNothing); // never printed on screen

      await tester.tap(find.text('Copy link'));
      await tester.pump();
      expect(copied, [expected]);
      expect(find.text('Link copied'), findsOneWidget);

      vm.dispose();
      conn.dispose();
      bridge.dispose();
      identityStore.dispose();
      prefs.dispose();
    },
  );
}
