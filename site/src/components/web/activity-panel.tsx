"use client";

import { useEffect, useState } from "react";
import { BrailleSpinner } from "./braille-spinner";
import { agentRowView, agentsSummary, type AgentActivityJob, type AgentBoard } from "./activity";

const FINISHED_ICON: Record<Exclude<AgentActivityJob["status"], "running">, { icon: string; className: string; title: string }> = {
  done: { icon: "✓", className: "text-[#6CD28A]", title: "Done" },
  failed: { icon: "✗", className: "text-[#E5484D]", title: "Failed" },
  cancelled: { icon: "✗", className: "text-[#6B6B6B]", title: "Cancelled" },
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

function CloseButton({ onClose }: { onClose: () => void }) {
  return (
    <button
      type="button"
      onClick={onClose}
      title="Close agents panel"
      aria-label="Close agents panel"
      className="p-1 text-[#888] hover:text-white hover:bg-white/5 rounded-lg transition-colors cursor-pointer"
    >
      <svg className="w-4 h-4" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
        <line x1="18" y1="6" x2="6" y2="18" />
        <line x1="6" y1="6" x2="18" y2="18" />
      </svg>
    </button>
  );
}

/** One job as a compact card; click to expand the full text (and a subagent's assignment). */
function AgentCard({ job, now }: { job: AgentActivityJob; now: number }) {
  const [expanded, setExpanded] = useState(false);
  const row = agentRowView(job, now);
  const finished = job.status === "running" ? null : FINISHED_ICON[job.status];
  const running = job.status === "running";
  return (
    <div
      className={`rounded-lg border px-2.5 py-2 transition-colors ${
        running ? "border-[#4fc3f7]/25 bg-[#4fc3f7]/[0.04]" : "border-white/10 bg-[#0b0e14]"
      }`}
    >
      <button
        type="button"
        onClick={() => setExpanded((e) => !e)}
        aria-expanded={expanded}
        className="w-full text-left cursor-pointer group"
      >
        <div className="flex items-center gap-2 min-w-0">
          <span
            className={`w-4 shrink-0 text-center text-sm leading-none ${finished ? finished.className : "text-[#4fc3f7]"}`}
            title={finished ? finished.title : "Running"}
          >
            {finished ? finished.icon : <BrailleSpinner />}
          </span>
          <span className="text-[13px] font-medium text-white truncate group-hover:text-[#4fc3f7] transition-colors">
            {row.name}
          </span>
          <span className="shrink-0 px-1.5 py-px rounded-full border border-white/10 bg-white/5 text-[10px] text-[#999]">
            {row.badge}
          </span>
          <span className="ml-auto shrink-0 text-[11px] text-[#888] tabular-nums">{row.elapsed}</span>
        </div>
        {row.summary && (
          <div
            title={row.summary}
            className={`mt-0.5 pl-6 text-xs text-[#9A9A9A] ${
              expanded ? "whitespace-pre-wrap break-words" : "truncate"
            } ${job.kind === "bash" ? "font-mono" : ""}`}
          >
            {row.summary}
          </div>
        )}
        {row.activity && (
          <div title={row.activity} className={`mt-0.5 pl-6 text-[11px] text-[#4fc3f7]/80 ${expanded ? "break-words" : "truncate"}`}>
            {row.activity}
          </div>
        )}
      </button>
      {row.chips.length > 0 && (
        <div className="mt-1.5 pl-6 flex flex-wrap gap-1">
          {row.chips.map((c) => (
            <span
              key={c.label}
              className="px-1.5 py-px rounded-md border border-white/10 bg-white/[0.03] text-[10px] text-[#BBB] tabular-nums"
            >
              <span className="text-[#666]">{c.label}</span> {c.value}
            </span>
          ))}
        </div>
      )}
      {expanded && job.assignment && (
        <div className="mt-2 ml-6 rounded-md border border-white/5 bg-black/30 p-2.5">
          <div className="text-[10px] uppercase tracking-wider text-[#666] mb-1">Assignment</div>
          <div className="text-[12.5px] leading-relaxed text-[#C8C8C8] whitespace-pre-wrap break-words max-h-72 overflow-y-auto">
            {job.assignment}
          </div>
        </div>
      )}
    </div>
  );
}

function AgentCards({ board, now }: { board: AgentBoard; now: number }) {
  return (
    <div className="space-y-1.5">
      {board.running.map((job) => (
        <AgentCard key={job.id} job={job} now={now} />
      ))}
      {board.finished.length > 0 && (
        <>
          <div className="flex items-center gap-2 pt-2 pb-0.5 text-[10px] uppercase tracking-wider text-[#6B6B6B]">
            <span className="h-px flex-1 bg-[#1F1F1F]" />
            <span>Finished</span>
            <span className="h-px flex-1 bg-[#1F1F1F]" />
          </div>
          {board.finished.map((job) => (
            <AgentCard key={job.id} job={job} now={now} />
          ))}
        </>
      )}
    </div>
  );
}

function RunningPill({ count }: { count: number }) {
  return (
    <span className="flex items-center gap-1 px-1.5 py-0.5 rounded-full border border-[#38bdf8] bg-[#38bdf8]/15 text-[10px] text-[#38bdf8]">
      <span className="w-1.5 h-1.5 rounded-full bg-[#38bdf8] animate-pulse" />
      {count} running
    </span>
  );
}

/** Wide screens: the `Agents` column beside the chat, closable. */
export function AgentsSideColumn({ board, onClose }: { board: AgentBoard; onClose: () => void }) {
  const now = useNow(board);
  const empty = board.running.length === 0 && board.finished.length === 0;
  return (
    <aside className="hidden lg:flex flex-col w-[300px] shrink-0 border-r border-white/10 bg-[#0a0c10] font-[family-name:var(--ff-body)]">
      <div className="h-14 pl-4 pr-2 border-b border-white/10 flex items-center justify-between gap-2 shrink-0">
        <div className="flex items-center gap-2 min-w-0">
          <span className="text-sm font-semibold text-white">Agents</span>
          {board.running.length > 0 && <RunningPill count={board.running.length} />}
        </div>
        <CloseButton onClose={onClose} />
      </div>
      <div className="flex-1 overflow-y-auto p-3">
        {empty ? (
          <div className="text-xs text-[#666] text-center mt-6">No subagents or background jobs</div>
        ) : (
          <AgentCards board={board} now={now} />
        )}
      </div>
    </aside>
  );
}

/** Narrow screens: the bottom panel above the composer, collapsible to its header, closable. */
export function AgentsBottomPanel({ board, onClose }: { board: AgentBoard; onClose: () => void }) {
  const now = useNow(board);
  // Open while something runs unless the user chose otherwise.
  const [userExpanded, setUserExpanded] = useState<boolean | null>(null);
  if (board.running.length === 0 && board.finished.length === 0) return null;
  const expanded = userExpanded ?? board.running.length > 0;
  return (
    <div className="lg:hidden px-3 sm:px-4 py-1.5 border-t border-white/10 bg-[#0a0c10] font-[family-name:var(--ff-body)] shrink-0">
      <div className="flex items-center justify-between gap-2">
        <button
          type="button"
          onClick={() => setUserExpanded(!expanded)}
          aria-expanded={expanded}
          className="flex items-center gap-1.5 text-xs text-[#4fc3f7] cursor-pointer hover:text-white"
        >
          <span className="text-[10px] text-[#666]">{expanded ? "▾" : "▸"}</span>
          <span>{agentsSummary(board)}</span>
        </button>
        <CloseButton onClose={onClose} />
      </div>
      {expanded && (
        <div className="mt-1 mb-1 max-h-[45vh] overflow-y-auto">
          <AgentCards board={board} now={now} />
        </div>
      )}
    </div>
  );
}
