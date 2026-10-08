// Regression guards for the Settings page:
// - the Display section's five-segment Text size control must fit on a phone
//   (~360 logical px wide) and tapping a segment must persist AppFontScale;
// - "Sign in on web" opens the website-QR scanner, rejects foreign codes while
//   scanning, confirms, then delivers the encrypted Owner seed.
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:app/data/local/app_database.dart';
import 'package:app/data/preferences/preferences.dart';
import 'package:app/data/site/web_login.dart';
import 'package:app/data/transport/connection_manager.dart';
import 'package:app/data/transport/peer_channel.dart';
import 'package:app/pairing/owner_identity_bridge.dart';
import 'package:app/pairing/pair_request_flow.dart';
import 'package:app/pairing/storage.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:app/ui/settings/settings_page.dart';
import 'package:app/ui/settings/viewmodels/settings_viewmodel.dart';
import 'package:app/ui/settings/web_login_scan_page.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
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

  group('Sign in on web', () {
    late Preferences prefs;
    late _FakeStorage storage;
    late InMemoryOwnerIdentityStore identityStore;
    late OwnerIdentityBridge bridge;
    late ConnectionManager conn;
    late _StubWebLoginClient client;
    late SettingsViewModel vm;
    late String webCode;
    ValueChanged<String>? feed;

    Widget fakeScanner(BuildContext context, ValueChanged<String> onCode) {
      feed = onCode;
      return const ColoredBox(key: Key('fake-scanner'), color: Colors.black);
    }

    Future<void> openScanner(WidgetTester tester, WebLoginResult reply) async {
      tester.view.physicalSize = const Size(400, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      prefs = _preferences();
      await prefs.load();
      storage = _FakeStorage();
      identityStore = InMemoryOwnerIdentityStore();
      bridge = OwnerIdentityBridge(identityStore, storage);
      await tester.runAsync(bridge.boot);
      conn = ConnectionManager(
        factory: (_, _) async =>
            PlainPeerChannel(transport: _NoopTransport()),
        storage: storage,
      );
      client = _StubWebLoginClient(reply);
      vm = SettingsViewModel(storage, prefs, conn, null, bridge, client);
      final browser = await tester.runAsync(() async {
        final keyPair = await X25519().newKeyPair();
        return keyPair.extractPublicKey();
      });
      final pk = base64Url.encode(browser!.bytes).replaceAll('=', '');
      webCode =
          'remotepi://web-login?h=$webLoginHost&id=EBESExQVFhcYGRobHB0eHw'
          '&pk=$pk';

      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<Preferences>.value(value: prefs),
            ChangeNotifierProvider<SettingsViewModel>.value(value: vm),
          ],
          child: MaterialApp(
            theme: buildDarkTheme(),
            home: SettingsPage(webLoginScanner: fakeScanner),
          ),
        ),
      );
      await tester.pump();

      await tester.tap(find.text('Sign in on web'));
      await tester.pumpAndSettle();
    }

    void dispose() {
      vm.dispose();
      conn.dispose();
      bridge.dispose();
      identityStore.dispose();
      prefs.dispose();
    }

    Future<void> scan(WidgetTester tester, String raw) async {
      feed!(raw);
      await tester.pumpAndSettle();
    }

    testWidgets(
      'row opens the scanner; foreign codes are rejected while scanning; '
      'confirmed code signs the browser in',
      (tester) async {
        await openScanner(tester, const WebLoginDelivered());

        expect(find.byType(WebLoginScanPage), findsOneWidget);
        expect(find.text('Scan the code on the website'), findsOneWidget);
        expect(find.byKey(const Key('fake-scanner')), findsOneWidget);

        // A pairing QR is refused with a clear error; scanning continues.
        await scan(tester, 'remotepi://pair?t=AAAA&epk=BBBB&n=mac');
        expect(find.textContaining('PC pairing code'), findsOneWidget);
        expect(find.byKey(const Key('fake-scanner')), findsOneWidget);

        // A web-login code for another host is refused too.
        await scan(
          tester,
          webCode.replaceFirst('h=$webLoginHost', 'h=evil.example'),
        );
        expect(find.textContaining('Unknown website'), findsOneWidget);
        expect(find.byKey(const Key('fake-scanner')), findsOneWidget);
        expect(client.delivered, isEmpty);

        await scan(tester, webCode);
        expect(
          find.text(
            'Sign in the browser at $webLoginHost? '
            'It gets full control of your PCs.',
          ),
          findsOneWidget,
        );
        expect(find.byKey(const Key('fake-scanner')), findsNothing);

        await tester.runAsync(() async {
          await tester.tap(find.text('Sign in'));
          // Let the real X25519/HKDF/AES-GCM work finish.
          for (var i = 0; i < 50 && client.delivered.isEmpty; i++) {
            await Future<void>.delayed(const Duration(milliseconds: 10));
          }
        });
        await tester.pumpAndSettle();

        expect(client.delivered, hasLength(1));
        expect(client.delivered.single.id, 'EBESExQVFhcYGRobHB0eHw');
        expect(find.byType(WebLoginScanPage), findsNothing);
        expect(find.text('Browser signed in'), findsOneWidget);

        dispose();
      },
    );

    testWidgets('expired code tells the user to refresh the website', (
      tester,
    ) async {
      await openScanner(tester, const WebLoginExpired());

      await scan(tester, webCode);
      await tester.runAsync(() async {
        await tester.tap(find.text('Sign in'));
        for (var i = 0; i < 50 && client.delivered.isEmpty; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
      });
      await tester.pumpAndSettle();

      expect(
        find.text('Code expired, refresh the website and scan again'),
        findsOneWidget,
      );
      await tester.tap(find.text('Scan again'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('fake-scanner')), findsOneWidget);

      dispose();
    });

    testWidgets('network failure is reported', (tester) async {
      await openScanner(tester, const WebLoginNetworkError());

      await scan(tester, webCode);
      await tester.runAsync(() async {
        await tester.tap(find.text('Sign in'));
        for (var i = 0; i < 50 && client.delivered.isEmpty; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
      });
      await tester.pumpAndSettle();

      expect(
        find.text('Network error. Check your connection and try again.'),
        findsOneWidget,
      );

      dispose();
    });

    testWidgets('Cancel sends nothing and leaves the scanner', (tester) async {
      await openScanner(tester, const WebLoginDelivered());

      await scan(tester, webCode);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(client.delivered, isEmpty);
      expect(find.byType(WebLoginScanPage), findsNothing);
      expect(find.text('Sign in on web'), findsOneWidget);

      dispose();
    });
  });
}

class _StubWebLoginClient extends WebLoginClient {
  final WebLoginResult reply;
  final List<WebLoginRequest> delivered = [];

  _StubWebLoginClient(this.reply);

  @override
  Future<WebLoginResult> deliver(
    WebLoginRequest request,
    WebLoginEnvelope envelope,
  ) async {
    delivered.add(request);
    return reply;
  }
}
