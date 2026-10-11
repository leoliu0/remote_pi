import { describe, expect, test } from "vitest";
import fixture from "./todo_state.fixture.json" with { type: "json" };
import { TodoBroadcaster, TodoTracker, latestTodoPhases, todoHudVisibility, todoPhasesFromToolResult } from "./todo_state.js";
import type { ServerMessage, TodoPhaseWire } from "./protocol/types.js";

// Captured from a scratch omp v18.9.2 session (see the fixture's _comment).
interface Run { args: { op?: string }; toolCallId: string; toolName: string; result: unknown; isError: boolean }
interface Entry { message?: { toolCallId?: string }; data?: Record<string, unknown> }
const runs: Run[] = fixture.toolExecutions;
const branch: Entry[] = fixture.branch;
const byOp = (op: string, nth = 0) => runs.filter((r) => r.args.op === op)[nth]!;
const brief = (phases: TodoPhaseWire[]) =>
  phases.map((p) => `${p.name}: ${p.tasks.map((t) => `${t.content}=${t.status}${t.blocker ? `(${t.blocker})` : ""}`).join(", ")}`);
/** Branch up to and including the entry persisting `toolCallId`'s result. */
const branchThrough = (toolCallId: string) =>
  branch.slice(0, branch.findIndex((e) => e.message?.toolCallId === toolCallId) + 1);

describe("todo tool results (omp rules)", () => {
  test("init auto-starts the first task; done advances; start moves the single in_progress", () => {
    expect(brief(todoPhasesFromToolResult(byOp("init").result, false)!)).toEqual([
      "Setup: Create repo=in_progress, Add CI=pending",
      "Build: Write parser=pending, Write tests=pending, Ship=pending",
    ]);
    expect(brief(todoPhasesFromToolResult(byOp("done").result, false)!)[0]).toBe("Setup: Create repo=completed, Add CI=in_progress");
    expect(brief(todoPhasesFromToolResult(byOp("start").result, false)!)).toEqual([
      "Setup: Create repo=completed, Add CI=pending",
      "Build: Write parser=in_progress, Write tests=pending, Ship=pending",
    ]);
  });

  test("block keeps the reason; append adds to the phase; drop abandons", () => {
    expect(brief(todoPhasesFromToolResult(byOp("block").result, false)!)[1])
      .toBe("Build: Write parser=in_progress, Write tests=blocked(waiting on fixtures), Ship=pending");
    expect(brief(todoPhasesFromToolResult(byOp("append").result, false)!)[1])
      .toBe("Build: Write parser=in_progress, Write tests=blocked(waiting on fixtures), Ship=pending, Write docs=pending");
    expect(brief(todoPhasesFromToolResult(byOp("drop").result, false)!)[1])
      .toBe("Build: Write parser=in_progress, Write tests=blocked(waiting on fixtures), Ship=abandoned, Write docs=pending");
  });

  test("view and failed ops change nothing (omp skips them)", () => {
    expect(todoPhasesFromToolResult(byOp("view").result, false)).toBeNull();
    const failed = byOp("done", 1);
    expect(failed.isError).toBe(true);
    expect(todoPhasesFromToolResult(failed.result, failed.isError)).toBeNull();
    expect(todoPhasesFromToolResult({ details: { op: "init", phases: [{ name: "X", tasks: [{ content: "a", status: "weird" }] }] } }, false)).toBeNull();
  });
});

describe("TodoTracker", () => {
  test("live tool results drive the snapshot; eval's nested todo comes from its user_todo_edit entry", () => {
    const t = new TodoTracker();
    for (const r of runs) {
      if (r.toolName === "todo") t.applyToolResult(r.toolCallId, r.result, r.isError);
      t.syncFromBranch(branchThrough(r.toolCallId));
      if (r.toolCallId === byOp("drop").toolCallId) {
        expect(brief(t.snapshot())[1]).toBe("Build: Write parser=in_progress, Write tests=blocked(waiting on fixtures), Ship=abandoned, Write docs=pending");
      }
      if (r.toolName === "eval") {
        expect(brief(t.snapshot())[0]).toBe("Setup: Create repo=completed, Add CI=completed");
      }
    }
    expect(t.snapshot().flatMap((p) => p.tasks).every((x) => x.status === "completed")).toBe(true);
  });

  test("rebuild from the branch equals the live list after every op", () => {
    const live = new TodoTracker();
    for (const r of runs.filter((x) => x.toolName === "todo")) {
      live.applyToolResult(r.toolCallId, r.result, r.isError);
      const rebuilt = new TodoTracker();
      rebuilt.syncFromBranch(branchThrough(r.toolCallId));
      expect(rebuilt.snapshot()).toEqual(live.snapshot());
    }
  });

  test("the TUI's auto-dismiss of a finished list hides it; a reveal or a new list shows it", () => {
    const t = new TodoTracker();
    t.syncFromBranch(branch);
    expect(t.snapshot()).toEqual([]);
    const withoutHud = branch.slice(0, -1);
    t.syncFromBranch(withoutHud);
    expect(t.snapshot().map((p) => p.name)).toEqual(["Setup", "Build"]);
    const hud = branch.at(-1)!;
    expect(todoHudVisibility(branch, latestTodoPhases(branch))).toBe("dismissed");
    t.syncFromBranch([...branch, { type: "custom", customType: "todo_hud_state", id: "r1", data: { ...hud.data, visibility: "revealed" } }]);
    expect(t.snapshot()).toHaveLength(2);
    const edit = { type: "custom", customType: "user_todo_edit", id: "e1", data: { phases: [{ name: "Next", tasks: [{ content: "a", status: "pending" }] }] } };
    t.syncFromBranch([...branch, edit]);
    expect(brief(t.snapshot())).toEqual(["Next: a=pending"]);
  });

  test("phases without tasks are dropped; no todo entries → empty", () => {
    const t = new TodoTracker();
    t.syncFromBranch([{ type: "custom", customType: "user_todo_edit", id: "e", data: { phases: [{ name: "Empty", tasks: [] }, { name: "B", tasks: [{ content: "x", status: "blocked" }] }] } }]);
    expect(brief(t.snapshot())).toEqual(["B: x=blocked"]);
    t.syncFromBranch([{ type: "message", id: "m", message: { role: "user", content: "hi" } }]);
    expect(t.snapshot()).toEqual([]);
  });

  test("a live result not yet persisted is not rolled back by a branch read", () => {
    let now = 0;
    const t = new TodoTracker(() => now);
    const init = byOp("init");
    t.applyToolResult(init.toolCallId, init.result, false);
    t.syncFromBranch([]);
    expect(t.snapshot()).toHaveLength(2);
    now = 5_000;
    t.syncFromBranch([]);
    expect(t.snapshot()).toEqual([]);
  });
});

describe("TodoBroadcaster", () => {
  test("sends only changes, only while an owner is active", () => {
    let phases: TodoPhaseWire[] = [];
    let active = false;
    const sent: ServerMessage[] = [];
    const b = new TodoBroadcaster(() => phases, (m) => sent.push(m), () => active, () => 42);
    phases = [{ name: "A", tasks: [{ content: "x", status: "pending" }] }];
    b.flush();
    expect(sent).toEqual([]);
    active = true;
    b.flush();
    b.flush();
    expect(sent).toEqual([{ type: "todo_state", phases, ts: 42 }]);
    phases = [];
    b.flush();
    expect(sent.at(-1)).toEqual({ type: "todo_state", phases: [], ts: 42 });
    expect(b.message()).toEqual({ type: "todo_state", phases: [], ts: 42 });
  });
});
