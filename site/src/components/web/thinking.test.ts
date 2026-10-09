import { test } from "node:test";
import assert from "node:assert/strict";
import { splitThinking, stripThinking } from "./thinking.ts";

test("splits closed thinking sections in order", () => {
  assert.deepEqual(splitThinking("<think>\nplan the fix\nstep two\n</think>\n\nHere is the fix."), [
    { kind: "thinking", text: "plan the fix\nstep two", open: false },
    { kind: "text", text: "Here is the fix." },
  ]);
  assert.deepEqual(splitThinking("A<THINK>x</Think>B<think>y</think>"), [
    { kind: "text", text: "A" },
    { kind: "thinking", text: "x", open: false },
    { kind: "text", text: "B" },
    { kind: "thinking", text: "y", open: false },
  ]);
});

test("unterminated <think> while streaming is an open section", () => {
  assert.deepEqual(splitThinking("<think>\nstill reasoning about"), [
    { kind: "thinking", text: "still reasoning about", open: true },
  ]);
  // Just the opener so far: an empty open section (renders "Thinking…").
  assert.deepEqual(splitThinking("<think>"), [{ kind: "thinking", text: "", open: true }]);
  assert.equal(stripThinking("Answer.\n\n<think>more"), "Answer.");
});

test("plain text, empty closed sections and stray closing tags", () => {
  assert.deepEqual(splitThinking("no traces here"), [{ kind: "text", text: "no traces here" }]);
  assert.deepEqual(splitThinking("<think>  </think>done"), [{ kind: "text", text: "done" }]);
  assert.deepEqual(splitThinking("tail of a trace</think>\n\nreal answer"), [{ kind: "text", text: "tail of a trace\n\nreal answer" }]);
  assert.deepEqual(splitThinking(""), []);
});

test("stripThinking keeps only the answer text", () => {
  assert.equal(stripThinking("<think>a</think>\n\nOne.\n<think>b</think>\nTwo."), "One.\n\nTwo.");
  assert.equal(stripThinking("<think>only thinking</think>"), "");
});
