import { mkdtempSync, mkdirSync, rmSync, utimesSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, beforeEach, describe, expect, test, vi } from "vitest";

import {
  createPlanReview,
  localPlanFiles,
  ompPlanMode,
  PLAN_MODE_NEEDS_TERMINAL,
  readPlanFile,
  type ContextUsage,
  type OmpPlanMode,
  type PlanReviewController,
} from "./plan_review.js";
import type { PlanReviewAction, ServerMessage } from "./protocol/types.js";

// Captured from omp 18.9.2 (scratch session, plan-mode investigation,
// run1-approve-execute.jsonl line 40): the `write xd://propose` result.
const PROPOSE_EVENT = {
  type: "tool_execution_end",
  toolCallId: "toolu_019RaxgagFLMnWDaT826y9KG",
  toolName: "write",
  isError: false,
  result: {
    content: [{ type: "text", text: "Plan ready for review." }],
    details: {
      xdev: {
        tool: "propose",
        mode: "execute",
        args: { title: "hello-txt" },
        inner: { planFilePath: "local://hello-txt-plan.md", title: "hello-txt", planExists: true },
      },
    },
  },
} as const;
const REVIEW_ID = "plan-review:toolu_019RaxgagFLMnWDaT826y9KG";
// The plan file the agent wrote just before proposing (same run, line 27).
const PLAN_MARKDOWN =
  "# Plan: create hello.txt\n\n- Create `/tmp/pm-e2e/proj/hello.txt` with the `write` tool.\n- Content: `hello plan`.\n- Verify with `cat`.\n";

const DOWN = "\x1b[B";
const UP = "\x1b[A";
const ENTER = "\r";
const ESC = "\x1b";

/** omp's interactive mode as far as the controller can observe it. `/plan`
 *  steps plan → plan_paused → none (the first step behind omp's "Exit plan
 *  mode?" confirm, answered by Enter, when a plan file exists). */
function fakeOmp(opts: { mode?: OmpPlanMode; terminal?: boolean; usage?: ContextUsage | null; planFile?: boolean } = {}) {
  const sent: ServerMessage[] = [];
  /** Keys and lines in the order they reached omp's terminal. */
  const io: string[] = [];
  const prompts: string[] = [];
  const state = {
    mode: opts.mode ?? ("plan" as OmpPlanMode),
    terminal: opts.terminal ?? true,
    idle: true,
    planFile: opts.planFile ?? true,
    confirmOpen: false,
  };
  let controller: PlanReviewController | null = null;
  const pressKeys = (keys: string): void => {
    io.push(`key:${JSON.stringify(keys)}`);
    if (state.confirmOpen && keys === ENTER) {
      state.confirmOpen = false;
      state.mode = "plan_paused";
    }
    // omp hands every key, injected ones too, to onTerminalInput listeners.
    controller!.onTerminalInput(keys);
  };
  controller = createPlanReview({
    broadcast: (msg) => sent.push(msg),
    hasTerminal: () => state.terminal,
    isIdle: () => state.idle,
    pressKeys,
    typeLine: (text) => {
      io.push(`line:${text}`);
      controller!.onTerminalInput(ENTER);
      controller!.onInput(text);
      if (text === "/plan") {
        if (state.mode === "plan" && state.planFile) state.confirmOpen = true;
        else if (state.mode === "plan") state.mode = "plan_paused";
        else if (state.mode === "plan_paused") state.mode = "none";
        else state.mode = "plan";
      }
      return true;
    },
    submitPrompt: (text) => prompts.push(text),
    mode: () => state.mode,
    readPlan: (path) => (path === "local://hello-txt-plan.md" ? PLAN_MARKDOWN : null),
    hasPlanFile: () => state.planFile,
    latestPlanFile: () => (state.planFile ? "local://hello-txt-plan.md" : null),
    contextUsage: () => (opts.usage === undefined ? { tokens: 19_000, contextWindow: 1_000_000, percent: 1.9 } : opts.usage),
    setTimer: (fn, ms) => {
      setTimeout(fn, ms);
    },
    now: () => Date.now(),
  });
  const keys = () => io.filter((x) => x.startsWith("key:")).map((x) => JSON.parse(x.slice(4)) as string);
  const notifies = (id: string) =>
    sent.filter((m) => m.type === "extension_ui_request" && m.method === "notify" && m.id === id);
  const states = () => sent.filter((m) => m.type === "plan_state");
  return { c: controller, sent, io, keys, prompts, state, notifies, states };
}

/** The captured propose → aborted turn → agent_end, then the overlay settles. */
function proposeAndOpen(omp: ReturnType<typeof fakeOmp>): void {
  omp.c.onToolEnd(PROPOSE_EVENT);
  omp.c.onAgentEnd();
  vi.advanceTimersByTime(400);
}

function answer(omp: ReturnType<typeof fakeOmp>, action: PlanReviewAction, feedback?: string, id = REVIEW_ID): void {
  omp.c.respond({
    type: "extension_ui_response",
    id,
    plan: feedback === undefined ? { action } : { action, feedback },
  });
}

beforeEach(() => {
  vi.useFakeTimers();
});

afterEach(() => {
  vi.useRealTimers();
});

describe("plan review request", () => {
  test("omp's propose result opens one review with the plan markdown and omp's five choices", () => {
    const omp = fakeOmp();
    omp.c.onToolEnd(PROPOSE_EVENT);

    expect(omp.sent).toEqual([
      {
        type: "extension_ui_request",
        id: REVIEW_ID,
        method: "select",
        title: "Plan ready for review: hello-txt",
        options: [
          "Approve and execute",
          "Approve and compact context",
          "Approve and keep context (~19k / 1m)",
          "Refine plan",
          "Save and quit",
        ],
        plan: {
          plan_file_path: "local://hello-txt-plan.md",
          title: "hello-txt",
          content: PLAN_MARKDOWN,
          options: [
            { action: "approve_execute", label: "Approve and execute" },
            { action: "approve_compact", label: "Approve and compact context" },
            { action: "approve_keep", label: "Approve and keep context (~19k / 1m)" },
            { action: "refine", label: "Refine plan" },
            { action: "save_quit", label: "Save and quit" },
          ],
        },
      },
      { type: "plan_state", status: "review", plan_file_path: "local://hello-txt-plan.md", title: "hello-txt" },
    ]);
  });

  test("root cause 1: the plan file write and the old `details.planFilePath` guess open nothing", () => {
    const omp = fakeOmp();
    // The plan file itself (same run, line 29): a plain write result.
    omp.c.onToolEnd({
      toolName: "write",
      toolCallId: "toolu_016yMCs4moFkDJ9WJW6x4HZK",
      isError: false,
      result: { content: [{ type: "text", text: "Wrote local://hello-txt-plan.md" }] },
    });
    // The shape the old detection read (never produced by omp).
    omp.c.onToolEnd({
      toolName: "write",
      toolCallId: "x",
      isError: false,
      result: { details: { planFilePath: "local://PLAN.md", title: "Proposed Plan" } },
    });
    omp.c.onToolEnd({ ...PROPOSE_EVENT, isError: true });
    expect(omp.sent).toEqual([]);
  });

  test("keep context is disabled above 95% context, like omp's overlay", () => {
    const omp = fakeOmp({ usage: { tokens: 960_000, contextWindow: 1_000_000, percent: 96 } });
    omp.c.onToolEnd(PROPOSE_EVENT);
    const req = omp.sent[0] as Extract<ServerMessage, { type: "extension_ui_request" }>;
    expect(req.method === "select" && req.plan?.options[2]).toEqual({
      action: "approve_keep",
      label: "Approve and keep context (~960k / 1m)",
      disabled: true,
    });

    proposeAndOpen(omp);
    answer(omp, "approve_keep");
    vi.runAllTimers();
    expect(omp.keys()).toEqual([]);
    expect(omp.notifies(REVIEW_ID).at(-1)).toMatchObject({ notify_type: "warning" });
  });
});

describe("answering the overlay", () => {
  test.each<[PlanReviewAction, string[], string]>([
    ["approve_execute", [ENTER], "Plan approved."],
    ["approve_compact", [DOWN, ENTER], "Plan approved."],
    ["approve_keep", [DOWN, DOWN, ENTER], "Plan approved."],
    ["refine", [DOWN, DOWN, DOWN, DOWN, DOWN, UP, ENTER], "Refining the plan."],
    // "Save and quit" asks for the path in a second overlay; Enter keeps omp's.
    ["save_quit", [DOWN, DOWN, DOWN, DOWN, DOWN, ENTER, ENTER], "Plan saved; plan mode closed."],
  ])("%s: an answer before agent_end waits for the overlay, then sends %j", (action, expected, message) => {
    const omp = fakeOmp();
    omp.c.onToolEnd(PROPOSE_EVENT);
    answer(omp, action);
    expect(omp.keys()).toEqual([]);

    omp.c.onAgentEnd();
    vi.advanceTimersByTime(399);
    expect(omp.keys()).toEqual([]);
    vi.runAllTimers();

    expect(omp.keys()).toEqual(expected);
    expect(omp.notifies(REVIEW_ID)).toEqual([
      { type: "extension_ui_request", id: REVIEW_ID, method: "notify", message },
    ]);
    // Our own keys echo through onTerminalInput: they never count as the
    // terminal user's, so no Esc/re-open dance happens.
    expect(omp.io.some((x) => x.startsWith("line:"))).toBe(false);
  });

  test("refine with feedback submits it as the follow-up prompt omp asks for", () => {
    const omp = fakeOmp();
    proposeAndOpen(omp);
    answer(omp, "refine", "  add a fourth bullet: print it with cat  ");
    vi.runAllTimers();
    expect(omp.keys()).toEqual([DOWN, DOWN, DOWN, DOWN, DOWN, UP, ENTER]);
    expect(omp.prompts).toEqual(["add a fourth bullet: print it with cat"]);
  });

  test("Keep planning (cancel) presses Esc and leaves plan mode active", () => {
    const omp = fakeOmp();
    proposeAndOpen(omp);
    omp.c.respond({ type: "extension_ui_response", id: REVIEW_ID, cancelled: true });
    vi.runAllTimers();
    expect(omp.keys()).toEqual([ESC]);
    expect(omp.notifies(REVIEW_ID)).toEqual([
      expect.objectContaining({ message: "Plan review closed — still planning." }),
    ]);
    expect(omp.states().at(-1)).toEqual({
      type: "plan_state",
      status: "active",
      plan_file_path: "local://hello-txt-plan.md",
      title: "hello-txt",
    });
  });

  test("a client that only knows the plain select answers by label", () => {
    const omp = fakeOmp();
    proposeAndOpen(omp);
    omp.c.respond({ type: "extension_ui_response", id: REVIEW_ID, value: "Approve and keep context (~19k / 1m)" });
    vi.runAllTimers();
    expect(omp.keys()).toEqual([DOWN, DOWN, ENTER]);
  });

  test("terminal keys since the overlay opened: Esc, Esc, /plan-review, then the choice's keys", () => {
    const omp = fakeOmp();
    proposeAndOpen(omp);
    omp.c.onTerminalInput(DOWN); // the terminal user moved the cursor

    answer(omp, "approve_compact");
    vi.runAllTimers();

    expect(omp.io).toEqual([
      `key:${JSON.stringify(ESC)}`,
      `key:${JSON.stringify(ESC)}`,
      "line:/plan-review",
      `key:${JSON.stringify(DOWN)}`,
      `key:${JSON.stringify(ENTER)}`,
    ]);
    // The re-opened review replaces the same client prompt (same id).
    const requests = omp.sent.filter((m) => m.type === "extension_ui_request" && m.method === "select");
    expect(requests.map((m) => m.id)).toEqual([REVIEW_ID, REVIEW_ID]);
    expect(omp.notifies(REVIEW_ID).at(-1)).toMatchObject({ message: "Plan approved." });
  });
});

describe("the terminal answers first", () => {
  test("Esc in the terminal closes the client prompt; a late client answer re-opens the overlay", () => {
    const omp = fakeOmp();
    proposeAndOpen(omp);
    omp.c.onTerminalInput(ESC);
    expect(omp.notifies(REVIEW_ID)).toEqual([
      expect.objectContaining({ message: "Plan review closed in the terminal." }),
    ]);
    expect(omp.c.syncFrames()).toEqual([
      { type: "plan_state", status: "active", plan_file_path: "local://hello-txt-plan.md", title: "hello-txt" },
    ]);

    answer(omp, "approve_execute");
    vi.runAllTimers();
    expect(omp.io).toEqual([
      `key:${JSON.stringify(ESC)}`,
      `key:${JSON.stringify(ESC)}`,
      "line:/plan-review",
      `key:${JSON.stringify(ENTER)}`,
    ]);
  });

  test("a choice picked in the terminal (agent_start) closes the client prompt", () => {
    const omp = fakeOmp();
    proposeAndOpen(omp);
    omp.c.onTerminalInput(ENTER);
    omp.state.mode = "none"; // captured: "Approve and keep context" runs in place
    omp.c.onAgentStart();
    expect(omp.notifies(REVIEW_ID)).toEqual([expect.objectContaining({ message: "Plan approved." })]);
    expect(omp.states().at(-1)).toEqual({ type: "plan_state", status: "idle" });

    answer(omp, "approve_compact");
    vi.runAllTimers();
    expect(omp.keys()).toEqual([]);
    expect(omp.notifies(REVIEW_ID).at(-1)).toMatchObject({ message: "Plan mode is no longer active." });
  });

  test("session_switch (Approve and execute / Save and quit in the terminal) closes it too", () => {
    const omp = fakeOmp();
    proposeAndOpen(omp);
    omp.state.mode = "none"; // the new session has no mode_change entry
    omp.c.onSessionChange();
    expect(omp.notifies(REVIEW_ID)).toEqual([expect.objectContaining({ message: "Plan approved." })]);
    expect(omp.c.syncFrames()).toEqual([{ type: "plan_state", status: "idle" }]);
  });

  test("a terminal line typed while the review is up means the overlay is gone", () => {
    const omp = fakeOmp();
    proposeAndOpen(omp);
    omp.c.onInput("Refine: add a fourth bullet");
    expect(omp.notifies(REVIEW_ID)).toEqual([
      expect.objectContaining({ message: "Plan review closed in the terminal." }),
    ]);
  });

  test("/plan-review typed in the terminal re-opens a client prompt", () => {
    const omp = fakeOmp();
    omp.c.onInput("/plan-review");
    const req = omp.sent.find((m) => m.type === "extension_ui_request");
    expect(req).toMatchObject({ method: "select", title: "Plan ready for review: hello-txt" });
    expect(req?.id.startsWith("plan-review:reopen-")).toBe(true);
  });
});

describe("plan_mode from a client", () => {
  test("exit steps through omp's 'Exit plan mode?' confirm (Yes) and then /plan again", () => {
    const omp = fakeOmp({ mode: "plan" });
    omp.c.refresh(); // plan mode was entered earlier: the clients know "active"
    // A local plan exists, so the state names it: clients ask omp's
    // "Exit plan mode?" before sending exit, as omp will.
    expect(omp.states()).toEqual([
      { type: "plan_state", status: "active", plan_file_path: "local://hello-txt-plan.md", title: "hello-txt" },
    ]);
    expect(omp.c.planMode("exit")).toBeNull();
    vi.advanceTimersByTime(400);
    expect(omp.state.mode).toBe("plan_paused");
    vi.runAllTimers();

    expect(omp.io).toEqual(["line:/plan", `key:${JSON.stringify(ENTER)}`, "line:/plan"]);
    expect(omp.state.mode).toBe("none");
    expect(omp.states().at(-1)).toEqual({ type: "plan_state", status: "idle" });
  });

  test("exit with no plan file: no confirm, no stray Enter", () => {
    const omp = fakeOmp({ mode: "plan", planFile: false });
    expect(omp.c.planMode("exit")).toBeNull();
    vi.runAllTimers();
    expect(omp.io).toEqual(["line:/plan", "line:/plan"]);
    expect(omp.state.mode).toBe("none");
  });

  test("exit while the review is open closes the overlay before /plan", () => {
    const omp = fakeOmp({ mode: "plan" });
    proposeAndOpen(omp);
    expect(omp.c.planMode("exit")).toBeNull();
    vi.runAllTimers();
    expect(omp.io).toEqual([
      `key:${JSON.stringify(ESC)}`,
      `key:${JSON.stringify(ESC)}`,
      "line:/plan",
      `key:${JSON.stringify(ENTER)}`,
      "line:/plan",
    ]);
    expect(omp.state.mode).toBe("none");
  });

  test("enter runs /plan; review re-sends the open review or runs /plan-review", () => {
    const omp = fakeOmp({ mode: "none" });
    expect(omp.c.planMode("enter")).toBeNull();
    vi.runAllTimers();
    expect(omp.io).toEqual(["line:/plan"]);
    expect(omp.state.mode).toBe("plan");
    expect(omp.states().at(-1)).toEqual({
      type: "plan_state",
      status: "active",
      plan_file_path: "local://hello-txt-plan.md",
      title: "hello-txt",
    });

    expect(omp.c.planMode("review")).toBeNull();
    expect(omp.io.at(-1)).toBe("line:/plan-review");
  });

  test("headless (no omp TUI): plan_mode and answers report that plan mode needs the terminal", () => {
    const omp = fakeOmp({ mode: "none", terminal: false });
    expect(omp.c.planMode("enter")).toBe(PLAN_MODE_NEEDS_TERMINAL);

    omp.state.mode = "plan";
    omp.c.onToolEnd(PROPOSE_EVENT);
    answer(omp, "approve_execute");
    expect(omp.keys()).toEqual([]);
    expect(omp.notifies(REVIEW_ID).at(-1)).toMatchObject({
      message: PLAN_MODE_NEEDS_TERMINAL,
      notify_type: "warning",
    });
  });
});

describe("state frames", () => {
  test("syncFrames: idle, then the review after its state, then active with the plan", () => {
    const omp = fakeOmp({ mode: "none" });
    expect(omp.c.syncFrames()).toEqual([{ type: "plan_state", status: "idle" }]);

    omp.state.mode = "plan";
    omp.c.onToolEnd(PROPOSE_EVENT);
    const frames = omp.c.syncFrames();
    expect(frames.map((f) => f.type)).toEqual(["plan_state", "extension_ui_request"]);
    expect(frames[0]).toMatchObject({ status: "review" });
    expect(frames[1]).toMatchObject({ id: REVIEW_ID, method: "select" });
  });

  test("an unchanged idle state is never broadcast (non-plan sessions stay quiet)", () => {
    const omp = fakeOmp({ mode: "none" });
    omp.c.onAgentStart();
    omp.c.onAgentEnd();
    omp.c.refresh();
    expect(omp.sent).toEqual([]);
  });

  test("reviewOpen is true only while omp's overlay has focus", () => {
    const omp = fakeOmp();
    omp.c.onToolEnd(PROPOSE_EVENT);
    expect(omp.c.reviewOpen()).toBe(false);
    omp.c.onAgentEnd();
    vi.advanceTimersByTime(400);
    expect(omp.c.reviewOpen()).toBe(true);
    omp.c.onTerminalInput(ESC);
    expect(omp.c.reviewOpen()).toBe(false);
  });
});

describe("omp session readers", () => {
  let dir: string;
  beforeEach(() => {
    dir = mkdtempSync(join(tmpdir(), "plan-review-"));
  });
  afterEach(() => {
    rmSync(dir, { recursive: true, force: true });
  });

  test("ompPlanMode follows the latest mode_change entry", () => {
    const sm = (entries: Array<{ type: string; mode?: string }>) => ({ getEntries: () => entries });
    expect(ompPlanMode(sm([]))).toBe("none");
    expect(ompPlanMode(sm([{ type: "mode_change", mode: "plan" }, { type: "message" }]))).toBe("plan");
    expect(ompPlanMode(sm([{ type: "mode_change", mode: "plan" }, { type: "mode_change", mode: "plan_paused" }]))).toBe("plan_paused");
    expect(ompPlanMode(sm([{ type: "mode_change", mode: "plan" }, { type: "mode_change", mode: "none" }]))).toBe("none");
    expect(ompPlanMode(null)).toBe("none");
  });

  test("local:// plans resolve under the session's artifacts dir, newest first", () => {
    const local = join(dir, "local");
    mkdirSync(local);
    writeFileSync(join(local, "hello-txt-plan.md"), PLAN_MARKDOWN);
    writeFileSync(join(local, "bye-txt-plan.md"), "# bye");
    writeFileSync(join(local, "notes.md"), "not a plan");
    utimesSync(join(local, "hello-txt-plan.md"), 1, 1);
    const sm = { getArtifactsDir: () => dir, getSessionId: () => "s1" };

    expect(readPlanFile("local://hello-txt-plan.md", sm, "/nowhere")).toBe(PLAN_MARKDOWN);
    expect(readPlanFile("local://../escape-plan.md", sm, "/nowhere")).toBeNull();
    expect(localPlanFiles(sm)).toEqual(["local://bye-txt-plan.md", "local://hello-txt-plan.md"]);
  });
});
