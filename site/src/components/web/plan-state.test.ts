import { test } from "node:test";
import assert from "node:assert/strict";
import { EXIT_PLAN_CONFIRM, parsePlanState, planControl } from "./plan-state.ts";

// local://plan-capture.md — `plan_state` frames, broadcast on change and after
// each session_sync reply.
const REVIEW = { type: "plan_state", status: "review", plan_file_path: "local://hello-txt-plan.md", title: "hello-txt" };

test("parses plan_state frames; anything else is ignored", () => {
  assert.deepEqual(parsePlanState(REVIEW), { status: "review", planFilePath: "local://hello-txt-plan.md", title: "hello-txt" });
  assert.deepEqual(parsePlanState({ type: "plan_state", status: "active" }), { status: "active", planFilePath: null, title: null });
  assert.deepEqual(parsePlanState({ type: "plan_state", status: "paused" }), { status: "paused", planFilePath: null, title: null });
  assert.deepEqual(parsePlanState({ type: "plan_state", status: "idle" }), { status: "idle", planFilePath: null, title: null });
  assert.equal(parsePlanState({ type: "plan_state", status: "drafting" }), null);
  assert.equal(parsePlanState({ type: "plan_state" }), null);
  assert.equal(parsePlanState({ type: "status_line", status: "idle" }), null);
  // Empty / non-string path and title read as unknown.
  assert.deepEqual(parsePlanState({ type: "plan_state", status: "active", plan_file_path: "", title: 3 }), {
    status: "active",
    planFilePath: null,
    title: null,
  });
});

test("the Plan control: enter when idle, open the review when ready", () => {
  assert.deepEqual(planControl(parsePlanState({ type: "plan_state", status: "idle" })!), {
    label: "Plan",
    menu: false,
    items: [{ action: "enter", label: "Enter plan mode", confirm: null }],
  });
  assert.deepEqual(planControl(parsePlanState(REVIEW)!), {
    label: "Plan ready",
    menu: false,
    items: [{ action: "review", label: "Review plan", confirm: null }],
  });
});

test("planning offers Review only with a known plan; Exit confirms when a plan exists", () => {
  assert.deepEqual(planControl(parsePlanState({ type: "plan_state", status: "active" })!), {
    label: "Planning",
    menu: true,
    items: [{ action: "exit", label: "Exit plan mode", confirm: null }],
  });
  assert.deepEqual(planControl(parsePlanState({ ...REVIEW, status: "active" })!), {
    label: "Planning",
    menu: true,
    items: [
      { action: "review", label: "Review plan", confirm: null },
      { action: "exit", label: "Exit plan mode", confirm: EXIT_PLAN_CONFIRM },
    ],
  });
  assert.equal(EXIT_PLAN_CONFIRM, "Exit plan mode? This exits plan mode without approving a plan.");
  assert.deepEqual(planControl(parsePlanState({ type: "plan_state", status: "paused" })!), {
    label: "Plan paused",
    menu: true,
    items: [{ action: "exit", label: "Exit plan mode", confirm: null }],
  });
});
