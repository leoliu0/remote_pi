"use client";

import { useState } from "react";
import { PairedSession } from "./web-client";

interface HomeViewProps {
  sessions: PairedSession[];
  isRelayConnected?: boolean;
  deviceName?: string;
  onOpenSession: (session: PairedSession) => void;
  onOpenPairModal: () => void;
  onOpenSettings?: () => void;
  onDeleteSession: (id: string) => void;
}

export function HomeView({
  sessions,
  isRelayConnected = true,
  deviceName = "Remote Pi",
  onOpenSession,
  onOpenPairModal,
  onOpenSettings,
  onDeleteSession,
}: HomeViewProps) {
  // Default tab is "online" (matches mobile app HomeFilter.online)
  const [filter, setFilter] = useState<"all" | "online" | "offline">("online");

  // Deterministic session sorting (working -> online -> offline -> alphabetical)
  const sortSessions = (list: PairedSession[]) =>
    [...list].sort((a, b) => {
      const rank = (s: PairedSession) =>
        s.status === "working" ? 0 : s.isLive || s.status === "online" ? 1 : 2;
      const rankDiff = rank(a) - rank(b);
      if (rankDiff !== 0) return rankDiff;
      const nameA = (a.name || a.roomId || "").toLowerCase();
      const nameB = (b.name || b.roomId || "").toLowerCase();
      if (nameA !== nameB) return nameA.localeCompare(nameB);
      return (a.roomId || "").localeCompare(b.roomId || "");
    });

  const sortedAll = sortSessions(sessions);
  const onlineSessions = sortedAll.filter((s) => s.isLive || s.status === "online" || s.status === "working");
  const offlineSessions = sortedAll.filter((s) => !s.isLive && s.status !== "online" && s.status !== "working");

  const counts = {
    all: sortedAll.length,
    online: onlineSessions.length,
    offline: offlineSessions.length,
  };

  const visibleSessions = filter === "all"
    ? sortedAll
    : filter === "online"
    ? onlineSessions
    : offlineSessions;

  // Group visible sessions by Peer / Device
  const groupedByDevice: Record<string, PairedSession[]> = {};
  for (const s of visibleSessions) {
    const dev = (s.device || deviceName || "Remote Pi").toUpperCase();
    if (!groupedByDevice[dev]) groupedByDevice[dev] = [];
    groupedByDevice[dev].push(s);
  }

  const deviceKeys = Object.keys(groupedByDevice).sort();

  return (
    <div className="max-w-2xl mx-auto w-full px-3 sm:px-4 py-3 sm:py-4 flex flex-col space-y-3">
      {/* 1. Ultra-Compact Inline Header */}
      <div className="flex items-center justify-between pb-2.5 border-b border-white/10">
        <div className="flex items-center gap-2.5">
          <div className="flex items-center gap-1.5 font-mono text-xs font-semibold text-white tracking-tight">
            <span className="text-[#4fc3f7] font-bold text-sm">π</span>
            <span>Remote Pi</span>
          </div>

          <span className="text-[#333]">&bull;</span>

          <div className="flex items-center gap-1.5 text-[11px] font-mono">
            <span className={`w-1.5 h-1.5 rounded-full ${isRelayConnected ? "bg-[#5fd38a]" : "bg-amber-400"}`} />
            <span className={isRelayConnected ? "text-[#888]" : "text-amber-400"}>
              {isRelayConnected ? "Relay Connected" : "Relay Offline"}
            </span>
          </div>
        </div>

        <div className="flex items-center gap-2">
          <button
            type="button"
            onClick={onOpenPairModal}
            className="px-2.5 py-1 bg-[#4fc3f7]/15 hover:bg-[#4fc3f7]/25 text-[#4fc3f7] border border-[#4fc3f7]/30 hover:border-[#4fc3f7]/60 active:scale-95 font-mono text-[11px] font-medium rounded-lg transition-all cursor-pointer flex items-center gap-1"
          >
            <svg className="w-3 h-3" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.5">
              <line x1="12" y1="5" x2="12" y2="19" />
              <line x1="5" y1="12" x2="19" y2="12" />
            </svg>
            <span>Pair</span>
          </button>

          {onOpenSettings && (
            <button
              type="button"
              onClick={onOpenSettings}
              className="p-1 text-[#888] hover:text-white hover:bg-white/5 rounded-lg transition-colors cursor-pointer"
              title="Settings"
            >
              <svg className="w-4 h-4" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
                <circle cx="12" cy="12" r="3" />
                <path d="M19.4 15a1.65 1.65 0 0 0 .33 1.82l.06.06a2 2 0 0 1 0 2.83 2 2 0 0 1-2.83 0l-.06-.06a1.65 1.65 0 0 0-1.82-.33 1.65 1.65 0 0 0-1 1.51V21a2 2 0 0 1-2 2 2 2 0 0 1-2-2v-.09A1.65 1.65 0 0 0 9 19.4a1.65 1.65 0 0 0-1.82.33l-.06.06a2 2 0 0 1-2.83 0 2 2 0 0 1 0-2.83l.06-.06a1.65 1.65 0 0 0 .33-1.82 1.65 1.65 0 0 0-1.51-1H3a2 2 0 0 1-2-2 2 2 0 0 1 2-2h.09A1.65 1.65 0 0 0 4.6 9a1.65 1.65 0 0 0-.33-1.82l-.06-.06a2 2 0 0 1 0-2.83 2 2 0 0 1 2.83 0l.06.06a1.65 1.65 0 0 0 1.82.33H9a1.65 1.65 0 0 0 1-1.51V3a2 2 0 0 1 2-2 2 2 0 0 1 2 2v.09a1.65 1.65 0 0 0 1 1.51 1.65 1.65 0 0 0 1.82-.33l.06-.06a2 2 0 0 1 2.83 0 2 2 0 0 1 0 2.83l-.06.06a1.65 1.65 0 0 0-.33 1.82V9a1.65 1.65 0 0 0 1.51 1H21a2 2 0 0 1 2 2 2 2 0 0 1-2 2h-.09a1.65 1.65 0 0 0-1.51 1z" />
              </svg>
            </button>
          )}
        </div>
      </div>
      {/* 2. Compact Segmented Filter Tabs */}
      {sessions.length > 0 && (
        <div className="bg-[#11141a] border border-white/10 rounded-lg p-0.5 flex items-center w-fit">
          <button
            type="button"
            onClick={() => setFilter("online")}
            className={`py-1 px-2.5 rounded-md text-[11px] font-mono transition-all flex items-center gap-1.5 cursor-pointer ${
              filter === "online"
                ? "bg-[#4fc3f7] text-[#04222e] font-semibold shadow-xs"
                : "text-[#888] hover:text-white"
            }`}
          >
            <span>Online</span>
            <span className={`text-[10px] ${filter === "online" ? "text-[#04222e]/70" : "text-[#555]"}`}>
              {counts.online}
            </span>
          </button>

          <button
            type="button"
            onClick={() => setFilter("all")}
            className={`py-1 px-2.5 rounded-md text-[11px] font-mono transition-all flex items-center gap-1.5 cursor-pointer ${
              filter === "all"
                ? "bg-[#4fc3f7] text-[#04222e] font-semibold shadow-xs"
                : "text-[#888] hover:text-white"
            }`}
          >
            <span>All</span>
            <span className={`text-[10px] ${filter === "all" ? "text-[#04222e]/70" : "text-[#555]"}`}>
              {counts.all}
            </span>
          </button>

          <button
            type="button"
            onClick={() => setFilter("offline")}
            className={`py-1 px-2.5 rounded-md text-[11px] font-mono transition-all flex items-center gap-1.5 cursor-pointer ${
              filter === "offline"
                ? "bg-[#4fc3f7] text-[#04222e] font-semibold shadow-xs"
                : "text-[#888] hover:text-white"
            }`}
          >
            <span>Offline</span>
            <span className={`text-[10px] ${filter === "offline" ? "text-[#04222e]/70" : "text-[#555]"}`}>
              {counts.offline}
            </span>
          </button>
        </div>
      )}

      {/* 3. Empty State Handling */}
      {visibleSessions.length === 0 ? (
        <div className="flex flex-col items-center justify-center py-10 px-4 text-center">
          <div className="w-10 h-10 rounded-full bg-white/[0.03] border border-white/10 flex items-center justify-center mb-2.5 text-[#888]">
            <svg className="w-5 h-5 text-[#888]" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.5">
              <path d="M12 3a6 6 0 0 0 9 9 9 9 0 1 1-9-9Z" />
            </svg>
          </div>
          <div className="text-xs font-mono font-medium text-white mb-0.5">
            {filter === "online"
              ? "No sessions online"
              : filter === "offline"
              ? "No offline sessions"
              : "No sessions"}
          </div>
          <div className="text-[11px] font-mono text-[#666] max-w-xs">
            {filter === "online"
              ? "Live sessions appear here when active."
              : "Cached sessions show up here."}
          </div>
        </div>
      ) : (
        /* 4. High-Density Session Grouping */
        <div className="space-y-3 pt-1">
          {deviceKeys.map((devName) => (
            <div key={devName} className="space-y-1">
              {/* Peer Device Header */}
              <div className="px-1 text-[10px] font-mono font-semibold uppercase tracking-wider text-[#666]">
                {devName}
              </div>

              {/* High-Density Session Rows */}
              <div className="bg-[#0b0e14] border border-white/10 rounded-xl overflow-hidden shadow-xs">
                {groupedByDevice[devName].map((s, idx, arr) => {
                  const isLive = s.isLive || s.status === "online" || s.status === "working";
                  const isWorking = s.status === "working";
                  const initial = (s.name || "?").trim().charAt(0).toUpperCase();
                  const isLast = idx === arr.length - 1;

                  return (
                    <div key={s.id}>
                      <div
                        onClick={() => onOpenSession(s)}
                        className="group flex items-center justify-between py-2.5 px-3 hover:bg-white/[0.035] transition-[background-color] duration-150 cursor-pointer"
                      >
                        {/* Left: Refined Avatar + Compact Title Block */}
                        <div className="flex items-center gap-2.5 min-w-0">
                          {/* Refined Avatar */}
                          <div className="w-7 h-7 rounded-lg bg-[#141822] border border-white/10 flex items-center justify-center text-[#4fc3f7] font-mono font-semibold text-xs shrink-0 group-hover:border-[#4fc3f7]/50 transition-colors">
                            {initial}
                          </div>

                          {/* Title + Metadata */}
                          <div className="min-w-0">
                            <div className="flex items-center gap-1.5">
                              <span className="text-xs font-medium text-white group-hover:text-[#4fc3f7] transition-colors truncate">
                                {s.name}
                              </span>
                              <span className="text-[10px] font-mono text-[#555] bg-white/[0.03] px-1 py-0.2 rounded border border-white/5">
                                {s.roomId}
                              </span>
                            </div>

                            {/* Subtitle: Model when online or cwd path when offline */}
                            <div className="text-[10px] font-mono mt-0.2 truncate">
                              {isLive && s.model ? (
                                <span className="text-[#4fc3f7]">{s.model}</span>
                              ) : (
                                <span className="text-[#666]">
                                  {s.cwd || `Last paired: ${new Date(s.pairedAt).toLocaleDateString()}`}
                                </span>
                              )}
                            </div>
                          </div>
                        </div>

                        {/* Right: Presence Dot + Chevron */}
                        <div className="flex items-center gap-2.5 shrink-0 ml-3">
                          {isWorking ? (
                            <div className="flex items-center gap-1 text-[11px] font-mono text-[#38bdf8]">
                              <span className="w-1.5 h-1.5 rounded-full bg-[#38bdf8] animate-pulse" />
                              <span>working…</span>
                            </div>
                          ) : isLive ? (
                            <div className="flex items-center gap-1 text-[11px] font-mono text-[#5fd38a]">
                              <span className="w-1.5 h-1.5 rounded-full bg-[#5fd38a]" />
                              <span>online</span>
                            </div>
                          ) : (
                            <div className="flex items-center gap-1 text-[11px] font-mono text-[#555]">
                              <span className="w-1.5 h-1.5 rounded-full bg-[#444]" />
                              <span>offline</span>
                            </div>
                          )}

                          <svg className="w-3.5 h-3.5 text-[#444] group-hover:text-white transition-colors" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
                            <polyline points="9 18 15 12 9 6" />
                          </svg>
                        </div>
                      </div>
                      {!isLast && <div className="h-[1px] bg-white/[0.05] w-full" />}
                    </div>
                  );
                })}
              </div>
            </div>
          ))}
        </div>
      )}
    </div>
  );
}
