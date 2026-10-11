/**
 * omp's todo list (the `todo` tool's phases/tasks, shown by the TUI as its
 * `TODO` panel above the editor) mirrored to paired clients as `todo_state`
 * snapshots. Same rules omp v18.9.2 uses (`packages/coding-agent/src/tools/todo.ts`
 * and the interactive mode's todo HUD):
 *
 * - Live: a non-error `todo` tool result whose `details.op` is not `"view"`
 *   carries the whole list after the op (`details.phases`); the TUI calls
 *   `setTodos(details.phases)` on exactly those.
 * - Rebuilt: `getLatestTodoPhasesFromEntries(branch)` walks the branch from the
 *   leaf and takes the first `custom` entry of type `user_todo_edit`
 *   (`data.phases`: `/todo` edits, todos changed from `eval`, subagent
 *   auto-completion) or `toolResult` message from `todo` (not an error, not
 *   `view`) — omp's `syncTodoPhasesFromBranch` on resume/switch/branch.
 * - Hidden: phases with no tasks are never drawn; once every task is done
 *   (`completed`/`abandoned`) the TUI auto-dismisses the panel after
 *   `tasks.todoClearDelay` and records a `todo_hud_state` entry
 *   (`visibility: "dismissed"`, keyed by the source entry id + list
 *   fingerprint); a later `"revealed"` entry or any list change shows it again.
 *   Hidden is sent as `phases: []`.
 */
import type { ServerMessage, TodoPhaseWire, TodoStateMessage, TodoStatus, TodoTaskWire } from "./protocol/types.js";

/** omp `qp`: a todo list written outside a `todo` tool result. */
const USER_TODO_EDIT = "user_todo_edit";
/** omp `OF`: the TUI panel's dismissed/revealed marker. */
const TODO_HUD_STATE = "todo_hud_state";
/**
 * The persisted tool result precedes `tool_execution_end` in omp 18.9.2. If it
 * ever lags, a branch read within this window that lacks the result must not
 * roll the list back.
 */
const PENDING_RESULT_MS = 5_000;

const STATUSES: Record<TodoStatus, true> = {
  pending: true, in_progress: true, completed: true, abandoned: true, blocked: true,
};

/** `details` of a `todo` tool result (omp `TodoToolDetails`). */
interface TodoDetails {
  op?: unknown;
  phases?: unknown;
}

/** The fields of an omp session entry read here; each is checked before use. */
interface BranchEntry {
  id?: unknown;
  type?: unknown;
  customType?: unknown;
  data?: { phases?: unknown; sourceEntryId?: unknown; fingerprint?: unknown; visibility?: unknown } | null;
  message?: {
    role?: unknown;
    toolName?: unknown;
    toolCallId?: unknown;
    isError?: unknown;
    details?: TodoDetails | null;
  } | null;
}

/** omp `isTodoPhase` over a whole list. */
function isPhaseList(value: unknown): value is TodoPhaseWire[] {
  return Array.isArray(value) && value.every((p: { name?: unknown; tasks?: unknown } | null) =>
    typeof p?.name === "string" && Array.isArray(p.tasks) &&
    p.tasks.every((t: { content?: unknown; status?: unknown } | null) =>
      typeof t?.content === "string" && typeof t.status === "string" && Object.hasOwn(STATUSES, t.status)));
}

/** omp `clonePhases`: only content/status/blocker survive. */
function clonePhases(phases: readonly TodoPhaseWire[]): TodoPhaseWire[] {
  return phases.map((p) => ({
    name: p.name,
    tasks: p.tasks.map((t): TodoTaskWire =>
      typeof t.blocker === "string"
        ? { content: t.content, status: t.status, blocker: t.blocker }
        : { content: t.content, status: t.status }),
  }));
}

/**
 * The todo list a `todo` tool result carries, or null when it changes nothing:
 * an error (details hold the unchanged list), a `view`, or a malformed payload.
 */
export function todoPhasesFromToolResult(result: unknown, isError: boolean): TodoPhaseWire[] | null {
  if (isError || typeof result !== "object" || result === null || !("details" in result)) return null;
  const details = result.details as TodoDetails | null | undefined;  // fields checked below
  if (!details || details.op === "view" || !isPhaseList(details.phases)) return null;
  return clonePhases(details.phases);
}

/** omp's per-entry source read: the list one branch entry sets, if any. */
function phasesOfEntry(e: BranchEntry): TodoPhaseWire[] | null {
  if (e.type === "custom" && e.customType === USER_TODO_EDIT) {
    return isPhaseList(e.data?.phases) ? e.data.phases : null;
  }
  const m = e.type === "message" ? e.message : null;
  if (!m || m.role !== "toolResult" || m.toolName !== "todo" || m.isError === true) return null;
  if (!m.details || m.details.op === "view") return null;
  return isPhaseList(m.details.phases) ? m.details.phases : null;
}

export interface TodoSource {
  phases: TodoPhaseWire[];
  entryId: string | null;
}

/** omp `getLatestTodoPhasesFromEntries`: the newest list on the branch (none → []). */
export function latestTodoPhases(branch: readonly unknown[]): TodoSource {
  const entries = branch as readonly BranchEntry[];  // omp SessionEntry[]; fields checked in phasesOfEntry
  for (let i = entries.length - 1; i >= 0; i--) {
    const e = entries[i];
    const phases = e ? phasesOfEntry(e) : null;
    if (phases) return { phases: clonePhases(phases), entryId: typeof e?.id === "string" ? e.id : null };
  }
  return { phases: [], entryId: null };
}

/** omp `todoHudVisibility`: the TUI's latest dismiss/reveal of THIS list, if any. */
export function todoHudVisibility(branch: readonly unknown[], source: TodoSource): "dismissed" | "revealed" | null {
  if (!source.entryId || source.phases.length === 0) return null;
  const fingerprint = JSON.stringify(clonePhases(source.phases));
  const entries = branch as readonly BranchEntry[];
  for (let i = entries.length - 1; i >= 0; i--) {
    const e = entries[i];
    if (e?.type !== "custom" || e.customType !== TODO_HUD_STATE || !e.data) continue;
    const { sourceEntryId, fingerprint: print, visibility } = e.data;
    if (sourceEntryId === source.entryId && print === fingerprint && (visibility === "dismissed" || visibility === "revealed")) {
      return visibility;
    }
  }
  return null;
}

/** The main session's current todo list, as the TUI panel would draw it. */
export class TodoTracker {
  #phases: TodoPhaseWire[] = [];
  #dismissed = false;
  #pending: { toolCallId: string; at: number } | null = null;

  constructor(private readonly now: () => number = Date.now) {}

  /** A main-session `todo` tool finished (`tool_execution_end`). */
  applyToolResult(toolCallId: string, result: unknown, isError: boolean): void {
    const phases = todoPhasesFromToolResult(result, isError);
    if (!phases) return;
    this.#phases = phases;
    this.#dismissed = false;
    this.#pending = { toolCallId, at: this.now() };
  }

  /** Re-read the list from the session branch (attach, sync, resume, edits). */
  syncFromBranch(branch: readonly unknown[]): void {
    const pending = this.#pending;
    if (pending) {
      const persisted = (branch as readonly BranchEntry[]).some((e) =>
        e?.message?.role === "toolResult" && e.message.toolCallId === pending.toolCallId);
      if (!persisted && this.now() - pending.at < PENDING_RESULT_MS) return;  // keep the live result
      this.#pending = null;
    }
    const source = latestTodoPhases(branch);
    this.#phases = source.phases;
    this.#dismissed = todoHudVisibility(branch, source) === "dismissed";
  }

  /** Visible phases: empty phases dropped; [] while dismissed or empty. */
  snapshot(): TodoPhaseWire[] {
    if (this.#dismissed) return [];
    return clonePhases(this.#phases.filter((p) => p.tasks.length > 0));
  }

  reset(): void {
    this.#phases = [];
    this.#dismissed = false;
    this.#pending = null;
  }
}

/** Deduplicated `todo_state` fan-out: an unchanged list is never re-sent. */
export class TodoBroadcaster {
  #lastKey = "[]";

  constructor(
    private readonly build: () => TodoPhaseWire[],
    private readonly send: (msg: ServerMessage) => void,
    private readonly canSend: () => boolean,
    private readonly now: () => number = Date.now,
  ) {}

  /** Full snapshot message, for a single owner (attach / session_sync). */
  message(): TodoStateMessage {
    return { type: "todo_state", phases: this.build(), ts: this.now() };
  }

  /** Broadcasts to active owners if the list changed since the last broadcast. */
  flush(): void {
    if (!this.canSend()) return;
    const msg = this.message();
    const key = JSON.stringify(msg.phases);
    if (key === this.#lastKey) return;
    this.#lastKey = key;
    this.send(msg);
  }

  /** Forget send history (session replaced). */
  reset(): void {
    this.#lastKey = "[]";
  }
}
