import 'dart:async';
import 'dart:ui' show PlatformDispatcher;

import 'package:app/config/dependencies.dart';
import 'package:app/data/local/app_database.dart';
import 'package:app/data/local/legacy_data_migrator.dart';
import 'package:app/data/mesh/mesh_sync_service.dart';
import 'package:app/data/preferences/preferences.dart';
import 'package:app/data/sync/sync_service.dart';
import 'package:app/data/transport/connection_manager.dart';
import 'package:app/pairing/owner_identity_bridge.dart';
import 'package:app/pairing/storage.dart';
import 'package:app/routing/adaptive.dart';
import 'package:app/routing/app_router.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  PlatformDispatcher.instance.onError = (error, stack) {
    debugPrint('[Main] uncaught async error: $error');
    return true;
  };
  runApp(const AppBootstrap());
}

/// Opens and migrates local storage before constructing the dependency graph.
/// Relay access is deliberately absent: cached UI can boot while offline.
Future<void> initializeApplication() async {
  try {
    await AppDatabase.initialize();
    await LegacyDataMigrator(AppDatabase.instance).migrate();
    await setupDependencies();
    injector.get<SyncService>();
  } catch (_) {
    disposeDependencies();
    rethrow;
  }
}

class AppBootstrap extends StatefulWidget {
  const AppBootstrap({super.key, this.initialize, this.appBuilder});

  final Future<void> Function()? initialize;
  final WidgetBuilder? appBuilder;

  @override
  State<AppBootstrap> createState() => _AppBootstrapState();
}

class _AppBootstrapState extends State<AppBootstrap> {
  bool _loading = true;
  bool _ready = false;
  int _attemptGeneration = 0;
  static const _startupDeadline = Duration(seconds: 30);

  @override
  void initState() {
    super.initState();
    unawaited(_start());
  }

  Future<void> _start() async {
    final generation = ++_attemptGeneration;
    setState(() {
      _loading = true;
      _ready = false;
    });
    try {
      await (widget.initialize ?? initializeApplication)().timeout(
        _startupDeadline,
        onTimeout: () => throw TimeoutException(
          'Local startup exceeded ${_startupDeadline.inSeconds}s',
        ),
      );
      if (!mounted || generation != _attemptGeneration) return;
      setState(() {
        _loading = false;
        _ready = true;
      });
    } catch (error, stack) {
      debugPrint('[Main] local startup failed: $error\n$stack');
      if (!mounted || generation != _attemptGeneration) return;
      setState(() {
        _loading = false;
        _ready = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_ready) {
      return (widget.appBuilder ?? (_) => const RemotePiApp())(context);
    }
    return MaterialApp(
      title: 'Remote Pi',
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        body: SafeArea(
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: _loading
                  ? const Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        CircularProgressIndicator(),
                        SizedBox(height: 20),
                        Text('Opening saved data…'),
                      ],
                    )
                  : Column(
                      key: const Key('startup-error'),
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.storage_rounded, size: 40),
                        const SizedBox(height: 16),
                        const Text(
                          "Couldn't open your saved data",
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 8),
                        const Text(
                          'Nothing was erased. Retry after local storage '
                          'is available.',
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 20),
                        FilledButton.icon(
                          key: const Key('startup-retry'),
                          onPressed: _start,
                          icon: const Icon(Icons.refresh_rounded),
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

class RemotePiApp extends StatefulWidget {
  const RemotePiApp({super.key});

  @override
  State<RemotePiApp> createState() => _RemotePiAppState();
}

class _RemotePiAppState extends State<RemotePiApp> with WidgetsBindingObserver {
  late final _router = buildRouter(
    injector.get<PairingStorage>(),
    injector.get<ConnectionManager>(),
    injector.get<Preferences>(),
    injector.get<OwnerIdentityBridge>(),
    injector.get<MeshSyncService>(),
  );

  StreamSubscription<ConnectionStatus>? _meshReconnectSub;
  bool _relayWasOnline = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final conn = injector.get<ConnectionManager>();
    final meshSync = injector.get<MeshSyncService>();
    _meshReconnectSub = conn.statusStream.listen((status) {
      final online = status is StatusOnline;
      if (online && !_relayWasOnline) {
        unawaited(meshSync.drainPending());
      }
      _relayWasOnline = online;
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_meshReconnectSub?.cancel());
    disposeDependencies();
    super.dispose();
  }

  /// Keep membership polling and the sole connection coordinator aligned with
  /// foreground lifecycle. Durable pending membership intent is drained on
  /// every resume; command messages are never replayed here.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final meshSync = injector.get<MeshSyncService>();
    final connMgr = injector.get<ConnectionManager>();
    switch (state) {
      case AppLifecycleState.resumed:
        meshSync.startPolling();
        unawaited(meshSync.synchronize());
        connMgr.onAppResumed();
      case AppLifecycleState.inactive:
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
      case AppLifecycleState.detached:
        meshSync.stopPolling();
    }
  }

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider<Preferences>.value(
          value: injector.get<Preferences>(),
        ),
        ChangeNotifierProvider<SessionSelection>.value(
          value: injector.get<SessionSelection>(),
        ),
        // Shell layout state — lets the adaptive shell collapse the split
        // into a single centered pane on zero-state Home (no Pi / empty).
        ChangeNotifierProvider<ShellLayout>.value(
          value: injector.get<ShellLayout>(),
        ),
      ],
      // Theme is reactive: toggling the mode in Settings notifies
      // [Preferences] → this Consumer rebuilds → MaterialApp swaps theme.
      child: Consumer<Preferences>(
        builder: (context, prefs, _) => MaterialApp.router(
          title: 'Remote Pi',
          theme: buildLightTheme(fontFamily: prefs.fontFamily),
          darkTheme: buildDarkTheme(fontFamily: prefs.fontFamily),
          themeMode: prefs.themeMode,
          routerConfig: _router,
          debugShowCheckedModeBanner: false,
          builder: (context, child) {
            if (child == null) return const SizedBox.shrink();
            return Builder(
              builder: (innerContext) {
                final media = MediaQuery.of(innerContext);
                return MediaQuery(
                  data: media.copyWith(
                    textScaler: TextScaler.linear(prefs.fontScale.factor),
                  ),
                  child: child,
                );
              },
            );
          },
        ),
      ),
    );
  }
}
