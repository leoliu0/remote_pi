import { afterEach, beforeEach, describe, expect, test, vi } from "vitest";
import {
  ACTIVITY_FINISHED_LINGER_MS,
  ACTIVITY_MIN_INTERVAL_MS,
  ActivityBroadcaster,
  ActivityTracker,
} from "./activity.js";
import type { AgentActivityJob, ServerMessage } from "./protocol/types.js";

// Payloads captured from a real omp v18.8.7 run (scratch session, RPC mode):
// one async `sleep 20` bash job, then one `task` call spawning AgentA/AgentB.
const SPAWN_MS = 1791581635609;
const ajmRunning = {
  running: [
    { id: "bg_1", type: "bash", status: "running", label: "sleep 20", command: "sleep 20", startTime: 1791581631774 },
    { id: "AgentA", type: "task", status: "running", label: "AgentA", startTime: SPAWN_MS, agentId: "AgentA" },
    { id: "AgentB", type: "task", status: "running", label: "AgentB", startTime: SPAWN_MS, agentId: "AgentB" },
  ],
  recent: [],
  delivery: { queued: 0, delivering: false, pendingJobIds: [] },
};
const startedB = {
  id: "AgentB", agent: "task", parentToolCallId: "toolu_01Kd68jzyNvXctk692znDP89", detached: true,
  agentSource: "bundled", status: "started", sessionFile: "/tmp/omp-task-159ff2e508385b37/AgentB.jsonl", index: 1,
};
const startedA = {
  id: "AgentA", agent: "task", parentToolCallId: "toolu_01Kd68jzyNvXctk692znDP89", detached: true,
  agentSource: "bundled", status: "started", sessionFile: "/tmp/omp-task-159ff2e508385b36/AgentA.jsonl", index: 0,
};
const completedA = {
  ...startedA, description: "Run sleep command and report echo output", status: "completed",
};
const assignmentB = "# Target\nRun with the bash tool: `sleep 8 && echo beta`\n# Acceptance\nReport the exact output.";
const progressB = {
  index: 1, agent: "task", agentSource: "bundled", parentToolCallId: "toolu_01Kd68jzyNvXctk692znDP89",
  detached: true, assignment: assignmentB,
  progress: {
    index: 1, id: "AgentB", agent: "task", agentSource: "bundled", status: "running", assignment: assignmentB,
    description: "Run sleep command and report echoed output", lastIntent: "Running sleep then echo",
    toolCount: 1, requests: 1, tokens: 1589, cost: 0.01604, durationMs: 2061, modelRole: "task",
    contextWindow: 1000000, resolvedModel: "anthropic/claude-opus-5-5:high", contextTokens: 13209,
    currentTool: "bash", currentToolArgs: "sleep 8 && echo beta", currentToolArgsKey: "command",
    currentToolStartMs: 1791581637677, currentToolIntent: "Running sleep then echo",
  },
  sessionFile: "/tmp/omp-task-159ff2e508385b37/AgentB.jsonl",
};

describe("ActivityTracker", () => {
  test("builds the omp panel from real job snapshots and subagent events", () => {
    const t = new ActivityTracker();
    t.applyJobSnapshot(ajmRunning, SPAWN_MS + 1);
    t.onLifecycle(startedB, SPAWN_MS + 68);
    t.onLifecycle(startedA, SPAWN_MS + 81);
    t.onProgress(progressB, SPAWN_MS + 2100);

    expect(t.snapshot(SPAWN_MS + 2200)).toEqual<AgentActivityJob[]>([
      { id: "bg_1", kind: "bash", label: "sleep 20", command: "sleep 20", status: "running", started_at: 1791581631774 },
      {
        id: "AgentA", kind: "subagent", label: "AgentA", status: "running", started_at: SPAWN_MS,
        agent: "task", parent_tool_call_id: "toolu_01Kd68jzyNvXctk692znDP89",
      },
      {
        id: "AgentB", kind: "subagent", label: "Run sleep command and report echoed output", status: "running",
        started_at: SPAWN_MS, agent: "task", parent_tool_call_id: "toolu_01Kd68jzyNvXctk692znDP89",
        description: "Run sleep command and report echoed output", assignment: assignmentB,
        detail: "Running sleep then echo",
        progress: {
          tool: "bash", tool_args: "sleep 8 && echo beta", tool_started_at: 1791581637677,
          tool_count: 1, tokens: 1589, cost: 0.01604,
        },
      },
    ]);
  });

  test("completion: subagent rows settle, linger, then drop; late progress is ignored", () => {
    const t = new ActivityTracker();
    t.onLifecycle(startedA, 1_000);
    t.onLifecycle(completedA, 9_000);
    t.onProgress({ ...progressB, progress: { ...progressB.progress, id: "AgentA" } }, 9_001);

    const [row] = t.snapshot(9_002);
    expect(row).toMatchObject({
      id: "AgentA", status: "done", started_at: 1_000, ended_at: 9_000,
      label: "Run sleep command and report echo output",
    });
    expect(row).not.toHaveProperty("detail");
    expect(t.snapshot(9_000 + ACTIVITY_FINISHED_LINGER_MS)).toEqual([]);
    expect(t.hasRows()).toBe(false);
  });

  test("bash job completion comes from omp's `recent` list with its end time", () => {
    const t = new ActivityTracker();
    t.applyJobSnapshot({
      running: [{ id: "bg_1", type: "bash", status: "running", label: "sleep 4", command: "sleep 4", startTime: 1791581796129 }],
      recent: [],
    });
    t.applyJobSnapshot({
      running: [],
      recent: [{ id: "bg_1", type: "bash", status: "completed", label: "sleep 4", command: "sleep 4", startTime: 1791581796129, endTime: 1791581800156 }],
    }, 1791581800157);
    expect(t.snapshot(1791581800200)).toEqual([{
      id: "bg_1", kind: "bash", label: "sleep 4", command: "sleep 4", status: "done",
      started_at: 1791581796129, ended_at: 1791581800156,
    }]);
  });

  test("clearFinished (main agent_end) keeps running rows; failures map to failed", () => {
    const t = new ActivityTracker();
    t.applyJobSnapshot(ajmRunning, 1);
    t.onLifecycle(startedA, 2);
    t.onLifecycle({ ...startedA, status: "failed" }, 3);
    t.applyJobSnapshot({ ...ajmRunning, running: ajmRunning.running.filter((j) => j.id !== "AgentA") }, 4);
    expect(t.snapshot(5).map((r) => [r.id, r.status])).toEqual([
      ["bg_1", "running"], ["AgentA", "failed"], ["AgentB", "running"],
    ]);
    t.clearFinished();
    expect(t.snapshot(6).map((r) => r.id)).toEqual(["bg_1", "AgentB"]);
  });

  test("ignores malformed payloads and off-omp hosts (null snapshot)", () => {
    const t = new ActivityTracker();
    t.applyJobSnapshot(null);
    t.onLifecycle({ status: "started" });
    t.onLifecycle({ ...completedA });  // end of a run never seen
    t.onProgress({ progress: {} });
    expect(t.snapshot()).toEqual([]);
  });
});

describe("ActivityBroadcaster", () => {
  beforeEach(() => { vi.useFakeTimers(); });
  afterEach(() => { vi.useRealTimers(); });

  function harness(canSend = () => true) {
    let jobs: AgentActivityJob[] = [];
    const sent: Array<Extract<ServerMessage, { type: "agent_activity" }>> = [];
    const b = new ActivityBroadcaster(
      () => jobs,
      (msg) => { if (msg.type === "agent_activity") sent.push(msg); },
      canSend,
      () => Date.now(),
    );
    const set = (id: string, tokens: number) => {
      jobs = [{ id, kind: "subagent", label: id, status: "running", started_at: 1, progress: { tokens } }];
    };
    return { b, sent, set, clear: () => { jobs = []; } };
  }

  test("at most 2 snapshots per second: leading send, one trailing send per window", () => {
    const { b, sent, set } = harness();
    set("AgentA", 1);
    b.schedule();
    expect(sent).toHaveLength(1);
    // omp emits progress every ~150 ms per subagent.
    for (let tokens = 2; tokens <= 6; tokens++) {
      vi.advanceTimersByTime(80);
      set("AgentA", tokens);
      b.schedule();
    }
    expect(sent).toHaveLength(1);
    vi.advanceTimersByTime(ACTIVITY_MIN_INTERVAL_MS - 400);
    expect(sent).toHaveLength(2);
    expect(sent[1]!.jobs[0]!.progress?.tokens).toBe(6);
    expect(sent[1]!.ts - sent[0]!.ts).toBe(ACTIVITY_MIN_INTERVAL_MS);
  });

  test("identical snapshots are not re-sent; an emptied panel is", () => {
    const { b, sent, set, clear } = harness();
    set("AgentA", 1);
    b.schedule();
    vi.advanceTimersByTime(ACTIVITY_MIN_INTERVAL_MS);
    b.schedule();
    vi.advanceTimersByTime(ACTIVITY_MIN_INTERVAL_MS);
    expect(sent).toHaveLength(1);
    clear();
    b.schedule();
    expect(sent.map((m) => m.jobs)).toEqual([sent[0]!.jobs, []]);
  });

  test("nothing goes out without an owner; the change is sent once one is", () => {
    let owner = false;
    const { b, sent, set } = harness(() => owner);
    set("AgentA", 1);
    b.schedule();
    expect(sent).toHaveLength(0);
    owner = true;
    vi.advanceTimersByTime(ACTIVITY_MIN_INTERVAL_MS);
    b.schedule();
    expect(sent).toHaveLength(1);
  });
});
