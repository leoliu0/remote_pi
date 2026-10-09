import { test } from "node:test";
import assert from "node:assert/strict";
import {
  argRows,
  bashCard,
  bashFooter,
  bashFooterLine,
  parseBashOutput,
  toolOutcome,
  toolSummary,
} from "./tool-output.ts";

test("toolOutcome: result, error and non-string payloads normalise to one text", () => {
  assert.deepEqual(toolOutcome("ok", undefined), { output: "ok", isError: false });
  assert.deepEqual(toolOutcome(undefined, "boom"), { output: "boom", isError: true });
  // An empty error string is still a failure (the extension sends `error: ""`).
  assert.deepEqual(toolOutcome(undefined, ""), { output: "", isError: true });
  assert.deepEqual(toolOutcome({ from: "a", message: "hi" }, undefined), {
    output: '{\n  "from": "a",\n  "message": "hi"\n}',
    isError: false,
  });
  assert.deepEqual(toolOutcome(undefined, undefined), { output: "", isError: false });
  assert.deepEqual(toolOutcome(null, null), { output: "", isError: false });
});

// Shared test vectors with the phone's bash card (same strings on both sides).
test("bash: command not found → body without status lines, red exit in footer", () => {
  const text = "error: command not found: flutter\n\n\nWall time: 0.00 seconds\n\nCommand exited with code 127";
  const card = bashCard({ command: "flutter test", timeout: 300 }, text);
  assert.equal(card.command, "flutter test");
  assert.equal(card.body, "error: command not found: flutter");
  assert.deepEqual(card.footer, { text: "Wall: 0.00s | Timeout: 300s", exit: "exit 127" });
  assert.equal(bashFooterLine(card.footer), "Wall: 0.00s | Timeout: 300s | exit 127");
});

test("bash: no output, no timeout → wall only", () => {
  const card = bashCard({ command: "sleep 15" }, "(no output)\n\nWall time: 15.67 seconds");
  assert.equal(card.body, "(no output)");
  assert.equal(bashFooterLine(card.footer), "Wall: 15.67s");
});

test("bash: empty body shows (no output); exit 0 is not shown", () => {
  const card = bashCard({ command: "true" }, "\nWall time: 0.5 seconds\n\nCommand exited with code 0\n");
  assert.equal(card.body, "(no output)");
  assert.equal(bashFooterLine(card.footer), "Wall: 0.50s");
  assert.equal(card.footer.exit, null);
});

test("bash: running state, intent, cwd and multi-line command", () => {
  const card = bashCard({ command: "cd x &&\n  make", i: " Building app ", cwd: "/repo", timeout: "60" }, null);
  assert.equal(card.command, "cd x &&\n  make");
  assert.equal(card.intent, "Building app");
  assert.equal(card.cwd, "/repo");
  assert.equal(card.body, null);
  assert.deepEqual(card.footer, { text: "Running…", exit: null });
});

test("parseBashOutput keeps the body intact and only strips trailing status lines", () => {
  const text = "line 1\nWall time: 9 seconds\nline 3\n\n\nWall time: 1.234 seconds";
  assert.deepEqual(parseBashOutput(text), {
    body: "line 1\nWall time: 9 seconds\nline 3",
    wallSeconds: 1.234,
    exitCode: null,
  });
  assert.deepEqual(parseBashOutput("plain"), { body: "plain", wallSeconds: null, exitCode: null });
  assert.deepEqual(parseBashOutput("x\r\nCommand exited with code 2\r\n"), { body: "x", wallSeconds: null, exitCode: 2 });
});

test("bashFooter: timeout only, exit without wall", () => {
  assert.equal(bashFooterLine(bashFooter({ body: "", wallSeconds: null, exitCode: null }, 30)), "Timeout: 30s");
  assert.equal(bashFooterLine(bashFooter({ body: "", wallSeconds: null, exitCode: 1 }, null)), "exit 1");
});

test("argRows: strings verbatim, nested values as JSON", () => {
  assert.deepEqual(argRows({ path: "a.ts", limit: 5, opts: { x: [1] }, on: true }), [
    { key: "path", value: "a.ts" },
    { key: "limit", value: "5" },
    { key: "opts", value: '{\n  "x": [\n    1\n  ]\n}' },
    { key: "on", value: "true" },
  ]);
  assert.deepEqual(argRows(null), []);
});

test("toolSummary: intent first, else command / main argument", () => {
  assert.equal(toolSummary({ command: "ls", i: "Listing files" }), "Listing files");
  assert.equal(toolSummary({ command: "ls -la" }), "ls -la");
  assert.equal(toolSummary({ path: "src/a.ts" }), "src/a.ts");
  assert.equal(toolSummary({ n: 1 }), '{"n":1}');
  assert.equal(toolSummary(undefined), "");
});
