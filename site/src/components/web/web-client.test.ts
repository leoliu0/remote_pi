import { test } from "node:test";
import assert from "node:assert/strict";
import { RemotePiRelayClient, type PairedSession } from "./web-client.ts";
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
