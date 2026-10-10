import { test } from "node:test";
import assert from "node:assert/strict";
import { EMPTY_CHAT, applyChatEvent, cancelTargetId, chatEventFromFrame, historyMessages, type ChatEvent, type ChatState } from "./chat-stream.ts";
import type { WebChatMessage } from "./web-client.ts";

const TURN = "cli_1791600000000";
const chunk = (delta: string, inReplyTo = TURN) => ({ type: "agent_chunk", in_reply_to: inReplyTo, delta });
const toolRequest = (id: string, tool: string, args: Record<string, unknown>) => ({ type: "tool_request", tool_call_id: id, tool, args });
const toolResult = (id: string, result: string) => ({ type: "tool_result", tool_call_id: id, result });

// One turn as pi-extension streams it to every client (index.ts message_update /
// _handleToolStart / _maybeFinalizeTurn): thinking + text, a tool, text, an
// async bash, thinking closed at a tool boundary, the answer, then agent_done
// and the final agent_message.
const TURN_FRAMES: Record<string, unknown>[] = [
  { type: "user_input", id: TURN, text: "Run the checks" },
  chunk("<think>"),
  chunk("Need to list files."),
  chunk("</think>"),
  chunk("\n\n"),
  chunk("Plan: list the files,"),
  chunk(" then finish."),
  toolRequest("toolu_1", "bash", { command: "ls" }),
  toolResult("toolu_1", "a.ts\nb.ts"),
  chunk("Only `bg_5` is still running"),
  chunk("; starting the sleep in the background."),
  toolRequest("toolu_2", "bash", { command: "sleep 20", async: true }),
  toolResult("toolu_2", "Started background job bg_5"),
  chunk("<think>"),
  chunk("Wait for bg_5."),
  chunk("</think>"),
  toolRequest("toolu_3", "wait", { ids: ["bg_5"] }),
  toolResult("toolu_3", "bg_5 completed"),
  chunk("Done: bg_5 finished"),
  chunk(" cleanly."),
  { type: "agent_done", in_reply_to: TURN },
  { type: "agent_message", in_reply_to: TURN, text: "Done: bg_5 finished cleanly." },
];

// The same turn as `session_sync` replays it after a reload.
const TURN_HISTORY = [
  { ts: 1, type: "user_input", id: TURN, text: "Run the checks" },
  { ts: 2, type: "agent_message", in_reply_to: TURN, text: "<think>Need to list files.</think>\n\nPlan: list the files, then finish." },
  { ts: 3, type: "tool_request", tool_call_id: "toolu_1", tool: "bash", args: { command: "ls" } },
  { ts: 4, type: "tool_result", tool_call_id: "toolu_1", result: "a.ts\nb.ts" },
  { ts: 5, type: "agent_message", in_reply_to: TURN, text: "Only `bg_5` is still running; starting the sleep in the background." },
  { ts: 6, type: "tool_request", tool_call_id: "toolu_2", tool: "bash", args: { command: "sleep 20", async: true } },
  { ts: 7, type: "tool_result", tool_call_id: "toolu_2", result: "Started background job bg_5" },
  { ts: 8, type: "agent_message", in_reply_to: TURN, text: "<think>Wait for bg_5.</think>" },
  { ts: 9, type: "tool_request", tool_call_id: "toolu_3", tool: "wait", args: { ids: ["bg_5"] } },
  { ts: 10, type: "tool_result", tool_call_id: "toolu_3", result: "bg_5 completed" },
  { ts: 11, type: "agent_message", in_reply_to: TURN, text: "Done: bg_5 finished cleanly." },
];

function replay(frames: Record<string, unknown>[], start: ChatState = EMPTY_CHAT): ChatState {
  return frames.reduce((state, frame, i) => {
    const event = chatEventFromFrame(frame, 1000 + i);
    return event ? applyChatEvent(state, event, 1000 + i) : state;
  }, start);
}

function apply(state: ChatState, ...events: ChatEvent[]): ChatState {
  return events.reduce((s, e, i) => applyChatEvent(s, e, 5000 + i), state);
}

/** What the timeline shows: role + text (tool id for tools), ids ignored. */
function shown(messages: WebChatMessage[]): string[] {
  return messages.map((m) => (m.role === "tool" ? `tool:${m.tool?.id}:${m.tool?.status}` : `${m.role}:${m.text}`));
}

test("tool_request closes the streamed segment: text, tool, text interleave in order", () => {
  const { messages } = replay(TURN_FRAMES);
  assert.deepEqual(shown(messages), [
    "user:Run the checks",
    "assistant:<think>Need to list files.</think>\n\nPlan: list the files, then finish.",
    "tool:toolu_1:done",
    "assistant:Only `bg_5` is still running; starting the sleep in the background.",
    "tool:toolu_2:done",
    "assistant:<think>Wait for bg_5.</think>",
    "tool:toolu_3:done",
    "assistant:Done: bg_5 finished cleanly.",
  ]);
  assert.equal(messages.some((m) => m.isStreaming), false, "agent_done closes the last segment");
});

test("the final agent_message never adds a second copy of the answer", () => {
  const { messages } = replay(TURN_FRAMES);
  const answers = messages.filter((m) => m.role === "assistant" && m.text.includes("Done: bg_5 finished cleanly."));
  assert.equal(answers.length, 1);
  assert.equal(messages.at(-1)?.text, "Done: bg_5 finished cleanly.");
});

test("no text is glued across a tool boundary", () => {
  const { messages } = replay(TURN_FRAMES);
  for (const m of messages.filter((x) => x.role === "assistant")) {
    assert.doesNotMatch(m.text, /finish\.Only|background\.Done|<\/think>Done/);
  }
});

test("live rendering matches the session_sync history of the same turn", () => {
  const live = replay(TURN_FRAMES).messages;
  const history = historyMessages(TURN_HISTORY, 0);
  assert.deepEqual(shown(live), shown(history));
});

test("an open thinking block streamed at a tool boundary stays its own segment", () => {
  const { messages } = replay([
    { type: "user_input", id: TURN, text: "go" },
    chunk("<think>"),
    chunk("Check the tree first."),
    // pi-extension closes the dangling wrapper right before the tool_request.
    chunk("</think>"),
    toolRequest("toolu_1", "read", { path: "." }),
    // While the tool runs, nothing streams: the thinking segment is closed.
    chunk("<think>Tree is small.</think>\n\nOne file."),
    { type: "agent_done", in_reply_to: TURN },
    { type: "agent_message", in_reply_to: TURN, text: "One file." },
  ]);
  assert.deepEqual(shown(messages), [
    "user:go",
    "assistant:<think>Check the tree first.</think>",
    "tool:toolu_1:pending",
    "assistant:<think>Tree is small.</think>\n\nOne file.",
  ]);
});

test("a single streamed answer is not repeated by agent_message", () => {
  const { messages } = replay([
    { type: "user_input", id: TURN, text: "hi" },
    chunk("Hello"),
    chunk(" there."),
    { type: "agent_done", in_reply_to: TURN },
    { type: "agent_message", in_reply_to: TURN, text: "Hello there." },
  ]);
  assert.deepEqual(shown(messages), ["user:hi", "assistant:Hello there."]);
});

test("a cut-off streamed copy is completed in place, keeping its thinking", () => {
  const { messages } = replay([
    { type: "user_input", id: TURN, text: "why" },
    toolRequest("toolu_1", "read", { path: "README.md" }),
    toolResult("toolu_1", "…"),
    chunk("<think>Summarize.</think>\n\n"),
    chunk("It reads the config from its"),
    { type: "agent_done", in_reply_to: TURN },
    { type: "agent_message", in_reply_to: TURN, text: "It reads the config from its home directory." },
  ]);
  assert.deepEqual(shown(messages), [
    "user:why",
    "tool:toolu_1:done",
    "assistant:<think>Summarize.</think>\n\nIt reads the config from its home directory.",
  ]);
});

test("a steer splits the segment; the next turn starts a fresh one", () => {
  const SECOND = "cli_1791600009999";
  let state = replay([
    { type: "user_input", id: TURN, text: "fix a" },
    chunk("Fixing a first."),
  ]);
  // Local steer while streaming (web-chat's optimistic send).
  state = apply(state, { type: "user", message: { id: "cli_steer", role: "user", text: "also b", timestamp: 1, status: "sending" } });
  state = replay(
    [
      { type: "user_input", id: "cli_steer", text: "also b" },
      chunk("Now b too."),
      toolRequest("toolu_1", "edit", { path: "b.ts" }),
      toolResult("toolu_1", "ok"),
      chunk("Both fixed."),
      { type: "agent_done", in_reply_to: TURN },
      { type: "agent_message", in_reply_to: TURN, text: "Both fixed." },
      { type: "user_input", id: SECOND, text: "thanks" },
      chunk("You're welcome.", SECOND),
      { type: "agent_done", in_reply_to: SECOND },
      { type: "agent_message", in_reply_to: SECOND, text: "You're welcome." },
    ],
    state
  );
  assert.deepEqual(shown(state.messages), [
    "user:fix a",
    "assistant:Fixing a first.",
    "user:also b",
    "assistant:Now b too.",
    "tool:toolu_1:done",
    "assistant:Both fixed.",
    "user:thanks",
    "assistant:You're welcome.",
  ]);
  assert.equal(state.messages.find((m) => m.id === "cli_steer")?.status, "sent", "echo confirms the optimistic row in place");
});

// Captured live 2026-10-10 from the scratch omp room (pi-extension
// _echoUserMessage): the Pi echoes a client's prompt back as `user_message`,
// not `user_input`. The web ignored it, so its own bubble stayed ⏳ and prompts
// sent from the phone never appeared live. The app treats both types alike
// (protocol.dart: 'user_input' || 'user_message' => UserInput).
const LIVE_ECHO = {
  type: "user_message",
  id: "cli_1791597415713",
  text: "Spawn exactly ONE subagent with the task tool, named SleepCheck. Its assignment: run `sleep 25` in bash, then reply 'slept'. Wait for it, then answer 'done' in one word.",
};

test("a user_message echo confirms this tab's optimistic bubble in place", () => {
  let state = apply(EMPTY_CHAT, {
    type: "user",
    message: { id: LIVE_ECHO.id, role: "user", text: LIVE_ECHO.text, timestamp: 1, status: "sending" },
  });
  state = replay([LIVE_ECHO, { type: "agent_done", in_reply_to: LIVE_ECHO.id }, { type: "agent_message", in_reply_to: LIVE_ECHO.id, text: "done" }], state);
  assert.deepEqual(shown(state.messages), [`user:${LIVE_ECHO.text}`, "assistant:done"]);
  assert.equal(state.messages[0].status, "sent");
});

test("a user_message echo of another device's prompt adds its user row", () => {
  const state = replay([LIVE_ECHO, chunk("done", LIVE_ECHO.id), { type: "agent_done", in_reply_to: LIVE_ECHO.id }]);
  assert.deepEqual(shown(state.messages), [`user:${LIVE_ECHO.text}`, "assistant:done"]);
  assert.equal(state.messages[0].id, LIVE_ECHO.id);
  assert.equal(state.messages[0].status, "sent");
});

test("a turn's chunks never land in the previous turn's bubble", () => {
  const SECOND = "cli_1791600009999";
  const { messages } = replay([
    chunk("First answer."),
    // No agent_done for the first turn reached this tab.
    chunk("Second answer.", SECOND),
    { type: "agent_done", in_reply_to: SECOND },
  ]);
  assert.deepEqual(shown(messages), ["assistant:First answer.", "assistant:Second answer."]);
});

test("final text with nothing streamed (reload mid-turn) is added once", () => {
  let state = replay([{ type: "session_history", events: TURN_HISTORY.slice(0, 4) }]);
  state = replay(
    [
      { type: "agent_done", in_reply_to: TURN },
      { type: "agent_message", in_reply_to: TURN, text: "All done." },
    ],
    state
  );
  assert.deepEqual(shown(state.messages).slice(-2), ["tool:toolu_1:done", "assistant:All done."]);
  // A resync that already holds the answer, then a late duplicate frame.
  state = replay([{ type: "session_history", events: TURN_HISTORY }], state);
  state = replay([{ type: "agent_message", in_reply_to: TURN, text: "Done: bg_5 finished cleanly." }], state);
  assert.deepEqual(shown(state.messages), shown(historyMessages(TURN_HISTORY, 0)));
});

// ── frames the app shows that the web used to drop ─────────────────────────

// pi-extension index.ts:3073-3076 (provider error mid-turn).
test("an error frame stops the turn and shows `⚠ code: message`, as the app does", () => {
  const state = replay([
    { type: "user_input", id: TURN, text: "Run the checks" },
    chunk("Partial"),
    { type: "error", in_reply_to: TURN, code: "provider_error", message: "rate limited" },
  ]);
  assert.deepEqual(shown(state.messages), ["user:Run the checks", "assistant:Partial", "assistant:⚠ provider_error: rate limited"]);
  assert.equal(state.messages[1].isStreaming, false);
  assert.equal(state.cursor.openId, null);
  // index.ts:2495-2499 — no in_reply_to; still visible.
  const unpaired = replay([{ type: "error", code: "unknown_peer", message: "Peer not paired — re-scan QR" }]);
  assert.deepEqual(shown(unpaired.messages), ["assistant:⚠ unknown_peer: Peer not paired — re-scan QR"]);
});

// index.ts:5747 — `cancelled` echoes the cancel's target_id.
test("cancelled closes the stream and drops only an unconfirmed bubble for its target", () => {
  const pending: WebChatMessage = { id: "cli_9", role: "user", text: "never echoed", timestamp: 1, status: "sending" };
  let state = replay([{ type: "user_input", id: TURN, text: "Run the checks" }, chunk("Working on it")]);
  state = apply(state, { type: "user", message: pending });
  state = replay([{ type: "cancelled", in_reply_to: "can_1", target_id: "cli_9" }], state);
  assert.deepEqual(shown(state.messages), ["user:Run the checks", "assistant:Working on it"]);
  assert.equal(state.messages[1].isStreaming, false);
  // A confirmed prompt stays: cancel is stop-generation, not delete-history.
  state = replay([{ type: "cancelled", in_reply_to: "can_2", target_id: TURN }], state);
  assert.deepEqual(shown(state.messages), ["user:Run the checks", "assistant:Working on it"]);
});

// index.ts:1982 — the Pi says goodbye mid-turn.
test("bye stops the open segment streaming", () => {
  const state = replay([chunk("Half an answer"), { type: "bye", reason: "shutdown" }]);
  assert.equal(state.messages[0].isStreaming, false);
  assert.equal(state.cursor.openId, null);
});

// index.ts:741-746 (live echo) and index.ts:6538-6546 (history) carry `images: WireImage[]`.
test("user images from the echo and from history reach the bubble", () => {
  const images = [{ data: "iVBORw0KGgo=", mime: "image/png" }];
  const live = replay([{ type: "user_message", id: "app_1", text: "what is this?", images }]);
  assert.deepEqual(live.messages[0].image, { data: "iVBORw0KGgo=", mime: "image/png" });
  const hist = historyMessages([{ ts: 1, type: "user_input", id: "app_1", text: "", images }], 0);
  assert.deepEqual(hist[0].image, { data: "iVBORw0KGgo=", mime: "image/png" });
  // Text-only frames carry no `images` key and get no image.
  assert.equal(replay([{ type: "user_input", id: "t", text: "hi" }]).messages[0].image, undefined);
});

test("an echo without images keeps the image of the bubble it confirms", () => {
  const image = { data: "iVBORw0KGgo=", mime: "image/png" };
  let state = apply(EMPTY_CHAT, { type: "user", message: { id: "app_1", role: "user", text: "x", timestamp: 1, status: "sending", image } });
  state = replay([{ type: "user_message", id: "app_1", text: "x" }], state);
  assert.deepEqual(state.messages[0].image, image);
  assert.equal(state.messages[0].status, "sent");
});

// index.ts:6653-6655 — a result whose request fell outside the history window.
test("a tool_result without its request still shows, as an unknown tool", () => {
  const hist = historyMessages([{ ts: 1, type: "tool_result", tool_call_id: "toolu_0", result: "ok" }], 0);
  assert.deepEqual(shown(hist), ["tool:toolu_0:done"]);
  assert.equal(hist[0].tool?.tool, "unknown");
  const live = replay([chunk("text"), toolResult("toolu_x", "late")]);
  assert.deepEqual(shown(live.messages), ["assistant:text", "tool:toolu_x:done"]);
  assert.equal(live.cursor.openId, null);
});

test("a history resync keeps sends the Pi has not recorded yet", () => {
  let state = apply(EMPTY_CHAT, { type: "user", message: { id: "cli_5", role: "user", text: "still sending", timestamp: 1, status: "sending" } });
  state = replay([{ type: "session_history", events: TURN_HISTORY.slice(0, 2) }], state);
  assert.deepEqual(shown(state.messages).slice(-1), ["user:still sending"]);
  // Once history holds it (same text), the pending copy is not kept twice.
  state = replay(
    [{ type: "session_history", events: [...TURN_HISTORY.slice(0, 2), { ts: 3, type: "user_input", id: "pi_7", text: "still sending" }] }],
    state
  );
  assert.deepEqual(shown(state.messages).filter((s) => s === "user:still sending"), ["user:still sending"]);
});

test("Stop targets the running turn even before any text streamed (app cancelTargetId)", () => {
  const state = replay([{ type: "user_input", id: TURN, text: "Run the checks" }, toolRequest("toolu_1", "bash", { command: "ls" })]);
  assert.equal(cancelTargetId(state, true), TURN);
  assert.equal(cancelTargetId(EMPTY_CHAT, true), "working");
  assert.equal(cancelTargetId(state, false), null);
});
