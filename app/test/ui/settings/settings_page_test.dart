// Regression guard — the Display section's five-segment Text size control
// must fit on a phone (~360 logical px wide) so every option stays tappable,
// and tapping a segment must persist the new AppFontScale.
import 'dart:async';
import 'dart:typed_data';

import 'package:app/data/preferences/preferences.dart';
import 'package:app/data/transport/connection_manager.dart';
import 'package:app/data/transport/peer_channel.dart';
import 'package:app/pairing/pair_request_flow.dart';
import 'package:app/pairing/storage.dart';
import 'package:app/ui/core/themes/app_font_scale.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:app/ui/settings/settings_page.dart';
import 'package:app/ui/settings/viewmodels/settings_viewmodel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

class _NoopTransport implements PeerTransport {
  @override
  Future<void> send(Uint8List data) async {}
  @override
  Future<Uint8List> receive() => Completer<Uint8List>().future;
  @override
  Future<void> close() async {}
}

class _FakeStorage extends PairingStorage {
  @override
  Future<List<PeerRecord>> listPeers() async => const [];
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'Text size control fits phone width and tapping a segment persists it',
    (tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final prefs = Preferences(_FakeSecureStorage());
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

      final prefs = Preferences(_FakeSecureStorage());
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
}
