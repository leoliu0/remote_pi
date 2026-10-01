import 'dart:async';

import 'package:app/data/transport/ws_transport.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // Live incident 2026-10-01: a relay connect that finished after the 10 s
  // timeout authenticated a socket the app never owned; it stayed open and
  // doubled every inbound frame.
  test('a connect that completes after the timeout is closed', () async {
    final pending = Completer<String>();
    final closed = <String>[];

    await expectLater(
      connectWithin(pending.future, const Duration(milliseconds: 10), (v) async {
        closed.add(v);
      }),
      throwsA(isA<TimeoutException>()),
    );
    expect(closed, isEmpty);

    pending.complete('late-socket');
    await Future<void>.delayed(Duration.zero);
    expect(closed, ['late-socket']);
  });

  test('a connect that completes in time is returned and not closed', () async {
    final closed = <String>[];
    final value = await connectWithin(
      Future.value('socket'),
      const Duration(seconds: 1),
      (v) async => closed.add(v),
    );
    expect(value, 'socket');
    expect(closed, isEmpty);
  });
}
