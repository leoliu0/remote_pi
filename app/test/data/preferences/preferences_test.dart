import 'dart:io';

import 'package:app/data/local/app_database.dart';
import 'package:app/data/preferences/preferences.dart';
import 'package:app/ui/core/themes/app_font_family.dart';
import 'package:app/ui/core/themes/app_font_scale.dart';
import 'package:flutter/material.dart' show ThemeMode;
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Preferences SQLite persistence', () {
    late AppDatabase database;

    setUp(() {
      database = AppDatabase.memory();
    });

    tearDown(() {
      database.dispose();
    });

    test('uses existing defaults before and after an empty load', () async {
      final preferences = Preferences(database);
      expect(preferences.toolCallDisplay, ToolCallDisplay.brief);
      expect(preferences.hideToolCalls, isFalse);
      expect(preferences.selectedPeerEpk, isNull);
      expect(preferences.relayUrl, isNull);
      expect(preferences.onboardingCompleted, isFalse);
      expect(preferences.themeMode, ThemeMode.system);
      expect(preferences.fontScale, AppFontScale.large);
      expect(preferences.fontFamily, AppFontFamily.jetbrainsMono);

      await preferences.load();
      expect(preferences.toolCallDisplay, ToolCallDisplay.brief);
      expect(preferences.fontScale, AppFontScale.large);
    });

    test('all settings round-trip through a new Preferences instance',
        () async {
      final first = Preferences(database);
      await first.setToolCallDisplay(ToolCallDisplay.hidden);
      await first.setSelectedRoom(epk: 'abc123', roomId: 'room-xyz');
      await first.setRelayUrl('https://custom.example.com');
      await first.setOnboardingCompleted(true);
      await first.setThemeMode(ThemeMode.dark);
      await first.setFontScale(AppFontScale.standard);
      await first.setFontFamily(AppFontFamily.firaCode);
      first.setDraft('abc123', 'room-xyz', 'unfinished text');

      final reopened = Preferences(database);
      await reopened.load();
      expect(reopened.toolCallDisplay, ToolCallDisplay.hidden);
      expect(reopened.hideToolCalls, isTrue);
      expect(reopened.selectedPeerEpk, 'abc123');
      expect(reopened.selectedRoomId, 'room-xyz');
      expect(reopened.selectedRoomRaw, 'abc123:room-xyz');
      expect(reopened.relayUrl, 'https://custom.example.com');
      expect(reopened.onboardingCompleted, isTrue);
      expect(reopened.themeMode, ThemeMode.dark);
      expect(reopened.fontScale, AppFontScale.standard);
      expect(reopened.fontFamily, AppFontFamily.firaCode);
      expect(reopened.getDraft('abc123', 'room-xyz'), 'unfinished text');
    });

    test('legacy selected peer without room still defaults at the caller',
        () async {
      database.db.execute(
        'INSERT INTO preferences(key, value) VALUES (?, ?)',
        <Object?>['prefs.selected_peer_epk', 'legacy_epk'],
      );
      final preferences = Preferences(database);
      await preferences.load();

      expect(preferences.selectedPeerEpk, 'legacy_epk');
      expect(preferences.selectedRoomId, isNull);
    });

    test('drafts are scoped, synchronously durable, and clear independently',
        () async {
      final preferences = Preferences(database);
      preferences.setDraft('peer-a', 'room-1', 'A1');
      preferences.setDraft('peer-a', 'room-2', 'A2');
      preferences.setDraft('peer-b', 'room-1', 'B1');

      final reopened = Preferences(database);
      await reopened.load();
      expect(reopened.getDraft('peer-a', 'room-1'), 'A1');
      expect(reopened.getDraft('peer-a', 'room-2'), 'A2');
      expect(reopened.getDraft('peer-b', 'room-1'), 'B1');

      reopened.clearDraft('peer-a', 'room-1');
      final afterClear = Preferences(database);
      await afterClear.load();
      expect(afterClear.getDraft('peer-a', 'room-1'), isEmpty);
      expect(afterClear.getDraft('peer-a', 'room-2'), 'A2');
    });

    test('setters notify once after a durable change and not for no-ops',
        () async {
      final preferences = Preferences(database);
      var calls = 0;
      preferences.addListener(() => calls++);

      await preferences.setFontScale(AppFontScale.small);
      expect(calls, 1);
      expect(
        database.db.select(
          'SELECT value FROM preferences WHERE key = ?',
          <Object?>['prefs.font_scale'],
        ).single['value'],
        AppFontScale.small.name,
      );

      await preferences.setFontScale(AppFontScale.small);
      expect(calls, 1);
      await preferences.setHideToolCalls(true);
      expect(calls, 2);
      await preferences.setHideToolCalls(true);
      expect(calls, 2);
    });

    test('clearing nullable settings deletes their durable rows', () async {
      final preferences = Preferences(database);
      await preferences.setSelectedRoom(epk: 'abc', roomId: 'r');
      await preferences.setRelayUrl('https://relay.example');
      await preferences.setSelectedRoom(epk: null);
      await preferences.setRelayUrl('');

      final reopened = Preferences(database);
      await reopened.load();
      expect(reopened.selectedPeerEpk, isNull);
      expect(reopened.relayUrl, isNull);
      expect(
        database.db.select(
          'SELECT key FROM preferences WHERE key IN (?, ?)',
          <Object?>['prefs.selected_peer_epk', 'prefs.relay_url'],
        ),
        isEmpty,
      );
    });

    test('preferences survive a physical SQLite close and reopen', () async {
      final directory = Directory.systemTemp.createTempSync('rp_prefs_reopen_');
      addTearDown(() => directory.deleteSync(recursive: true));
      final path = '${directory.path}/remote_pi.sqlite';
      final firstDatabase = AppDatabase.openForTest(path);
      final first = Preferences(firstDatabase);
      await first.setRelayUrl('https://durable.example');
      await first.setSelectedRoom(epk: 'peer', roomId: 'room');
      first.setDraft('peer', 'room', 'survive process death');
      firstDatabase.dispose();

      final reopenedDatabase = AppDatabase.openForTest(path);
      addTearDown(reopenedDatabase.dispose);
      final reopened = Preferences(reopenedDatabase);
      await reopened.load();
      expect(reopened.relayUrl, 'https://durable.example');
      expect(reopened.selectedRoomRaw, 'peer:room');
      expect(reopened.getDraft('peer', 'room'), 'survive process death');
    });

    test('unknown enum values fall back without erasing their source rows',
        () async {
      database.db.execute(
        'INSERT INTO preferences(key, value) VALUES (?, ?), (?, ?)',
        <Object?>[
          'prefs.font_scale',
          'gigantic',
          'prefs.font_family',
          'comic_sans',
        ],
      );
      final preferences = Preferences(database);
      await preferences.load();

      expect(preferences.fontScale, AppFontScale.large);
      expect(preferences.fontFamily, AppFontFamily.jetbrainsMono);
      expect(
        database.db.select(
          'SELECT COUNT(*) AS count FROM preferences',
        ).single['count'],
        2,
      );
    });
  });
}
