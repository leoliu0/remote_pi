import 'dart:async';
import 'dart:convert';

import 'package:app/data/local/app_database.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

const legacyPeersService = 'dev.remotepi.peers';
const legacyRoomsService = 'dev.remotepi.rooms';
const legacyPeersIndexKey = 'dev.remotepi.peers_index';
const legacyPairingImportSource = 'pairing.secure_storage';

final class PairingMigrationException implements Exception {
  final String message;
  final Object? cause;

  const PairingMigrationException(this.message, [this.cause]);

  @override
  String toString() => cause == null
      ? 'PairingMigrationException: $message'
      : 'PairingMigrationException: $message ($cause)';
}

final class LegacyPairingEntry {
  final String storageEpk;
  final Map<String, dynamic> peerJson;
  final List<Map<String, dynamic>> roomsJson;

  const LegacyPairingEntry({
    required this.storageEpk,
    required this.peerJson,
    required this.roomsJson,
  });
}

final class LegacyPairingInventory {
  final List<LegacyPairingEntry> entries;
  final int sourceVersion;
  final String fingerprint;

  const LegacyPairingInventory({
    required this.entries,
    required this.sourceVersion,
    required this.fingerprint,
  });

  int get rowCount => entries.fold<int>(
        0,
        (count, entry) => count + 1 + entry.roomsJson.length,
      );
}

/// One-time reader for peer metadata that older app versions kept in secure
/// storage. Legacy values are deliberately never modified or deleted.
final class LegacyPairingMigration {
  final AppDatabase _database;
  final FlutterSecureStorage _legacyStore;
  final Duration readTimeout;

  const LegacyPairingMigration(
    this._database,
    this._legacyStore, {
    this.readTimeout = const Duration(seconds: 4),
  });

  Future<void> run({
    required void Function(LegacyPairingInventory inventory) importRows,
    bool Function()? shouldCommit,
  }) async {
    if (_isComplete()) return;

    final LegacyPairingInventory inventory;
    try {
      inventory = await _readInventory();
    } on PairingMigrationException {
      rethrow;
    } catch (error) {
      throw PairingMigrationException('Could not read legacy pairing data', error);
    }
    if (shouldCommit != null && !shouldCommit()) return;

    try {
      _database.transaction(() {
        if (_isComplete() ||
            (shouldCommit != null && !shouldCommit())) {
          return;
        }
        importRows(inventory);
        _database.db.execute(
          '''
            INSERT INTO legacy_imports(
              source, source_version, completed_at_ms, row_count, fingerprint
            ) VALUES (?, ?, ?, ?, ?)
          ''',
          <Object?>[
            legacyPairingImportSource,
            inventory.sourceVersion,
            DateTime.now().toUtc().millisecondsSinceEpoch,
            inventory.rowCount,
            inventory.fingerprint,
          ],
        );
      });
    } on PairingMigrationException {
      rethrow;
    } catch (error) {
      throw PairingMigrationException(
        'Legacy pairing data was invalid; nothing was imported',
        error,
      );
    }
  }

  bool _isComplete() => _database.db.select(
        'SELECT 1 FROM legacy_imports WHERE source = ? LIMIT 1',
        <Object?>[legacyPairingImportSource],
      ).isNotEmpty;

  Future<LegacyPairingInventory> _readInventory() async {
    final String? rawIndex;
    try {
      rawIndex = await _legacyStore
          .read(key: legacyPeersIndexKey)
          .timeout(readTimeout);
    } catch (error) {
      throw PairingMigrationException(
        'Legacy peer inventory is unreadable. Existing data was preserved.',
        error,
      );
    }

    if (rawIndex != null) {
      return _readIndexedInventory(rawIndex);
    }
    return _readEnumeratedInventory();
  }

  Future<LegacyPairingInventory> _readIndexedInventory(String rawIndex) async {
    final List<String> indexedEpks;
    try {
      final decoded = jsonDecode(rawIndex);
      if (decoded is! List || decoded.any((value) => value is! String)) {
        throw const FormatException('peer index must be a list of strings');
      }
      indexedEpks = decoded.cast<String>().toSet().toList()..sort();
    } catch (error) {
      throw PairingMigrationException(
        'Legacy peer inventory is corrupt. Existing data was preserved.',
        error,
      );
    }

    final entries = <LegacyPairingEntry>[];
    for (final epk in indexedEpks) {
      final peerKey = '$legacyPeersService:$epk';
      final String? rawPeer;
      try {
        rawPeer = await _legacyStore.read(key: peerKey).timeout(readTimeout);
      } catch (error) {
        throw PairingMigrationException(
          'Legacy peer "$epk" is unreadable. Existing data was preserved.',
          error,
        );
      }
      if (rawPeer == null) {
        throw PairingMigrationException(
          'Legacy inventory references missing peer "$epk". '
          'Existing data was preserved.',
        );
      }

      final roomsKey = '$legacyRoomsService:$epk';
      final String? rawRooms;
      try {
        rawRooms = await _legacyStore.read(key: roomsKey).timeout(readTimeout);
      } catch (error) {
        throw PairingMigrationException(
          'Legacy rooms for "$epk" are unreadable. Existing data was preserved.',
          error,
        );
      }
      entries.add(
        _decodeEntry(epk, rawPeer, rawRooms),
      );
    }
    return _inventory(entries, sourceVersion: 2);
  }

  Future<LegacyPairingInventory> _readEnumeratedInventory() async {
    final Map<String, String> all;
    try {
      all = await _legacyStore.readAll().timeout(readTimeout);
    } catch (error) {
      throw PairingMigrationException(
        'Legacy peer inventory cannot be enumerated. Existing data was preserved.',
        error,
      );
    }

    final peerPrefix = '$legacyPeersService:';
    final peerKeys = all.keys
        .where((key) => key.startsWith(peerPrefix))
        .toList(growable: false)
      ..sort();

    final entries = <LegacyPairingEntry>[
      for (final peerKey in peerKeys)
        _decodeEntry(
          peerKey.substring(peerPrefix.length),
          all[peerKey]!,
          all['$legacyRoomsService:${peerKey.substring(peerPrefix.length)}'],
        ),
    ];
    return _inventory(entries, sourceVersion: 1);
  }

  LegacyPairingEntry _decodeEntry(
    String storageEpk,
    String rawPeer,
    String? rawRooms,
  ) {
    try {
      final decodedPeer = jsonDecode(rawPeer);
      if (decodedPeer is! Map<String, dynamic>) {
        throw const FormatException('peer record must be an object');
      }
      final rooms = <Map<String, dynamic>>[];
      if (rawRooms != null) {
        final decodedRooms = jsonDecode(rawRooms);
        if (decodedRooms is! List) {
          throw const FormatException('rooms record must be a list');
        }
        for (final room in decodedRooms) {
          if (room is! Map<String, dynamic>) {
            throw const FormatException('each room must be an object');
          }
          rooms.add(room);
        }
      }
      return LegacyPairingEntry(
        storageEpk: storageEpk,
        peerJson: decodedPeer,
        roomsJson: rooms,
      );
    } catch (error) {
      throw PairingMigrationException(
        'Legacy data for "$storageEpk" is corrupt. Existing data was preserved.',
        error,
      );
    }
  }

  Future<LegacyPairingInventory> _inventory(
    List<LegacyPairingEntry> entries, {
    required int sourceVersion,
  }) async {
    final canonical = <Object?>[
      for (final entry in entries)
        <String, Object?>{
          'storage_epk': entry.storageEpk,
          'peer': entry.peerJson,
          'rooms': entry.roomsJson,
        },
    ];
    final digest = await Sha256().hash(utf8.encode(jsonEncode(canonical)));
    return LegacyPairingInventory(
      entries: List<LegacyPairingEntry>.unmodifiable(entries),
      sourceVersion: sourceVersion,
      fingerprint: base64Url.encode(digest.bytes).replaceAll('=', ''),
    );
  }
}
