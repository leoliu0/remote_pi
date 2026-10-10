import assert from "node:assert/strict";
import { describe, it } from "node:test";
import {
  applyControl,
  clearLiveState,
  commitWorkingOff,
  emptyRoomsState,
  filterItems,
  forgetPeer,
  formatModelName,
  homeCounts,
  homeItems,
  isRoomInLiveSet,
  isRoomLive,
  isRoomUnreadFinished,
  isRoomWorking,
  markRoomViewed,
  onlineListPending,
  parseControlFrame,
  peerLabel,
  roomDisplayName,
  roomKey,
  tileStatus,
  tileSubtitle,
  toStandardB64,
  type ControlFrame,
  type PeerRecord,
  type RoomInfo,
  type RoomsState,
} from "./session-list.ts";

const EPK_A = "vTZygijDajc/5j3QC55NXvDI+Hcigl5tG3QZjQV0wAc=";
const EPK_B = "qcy7AN3OQ6NHuHwQyZebY67WL0u9k6X2mYUhfy2WkHY=";

function peer(partial: Partial<PeerRecord> & Pick<PeerRecord, "remoteEpk">): PeerRecord {
  return {
    sessionName: "pi",
    relayUrl: "http://178.157.59.181",
    pairedAt: "2026-01-01T00:00:00.000Z",
    ...partial,
  };
}

function room(partial: Partial<RoomInfo> & Pick<RoomInfo, "roomId">): RoomInfo {
  return {
    name: null,
    cwd: null,
    startedAt: 1,
    model: null,
    thinking: null,
    working: false,
    goal: null,
    loop: null,
    plan: null,
    ...partial,
  };
}

/** Parses a wire frame exactly as the relay sends it, then applies it. */
function apply(state: RoomsState, wire: Record<string, unknown>) {
  const frame = parseControlFrame(wire);
  assert.ok(frame, `frame should parse: ${JSON.stringify(wire)}`);
  return applyControl(state, frame as ControlFrame);
}

function rooms(state: RoomsState, epk = EPK_A): RoomInfo[] {
  return state.roomsByPeer[toStandardB64(epk)] ?? [];
}

const snapshot = (epk: string, list: Array<Record<string, unknown>>) => ({ type: "rooms", peer: epk, rooms: list });

describe("parseControlFrame", () => {
  it("reads announce fields top-level or nested under meta", () => {
    const frame = parseControlFrame({
      type: "room_announced",
      peer: EPK_A,
      room_id: "r1",
      started_at: 5,
      meta: { thinking: "high", working: true },
    });
    assert.deepEqual(frame && frame.type === "room_announced" && [frame.thinking, frame.working], ["high", true]);
  });

  it("marks which meta keys were present (absent ≠ explicit null)", () => {
    const frame = parseControlFrame({ type: "room_meta_updated", peer: EPK_A, room_id: "r1", meta: { model: null } });
    assert.ok(frame && frame.type === "room_meta_updated");
    assert.equal(frame.hasModel, true);
    assert.equal(frame.model, null);
    assert.equal(frame.hasThinking, false);
    assert.equal(frame.working, null);
  });

  it("drops unknown thinking levels and malformed frames", () => {
    const frame = parseControlFrame(snapshot(EPK_A, [{ room_id: "r1", started_at: 1, thinking: "ultra" }]));
    assert.ok(frame && frame.type === "rooms");
    assert.equal(frame.rooms[0].thinking, null);
    assert.equal(parseControlFrame({ type: "rooms", peer: EPK_A }), null);
    assert.equal(parseControlFrame({ type: "room_ended", peer: EPK_A, room_id: "r1" }), null);
    assert.equal(parseControlFrame({ type: "something_new" }), null);
  });
});

describe("rooms snapshot", () => {
  it("replaces the live set but keeps rooms it omitted as cached/offline", () => {
    let s = apply(emptyRoomsState(), snapshot(EPK_A, [
      { room_id: "r1", started_at: 1, name: "papers" },
      { room_id: "r2", started_at: 2, name: "site" },
    ])).state;
    assert.equal(s.liveRoomsKnown, true);
    assert.deepEqual(rooms(s).map((r) => r.roomId), ["r1", "r2"]);

    s = apply(s, snapshot(EPK_A, [{ room_id: "r2", started_at: 2, name: "site" }])).state;
    assert.deepEqual(rooms(s).map((r) => r.roomId), ["r1", "r2"]);
    assert.equal(isRoomInLiveSet(s, EPK_A, "r1"), false);
    assert.equal(isRoomInLiveSet(s, EPK_A, "r2"), true);
  });

  it("an empty snapshot takes every room offline without deleting it", () => {
    let s = apply(emptyRoomsState(), snapshot(EPK_A, [{ room_id: "r1", started_at: 1 }])).state;
    s = apply(s, snapshot(EPK_A, [])).state;
    assert.equal(rooms(s).length, 1);
    assert.equal(isRoomInLiveSet(s, EPK_A, "r1"), false);
  });

  it("keeps the cached name and fills omitted model/thinking from cache", () => {
    let s = emptyRoomsState({
      [EPK_A]: [room({ roomId: "r1", name: "renamed", model: "gpt-5", thinking: "high", goal: "g" })],
    });
    s = apply(s, snapshot(EPK_A, [{ room_id: "r1", started_at: 9, name: "wire-name", cwd: "/w" }])).state;
    const r = rooms(s)[0];
    assert.equal(r.name, "renamed");
    assert.equal(r.model, "gpt-5");
    assert.equal(r.thinking, "high");
    assert.equal(r.goal, "g");
    assert.equal(r.cwd, "/w");
    assert.equal(r.startedAt, 9);
  });

  it("returns the same state object for an identical re-emit", () => {
    const s = apply(emptyRoomsState(), snapshot(EPK_A, [{ room_id: "r1", started_at: 1 }])).state;
    assert.equal(apply(s, snapshot(EPK_A, [{ room_id: "r1", started_at: 1 }])).state, s);
  });

  it("normalises url-safe epks to the relay's standard base64", () => {
    const urlSafe = EPK_A.replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
    const s = apply(emptyRoomsState(), snapshot(EPK_A, [{ room_id: "r1", started_at: 1 }])).state;
    assert.equal(isRoomInLiveSet(s, urlSafe, "r1"), true);
  });
});

describe("room_announced", () => {
  it("adds the room to the canonical list and the live set", () => {
    const s = apply(emptyRoomsState(), {
      type: "room_announced", peer: EPK_A, room_id: "r1", started_at: 1, name: "papers", model: "claude-opus",
    }).state;
    assert.equal(rooms(s)[0].name, "papers");
    assert.equal(isRoomInLiveSet(s, EPK_A, "r1"), true);
    assert.equal(s.liveRoomsKnown, true);
  });

  it("preserves cached name/thinking/working when the announce omits them, but takes model as sent", () => {
    let s = emptyRoomsState({
      [EPK_A]: [room({ roomId: "r1", name: "mine", thinking: "low", working: true, model: "old-model" })],
    });
    s = apply(s, { type: "room_announced", peer: EPK_A, room_id: "r1", started_at: 3, name: "wire" }).state;
    const r = rooms(s)[0];
    assert.equal(r.name, "mine");
    assert.equal(r.thinking, "low");
    assert.equal(r.working, true);
    assert.equal(r.model, null);
  });

  it("is a no-op when the room is already live and unchanged", () => {
    const wire = { type: "room_announced", peer: EPK_A, room_id: "r1", started_at: 1, name: "a" };
    const s = apply(emptyRoomsState(), wire).state;
    assert.equal(apply(s, wire).state, s);
  });

  it("re-announcing a cached offline room brings it back online", () => {
    let s = apply(emptyRoomsState(), snapshot(EPK_A, [{ room_id: "r1", started_at: 1 }])).state;
    s = apply(s, { type: "room_ended", peer: EPK_A, room_id: "r1", since_ts: 2 }).state;
    s = apply(s, { type: "room_announced", peer: EPK_A, room_id: "r1", started_at: 1 }).state;
    assert.equal(isRoomInLiveSet(s, EPK_A, "r1"), true);
  });
});

describe("room_ended and presence", () => {
  it("room_ended leaves the live set but keeps the tile", () => {
    let s = apply(emptyRoomsState(), snapshot(EPK_A, [{ room_id: "r1", started_at: 1 }])).state;
    s = apply(s, { type: "room_ended", peer: EPK_A, room_id: "r1", since_ts: 2 }).state;
    assert.equal(rooms(s).length, 1);
    assert.equal(isRoomInLiveSet(s, EPK_A, "r1"), false);
    assert.equal(s.liveRoomIds[EPK_A], undefined);
  });

  it("peer_offline only records presence; rooms leave via room_ended / snapshot", () => {
    let s = apply(emptyRoomsState(), snapshot(EPK_A, [{ room_id: "r1", started_at: 1 }])).state;
    s = apply(s, { type: "peer_offline", peer: EPK_A, since_ts: 7 }).state;
    assert.deepEqual(s.presence[EPK_A], { online: false, sinceTs: 7 });
    assert.equal(isRoomInLiveSet(s, EPK_A, "r1"), true);
    s = apply(s, { type: "peer_online", peer: EPK_A }).state;
    assert.deepEqual(s.presence[EPK_A], { online: true, sinceTs: null });
  });

  it("presence snapshots update every listed peer and dedupe repeats", () => {
    const wire = { type: "presence", states: [{ peer: EPK_A, online: true }, { peer: EPK_B, online: false, since_ts: 3 }] };
    const s = apply(emptyRoomsState(), wire).state;
    assert.deepEqual(s.presence[EPK_B], { online: false, sinceTs: 3 });
    assert.equal(apply(s, wire).state, s);
  });

  it("clearLiveState (relay switch) drops live set + presence, keeps cached rooms", () => {
    let s = apply(emptyRoomsState(), snapshot(EPK_A, [{ room_id: "r1", started_at: 1 }])).state;
    s = apply(s, { type: "peer_online", peer: EPK_A }).state;
    s = clearLiveState(s);
    assert.equal(rooms(s).length, 1);
    assert.equal(isRoomInLiveSet(s, EPK_A, "r1"), false);
    assert.equal(s.liveRoomsKnown, false);
    assert.deepEqual(s.presence, {});
  });

  it("live/working answers are gated on the relay link, live-set membership is not", () => {
    const s = apply(emptyRoomsState(), snapshot(EPK_A, [{ room_id: "r1", started_at: 1, working: true }])).state;
    assert.equal(isRoomLive(s, true, EPK_A, "r1"), true);
    assert.equal(isRoomLive(s, false, EPK_A, "r1"), false);
    assert.equal(isRoomWorking(s, false, EPK_A, "r1"), false);
    assert.equal(isRoomInLiveSet(s, EPK_A, "r1"), true);
  });
});

describe("room_meta_updated", () => {
  const base = () =>
    apply(emptyRoomsState(), snapshot(EPK_A, [{ room_id: "r1", started_at: 1, model: "gpt-5", thinking: "high" }])).state;

  it("only patches fields present in meta; explicit null clears", () => {
    let s = apply(base(), { type: "room_meta_updated", peer: EPK_A, room_id: "r1", meta: { thinking: "low" } }).state;
    assert.equal(rooms(s)[0].model, "gpt-5");
    assert.equal(rooms(s)[0].thinking, "low");
    s = apply(s, { type: "room_meta_updated", peer: EPK_A, room_id: "r1", meta: { model: null } }).state;
    assert.equal(rooms(s)[0].model, null);
    assert.equal(rooms(s)[0].thinking, "low");
  });

  it("ignores rooms it has never seen", () => {
    const s = base();
    assert.equal(apply(s, { type: "room_meta_updated", peer: EPK_A, room_id: "zz", meta: { working: true } }).state, s);
    assert.equal(apply(s, { type: "room_meta_updated", peer: EPK_B, room_id: "r1", meta: { working: true } }).state, s);
  });

  it("working:true flips immediately; working:false is debounced then marks Done", () => {
    let s = apply(base(), { type: "room_meta_updated", peer: EPK_A, room_id: "r1", meta: { working: true } }).state;
    assert.equal(isRoomWorking(s, true, EPK_A, "r1"), true);

    const off = apply(s, { type: "room_meta_updated", peer: EPK_A, room_id: "r1", meta: { working: false } });
    assert.ok(off.scheduleWorkingOff);
    s = off.state;
    // Still working until the debounce fires.
    assert.equal(isRoomWorking(s, true, EPK_A, "r1"), true);

    s = commitWorkingOff(s, off.scheduleWorkingOff.key, off.scheduleWorkingOff.token, null);
    assert.equal(isRoomWorking(s, true, EPK_A, "r1"), false);
    assert.equal(isRoomUnreadFinished(s, EPK_A, "r1"), true);

    s = markRoomViewed(s, EPK_A, "r1");
    assert.equal(isRoomUnreadFinished(s, EPK_A, "r1"), false);
  });

  it("no Done badge for the room the user has open", () => {
    let s = apply(base(), { type: "room_meta_updated", peer: EPK_A, room_id: "r1", meta: { working: true } }).state;
    const off = apply(s, { type: "room_meta_updated", peer: EPK_A, room_id: "r1", meta: { working: false } });
    assert.ok(off.scheduleWorkingOff);
    s = commitWorkingOff(off.state, off.scheduleWorkingOff.key, off.scheduleWorkingOff.token, roomKey(EPK_A, "r1"));
    assert.equal(isRoomUnreadFinished(s, EPK_A, "r1"), false);
  });

  it("a new working:true cancels the pending debounce", () => {
    let s = apply(base(), { type: "room_meta_updated", peer: EPK_A, room_id: "r1", meta: { working: true } }).state;
    const off = apply(s, { type: "room_meta_updated", peer: EPK_A, room_id: "r1", meta: { working: false } });
    assert.ok(off.scheduleWorkingOff);
    s = apply(off.state, { type: "room_meta_updated", peer: EPK_A, room_id: "r1", meta: { working: true } }).state;
    s = commitWorkingOff(s, off.scheduleWorkingOff.key, off.scheduleWorkingOff.token, null);
    assert.equal(isRoomWorking(s, true, EPK_A, "r1"), true);
    assert.equal(isRoomUnreadFinished(s, EPK_A, "r1"), false);
  });

  it("a snapshot during the debounce keeps the room working", () => {
    let s = apply(base(), { type: "room_meta_updated", peer: EPK_A, room_id: "r1", meta: { working: true } }).state;
    const off = apply(s, { type: "room_meta_updated", peer: EPK_A, room_id: "r1", meta: { working: false } });
    s = apply(off.state, snapshot(EPK_A, [{ room_id: "r1", started_at: 1, working: false }])).state;
    assert.equal(rooms(s)[0].working, true);
  });

  it("working:false on an idle room schedules nothing", () => {
    const off = apply(base(), { type: "room_meta_updated", peer: EPK_A, room_id: "r1", meta: { working: false } });
    assert.equal(off.scheduleWorkingOff, null);
  });
});

describe("Home derivations", () => {
  const peers = [
    peer({ remoteEpk: EPK_B, nickname: "uts" }),
    peer({ remoteEpk: EPK_A, nickname: "x3d" }),
  ];
  const state = () => {
    let s = emptyRoomsState({ [EPK_B]: [room({ roomId: "old", name: "archive" })] });
    s = apply(s, snapshot(EPK_A, [
      { room_id: "r2", started_at: 1, cwd: "/home/leo/site" },
      { room_id: "r1", started_at: 1, name: "Papers", model: "google/gemini-3.8-flash", thinking: "medium" },
    ])).state;
    return s;
  };

  it("groups by PC (sorted by label) with rooms sorted by label", () => {
    const items = homeItems(peers, state());
    assert.deepEqual(
      items.map((it) => `${peerLabel(it.peer)}/${roomDisplayName(it.peer, it.room)}`),
      ["uts/archive", "x3d/Papers", "x3d/site"],
    );
  });

  it("skips rooms of PCs that are not paired", () => {
    const items = homeItems([peers[0]], state());
    assert.deepEqual(items.map((it) => it.room.roomId), ["old"]);
  });

  it("counts and filters by live-set membership", () => {
    const s = state();
    const items = homeItems(peers, s);
    assert.deepEqual(homeCounts(items, s, true), { all: 3, online: 2, offline: 1 });
    assert.deepEqual(filterItems(items, "offline", s, true).map((it) => it.room.roomId), ["old"]);
    // A dropped relay link must not empty the Online tab.
    assert.deepEqual(homeCounts(items, s, false), { all: 3, online: 2, offline: 1 });
  });

  it("shows a spinner on Online until the first rooms frame arrives", () => {
    assert.equal(onlineListPending("online", 0, emptyRoomsState()), true);
    assert.equal(onlineListPending("online", 0, state()), false);
    assert.equal(onlineListPending("all", 0, emptyRoomsState()), false);
  });

  it("tile status priority: working > Done > reconnecting > online/offline", () => {
    let s = state();
    const items = homeItems(peers, s);
    const papers = items[1];
    assert.equal(tileStatus(s, true, papers), "online");
    assert.equal(tileStatus(s, false, papers), "reconnecting");
    assert.equal(tileStatus(s, true, items[0]), "offline");
    s = apply(s, { type: "room_meta_updated", peer: EPK_A, room_id: "r1", meta: { working: true } }).state;
    assert.equal(tileStatus(s, true, papers), "working");
    const off = apply(s, { type: "room_meta_updated", peer: EPK_A, room_id: "r1", meta: { working: false } });
    assert.ok(off.scheduleWorkingOff);
    s = commitWorkingOff(off.state, off.scheduleWorkingOff.key, off.scheduleWorkingOff.token, null);
    assert.equal(tileStatus(s, true, papers), "done");
  });

  it("subtitle shows model · thinking, else the pairing age", () => {
    const items = homeItems(peers, state());
    assert.deepEqual(tileSubtitle(items[1]), { text: "Gemini 3.8 Flash · med", accented: true });
    assert.equal(tileSubtitle(items[2], Date.parse("2026-01-03T00:00:00.000Z")).text, "Last paired: 2d ago");
  });

  it("formats model ids like the app", () => {
    assert.equal(formatModelName("qwen3.8-flash"), "Qwen 3.8 Flash");
    assert.equal(formatModelName("anthropic/claude-opus-4-7"), "Claude Opus 4 7");
    assert.equal(formatModelName("Gemini 3.8 Flash"), "Gemini 3.8 Flash");
  });

  it("labels registry names like the omp footer (drops a leading \"Claude \")", () => {
    // room_meta.model as pi-extension sends it (captured from omp v18.8.7);
    // the terminal footer shows "Opus 5.5 · auto" for this session.
    assert.equal(formatModelName("Claude Opus 5.5"), "Opus 5.5");
    assert.equal(formatModelName("Claude Sonnet 5.5"), "Sonnet 5.5");
    const items = homeItems(peers, state());
    const tile = { ...items[1], room: { ...items[1].room, model: "Claude Opus 5.5", thinking: "auto" } };
    assert.deepEqual(tileSubtitle(tile), { text: "Opus 5.5 · auto", accented: true });
  });

  it("forgetPeer removes a revoked PC everywhere", () => {
    const s = forgetPeer(state(), EPK_A);
    assert.equal(s.roomsByPeer[EPK_A], undefined);
    assert.equal(s.liveRoomIds[EPK_A], undefined);
    assert.equal(rooms(s, EPK_B).length, 1);
  });
});
