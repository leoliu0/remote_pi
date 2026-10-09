import { test } from "node:test";
import assert from "node:assert/strict";
import {
  applyExtensionUiRequest,
  buildCancelResponse,
  buildSubmitResponse,
  canSubmit,
  parseExtensionUiRequest,
  toggleOption,
  type AskDraft,
  type ExtensionUiRequest,
} from "./extension-ui.ts";

// The frame pi-extension's bridge emits for a pi-ask flow
// (extension_ui_bridge.test.ts `singleQuestionFlow`), plus a multi + preview
// question to exercise the rich envelope.
const ASK_FRAME = {
  type: "extension_ui_request",
  id: "tool:tc_1",
  method: "select",
  title: "Direction",
  options: ["Alpha", "Beta"],
  ask: {
    flow_id: "tool:tc_1",
    tool_call_id: "tc_1",
    source: "tool",
    title: "Direction",
    questions: [
      {
        id: "goal",
        label: "Goal",
        prompt: "What's the goal?",
        type: "single",
        required: true,
        options: [
          { value: "a", label: "Alpha" },
          { value: "b", label: "Beta", description: "second choice" },
        ],
      },
      {
        id: "langs",
        label: "Languages",
        prompt: "Which languages?",
        type: "multi",
        required: false,
        options: [
          { value: "ts", label: "TypeScript" },
          { value: "rs", label: "Rust" },
        ],
      },
      {
        id: "layout",
        label: "Layout",
        prompt: "Pick a layout",
        type: "preview",
        required: false,
        options: [{ value: "grid", label: "Grid", preview: "[ ][ ]\n[ ][ ]" }, { label: "List" }],
      },
    ],
  },
};

const ask = (): ExtensionUiRequest => parseExtensionUiRequest(ASK_FRAME)!;

test("parses the bridge's rich select request", () => {
  const req = ask();
  assert.equal(req.id, "tool:tc_1");
  assert.equal(req.method, "select");
  assert.deepEqual(req.options, ["Alpha", "Beta"]);
  assert.equal(req.ask?.flowId, "tool:tc_1");
  assert.equal(req.ask?.toolCallId, "tc_1");
  assert.equal(req.ask?.questions.length, 3);
  assert.equal(req.ask?.questions[0].options[1].description, "second choice");
  assert.equal(req.ask?.questions[1].type, "multi");
  assert.equal(req.ask?.questions[2].options[0].preview, "[ ][ ]\n[ ][ ]");
  // label-only option falls back to value = label, like the bridge.
  assert.deepEqual(req.ask?.questions[2].options[1], { value: "List", label: "List", description: undefined, preview: undefined });
});

test("parses plain SDK requests and rejects non-requests", () => {
  const confirm = parseExtensionUiRequest({ type: "extension_ui_request", id: "c1", method: "confirm", title: "Delete?", message: "Really delete x?" });
  assert.equal(confirm?.method, "confirm");
  assert.equal(confirm?.message, "Really delete x?");
  assert.equal(confirm?.ask, undefined);
  const editor = parseExtensionUiRequest({ type: "extension_ui_request", id: "e1", method: "editor", title: "Edit", prefill: "abc" });
  assert.equal(editor?.prefill, "abc");
  const notify = parseExtensionUiRequest({ type: "extension_ui_request", id: "n1", method: "notify", message: "hi", notify_type: "warning" });
  assert.equal(notify?.notifyType, "warning");
  // Unknown methods degrade to select (phone parity).
  assert.equal(parseExtensionUiRequest({ type: "extension_ui_request", id: "x", method: "wat" })?.method, "select");
  assert.equal(parseExtensionUiRequest({ type: "tool_request", id: "x" }), null);
  assert.equal(parseExtensionUiRequest({ type: "extension_ui_request" }), null);
});

test("rich answer round-trip: single, multi, preview, custom text and notes", () => {
  const req = ask();
  const draft: AskDraft = {
    goal: { selected: ["a"], custom: "", note: " ship it " },
    langs: toggleOption(toggleOption(toggleOption({ selected: [], custom: "", note: "" }, "ts", true), "rs", true), "ts", true),
    layout: { selected: ["grid"], custom: "my own layout", note: "" },
  };
  assert.deepEqual(draft.langs.selected, ["rs"]);
  assert.equal(canSubmit(req, draft, { value: "" }), true);
  const resp = buildSubmitResponse(req, draft, { value: "" });
  assert.deepEqual(JSON.parse(JSON.stringify(resp)), {
    type: "extension_ui_response",
    id: "tool:tc_1",
    ask: {
      flow_id: "tool:tc_1",
      kind: "answer",
      mode: "submit",
      answers: {
        goal: { values: ["a"], note: "ship it" },
        langs: { values: ["rs"] },
        // Non-multi: custom text wins over a selection (pi-ask rule).
        layout: { customText: "my own layout" },
      },
    },
  });
});

test("rich answer skips unanswered questions; nothing answered cannot submit", () => {
  const req = ask();
  assert.equal(canSubmit(req, {}, { value: "" }), false);
  const resp = buildSubmitResponse(req, { goal: { selected: ["b"], custom: "", note: "" } }, { value: "" });
  assert.deepEqual(resp.ask, { flow_id: "tool:tc_1", kind: "answer", mode: "submit", answers: { goal: { values: ["b"] } } });
  assert.equal(toggleOption({ selected: ["a"], custom: "", note: "" }, "b", false).selected[0], "b");
});

test("cancel carries the ask envelope when present (phone wire format)", () => {
  assert.deepEqual(buildCancelResponse(ask()), {
    type: "extension_ui_response",
    id: "tool:tc_1",
    cancelled: true,
    ask: { flow_id: "tool:tc_1", kind: "cancel" },
  });
  const plain = parseExtensionUiRequest({ type: "extension_ui_request", id: "c1", method: "confirm", title: "t", message: "m" })!;
  assert.deepEqual(buildCancelResponse(plain), { type: "extension_ui_response", id: "c1", cancelled: true });
});

test("plain responses: select value, input text, confirm", () => {
  const select = parseExtensionUiRequest({ type: "extension_ui_request", id: "s1", method: "select", title: "Pick", options: ["x", "y"] })!;
  assert.equal(canSubmit(select, {}, { value: "" }), false);
  assert.deepEqual(buildSubmitResponse(select, {}, { value: "y" }), { type: "extension_ui_response", id: "s1", value: "y" });
  const input = parseExtensionUiRequest({ type: "extension_ui_request", id: "i1", method: "input", title: "Name" })!;
  assert.equal(canSubmit(input, {}, { value: "  " }), false);
  assert.deepEqual(buildSubmitResponse(input, {}, { value: "bob" }), { type: "extension_ui_response", id: "i1", value: "bob" });
  const confirm = parseExtensionUiRequest({ type: "extension_ui_request", id: "c1", method: "confirm", title: "t", message: "m" })!;
  assert.deepEqual(buildSubmitResponse(confirm, {}, { value: "" }), { type: "extension_ui_response", id: "c1", confirmed: true });
});

test("notify: dismiss closes, warning keeps open with message, unmatched ignored", () => {
  const open = applyExtensionUiRequest(null, ask());
  assert.equal(open?.request.id, "tool:tc_1");
  const notify = (id: string, extra: Record<string, unknown> = {}) =>
    parseExtensionUiRequest({ type: "extension_ui_request", id, method: "notify", message: "Clarification resolved.", ...extra })!;
  assert.equal(applyExtensionUiRequest(open, notify("other")), open);
  assert.equal(applyExtensionUiRequest(null, notify("tool:tc_1")), null);
  const warned = applyExtensionUiRequest(open, notify("tool:tc_1", { notify_type: "warning", message: "invalid answer" }));
  assert.equal(warned?.error, "invalid answer");
  assert.equal(applyExtensionUiRequest(warned, notify("tool:tc_1", { notify_type: "error", message: "" }))?.error, "Answer was not accepted.");
  assert.equal(applyExtensionUiRequest(warned, notify("tool:tc_1")), null);
  // A replayed request replaces the open one and clears the error.
  assert.deepEqual(applyExtensionUiRequest(warned, ask()), { request: ask(), error: null });
});
