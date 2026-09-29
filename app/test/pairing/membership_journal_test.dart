import 'dart:typed_data';

import 'package:app/data/local/app_database.dart';
import 'package:app/pairing/membership_journal.dart';
import 'package:flutter_test/flutter_test.dart';

final _scope = MembershipScope(
  ownerPk: Uint8List.fromList(List<int>.generate(32, (i) => i + 1)),
  relayUrl: 'wss://Relay.Example.test/',
);

const _alpha = MembershipMember(
  remoteEpk: 'alpha',
  relayUrl: 'wss://relay.example.test',
  pairedAt: '2026-09-01T00:00:00Z',
  nickname: 'Alpha',
);

const _beta = MembershipMember(
  remoteEpk: 'beta',
  relayUrl: 'wss://relay.example.test',
  pairedAt: '2026-09-02T00:00:00Z',
  nickname: 'Beta',
);

void main() {
  test('scope canonicalizes owner bytes and relay URL', () {
    final equivalent = MembershipScope(
      ownerPk: Uint8List.fromList(List<int>.generate(32, (i) => i + 1)),
      relayUrl: 'https://relay.example.test',
    );
    expect(equivalent, _scope);
    expect(equivalent.relayUrl, 'https://relay.example.test');
  });

  test('rebase applies explicit operations without unioning cached peers', () {
    final result = MembershipJournal.rebase(
      <MembershipMember>[_alpha, _beta],
      <MembershipOperation>[
        const MembershipOperation(
          sequence: 1,
          kind: MembershipOperationKind.revoke,
          remoteEpk: 'beta',
        ),
        const MembershipOperation(
          sequence: 2,
          kind: MembershipOperationKind.rename,
          remoteEpk: 'alpha',
          nickname: 'Renamed alpha',
        ),
        const MembershipOperation(
          sequence: 3,
          kind: MembershipOperationKind.enroll,
          remoteEpk: 'gamma',
          relayUrl: 'wss://relay.example.test',
          pairedAt: '2026-09-03T00:00:00Z',
          nickname: 'Gamma',
        ),
      ],
    );

    expect(result.map((member) => member.remoteEpk), <String>['alpha', 'gamma']);
    expect(result.first.nickname, 'Renamed alpha');
  });

  test('rename of remotely absent peer never resurrects it', () {
    final result = MembershipJournal.rebase(
      const <MembershipMember>[],
      const <MembershipOperation>[
        MembershipOperation(
          sequence: 1,
          kind: MembershipOperationKind.rename,
          remoteEpk: 'revoked-elsewhere',
          nickname: 'Must stay gone',
        ),
      ],
    );
    expect(result, isEmpty);
  });

  test('fresh snapshot supersedes only absent renames, not enroll intent', () {
    const operations = <MembershipOperation>[
      MembershipOperation(
        sequence: 1,
        kind: MembershipOperationKind.rename,
        remoteEpk: 'remote-revoked',
        nickname: 'Stale rename',
      ),
      MembershipOperation(
        sequence: 2,
        kind: MembershipOperationKind.enroll,
        remoteEpk: 'locally-enrolled',
        relayUrl: 'wss://relay.example.test',
        pairedAt: '2026-09-03T00:00:00Z',
      ),
      MembershipOperation(
        sequence: 3,
        kind: MembershipOperationKind.rename,
        remoteEpk: 'locally-enrolled',
        nickname: 'Keep me',
      ),
    ];

    expect(
      MembershipJournal.supersededRenameSequences(
        const <MembershipMember>[],
        operations,
      ),
      <int>[1],
    );
  });

  test('acknowledging a captured batch leaves later operations durable', () {
    final database = AppDatabase.memory();
    addTearDown(database.dispose);
    final journal = MembershipJournal(database)..ensureSchema();

    final enroll = journal.appendEnroll(_scope, _alpha);
    final captured = journal.pending(_scope);
    final rename = journal.appendRename(_scope, 'alpha', 'Newest');

    expect(enroll, lessThan(rename));
    journal.acknowledge(_scope, captured.map((operation) => operation.sequence));

    final remaining = journal.pending(_scope);
    expect(remaining, hasLength(1));
    expect(remaining.single.sequence, rename);
    expect(remaining.single.nickname, 'Newest');
  });

  test('operation sequence remains monotonic across journal instances', () {
    final database = AppDatabase.memory();
    addTearDown(database.dispose);
    final first = MembershipJournal(database)..ensureSchema();
    final firstSequence = first.appendEnroll(_scope, _alpha);

    final second = MembershipJournal(database)..ensureSchema();
    final secondSequence = second.appendRevoke(_scope, 'alpha');

    expect(secondSequence, greaterThan(firstSequence));
    expect(second.pending(_scope).map((operation) => operation.sequence),
        <int>[firstSequence, secondSequence]);
  });
}
