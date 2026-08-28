import type { PairedSession } from "./web-client";

export type RelayRoomLite = {
  room_id?: string;
  name?: string;
  cwd?: string;
  model?: string;
  thinking?: string;
  working?: boolean;
  started_at?: number;
};

export type HomeListMode = "loading" | "empty" | "list";

export function homeListMode(loading: boolean, visibleCount: number): HomeListMode {
  if (loading && visibleCount === 0) return "loading";
  if (visibleCount === 0) return "empty";
  return "list";
}

export function sortSessions(list: PairedSession[]): PairedSession[] {
  return [...list].sort((a, b) => {
    const rank = (s: PairedSession) =>
      s.status === "working" ? 0 : s.isLive || s.status === "online" ? 1 : 2;
    const rankDiff = rank(a) - rank(b);
    if (rankDiff !== 0) return rankDiff;
    const nameA = (a.name || a.roomId || "").toLowerCase();
    const nameB = (b.name || b.roomId || "").toLowerCase();
    if (nameA !== nameB) return nameA.localeCompare(nameB);
    return (a.roomId || "").localeCompare(b.roomId || "");
  });
}

export function sameSessionList(a: PairedSession[], b: PairedSession[]): boolean {
  if (a.length !== b.length) return false;
  for (let i = 0; i < a.length; i++) {
    if (
      a[i].id !== b[i].id ||
      a[i].status !== b[i].status ||
      a[i].model !== b[i].model ||
      a[i].isLive !== b[i].isLive
    ) {
      return false;
    }
  }
  return true;
}

export function shouldIgnoreEmptyRoomsSnapshot(
  prev: PairedSession[],
  peer: string,
  rooms: RelayRoomLite[],
): boolean {
  return (
    rooms.length === 0 &&
    prev.some(
      (s) =>
        s.remoteEpk === peer &&
        (s.isLive || s.status === "online" || s.status === "working"),
    )
  );
}

export function mergeRemoteSessions(opts: {
  prev: PairedSession[];
  remote: PairedSession[];
  stored: PairedSession[];
  roomsComplete: boolean;
}): PairedSession[] {
  const { prev, remote, stored, roomsComplete } = opts;
  if (!roomsComplete && remote.length === 0 && prev.length > 0) {
    return prev;
  }
  const map = new Map<string, PairedSession>();
  if (!roomsComplete) {
    for (const s of prev) map.set(s.roomId, s);
  }
  for (const s of remote) map.set(s.roomId, s);
  for (const s of stored) {
    if (!map.has(s.roomId)) map.set(s.roomId, s);
  }
  const next = sortSessions(Array.from(map.values()));
  return sameSessionList(prev, next) ? prev : next;
}

export function applyPeerRooms(
  prev: PairedSession[],
  peer: string,
  rooms: RelayRoomLite[],
  deviceFallback: string,
): PairedSession[] {
  const live = new Map<string, RelayRoomLite>();
  for (const r of rooms) {
    if (r.room_id) live.set(r.room_id, r);
  }
  const seen = new Set<string>();
  let device = deviceFallback;
  let relayUrl = "";
  for (const s of prev) {
    if (s.remoteEpk === peer) {
      if (s.device) device = s.device;
      if (s.relayUrl) relayUrl = s.relayUrl;
    }
  }
  const next: PairedSession[] = [];
  for (const s of prev) {
    if (s.remoteEpk !== peer) {
      next.push(s);
      continue;
    }
    const r = live.get(s.roomId);
    seen.add(s.roomId);
    if (r) {
      next.push({
        ...s,
        name: r.name || s.name,
        cwd: r.cwd || s.cwd,
        model: r.model || s.model,
        thinking: r.thinking || s.thinking,
        status: r.working ? "working" : "online",
        isLive: true,
      });
    } else {
      next.push({ ...s, status: "offline", isLive: false });
    }
  }
  for (const r of rooms) {
    const id = r.room_id;
    if (!id || seen.has(id)) continue;
    next.push({
      id: `${peer}_${id}`,
      name: r.name || (r.cwd ? r.cwd.split("/").pop() || id : id),
      device,
      remoteEpk: peer,
      relayUrl,
      roomId: id,
      cwd: r.cwd,
      model: r.model,
      thinking: r.thinking,
      status: r.working ? "working" : "online",
      isLive: true,
      pairedAt: r.started_at ? new Date(r.started_at).toISOString() : new Date().toISOString(),
      lastConnectedAt: new Date().toISOString(),
    });
  }
  return sortSessions(next);
}

export function upsertLiveRoom(
  prev: PairedSession[],
  peer: string,
  room: RelayRoomLite,
  deviceFallback: string,
): PairedSession[] {
  const roomId = room.room_id;
  if (!roomId) return prev;
  let found = false;
  const next = prev.map((s) => {
    if (s.remoteEpk !== peer || s.roomId !== roomId) return s;
    found = true;
    return {
      ...s,
      name: room.name || s.name,
      cwd: room.cwd || s.cwd,
      model: room.model || s.model,
      thinking: room.thinking || s.thinking,
      status: (room.working ? "working" : "online") as "working" | "online",
      isLive: true,
    };
  });
  if (found) return next;
  const device = prev.find((s) => s.remoteEpk === peer)?.device || deviceFallback;
  const relayUrl = prev.find((s) => s.remoteEpk === peer)?.relayUrl || "";
  next.push({
    id: `${peer}_${roomId}`,
    name: room.name || (room.cwd ? room.cwd.split("/").pop() || roomId : roomId),
    device,
    remoteEpk: peer,
    relayUrl,
    roomId,
    cwd: room.cwd,
    model: room.model,
    thinking: room.thinking,
    status: room.working ? "working" : "online",
    isLive: true,
    pairedAt: room.started_at ? new Date(room.started_at).toISOString() : new Date().toISOString(),
    lastConnectedAt: new Date().toISOString(),
  });
  return sortSessions(next);
}
