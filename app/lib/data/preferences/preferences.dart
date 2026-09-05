import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show ThemeMode;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:path_provider/path_provider.dart';

import 'package:app/data/local/boxes.dart';
import 'package:app/ui/core/themes/app_font_family.dart';
import 'package:app/ui/core/themes/app_font_scale.dart';

/// Display mode for tool calls in the chat view.
enum ToolCallDisplay {
  /// Full detail: tool header, code/command block, and outcome box.
  full('Full'),

  /// Brief single-line summary with tool and target, tap to expand.
  brief('Brief'),

  /// Hide tool calls completely from the chat list.
  hidden('Hidden');

  const ToolCallDisplay(this.label);
  final String label;

  static ToolCallDisplay fromName(String? raw) {
    for (final v in ToolCallDisplay.values) {
      if (v.name == raw) return v;
    }
    if (raw == 'true') return ToolCallDisplay.hidden;
    if (raw == 'false') return ToolCallDisplay.full;
    return ToolCallDisplay.brief;
  }
}
/// App-wide UI preferences (persisted across launches).
///
/// Extends [ChangeNotifier] so widgets can `context.watch<Preferences>()`
/// and rebuild on toggle. Backed by [FlutterSecureStorage] (same store
/// already used by pairing). Call [load] once during bootstrap before
/// the first frame to hydrate the in-memory cache.
class Preferences extends ChangeNotifier {
  final FlutterSecureStorage _store;

  /// Test seam: when set, the relay-URL file layer reads/writes this file
  /// instead of the app-support dir. `null` in production (resolved lazily).
  final File? relayFileOverride;
  File? _relayFile;
  bool _relayFileResolved = false;

  ToolCallDisplay _toolCallDisplay = ToolCallDisplay.brief;
  String? _selectedPeerEpk;
  String? _relayUrl;
  bool _onboardingCompleted = false;
  ThemeMode _themeMode = ThemeMode.system;
  AppFontScale _fontScale = AppFontScale.large;
  AppFontFamily _fontFamily = AppFontFamily.jetbrainsMono;
  final Map<String, String> _drafts = {};
  Preferences([FlutterSecureStorage? store, this.relayFileOverride])
      : _store = store ?? const FlutterSecureStorage();

  /// Plain file in the app-support dir — the durable last resort for the
  /// relay URL. Secure storage can come back empty after an Android
  /// Keystore reset and Hive can fail to open; a plain file survives both.
  /// Returns `null` when the platform channel is unavailable (unit tests).
  Future<File?> _resolveRelayFile() async {
    if (relayFileOverride != null) return relayFileOverride;
    if (_relayFileResolved) return _relayFile;
    _relayFileResolved = true;
    try {
      // Under `flutter test` (FakeAsync) a platform-channel call never
    // completes and would hang boot — skip the file layer entirely.
    if (Platform.environment['FLUTTER_TEST'] == 'true') {
      _relayFile = null;
      return _relayFile;
    }
      final dir = await getApplicationSupportDirectory().timeout(
        const Duration(seconds: 2),
      );
      _relayFile = File('${dir.path}/relay_url.txt');
    } catch (_) {
      _relayFile = null;
    }
    return _relayFile;
  }

  Future<String?> _readRelayFile() async {
    final f = await _resolveRelayFile();
    if (f == null) return null;
    try {
      final v = await f.readAsString();
      return v.isEmpty ? null : v;
    } catch (_) {
      return null;
    }
  }

  Future<void> _writeRelayFile(String? value) async {
    final f = await _resolveRelayFile();
    if (f == null) return;
    try {
      if (value == null) {
        if (await f.exists()) await f.delete();
      } else {
        await f.writeAsString(value, flush: true);
      }
    } catch (_) {}
  }

  static const _kStoreTimeout = Duration(seconds: 2);

  Future<String?> _readKey(String key) async {
    try {
      return await _store.read(key: key).timeout(_kStoreTimeout);
    } catch (_) {
      return null;
    }
  }

  Future<String?> _storeGet(Map<String, String> all, String key) async {
    if (all.containsKey(key)) return all[key];
    return _readKey(key);
  }

  Future<void> _writeKey(String key, String? value) async {
    try {
      if (value == null) {
        await _store.delete(key: key).timeout(_kStoreTimeout);
      } else {
        await _store.write(key: key, value: value).timeout(_kStoreTimeout);
      }
    } catch (_) {}
  }

  static String _draftKey(String? peerEpk, String? roomId) {
    return 'prefs.draft.${peerEpk ?? ""}:${roomId ?? "main"}';
  }

  /// Get the unsent composer draft for the given session.
  String getDraft(String? peerEpk, String? roomId) {
    final key = _draftKey(peerEpk, roomId);
    return _drafts[key] ?? '';
  }

  /// Update the unsent composer draft for the given session.
  void setDraft(String? peerEpk, String? roomId, String text) {
    final key = _draftKey(peerEpk, roomId);
    if (text.isEmpty) {
      if (_drafts.containsKey(key)) {
        _drafts.remove(key);
        _store.delete(key: key).ignore();
      }
    } else {
      if (_drafts[key] != text) {
        _drafts[key] = text;
        _store.write(key: key, value: text).ignore();
      }
    }
  }

  /// Clear the unsent composer draft for the given session (e.g. after send).
  void clearDraft(String? peerEpk, String? roomId) {
    setDraft(peerEpk, roomId, '');
  }


  static const _kHideToolCallsKey = 'prefs.hide_tool_calls';
  static const _kSelectedPeerEpkKey = 'prefs.selected_peer_epk';
  static const _kRelayUrlKey = 'prefs.relay_url';
  static const _kOnboardingCompletedKey = 'prefs.onboarding_completed';
  static const _kThemeModeKey = 'prefs.theme_mode';
  static const _kFontScaleKey = 'prefs.font_scale';
  static const _kFontFamilyKey = 'prefs.font_family';
  static const _kToolCallDisplayKey = 'prefs.tool_call_display';
  /// True → chat hides `ToolEvent` rows (only user/assistant text remain).
  bool get hideToolCalls => _toolCallDisplay == ToolCallDisplay.hidden;

  /// Tool call display mode: full, brief, or hidden.
  ToolCallDisplay get toolCallDisplay => _toolCallDisplay;
  /// Epoch of the peer the user last picked from Home — the one
  /// `/chat` will connect to when it mounts. Null = no peer selected yet
  /// (user is still browsing or hasn't paired). Persisted so reopening
  /// the app right into `/chat` (e.g. via deep-link) knows which peer.
  ///
  /// Plan 17: under the new rooms model the persisted value carries an
  /// optional `:roomId` suffix (e.g. `Bz02uLi…:main` or
  /// `Bz02uLi…:room-uuid-xyz`). The getter returns only the EPK; use
  /// [selectedRoomId] for the room half. Legacy values without the
  /// `:room` suffix transparently fall through (the value is the epk
  /// and `selectedRoomId` returns null → falls back to 'main' at the
  /// caller).
  String? get selectedPeerEpk {
    final raw = _selectedPeerEpk;
    if (raw == null) return null;
    final ix = raw.indexOf(':');
    return ix < 0 ? raw : raw.substring(0, ix);
  }

  /// Plan 17 — the room half of the persisted selected target. Returns
  /// null for legacy values (caller defaults to 'main').
  String? get selectedRoomId {
    final raw = _selectedPeerEpk;
    if (raw == null) return null;
    final ix = raw.indexOf(':');
    if (ix < 0) return null;
    final r = raw.substring(ix + 1);
    return r.isEmpty ? null : r;
  }

  /// Composite raw value (epk[:room]). Tests can inspect.
  String? get selectedRoomRaw => _selectedPeerEpk;

  /// User-configured relay URL override. `null` = use the public default
  /// (`kDefaultRelayUrl` in `relay_config.dart`). Set via Settings or
  /// during onboarding step 2 (custom relay).
  String? get relayUrl => _relayUrl;

  /// `true` after the user completed the 3-step onboarding flow at least
  /// once. Drives `/boot` redirect: false → `/onboarding`, true → `/home`.
  bool get onboardingCompleted => _onboardingCompleted;

  /// Preferred app theme. `ThemeMode.system` (default) follows the OS
  /// light/dark setting; `light` / `dark` pin it. Consumed by `MaterialApp`
  /// in `main.dart` and set from the Settings "Display" section.
  ThemeMode get themeMode => _themeMode;

  /// Preferred text size (issue #114). Applied as a `TextScaler` above the
  /// router in `main.dart`, so it scales the whole UI — including the per-widget
  /// `copyWith(fontSize: …)` overrides that a typography-only change would miss.
  AppFontScale get fontScale => _fontScale;

  /// Preferred font family for the app UI.
  AppFontFamily get fontFamily => _fontFamily;
  /// Hydrate from secure storage. Safe to call multiple times.
  Future<void> load() async {
    var changed = false;
    try {
      Map<String, String> all = {};
      try {
        all = await _store.readAll().timeout(
          const Duration(seconds: 4),
          onTimeout: () => <String, String>{},
        );
      } catch (_) {}

      final raw = await _storeGet(all, _kHideToolCallsKey);
      final rawDisplay = await _storeGet(all, _kToolCallDisplayKey);
      final toolDisplay = rawDisplay != null
          ? ToolCallDisplay.fromName(rawDisplay)
          : (raw == 'true' ? ToolCallDisplay.hidden : ToolCallDisplay.brief);
      if (toolDisplay != _toolCallDisplay) {
        _toolCallDisplay = toolDisplay;
        changed = true;
      }
      final selected = await _storeGet(all, _kSelectedPeerEpkKey);
      final cleaned =
          (selected != null && selected.isNotEmpty) ? selected : null;
      if (cleaned != _selectedPeerEpk) {
        _selectedPeerEpk = cleaned;
        changed = true;
      }
      // Relay URL — three layers, most durable first: plain file, Hive,
      // secure store. Android Keystore `readAll` can come back empty after
      // a restart and Hive can fail to open; the file survives both.
      final fileRelay = await _readRelayFile();
      final hiveRelay = _readRelayHive();
      final secureRelay = await _storeGet(all, _kRelayUrlKey);
      final relay = fileRelay ?? hiveRelay ?? secureRelay;
      final relayCleaned = (relay != null && relay.isNotEmpty) ? relay : null;
      if (relayCleaned != _relayUrl) {
        _relayUrl = relayCleaned;
        changed = true;
      }
      // Backfill the layers that missed the value so all three agree.
      if (relayCleaned != null) {
        if (fileRelay == null) await _writeRelayFile(relayCleaned);
        if (hiveRelay == null) _writeRelayHive(relayCleaned);
      }
      final onboarded = all.containsKey(_kOnboardingCompletedKey)
          ? all[_kOnboardingCompletedKey]
          : await _store.read(key: _kOnboardingCompletedKey);
      final onboardedBool = onboarded == 'true';
      if (onboardedBool != _onboardingCompleted) {
        _onboardingCompleted = onboardedBool;
        changed = true;
      }
      final theme = all.containsKey(_kThemeModeKey)
          ? all[_kThemeModeKey]
          : await _store.read(key: _kThemeModeKey);
      final themeMode = _themeModeFromString(theme);
      if (themeMode != _themeMode) {
        _themeMode = themeMode;
        changed = true;
      }
      final scaleRaw = all.containsKey(_kFontScaleKey)
          ? all[_kFontScaleKey]
          : await _store.read(key: _kFontScaleKey);
      final scale = AppFontScale.fromName(scaleRaw);
      if (scale != _fontScale) {
        _fontScale = scale;
        changed = true;
      }
      final fontFamRaw = all.containsKey(_kFontFamilyKey)
          ? all[_kFontFamilyKey]
          : await _store.read(key: _kFontFamilyKey);
      final fontFam = AppFontFamily.fromName(fontFamRaw);
      if (fontFam != _fontFamily) {
        _fontFamily = fontFam;
        changed = true;
      }
      for (final entry in all.entries) {
        if (entry.key.startsWith('prefs.draft.') && entry.value.isNotEmpty) {
          _drafts[entry.key] = entry.value;
        }
      }
    } catch (_) {}
    if (changed) notifyListeners();
  }

  Future<void> setHideToolCalls(bool value) async {
    final nextDisplay = value ? ToolCallDisplay.hidden : ToolCallDisplay.full;
    if (_toolCallDisplay == nextDisplay) return;
    _toolCallDisplay = nextDisplay;
    await _store.write(key: _kHideToolCallsKey, value: value.toString());
    await _store.write(key: _kToolCallDisplayKey, value: nextDisplay.name);
    notifyListeners();
  }

  Future<void> setToolCallDisplay(ToolCallDisplay value) async {
    if (_toolCallDisplay == value) return;
    _toolCallDisplay = value;
    await _store.write(key: _kToolCallDisplayKey, value: value.name);
    await _store.write(
      key: _kHideToolCallsKey,
      value: (value == ToolCallDisplay.hidden).toString(),
    );
    notifyListeners();
  }

  Future<void> setFontFamily(AppFontFamily value) async {
    if (_fontFamily == value) return;
    _fontFamily = value;
    await _store.write(key: _kFontFamilyKey, value: value.name);
    notifyListeners();
  }
  Future<void> setSelectedPeerEpk(String? value) async {
    final cleaned = (value != null && value.isNotEmpty) ? value : null;
    if (cleaned == _selectedPeerEpk) return;
    _selectedPeerEpk = cleaned;
    if (cleaned == null) {
      await _store.delete(key: _kSelectedPeerEpkKey);
    } else {
      await _store.write(key: _kSelectedPeerEpkKey, value: cleaned);
    }
    notifyListeners();
  }

  /// Plan 17 — persist the composite `epk:roomId` selection. Passing
  /// [roomId] = null falls back to 'main' implicitly via the getter
  /// contract. Null [epk] clears the entire selection.
  Future<void> setSelectedRoom({String? epk, String? roomId}) async {
    if (epk == null || epk.isEmpty) {
      return setSelectedPeerEpk(null);
    }
    final composite = (roomId == null || roomId.isEmpty)
        ? epk
        : '$epk:$roomId';
    return setSelectedPeerEpk(composite);
  }

  /// Set the user-configured relay URL. `null` or empty clears the
  /// override so the app falls back to `kDefaultRelayUrl`. Caller should
  /// validate via `isValidRelayUrl` first when [value] is non-null.
  Future<void> setRelayUrl(String? value) async {
    final cleaned = (value != null && value.isNotEmpty) ? value : null;
    if (cleaned == _relayUrl) return;
    _relayUrl = cleaned;
    // Persist every layer before returning: the plain file is the layer
    // that survives keystore resets, so it must not be fire-and-forget.
    await _writeRelayFile(cleaned);
    _writeRelayHive(cleaned);
    if (cleaned == null) {
      await _store.delete(key: _kRelayUrlKey);
    } else {
      await _store.write(key: _kRelayUrlKey, value: cleaned);
    }
    notifyListeners();
  }

  static const _kHiveRelayKey = 'relay_url';

  String? _readRelayHive() {
    try {
      if (!Hive.isBoxOpen(kAppPrefsBox)) return null;
      final v = Hive.box<dynamic>(kAppPrefsBox).get(_kHiveRelayKey);
      if (v is String && v.isNotEmpty) return v;
    } catch (_) {}
    return null;
  }

  void _writeRelayHive(String? value) {
    try {
      if (!Hive.isBoxOpen(kAppPrefsBox)) return;
      final box = Hive.box<dynamic>(kAppPrefsBox);
      if (value == null) {
        // ignore: unawaited_futures
        box.delete(_kHiveRelayKey);
      } else {
        // ignore: unawaited_futures
        box.put(_kHiveRelayKey, value);
      }
    } catch (_) {}
  }

  Future<void> setOnboardingCompleted(bool value) async {
    if (_onboardingCompleted == value) return;
    _onboardingCompleted = value;
    await _store.write(
      key: _kOnboardingCompletedKey,
      value: value.toString(),
    );
    notifyListeners();
  }

  /// Persist the preferred [ThemeMode]. Stored as a stable string key so the
  /// value survives enum reordering.
  Future<void> setThemeMode(ThemeMode value) async {
    if (_themeMode == value) return;
    _themeMode = value;
    await _store.write(key: _kThemeModeKey, value: value.name);
    notifyListeners();
  }

  /// Persist the preferred [AppFontScale]. Stored by `name` so the value
  /// survives enum reordering.
  Future<void> setFontScale(AppFontScale value) async {
    if (_fontScale == value) return;
    _fontScale = value;
    await _store.write(key: _kFontScaleKey, value: value.name);
    notifyListeners();
  }

  static ThemeMode _themeModeFromString(String? raw) {
    switch (raw) {
      case 'light':
        return ThemeMode.light;
      case 'dark':
        return ThemeMode.dark;
      default:
        return ThemeMode.system;
    }
  }
}
