import { test } from "node:test";
import assert from "node:assert/strict";
import { activityHeader, activityLines, formatElapsed, parseAgentActivity, type AgentActivityJob } from "./activity.ts";

// Snapshot captured from a real omp run (pi-extension activity.test.ts): one
// async `sleep 20` bash job, then one `task` call spawning AgentA/AgentB.
const SPAWN_MS = 1791581635609;
const RUNNING_FRAME = {
  type: "agent_activity",
  ts: SPAWN_MS + 2200,
  jobs: [
    { id: "bg_1", kind: "bash", label: "sleep 20", command: "sleep 20", status: "running", started_at: 1791581631774 },
    {
      id: "AgentA", kind: "subagent", label: "AgentA", status: "running", started_at: SPAWN_MS,
      agent: "task", parent_tool_call_id: "toolu_01Kd68jzyNvXctk692znDP89",
    },
    {
      id: "AgentB", kind: "subagent", label: "Run sleep command and report echoed output", status: "running",
      started_at: SPAWN_MS, agent: "task", parent_tool_call_id: "toolu_01Kd68jzyNvXctk692znDP89",
      description: "Run sleep command and report echoed output",
      assignment: "# Target\nRun with the bash tool: `sleep 8 && echo beta`\n# Acceptance\nReport the exact output.",
      detail: "Running sleep then echo",
      progress: {
        tool: "bash", tool_args: "sleep 8 && echo beta", tool_started_at: 1791581637677,
        tool_count: 1, tokens: 1589, cost: 0.01604,
      },
    },
  ],
};

test("parses a full snapshot and drops malformed rows", () => {
  const jobs = parseAgentActivity(RUNNING_FRAME)!;
  assert.deepEqual(jobs.map((j) => [j.id, j.kind, j.status]), [
    ["bg_1", "bash", "running"],
    ["AgentA", "subagent", "running"],
    ["AgentB", "subagent", "running"],
  ]);
  assert.equal(jobs[2].progress?.tokens, 1589);
  assert.equal(jobs[2].parent_tool_call_id, "toolu_01Kd68jzyNvXctk692znDP89");
  const messy = parseAgentActivity({
    type: "agent_activity",
    jobs: [{ id: "x", kind: "nope", status: "running", started_at: 1 }, { id: "y", kind: "job", status: "done", started_at: 1 }, null, "z"],
  });
  // Unknown kind and non-objects are dropped; a missing label falls back to the id.
  assert.deepEqual(messy?.map((j) => [j.id, j.label]), [["y", "y"]]);
  assert.equal(parseAgentActivity({ type: "agent_activity" }), null);
  assert.equal(parseAgentActivity({ type: "tool_result", jobs: [] }), null);
});

test("each frame replaces the list wholesale (no merge)", () => {
  let panel: AgentActivityJob[] = parseAgentActivity(RUNNING_FRAME)!;
  panel = parseAgentActivity({
    type: "agent_activity",
    jobs: [{ id: "bg_1", kind: "bash", label: "sleep 4", command: "sleep 4", status: "done", started_at: 1791581796129, ended_at: 1791581800156 }],
  })!;
  assert.deepEqual(panel.map((j) => j.id), ["bg_1"]);
  panel = parseAgentActivity({ type: "agent_activity", jobs: [], ts: 1 })!;
  assert.deepEqual(panel, []);
});

test("formatElapsed: tenths under a minute, else m + zero-padded s", () => {
  assert.equal(formatElapsed(0), "0.0s");
  assert.equal(formatElapsed(12_345), "12.3s");
  assert.equal(formatElapsed(59_999), "59.9s");
  assert.equal(formatElapsed(60_000), "1m 00s");
  assert.equal(formatElapsed(65_400), "1m 05s");
  assert.equal(formatElapsed(3_725_000), "62m 05s");
  assert.equal(formatElapsed(-5), "0.0s");
});

test("header counts running rows only", () => {
  const jobs = parseAgentActivity(RUNNING_FRAME)!;
  assert.equal(activityHeader(jobs), "waiting on 3 jobs");
  assert.equal(activityHeader(jobs.slice(0, 1)), "waiting on 1 job");
  assert.equal(activityHeader([{ ...jobs[0], status: "done", ended_at: jobs[0].started_at + 1 }]), "waiting on 0 jobs");
});

test("lines from the captured running example", () => {
  const [bash, a, b] = parseAgentActivity(RUNNING_FRAME)!;
  const now = SPAWN_MS + 2200;
  assert.deepEqual(activityLines(bash, now), { main: "└─ bg_1 sleep 20 · 6.0s", sub: null });
  assert.deepEqual(activityLines(a, now), { main: "└─ AgentA AgentA · 2.2s", sub: null });
  assert.deepEqual(activityLines(b, now), {
    main: "└─ AgentB Run sleep command and report echoed output · 2.2s",
    sub: "Running sleep then echo · 1 tools · 1.6k tok",
  });
  // Without detail the sub line is `<tool> <tool_args>`.
  assert.equal(activityLines({ ...b, detail: undefined }, now).sub, "bash sleep 8 && echo beta · 1 tools · 1.6k tok");
});

test("finished rows freeze at ended_at", () => {
  const done: AgentActivityJob = {
    id: "bg_1", kind: "bash", label: "sleep 4", command: "sleep 4", status: "done",
    started_at: 1791581796129, ended_at: 1791581800156,
  };
  assert.equal(activityLines(done, done.ended_at! + 90_000).main, "└─ bg_1 sleep 4 · 4.0s");
  const job: AgentActivityJob = { id: "j1", kind: "job", label: "index", job_type: "index", status: "failed", started_at: 0, ended_at: 125_000 };
  assert.deepEqual(activityLines(job, 999_999), { main: "└─ j1 index · 2m 05s", sub: null });
});
