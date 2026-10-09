// The `agent_activity` panel (omp's bottom "waiting on N jobs" list): running
// subagents and background jobs. Wire contract: pi-extension
// src/protocol/types.ts `AgentActivityJob`. Every frame is a FULL snapshot —
// the client replaces its list, never merges. Elapsed time is not on the wire;
// it is computed here and ticks client-side. Strings match the phone app.

export type AgentActivityStatus = "running" | "done" | "failed" | "cancelled";
export type AgentActivityKind = "subagent" | "bash" | "job";

export interface AgentActivityProgress {
  tool?: string;
  tool_args?: string;
  tool_started_at?: number;
  tool_count?: number;
  tokens?: number;
  cost?: number;
  percent?: number;
}

export interface AgentActivityJob {
  id: string;
  kind: AgentActivityKind;
  label: string;
  status: AgentActivityStatus;
  started_at: number;
  ended_at?: number;
  agent?: string;
  description?: string;
  assignment?: string;
  parent_tool_call_id?: string;
  command?: string;
  job_type?: string;
  detail?: string;
  progress?: AgentActivityProgress;
}

const KINDS: readonly AgentActivityKind[] = ["subagent", "bash", "job"];
const STATUSES: readonly AgentActivityStatus[] = ["running", "done", "failed", "cancelled"];

function optString(v: unknown): string | undefined {
  return typeof v === "string" && v !== "" ? v : undefined;
}

function optNumber(v: unknown): number | undefined {
  return typeof v === "number" && Number.isFinite(v) ? v : undefined;
}

/** Wire fields as received: present or not, any type until checked. */
type Unchecked<K extends string> = Partial<Record<K, unknown>>;

function parseProgress(raw: unknown): AgentActivityProgress | undefined {
  if (typeof raw !== "object" || raw === null) return undefined;
  const p = raw as Unchecked<keyof AgentActivityProgress>;
  return {
    tool: optString(p.tool),
    tool_args: optString(p.tool_args),
    tool_started_at: optNumber(p.tool_started_at),
    tool_count: optNumber(p.tool_count),
    tokens: optNumber(p.tokens),
    cost: optNumber(p.cost),
    percent: optNumber(p.percent),
  };
}

function parseJob(raw: unknown): AgentActivityJob | null {
  if (typeof raw !== "object" || raw === null) return null;
  const j = raw as Unchecked<keyof AgentActivityJob>;
  const kind = KINDS.find((k) => k === j.kind);
  const status = STATUSES.find((s) => s === j.status);
  const startedAt = optNumber(j.started_at);
  if (typeof j.id !== "string" || !j.id || !kind || !status || startedAt === undefined) return null;
  return {
    id: j.id,
    kind,
    label: optString(j.label) ?? j.id,
    status,
    started_at: startedAt,
    ended_at: optNumber(j.ended_at),
    agent: optString(j.agent),
    description: optString(j.description),
    assignment: optString(j.assignment),
    parent_tool_call_id: optString(j.parent_tool_call_id),
    command: optString(j.command),
    job_type: optString(j.job_type),
    detail: optString(j.detail),
    progress: parseProgress(j.progress),
  };
}

/** `agent_activity` frame → the new full job list (null when not one). Malformed rows are dropped. */
export function parseAgentActivity(frame: Record<string, unknown>): AgentActivityJob[] | null {
  if (frame.type !== "agent_activity" || !Array.isArray(frame.jobs)) return null;
  return frame.jobs.flatMap((j) => parseJob(j) ?? []);
}

/** `12.3s` under a minute, else `1m 05s`. */
export function formatElapsed(ms: number): string {
  const safe = Math.max(0, ms);
  if (safe < 60_000) return `${(Math.floor(safe / 100) / 10).toFixed(1)}s`;
  const total = Math.floor(safe / 1000);
  return `${Math.floor(total / 60)}m ${String(total % 60).padStart(2, "0")}s`;
}

/** now − started_at while running; ended_at − started_at once finished. */
export function jobElapsedMs(job: AgentActivityJob, now: number): number {
  const end = job.status === "running" ? now : job.ended_at ?? now;
  return end - job.started_at;
}

/** `waiting on N job` / `waiting on N jobs`, N = running rows. */
export function activityHeader(jobs: readonly AgentActivityJob[]): string {
  const n = jobs.filter((j) => j.status === "running").length;
  return `waiting on ${n} ${n === 1 ? "job" : "jobs"}`;
}

export interface ActivityLines {
  main: string;
  /** Subagents only: what it is doing now, plus tool/token counters. */
  sub: string | null;
}

export function activityLines(job: AgentActivityJob, now: number): ActivityLines {
  const what = job.kind === "bash" ? job.command ?? job.label : job.label;
  const main = `└─ ${job.id} ${what} · ${formatElapsed(jobElapsedMs(job, now))}`;
  if (job.kind !== "subagent") return { main, sub: null };
  const p = job.progress;
  const doing = job.detail ?? (p?.tool ? [p.tool, p.tool_args].filter(Boolean).join(" ") : undefined);
  const parts = [
    doing,
    p?.tool_count !== undefined ? `${p.tool_count} tools` : undefined,
    p?.tokens !== undefined ? `${(p.tokens / 1000).toFixed(1)}k tok` : undefined,
  ].filter((s): s is string => !!s);
  return { main, sub: parts.length > 0 ? parts.join(" · ") : null };
}
