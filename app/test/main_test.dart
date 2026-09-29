import 'dart:async';

import 'package:app/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('storage bootstrap failure shows a usable retry path', (
    tester,
  ) async {
    var attempts = 0;

    Future<void> initialize() async {
      attempts++;
      if (attempts == 1) {
        throw StateError('legacy database is unreadable');
      }
    }

    await tester.pumpWidget(
      AppBootstrap(
        initialize: initialize,
        appBuilder: (_) => const MaterialApp(home: Text('Ready home')),
      ),
    );
    await tester.pump();

    expect(find.byKey(const Key('startup-error')), findsOneWidget);
    expect(find.text("Couldn't open your saved data"), findsOneWidget);
    expect(find.text('Pair your first Pi'), findsNothing);
    expect(find.byKey(const Key('startup-retry')), findsOneWidget);
    expect(find.text('Ready home'), findsNothing);

    await tester.tap(find.byKey(const Key('startup-retry')));
    await tester.pump();
    await tester.pump();

    expect(attempts, 2);
    expect(find.text('Ready home'), findsOneWidget);
    expect(find.byKey(const Key('startup-error')), findsNothing);
  });

  testWidgets(
    'hung bootstrap times out; retry wins and stale completion is ignored',
    (tester) async {
      final firstAttempt = Completer<void>();
      var attempts = 0;

      Future<void> initialize() {
        attempts++;
        if (attempts == 1) return firstAttempt.future;
        return Future<void>.value();
      }

      await tester.pumpWidget(
        AppBootstrap(
          initialize: initialize,
          appBuilder: (_) => const MaterialApp(home: Text('Recovered home')),
        ),
      );
      await tester.pump(const Duration(seconds: 31));
      await tester.pump();

      expect(find.byKey(const Key('startup-error')), findsOneWidget);
      expect(find.byKey(const Key('startup-retry')), findsOneWidget);
      expect(attempts, 1);

      await tester.tap(find.byKey(const Key('startup-retry')));
      await tester.pump();
      await tester.pump();

      expect(attempts, 2);
      expect(find.text('Recovered home'), findsOneWidget);

      firstAttempt.completeError(StateError('stale bootstrap failed late'));
      await tester.pump();

      expect(find.text('Recovered home'), findsOneWidget);
      expect(find.byKey(const Key('startup-error')), findsNothing);
    },
  );
}
