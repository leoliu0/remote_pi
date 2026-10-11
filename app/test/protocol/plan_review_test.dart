// omp plan mode — protocol surface, built from the captured frames
// (test/protocol/plan_capture_fixtures.dart). Contract:
// pi-extension/src/protocol/types.ts (PlanReviewWire, PlanReviewAnswerWire,
// PlanStatus, `plan_state`, `plan_mode`).

import 'dart:convert';

import 'package:app/protocol/protocol.dart';
import 'package:flutter_test/flutter_test.dart';

import 'plan_capture_fixtures.dart';

ServerMessage _parse(String frame) =>
    ServerMessage.fromJson(jsonDecode(frame) as Map<String, dynamic>);

Map<String, dynamic> _json(String frame) =>
    jsonDecode(frame) as Map<String, dynamic>;

void main() {
  group('extension_ui_request — plan envelope', () {
    test('captured plan review request parses the typed plan', () {
      final req = _parse(kPlanReviewRequestFrame) as ExtensionUiRequest;
      expect(req.id, kPlanReviewId);
      expect(req.method, ExtensionUiMethod.select);
      expect(req.options, hasLength(5), reason: 'plain select fallback kept');

      final plan = req.plan!;
      expect(plan.planFilePath, 'local://hello-txt-plan.md');
      expect(plan.title, 'hello-txt');
      expect(plan.content, startsWith('# Create hello.txt\n\n- Create'));
      expect(plan.options.map((o) => o.action), [
        PlanReviewAction.approveExecute,
        PlanReviewAction.approveCompact,
        PlanReviewAction.approveKeep,
        PlanReviewAction.refine,
        PlanReviewAction.saveQuit,
      ]);
      expect(plan.options.map((o) => o.label), [
        'Approve and execute',
        'Approve and compact context',
        'Approve and keep context (~19k / 1m)',
        'Refine plan',
        'Save and quit',
      ]);
      expect(plan.options.any((o) => o.disabled), isFalse);
    });

    test('disabled option, null content, unknown action', () {
      final j = _json(kPlanReviewRequestFrame);
      final plan = j['plan'] as Map<String, dynamic>;
      plan['content'] = null;
      final options = plan['options'] as List<dynamic>;
      (options[2] as Map<String, dynamic>)['disabled'] = true;
      options.add({'action': 'future_choice', 'label': 'Future'});

      final parsed = ExtensionUiRequest.fromJson(j).plan!;
      expect(parsed.content, isNull);
      expect(parsed.options[2].disabled, isTrue);
      expect(
        parsed.options,
        hasLength(5),
        reason: 'an action this build does not know is dropped',
      );
    });

    test('a request without the envelope has no plan (older Pi)', () {
      final req = _parse(kPlanCloseFrame) as ExtensionUiRequest;
      expect(req.method, ExtensionUiMethod.notify);
      expect(req.plan, isNull);
    });
  });

  group('extension_ui_response — plan answer', () {
    test('approve encodes exactly the captured frame', () {
      final resp = ExtensionUiResponse(
        id: kPlanReviewId,
        plan: const PlanReviewAnswer(action: PlanReviewAction.approveExecute),
      );
      expect(resp.toJson(), _json(kPlanApproveExecuteFrame));
    });

    test('refine carries trimmed feedback', () {
      final resp = ExtensionUiResponse(
        id: kPlanReviewId,
        plan: const PlanReviewAnswer(
          action: PlanReviewAction.refine,
          feedback: '  Also print the file with cat afterwards.\n',
        ),
      );
      expect(resp.toJson(), _json(kPlanRefineFrame));
    });

    test('empty feedback and non-refine feedback are omitted', () {
      expect(
        const PlanReviewAnswer(
          action: PlanReviewAction.refine,
          feedback: '   ',
        ).toJson(),
        {'action': 'refine'},
      );
      expect(
        const PlanReviewAnswer(
          action: PlanReviewAction.saveQuit,
          feedback: 'ignored',
        ).toJson(),
        {'action': 'save_quit'},
      );
    });

    test('cancel encodes the captured frame', () {
      expect(
        ExtensionUiResponse(id: kPlanReviewId, cancelled: true).toJson(),
        _json(kPlanCancelFrame),
      );
    });
  });

  group('plan_state', () {
    test('review carries the plan path and title', () {
      final s = _parse(kPlanStateReviewFrame) as PlanState;
      expect(s.status, PlanStatus.review);
      expect(s.planFilePath, 'local://hello-txt-plan.md');
      expect(s.title, 'hello-txt');
    });

    test('active / paused / idle without a plan', () {
      for (final (frame, status) in [
        (kPlanStateActiveFrame, PlanStatus.active),
        (kPlanStatePausedFrame, PlanStatus.paused),
        (kPlanStateIdleFrame, PlanStatus.idle),
      ]) {
        final s = _parse(frame) as PlanState;
        expect(s.status, status);
        expect(s.planFilePath, isNull);
        expect(s.title, isNull);
      }
    });
  });

  group('plan_mode action', () {
    test('enter / exit / review encode the captured frames', () {
      for (final (action, frame) in [
        (PlanModeAction.enter, kPlanModeEnterFrame),
        (PlanModeAction.exit, kPlanModeExitFrame),
        (PlanModeAction.review, kPlanModeReviewFrame),
      ]) {
        expect(PlanMode(id: '<id>', action: action).toJson(), _json(frame));
      }
    });

    test('action_ok / action_error replies map to ActionName.planMode', () {
      final ok = _parse(kPlanModeOkFrame) as ActionOk;
      expect(ok.inReplyTo, '<id>');
      expect(ok.action, ActionName.planMode);

      final err = _parse(kPlanModeErrorFrame) as ActionError;
      expect(err.action, ActionName.planMode);
      expect(err.error, '…');
    });
  });
}
