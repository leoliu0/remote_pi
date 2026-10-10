import { test } from "node:test";
import assert from "node:assert/strict";
import {
  AGENTS_PANEL_KEY,
  EMPTY_BOARD,
  FINISHED_MAX,
  agentRowView,
  agentsSummary,
  applyActivitySnapshot,
  clearFinished,
  formatCost,
  formatElapsed,
  formatTokens,
  parseAgentActivity,
  readAgentsPanelOpen,
  writeAgentsPanelOpen,
  type AgentActivityJob,
} from "./activity.ts";

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

const running = (id: string, started_at = 0): AgentActivityJob => ({ id, kind: "subagent", label: id, status: "running", started_at });

test("board: running rows that vanish move to finished as ✓ frozen at the vanishing snapshot", () => {
  let board = applyActivitySnapshot(EMPTY_BOARD, parseAgentActivity(RUNNING_FRAME)!, SPAWN_MS + 2200);
  assert.deepEqual(board.running.map((j) => j.id), ["bg_1", "AgentA", "AgentB"]);
  assert.deepEqual(board.finished, []);
  // agent_end: `[]` — everything still running settles as done at `now`.
  board = applyActivitySnapshot(board, [], SPAWN_MS + 9000);
  assert.deepEqual(board.running, []);
  assert.deepEqual(board.finished.map((j) => [j.id, j.status, j.ended_at]), [
    ["bg_1", "done", SPAWN_MS + 9000],
    ["AgentA", "done", SPAWN_MS + 9000],
    ["AgentB", "done", SPAWN_MS + 9000],
  ]);
  assert.equal(agentRowView(board.finished[1], SPAWN_MS + 99_000).elapsed, "9.0s");
  assert.equal(agentsSummary(board), "Agents · 0 running · 3 finished");
});

test("board: explicit done/failed keep their status and ended_at; lingering repeats dedupe by id", () => {
  let board = applyActivitySnapshot(EMPTY_BOARD, [running("A", 0), running("B", 0)], 1000);
  const doneA = { ...running("A", 0), status: "done" as const, ended_at: 4000 };
  const failedB = { ...running("B", 0), status: "failed" as const, ended_at: 5000 };
  board = applyActivitySnapshot(board, [doneA, failedB], 5100);
  board = applyActivitySnapshot(board, [doneA, failedB], 5600); // linger re-sent
  board = applyActivitySnapshot(board, [], 11_000); // dropped after 5 s
  assert.deepEqual(board.finished.map((j) => [j.id, j.status, j.ended_at]), [
    ["B", "failed", 5000],
    ["A", "done", 4000],
  ]);
  assert.equal(agentsSummary(board), "Agents · 0 running · 2 finished");
  // A finished row reported without ended_at freezes at arrival.
  board = applyActivitySnapshot(board, [{ ...running("C", 0), status: "cancelled" }], 12_000);
  assert.deepEqual(board.finished[0], { ...running("C", 0), status: "cancelled", ended_at: 12_000 });
  // An id that runs again leaves the finished list.
  board = applyActivitySnapshot(board, [running("A", 13_000)], 13_000);
  assert.deepEqual(board.running.map((j) => j.id), ["A"]);
  assert.deepEqual(board.finished.map((j) => j.id), ["C", "B"]);
});

test("board: clear on send keeps running rows; finished capped at 20, newest first", () => {
  let board = EMPTY_BOARD;
  for (let i = 0; i < 25; i++) {
    board = applyActivitySnapshot(board, [running(`J${i}`, i)], i * 10);
  }
  board = applyActivitySnapshot(board, [running("live", 300)], 300);
  assert.equal(board.finished.length, FINISHED_MAX);
  assert.equal(board.finished[0].id, "J24");
  assert.equal(board.finished.at(-1)?.id, "J5");
  const cleared = clearFinished(board);
  assert.deepEqual(cleared, { running: board.running, finished: [] });
  assert.equal(clearFinished(cleared), cleared);
});

test("row view from the captured running example", () => {
  const [bash, a, b] = parseAgentActivity(RUNNING_FRAME)!;
  const now = SPAWN_MS + 2200;
  assert.deepEqual(agentRowView(bash, now), {
    name: "bg_1", badge: "bash", summary: "sleep 20", activity: null, elapsed: "6.0s", chips: [],
  });
  // A label that only repeats the id is not shown twice.
  assert.deepEqual(agentRowView(a, now), {
    name: "AgentA", badge: "subagent", summary: null, activity: null, elapsed: "2.2s", chips: [],
  });
  assert.deepEqual(agentRowView(b, now), {
    name: "AgentB",
    badge: "subagent",
    summary: "Run sleep command and report echoed output",
    activity: "Running sleep then echo",
    elapsed: "2.2s",
    chips: [
      { label: "tools", value: "1" },
      { label: "tokens", value: "1.6k" },
      { label: "cost", value: "$0.016" },
    ],
  });
  // Without detail the activity is `<tool> <tool_args>`; finished rows show none.
  assert.equal(agentRowView({ ...b, detail: undefined }, now).activity, "bash sleep 8 && echo beta");
  assert.equal(agentRowView({ ...b, status: "done", ended_at: now }, now).activity, null);
});

test("finished rows freeze at ended_at; jobs badge with their type", () => {
  const done: AgentActivityJob = {
    id: "bg_1", kind: "bash", label: "sleep 4", command: "sleep 4", status: "done",
    started_at: 1791581796129, ended_at: 1791581800156,
  };
  assert.equal(agentRowView(done, done.ended_at! + 90_000).elapsed, "4.0s");
  const job: AgentActivityJob = { id: "j1", kind: "job", label: "index", job_type: "index", status: "failed", started_at: 0, ended_at: 125_000 };
  assert.deepEqual(agentRowView(job, 999_999), {
    name: "j1", badge: "index", summary: "index", activity: null, elapsed: "2m 05s", chips: [],
  });
  assert.equal(agentRowView({ ...job, job_type: undefined }, 0).badge, "job");
});

test("token and cost chips", () => {
  assert.equal(formatTokens(950), "950");
  assert.equal(formatTokens(1589), "1.6k");
  assert.equal(formatTokens(2_340_000), "2.3M");
  assert.equal(formatCost(0.01604), "$0.016");
  assert.equal(formatCost(1.5), "$1.50");
});

test("open/closed preference: default open, persisted as open/closed", () => {
  const store = new Map<string, string>();
  const g = globalThis as { localStorage?: unknown };
  const saved = g.localStorage;
  g.localStorage = {
    getItem: (k: string) => store.get(k) ?? null,
    setItem: (k: string, v: string) => void store.set(k, v),
  };
  try {
    assert.equal(readAgentsPanelOpen(), true);
    writeAgentsPanelOpen(false);
    assert.equal(store.get(AGENTS_PANEL_KEY), "closed");
    assert.equal(readAgentsPanelOpen(), false);
    writeAgentsPanelOpen(true);
    assert.equal(store.get(AGENTS_PANEL_KEY), "open");
    assert.equal(readAgentsPanelOpen(), true);
    store.set(AGENTS_PANEL_KEY, "garbage");
    assert.equal(readAgentsPanelOpen(), true);
  } finally {
    g.localStorage = saved;
  }
  // No storage (SSR / blocked): open, and writing does not throw.
  assert.equal(readAgentsPanelOpen(), true);
  writeAgentsPanelOpen(false);
});
