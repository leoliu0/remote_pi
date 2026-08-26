"use client";

import { useState } from "react";
import { PairedSession } from "./web-client";

interface HomeViewProps {
  sessions: PairedSession[];
  isRelayConnected?: boolean;
  deviceName?: string;
  onOpenSession: (session: PairedSession) => void;
  onOpenPairModal: () => void;
  onDeleteSession: (id: string) => void;
}

export function HomeView({
  sessions,
  isRelayConnected = true,
  deviceName = "Remote Pi",
  onOpenSession,
  onOpenPairModal,
  onDeleteSession,
}: HomeViewProps) {
  // Mobile Parity: default tab is "online" (matches HomeList.filter = HomeFilter.online in Flutter)
  const [filter, setFilter] = useState<"all" | "online" | "offline">("online");

  // Calculate live vs offline counts
  const onlineSessions = sessions.filter((s) => s.isLive || s.status === "online" || s.status === "working");
  const offlineSessions = sessions.filter((s) => !s.isLive && s.status !== "online" && s.status !== "working");

  const counts = {
    all: sessions.length,
    online: onlineSessions.length,
    offline: offlineSessions.length,
  };

  const visibleSessions = filter === "all"
    ? sessions
    : filter === "online"
    ? onlineSessions
    : offlineSessions;

  // Group visible sessions by Peer / Device (Mobile Parity)
  const groupedByDevice: Record<string, PairedSession[]> = {};
  for (const s of visibleSessions) {
    const dev = (s.device || deviceName || "Remote Pi").toUpperCase();
    if (!groupedByDevice[dev]) groupedByDevice[dev] = [];
    groupedByDevice[dev].push(s);
  }

  const deviceKeys = Object.keys(groupedByDevice);

  return (
    <div className="flex-1 max-w-4xl mx-auto w-full px-4 sm:px-6 py-6 sm:py-8 flex flex-col">
      {/* 1. iOS-style Large Title Header (Mobile Parity) */}
      <div className="flex flex-col sm:flex-row sm:items-end justify-between gap-4 mb-6 pb-6 border-b border-white/10">
        <div>
          <h1 className="text-3xl sm:text-4xl font-bold tracking-tight text-white font-[family-name:var(--ff-display)] mb-2">
            Remote Pi
          </h1>
          {/* Subtitle: ● Relay · Connected */}
          <div className="flex items-center gap-2 text-xs font-mono text-[#a3a3a3]">
            <span className={`w-2 h-2 rounded-full ${isRelayConnected ? "bg-[#5fd38a]" : "bg-[#f59e0b]"}`} />
            <span className="text-white font-medium">Relay</span>
            <span className="text-[#555]">&bull;</span>
            <span className={isRelayConnected ? "text-[#a3a3a3]" : "text-[#f59e0b]"}>
              {isRelayConnected ? "Connected" : "Offline"}
            </span>
          </div>
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

      {/* 2. 3-Pill Filter Tabs (All · Online · Offline) - Mobile Parity */}
      {sessions.length > 0 && (
        <div className="bg-[#161b22] border border-white/10 rounded-xl p-1 flex items-center mb-6 max-w-md">
          <button
            type="button"
            onClick={() => setFilter("all")}
            className={`flex-1 py-1.5 px-3 rounded-lg text-xs font-mono font-medium transition-all flex items-center justify-center gap-1.5 cursor-pointer ${
              filter === "all"
                ? "bg-[#4fc3f7] text-[#04222e] shadow-sm font-semibold"
                : "text-[#888] hover:text-white"
            }`}
          >
            <span>All</span>
            <span className={`text-[11px] px-1.5 py-0.2 rounded-full ${filter === "all" ? "bg-[#04222e]/20 text-[#04222e]" : "text-[#555]"}`}>
              {counts.all}
            </span>
          </button>

          <button
            type="button"
            onClick={() => setFilter("online")}
            className={`flex-1 py-1.5 px-3 rounded-lg text-xs font-mono font-medium transition-all flex items-center justify-center gap-1.5 cursor-pointer ${
              filter === "online"
                ? "bg-[#4fc3f7] text-[#04222e] shadow-sm font-semibold"
                : "text-[#888] hover:text-white"
            }`}
          >
            <span>Online</span>
            <span className={`text-[11px] px-1.5 py-0.2 rounded-full ${filter === "online" ? "bg-[#04222e]/20 text-[#04222e]" : "text-[#555]"}`}>
              {counts.online}
            </span>
          </button>

          <button
            type="button"
            onClick={() => setFilter("offline")}
            className={`flex-1 py-1.5 px-3 rounded-lg text-xs font-mono font-medium transition-all flex items-center justify-center gap-1.5 cursor-pointer ${
              filter === "offline"
                ? "bg-[#4fc3f7] text-[#04222e] shadow-sm font-semibold"
                : "text-[#888] hover:text-white"
            }`}
          >
            <span>Offline</span>
            <span className={`text-[11px] px-1.5 py-0.2 rounded-full ${filter === "offline" ? "bg-[#04222e]/20 text-[#04222e]" : "text-[#555]"}`}>
              {counts.offline}
            </span>
          </button>
        </div>
      )}

      {/* 3. Empty State Handling (Mobile Parity: HomeFilterEmptyState with Moon Icon) */}
      {visibleSessions.length === 0 ? (
        <div className="flex-1 flex flex-col items-center justify-center py-16 px-4 text-center">
          <div className="w-14 h-14 rounded-full bg-white/[0.03] border border-white/10 flex items-center justify-center mb-4 text-[#888]">
            <svg className="w-7 h-7 text-[#888]" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.5">
              <path d="M12 3a6 6 0 0 0 9 9 9 9 0 1 1-9-9Z" />
            </svg>
          </div>
          <h3 className="text-sm font-mono font-medium text-white mb-1">
            {filter === "online"
              ? "No sessions online"
              : filter === "offline"
              ? "No offline sessions"
              : "Nothing here…"}
          </h3>
          <p className="text-xs font-mono text-[#888] max-w-xs leading-relaxed">
            {filter === "online"
              ? "Live sessions appear here when a paired Pi is active."
              : filter === "offline"
              ? "Sessions you’ve seen before that aren’t live show up here."
              : "When a paired Pi opens a session, it shows up here."}
          </p>
          {filter !== "all" && counts.all > 0 && (
            <button
              type="button"
              onClick={() => setFilter("all")}
              className="mt-4 px-3 py-1.5 rounded-lg bg-white/[0.04] hover:bg-white/10 text-xs font-mono text-[#4fc3f7] transition-all cursor-pointer"
            >
              View all sessions ({counts.all})
            </button>
          )}
        </div>
      ) : (
        /* 4. Session Grouping by Peer (Mobile Parity) */
        <div className="space-y-6">
          {deviceKeys.map((devName) => (
            <div key={devName} className="space-y-2">
              {/* PeerSectionHeader */}
              <div className="px-1 text-[11px] font-mono font-semibold uppercase tracking-wider text-[#888]">
                {devName}
              </div>

              {/* Session Tiles in this Peer group */}
              <div className="bg-[#0e1217] border border-white/10 rounded-2xl overflow-hidden">
                {groupedByDevice[devName].map((s, idx, arr) => {
                  const isLive = s.isLive || s.status === "online" || s.status === "working";
                  const isWorking = s.status === "working";
                  const initial = (s.name || "?").trim().charAt(0).toUpperCase();
                  const isLast = idx === arr.length - 1;

                  return (
                    <div key={s.id}>
                      <div
                        onClick={() => onOpenSession(s)}
                        className="group flex items-center justify-between p-4 hover:bg-white/[0.03] transition-[background-color] duration-150 cursor-pointer"
                      >
                        {/* Avatar circle with initial letter */}
                        <div className="w-10 h-10 rounded-full bg-[#161b22] border border-white/10 flex items-center justify-center text-[#4fc3f7] font-mono font-semibold text-base shrink-0 group-hover:border-[#4fc3f7]/40 transition-colors">
                          {initial}
                        </div>

                        {/* Title Block */}
                        <div className="min-w-0">
                          <div className="flex items-center gap-2">
                            <span className="text-sm font-medium text-white group-hover:text-[#4fc3f7] transition-colors truncate">
                              {s.name}
                            </span>
                            <span className="text-[11px] font-mono text-[#555] bg-white/[0.03] px-1.5 py-0.5 rounded border border-white/5">
                              {s.roomId}
                            </span>
                          </div>

                          {/* Subtitle: Model when online, or cwd / paired timestamp when offline */}
                          <div className="text-xs font-mono mt-0.5 truncate">
                            {isLive && s.model ? (
                              <span className="text-[#4fc3f7] font-medium">{s.model}</span>
                            ) : (
                              <span className="text-[#888]">
                                {s.cwd || `Last paired: ${new Date(s.pairedAt).toLocaleDateString()}`}
                              </span>
                            )}
                          </div>
                        </div>
                      </div>

                      {/* Right Presence Indicator & Chevron */}
                      <div className="flex items-center gap-3 shrink-0 ml-4">
                        {isWorking ? (
                          <div className="flex items-center gap-1.5 text-xs font-mono text-[#38bdf8]">
                            <span className="w-2.5 h-2.5 rounded-full bg-[#38bdf8] animate-pulse" />
                            <span className="hidden sm:inline">working…</span>
                          </div>
                        ) : isLive ? (
                          <div className="flex items-center gap-1.5 text-xs font-mono text-[#5fd38a]">
                            <span className="w-2.5 h-2.5 rounded-full bg-[#5fd38a]" />
                            <span className="hidden sm:inline">online</span>
                          </div>
                        ) : (
                          <div className="flex items-center gap-1.5 text-xs font-mono text-[#666]">
                            <span className="w-2 h-2 rounded-full bg-[#555]" />
                            <span className="hidden sm:inline">offline</span>
                          </div>
                        )}

                        <svg className="w-4 h-4 text-[#555] group-hover:text-white transition-colors" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
                          <polyline points="9 18 15 12 9 6" />
                        </svg>
                      </div>
                      {!isLast && <div className="h-[1px] bg-white/[0.06] w-full" />}
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
