// omp's todo list (the TUI's `TODO` panel) from `todo_state` frames, plus the
// chat's compact todo-tool pill. Same rules as omp v18.9.2:
// - done = `completed` + `abandoned`; the header and each phase show done/total;
// - the active phase is the first with a `pending`/`in_progress` task, else
//   the last; it is drawn bold/accent, the others muted;
// - with more than one phase, titles get Roman numerals (`I. Setup`);
// - a phase whose tasks are all done is collapsed to its title;
// - `phases: []` hides the panel (no list, or the TUI dismissed a finished one).

export type TodoStatus = "pending" | "in_progress" | "completed" | "abandoned" | "blocked";

export interface TodoTask {
  content: string;
  status: TodoStatus;
  /** `blocked` only: the agent's reason. */
  blocker?: string;
}

export interface TodoPhase {
  name: string;
  tasks: TodoTask[];
}

const STATUSES: Record<TodoStatus, true> = {
  pending: true, in_progress: true, completed: true, abandoned: true, blocked: true,
};

/** `todo_state` frame → the full list (null when not one). Malformed tasks and empty phases are dropped. */
export function parseTodoState(frame: Record<string, unknown>): TodoPhase[] | null {
  if (frame.type !== "todo_state" || !Array.isArray(frame.phases)) return null;
  return frame.phases.flatMap((p: { name?: unknown; tasks?: unknown } | null) => {
    if (typeof p?.name !== "string" || !Array.isArray(p.tasks)) return [];
    const tasks = p.tasks.flatMap((t: { content?: unknown; status?: unknown; blocker?: unknown } | null): TodoTask[] => {
      if (typeof t?.content !== "string" || typeof t.status !== "string" || !Object.hasOwn(STATUSES, t.status)) return [];
      const status = t.status as TodoStatus;
      return [typeof t.blocker === "string" && t.blocker ? { content: t.content, status, blocker: t.blocker } : { content: t.content, status }];
    });
    return tasks.length > 0 ? [{ name: p.name, tasks }] : [];
  });
}

/** omp counts dropped (`abandoned`) tasks as done. */
export function isTaskDone(task: TodoTask): boolean {
  return task.status === "completed" || task.status === "abandoned";
}

export interface TodoCount {
  done: number;
  total: number;
}

export function todoCount(tasks: readonly TodoTask[]): TodoCount {
  return { done: tasks.filter(isTaskDone).length, total: tasks.length };
}

/** Index of the phase omp highlights: first with open work, else the last. */
export function activePhaseIndex(phases: readonly TodoPhase[]): number {
  const open = phases.findIndex((p) => p.tasks.some((t) => t.status === "pending" || t.status === "in_progress"));
  return open === -1 ? phases.length - 1 : open;
}

const ROMAN: Array<[number, string]> = [
  [1000, "M"], [900, "CM"], [500, "D"], [400, "CD"], [100, "C"], [90, "XC"],
  [50, "L"], [40, "XL"], [10, "X"], [9, "IX"], [5, "V"], [4, "IV"], [1, "I"],
];

/** `I. Setup` when the list has several phases (omp numbers them), else the bare name. */
export function phaseTitle(name: string, index: number, phaseCount: number): string {
  if (phaseCount <= 1) return name;
  let n = index + 1;
  let roman = "";
  for (const [value, digits] of ROMAN) {
    while (n >= value) {
      roman += digits;
      n -= value;
    }
  }
  return `${roman}. ${name}`;
}

/** The task omp treats as current: the `in_progress` one, else the first pending. */
export function currentTask(phases: readonly TodoPhase[]): TodoTask | null {
  const tasks = phases.flatMap((p) => p.tasks);
  return tasks.find((t) => t.status === "in_progress") ?? tasks.find((t) => t.status === "pending") ?? null;
}

// ── chat pill for `todo` tool calls ─────────────────────────────────────────

// omp's todo result text: `Overall: 3/7 done, 4 open.` / `Todo list cleared.`
const OVERALL = /^Overall: (\d+)\/(\d+) done\b/m;

export interface TodoPill {
  /** `Todo · 3/7` once the result is in; `Todo · <op>` while it runs. */
  label: string;
  /** What the call did: `done · Write parser`, `init · 2 phases`. */
  detail: string;
}

/** The one-line pill a `todo` tool row shows instead of a full card. */
export function todoPill(args: Record<string, unknown> | null | undefined, output: string | undefined, status: "pending" | "done" | "error"): TodoPill {
  const op = typeof args?.op === "string" ? args.op : "update";
  const target = [args?.task, args?.phase].find((v): v is string => typeof v === "string" && v.length > 0);
  const list = Array.isArray(args?.list) ? args.list.length : 0;
  const items = Array.isArray(args?.items) ? args.items.length : 0;
  const detail = target
    ? `${op} · ${target}`
    : list > 0
      ? `${op} · ${list} phase${list === 1 ? "" : "s"}`
      : items > 0
        ? `${op} · ${items} item${items === 1 ? "" : "s"}`
        : op;
  if (status === "pending") return { label: `Todo · ${op}`, detail: target ?? "" };
  if (status === "error") return { label: "Todo · failed", detail };
  const overall = output ? OVERALL.exec(output) : null;
  if (overall) return { label: `Todo · ${overall[1]}/${overall[2]}`, detail };
  return { label: output?.includes("cleared") ? "Todo · cleared" : "Todo", detail };
}

// ── panel open/closed (same persistence as the Agents panel) ────────────────

export const TODO_PANEL_KEY = "remotepi_todo_panel";

export function readTodoPanelOpen(): boolean {
  try {
    return localStorage.getItem(TODO_PANEL_KEY) !== "closed";
  } catch {
    return true;
  }
}

export function writeTodoPanelOpen(open: boolean): void {
  try {
    localStorage.setItem(TODO_PANEL_KEY, open ? "open" : "closed");
  } catch {}
}
