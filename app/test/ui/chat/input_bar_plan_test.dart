// Plan button: driven by the session's `plan_state`, dispatches typed
// `plan_mode` actions (never '/plan' chat text), confirms an exit that would
// discard a proposed plan with omp's own wording.

import 'dart:convert';

import 'package:app/protocol/protocol.dart';
import 'package:app/ui/chat/widgets/input_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../protocol/plan_capture_fixtures.dart';

PlanState _state(String frame) =>
    PlanState.fromJson(jsonDecode(frame) as Map<String, dynamic>);

void main() {
  final planButton = find.byKey(const Key('input-bar-plan-mode'));

  Future<({List<PlanModeAction> actions, List<String> sent})> pumpBar(
    WidgetTester tester, {
    PlanState? planState,
    bool wired = true,
  }) async {
    final actions = <PlanModeAction>[];
    final sent = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: InputBar(
            onSend: sent.add,
            planState: planState,
            onPlanMode: wired ? actions.add : null,
          ),
        ),
      ),
    );
    return (actions: actions, sent: sent);
  }

  String? tooltip(WidgetTester tester) =>
      tester.widget<IconButton>(planButton).tooltip;

  testWidgets('plan_state drives the plan button status', (tester) async {
    await pumpBar(tester);
    expect(tooltip(tester), 'Plan mode', reason: 'no plan_state yet');

    await pumpBar(tester, planState: _state(kPlanStateIdleFrame));
    expect(tooltip(tester), 'Plan mode');

    await pumpBar(tester, planState: _state(kPlanStateActiveFrame));
    expect(tooltip(tester), 'Plan mode active — tap to manage');

    await pumpBar(tester, planState: _state(kPlanStatePausedFrame));
    expect(tooltip(tester), 'Plan mode paused — tap to manage');

    await pumpBar(tester, planState: _state(kPlanStateReviewFrame));
    expect(tooltip(tester), 'Plan ready for review — tap to review');
  });

  testWidgets('no plan_mode dispatcher (offline) disables the button', (
    tester,
  ) async {
    await pumpBar(tester, wired: false);
    expect(tester.widget<IconButton>(planButton).onPressed, isNull);
  });

  testWidgets('idle: menu enters plan mode with a plan_mode action', (
    tester,
  ) async {
    final bar = await pumpBar(tester, planState: _state(kPlanStateIdleFrame));
    await tester.tap(planButton);
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('plan-menu-exit')), findsNothing);
    expect(find.byKey(const Key('plan-menu-review')), findsNothing);
    await tester.tap(find.byKey(const Key('plan-menu-enter')));
    await tester.pumpAndSettle();

    expect(bar.actions, [PlanModeAction.enter]);
    expect(bar.sent, isEmpty, reason: 'no /plan chat message');
  });

  testWidgets('active without a plan: exit goes straight out, no review', (
    tester,
  ) async {
    final bar = await pumpBar(
      tester,
      planState: _state(kPlanStateActiveFrame),
    );
    await tester.tap(planButton);
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('plan-menu-review')), findsNothing);
    expect(find.byKey(const Key('plan-menu-enter')), findsNothing);
    await tester.tap(find.byKey(const Key('plan-menu-exit')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('plan-exit-confirm')), findsNothing);
    expect(bar.actions, [PlanModeAction.exit]);
    expect(bar.sent, isEmpty);
  });

  testWidgets('active with a plan: Review plan sends plan_mode review', (
    tester,
  ) async {
    final bar = await pumpBar(
      tester,
      planState: const PlanState(
        status: PlanStatus.active,
        planFilePath: 'local://hello-txt-plan.md',
        title: 'hello-txt',
      ),
    );
    await tester.tap(planButton);
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('plan-menu-review')));
    await tester.pumpAndSettle();

    expect(bar.actions, [PlanModeAction.review]);
  });

  testWidgets('active with a plan: exit asks omp\'s confirm first', (
    tester,
  ) async {
    final bar = await pumpBar(
      tester,
      planState: const PlanState(
        status: PlanStatus.active,
        planFilePath: 'local://hello-txt-plan.md',
        title: 'hello-txt',
      ),
    );

    await tester.tap(planButton);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('plan-menu-exit')));
    await tester.pumpAndSettle();

    expect(find.text('Exit plan mode?'), findsOneWidget);
    expect(
      find.text('This exits plan mode without approving a plan.'),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const Key('plan-exit-cancel')));
    await tester.pumpAndSettle();
    expect(bar.actions, isEmpty, reason: 'declined → nothing sent');

    await tester.tap(planButton);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('plan-menu-exit')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('plan-exit-confirm')));
    await tester.pumpAndSettle();

    expect(bar.actions, [PlanModeAction.exit]);
    expect(bar.sent, isEmpty);
  });

  testWidgets('paused: menu offers exit', (tester) async {
    final bar = await pumpBar(
      tester,
      planState: _state(kPlanStatePausedFrame),
    );
    await tester.tap(planButton);
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('plan-menu-enter')), findsNothing);
    await tester.tap(find.byKey(const Key('plan-menu-exit')));
    await tester.pumpAndSettle();

    expect(bar.actions, [PlanModeAction.exit]);
  });

  testWidgets('review: tapping the button re-opens the review directly', (
    tester,
  ) async {
    final bar = await pumpBar(
      tester,
      planState: _state(kPlanStateReviewFrame),
    );
    await tester.tap(planButton);
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('plan-menu-exit')), findsNothing);
    expect(bar.actions, [PlanModeAction.review]);
    expect(bar.sent, isEmpty, reason: 'no /plan-review chat message');
  });
}
