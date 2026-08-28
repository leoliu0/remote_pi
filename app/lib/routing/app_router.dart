import 'dart:async';
import 'package:app/config/dependencies.dart';
import 'package:app/data/mesh/mesh_sync_service.dart';
import 'package:app/data/preferences/preferences.dart';
import 'package:app/data/transport/connection_manager.dart';
import 'package:app/pairing/owner_identity_bridge.dart';
import 'package:app/pairing/storage.dart';
import 'package:app/routing/adaptive.dart';
import 'package:app/ui/chat/attachment/viewmodels/attachment_viewmodel.dart';
import 'package:app/ui/chat/chat_page.dart';
import 'package:app/ui/chat/viewmodels/chat_viewmodel.dart';
import 'package:app/ui/chat/voice/viewmodels/voice_input_viewmodel.dart';
import 'package:app/ui/chat/widgets/detail_placeholder.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:app/ui/home/home_page.dart';
import 'package:app/ui/home/viewmodels/home_viewmodel.dart';
import 'package:app/ui/onboarding/onboarding_page.dart';
import 'package:app/ui/onboarding/viewmodels/onboarding_viewmodel.dart';
import 'package:app/ui/pairing/pairing_page.dart';
import 'package:app/ui/pairing/viewmodels/pairing_viewmodel.dart';
import 'package:app/ui/settings/settings_page.dart';
import 'package:app/ui/settings/viewmodels/settings_viewmodel.dart';
import 'package:app/ui/sync_required/sync_required_page.dart';
import 'package:app/ui/update/viewmodels/update_banner_viewmodel.dart';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

// Boot decision is async — _BootState is a ChangeNotifier used as
// refreshListenable so the router redirects once the storage check finishes.
class _BootState extends ChangeNotifier {
  bool _ready = false;
  bool _hasPeer = false;
  bool _onboarded = false;
  bool _syncAvailable = true;
  bool _identityWasGenerated = false;

  bool get ready => _ready;
  bool get hasPeer => _hasPeer;
  bool get onboarded => _onboarded;
  bool get syncAvailable => _syncAvailable;

  /// True when this run is the very first time the Owner key materialised
  /// on this account (the bridge just generated it). Restored identities
  /// — anything coming back from iCloud Keychain / Block Store, including
  /// the "reinstalled the app on the same device" case where the platform
  /// re-hands the previous key — set this to false.
  ///
  /// Drives the redirect: only fresh identities **and** an empty peer
  /// list get sent to the onboarding stepper; everything else lands on
  /// /home (which itself shows a friendly "pair your first Pi" state
  /// when peers is empty).
  bool get identityWasGenerated => _identityWasGenerated;

  Future<void> load(
    PairingStorage storage,
    ConnectionManager conn,
    Preferences prefs,
    OwnerIdentityBridge ownerBridge,
    MeshSyncService meshSync, {
    void Function()? installWatcherAfterBoot,
  }) async {
    try {
      await prefs.load();
      OwnerIdentityBootResult? ownerResult;
      try {
        ownerResult = await ownerBridge.boot().timeout(
          const Duration(seconds: 4),
          onTimeout: () => const SyncUnavailableResult(),
        );
      } catch (_) {}

      if (ownerResult is SyncUnavailableResult) {
        _syncAvailable = true;
        _ready = true;
        notifyListeners();
        return;
      }
      _syncAvailable = true;
      _identityWasGenerated =
          ownerResult is IdentityReady && ownerResult.generated;

      try {
        installWatcherAfterBoot?.call();
      } catch (_) {}

      try {
        await meshSync.pullOnDemand().timeout(
          const Duration(seconds: 3),
          onTimeout: () => false,
        );
      } catch (_) {}

      final peers = await storage.listPeers();
      _hasPeer = peers.isNotEmpty;
      if (_hasPeer && !prefs.onboardingCompleted) {
        await prefs.setOnboardingCompleted(true);
      }
      _onboarded = prefs.onboardingCompleted;
    } catch (_) {
      // Never block the app boot on unexpected initialization errors
    } finally {
      _ready = true;
      notifyListeners();
    }

    try {
      final peers = await storage.listPeers();
      if (peers.isNotEmpty) {
        var selected = prefs.selectedPeerEpk;
        if (selected == null || !peers.any((p) => p.remoteEpk == selected)) {
          selected = peers.first.remoteEpk;
          await prefs.setSelectedPeerEpk(selected);
        }
        unawaited(conn.boot(preferredEpk: selected));
      }
    } catch (_) {}
  }

  /// Plan 23 — invoked by the OwnerIdentityBridge watch listener when
  /// platform sync delivers a different Owner-pk. We reset to the
  /// "no-state" view; the next `load()` call (triggered when the user
  /// returns to /boot) will repopulate from the freshly-wiped storage.
  void onOwnerKeyReplaced() {
    _ready = false;
    _hasPeer = false;
    _onboarded = false;
    notifyListeners();
  }
}

GoRouter buildRouter(
  PairingStorage storage,
  ConnectionManager conn,
  Preferences prefs,
  OwnerIdentityBridge ownerBridge,
  MeshSyncService meshSync,
) {
  final boot = _BootState();

  // Plan 23 — watch for Owner-key drift on the sync surface. When the
  // platform delivers a different keypair (restored on a new device,
  // user wiped and re-installed elsewhere), the bridge wipes peers/rooms
  // and we reset the boot state so the router redirects through /boot.
  // Plan 24 — reset the mesh version watermark too, otherwise the
  // first fetch against the new Owner-pk would use a stale `since`.
  //
  // Hook is captured here but only installed AFTER boot() succeeds —
  // see _BootState.load's `installWatcherAfterBoot` parameter. That
  // ordering matters: the platform plugin emits an initial blob the
  // moment we subscribe; we must have `_current` populated by boot()
  // first, otherwise the bridge would see "different owner_pk" (vs
  // null) and wipe the freshly-loaded peer set.
  var watcherInstalled = false;
  void installWatcher() {
    if (watcherInstalled) return;
    watcherInstalled = true;
    ownerBridge.startWatching(
      onReset: () async {
        await conn.disconnect();
        meshSync.resetVersionWatermark();
        boot.onOwnerKeyReplaced();
        await boot.load(storage, conn, prefs, ownerBridge, meshSync);
      },
    );
  }

  boot.load(
    storage,
    conn,
    prefs,
    ownerBridge,
    meshSync,
    installWatcherAfterBoot: installWatcher,
  );

  // Plan 24 — start foreground polling. The router doesn't have
  // direct access to AppLifecycleState; main.dart wires
  // [MeshSyncService.startPolling/stopPolling] to the lifecycle so
  // this initial start covers the "app launched in foreground" case.
  meshSync.startPolling();

  return GoRouter(
    initialLocation: '/boot',
    refreshListenable: boot,
    redirect: (context, state) {
      if (!boot.ready) return '/boot';
      if (!boot.syncAvailable) {
        return state.uri.path == '/sync-required' ? null : '/sync-required';
      }
      final shouldOnboard = boot.identityWasGenerated && !boot.hasPeer;
      final target = shouldOnboard ? '/onboarding' : '/home';
      if (state.uri.path == '/sync-required' || state.uri.path == '/boot') {
        return target;
      }
      return null;
    },
    routes: [
      // Splash while boot.load() is in flight
      GoRoute(path: '/boot', builder: (ctx, st) => const _BootSplash()),

      // Plan 23 — first-launch gate when iCloud Keychain / Google
      // Backup is off. Sticky route: redirect keeps the user here
      // until the bridge reports sync available.
      GoRoute(
        path: '/sync-required',
        builder: (ctx, st) => const SyncRequiredPage(),
      ),

      // Plan/tablet — adaptive master-detail shell.
      //
      // Two branches, each with its own Navigator: branch 0 = Home
      // (master list), branch 1 = the chat detail. `navigatorContainerBuilder`
      // lays them out by available width:
      //   • wide (≥ kTabletBreakpoint) → master + detail side by side
      //   • narrow                     → only the active branch (phone)
      //
      // On phone the detail branch is never activated — tapping a session
      // does a full-screen root `push('/chat')` instead (see Home._open),
      // which preserves native back/swipe. The detail branch only renders
      // on tablet, where it reacts to [SessionSelection].
      StatefulShellRoute.indexedStack(
        builder: (ctx, st, navShell) {
          final twoPane =
              isWideLayout(ctx) && !ctx.watch<ShellLayout>().isZeroState;
          if (!twoPane) {
            return navShell;
          }
          return Row(
            children: [
              SizedBox(
                width: 360,
                child: MediaQuery.removePadding(
                  context: ctx,
                  removeRight: true,
                  child: navShell,
                ),
              ),
              VerticalDivider(width: 1, thickness: 1, color: ctx.colors.border),
              Expanded(
                child: MediaQuery.removePadding(
                  context: ctx,
                  removeLeft: true,
                  child: const _DetailPane(),
                ),
              ),
            ],
          );
        },
        branches: [
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/home',
                builder: (ctx, st) => MultiProvider(
                  providers: [
                    ViewmodelProvider<HomeViewModel>(),
                    ViewmodelProvider<UpdateBannerViewModel>(),
                  ],
                  child: const HomePage(),
                ),
              ),
            ],
          ),
          // `preload: true` so the detail branch is built up-front and
          // renders in the tablet's right pane at launch (showing the
          // placeholder) without first navigating into it. On phone the
          // branch is built but never displayed.
          StatefulShellBranch(
            preload: true,
            routes: [
              GoRoute(
                path: '/session',
                builder: (ctx, st) => const _DetailPane(),
              ),
            ],
          ),
        ],
      ),

      // QR pairing flow
      GoRoute(
        path: '/pair',
        builder: (ctx, st) =>
            ViewmodelProvider<PairingViewModel>(child: const PairingPage()),
      ),

      // Onboarding (plan 14) — 3-step flow shown when the app has
      // never been paired AND the user hasn't opted out. Provides
      // both OnboardingViewModel (state machine) AND PairingViewModel
      // (step 3 embeds the QR scanner reusing existing pair flow).
      GoRoute(
        path: '/onboarding',
        builder: (ctx, st) => MultiProvider(
          providers: [
            ViewmodelProvider<OnboardingViewModel>(),
            ViewmodelProvider<PairingViewModel>(),
          ],
          child: const OnboardingPage(),
        ),
      ),

      // Chat screen — PHONE full-screen path (root navigator, above the
      // shell), so it keeps native back/swipe. On tablet the chat lives
      // in the detail branch instead (see _detailPane). Entered by
      // tapping a session in /home.
      // Plan/24-fix-title: Home passes the already-known peer label
      // (nickname / sessionName) via `extra` so the AppBar renders
      // the right title from frame 1 instead of waiting for the
      // first `room_meta_updated` to arrive. Keeps reactivity to
      // room metadata changes that come later through the
      // ChatViewModel.
      GoRoute(
        path: '/chat',
        builder: (ctx, st) {
          final extra = st.extra;
          String? initialTitle;
          String? initialDevice;
          var initialOnline = false;
          if (extra is Map) {
            final t = extra['title'];
            if (t is String && t.isNotEmpty) initialTitle = t;
            // Plan/32g — device (Mac) label Home already knows, so AppBar
            // line 2 renders immediately (no async PeerRecord wait).
            final d = extra['device'];
            if (d is String && d.isNotEmpty) initialDevice = d;
            // Live state of the tile → initial status dot (no reconnect flash).
            initialOnline = extra['online'] == true;
          }
          return MultiProvider(
            providers: [
              ViewmodelProvider<ChatViewModel>(),
              ViewmodelProvider<VoiceInputViewModel>(),
              ViewmodelProvider<AttachmentViewModel>(),
            ],
            child: ChatPage(
              initialTitle: initialTitle,
              initialDevice: initialDevice,
              initialOnline: initialOnline,
            ),
          );
        },
      ),

      // Settings (entered from /home menu)
      GoRoute(
        path: '/settings',
        builder: (ctx, st) =>
            ViewmodelProvider<SettingsViewModel>(child: const SettingsPage()),
      ),
    ],
  );
}

/// Detail pane for the tablet's right side. Reacts to [SessionSelection]:
/// shows the placeholder until a session is picked, then the chat — keyed
/// by (epk, room) so switching sessions tears down the old ChatViewModel
/// and builds a fresh one, which re-binds to the now-selected peer (the
/// VM reads `Preferences.selectedPeerEpk`, already set by Home._open).
class _DetailPane extends StatelessWidget {
  const _DetailPane();

  @override
  Widget build(BuildContext context) {
    final sel = context.watch<SessionSelection>();
    if (sel.current == null) {
      return const DetailPlaceholder();
    }
    return MultiProvider(
      key: ValueKey('chat-${sel.current!.epk}-${sel.current!.roomId}'),
      providers: [
        ViewmodelProvider<ChatViewModel>(),
        ViewmodelProvider<VoiceInputViewModel>(),
        ViewmodelProvider<AttachmentViewModel>(),
      ],
      child: ChatPage(
        initialTitle: sel.current!.title,
        initialDevice: sel.current!.device.isEmpty ? null : sel.current!.device,
        initialOnline: sel.current!.online,
        showBack: false,
      ),
    );
  }
}

class _BootSplash extends StatelessWidget {
  const _BootSplash();

  @override
  Widget build(BuildContext context) {
    print('[_BootSplash] build called');
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(LucideIcons.radio, size: 40, color: context.colors.accent),
            const SizedBox(height: 16),
            Text(
              'Remote Pi',
              style: TextStyle(
                fontFamily: kMonoFamily,
                fontSize: 18,
                fontWeight: FontWeight.w600,
                color: context.colors.text,
              ),
            ),
            const SizedBox(height: 24),
            SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(
                color: context.colors.accent,
                strokeWidth: 2,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
