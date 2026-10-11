import { test } from "node:test";
import assert from "node:assert/strict";
import {
  activePhaseIndex,
  currentTask,
  parseTodoState,
  phaseTitle,
  todoCount,
  todoPill,
  type TodoPhase,
} from "./todo.ts";

// The list after omp v18.9.2's `drop Ship` in a captured scratch run (init with
// Setup/Build, done, start out of order, block, append, drop), as the
// pi-extension sends it.
const afterDrop = {
  type: "todo_state",
  ts: 1791587119493,
  phases: [
    { name: "Setup", tasks: [{ content: "Create repo", status: "completed" }, { content: "Add CI", status: "pending" }] },
    {
      name: "Build",
      tasks: [
        { content: "Write parser", status: "in_progress" },
        { content: "Write tests", status: "blocked", blocker: "waiting on fixtures" },
        { content: "Ship", status: "abandoned" },
        { content: "Write docs", status: "pending" },
      ],
    },
  ],
};

test("parseTodoState keeps the list; drops malformed tasks and empty phases", () => {
  const phases = parseTodoState(afterDrop)!;
  assert.equal(phases.length, 2);
  assert.deepEqual(phases[1].tasks[1], { content: "Write tests", status: "blocked", blocker: "waiting on fixtures" });
  assert.deepEqual(
    parseTodoState({ type: "todo_state", phases: [{ name: "E", tasks: [] }, { name: "B", tasks: [{ content: "x", status: "weird" }, { content: "y", status: "pending" }] }] }),
    [{ name: "B", tasks: [{ content: "y", status: "pending" }] }],
  );
  assert.deepEqual(parseTodoState({ type: "todo_state", phases: [] }), []);
  assert.equal(parseTodoState({ type: "agent_activity", jobs: [] }), null);
});

test("counts like omp: dropped tasks count as done", () => {
  const phases = parseTodoState(afterDrop)!;
  assert.deepEqual(todoCount(phases.flatMap((p) => p.tasks)), { done: 2, total: 6 });
  assert.deepEqual(todoCount(phases[1].tasks), { done: 1, total: 4 });
});

test("active phase: first with pending/in-progress work, else the last", () => {
  const phases = parseTodoState(afterDrop)!;
  // Setup still has a pending task, so it stays active while Build's task runs (omp TUI did the same).
  assert.equal(activePhaseIndex(phases), 0);
  const allDone: TodoPhase[] = phases.map((p) => ({ ...p, tasks: p.tasks.map((t) => ({ ...t, status: "completed" as const })) }));
  assert.equal(activePhaseIndex(allDone), 1);
  const onlyBlocked: TodoPhase[] = [{ name: "A", tasks: [{ content: "a", status: "completed" }] }, { name: "B", tasks: [{ content: "b", status: "blocked" }] }];
  assert.equal(activePhaseIndex(onlyBlocked), 1);
});

test("phase titles get Roman numerals only when there are several phases", () => {
  assert.equal(phaseTitle("Setup", 0, 2), "I. Setup");
  assert.equal(phaseTitle("Build", 1, 2), "II. Build");
  assert.equal(phaseTitle("Ninth", 8, 9), "IX. Ninth");
  assert.equal(phaseTitle("Tasks", 0, 1), "Tasks");
});

test("current task is the in-progress one, else the first pending", () => {
  assert.equal(currentTask(parseTodoState(afterDrop)!)?.content, "Write parser");
  assert.equal(currentTask([{ name: "A", tasks: [{ content: "a", status: "completed" }, { content: "b", status: "pending" }] }])?.content, "b");
  assert.equal(currentTask([{ name: "A", tasks: [{ content: "a", status: "completed" }] }]), null);
});

test("todo tool pill: op while running, done/total from omp's result text, failures", () => {
  assert.deepEqual(todoPill({ op: "done", task: "Create repo" }, undefined, "pending"), { label: "Todo · done", detail: "Create repo" });
  // omp's result text for `drop Ship` (captured).
  const dropText = "Remaining items (3):\n  - Add CI [pending] (Setup)\n  - Write parser [in_progress] (Build)\n  - Write docs [pending] (Build)\nOverall: 2/6 done, 3 open, 1 blocked.\nActive phase 1/2 \"Setup\" (1/2).";
  assert.deepEqual(todoPill({ op: "drop", task: "Ship" }, dropText, "done"), { label: "Todo · 2/6", detail: "drop · Ship" });
  const initArgs = { op: "init", list: [{ phase: "Setup", items: ["Create repo", "Add CI"] }, { phase: "Build", items: ["Write parser"] }] };
  assert.deepEqual(todoPill(initArgs, "Remaining items (5):\nOverall: 0/5 done, 5 open.", "done"), { label: "Todo · 0/5", detail: "init · 2 phases" });
  assert.deepEqual(todoPill({ op: "append", phase: "Build", items: ["Write docs"] }, "Overall: 1/6 done, 4 open, 1 blocked.", "done").detail, "append · Build");
  assert.deepEqual(todoPill({ op: "done", task: "No such task" }, "Errors: Task \"No such task\" not found", "error"), { label: "Todo · failed", detail: "done · No such task" });
  assert.deepEqual(todoPill({ op: "rm" }, "Todo list cleared.", "done"), { label: "Todo · cleared", detail: "rm" });
});
