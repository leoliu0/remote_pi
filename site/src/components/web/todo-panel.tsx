"use client";

import { useState } from "react";
import { BrailleSpinner } from "./braille-spinner";
import {
  activePhaseIndex,
  currentTask,
  isTaskDone,
  phaseTitle,
  todoCount,
  type TodoPhase,
  type TodoStatus,
  type TodoTask,
} from "./todo";

const STATUS_VIEW: Record<Exclude<TodoStatus, "in_progress">, { icon: string; iconClass: string; textClass: string; title: string }> = {
  pending: { icon: "○", iconClass: "text-[#5A5A5A]", textClass: "text-[#9A9A9A]", title: "Pending" },
  completed: { icon: "✓", iconClass: "text-[#6CD28A]", textClass: "text-[#6B6B6B] line-through decoration-[#4A4A4A]", title: "Done" },
  abandoned: { icon: "✗", iconClass: "text-[#E5484D]/70", textClass: "text-[#6B6B6B] line-through decoration-[#4A4A4A]", title: "Dropped" },
  blocked: { icon: "!", iconClass: "text-amber-400 font-bold", textClass: "text-amber-200/90", title: "Blocked" },
};

/** One task: status icon + text; the in-progress task is highlighted with a spinner while the agent works. */
function TaskRow({ task, working }: { task: TodoTask; working: boolean }) {
  if (task.status === "in_progress") {
    return (
      <li className="flex items-start gap-2 rounded-md bg-[#4fc3f7]/[0.08] border border-[#4fc3f7]/25 px-1.5 py-1" title="In progress">
        <span className="w-4 shrink-0 text-center text-[#4fc3f7] leading-5">{working ? <BrailleSpinner /> : "●"}</span>
        <span className="text-[13px] leading-5 text-white break-words min-w-0">{task.content}</span>
      </li>
    );
  }
  const view = STATUS_VIEW[task.status];
  return (
    <li className="flex items-start gap-2 px-1.5 py-0.5" title={view.title}>
      <span className={`w-4 shrink-0 text-center leading-5 ${view.iconClass}`}>{view.icon}</span>
      <span className="min-w-0">
        <span className={`text-[13px] leading-5 break-words ${view.textClass}`}>
          {task.content}
          {task.status === "blocked" && <span className="text-amber-400/80"> (blocked)</span>}
        </span>
        {task.blocker && <span className="block text-[11px] leading-4 text-[#8A8A8A] break-words">{task.blocker}</span>}
      </span>
    </li>
  );
}

/** Phases as omp draws them: numbered titles with done/total, the active one accented, finished ones folded. */
function PhaseList({ phases, working }: { phases: TodoPhase[]; working: boolean }) {
  const active = activePhaseIndex(phases);
  // Finished phases other than the active one start folded (omp's checklist
  // `collapsed`; the TUI always lists the active phase's tasks); the reader can unfold one.
  const [unfolded, setUnfolded] = useState<ReadonlySet<string>>(() => new Set());
  return (
    <div className="space-y-2">
      {phases.map((phase, i) => {
        const count = todoCount(phase.tasks);
        const isActive = i === active;
        const foldable = !isActive && phase.tasks.every(isTaskDone);
        const open = !foldable || unfolded.has(phase.name);
        return (
          <div key={`${i}:${phase.name}`}>
            <button
              type="button"
              onClick={() =>
                foldable &&
                setUnfolded((prev) => {
                  const next = new Set(prev);
                  if (next.has(phase.name)) next.delete(phase.name);
                  else next.add(phase.name);
                  return next;
                })
              }
              aria-expanded={open}
              disabled={!foldable}
              className={`w-full flex items-center gap-1.5 text-left text-xs ${foldable ? "cursor-pointer hover:text-white" : "cursor-default"}`}
            >
              <span className={`truncate ${isActive ? "font-semibold text-[#4fc3f7]" : "text-[#8A8A8A]"}`}>
                {phaseTitle(phase.name, i, phases.length)}
              </span>
              <span className="shrink-0 text-[11px] text-[#5A5A5A] tabular-nums">· {count.done}/{count.total}</span>
              {foldable && <span className="ml-auto shrink-0 text-[10px] text-[#666]">{open ? "▾" : "▸"}</span>}
            </button>
            {open && (
              <ul className="mt-1 space-y-0.5">
                {phase.tasks.map((task, j) => (
                  <TaskRow key={`${j}:${task.content}`} task={task} working={working} />
                ))}
              </ul>
            )}
          </div>
        );
      })}
    </div>
  );
}

function ProgressBar({ done, total }: { done: number; total: number }) {
  return (
    <span className="h-1 w-14 shrink-0 rounded-full bg-white/10 overflow-hidden" aria-hidden>
      <span className="block h-full bg-[#4fc3f7]" style={{ width: `${total > 0 ? (done / total) * 100 : 0}%` }} />
    </span>
  );
}

interface TodoPanelProps {
  phases: TodoPhase[];
  /** The agent is running: the in-progress task spins. */
  working: boolean;
  open: boolean;
  onToggle: () => void;
}

/** Header shared by both layouts: `Todo 3/7 ▬▬▭` and, folded, the current task. */
function TodoHeader({ phases, open, onToggle }: Omit<TodoPanelProps, "working">) {
  const count = todoCount(phases.flatMap((p) => p.tasks));
  const current = currentTask(phases);
  return (
    <button
      type="button"
      onClick={onToggle}
      aria-expanded={open}
      aria-label={open ? "Collapse todo list" : "Expand todo list"}
      className="w-full flex items-center gap-2 min-w-0 text-left cursor-pointer group"
    >
      <span className="text-[10px] text-[#666] w-2.5 shrink-0">{open ? "▾" : "▸"}</span>
      <span className="text-sm font-semibold text-white group-hover:text-[#4fc3f7] transition-colors">Todo</span>
      <span className="text-xs text-[#8A8A8A] tabular-nums">
        {count.done}/{count.total}
      </span>
      <ProgressBar done={count.done} total={count.total} />
      {!open && (
        <span className="min-w-0 truncate text-xs text-[#9A9A9A]">
          {current ? current.content : <span className="text-[#6CD28A]">✓ done</span>}
        </span>
      )}
    </button>
  );
}

/** Wide screens: the `Todo` section at the top of the Agents column. */
export function TodoSideSection({ phases, working, open, onToggle }: TodoPanelProps) {
  if (phases.length === 0) return null;
  return (
    <section aria-label="Todo list" className="mb-3 pb-3 border-b border-white/10">
      <TodoHeader phases={phases} open={open} onToggle={onToggle} />
      {open && (
        <div className="mt-2">
          <PhaseList phases={phases} working={working} />
        </div>
      )}
    </section>
  );
}

/** Narrow screens: the todo list above the composer (and the Agents panel), collapsible to one line. */
export function TodoBottomPanel({ phases, working, open, onToggle }: TodoPanelProps) {
  if (phases.length === 0) return null;
  return (
    <section
      aria-label="Todo list"
      className="lg:hidden px-3 sm:px-4 py-1.5 border-t border-white/10 bg-[#0a0c10] font-[family-name:var(--ff-body)] shrink-0"
    >
      <TodoHeader phases={phases} open={open} onToggle={onToggle} />
      {open && (
        <div className="mt-1.5 mb-1 max-h-[40vh] overflow-y-auto">
          <PhaseList phases={phases} working={working} />
        </div>
      )}
    </section>
  );
}
