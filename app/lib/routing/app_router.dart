import 'dart:async';
import 'package:app/config/dependencies.dart';
import 'package:app/data/mesh/mesh_sync_service.dart';
import 'package:app/data/preferences/preferences.dart';
import 'package:app/data/transport/connection_manager.dart';
import 'package:app/data/transport/relay_config.dart';
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
const _corruptMembershipError = 'corrupt-membership-snapshot';
class _BootState extends ChangeNotifier {
  bool _ready = false;
  bool _hasPeer = false;
  bool _onboarded = false;
  bool _syncAvailable = true;
  bool _identityWasGenerated = false;
  String? _storageError;
  String _phase = 'starting';
  int _loadGeneration = 0;
  final int startedAtMs = DateTime.now().millisecondsSinceEpoch;

  String get phase => _phase;
  bool get ready => _ready;
  bool get hasPeer => _hasPeer;
  bool get onboarded => _onboarded;
  bool get syncAvailable => _syncAvailable;
  bool get identityWasGenerated => _identityWasGenerated;
  String? get storageError => _storageError;
  bool get corruptMembershipSnapshot =>
      _storageError == _corruptMembershipError;

  Future<void> load(
    PairingStorage storage,
    ConnectionManager conn,
    Preferences prefs,
    OwnerIdentityBridge ownerBridge,
    MeshSyncService meshSync, {
    void Function()? installWatcherAfterBoot,
  }) async {
    final generation = ++_loadGeneration;
    _ready = false;
    _storageError = null;
    _phase = 'identity';
    notifyListeners();

    final OwnerIdentityBootResult ownerResult;
    try {
      ownerResult = await ownerBridge.boot().timeout(
        const Duration(seconds: 4),
        onTimeout: () => const SyncUnavailableResult(),
      );
    } catch (_) {
      if (generation != _loadGeneration) return;
      _syncAvailable = false;
      _ready = true;
      _phase = 'identity-unavailable';
      notifyListeners();
      return;
    }
    if (generation != _loadGeneration) return;
    if (ownerResult is! IdentityReady) {
      _syncAvailable = false;
      _ready = true;
      _phase = 'identity-unavailable';
      notifyListeners();
      return;
    }

    _syncAvailable = true;
    _identityWasGenerated = ownerResult.generated;
    _phase = 'local-storage';
    try {
      await storage.initialize(
        ownerPk: ownerResult.identity.ownerPk,
        relayUrl: resolveRelayUrl(prefs),
      );
      if (generation != _loadGeneration) return;
      installWatcherAfterBoot?.call();

      final peers = await storage.listPeers();
      if (generation != _loadGeneration) return;
      _hasPeer = peers.isNotEmpty;
      if (_hasPeer && !prefs.onboardingCompleted) {
        await prefs.setOnboardingCompleted(true);
      }
      if (generation != _loadGeneration) return;
      _onboarded = prefs.onboardingCompleted;

      String? selected;
      if (peers.isNotEmpty) {
        selected = prefs.selectedPeerEpk;
        if (selected == null ||
            !peers.any((peer) => peer.remoteEpk == selected)) {
          selected = peers.first.remoteEpk;
          await prefs.setSelectedPeerEpk(selected);
        }
      }
      if (generation != _loadGeneration) return;

      // Hydrate the durable room index before routing to Home. This is local
      // SQLite work only: cached sessions remain available even when the
      // relay is unreachable, and a corrupt cache read reaches the retry UI.
      _phase = 'cached-sessions';
      await conn.ensureCachedRoomsRestored();
      if (generation != _loadGeneration) return;

      _ready = true;
      _phase = 'done';
      notifyListeners();

      // Network work starts only after durable state is visible. Failure is a
      // disconnected status, never an empty peer inventory.
      meshSync.startPolling();
      if (selected != null) {
        unawaited(conn.boot(preferredEpk: selected));
      }
      unawaited(
        _synchronizeAndReconcile(
          generation: generation,
          storage: storage,
          connection: conn,
          preferences: prefs,
          meshSync: meshSync,
          selectedBeforeSync: selected,
        ),
      );
    } catch (error) {
      if (generation != _loadGeneration) return;
      _hasPeer = false;
      _onboarded = false;
      _storageError = error.toString();
      _ready = true;
      _phase = 'storage-error';
      notifyListeners();
    }
  }

  Future<void> _synchronizeAndReconcile({
    required int generation,
    required PairingStorage storage,
    required ConnectionManager connection,
    required Preferences preferences,
    required MeshSyncService meshSync,
    required String? selectedBeforeSync,
  }) async {
    bool synchronized;
    try {
      synchronized = await meshSync.synchronize();
    } catch (_) {
      return;
    }
    if (generation != _loadGeneration) return;
    if (meshSync.lastProblem == MeshSyncProblem.corruptStoredSnapshot) {
      onMeshProblem(meshSync.lastProblem);
      return;
    }
    if (!synchronized) return;

    final peers = await storage.listPeers();
    if (generation != _loadGeneration) return;
    final hadPeer = _hasPeer;
    _hasPeer = peers.isNotEmpty;

    String? selected;
    if (peers.isNotEmpty) {
      selected = preferences.selectedPeerEpk;
      if (selected == null ||
          !peers.any((peer) => peer.remoteEpk == selected)) {
        selected = peers.first.remoteEpk;
        await preferences.setSelectedPeerEpk(selected);
      }
      if (!preferences.onboardingCompleted) {
        await preferences.setOnboardingCompleted(true);
      }
    } else {
      await preferences.setSelectedPeerEpk(null);
    }
    if (generation != _loadGeneration) return;
    _onboarded = preferences.onboardingCompleted;
    notifyListeners();

    if (selected == null) {
      if (hadPeer) {
        await connection.reconnect();
      }
      return;
    }
    if (selectedBeforeSync == null) {
      await connection.boot(preferredEpk: selected);
    } else if (selected != selectedBeforeSync) {
      await connection.reconnect(preferredEpk: selected);
    } else {
      connection.subscribeToPeers(peers.map((peer) => peer.remoteEpk).toList());
    }
  }

  void onMeshProblem(MeshSyncProblem? problem) {
    if (problem != MeshSyncProblem.corruptStoredSnapshot ||
        _storageError == _corruptMembershipError) {
      return;
    }
    _storageError = _corruptMembershipError;
    _ready = true;
    _phase = 'membership-sync-error';
    notifyListeners();
  }

  void onOwnerKeyReplaced() {
    _ready = false;
    _hasPeer = false;
    _onboarded = false;
    _storageError = null;
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
  void onMeshChanged() => boot.onMeshProblem(meshSync.lastProblem);

  meshSync.addListener(onMeshChanged);
  onMeshChanged();

  var watcherInstalled = false;
  late final Future<void> Function() loadBoot;

  void installWatcher() {
    if (watcherInstalled) return;
    watcherInstalled = true;
    ownerBridge.startWatching(
      onBeforeReset: conn.disconnect,
      onReset: () async {
        boot.onOwnerKeyReplaced();
        await loadBoot();
      },
    );
  }

  loadBoot = () => boot.load(
        storage,
        conn,
        prefs,
        ownerBridge,
        meshSync,
        installWatcherAfterBoot: installWatcher,
      );

  unawaited(loadBoot());

  return GoRouter(
    initialLocation: '/boot',
    refreshListenable: boot,
    redirect: (context, state) {
      if (!boot.ready) return '/boot';
      if (boot.storageError != null) {
        return state.uri.path == '/storage-error' ? null : '/storage-error';
      }
      if (!boot.syncAvailable) {
        return state.uri.path == '/sync-required' ? null : '/sync-required';
      }
      final shouldOnboard =
          !boot.hasPeer && (boot.identityWasGenerated || !boot.onboarded);
      final target = shouldOnboard ? '/onboarding' : '/home';
      if (state.uri.path == '/sync-required' ||
          state.uri.path == '/storage-error' ||
          state.uri.path == '/boot') {
        return target;
      }
      return null;
    },
    routes: [
      // Splash while boot.load() is in flight
      GoRoute(path: '/boot', builder: (ctx, st) => _BootSplash(boot: boot)),

      GoRoute(
        path: '/storage-error',
        builder: (ctx, st) => _StorageFailurePage(
          onRetry: loadBoot,
          membershipSyncCorrupt: boot.corruptMembershipSnapshot,
        ),
      ),

      // Plan 23 — first-launch gate when iCloud Keychain / Google
      // Backup is off. Sticky route: redirect keeps the user here
      // until the bridge reports sync available.
      GoRoute(
        path: '/sync-required',
        builder: (ctx, st) => SyncRequiredPage(onCheck: loadBoot),
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

/// Splash with a boot watchdog: after 3 s it shows the current boot
/// phase and an elapsed-seconds counter (ticking from a Dart timer).
///
/// Diagnostic contract for the intermittent "stuck on splash" reports:
///  • counter ticking, phase label stuck  → Dart alive; that step's
///    await never completed (platform channel dropped).
///  • counter frozen                      → platform main thread
///    blocked (native), or the rasterizer died — no Dart fix applies.
class _BootSplash extends StatefulWidget {
  final _BootState boot;
  const _BootSplash({required this.boot});

  @override
  State<_BootSplash> createState() => _BootSplashState();
}

class _BootSplashState extends State<_BootSplash> {
  Timer? _ticker;
  int _elapsed = 0;

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() => _elapsed += 1);
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(LucideIcons.radio, size: 40, color: colors.accent),
            const SizedBox(height: 16),
            Text(
              'Remote Pi',
              style: TextStyle(
                fontFamily: kMonoFamily,
                fontSize: 18,
                fontWeight: FontWeight.w600,
                color: colors.text,
              ),
            ),
            const SizedBox(height: 24),
            SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(
                color: colors.accent,
                strokeWidth: 2,
              ),
            ),
            if (_elapsed >= 3) ...[
              const SizedBox(height: 24),
              Text(
                'initialising: ${widget.boot.phase} · ${_elapsed}s',
                key: const Key('boot-watchdog'),
                style: TextStyle(
                  fontFamily: kMonoFamily,
                  fontSize: 12,
                  color: colors.muted,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _StorageFailurePage extends StatelessWidget {
  const _StorageFailurePage({
    required this.onRetry,
    required this.membershipSyncCorrupt,
  });

  final Future<void> Function() onRetry;
  final bool membershipSyncCorrupt;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Column(
                key: const Key('storage-boot-error'),
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(LucideIcons.database, size: 40, color: colors.warning),
                  const SizedBox(height: 16),
                  Text(
                    membershipSyncCorrupt
                        ? "Pairing sync data couldn't be verified"
                        : "Couldn't open saved data",
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontFamily: kMonoFamily,
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                      color: colors.text,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    membershipSyncCorrupt
                        ? 'Connect to your relay and retry. Your cached '
                            'pairings and history were left unchanged.'
                        : 'Your existing pairings and history were left '
                            'unchanged.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: colors.muted),
                  ),
                  const SizedBox(height: 20),
                  FilledButton.icon(
                    key: const Key('storage-boot-retry'),
                    onPressed: () => unawaited(onRetry()),
                    icon: const Icon(LucideIcons.refreshCw),
                    label: const Text('Retry'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
