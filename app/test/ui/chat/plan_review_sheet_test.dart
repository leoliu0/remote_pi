// omp plan review sheet: renders the captured plan as markdown with omp's
// choices and sends exactly the contract frames
// (test/protocol/plan_capture_fixtures.dart).

import 'dart:convert';

import 'package:app/protocol/protocol.dart';
import 'package:app/ui/chat/widgets/agent_markdown.dart';
import 'package:app/ui/chat/widgets/plan_review_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../protocol/plan_capture_fixtures.dart';

Map<String, dynamic> _json(String frame) =>
    jsonDecode(frame) as Map<String, dynamic>;

ExtensionUiRequest _captured({
  bool keepDisabled = false,
  bool unreadable = false,
}) {
  final j = _json(kPlanReviewRequestFrame);
  final plan = j['plan'] as Map<String, dynamic>;
  if (keepDisabled) {
    ((plan['options'] as List<dynamic>)[2] as Map<String, dynamic>)['disabled'] =
        true;
  }
  if (unreadable) plan['content'] = null;
  return ExtensionUiRequest.fromJson(j);
}

void main() {
  Future<void> pumpSheet(
    WidgetTester tester, {
    required ExtensionUiRequest request,
    String? error,
    Future<void> Function(ExtensionUiResponse)? onRespond,
  }) {
    // Tall phone so the plan and every choice fit without scrolling.
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.reset);
    return tester.pumpWidget(
      MaterialApp(
        home: PlanReviewSheet(
          key: ValueKey(request.id),
          request: request,
          plan: request.plan!,
          error: error,
          onRespond: onRespond ?? (_) async {},
        ),
      ),
    );
  }

  Finder option(String wire) => find.byKey(Key('plan-review-option-$wire'));

  bool enabled(WidgetTester tester, Finder f) =>
      tester.widget<ButtonStyleButton>(f).onPressed != null;

  testWidgets('renders the plan as markdown with omp\'s 5 choices in order', (
    tester,
  ) async {
    await pumpSheet(tester, request: _captured());

    expect(find.text('Plan ready for review'), findsOneWidget);
    expect(find.text('hello-txt'), findsOneWidget);
    expect(find.text('local://hello-txt-plan.md'), findsOneWidget);
    // Markdown, not raw text: the heading renders without its `#`.
    expect(find.byType(AgentMarkdown), findsOneWidget);
    expect(find.textContaining('Create hello.txt'), findsOneWidget);
    expect(find.textContaining('# Create'), findsNothing);

    final wires = [
      'approve_execute',
      'approve_compact',
      'approve_keep',
      'refine',
      'save_quit',
    ];
    final tops = [
      for (final w in wires) tester.getTopLeft(option(w)).dy,
    ];
    expect(tops, orderedEquals([...tops]..sort()), reason: "omp's order");
    expect(find.text('Approve and keep context (~19k / 1m)'), findsOneWidget);
    for (final w in wires) {
      expect(enabled(tester, option(w)), isTrue);
    }
    expect(find.byKey(const Key('plan-review-keep-planning')), findsOneWidget);
  });

  testWidgets('a disabled choice is shown but not tappable', (tester) async {
    final sent = <ExtensionUiResponse>[];
    await pumpSheet(
      tester,
      request: _captured(keepDisabled: true),
      onRespond: (r) async => sent.add(r),
    );

    expect(enabled(tester, option('approve_keep')), isFalse);
    expect(find.text('context too full'), findsOneWidget);
    await tester.tap(option('approve_keep'), warnIfMissed: false);
    await tester.pump();
    expect(sent, isEmpty);
  });

  testWidgets('tapping approve sends the exact plan answer frame at once', (
    tester,
  ) async {
    final sent = <ExtensionUiResponse>[];
    await pumpSheet(
      tester,
      request: _captured(),
      onRespond: (r) async => sent.add(r),
    );

    await tester.tap(option('approve_execute'));
    await tester.pump();

    expect(sent.single.toJson(), _json(kPlanApproveExecuteFrame));
    // Stays open, every choice locked, until the same-id close notify.
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    expect(enabled(tester, option('refine')), isFalse);
  });

  testWidgets('refine sends the feedback text', (tester) async {
    final sent = <ExtensionUiResponse>[];
    await pumpSheet(
      tester,
      request: _captured(),
      onRespond: (r) async => sent.add(r),
    );

    await tester.enterText(
      find.byKey(const Key('plan-review-feedback')),
      'Also print the file with cat afterwards.',
    );
    await tester.tap(option('refine'));
    await tester.pump();

    expect(sent.single.toJson(), _json(kPlanRefineFrame));
  });

  testWidgets('Keep planning sends cancelled', (tester) async {
    final sent = <ExtensionUiResponse>[];
    await pumpSheet(
      tester,
      request: _captured(),
      onRespond: (r) async => sent.add(r),
    );

    await tester.tap(find.byKey(const Key('plan-review-keep-planning')));
    await tester.pump();

    expect(sent.single.toJson(), _json(kPlanCancelFrame));
  });

  testWidgets('system back keeps planning instead of popping the route', (
    tester,
  ) async {
    final sent = <ExtensionUiResponse>[];
    await pumpSheet(
      tester,
      request: _captured(),
      onRespond: (r) async => sent.add(r),
    );

    await tester.binding.handlePopRoute();
    await tester.pump();

    expect(sent.single.toJson(), _json(kPlanCancelFrame));
    expect(find.byType(PlanReviewSheet), findsOneWidget);
  });

  testWidgets('a warning shows its message and re-enables the choices', (
    tester,
  ) async {
    final sent = <ExtensionUiResponse>[];
    Future<void> onRespond(ExtensionUiResponse r) async => sent.add(r);
    final request = _captured();

    await pumpSheet(tester, request: request, onRespond: onRespond);
    await tester.tap(option('approve_execute'));
    await tester.pump();
    expect(enabled(tester, option('approve_execute')), isFalse);

    await pumpSheet(
      tester,
      request: request,
      error: 'Plan mode is no longer active',
      onRespond: onRespond,
    );
    await tester.pump();

    expect(find.text('Plan mode is no longer active'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(enabled(tester, option('approve_execute')), isTrue);
  });

  testWidgets('unreadable plan says so and shows the path', (tester) async {
    await pumpSheet(tester, request: _captured(unreadable: true));

    expect(find.text('The plan file could not be read'), findsOneWidget);
    expect(find.text('local://hello-txt-plan.md'), findsNWidgets(2));
    expect(find.byType(AgentMarkdown), findsNothing);
    expect(enabled(tester, option('approve_execute')), isTrue);
  });
}
