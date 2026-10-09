import { test } from "node:test";
import assert from "node:assert/strict";
import { workingLabel } from "./working-label.ts";
import type { WebChatMessage } from "./web-client.ts";

const user = (text: string): WebChatMessage => ({ id: `u-${text}`, role: "user", text, timestamp: 0 });
const tool = (name: string, args: Record<string, unknown>): WebChatMessage => ({
  id: `t-${name}`, role: "tool", text: "", timestamp: 0,
  tool: { id: name, tool: name, args, status: "pending" },
});

test("shows the tool intent the terminal shows", () => {
  assert.equal(
    workingLabel([user("go"), tool("wait", { i: "  Waiting for sleep completion " })]),
    "Waiting for sleep completion",
  );
});

test("falls back to the phone's per-tool labels", () => {
  assert.equal(workingLabel([user("go"), tool("bash", { command: "sleep   60" })]), "Running: sleep 60");
  assert.equal(workingLabel([user("go"), tool("read", { path: "a/b.ts" })]), "Reading a/b.ts");
  assert.equal(workingLabel([user("go"), tool("grep", {})]), "Searching files…");
  assert.equal(workingLabel([user("go"), tool("lsp", {})]), "Executing lsp…");
  assert.equal(
    workingLabel([user("go"), tool("bash", { command: "x".repeat(50) })]),
    `Running: ${"x".repeat(35)}…`,
  );
});

test("latest tool of the current turn wins; earlier turns never leak", () => {
  assert.equal(
    workingLabel([user("1"), tool("read", { i: "old" }), user("2"), tool("bash", { i: "new" })]),
    "new",
  );
  assert.equal(workingLabel([user("1"), tool("read", { i: "old" }), user("2")]), "Working…");
  assert.equal(workingLabel([]), "Working…");
});
