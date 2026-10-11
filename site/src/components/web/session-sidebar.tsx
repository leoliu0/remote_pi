"use client";

import { useState } from "react";
import { EmptyNote, FILTER_EMPTY, FilterTabs, SessionAvatar, Spinner, STATUS_DOT, StatusBadge } from "./home-view";
import {
  filterItems,
  groupItemsByPeer,
  homeCounts,
  homeItems,
  onlineListPending,
  peerLabel,
  roomDisplayName,
  roomKey,
  tileStatus,
  tileSubtitle,
  type HomeFilter,
  type HomeItem,
  type PeerRecord,
  type RoomsState,
} from "./session-list";

const COLLAPSED_KEY = "remotepi_sessions_sidebar";

interface SessionSidebarProps {
  peers: PeerRecord[];
  rooms: RoomsState;
  connected: boolean;
  relayUnreachable: boolean;
  /** Shared with Home's tabs. */
  filter: HomeFilter;
  onFilterChange: (filter: HomeFilter) => void;
  /** `roomKey` of the open chat. */
  activeKey: string;
  onOpenItem: (item: HomeItem) => void;
}

function PanelIcon({ open }: { open: boolean }) {
  return (
    <svg className="w-4 h-4" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
      <rect width="18" height="18" x="3" y="3" rx="2" />
      <path d="M9 3v18" />
      <path d={open ? "m16 15-3-3 3-3" : "m14 9 3 3-3 3"} />
    </svg>
  );
}

/**
 * Wide screens: every session beside the chat, one click to switch (the
 * app's tablet list pane). Collapses to a rail of avatars; the choice persists.
 */
export function SessionSidebar({
  peers,
  rooms,
  connected,
  relayUnreachable,
  filter,
  onFilterChange,
  activeKey,
  onOpenItem,
}: SessionSidebarProps) {
  const [collapsed, setCollapsedState] = useState(() => {
    try {
      return localStorage.getItem(COLLAPSED_KEY) === "collapsed";
    } catch {
      return false;
    }
  });
  const setCollapsed = (next: boolean) => {
    setCollapsedState(next);
    try {
      localStorage.setItem(COLLAPSED_KEY, next ? "collapsed" : "open");
    } catch {}
  };

  const items = homeItems(peers, rooms);
  const visible = filterItems(items, filter, rooms, connected);
  const toggleClass = "p-1.5 text-[#888] hover:text-white hover:bg-white/10 rounded-lg transition-colors cursor-pointer";

  if (collapsed) {
    // The rail has no tabs: keep the open chat in it even when the filter hides it.
    const isActive = (it: HomeItem) => roomKey(it.peer.remoteEpk, it.room.roomId) === activeKey;
    const railItems = visible.some(isActive) ? visible : [...items.filter(isActive), ...visible];
    return (
      <aside aria-label="Sessions" className="hidden lg:flex flex-col w-14 shrink-0 h-screen border-r border-white/10 bg-[#0a0c10]">
        <div className="h-14 border-b border-white/10 flex items-center justify-center shrink-0">
          <button type="button" onClick={() => setCollapsed(false)} className={toggleClass} title="Show sessions" aria-label="Show sessions">
            <PanelIcon open={false} />
          </button>
        </div>
        <nav className="flex-1 overflow-y-auto py-3 flex flex-col items-center gap-2">
          {railItems.map((it) => {
            const title = roomDisplayName(it.peer, it.room);
            const key = roomKey(it.peer.remoteEpk, it.room.roomId);
            return (
              <button
                key={key}
                type="button"
                onClick={() => onOpenItem(it)}
                title={`${title} · ${peerLabel(it.peer)}`}
                aria-label={title}
                aria-current={key === activeKey ? "page" : undefined}
                className={`relative rounded-full cursor-pointer ${key === activeKey ? "ring-2 ring-[#4fc3f7]" : "hover:ring-1 hover:ring-white/30"}`}
              >
                <SessionAvatar title={title} className="w-8 h-8 text-xs" />
                <span
                  className={`absolute -bottom-0.5 -right-0.5 w-2.5 h-2.5 rounded-full border-2 border-[#0a0c10] ${STATUS_DOT[tileStatus(rooms, connected, it)]}`}
                />
              </button>
            );
          })}
        </nav>
      </aside>
    );
  }

  let list: React.ReactNode;
  if (visible.length === 0) {
    list = onlineListPending(filter, 0, rooms, relayUnreachable) ? <Spinner /> : <EmptyNote {...FILTER_EMPTY[filter]} />;
  } else {
    list = groupItemsByPeer(visible).map(({ peer, items: groupItems }) => (
      <section key={peer.remoteEpk} className="pb-2">
        <div className="px-4 pt-2 pb-1 text-[10px] font-semibold uppercase tracking-wider text-[#666] truncate">{peerLabel(peer)}</div>
        {groupItems.map((it) => {
          const title = roomDisplayName(it.peer, it.room);
          const subtitle = tileSubtitle(it);
          const active = roomKey(it.peer.remoteEpk, it.room.roomId) === activeKey;
          return (
            <button
              key={it.room.roomId}
              type="button"
              onClick={() => onOpenItem(it)}
              aria-current={active ? "page" : undefined}
              className={`group w-full flex items-center gap-2 py-2 pl-[13px] pr-3 text-left border-l-[3px] transition-colors cursor-pointer ${
                active ? "border-[#4fc3f7] bg-[#4fc3f7]/[0.07]" : "border-transparent hover:bg-white/[0.035]"
              }`}
            >
              <SessionAvatar title={title} className="w-6 h-6 text-[10px]" />
              <span className="flex-1 min-w-0">
                <span
                  className={`block text-xs font-medium truncate transition-colors ${
                    active ? "text-[#4fc3f7]" : "text-white group-hover:text-[#4fc3f7]"
                  }`}
                >
                  {title}
                </span>
                <span className={`block text-[10px] truncate ${subtitle.accented ? "text-[#4fc3f7]/80" : "text-[#666]"}`}>
                  {subtitle.text}
                </span>
              </span>
              <StatusBadge status={tileStatus(rooms, connected, it)} />
            </button>
          );
        })}
      </section>
    ));
  }

  return (
    <aside aria-label="Sessions" className="hidden lg:flex flex-col w-[260px] shrink-0 h-screen border-r border-white/10 bg-[#0a0c10] font-mono">
      <div className="h-14 pl-4 pr-2 border-b border-white/10 flex items-center justify-between gap-2 shrink-0">
        <span className="text-sm font-semibold text-white">Sessions</span>
        <button type="button" onClick={() => setCollapsed(true)} className={toggleClass} title="Hide sessions" aria-label="Hide sessions">
          <PanelIcon open />
        </button>
      </div>
      <div className="px-3 pt-3 pb-1 shrink-0">
        <FilterTabs filter={filter} counts={homeCounts(items, rooms, connected)} onChange={onFilterChange} />
      </div>
      <nav className="flex-1 overflow-y-auto">{list}</nav>
    </aside>
  );
}
