"use client";

import { useEffect, useState } from "react";
import { BrailleSpinner } from "./braille-spinner";
import { activityHeader, activityLines, type AgentActivityJob } from "./activity";

const STATUS_ICON: Record<Exclude<AgentActivityJob["status"], "running">, { icon: string; className: string }> = {
  done: { icon: "✓", className: "text-[#6CD28A]" },
  failed: { icon: "✗", className: "text-[#E5484D]" },
  cancelled: { icon: "✗", className: "text-[#E5484D]" },
};

/** omp's bottom activity panel: running subagents and background jobs. */
export function ActivityPanel({ jobs }: { jobs: readonly AgentActivityJob[] }) {
  const [collapsed, setCollapsed] = useState(false);
  const [now, setNow] = useState(() => Date.now());
  const anyRunning = jobs.some((j) => j.status === "running");

  // Re-read the clock as soon as a snapshot lands (the panel stays mounted
  // between turns, so `now` may be stale), then tick every second while
  // anything runs.
  useEffect(() => {
    const tick = () => setNow(Date.now());
    const first = setTimeout(tick, 0);
    const every = anyRunning ? setInterval(tick, 1000) : undefined;
    return () => {
      clearTimeout(first);
      clearInterval(every);
    };
  }, [jobs, anyRunning]);

  if (jobs.length === 0) return null;

  return (
    <div className="px-3 sm:px-4 py-1.5 border-t border-white/10 bg-[#0a0c10] font-mono text-xs shrink-0">
      <button
        type="button"
        onClick={() => setCollapsed((c) => !c)}
        aria-expanded={!collapsed}
        className="flex items-center gap-1.5 text-[#4fc3f7] cursor-pointer hover:text-white"
      >
        <span className="text-[10px] text-[#666]">{collapsed ? "▸" : "▾"}</span>
        <span>{activityHeader(jobs)}</span>
      </button>
      {!collapsed && (
        <div className="mt-1 space-y-0.5 max-h-40 overflow-y-auto">
          {jobs.map((job) => {
            const { main, sub } = activityLines(job, now);
            const done = job.status === "running" ? null : STATUS_ICON[job.status];
            return (
              <div key={job.id}>
                <div className="flex items-start gap-1.5 text-[#D0D0D0]">
                  <span className={`w-3 shrink-0 ${done ? done.className : "text-[#4fc3f7]"}`}>
                    {done ? done.icon : <BrailleSpinner />}
                  </span>
                  <span className="min-w-0 break-words whitespace-pre-wrap">{main}</span>
                </div>
                {sub && <div className="pl-[2.6rem] text-[#777] truncate">{sub}</div>}
              </div>
            );
          })}
        </div>
      )}
    </div>
  );
}
