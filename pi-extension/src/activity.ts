/**
 * Running subagents + background jobs, mirrored from omp for the
 * `agent_activity` wire snapshot (see `AgentActivityJob` in protocol/types).
 *
 * Sources (all omp-only; plain pi has none, so the panel stays empty there):
 * - Subagents: the `task` tool emits `task:subagent:lifecycle` (started /
 *   completed / failed / aborted) and `task:subagent:progress` (~150 ms
 *   throttled) on the session event bus, which extensions see as `pi.events`.
 * - Background jobs: `ctx.getAsyncJobSnapshot()` returns the main session's
 *   AsyncJobManager view (`running` + `recent`). It has no change event, so
 *   the caller polls it while the agent runs or rows are live.
 */
import type {
  AgentActivityJob,
  AgentActivityProgress,
  AgentActivityStatus,
  ServerMessage,
} from "./protocol/types.js";

export const SUBAGENT_LIFECYCLE_CHANNEL = "task:subagent:lifecycle";
export const SUBAGENT_PROGRESS_CHANNEL = "task:subagent:progress";
/** Finished rows stay visible this long so clients can flash the outcome. */
export const ACTIVITY_FINISHED_LINGER_MS = 5_000;
/** At most 2 snapshots per second. */
export const ACTIVITY_MIN_INTERVAL_MS = 500;

const ASSIGNMENT_MAX = 300;
const LABEL_MAX = 120;
const TOOL_ARGS_MAX = 200;

function rec(value: unknown): Record<string, unknown> | undefined {
  return value !== null && typeof value === "object" && !Array.isArray(value)
    ? (value as Record<string, unknown>)
    : undefined;
}

function str(value: unknown): string | undefined {
  return typeof value === "string" && value.length > 0 ? value : undefined;
}

function num(value: unknown): number | undefined {
  return typeof value === "number" && Number.isFinite(value) ? value : undefined;
}

function clip(text: string, max: number): string {
  return text.length > max ? `${text.slice(0, max - 1)}…` : text;
}

function subagentStatus(raw: unknown): AgentActivityStatus {
  switch (raw) {
    case "started":
    case "running":
    case "pending":
      return "running";
    case "failed":
    case "error":
      return "failed";
    case "aborted":
    case "cancelled":
      return "cancelled";
    default:
      return "done";
  }
}

function jobStatus(raw: unknown): AgentActivityStatus {
  switch (raw) {
    case "running":
      return "running";
    case "failed":
      return "failed";
    case "cancelled":
      return "cancelled";
    default:
      return "done";
  }
}

function progressFrom(p: Record<string, unknown>): AgentActivityProgress | undefined {
  const out: AgentActivityProgress = {};
  const tool = str(p["currentTool"]);
  if (tool) {
    out.tool = tool;
    const args = str(p["currentToolArgs"]);
    if (args) out.tool_args = clip(args, TOOL_ARGS_MAX);
    const startedAt = num(p["currentToolStartMs"]);
    if (startedAt !== undefined) out.tool_started_at = startedAt;
  }
  const toolCount = num(p["toolCount"]);
  if (toolCount !== undefined) out.tool_count = toolCount;
  const tokens = num(p["tokens"]);
  if (tokens !== undefined) out.tokens = tokens;
  const cost = num(p["cost"]);
  if (cost !== undefined) out.cost = cost;
  const percent = num(p["completionPercent"]);
  if (percent !== undefined) out.percent = percent;
  return Object.keys(out).length > 0 ? out : undefined;
}

/** omp's own status-line wording: intent first, else `running <tool>`. */
function detailFrom(p: Record<string, unknown>): string | undefined {
  const intent = str(p["currentToolIntent"]) ?? str(p["lastIntent"]);
  if (intent) return clip(intent, LABEL_MAX);
  const tool = str(p["currentTool"]);
  return tool ? `running ${tool}` : undefined;
}

/** Merges omp's subagent events and async-job snapshots into panel rows. */
export class ActivityTracker {
  readonly #subagents = new Map<string, AgentActivityJob>();
  readonly #jobs = new Map<string, AgentActivityJob>();

  /** `task:subagent:lifecycle` payload. */
  onLifecycle(payload: unknown, now = Date.now()): void {
    const p = rec(payload);
    const id = str(p?.["id"]);
    if (!p || !id) return;
    const status = subagentStatus(p["status"]);
    const prior = this.#subagents.get(id);
    if (!prior && status !== "running") return;  // end of a run we never saw
    const row: AgentActivityJob = prior ?? { id, kind: "subagent", label: id, status, started_at: this.#spawnedAt(id) ?? now };
    if (p["status"] === "started") {
      // A restarted id is a new run: drop the previous run's progress/end.
      row.status = "running";
      row.started_at = prior?.status === "running" ? prior.started_at : this.#spawnedAt(id) ?? now;
      delete row.ended_at;
      if (prior?.status !== "running") {
        delete row.progress;
        delete row.detail;
      }
    } else {
      row.status = status;
      row.ended_at ??= now;
      // Keep the run's totals; the "current tool" is over.
      if (row.progress) {
        delete row.progress.tool;
        delete row.progress.tool_args;
        delete row.progress.tool_started_at;
      }
      delete row.detail;
    }
    this.#applySubagentMeta(row, p);
    this.#subagents.set(id, row);
  }

  /** `task:subagent:progress` payload (`{ …, progress: { id, … } }`). */
  onProgress(payload: unknown, now = Date.now()): void {
    const p = rec(payload);
    const progress = rec(p?.["progress"]);
    const id = str(progress?.["id"]);
    if (!p || !progress || !id) return;
    const prior = this.#subagents.get(id);
    // omp may flush one more progress tick after the lifecycle end.
    if (prior && prior.status !== "running") return;
    const duration = num(progress["durationMs"]);
    const row: AgentActivityJob = prior ?? {
      id,
      kind: "subagent",
      label: id,
      status: "running",
      started_at: this.#spawnedAt(id) ?? (duration !== undefined ? now - duration : now),
    };
    this.#applySubagentMeta(row, { ...p, description: progress["description"] ?? p["description"] });
    const nextProgress = progressFrom(progress);
    if (nextProgress) row.progress = nextProgress;
    else delete row.progress;
    const detail = detailFrom(progress);
    if (detail) row.detail = detail;
    else delete row.detail;
    this.#subagents.set(id, row);
  }

  /** Result of omp's `ctx.getAsyncJobSnapshot()` (`null` off omp). */
  applyJobSnapshot(snapshot: unknown, now = Date.now()): void {
    const snap = rec(snapshot);
    if (!snap) return;
    const running = Array.isArray(snap["running"]) ? snap["running"] : [];
    const recent = Array.isArray(snap["recent"]) ? snap["recent"] : [];
    const seen = new Set<string>();
    for (const raw of running) {
      const job = rec(raw);
      const id = str(job?.["id"]);
      if (!job || !id) continue;
      seen.add(id);
      this.#jobs.set(id, this.#jobRow(job, id, "running", now));
    }
    const recentById = new Map<string, Record<string, unknown>>();
    for (const raw of recent) {
      const job = rec(raw);
      const id = str(job?.["id"]);
      if (job && id) recentById.set(id, job);
    }
    for (const [id, row] of this.#jobs) {
      if (seen.has(id) || row.status !== "running") continue;
      const ended = recentById.get(id);
      if (!ended) {
        // Evicted from omp's recent list before we saw it settle.
        this.#jobs.delete(id);
        continue;
      }
      row.status = jobStatus(ended["status"]);
      row.ended_at = num(ended["endTime"]) ?? now;
    }
  }

  /** Drops finished rows older than the linger window. */
  prune(now = Date.now()): void {
    for (const rows of [this.#subagents, this.#jobs]) {
      for (const [id, row] of rows) {
        if (row.status !== "running" && now - (row.ended_at ?? now) >= ACTIVITY_FINISHED_LINGER_MS) {
          rows.delete(id);
        }
      }
    }
  }

  /** The main agent finished its run: omp clears settled rows here. */
  clearFinished(): void {
    for (const rows of [this.#subagents, this.#jobs]) {
      for (const [id, row] of rows) {
        if (row.status !== "running") rows.delete(id);
      }
    }
  }

  reset(): void {
    this.#subagents.clear();
    this.#jobs.clear();
  }

  /** True while any row (running or lingering) needs polling/pruning. */
  hasRows(): boolean {
    return this.#subagents.size > 0 || this.#jobs.size > 0;
  }

  snapshot(now = Date.now()): AgentActivityJob[] {
    this.prune(now);
    const rows: AgentActivityJob[] = [...this.#subagents.values()];
    for (const job of this.#jobs.values()) {
      // A detached `task` subagent is also an async job; the subagent row
      // (from the event bus) is the richer one.
      if (job.kind === "subagent" && this.#subagents.has(job.id)) continue;
      rows.push(job);
    }
    return rows
      .sort((a, b) => a.started_at - b.started_at || a.id.localeCompare(b.id))
      .map((row) => ({ ...row, ...(row.progress ? { progress: { ...row.progress } } : {}) }));
  }

  #applySubagentMeta(row: AgentActivityJob, p: Record<string, unknown>): void {
    const agent = str(p["agent"]);
    if (agent) row.agent = agent;
    const description = str(p["description"]);
    if (description) row.description = clip(description, LABEL_MAX);
    const assignment = str(p["assignment"]);
    if (assignment) row.assignment = clip(assignment.trim(), ASSIGNMENT_MAX);
    const parent = str(p["parentToolCallId"]);
    if (parent) row.parent_tool_call_id = parent;
    // The assignment's first line is usually a markdown heading ("# Target"),
    // useless as a title; the id ("AgentA") reads better until omp's
    // generated description arrives (~1 s after start).
    row.label = row.description ?? row.id;
  }

  /** A detached subagent's async-job start time (registered before the bus event). */
  #spawnedAt(id: string): number | undefined {
    for (const job of this.#jobs.values()) {
      if (job.kind === "subagent" && job.id === id) return job.started_at;
    }
    return undefined;
  }

  #jobRow(job: Record<string, unknown>, id: string, status: AgentActivityStatus, now: number): AgentActivityJob {
    const type = str(job["type"]);
    const command = str(job["command"]);
    const label = str(job["label"]) ?? command ?? id;
    const startedAt = num(job["startTime"]) ?? this.#jobs.get(id)?.started_at ?? now;
    if (type === "bash") {
      return { id, kind: "bash", label: clip(label, LABEL_MAX), command: command ?? label, status, started_at: startedAt };
    }
    if (type === "task") {
      return { id: str(job["agentId"]) ?? id, kind: "subagent", label: clip(label, LABEL_MAX), status, started_at: startedAt };
    }
    return { id, kind: "job", label: clip(label, LABEL_MAX), ...(type ? { job_type: type } : {}), status, started_at: startedAt };
  }
}

/**
 * Throttled, deduplicated `agent_activity` fan-out: the first change after a
 * quiet period goes out at once, later ones coalesce into one trailing send
 * per `ACTIVITY_MIN_INTERVAL_MS`. Identical snapshots are never re-sent.
 */
export class ActivityBroadcaster {
  #lastKey = "[]";
  #lastSentAt = Number.NEGATIVE_INFINITY;
  #timer: NodeJS.Timeout | null = null;

  constructor(
    private readonly build: () => AgentActivityJob[],
    private readonly send: (msg: ServerMessage) => void,
    private readonly canSend: () => boolean,
    private readonly now: () => number = Date.now,
  ) {}

  /** Full snapshot message, for a single owner (attach / session_sync). */
  message(): Extract<ServerMessage, { type: "agent_activity" }> {
    return { type: "agent_activity", jobs: this.build(), ts: this.now() };
  }

  schedule(): void {
    if (this.#timer) return;
    const wait = this.#lastSentAt + ACTIVITY_MIN_INTERVAL_MS - this.now();
    if (wait <= 0) {
      this.flush();
      return;
    }
    this.#timer = setTimeout(() => {
      this.#timer = null;
      this.flush();
    }, wait);
    this.#timer.unref?.();
  }

  /** Sends now if the snapshot changed since the last broadcast. */
  flush(): void {
    if (this.#timer) {
      clearTimeout(this.#timer);
      this.#timer = null;
    }
    if (!this.canSend()) return;
    const msg = this.message();
    const key = JSON.stringify(msg.jobs);
    if (key === this.#lastKey) return;
    this.#lastKey = key;
    this.#lastSentAt = msg.ts;
    this.send(msg);
  }

  /** Forget send history (session replaced); cancels a pending send. */
  reset(): void {
    clearTimeout(this.#timer ?? undefined);
    this.#timer = null;
    this.#lastKey = "[]";
    this.#lastSentAt = Number.NEGATIVE_INFINITY;
  }
}
