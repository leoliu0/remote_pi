import { test } from "node:test";
import assert from "node:assert/strict";
import {
  STICK_DISTANCE_PX,
  keyScrollsUp,
  pickAnchor,
  restoredScrollTop,
  stickAfterScroll,
  stickAfterUpIntent,
  touchScrollsUp,
  unreadRows,
  wheelScrollsUp,
} from "./scroll-follow.ts";
import type { WebChatMessage } from "./web-client.ts";

// A 600 px viewport over 5000 px of chat: the bottom is scrollTop 4400.
const at = (scrollTop: number, scrollHeight = 5000) => ({ scrollTop, scrollHeight, clientHeight: 600 });

test("scrolling up one wheel notch unsets stick, even while still near the bottom", () => {
  assert.equal(stickAfterScroll(true, 4400, at(4300)), false);
  // Inside the old 120 px follow zone, but the user moved up.
  assert.equal(stickAfterScroll(true, 4400, at(4340)), false);
  // A small trackpad step, well inside the bottom zone.
  assert.equal(stickAfterScroll(true, 4400, at(4397)), false);
});

test("reaching the bottom sets stick again", () => {
  assert.equal(stickAfterScroll(false, 4000, at(4400)), true);
  assert.equal(stickAfterScroll(false, 4000, at(4400 - STICK_DISTANCE_PX)), true);
  assert.equal(stickAfterScroll(false, 4000, at(4400 - STICK_DISTANCE_PX - 1)), false);
});

test("scrolling down while away from the bottom keeps the reader unstuck", () => {
  assert.equal(stickAfterScroll(false, 3000, at(3500)), false);
});

test("programmatic growth keeps stick: pins only move down, content grows below", () => {
  // Content grew by 300 px before the pin: no scroll event, still stuck; the pin moves down.
  assert.equal(stickAfterScroll(true, 4400, at(4700, 5300)), true);
  // A pin that lands short of the new bottom (more content arrived since) still only moved down.
  assert.equal(stickAfterScroll(true, 4400, at(4600, 5400)), true);
  // A shorter resync clamps scrollTop down, but to the bottom.
  assert.equal(stickAfterScroll(true, 4400, at(4000, 4600)), true);
});

test("wheel-up, touch-drag-down and upward keys are an upward intent", () => {
  assert.equal(wheelScrollsUp(-100), true);
  assert.equal(wheelScrollsUp(100), false);
  assert.equal(wheelScrollsUp(0), false);
  // The finger moving down scrolls the content up.
  assert.equal(touchScrollsUp(200, 230), true);
  assert.equal(touchScrollsUp(230, 200), false);
  for (const key of ["PageUp", "Home", "ArrowUp"]) assert.equal(keyScrollsUp(key, false), true, key);
  assert.equal(keyScrollsUp(" ", true), true);
  assert.equal(keyScrollsUp(" ", false), false);
  assert.equal(keyScrollsUp("PageDown", false), false);
  assert.equal(keyScrollsUp("End", false), false);
});

test("an upward intent unsets stick only when the list can scroll up", () => {
  assert.equal(stickAfterUpIntent(true, at(4400)), false);
  assert.equal(stickAfterUpIntent(true, at(0)), true);
  assert.equal(stickAfterUpIntent(false, at(0)), false);
  // Everything fits: nothing to read above, keep following.
  assert.equal(stickAfterUpIntent(true, { scrollTop: 0, scrollHeight: 400, clientHeight: 600 }), true);
});

const msg = (id: string, role: WebChatMessage["role"], text = ""): WebChatMessage => ({ id, role, text, timestamp: 0 });

test("unread counts new user, assistant and error rows, not chunk deltas or tools", () => {
  const before = [msg("u1", "user"), msg("a1", "assistant", "hi")];
  // A chunk delta grows the open row in place.
  assert.equal(unreadRows(before, [msg("u1", "user"), msg("a1", "assistant", "hi there")]), 0);
  // The first chunk of a new segment is a new row.
  assert.equal(unreadRows(before, [...before, msg("stream-x-1", "assistant", "n")]), 1);
  assert.equal(unreadRows(before, [...before, msg("tool-1", "tool")]), 0);
  assert.equal(unreadRows(before, [...before, msg("err-1", "assistant", "⚠ x: y"), msg("u2", "user")]), 2);
  assert.equal(unreadRows(before, [...before, msg("comp-1", "compaction")]), 0);
  assert.equal(unreadRows(before, before), 0);
});

const rows = [
  { id: "r1", top: -900, bottom: -300 },
  { id: "r2", top: -284, bottom: 120 },
  { id: "r3", top: 136, bottom: 700 },
];

test("the anchor is the first row still on screen", () => {
  assert.deepEqual(pickAnchor(rows, 1500), { id: "r2", offset: -284, fromBottom: 1500 });
  assert.deepEqual(pickAnchor([{ id: "r1", top: -900, bottom: -300 }], 80), { id: null, offset: 0, fromBottom: 80 });
  assert.deepEqual(pickAnchor([], 0), { id: null, offset: 0, fromBottom: 0 });
});

test("a resync keeps the anchor row where it was", () => {
  const anchor = { id: "r2", offset: -284, fromBottom: 1500 };
  // Rows above were trimmed: the anchor now sits 700 px higher.
  assert.equal(restoredScrollTop(anchor, -984, at(3000, 4300)), 2300);
  // Nothing moved.
  assert.equal(restoredScrollTop(anchor, -284, at(3000)), 3000);
});

test("a resync without the anchor row keeps the distance from the bottom", () => {
  const anchor = { id: "gone", offset: 0, fromBottom: 1500 };
  assert.equal(restoredScrollTop(anchor, null, at(3000, 5200)), 3100);
  assert.equal(restoredScrollTop(anchor, null, at(0, 1000)), 0);
});
