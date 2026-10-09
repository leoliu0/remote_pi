// Plan/57 — ask prompts end to end on the sheet: real `extension_ui_request`
// frames (the exact JSON pi-extension sends — session/ask_tool.ts
// createAskRequestWire, extension_ui_bridge.ts requestForFlow / plan review,
// and the SDK select/confirm/input/editor methods) are decoded with the app's
// wire parser, driven through ExtensionUiSheet, and the resulting
// `extension_ui_response` is compared to the JSON the extension expects.

import 'package:app/protocol/protocol.dart';
import 'package:app/ui/chat/widgets/extension_ui_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

ExtensionUiRequest _decode(Map<String, dynamic> json) =>
    ServerMessage.fromJson(json) as ExtensionUiRequest;

/// session/ask_tool.ts — the `ask` tool with one single-choice question whose
/// options carry description + preview (type stays "single").
const Map<String, dynamic> _askToolSingle = {
  'type': 'extension_ui_request',
  'id': 'ask_call_1',
  'method': 'select',
  'title': 'Which auth?',
  'options': ['OAuth', 'API key'],
  'ask': {
    'flow_id': 'ask_call_1',
    'tool_call_id': 'ask_call_1',
    'source': 'tool',
    'title': 'Which auth?',
    'questions': [
      {
        'id': 'auth',
        'label': 'Auth',
        'prompt': 'Which auth?',
        'type': 'single',
        'required': true,
        'options': [
          {
            'value': 'OAuth',
            'label': 'OAuth',
            'description': 'Browser sign-in',
            'preview': 'GET /oauth/authorize',
          },
          {'value': 'API key', 'label': 'API key'},
        ],
      },
    ],
  },
};

/// session/ask_tool.ts — `multi: true`, no header (label == prompt).
const Map<String, dynamic> _askToolMulti = {
  'type': 'extension_ui_request',
  'id': 'ask_call_2',
  'method': 'select',
  'title': 'Which targets?',
  'options': ['android', 'ios', 'web'],
  'ask': {
    'flow_id': 'ask_call_2',
    'tool_call_id': 'ask_call_2',
    'source': 'tool',
    'title': 'Which targets?',
    'questions': [
      {
        'id': 'targets',
        'label': 'Which targets?',
        'prompt': 'Which targets?',
        'type': 'multi',
        'required': true,
        'options': [
          {'value': 'android', 'label': 'android'},
          {'value': 'ios', 'label': 'ios'},
          {'value': 'web', 'label': 'web'},
        ],
      },
    ],
  },
};

/// extension_ui_bridge.ts — pi-ask flow requested as multi but presented as
/// single after the live toggle (presentedType wins).
const Map<String, dynamic> _piAskToggled = {
  'type': 'extension_ui_request',
  'id': 'tool:tc_7',
  'method': 'select',
  'title': 'Direction',
  'options': ['Alpha', 'Beta'],
  'ask': {
    'flow_id': 'tool:tc_7',
    'tool_call_id': 'tc_7',
    'source': 'tool',
    'title': 'Direction',
    'questions': [
      {
        'id': 'dir',
        'label': 'Dir',
        'prompt': 'Pick one',
        'type': 'multi',
        'required': false,
        'presentedType': 'single',
        'requestedType': 'multi',
        'options': [
          {'value': 'a', 'label': 'Alpha'},
          {'value': 'b', 'label': 'Beta'},
        ],
      },
    ],
  },
};

/// extension_ui_bridge.ts — pure-text pi-ask question degrades to `input`.
const Map<String, dynamic> _piAskText = {
  'type': 'extension_ui_request',
  'id': 'y',
  'method': 'input',
  'title': 'Describe the goal',
  'placeholder': 'Describe the goal',
  'ask': {
    'flow_id': 'y',
    'tool_call_id': null,
    'source': 'tool',
    'title': null,
    'questions': [
      {
        'id': 'goal',
        'label': 'Goal',
        'prompt': 'Describe the goal',
        'type': 'single',
        'required': false,
        'options': <Object>[],
      },
    ],
  },
};

/// extension_ui_bridge.ts triggerPlanReview.
const Map<String, dynamic> _planReview = {
  'type': 'extension_ui_request',
  'id': 'plan-review',
  'method': 'select',
  'title': 'Plan Review: Ship it',
  'options': [
    'Approve and execute',
    'Approve and compact context',
    'Refine plan',
    'Reject / Cancel',
  ],
  'ask': {
    'flow_id': 'plan-review',
    'tool_call_id': null,
    'source': 'plan-review',
    'title': 'Plan Review: Ship it',
    'questions': [
      {
        'id': 'action',
        'label': 'Action',
        'prompt': 'Review the proposed plan below and select an action:',
        'type': 'preview',
        'required': true,
        'options': [
          {
            'value': 'Approve and execute',
            'label': 'Approve and execute',
            'description': 'Exit plan mode and begin implementation.',
            'preview': '1. Do the thing',
          },
          {'value': 'Refine plan', 'label': 'Refine plan'},
        ],
      },
    ],
  },
};

void main() {
  Future<List<Map<String, dynamic>>> pump(
    WidgetTester tester,
    Map<String, dynamic> json,
  ) async {
    final sent = <Map<String, dynamic>>[];
    final request = _decode(json);
    await tester.pumpWidget(
      MaterialApp(
        home: ExtensionUiSheet(
          key: ValueKey(request.id),
          request: request,
          onRespond: (r) async => sent.add(r.toJson()),
        ),
      ),
    );
    return sent;
  }

  Finder button(String label) => find.ancestor(
    of: find.text(label),
    matching: find.byWidgetPredicate((w) => w is ButtonStyleButton),
  );

  group('ask tool (session/ask_tool.ts)', () {
    testWidgets('single: option preview is shown and the answer round-trips', (
      tester,
    ) async {
      final sent = await pump(tester, _askToolSingle);
      expect(find.text('Browser sign-in'), findsOneWidget);
      expect(
        find.text('GET /oauth/authorize'),
        findsOneWidget,
        reason: 'ask tool previews ride on single/multi questions',
      );

      await tester.tap(find.text('OAuth'));
      await tester.pump();
      await tester.tap(button('Submit'));
      await tester.pump();

      expect(sent, [
        {
          'type': 'extension_ui_response',
          'id': 'ask_call_1',
          'ask': {
            'flow_id': 'ask_call_1',
            'kind': 'answer',
            'mode': 'submit',
            'answers': {
              'auth': {
                'values': ['OAuth'],
              },
            },
          },
        },
      ]);
    });

    testWidgets('multi: values + custom text + note round-trip together', (
      tester,
    ) async {
      final sent = await pump(tester, _askToolMulti);
      await tester.tap(find.text('android'));
      await tester.pump();
      await tester.tap(find.text('web'));
      await tester.pump();
      await tester.enterText(
        find.widgetWithText(TextField, 'Type your own…'),
        'desktop too',
      );
      await tester.tap(find.text('Add note'));
      await tester.pump();
      await tester.enterText(
        find.widgetWithText(TextField, 'Note (optional)'),
        'web first',
      );
      await tester.pump();
      await tester.tap(button('Submit'));
      await tester.pump();

      expect(sent.single['ask'], {
        'flow_id': 'ask_call_2',
        'kind': 'answer',
        'mode': 'submit',
        'answers': {
          'targets': {
            'values': ['android', 'web'],
            'customText': 'desktop too',
            'note': 'web first',
          },
        },
      });
    });

    testWidgets('a header-less question shows its prompt once (not twice)', (
      tester,
    ) async {
      await pump(tester, _askToolMulti);
      // AppBar title + the question prompt; the label (== prompt) is not
      // repeated underneath.
      expect(find.text('Which targets?'), findsNWidgets(2));
    });

    testWidgets('cancel sends cancelled + ask cancel envelope', (tester) async {
      final sent = await pump(tester, _askToolSingle);
      await tester.tap(button('Cancel'));
      await tester.pump();
      expect(sent, [
        {
          'type': 'extension_ui_response',
          'id': 'ask_call_1',
          'cancelled': true,
          'ask': {'flow_id': 'ask_call_1', 'kind': 'cancel'},
        },
      ]);
    });
  });

  group('pi-ask bridge (extension_ui_bridge.ts)', () {
    testWidgets('presentedType single overrides type multi', (tester) async {
      final sent = await pump(tester, _piAskToggled);
      await tester.tap(find.text('Alpha'));
      await tester.pump();
      await tester.tap(find.text('Beta'));
      await tester.pump();
      expect(find.byIcon(Icons.radio_button_checked), findsOneWidget);
      await tester.tap(button('Submit'));
      await tester.pump();
      expect(
        (sent.single['ask'] as Map)['answers'],
        {
          'dir': {
            'values': ['b'],
          },
        },
      );
    });

    testWidgets('pure-text question (input) answers with customText', (
      tester,
    ) async {
      final sent = await pump(tester, _piAskText);
      await tester.enterText(
        find.widgetWithText(TextField, 'Type your own…'),
        'ship it',
      );
      await tester.pump();
      await tester.tap(button('Submit'));
      await tester.pump();
      expect(sent, [
        {
          'type': 'extension_ui_response',
          'id': 'y',
          'ask': {
            'flow_id': 'y',
            'kind': 'answer',
            'mode': 'submit',
            'answers': {
              'goal': {'customText': 'ship it'},
            },
          },
        },
      ]);
    });

    testWidgets('plan review: preview shown; refine with feedback', (
      tester,
    ) async {
      final sent = await pump(tester, _planReview);
      expect(find.text('1. Do the thing'), findsOneWidget);
      await tester.tap(find.text('Refine plan'));
      await tester.pump();
      await tester.enterText(
        find.widgetWithText(TextField, 'Type your own…'),
        'split step 2',
      );
      await tester.pump();
      await tester.tap(button('Submit'));
      await tester.pump();
      // Non-multi: custom text wins over the selected value (pi-ask rule);
      // the bridge reads customText as refine feedback.
      expect((sent.single['ask'] as Map)['answers'], {
        'action': {'customText': 'split step 2'},
      });
    });
  });

  group('SDK methods without the ask envelope', () {
    testWidgets('select → value is the chosen label', (tester) async {
      final sent = await pump(tester, const {
        'type': 'extension_ui_request',
        'id': 'sel',
        'method': 'select',
        'title': 'Pick',
        'options': ['Alpha', 'Beta'],
      });
      await tester.tap(find.text('Beta'));
      await tester.pump();
      await tester.tap(button('Submit'));
      await tester.pump();
      expect(sent, [
        {'type': 'extension_ui_response', 'id': 'sel', 'value': 'Beta'},
      ]);
    });

    testWidgets('confirm → Yes sends confirmed:true', (tester) async {
      final sent = await pump(tester, const {
        'type': 'extension_ui_request',
        'id': 'cf',
        'method': 'confirm',
        'title': 'Delete branch?',
        'message': 'feature-1 will be removed.',
      });
      expect(find.text('feature-1 will be removed.'), findsOneWidget);
      await tester.tap(button('Yes'));
      await tester.pump();
      expect(sent, [
        {'type': 'extension_ui_response', 'id': 'cf', 'confirmed': true},
      ]);
    });

    testWidgets('confirm → No sends confirmed:false (not a cancel)', (
      tester,
    ) async {
      final sent = await pump(tester, const {
        'type': 'extension_ui_request',
        'id': 'cf',
        'method': 'confirm',
        'title': 'Delete branch?',
        'message': 'feature-1 will be removed.',
      });
      await tester.tap(button('No'));
      await tester.pump();
      expect(sent, [
        {'type': 'extension_ui_response', 'id': 'cf', 'confirmed': false},
      ]);
    });

    testWidgets('input → value is the typed text; placeholder as hint', (
      tester,
    ) async {
      final sent = await pump(tester, const {
        'type': 'extension_ui_request',
        'id': 'in',
        'method': 'input',
        'title': 'Name',
        'placeholder': 'branch name',
      });
      await tester.enterText(
        find.widgetWithText(TextField, 'branch name'),
        'feat/x',
      );
      await tester.pump();
      await tester.tap(button('Submit'));
      await tester.pump();
      expect(sent, [
        {'type': 'extension_ui_response', 'id': 'in', 'value': 'feat/x'},
      ]);
    });

    testWidgets('editor → prefill is editable and submitted as value', (
      tester,
    ) async {
      final sent = await pump(tester, const {
        'type': 'extension_ui_request',
        'id': 'ed',
        'method': 'editor',
        'title': 'Commit message',
        'prefill': 'fix: thing',
      });
      expect(find.text('fix: thing'), findsOneWidget);
      await tester.tap(button('Submit'));
      await tester.pump();
      expect(sent, [
        {'type': 'extension_ui_response', 'id': 'ed', 'value': 'fix: thing'},
      ]);
    });

    testWidgets('cancel without envelope sends cancelled only', (
      tester,
    ) async {
      final sent = await pump(tester, const {
        'type': 'extension_ui_request',
        'id': 'in',
        'method': 'input',
        'title': 'Name',
      });
      await tester.tap(button('Cancel'));
      await tester.pump();
      expect(sent, [
        {'type': 'extension_ui_response', 'id': 'in', 'cancelled': true},
      ]);
    });
  });
}
