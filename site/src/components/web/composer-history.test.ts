import { test } from "node:test";
import assert from "node:assert/strict";
import {
  HISTORY_IDLE,
  buildComposerHistory,
  historyHint,
  historyKey,
  recallNewer,
  recallOlder,
  type HistoryNav,
} from "./composer-history.ts";

const HISTORY = ["first", "second", "third"];

/** Presses a key with the caret at the end of `text` (where a recall leaves it). */
function press(key: string, text: string, nav: HistoryNav, history = HISTORY) {
  return historyKey(key, { text, selectionStart: text.length, selectionEnd: text.length }, history, nav);
}

test("repeated Up walks back through every message and stops at the oldest", () => {
  let nav = HISTORY_IDLE;
  let text = "";
  const seen: string[] = [];
  for (let i = 0; i < 5; i++) {
    const r = press("ArrowUp", text, nav);
    assert.ok(r, `Up #${i + 1} must be handled`);
    ({ nav, text } = r);
    seen.push(text);
  }
  assert.deepEqual(seen, ["third", "second", "first", "first", "first"]);
  assert.equal(nav.index, 2);
  assert.deepEqual(historyHint(HISTORY, nav), { label: "History 3/3", canGoOlder: false, newerLabel: "Newer" });
});

test("Down walks forward and restores the saved draft past the newest", () => {
  let nav = HISTORY_IDLE;
  let text = "half-typed draft";
  for (let i = 0; i < 3; i++) ({ nav, text } = press("ArrowUp", text, nav)!);
  assert.equal(text, "first");
  assert.equal(nav.savedDraft, "half-typed draft");

  const seen: string[] = [];
  for (let i = 0; i < 3; i++) {
    const r = press("ArrowDown", text, nav);
    assert.ok(r, `Down #${i + 1} must be handled`);
    ({ nav, text } = r);
    seen.push(text);
  }
  assert.deepEqual(seen, ["second", "third", "half-typed draft"]);
  assert.deepEqual(nav, HISTORY_IDLE);
  // Out of history mode, Down is the textarea's again.
  assert.equal(press("ArrowDown", text, nav), null);
});

test("hint labels the Down step Clear on the newest entry", () => {
  const { nav } = recallOlder(HISTORY, HISTORY_IDLE, "")!;
  assert.deepEqual(historyHint(HISTORY, nav), { label: "History 1/3", canGoOlder: true, newerLabel: "Clear" });
  assert.equal(historyHint(HISTORY, HISTORY_IDLE), null);
});

test("typing leaves history mode: the next Up saves the edit and starts from the newest", () => {
  const { nav } = press("ArrowUp", "", HISTORY_IDLE)!;
  // web-chat resets nav to HISTORY_IDLE on any edit that isn't a recall.
  assert.equal(nav.index, 0);
  const typed = "third, edited";
  assert.equal(press("ArrowDown", typed, HISTORY_IDLE), null);
  const r = press("ArrowUp", typed, HISTORY_IDLE)!;
  assert.equal(r.text, "third");
  assert.equal(r.nav.savedDraft, typed);
});

test("history trims, drops blanks and collapses consecutive duplicates", () => {
  assert.deepEqual(
    buildComposerHistory(["  ls  ", "ls", "", "   ", "pwd", "ls", "ls"], []),
    ["ls", "pwd", "ls"],
  );
});

test("earlier chat messages are history with nothing sent from this tab (reload)", () => {
  const history = buildComposerHistory(["one", "two", "three"], []);
  assert.deepEqual(history, ["one", "two", "three"]);
  let nav = HISTORY_IDLE;
  let text = "";
  const seen: string[] = [];
  for (let i = 0; i < 3; i++) {
    ({ nav, text } = press("ArrowUp", text, nav, history)!);
    seen.push(text);
  }
  assert.deepEqual(seen, ["three", "two", "one"]);
});

test("local sends already in the chat count once; undelivered queued texts go last", () => {
  // "two" was sent (optimistically in the chat); "queued" is still waiting.
  assert.deepEqual(buildComposerHistory(["one", "two"], ["two", "queued"]), ["one", "two", "queued"]);
  // Sent twice, both in the chat: still two entries, not four.
  assert.deepEqual(buildComposerHistory(["a", "b", "a", "b"], ["a", "b"]), ["a", "b", "a", "b"]);
});

test("Up with the caret below the first line moves the caret instead of recalling", () => {
  const text = "line one\nline two";
  const onSecond = { text, selectionStart: text.length, selectionEnd: text.length };
  assert.equal(historyKey("ArrowUp", onSecond, HISTORY, HISTORY_IDLE), null);
  const onFirst = { text, selectionStart: 3, selectionEnd: 3 };
  assert.equal(historyKey("ArrowUp", onFirst, HISTORY, HISTORY_IDLE)?.text, "third");
});

test("Down with the caret above the last line moves the caret while browsing", () => {
  const history = ["older", "line one\nline two"];
  const { nav, text } = press("ArrowUp", "", HISTORY_IDLE, history)!;
  const onFirst = { text, selectionStart: 2, selectionEnd: 2 };
  assert.equal(historyKey("ArrowDown", onFirst, history, nav), null);
  assert.equal(historyKey("ArrowDown", { text, selectionStart: text.length, selectionEnd: text.length }, history, nav)?.text, "");
});

test("nothing to recall: Up and Down fall through to the textarea", () => {
  assert.equal(press("ArrowUp", "", HISTORY_IDLE, []), null);
  assert.equal(recallNewer([], HISTORY_IDLE), null);
});
