import 'package:app/data/local/app_database.dart';
import 'package:app/data/local/preference_store.dart';
import 'package:app/ui/core/themes/app_font_family.dart';
import 'package:app/ui/core/themes/app_font_scale.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show ThemeMode;

/// Display mode for tool calls in the chat view.
enum ToolCallDisplay {
  full('Full'),
  brief('Brief'),
  hidden('Hidden');

  const ToolCallDisplay(this.label);

  final String label;

  static ToolCallDisplay fromName(String? raw) {
    for (final value in ToolCallDisplay.values) {
      if (value.name == raw) return value;
    }
    if (raw == 'true') return ToolCallDisplay.hidden;
    if (raw == 'false') return ToolCallDisplay.full;
    return ToolCallDisplay.brief;
  }
}

/// App-wide UI preferences backed only by the initialized SQLite database.
///
/// Secure storage, the old Hive box, and `relay_url.txt` are read by the
/// one-time legacy importer; runtime writes never dual-write those sources.
class Preferences extends ChangeNotifier {
  Preferences(AppDatabase database) : _store = PreferenceStore(database);

  final PreferenceStore _store;

  ToolCallDisplay _toolCallDisplay = ToolCallDisplay.brief;
  String? _selectedPeerEpk;
  String? _relayUrl;
  bool _onboardingCompleted = false;
  ThemeMode _themeMode = ThemeMode.system;
  AppFontScale _fontScale = AppFontScale.large;
  AppFontFamily _fontFamily = AppFontFamily.jetbrainsMono;
  final Map<String, String> _drafts = <String, String>{};

  static const String _hideToolCallsKey = 'prefs.hide_tool_calls';
  static const String _selectedPeerEpkKey = 'prefs.selected_peer_epk';
  static const String _relayUrlKey = 'prefs.relay_url';
  static const String _onboardingCompletedKey = 'prefs.onboarding_completed';
  static const String _themeModeKey = 'prefs.theme_mode';
  static const String _fontScaleKey = 'prefs.font_scale';
  static const String _fontFamilyKey = 'prefs.font_family';
  static const String _toolCallDisplayKey = 'prefs.tool_call_display';
  static const String _draftPrefix = 'prefs.draft.';

  bool get hideToolCalls => _toolCallDisplay == ToolCallDisplay.hidden;

  ToolCallDisplay get toolCallDisplay => _toolCallDisplay;

  /// Epoch of the selected peer. The persisted representation can include a
  /// `:roomId` suffix for room-aware navigation.
  String? get selectedPeerEpk {
    final raw = _selectedPeerEpk;
    if (raw == null) return null;
    final separator = raw.indexOf(':');
    return separator < 0 ? raw : raw.substring(0, separator);
  }

  String? get selectedRoomId {
    final raw = _selectedPeerEpk;
    if (raw == null) return null;
    final separator = raw.indexOf(':');
    if (separator < 0) return null;
    final room = raw.substring(separator + 1);
    return room.isEmpty ? null : room;
  }

  String? get selectedRoomRaw => _selectedPeerEpk;

  String? get relayUrl => _relayUrl;

  bool get onboardingCompleted => _onboardingCompleted;

  ThemeMode get themeMode => _themeMode;

  AppFontScale get fontScale => _fontScale;

  AppFontFamily get fontFamily => _fontFamily;

  static String _draftKey(String? peerEpk, String? roomId) =>
      '$_draftPrefix${peerEpk ?? ''}:${roomId ?? 'main'}';

  String getDraft(String? peerEpk, String? roomId) =>
      _drafts[_draftKey(peerEpk, roomId)] ?? '';

  /// Draft writes are synchronous so a process kill immediately after an edit
  /// cannot leave the in-memory value ahead of durable state.
  void setDraft(String? peerEpk, String? roomId, String text) {
    final key = _draftKey(peerEpk, roomId);
    if ((_drafts[key] ?? '') == text) return;
    if (text.isEmpty) {
      _store.delete(key);
      _drafts.remove(key);
    } else {
      _store.put(key, text);
      _drafts[key] = text;
    }
  }

  void clearDraft(String? peerEpk, String? roomId) {
    setDraft(peerEpk, roomId, '');
  }

  /// Hydrates the in-memory projection. Database read errors intentionally
  /// propagate so startup can show a recoverable storage error instead of
  /// presenting defaults as if the user's data were empty.
  Future<void> load() async {
    final values = _store.all();
    var changed = false;

    final rawDisplay = values[_toolCallDisplayKey];
    final legacyHidden = values[_hideToolCallsKey];
    final nextDisplay = rawDisplay != null
        ? ToolCallDisplay.fromName(rawDisplay)
        : (legacyHidden == 'true'
              ? ToolCallDisplay.hidden
              : ToolCallDisplay.brief);
    if (_toolCallDisplay != nextDisplay) {
      _toolCallDisplay = nextDisplay;
      changed = true;
    }

    final selectedRaw = values[_selectedPeerEpkKey];
    final nextSelected = selectedRaw == null || selectedRaw.isEmpty
        ? null
        : selectedRaw;
    if (_selectedPeerEpk != nextSelected) {
      _selectedPeerEpk = nextSelected;
      changed = true;
    }

    final relayRaw = values[_relayUrlKey];
    final nextRelay = relayRaw == null || relayRaw.isEmpty ? null : relayRaw;
    if (_relayUrl != nextRelay) {
      _relayUrl = nextRelay;
      changed = true;
    }

    final nextOnboarded = values[_onboardingCompletedKey] == 'true';
    if (_onboardingCompleted != nextOnboarded) {
      _onboardingCompleted = nextOnboarded;
      changed = true;
    }

    final nextTheme = _themeModeFromString(values[_themeModeKey]);
    if (_themeMode != nextTheme) {
      _themeMode = nextTheme;
      changed = true;
    }

    final nextScale = AppFontScale.fromName(values[_fontScaleKey]);
    if (_fontScale != nextScale) {
      _fontScale = nextScale;
      changed = true;
    }

    final nextFamily = AppFontFamily.fromName(values[_fontFamilyKey]);
    if (_fontFamily != nextFamily) {
      _fontFamily = nextFamily;
      changed = true;
    }

    final nextDrafts = <String, String>{
      for (final entry in values.entries)
        if (entry.key.startsWith(_draftPrefix) && entry.value.isNotEmpty)
          entry.key: entry.value,
    };
    if (!mapEquals(_drafts, nextDrafts)) {
      _drafts
        ..clear()
        ..addAll(nextDrafts);
      changed = true;
    }

    if (changed) notifyListeners();
  }

  Future<void> setHideToolCalls(bool value) async {
    final nextDisplay = value ? ToolCallDisplay.hidden : ToolCallDisplay.full;
    if (_toolCallDisplay == nextDisplay) return;
    _store.putAll(<String, String>{
      _hideToolCallsKey: '$value',
      _toolCallDisplayKey: nextDisplay.name,
    });
    _toolCallDisplay = nextDisplay;
    notifyListeners();
  }

  Future<void> setToolCallDisplay(ToolCallDisplay value) async {
    if (_toolCallDisplay == value) return;
    _store.putAll(<String, String>{
      _toolCallDisplayKey: value.name,
      _hideToolCallsKey: '${value == ToolCallDisplay.hidden}',
    });
    _toolCallDisplay = value;
    notifyListeners();
  }

  Future<void> setFontFamily(AppFontFamily value) async {
    if (_fontFamily == value) return;
    _store.put(_fontFamilyKey, value.name);
    _fontFamily = value;
    notifyListeners();
  }

  Future<void> setSelectedPeerEpk(String? value) async {
    final cleaned = value == null || value.isEmpty ? null : value;
    if (_selectedPeerEpk == cleaned) return;
    if (cleaned == null) {
      _store.delete(_selectedPeerEpkKey);
    } else {
      _store.put(_selectedPeerEpkKey, cleaned);
    }
    _selectedPeerEpk = cleaned;
    notifyListeners();
  }

  Future<void> setSelectedRoom({String? epk, String? roomId}) async {
    if (epk == null || epk.isEmpty) {
      return setSelectedPeerEpk(null);
    }
    final composite = roomId == null || roomId.isEmpty ? epk : '$epk:$roomId';
    return setSelectedPeerEpk(composite);
  }

  Future<void> setRelayUrl(String? value) async {
    final cleaned = value == null || value.isEmpty ? null : value;
    if (_relayUrl == cleaned) return;
    if (cleaned == null) {
      _store.delete(_relayUrlKey);
    } else {
      _store.put(_relayUrlKey, cleaned);
    }
    _relayUrl = cleaned;
    notifyListeners();
  }

  Future<void> setOnboardingCompleted(bool value) async {
    if (_onboardingCompleted == value) return;
    _store.put(_onboardingCompletedKey, '$value');
    _onboardingCompleted = value;
    notifyListeners();
  }

  Future<void> setThemeMode(ThemeMode value) async {
    if (_themeMode == value) return;
    _store.put(_themeModeKey, value.name);
    _themeMode = value;
    notifyListeners();
  }

  Future<void> setFontScale(AppFontScale value) async {
    if (_fontScale == value) return;
    _store.put(_fontScaleKey, value.name);
    _fontScale = value;
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
