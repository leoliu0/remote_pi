"use client";

import { useEffect, useState } from "react";
import { BrailleSpinner } from "./braille-spinner";
import {
  activityLines,
  agentsHeader,
  agentsSummary,
  progressCounters,
  type AgentActivityJob,
  type AgentBoard,
} from "./activity";

const STATUS_ICON: Record<Exclude<AgentActivityJob["status"], "running">, { icon: string; className: string }> = {
  done: { icon: "✓", className: "text-[#6CD28A]" },
  failed: { icon: "✗", className: "text-[#E5484D]" },
  cancelled: { icon: "✗", className: "text-[#E5484D]" },
};

/**
 * Wall clock for elapsed times: re-read as soon as the board changes (a view
 * stays mounted between turns, so `now` may be stale), then every second
 * while anything runs.
 */
function useNow(board: AgentBoard): number {
  const [now, setNow] = useState(() => Date.now());
  const anyRunning = board.running.length > 0;
  useEffect(() => {
    const tick = () => setNow(Date.now());
    const first = setTimeout(tick, 0);
    const every = anyRunning ? setInterval(tick, 1000) : undefined;
    return () => {
      clearTimeout(first);
      clearInterval(every);
    };
  }, [board, anyRunning]);
  return now;
}

/** One row; subagents expand on click to their assignment and counters. */
function AgentRow({ job, now }: { job: AgentActivityJob; now: number }) {
  const [expanded, setExpanded] = useState(false);
  const { main, sub } = activityLines(job, now);
  const done = job.status === "running" ? null : STATUS_ICON[job.status];
  const expandable = job.kind === "subagent";
  const counters = expanded ? progressCounters(job) : null;
  return (
    <div>
      <button
        type="button"
        disabled={!expandable}
        onClick={() => setExpanded((e) => !e)}
        aria-expanded={expandable ? expanded : undefined}
        className={`w-full text-left flex items-start gap-1.5 text-[#D0D0D0] ${
          expandable ? "cursor-pointer hover:text-white" : "cursor-default"
        }`}
      >
        <span className={`w-3 shrink-0 ${done ? done.className : "text-[#4fc3f7]"}`}>
          {done ? done.icon : <BrailleSpinner />}
        </span>
        <span className="min-w-0 break-words whitespace-pre-wrap">{main}</span>
      </button>
      {sub && <div className="pl-[2.6rem] text-[#777] break-words">{sub}</div>}
      {expanded && (
        <div className="pl-[2.6rem] mt-1 mb-1.5 space-y-1">
          {job.assignment && (
            <pre className="whitespace-pre-wrap break-words text-[#8A8A8A] max-h-60 overflow-y-auto font-mono">
              {job.assignment}
            </pre>
          )}
          {counters && <div className="text-[#777]">{counters}</div>}
        </div>
      )}
    </div>
  );
}

function AgentRows({ board, now }: { board: AgentBoard; now: number }) {
  return (
    <div className="space-y-0.5">
      {board.running.map((job) => (
        <AgentRow key={job.id} job={job} now={now} />
      ))}
      {board.finished.length > 0 && (
        <>
          <div className="flex items-center gap-2 pt-2 pb-1 text-[10px] text-[#6B6B6B]">
            <span className="h-px flex-1 bg-[#1F1F1F]" />
            <span>Finished</span>
            <span className="h-px flex-1 bg-[#1F1F1F]" />
          </div>
          {board.finished.map((job) => (
            <AgentRow key={job.id} job={job} now={now} />
          ))}
        </>
      )}
    </div>
  );
}

/** Wide screens: the persistent `Agents` column beside the chat. */
export function AgentsSideColumn({ board }: { board: AgentBoard }) {
  const now = useNow(board);
  const empty = board.running.length === 0 && board.finished.length === 0;
  return (
    <aside className="hidden lg:flex flex-col w-[300px] shrink-0 border-r border-white/10 bg-[#0a0c10] font-mono text-xs">
      <div className="h-14 px-4 border-b border-white/10 flex items-center shrink-0 text-[#4fc3f7] font-semibold">
        {agentsHeader(board)}
      </div>
      <div className="flex-1 overflow-y-auto p-3">
        {empty ? (
          <div className="text-[#666] text-center mt-6">No subagents or background jobs</div>
        ) : (
          <AgentRows board={board} now={now} />
        )}
      </div>
    </aside>
  );
}

/** Narrow screens: the bottom panel above the composer, collapsible to its header. */
export function AgentsBottomPanel({ board }: { board: AgentBoard }) {
  const now = useNow(board);
  // Open while something runs unless the user chose otherwise.
  const [userExpanded, setUserExpanded] = useState<boolean | null>(null);
  if (board.running.length === 0 && board.finished.length === 0) return null;
  const expanded = userExpanded ?? board.running.length > 0;
  return (
    <div className="lg:hidden px-3 sm:px-4 py-1.5 border-t border-white/10 bg-[#0a0c10] font-mono text-xs shrink-0">
      <button
        type="button"
        onClick={() => setUserExpanded(!expanded)}
        aria-expanded={expanded}
        className="flex items-center gap-1.5 text-[#4fc3f7] cursor-pointer hover:text-white"
      >
        <span className="text-[10px] text-[#666]">{expanded ? "▾" : "▸"}</span>
        <span>{agentsSummary(board)}</span>
      </button>
      {expanded && (
        <div className="mt-1 max-h-48 overflow-y-auto">
          <AgentRows board={board} now={now} />
        </div>
      )}
    </div>
  );
}
