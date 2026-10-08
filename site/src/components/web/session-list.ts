// Pure session-list state for the web Home view.
//
// Mirrors the mobile app's `ConnectionManager._onControl` room/presence
// bookkeeping (app/lib/data/transport/connection_manager.dart) and the
// Home derivations (app/lib/ui/home/viewmodels/home_viewmodel.dart,
// states/home_state.dart, widgets/session_tile.dart):
//
// - `roomsByPeer` is the CANONICAL set (cached + announced). Rooms stay in it
//   after they end so Home can still show them as offline.
// - `liveRoomIds` holds the roomIds the relay reports alive right now. A room
//   in `roomsByPeer` but not in `liveRoomIds` is offline.
// - Omitted wire fields preserve cached values exactly the way the app does.
//
// No runtime imports: the node test runner loads this file directly.

/** A paired PC, projected from the owner's signed mesh blob. */
export interface PeerRecord {
  /** Standard base64 Ed25519 pubkey of the paired PC. */
  remoteEpk: string;
  /** Mesh projection: the nickname, else `remote_pi` (app's storage.dart). */
  sessionName: string;
  /** User-facing PC label set on the phone. */
  nickname?: string;
  relayUrl: string;
  pairedAt: string;
}

export interface RoomInfo {
  roomId: string;
  name: string | null;
  cwd: string | null;
  startedAt: number;
  model: string | null;
  thinking: string | null;
  working: boolean;
  goal: string | null;
  loop: string | null;
  plan: string | null;
}

export interface PresenceState {
  online: boolean;
  sinceTs: number | null;
}

export type ControlFrame =
  | { type: "peer_online"; peer: string }
  | { type: "peer_offline"; peer: string; sinceTs: number }
  | { type: "presence"; states: Array<{ peer: string; online: boolean; sinceTs: number | null }> }
  | {
      type: "room_announced";
      peer: string;
      roomId: string;
      name: string | null;
      cwd: string | null;
      startedAt: number;
      model: string | null;
      thinking: string | null;
      working: boolean | null;
      goal: string | null;
      loop: string | null;
      plan: string | null;
    }
  | { type: "room_ended"; peer: string; roomId: string; sinceTs: number }
  | { type: "rooms"; peer: string; rooms: RoomInfo[] }
  | {
      type: "room_meta_updated";
      peer: string;
      roomId: string;
      model: string | null;
      thinking: string | null;
      working: boolean | null;
      goal: string | null;
      loop: string | null;
      plan: string | null;
      hasModel: boolean;
      hasThinking: boolean;
      hasGoal: boolean;
      hasLoop: boolean;
      hasPlan: boolean;
    };

export interface RoomsState {
  /** Keyed by standard-base64 epk. */
  roomsByPeer: Record<string, RoomInfo[]>;
  liveRoomIds: Record<string, string[]>;
  /** True once the relay delivered a rooms snapshot or an announce. */
  liveRoomsKnown: boolean;
  presence: Record<string, PresenceState>;
  /** Pending working→idle debounces: `${epk}:${roomId}` → timer token. */
  workingOff: Record<string, number>;
  /** Rooms that finished a turn while not being viewed (`Done` badge). */
  unreadFinished: string[];
}

export type HomeFilter = "all" | "online" | "offline";

export interface HomeItem {
  peer: PeerRecord;
  room: RoomInfo;
}

/** Same debounce the app uses before committing `working: false`. */
export const WORKING_OFF_DEBOUNCE_MS = 350;

/** Wire thinking levels → compact tile labels (also the set of valid levels). */
const THINKING_LABELS: Record<string, string> = {
  auto: "auto",
  off: "off",
  minimal: "min",
  low: "low",
  medium: "med",
  high: "high",
  xhigh: "xhigh",
  max: "max",
};

// ── epk + keys ───────────────────────────────────────────────────────────────

/** Relay epks are standard base64; QR payloads are url-safe. */
export function toStandardB64(s: string): string {
  let std = s.replace(/-/g, "+").replace(/_/g, "/");
  while (std.length % 4 !== 0) std += "=";
  return std;
}

export function roomKey(epk: string, roomId: string): string {
  return `${toStandardB64(epk)}:${roomId}`;
}

// ── wire parsing (app/lib/protocol/protocol.dart ControlInbound) ─────────────

function str(v: unknown): string | null {
  return typeof v === "string" ? v : null;
}

function bool(v: unknown): boolean | null {
  return typeof v === "boolean" ? v : null;
}

function num(v: unknown): number | null {
  return typeof v === "number" && Number.isFinite(v) ? Math.trunc(v) : null;
}

function thinkingLevel(v: unknown): string | null {
  return typeof v === "string" && Object.hasOwn(THINKING_LABELS, v) ? v : null;
}

function asObject(v: unknown): Record<string, unknown> | null {
  return v !== null && typeof v === "object" && !Array.isArray(v) ? (v as Record<string, unknown>) : null;
}

export function parseRoomInfo(v: unknown): RoomInfo | null {
  const j = asObject(v);
  if (!j) return null;
  const roomId = str(j.room_id);
  const startedAt = num(j.started_at);
  if (roomId === null || startedAt === null) return null;
  return {
    roomId,
    name: str(j.name),
    cwd: str(j.cwd),
    startedAt,
    model: str(j.model),
    thinking: thinkingLevel(j.thinking),
    working: bool(j.working) ?? false,
    goal: str(j.goal),
    loop: str(j.loop),
    plan: str(j.plan),
  };
}

/** Parses a relay control frame; `null` for unknown types or malformed frames. */
export function parseControlFrame(v: unknown): ControlFrame | null {
  const j = asObject(v);
  if (!j) return null;
  const peer = str(j.peer);
  switch (j.type) {
    case "peer_online":
      return peer === null ? null : { type: "peer_online", peer };
    case "peer_offline": {
      const sinceTs = num(j.since_ts);
      return peer === null || sinceTs === null ? null : { type: "peer_offline", peer, sinceTs };
    }
    case "presence": {
      if (!Array.isArray(j.states)) return null;
      const states: Array<{ peer: string; online: boolean; sinceTs: number | null }> = [];
      for (const raw of j.states) {
        const s = asObject(raw);
        const p = s ? str(s.peer) : null;
        const online = s ? bool(s.online) : null;
        if (!s || p === null || online === null) return null;
        states.push({ peer: p, online, sinceTs: num(s.since_ts) });
      }
      return { type: "presence", states };
    }
    case "room_announced": {
      const roomId = str(j.room_id);
      const startedAt = num(j.started_at);
      if (peer === null || roomId === null || startedAt === null) return null;
      // Thinking/working/goal/loop/plan arrive top-level (flattened relay) or
      // nested under `meta` (pre-flatten relay); read both.
      const meta = asObject(j.meta);
      return {
        type: "room_announced",
        peer,
        roomId,
        name: str(j.name),
        cwd: str(j.cwd),
        startedAt,
        model: str(j.model),
        thinking: thinkingLevel(str(j.thinking) ?? (meta ? str(meta.thinking) : null)),
        working: bool(j.working) ?? (meta ? bool(meta.working) : null),
        goal: str(j.goal) ?? (meta ? str(meta.goal) : null),
        loop: str(j.loop) ?? (meta ? str(meta.loop) : null),
        plan: str(j.plan) ?? (meta ? str(meta.plan) : null),
      };
    }
    case "room_ended": {
      const roomId = str(j.room_id);
      const sinceTs = num(j.since_ts);
      if (peer === null || roomId === null || sinceTs === null) return null;
      return { type: "room_ended", peer, roomId, sinceTs };
    }
    case "rooms": {
      if (peer === null || !Array.isArray(j.rooms)) return null;
      const rooms: RoomInfo[] = [];
      for (const raw of j.rooms) {
        const r = parseRoomInfo(raw);
        if (!r) return null;
        rooms.push(r);
      }
      return { type: "rooms", peer, rooms };
    }
    case "room_meta_updated": {
      const roomId = str(j.room_id);
      if (peer === null || roomId === null) return null;
      const meta = asObject(j.meta);
      const has = (k: string) => meta !== null && Object.prototype.hasOwnProperty.call(meta, k);
      return {
        type: "room_meta_updated",
        peer,
        roomId,
        model: meta ? str(meta.model) : null,
        thinking: meta ? thinkingLevel(meta.thinking) : null,
        working: meta ? bool(meta.working) : null,
        goal: meta ? str(meta.goal) : null,
        loop: meta ? str(meta.loop) : null,
        plan: meta ? str(meta.plan) : null,
        hasModel: has("model"),
        hasThinking: has("thinking"),
        hasGoal: has("goal"),
        hasLoop: has("loop"),
        hasPlan: has("plan"),
      };
    }
    default:
      return null;
  }
}

// ── state transitions (ConnectionManager._onControl) ────────────────────────

export function emptyRoomsState(roomsByPeer: Record<string, RoomInfo[]> = {}): RoomsState {
  return {
    roomsByPeer,
    liveRoomIds: {},
    liveRoomsKnown: false,
    presence: {},
    workingOff: {},
    unreadFinished: [],
  };
}

function sameRoom(a: RoomInfo, b: RoomInfo): boolean {
  return (
    a.roomId === b.roomId &&
    a.name === b.name &&
    a.cwd === b.cwd &&
    a.startedAt === b.startedAt &&
    a.model === b.model &&
    a.thinking === b.thinking &&
    a.working === b.working &&
    a.goal === b.goal &&
    a.loop === b.loop &&
    a.plan === b.plan
  );
}

function sameRoomList(a: RoomInfo[], b: RoomInfo[]): boolean {
  if (a === b) return true;
  if (a.length !== b.length) return false;
  const byId = new Map(b.map((r) => [r.roomId, r]));
  return a.every((r) => {
    const other = byId.get(r.roomId);
    return other !== undefined && sameRoom(r, other);
  });
}

function sameIdSet(a: string[], b: string[]): boolean {
  if (a.length !== b.length) return false;
  const set = new Set(b);
  return a.every((x) => set.has(x));
}

function withoutKey<T>(rec: Record<string, T>, key: string): Record<string, T> {
  const next = { ...rec };
  delete next[key];
  return next;
}

function setPresence(state: RoomsState, peer: string, next: PresenceState): RoomsState {
  const key = toStandardB64(peer);
  const prev = state.presence[key];
  if (prev && prev.online === next.online && prev.sinceTs === next.sinceTs) return state;
  return { ...state, presence: { ...state.presence, [key]: next } };
}

export interface ControlResult {
  state: RoomsState;
  /** Set when a working→idle debounce must start: fire `commitWorkingOff(key, token)` later. */
  scheduleWorkingOff: { key: string; token: number } | null;
}

let workingOffTokenSeq = 0;

/** Applies one relay control frame. Returns the same `state` object when nothing changed. */
export function applyControl(state: RoomsState, frame: ControlFrame): ControlResult {
  const unchanged: ControlResult = { state, scheduleWorkingOff: null };
  switch (frame.type) {
    case "peer_online":
      return { state: setPresence(state, frame.peer, { online: true, sinceTs: null }), scheduleWorkingOff: null };

    case "peer_offline":
      return {
        state: setPresence(state, frame.peer, { online: false, sinceTs: frame.sinceTs }),
        scheduleWorkingOff: null,
      };

    case "presence": {
      let next = state;
      for (const s of frame.states) {
        next = setPresence(next, s.peer, { online: s.online, sinceTs: s.sinceTs });
      }
      return { state: next, scheduleWorkingOff: null };
    }

    case "room_announced": {
      const key = toStandardB64(frame.peer);
      const list = state.roomsByPeer[key] ?? [];
      const existing = list.find((r) => r.roomId === frame.roomId);
      // Preserve the cached name (local rename wins) and every optional field
      // the announce omitted; model/cwd/startedAt always come from the wire.
      const next: RoomInfo = {
        roomId: frame.roomId,
        name: existing?.name ?? frame.name,
        cwd: frame.cwd,
        startedAt: frame.startedAt,
        model: frame.model,
        thinking: frame.thinking ?? existing?.thinking ?? null,
        working: frame.working ?? existing?.working ?? false,
        goal: frame.goal ?? existing?.goal ?? null,
        loop: frame.loop ?? existing?.loop ?? null,
        plan: frame.plan ?? existing?.plan ?? null,
      };
      const live = state.liveRoomIds[key] ?? [];
      const liveAlready = live.includes(frame.roomId);
      if (existing && sameRoom(existing, next) && liveAlready) return unchanged;
      return {
        state: {
          ...state,
          roomsByPeer: { ...state.roomsByPeer, [key]: [...list.filter((r) => r.roomId !== frame.roomId), next] },
          liveRoomIds: { ...state.liveRoomIds, [key]: liveAlready ? live : [...live, frame.roomId] },
          liveRoomsKnown: true,
        },
        scheduleWorkingOff: null,
      };
    }

    case "room_ended": {
      // Keep the room cached (tile turns grey); only leave the live set.
      const key = toStandardB64(frame.peer);
      const live = state.liveRoomIds[key];
      if (!live || !live.includes(frame.roomId)) return unchanged;
      const remaining = live.filter((id) => id !== frame.roomId);
      return {
        state: {
          ...state,
          liveRoomIds: remaining.length > 0 ? { ...state.liveRoomIds, [key]: remaining } : withoutKey(state.liveRoomIds, key),
        },
        scheduleWorkingOff: null,
      };
    }

    case "room_meta_updated": {
      const key = toStandardB64(frame.peer);
      const list = state.roomsByPeer[key];
      if (!list) return unchanged;
      const idx = list.findIndex((r) => r.roomId === frame.roomId);
      if (idx < 0) return unchanged;
      const current = list[idx];
      // Only fields present in `meta` change; an explicit null clears.
      const patched: RoomInfo = {
        ...current,
        model: frame.hasModel ? frame.model : current.model,
        thinking: frame.hasThinking ? frame.thinking : current.thinking,
        goal: frame.hasGoal ? frame.goal : current.goal,
        loop: frame.hasLoop ? frame.loop : current.loop,
        plan: frame.hasPlan ? frame.plan : current.plan,
      };
      const rk = `${key}:${frame.roomId}`;
      const replace = (room: RoomInfo): Record<string, RoomInfo[]> => {
        const nextList = [...list];
        nextList[idx] = room;
        return { ...state.roomsByPeer, [key]: nextList };
      };

      if (frame.working === true) {
        let next = state;
        if (rk in next.workingOff) next = { ...next, workingOff: withoutKey(next.workingOff, rk) };
        if (next.unreadFinished.includes(rk)) {
          next = { ...next, unreadFinished: next.unreadFinished.filter((k) => k !== rk) };
        }
        const working: RoomInfo = { ...patched, working: true };
        if (sameRoom(current, working)) return { state: next, scheduleWorkingOff: null };
        return { state: { ...next, roomsByPeer: replace(working) }, scheduleWorkingOff: null };
      }

      if (frame.working === false) {
        const anyField = frame.hasModel || frame.hasThinking || frame.hasGoal || frame.hasLoop || frame.hasPlan;
        let next = state;
        if (anyField && !sameRoom(current, patched)) next = { ...next, roomsByPeer: replace(patched) };
        if (current.working && !(rk in next.workingOff)) {
          const token = ++workingOffTokenSeq;
          return {
            state: { ...next, workingOff: { ...next.workingOff, [rk]: token } },
            scheduleWorkingOff: { key: rk, token },
          };
        }
        return { state: next, scheduleWorkingOff: null };
      }

      if (sameRoom(current, patched)) return unchanged;
      return { state: { ...state, roomsByPeer: replace(patched) }, scheduleWorkingOff: null };
    }

    case "rooms": {
      const key = toStandardB64(frame.peer);
      const existing = state.roomsByPeer[key] ?? [];
      const byId = new Map(existing.map((r) => [r.roomId, r]));
      let workingOff = state.workingOff;
      for (const r of frame.rooms) {
        const cached = byId.get(r.roomId);
        const rk = `${key}:${r.roomId}`;
        // A pending working→idle debounce keeps the room working until it fires.
        const effectiveWorking = rk in workingOff ? true : r.working;
        if (r.working && rk in workingOff) workingOff = withoutKey(workingOff, rk);
        byId.set(r.roomId, {
          roomId: r.roomId,
          name: cached?.name ?? r.name,
          cwd: r.cwd,
          startedAt: r.startedAt,
          model: r.model ?? cached?.model ?? null,
          thinking: r.thinking ?? cached?.thinking ?? null,
          working: effectiveWorking,
          goal: r.goal ?? cached?.goal ?? null,
          loop: r.loop ?? cached?.loop ?? null,
          plan: r.plan ?? cached?.plan ?? null,
        });
      }
      const newList = Array.from(byId.values());
      const newLive = Array.from(new Set(frame.rooms.map((r) => r.roomId)));
      const liveChanged = !sameIdSet(newLive, state.liveRoomIds[key] ?? []);
      const listChanged = !sameRoomList(newList, existing);
      const base: RoomsState =
        state.liveRoomsKnown && workingOff === state.workingOff
          ? state
          : { ...state, liveRoomsKnown: true, workingOff };
      if (!liveChanged && !listChanged) return { state: base, scheduleWorkingOff: null };
      return {
        state: {
          ...base,
          roomsByPeer: { ...state.roomsByPeer, [key]: newList },
          liveRoomIds: { ...state.liveRoomIds, [key]: newLive },
        },
        scheduleWorkingOff: null,
      };
    }
  }
}

/**
 * Fires when a working→idle debounce elapses. A token mismatch means the
 * debounce was cancelled (a newer `working: true`) or superseded.
 */
export function commitWorkingOff(
  state: RoomsState,
  key: string,
  token: number,
  activeKey: string | null,
): RoomsState {
  if (state.workingOff[key] !== token) return state;
  const next: RoomsState = { ...state, workingOff: withoutKey(state.workingOff, key) };
  const sep = key.lastIndexOf(":");
  const epk = key.slice(0, sep);
  const roomId = key.slice(sep + 1);
  const list = next.roomsByPeer[epk];
  const idx = list ? list.findIndex((r) => r.roomId === roomId) : -1;
  if (!list || idx < 0 || !list[idx].working) return next;
  const nextList = [...list];
  nextList[idx] = { ...list[idx], working: false };
  return {
    ...next,
    roomsByPeer: { ...next.roomsByPeer, [epk]: nextList },
    unreadFinished: key !== activeKey && !next.unreadFinished.includes(key) ? [...next.unreadFinished, key] : next.unreadFinished,
  };
}

export function markRoomViewed(state: RoomsState, epk: string, roomId: string): RoomsState {
  const key = roomKey(epk, roomId);
  if (!state.unreadFinished.includes(key)) return state;
  return { ...state, unreadFinished: state.unreadFinished.filter((k) => k !== key) };
}

/**
 * Relay switch / explicit reconnect: drop everything the old relay told us
 * (presence, live set, pending debounces) but keep cached rooms.
 */
export function clearLiveState(state: RoomsState): RoomsState {
  return { ...state, presence: {}, liveRoomIds: {}, liveRoomsKnown: false, workingOff: {} };
}

/** Removes every trace of a revoked pairing. */
export function forgetPeer(state: RoomsState, epk: string): RoomsState {
  const key = toStandardB64(epk);
  const prefix = `${key}:`;
  const workingOff: Record<string, number> = {};
  for (const [k, v] of Object.entries(state.workingOff)) if (!k.startsWith(prefix)) workingOff[k] = v;
  return {
    ...state,
    roomsByPeer: withoutKey(state.roomsByPeer, key),
    liveRoomIds: withoutKey(state.liveRoomIds, key),
    presence: withoutKey(state.presence, key),
    workingOff,
    unreadFinished: state.unreadFinished.filter((k) => !k.startsWith(prefix)),
  };
}

// ── queries (ConnectionManager.isRoom*) ──────────────────────────────────────

/** Last relay live-set membership, ignoring link status (Online filter). */
export function isRoomInLiveSet(state: RoomsState, epk: string, roomId: string): boolean {
  return state.liveRoomIds[toStandardB64(epk)]?.includes(roomId) ?? false;
}

/** Green dot: in the live set AND the relay link is up. */
export function isRoomLive(state: RoomsState, connected: boolean, epk: string, roomId: string): boolean {
  return connected && isRoomInLiveSet(state, epk, roomId);
}

export function isRoomWorking(state: RoomsState, connected: boolean, epk: string, roomId: string): boolean {
  if (!connected) return false;
  const key = toStandardB64(epk);
  if (`${key}:${roomId}` in state.workingOff) return true;
  return state.roomsByPeer[key]?.find((r) => r.roomId === roomId)?.working ?? false;
}

export function isRoomUnreadFinished(state: RoomsState, epk: string, roomId: string): boolean {
  return state.unreadFinished.includes(roomKey(epk, roomId));
}

// ── Home derivations (HomeList / HomeViewModel / SessionTile) ───────────────

function cwdTail(cwd: string | null): string | null {
  if (!cwd) return null;
  const segs = cwd.split("/").filter((s) => s.length > 0);
  return segs.length > 0 ? segs[segs.length - 1] : null;
}

/** Section header label: nickname → sessionName → epk prefix. */
export function peerLabel(peer: PeerRecord): string {
  if (peer.nickname) return peer.nickname;
  if (peer.sessionName) return peer.sessionName;
  return peer.remoteEpk.substring(0, 8);
}

/** Tile title: room name → cwd basename → peer nickname → session name. */
export function roomDisplayName(peer: PeerRecord, room: RoomInfo): string {
  return room.name || cwdTail(room.cwd) || peer.nickname || peer.sessionName;
}

/** Every (peer, room) pair, peers then rooms sorted case-insensitively by label. */
export function homeItems(peers: PeerRecord[], state: RoomsState): HomeItem[] {
  const sortedPeers = [...peers].sort((a, b) =>
    cmp(a.nickname || a.sessionName || a.remoteEpk, b.nickname || b.sessionName || b.remoteEpk),
  );
  const out: HomeItem[] = [];
  for (const peer of sortedPeers) {
    const rooms = state.roomsByPeer[toStandardB64(peer.remoteEpk)];
    if (!rooms || rooms.length === 0) continue;
    const label = (r: RoomInfo) => r.name || cwdTail(r.cwd) || r.roomId;
    for (const room of [...rooms].sort((a, b) => cmp(label(a), label(b)))) {
      out.push({ peer, room });
    }
  }
  return out;
}

function cmp(a: string, b: string): number {
  const x = a.toLowerCase();
  const y = b.toLowerCase();
  return x < y ? -1 : x > y ? 1 : 0;
}

/** Online tab membership: live-set member OR currently working. */
export function isItemOnline(state: RoomsState, connected: boolean, item: HomeItem): boolean {
  return (
    isRoomInLiveSet(state, item.peer.remoteEpk, item.room.roomId) ||
    isRoomWorking(state, connected, item.peer.remoteEpk, item.room.roomId)
  );
}

export function filterItems(items: HomeItem[], filter: HomeFilter, state: RoomsState, connected: boolean): HomeItem[] {
  if (filter === "all") return items;
  const wantOnline = filter === "online";
  return items.filter((it) => isItemOnline(state, connected, it) === wantOnline);
}

export function homeCounts(items: HomeItem[], state: RoomsState, connected: boolean) {
  const online = items.filter((it) => isItemOnline(state, connected, it)).length;
  return { all: items.length, online, offline: items.length - online };
}

/** Spinner instead of "No sessions online" until the relay reported rooms. */
export function onlineListPending(filter: HomeFilter, visibleCount: number, state: RoomsState): boolean {
  return filter === "online" && visibleCount === 0 && !state.liveRoomsKnown;
}

export type TileStatus = "working" | "done" | "online" | "reconnecting" | "offline";

/** Trailing indicator priority from the app's `_PresenceDot`. */
export function tileStatus(state: RoomsState, connected: boolean, item: HomeItem): TileStatus {
  const { remoteEpk } = item.peer;
  const { roomId } = item.room;
  if (isRoomWorking(state, connected, remoteEpk, roomId)) return "working";
  if (isRoomUnreadFinished(state, remoteEpk, roomId)) return "done";
  if (!connected) return "reconnecting";
  return isRoomLive(state, connected, remoteEpk, roomId) ? "online" : "offline";
}

const MODEL_BRANDS: Record<string, string> = {
  gpt: "GPT",
  claude: "Claude",
  gemini: "Gemini",
  qwen: "Qwen",
  deepseek: "DeepSeek",
  glm: "GLM",
  kimi: "Kimi",
  grok: "Grok",
  mistral: "Mistral",
  llama: "Llama",
  flash: "Flash",
  pro: "Pro",
  max: "Max",
  mini: "Mini",
  plus: "Plus",
  turbo: "Turbo",
  coder: "Coder",
  instruct: "Instruct",
  thinking: "Thinking",
};

/** `google/gemini-3.8-flash` → `Gemini 3.8 Flash` (app's `formatModelName`). */
export function formatModelName(raw: string): string {
  const trimmed = raw.trim();
  if (!trimmed) return trimmed;
  const namePart = trimmed.includes("/") ? trimmed.split("/").pop() ?? trimmed : trimmed;
  if (namePart.includes(" ") && /[A-Z]/.test(namePart)) return namePart;
  const tokens: string[] = [];
  for (const seg of namePart.split(/[-_]/)) {
    const m = /^([a-zA-Z]+)(\d.*)$/.exec(seg);
    if (m) tokens.push(m[1], m[2]);
    else tokens.push(seg);
  }
  return tokens
    .map((t) => {
      const lower = t.toLowerCase();
      if (MODEL_BRANDS[lower]) return MODEL_BRANDS[lower];
      if (/^\d+(\.\d+)?$/.test(t)) return t;
      if (/^v\d+/.test(lower)) return `V${t.substring(1)}`;
      return t ? `${t[0].toUpperCase()}${t.substring(1)}` : t;
    })
    .join(" ");
}

function truncate(name: string, max = 24): string {
  return name.length <= max ? name : `${name.substring(0, max - 3)}…`;
}

/** Subtitle: `model · thinking`, falling back to the pairing age. */
export function tileSubtitle(item: HomeItem, now: number = Date.now()): { text: string; accented: boolean } {
  const { room, peer } = item;
  const model = room.model ? formatModelName(room.model) : null;
  const thinking = room.thinking ? THINKING_LABELS[room.thinking] ?? room.thinking : null;
  if (model && thinking) return { text: `${truncate(model, 20)} · ${thinking}`, accented: true };
  if (model) return { text: truncate(model), accented: true };
  if (thinking) return { text: thinking, accented: true };
  return { text: `Last paired: ${relativeTime(peer.pairedAt, now)}`, accented: false };
}

export function relativeTime(iso: string, now: number = Date.now()): string {
  const t = Date.parse(iso);
  if (Number.isNaN(t)) return "—";
  const diff = Math.max(0, now - t);
  const min = Math.floor(diff / 60_000);
  if (min < 1) return "just now";
  if (min < 60) return `${min}m ago`;
  const h = Math.floor(min / 60);
  if (h < 24) return `${h}h ago`;
  const d = Math.floor(h / 24);
  if (d < 30) return `${d}d ago`;
  return new Date(t).toISOString().slice(0, 10);
}
