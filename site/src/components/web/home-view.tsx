"use client";

import { useState } from "react";
import { PairedSession } from "./web-client";

interface HomeViewProps {
  sessions: PairedSession[];
  onOpenSession: (session: PairedSession) => void;
  onOpenPairModal: () => void;
  onDeleteSession: (id: string) => void;
}

export function HomeView({
  sessions,
  onOpenSession,
  onOpenPairModal,
  onDeleteSession,
}: HomeViewProps) {
  const [filter, setFilter] = useState<"all" | "active" | "idle">("all");

  const liveSessionsCount = sessions.filter((s) => s.isLive || s.status === "online" || s.status === "working").length;

  const filteredSessions = sessions.filter((s) => {
    const isLive = s.isLive || s.status === "online" || s.status === "working";
    if (filter === "all") return true;
    if (filter === "active") return isLive;
    if (filter === "idle") return !isLive;
    return true;
  });

  return (
    <div className="flex-1 max-w-4xl mx-auto w-full px-4 sm:px-6 py-6 sm:py-8 flex flex-col">
      {/* 1. Large Title Header (Mobile Parity) */}
      <div className="flex flex-col sm:flex-row sm:items-end justify-between gap-4 mb-6 pb-6 border-b border-white/10">
        <div>
          <div className="flex items-center gap-2 text-xs font-mono text-[#4fc3f7] uppercase tracking-wider mb-1.5">
            <span className={`w-2 h-2 rounded-full ${liveSessionsCount > 0 ? "bg-[#5fd38a] animate-pulse" : "bg-[#666]"}`} />
            <span>
              Remote Pi &bull; {liveSessionsCount} Active &bull; {sessions.length} Total
            </span>
          </div>
          <h1 className="text-3xl sm:text-4xl font-bold tracking-tight text-white font-[family-name:var(--ff-display)]">
            Sessions
          </h1>
        </div>
        <div className="flex items-center gap-2.5">
          <button
            type="button"
            onClick={onOpenPairModal}
            className="px-4 py-2 bg-[#4fc3f7] hover:bg-[#38bdf8] active:scale-95 text-[#04222e] font-semibold text-xs rounded-xl transition-all cursor-pointer flex items-center gap-1.5 shadow-md shadow-[#4fc3f7]/20"
          >
            <svg className="w-4 h-4" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.5">
              <line x1="12" y1="5" x2="12" y2="19" />
              <line x1="5" y1="12" x2="19" y2="12" />
            </svg>
            <span>Pair Device</span>
          </button>
        </div>
      </div>

      {/* 2. Filter Tabs */}
      <div className="flex items-center justify-between gap-4 mb-5">
        <div className="flex p-1 rounded-xl bg-white/[0.03] border border-white/10 w-fit">
          <button
            type="button"
            onClick={() => setFilter("all")}
            className={`px-3.5 py-1.5 text-xs font-mono rounded-lg transition-all cursor-pointer ${
              filter === "all"
                ? "bg-[#4fc3f7]/20 text-[#4fc3f7] font-semibold border border-[#4fc3f7]/30"
                : "text-[#888] hover:text-white"
            }`}
          >
            All ({sessions.length})
          </button>
          <button
            type="button"
            onClick={() => setFilter("active")}
            className={`px-3.5 py-1.5 text-xs font-mono rounded-lg transition-all cursor-pointer flex items-center gap-1.5 ${
              filter === "active"
                ? "bg-[#4fc3f7]/20 text-[#4fc3f7] font-semibold border border-[#4fc3f7]/30"
                : "text-[#888] hover:text-white"
            }`}
          >
            <span className="w-1.5 h-1.5 rounded-full bg-[#5fd38a]" />
            Active ({liveSessionsCount})
          </button>
          <button
            type="button"
            onClick={() => setFilter("idle")}
            className={`px-3.5 py-1.5 text-xs font-mono rounded-lg transition-all cursor-pointer ${
              filter === "idle"
                ? "bg-[#4fc3f7]/20 text-[#4fc3f7] font-semibold border border-[#4fc3f7]/30"
                : "text-[#888] hover:text-white"
            }`}
          >
            Idle ({sessions.length - liveSessionsCount})
          </button>
        </div>

        <div className="text-xs font-mono text-[#666]">
          {filteredSessions.length} {filteredSessions.length === 1 ? "session" : "sessions"} shown
        </div>
      </div>

      {/* 3. Session Tiles List */}
      <div className="space-y-3 flex-1">
        {filteredSessions.length === 0 ? (
          <div className="p-12 text-center rounded-2xl bg-[#0a0c10]/80 border border-white/10 flex flex-col items-center justify-center">
            <div className="w-12 h-12 rounded-2xl bg-white/5 border border-white/10 flex items-center justify-center text-[#4fc3f7] mb-3">
              <svg className="w-6 h-6" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
                <rect x="2" y="3" width="20" height="14" rx="2" ry="2" />
                <line x1="8" y1="21" x2="16" y2="21" />
                <line x1="12" y1="17" x2="12" y2="21" />
              </svg>
            </div>
            <div className="text-base font-semibold text-white">
              {filter === "active" ? "No active live sessions" : "No sessions found"}
            </div>
            <div className="text-xs text-[#777] font-mono mt-1 max-w-sm">
              {filter === "active"
                ? "Run Pi in your project terminal to start an active session."
                : "Pair a new device or select All to browse historical projects."}
            </div>
          </div>
        ) : (
          filteredSessions.map((session) => {
            const initial = (session.name || session.device || "R").charAt(0).toUpperCase();
            const isLive = session.isLive || session.status === "online" || session.status === "working";
            const isWorking = session.status === "working";

            return (
              <div
                key={session.id}
                className={`group relative flex items-center justify-between p-4 sm:p-5 rounded-2xl border transition-all shadow-md cursor-pointer ${
                  isLive
                    ? "bg-[#0a0c10]/90 hover:bg-[#0f131a] border-white/10 hover:border-[#4fc3f7]/40"
                    : "bg-[#06070a]/60 hover:bg-[#0a0c10] border-white/5 hover:border-white/15 opacity-80 hover:opacity-100"
                }`}
                onClick={() => onOpenSession(session)}
              >
                {/* Left: Avatar + Details */}
                <div className="flex items-center gap-4 min-w-0 flex-1">
                  <div
                    className={`w-11 h-11 rounded-xl border flex items-center justify-center font-mono font-bold text-base shrink-0 group-hover:scale-105 transition-transform ${
                      isLive
                        ? "bg-[#4fc3f7]/15 border-[#4fc3f7]/30 text-[#4fc3f7]"
                        : "bg-white/5 border-white/10 text-[#777]"
                    }`}
                  >
                    {initial}
                  </div>

                  <div className="min-w-0 flex-1">
                    <div className="flex items-center gap-2 mb-1">
                      <span
                        className={`text-sm sm:text-base font-semibold truncate group-hover:text-[#4fc3f7] transition-colors ${
                          isLive ? "text-white" : "text-[#b0b0b0]"
                        }`}
                      >
                        {session.name || "Remote Pi"}
                      </span>
                      <span className="text-[10px] px-2 py-0.5 rounded-md bg-white/10 text-[#888] font-mono shrink-0">
                        {session.roomId || "main"}
                      </span>
                    </div>

                    <div className="flex items-center gap-2 text-xs text-[#888] font-mono">
                      <span className="truncate max-w-[160px] sm:max-w-[280px]">
                        {session.device || "Remote Host"}
                      </span>
                      <span className="text-[#444]">&bull;</span>
                      {session.model ? (
                        <span className="text-[#4fc3f7] truncate max-w-[140px] sm:max-w-[220px]">
                          {session.model}
                        </span>
                      ) : (
                        <span className="text-[#666] truncate max-w-[140px] sm:max-w-[220px]">
                          {session.cwd || "offline"}
                        </span>
                      )}
                    </div>
                  </div>
                </div>

                {/* Right: Presence Indicator & Actions */}
                <div className="flex items-center gap-4 shrink-0 pl-3">
                  <div className="flex items-center gap-2">
                    <span
                      className={`w-2.5 h-2.5 rounded-full ${
                        isWorking
                          ? "bg-[#4fc3f7] animate-pulse"
                          : isLive
                          ? "bg-[#5fd38a]"
                          : "bg-[#555]"
                      }`}
                    />
                    <span
                      className={`text-xs font-mono hidden sm:inline ${
                        isWorking
                          ? "text-[#4fc3f7]"
                          : isLive
                          ? "text-[#5fd38a]"
                          : "text-[#666]"
                      }`}
                    >
                      {isWorking ? "working…" : isLive ? "online" : "offline"}
                    </span>
                  </div>

                  <button
                    type="button"
                    onClick={(e) => {
                      e.stopPropagation();
                      onDeleteSession(session.id);
                    }}
                    className="p-2 text-[#666] hover:text-red-400 hover:bg-red-500/10 rounded-xl transition-colors opacity-0 group-hover:opacity-100 cursor-pointer"
                    title="Remove session"
                  >
                    <svg className="w-4 h-4" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
                      <polyline points="3 6 5 6 21 6" />
                      <path d="M19 6v14a2 2 0 0 1-2 2H7a2 2 0 0 1-2-2V6m3 0V4a2 2 0 0 1 2-2h4a2 2 0 0 1 2 2v2" />
                    </svg>
                  </button>

                  <div className="text-[#555] group-hover:text-[#4fc3f7] group-hover:translate-x-0.5 transition-all">
                    <svg className="w-5 h-5" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
                      <polyline points="9 18 15 12 9 6" />
                    </svg>
                  </div>
                </div>
              </div>
            );
          })
        )}
      </div>
    </div>
  );
}
