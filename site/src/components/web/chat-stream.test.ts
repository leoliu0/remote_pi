import { test } from "node:test";
import assert from "node:assert/strict";
import { EMPTY_CHAT, applyChatEvent, chatEventFromFrame, historyMessages, type ChatEvent, type ChatState } from "./chat-stream.ts";
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
