import 'dart:async';
import 'dart:io' show Platform;

import 'package:app/config/utils/injector.dart';
import 'package:app/data/actions/actions_repository.dart';
import 'package:app/data/mesh/mesh_client.dart';
import 'package:app/data/mesh/mesh_sync_service.dart';
import 'package:app/data/local/app_database.dart';
import 'package:app/data/local/session_store.dart';
import 'package:app/data/preferences/preferences.dart';
import 'package:app/data/repositories/home_read_repository.dart';
import 'package:app/data/repositories/session_read_repository.dart';
import 'package:app/data/sync/sync_service.dart';
import 'package:app/data/transport/channel.dart'; // IChannel
import 'package:app/data/transport/connection_manager.dart';
import 'package:app/data/transport/peer_channel.dart';
import 'package:app/data/images/image_picker_service.dart';
import 'package:app/data/transport/relay_config.dart';
import 'package:app/data/transport/ws_transport.dart';
import 'package:app/data/update/secure_dismissed_update_store.dart';
import 'package:app/data/update/update_checker_impl.dart';
import 'package:app/data/update/url_launcher_opener.dart';
import 'package:app/data/voice/speech_service.dart';
import 'package:app/domain/contracts/dismissed_update_store.dart';
import 'package:app/domain/contracts/update_checker.dart';
import 'package:app/domain/contracts/url_opener.dart';
import 'package:app/pairing/owner_identity_bridge.dart';
import 'package:app/pairing/pair_request_flow.dart';
import 'package:app/pairing/qr_scanner.dart';
import 'package:app/pairing/storage.dart';
import 'package:app/routing/adaptive.dart';
import 'package:app/ui/chat/attachment/viewmodels/attachment_viewmodel.dart';
import 'package:app/ui/chat/quick_actions/viewmodels/quick_actions_viewmodel.dart';
import 'package:app/ui/chat/viewmodels/chat_viewmodel.dart';
import 'package:app/ui/chat/voice/viewmodels/voice_input_viewmodel.dart';
import 'package:app/ui/core/viewmodel/viewmodel.dart';
import 'package:app/ui/home/viewmodels/home_viewmodel.dart';
import 'package:app/ui/onboarding/viewmodels/onboarding_viewmodel.dart';
import 'package:app/ui/pairing/viewmodels/pairing_viewmodel.dart';
import 'package:app/ui/settings/viewmodels/settings_viewmodel.dart';
import 'package:app/ui/update/viewmodels/update_banner_viewmodel.dart';
import 'package:cryptography/cryptography.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';
import 'package:remote_pi_identity/remote_pi_identity.dart';

CustomInjector _injector = CustomInjector();

/// Direct injector access — only for bootstrap, tests, and deep-link handlers.
CustomInjector get injector => _injector;

Future<void> setupDependencies() async {
  final next = CustomInjector();
  try {
    final database = AppDatabase.instance;
    next.addInstance<AppDatabase>(
      database,
      onDispose: (value) => value.dispose(),
    );

    final prefs = Preferences(database);
    await prefs.load();
    next.addInstance<Preferences>(
      prefs,
      onDispose: (value) => value.dispose(),
    );

    final pairingStorage = PairingStorage(database);
    next.addInstance<PairingStorage>(
      pairingStorage,
      onDispose: (value) => value.dispose(),
    );

    final sessionStore = SessionStore(database);
    next.addInstance<SessionStore>(
      sessionStore,
      onDispose: (value) => value.dispose(),
    );

    // The native identity store and key format remain unchanged. Pairing
    // metadata is initialized later, once router boot has the owner key.
    final OwnerIdentityStore ownerStore = MethodChannelOwnerIdentityStore();
    next.addInstance<OwnerIdentityStore>(ownerStore);
    final ownerBridge = OwnerIdentityBridge(ownerStore, pairingStorage);
    next.addInstance<OwnerIdentityBridge>(
      ownerBridge,
      onDispose: (value) => value.dispose(),
    );

    final meshClient = MeshClient(baseUrlProvider: () => resolveRelayUrl(prefs));
    next.addInstance<MeshClient>(meshClient);
    final meshSync = MeshSyncService(meshClient, ownerBridge, pairingStorage);
    next.addInstance<MeshSyncService>(
      meshSync,
      onDispose: (value) => value.dispose(),
    );
    pairingStorage.attachPeerMutationHook(() {
      unawaited(meshSync.drainPending());
    });

    next.addService<ConnectionManager>(
      () => ConnectionManager(
        factory: _productionConnectionFactory,
        storage: pairingStorage,
      ),
    );

    next.addService<SpeechService>(() => SpeechToTextService());
    next.addOther<IImagePickerService>(() => ImagePickerService());

    next.addService<SyncService>(
      () => SyncService(next.get<ConnectionManager>(), sessionStore),
    );
    next.addRepository<SessionReadRepository>(
      () => SessionReadRepository(sessionStore),
    );
    next.addRepository<HomeReadRepository>(
      () => HomeReadRepository(sessionStore),
    );
    next.addRepository<IActionsRepository>(
      () => ActionsRepository(next.get<ConnectionManager>()),
    );

    next.addViewModel<ChatViewModel>(
      () => ChatViewModel(
        next.get<SessionReadRepository>(),
        next.get<SyncService>(),
        next.get<ConnectionManager>(),
        prefs,
        pairingStorage,
      ),
    );
    next.addViewModel<HomeViewModel>(
      () => HomeViewModel(
        pairingStorage,
        prefs,
        next.get<ConnectionManager>(),
      ),
    );
    next.addViewModel<SettingsViewModel>(
      () => SettingsViewModel(
        pairingStorage,
        prefs,
        next.get<ConnectionManager>(),
        meshSync,
        ownerBridge,
      ),
    );
    next.addViewModel<PairingViewModel>(
      () => PairingViewModel(
        pairingStorage,
        _productionPairingTransportFactory,
        next.get<ConnectionManager>(),
        prefs,
        ownerBridge,
      ),
    );
    next.addViewModel<OnboardingViewModel>(OnboardingViewModel.new);
    next.addViewModel<QuickActionsViewModel>(
      () => QuickActionsViewModel(next.get<IActionsRepository>()),
    );
    next.addViewModel<VoiceInputViewModel>(
      () => VoiceInputViewModel(next.get<SpeechService>()),
    );
    next.addViewModel<AttachmentViewModel>(
      () => AttachmentViewModel(
        next.get<IImagePickerService>(),
        next.get<IActionsRepository>(),
      ),
    );

    next.addInstance<SessionSelection>(
      SessionSelection(),
      onDispose: (value) => value.dispose(),
    );
    next.addInstance<ShellLayout>(
      ShellLayout(),
      onDispose: (value) => value.dispose(),
    );

    var appVersion = '1.2.41';
    try {
      final packageInfo = await PackageInfo.fromPlatform().timeout(
        const Duration(milliseconds: 500),
      );
      appVersion = packageInfo.version;
    } catch (_) {}
    next.addOther<UpdateChecker>(() => UpdateCheckerImpl());
    next.addOther<DismissedUpdateStore>(
      () => SecureDismissedUpdateStore(),
    );
    next.addOther<UrlOpener>(() => const UrlLauncherOpener());
    next.addViewModel<UpdateBannerViewModel>(
      () => UpdateBannerViewModel(
        next.get<UpdateChecker>(),
        next.get<DismissedUpdateStore>(),
        next.get<UrlOpener>(),
        currentVersion: appVersion,
        enabled: Platform.isAndroid,
      ),
    );

    next.commit();
  } catch (_) {
    next.dispose();
    rethrow;
  }

  final previous = _injector;
  _injector = next;
  previous.dispose();
}

// ---------------------------------------------------------------------------
// Production ConnectionFactory — used by ConnectionManager for reconnection.
// Post-rollback: just open transport + wrap in PlainPeerChannel; Pi recognizes
// the peer via peers.json (no per-reconnect handshake).
// Plan 23: Owner-sk (synced via iCloud Keychain / Block Store) is the
// challenge-response key. OwnerIdentityBridge.boot() is the router's
// responsibility; by the time this factory runs, the identity is loaded.
// ---------------------------------------------------------------------------

Future<IChannel> _productionConnectionFactory(
  PeerRecord peer,
  CancelToken cancel,
) async {
  final bridge = injector.get<OwnerIdentityBridge>();
  final ownerKey = await bridge.requireKeyPair();
  if (cancel.isCancelled) throw _CancelledError();

  // Defensive timeout (plano app-state-normalization): without this the
  // WebSocket connect + Ed25519 challenge round-trip can hang
  // indefinitely if the relay is unreachable — ChatViewModel would sit
  // in `ChatConnecting` forever. Throwing here pushes the manager into
  // its retry/backoff path, which is observable as `StatusRetrying` and
  // renders a "reconnecting" banner rather than an empty spinner.
  const wsConnectTimeout = Duration(seconds: 10);
  // Resolve the GLOBAL relay URL (plan 14): user override > default.
  // `peer.relayUrl` is kept on PeerRecord for legacy QR payloads but is
  // no longer consulted when opening a connection.
  final relayUrl = resolveRelayUrl(_injector.get<Preferences>());
  final transport =
      await WsTransport.connect(
        relayUrl: relayUrl,
        peerPubkey: peer.remoteEpk,
        ed25519Key: ownerKey,
      ).timeout(
        wsConnectTimeout,
        onTimeout: () => throw TimeoutException(
          'WS connect to $relayUrl timed out after '
          '${wsConnectTimeout.inSeconds}s',
        ),
      );

  if (cancel.isCancelled) {
    await transport.close();
    throw _CancelledError();
  }

  return PlainPeerChannel(transport: transport);
}

// ---------------------------------------------------------------------------
// Production PairingTransportFactory — used by PairingViewModel for first pair.
// ---------------------------------------------------------------------------

Future<PeerTransport> _productionPairingTransportFactory(
  QrPairPayload qr,
  SimpleKeyPair deviceEd25519,
) async {
  // Plan 14: pairing connects via the GLOBAL relay URL (Preferences),
  // not whatever was embedded in the QR. Mismatch between qr.relayUrl
  // and the user's configured relay is handled upstream by
  // `pair_request_flow.dart` (raises a `relay_mismatch` error that
  // PairingViewModel surfaces as a "trocar relay?" modal).
  final relayUrl = resolveRelayUrl(_injector.get<Preferences>());
  return WsTransport.connect(
    relayUrl: relayUrl,
    peerPubkey: qr.epk,
    ed25519Key: deviceEd25519,
  );
}

// ---------------------------------------------------------------------------

class _CancelledError implements Exception {
  const _CancelledError();
}

void disposeDependencies() {
  final current = _injector;
  _injector = CustomInjector();
  current.dispose();
}

/// Bridges auto_injector and provider: creates a `ChangeNotifierProvider` that
/// asks the injector for a fresh `ViewModel<T>` instance on each route mount.
class ViewmodelProvider<T extends ViewModel> extends ChangeNotifierProvider<T> {
  ViewmodelProvider({super.key, super.child})
    : super(create: (_) => _injector.get<T>());

  ViewmodelProvider.value({super.key, required super.value, super.child})
    : super.value();
}
