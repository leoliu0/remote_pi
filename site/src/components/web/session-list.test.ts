import assert from "node:assert/strict";
import { describe, it } from "node:test";
import type { PairedSession } from "./web-client.ts";
import {
  applyPeerRooms,
  homeListMode,
  mergeRemoteSessions,
  shouldIgnoreEmptyRoomsSnapshot,
  upsertLiveRoom,
} from "./session-list.ts";

function session(partial: Partial<PairedSession> & Pick<PairedSession, "id" | "roomId">): PairedSession {
  return {
    name: partial.name ?? partial.roomId,
    device: partial.device ?? "x3d",
    remoteEpk: partial.remoteEpk ?? "epk_a",
    relayUrl: partial.relayUrl ?? "wss://relay.example",
    pairedAt: partial.pairedAt ?? "2026-01-01T00:00:00.000Z",
    status: partial.status ?? "online",
    isLive: partial.isLive ?? true,
    ...partial,
  };
}

describe("homeListMode", () => {
  it("shows loading instead of empty while the first snapshot is in flight", () => {
    assert.equal(homeListMode(true, 0), "loading");
  });

  it("keeps the list visible during a background refresh", () => {
    assert.equal(homeListMode(true, 3), "list");
  });

  it("shows empty only after a finished fetch with nothing visible", () => {
    assert.equal(homeListMode(false, 0), "empty");
  });
});

describe("mergeRemoteSessions", () => {
  const live = session({ id: "a_r1", roomId: "r1", name: "papers", isLive: true, status: "online" });

  it("does not wipe a populated list when an incomplete poll returns nothing", () => {
    const prev = [live];
    const next = mergeRemoteSessions({
      prev,
      remote: [],
      stored: [],
      roomsComplete: false,
    });
    assert.equal(next, prev);
    assert.equal(next[0].roomId, "r1");
  });

  it("overlays live rooms onto prev when the snapshot is incomplete", () => {
    const prev = [live];
    const extra = session({
      id: "a_r2",
      roomId: "r2",
      name: "home",
      isLive: true,
      status: "working",
    });
    const next = mergeRemoteSessions({
      prev,
      remote: [extra],
      stored: [],
      roomsComplete: false,
    });
    assert.deepEqual(
      next.map((s) => s.roomId),
      ["r2", "r1"],
    );
  });

  it("lets a complete empty snapshot drop live rooms", () => {
    const next = mergeRemoteSessions({
      prev: [live],
      remote: [],
      stored: [],
      roomsComplete: true,
    });
    assert.equal(next.length, 0);
  });

  it("keeps stored sessions that the relay snapshot omitted", () => {
    const stored = session({
      id: "stored_r9",
      roomId: "r9",
      name: "cached",
      isLive: false,
      status: "offline",
    });
    const next = mergeRemoteSessions({
      prev: [],
      remote: [live],
      stored: [stored],
      roomsComplete: true,
    });
    assert.deepEqual(
      next.map((s) => s.roomId),
      ["r1", "r9"],
    );
  });
});

describe("shouldIgnoreEmptyRoomsSnapshot", () => {
  it("ignores an empty rooms frame while that peer still has live sessions", () => {
    const prev = [session({ id: "a_r1", roomId: "r1", remoteEpk: "epk_a", isLive: true, status: "online" })];
    assert.equal(shouldIgnoreEmptyRoomsSnapshot(prev, "epk_a", []), true);
  });

  it("applies an empty rooms frame when that peer has no live sessions", () => {
    const prev = [
      session({ id: "a_r1", roomId: "r1", remoteEpk: "epk_a", isLive: false, status: "offline" }),
    ];
    assert.equal(shouldIgnoreEmptyRoomsSnapshot(prev, "epk_a", []), false);
  });
});

describe("applyPeerRooms", () => {
  it("marks missing rooms offline and adds new live rooms", () => {
    const prev = [
      session({ id: "a_r1", roomId: "r1", remoteEpk: "epk_a", name: "old" }),
      session({ id: "b_x", roomId: "x", remoteEpk: "epk_b", name: "other" }),
    ];
    const next = applyPeerRooms(prev, "epk_a", [{ room_id: "r2", name: "new", working: true }], "x3d");
    const a = next.filter((s) => s.remoteEpk === "epk_a");
    const r1 = a.find((s) => s.roomId === "r1")!;
    const r2 = a.find((s) => s.roomId === "r2")!;
    assert.equal(r1.isLive, false);
    assert.equal(r1.status, "offline");
    assert.equal(r2.isLive, true);
    assert.equal(r2.status, "working");
    assert.equal(next.find((s) => s.roomId === "x")?.remoteEpk, "epk_b");
  });
});

describe("upsertLiveRoom", () => {
  it("inserts a newly announced room without offlining others", () => {
    const prev = [session({ id: "a_r1", roomId: "r1", remoteEpk: "epk_a" })];
    const next = upsertLiveRoom(prev, "epk_a", { room_id: "r2", name: "home" }, "x3d");
    assert.equal(next.length, 2);
    assert.equal(next.find((s) => s.roomId === "r1")?.isLive, true);
    assert.equal(next.find((s) => s.roomId === "r2")?.name, "home");
  });
});
