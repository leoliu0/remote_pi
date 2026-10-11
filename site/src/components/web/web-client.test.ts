import { test } from "node:test";
import assert from "node:assert/strict";
import {
  RemotePiRelayClient,
  buildRoomCommand,
  parseModelsList,
  requestRoomAction,
  thinkingChoices,
  type PairedSession,
  type WireSkill,
} from "./web-client.ts";
import type { PeerPresence } from "./web-client.ts";
import type { PlanState } from "./plan-state.ts";
import type { TodoPhase } from "./todo.ts";
import { EMPTY_CHAT, applyChatEvent, chatEventFromFrame } from "./chat-stream.ts";
import type { InnerFrame, RelayConnection } from "./relay-connection.ts";

const SESSION: PairedSession = {
  id: "s1",
  name: "pc",
  device: "pc",
  remoteEpk: "AAAA",
  relayUrl: "wss://relay.invalid",
  roomId: "room-1",
  pairedAt: "2026-10-10",
};

function fakeConnection(sent: InnerFrame[]): RelayConnection {
  const fake = {
    currentStatus: "online",
    onInner: () => () => {},
    onStatus: () => () => {},
    sendInner: (_peer: string, _room: string, inner: InnerFrame) => {
      sent.push(inner);
      return true;
    },
  };
  return fake as unknown as RelayConnection;
}

test("a local send uses one id for the optimistic bubble and the user_message frame", () => {
  const sent: InnerFrame[] = [];
  const client = new RemotePiRelayClient(fakeConnection(sent), SESSION);
  // The clock moves on every read: two separate Date.now() ids would differ.
  const realNow = Date.now;
  let t = 1791600000000;
  Date.now = () => t++;
  let optimistic;
  try {
    optimistic = client.sendMessage("hello");
  } finally {
    Date.now = realNow;
  }
  const frame = sent.find((f) => f.type === "user_message");
  assert.ok(frame, "user_message frame sent");
  assert.equal(optimistic?.id, frame.id);
  assert.deepEqual(
    { role: optimistic?.role, text: optimistic?.text, status: optimistic?.status },
    { role: "user", text: "hello", status: "sending" }
  );

  // The Pi echoes `user_input` with that id: it confirms the bubble in place.
  let chat = applyChatEvent(EMPTY_CHAT, { type: "user", message: optimistic! }, 1);
  const echo = chatEventFromFrame({ type: "user_input", id: frame.id, text: "hello" }, 2);
  chat = applyChatEvent(chat, echo!, 2);
  assert.deepEqual(
    chat.messages.map((m) => [m.role, m.text, m.status]),
    [["user", "hello", "sent"]]
  );
});

/** A connection whose inbound frames the test pushes, scoped to SESSION's room. */
function liveConnection(sent: InnerFrame[], online = true) {
  const listeners = new Set<(peer: string, room: string, inner: InnerFrame) => void>();
  const conn = {
    currentStatus: online ? "online" : "offline",
    onInner: (fn: (peer: string, room: string, inner: InnerFrame) => void) => {
      listeners.add(fn);
      return () => listeners.delete(fn);
    },
    onStatus: () => () => {},
    sendInner: (_peer: string, _room: string, inner: InnerFrame) => {
      if (!online) return false;
      sent.push(inner);
      return true;
    },
  };
  const push = (inner: InnerFrame, room = SESSION.roomId) => [...listeners].forEach((fn) => fn(SESSION.remoteEpk, room, inner));
  return { conn: conn as unknown as RelayConnection, push, listeners };
}

test("presence follows the frames that start and stop a turn, as in the app", () => {
  const { conn, push } = liveConnection([]);
  const client = new RemotePiRelayClient(conn, SESSION);
  const seen: PeerPresence[] = [];
  client.connect({ onPresenceChange: (p) => seen.push(p) });
  // index.ts:741 echo of a prompt → working; index.ts:2771 steer echo → no change.
  push({ type: "user_message", id: "app_1", text: "go" });
  push({ type: "user_message", id: "steer_1", text: "also this", streaming_behavior: "steer" });
  // index.ts:3074 error, index.ts:5747 cancelled → idle; index.ts:1982 bye → offline.
  push({ type: "error", in_reply_to: "app_1", code: "provider_error", message: "boom" });
  push({ type: "user_input", id: "t_2", text: "again" });
  push({ type: "cancelled", in_reply_to: "can_1", target_id: "t_2" });
  push({ type: "bye", reason: "peer_stop" });
  assert.deepEqual(seen, ["working", "online", "working", "online", "offline"]);
  client.disconnect();
});

// index.ts:6119-6123 — sent after every session_sync reply.
test("skills_list reaches the chat for the slash menu", () => {
  const { conn, push } = liveConnection([]);
  const client = new RemotePiRelayClient(conn, SESSION);
  let skills: WireSkill[] | null = null;
  client.connect({ onSkills: (s) => (skills = s) });
  push({ type: "skills_list", in_reply_to: "sync_1", skills: [{ name: "pdf", description: "Read PDFs" }, { name: "" }] });
  assert.deepEqual(skills, [{ name: "pdf", description: "Read PDFs" }]);
  client.disconnect();
});

test("model_set sends the picked provider and id as-is (model ids may contain '/')", () => {
  const frame = buildRoomCommand({ action: "set_model", provider: "openrouter", modelId: "anthropic/claude-opus-4.7" });
  assert.equal(frame.type, "model_set");
  assert.equal(frame.provider, "openrouter");
  assert.equal(frame.model_id, "anthropic/claude-opus-4.7");
  // Two actions in one millisecond still get distinct ids (replies match by id).
  assert.notEqual(buildRoomCommand({ action: "compact" }).id, buildRoomCommand({ action: "compact" }).id);
});

// actions/handlers.ts:653-658 — the Pi's real catalogue.
test("list_models resolves with the models_list reply for this room only", async () => {
  const sent: InnerFrame[] = [];
  const { conn, push, listeners } = liveConnection(sent);
  const pending = requestRoomAction(conn, SESSION.remoteEpk, SESSION.roomId, { action: "list_models" });
  const req = sent[0];
  assert.equal(req.type, "list_models");
  const opus = { id: "claude-opus-4-7", name: "Claude Opus 4.7", provider: "anthropic", reasoning: true, context_window: 200000, vision: true, thinking_levels: ["off", "low", "high"] };
  // Another room's reply with the same id is ignored.
  push({ type: "models_list", in_reply_to: req.id, models: [], current: undefined }, "other-room");
  push({ type: "models_list", in_reply_to: req.id, models: [opus], current: opus });
  const catalogue = parseModelsList(await pending);
  assert.deepEqual(catalogue, { models: [opus], current: opus });
  assert.deepEqual(thinkingChoices(catalogue!.current), ["off", "low", "high"]);
  assert.equal(thinkingChoices(null).length, 8);
  assert.equal(listeners.size, 0, "unsubscribed after the reply");
});

// actions/handlers.ts:302 / index.ts:5980 — action_error carries the failure text.
test("action_error rejects with the Pi's error instead of being dropped", async () => {
  const sent: InnerFrame[] = [];
  const { conn, push } = liveConnection(sent);
  const pending = requestRoomAction(conn, SESSION.remoteEpk, SESSION.roomId, { action: "set_model", provider: "google", modelId: "nope" });
  push({ type: "action_ok", in_reply_to: "someone-else", action: "model_set" });
  push({ type: "action_error", in_reply_to: sent[0].id, action: "model_set", error: "Unknown model google/nope" });
  await assert.rejects(pending, /Unknown model google\/nope/);
});

test("an action on a dead link or with no reply fails visibly", async () => {
  const offline = liveConnection([], false);
  await assert.rejects(requestRoomAction(offline.conn, SESSION.remoteEpk, SESSION.roomId, { action: "compact" }), /Not connected/);
  const silent = liveConnection([]);
  await assert.rejects(requestRoomAction(silent.conn, SESSION.remoteEpk, SESSION.roomId, { action: "compact" }, 5), /timeout/);
  assert.equal(silent.listeners.size, 0);
});

// local://plan-capture.md — `plan_mode` actions and their replies.
test("plan_mode enter/exit/review send the typed action and resolve on its action_ok", async () => {
  const sent: InnerFrame[] = [];
  const { conn, push, listeners } = liveConnection(sent);
  for (const mode of ["enter", "exit", "review"] as const) {
    const pending = requestRoomAction(conn, SESSION.remoteEpk, SESSION.roomId, { action: "plan_mode", mode });
    const req = sent.at(-1)!;
    assert.deepEqual(req, { type: "plan_mode", id: req.id, action: mode });
    push({ type: "action_ok", in_reply_to: req.id, action: "plan_mode" });
    assert.equal((await pending).action, "plan_mode");
  }
  assert.equal(listeners.size, 0);
  const failing = requestRoomAction(conn, SESSION.remoteEpk, SESSION.roomId, { action: "plan_mode", mode: "review" });
  push({ type: "action_error", in_reply_to: sent.at(-1)!.id, action: "plan_mode", error: "No plan to review" });
  await assert.rejects(failing, /No plan to review/);
});

test("plan_state frames reach the chat for this room only", () => {
  const { conn, push } = liveConnection([]);
  const client = new RemotePiRelayClient(conn, SESSION);
  const seen: PlanState[] = [];
  client.connect({ onPlanState: (s) => seen.push(s) });
  push({ type: "plan_state", status: "review", plan_file_path: "local://hello-txt-plan.md", title: "hello-txt" });
  push({ type: "plan_state", status: "active" }, "other-room");
  push({ type: "plan_state", status: "bogus" });
  push({ type: "plan_state", status: "idle" });
  assert.deepEqual(seen, [
    { status: "review", planFilePath: "local://hello-txt-plan.md", title: "hello-txt" },
    { status: "idle", planFilePath: null, title: null },
  ]);
  client.disconnect();
});

test("todo_state frames reach the chat for this room only; [] clears", () => {
  const { conn, push } = liveConnection([]);
  const client = new RemotePiRelayClient(conn, SESSION);
  const seen: TodoPhase[][] = [];
  client.connect({ onTodoState: (p) => seen.push(p) });
  push({ type: "todo_state", ts: 1, phases: [{ name: "Setup", tasks: [{ content: "Create repo", status: "in_progress" }] }] });
  push({ type: "todo_state", ts: 2, phases: [{ name: "Other", tasks: [{ content: "x", status: "pending" }] }] }, "other-room");
  push({ type: "todo_state", ts: 3, phases: [] });
  assert.deepEqual(seen, [[{ name: "Setup", tasks: [{ content: "Create repo", status: "in_progress" }] }], []]);
  client.disconnect();
});
