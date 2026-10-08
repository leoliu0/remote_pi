"use client";

import { useState } from "react";
import type { RelayStatus } from "./relay-connection";
import { RelayPicker } from "./relay-picker";
import {
  filterItems,
  homeCounts,
  homeItems,
  onlineListPending,
  peerLabel,
  roomDisplayName,
  tileStatus,
  tileSubtitle,
  type HomeFilter,
  type HomeItem,
  type PeerRecord,
  type RoomsState,
  type TileStatus,
} from "./session-list";

interface HomeViewProps {
  peers: PeerRecord[];
  rooms: RoomsState;
  relayUrl: string;
  relayStatus: RelayStatus;
  onRelayChange: (url: string) => void;
  onOpenItem: (item: HomeItem) => void;
  /** True until the owner's mesh blob (paired PCs) has been read once. */
  peersLoading: boolean;
  onOpenSettings: () => void;
}

const FILTERS: Array<{ id: HomeFilter; label: string }> = [
  { id: "all", label: "All" },
  { id: "online", label: "Online" },
  { id: "offline", label: "Offline" },
];

const FILTER_EMPTY: Record<HomeFilter, { title: string; subtitle: string }> = {
  online: { title: "No sessions online", subtitle: "Live sessions appear here when a paired Pi is active." },
  offline: { title: "No offline sessions", subtitle: "Sessions you’ve seen before that aren’t live show up here." },
  all: { title: "Nothing here…", subtitle: "When a paired Pi opens a session, it shows up here." },
};

function Spinner() {
  return (
    <div className="flex justify-center py-12">
      <div className="w-5 h-5 border-2 border-[#4fc3f7] border-t-transparent rounded-full animate-spin" />
    </div>
  );
}

function EmptyNote({ title, subtitle }: { title: string; subtitle: string }) {
  return (
    <div className="flex flex-col items-center justify-center py-12 px-4 text-center opacity-60">
      <div className="text-xs font-medium text-[#ccc] mb-1">{title}</div>
      <div className="text-[11px] text-[#666] max-w-xs">{subtitle}</div>
    </div>
  );
}

function StatusBadge({ status }: { status: TileStatus }) {
  if (status === "working") {
    return (
      <span className="flex items-center gap-1 px-1.5 py-0.5 rounded-full border border-[#38bdf8] bg-[#38bdf8]/15 text-[10px] text-[#38bdf8]">
        <span className="w-1.5 h-1.5 rounded-full bg-[#38bdf8] animate-pulse" />
        working
      </span>
    );
  }
  if (status === "done") {
    return (
      <span className="flex items-center gap-1 px-1.5 py-0.5 rounded-full border border-[#5fd38a] bg-[#5fd38a]/15 text-[10px] font-bold text-[#5fd38a]">
        ✓ Done
      </span>
    );
  }
  const color = status === "online" ? "bg-[#5fd38a]" : status === "reconnecting" ? "bg-amber-400" : "bg-[#444]";
  return <span title={status} aria-label={status} className={`w-2.5 h-2.5 rounded-full ${color}`} />;
}

export function HomeView({
  peers,
  rooms,
  relayUrl,
  relayStatus,
  onRelayChange,
  onOpenItem,
  peersLoading,
  onOpenSettings,
}: HomeViewProps) {
  const [filter, setFilter] = useState<HomeFilter>("all");
  const connected = relayStatus === "online";
  const items = homeItems(peers, rooms);
  const counts = homeCounts(items, rooms, connected);
  const visible = filterItems(items, filter, rooms, connected);
  const pending = onlineListPending(filter, visible.length, rooms);

  let body: React.ReactNode;
  if (peers.length === 0) {
    body = peersLoading ? (
      <Spinner />
    ) : (
      <div className="flex flex-col items-center justify-center py-14 px-4 text-center">
        <div className="text-sm text-[#ccc] mb-1">No pairings yet</div>
        <div className="text-xs text-[#666]">Pair a PC in the Remote Pi app on your phone — it shows up here.</div>
      </div>
    );
  } else if (counts.all === 0) {
    // Paired, no rooms at all: no tabs, nothing to filter.
    body = pending ? <Spinner /> : <EmptyNote title="Nothing here…" subtitle="Run /remote-pi on your PC to start a session." />;
  } else {
    const groups: Array<{ peer: PeerRecord; items: HomeItem[] }> = [];
    for (const it of visible) {
      const last = groups[groups.length - 1];
      if (last && last.peer.remoteEpk === it.peer.remoteEpk) last.items.push(it);
      else groups.push({ peer: it.peer, items: [it] });
    }
    body = (
      <>
        <div className="bg-[#11141a] border border-white/10 rounded-lg p-0.5 flex items-center w-fit">
          {FILTERS.map((f) => (
            <button
              key={f.id}
              type="button"
              onClick={() => setFilter(f.id)}
              className={`py-1 px-2.5 rounded-md text-[11px] transition-all flex items-center gap-1.5 cursor-pointer ${
                filter === f.id ? "bg-[#4fc3f7] text-[#04222e] font-semibold" : "text-[#888] hover:text-white"
              }`}
            >
              <span>{f.label}</span>
              <span className={`text-[10px] ${filter === f.id ? "text-[#04222e]/70" : "text-[#555]"}`}>{counts[f.id]}</span>
            </button>
          ))}
        </div>

        {visible.length === 0 ? (
          pending ? <Spinner /> : <EmptyNote {...FILTER_EMPTY[filter]} />
        ) : (
          <div className="space-y-3 pt-1">
            {groups.map(({ peer, items: groupItems }) => (
              <section key={peer.remoteEpk} className="space-y-1">
                <div className="px-1 text-[10px] font-semibold uppercase tracking-wider text-[#666]">{peerLabel(peer)}</div>
                <div className="bg-[#0b0e14] border border-white/10 rounded-xl overflow-hidden divide-y divide-white/[0.05]">
                  {groupItems.map((it) => {
                    const title = roomDisplayName(it.peer, it.room);
                    const subtitle = tileSubtitle(it);
                    return (
                      <button
                        key={it.room.roomId}
                        type="button"
                        onClick={() => onOpenItem(it)}
                        className="group w-full flex items-center gap-2.5 py-2.5 px-3 text-left hover:bg-white/[0.035] transition-colors cursor-pointer"
                      >
                        <span className="w-8 h-8 rounded-full bg-[#141822] border border-white/10 flex items-center justify-center text-[#4fc3f7] font-semibold text-xs shrink-0">
                          {title.trim().charAt(0).toUpperCase() || "?"}
                        </span>
                        <span className="flex-1 min-w-0">
                          <span className="block text-xs font-medium text-white truncate group-hover:text-[#4fc3f7] transition-colors">
                            {title}
                          </span>
                          <span className={`block text-[10px] truncate ${subtitle.accented ? "text-[#4fc3f7]" : "text-[#666]"}`}>
                            {subtitle.text}
                          </span>
                        </span>
                        <StatusBadge status={tileStatus(rooms, connected, it)} />
                      </button>
                    );
                  })}
                </div>
              </section>
            ))}
          </div>
        )}
      </>
    );
  }

  return (
    <div className="max-w-2xl mx-auto w-full px-3 sm:px-4 py-3 sm:py-4 flex flex-col space-y-3 font-mono">
      <div className="flex flex-col gap-1.5 pb-2.5 border-b border-white/10">
        <div className="flex items-center justify-between">
          <div className="flex items-center gap-1.5 text-sm font-semibold text-white tracking-tight">
            <span className="text-[#4fc3f7] font-bold">π</span>
            <span>Remote Pi</span>
          </div>
          <div className="flex items-center gap-2">
            <button
              type="button"
              onClick={onOpenSettings}
              className="p-1 text-[#888] hover:text-white hover:bg-white/5 rounded-lg cursor-pointer"
              title="Settings"
              aria-label="Settings"
            >
              <svg className="w-4 h-4" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
                <circle cx="12" cy="12" r="3" />
                <path d="M19.4 15a1.65 1.65 0 0 0 .33 1.82l.06.06a2 2 0 0 1 0 2.83 2 2 0 0 1-2.83 0l-.06-.06a1.65 1.65 0 0 0-1.82-.33 1.65 1.65 0 0 0-1 1.51V21a2 2 0 0 1-2 2 2 2 0 0 1-2-2v-.09A1.65 1.65 0 0 0 9 19.4a1.65 1.65 0 0 0-1.82.33l-.06.06a2 2 0 0 1-2.83 0 2 2 0 0 1 0-2.83l.06-.06a1.65 1.65 0 0 0 .33-1.82 1.65 1.65 0 0 0-1.51-1H3a2 2 0 0 1-2-2 2 2 0 0 1 2-2h.09A1.65 1.65 0 0 0 4.6 9a1.65 1.65 0 0 0-.33-1.82l-.06-.06a2 2 0 0 1 0-2.83 2 2 0 0 1 2.83 0l.06.06a1.65 1.65 0 0 0 1.82.33H9a1.65 1.65 0 0 0 1-1.51V3a2 2 0 0 1 2-2 2 2 0 0 1 2 2v.09a1.65 1.65 0 0 0 1 1.51 1.65 1.65 0 0 0 1.82-.33l.06-.06a2 2 0 0 1 2.83 0 2 2 0 0 1 0 2.83l-.06.06a1.65 1.65 0 0 0-.33 1.82V9a1.65 1.65 0 0 0 1.51 1H21a2 2 0 0 1 2 2 2 2 0 0 1-2 2h-.09a1.65 1.65 0 0 0-1.51 1z" />
              </svg>
            </button>
          </div>
        </div>
        <RelayPicker key={relayUrl} relayUrl={relayUrl} status={relayStatus} onSave={onRelayChange} />
      </div>
      {body}
    </div>
  );
}
