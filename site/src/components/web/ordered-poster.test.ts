import { test } from "node:test";
import assert from "node:assert/strict";
import { createOrderedPoster } from "./ordered-poster.ts";

const flush = () => new Promise<void>((r) => setImmediate(r));

// Live incident 2026-10-10: over the HTTPS tunnel every frame was its own
// fire-and-forget POST, so `subscribe_rooms` / `rooms_check` could reach the
// relay before `auth`. The relay closes on that ("expected hello or auth"),
// and the web showed live PCs as offline or failed to connect.
test("tunnel frames are posted one at a time, in send order", async () => {
  const started: string[] = [];
  const finish: Array<() => void> = [];
  const post = (frame: string) => {
    started.push(frame);
    const { promise, resolve } = Promise.withResolvers<void>();
    finish.push(resolve);
    return promise;
  };
  const send = createOrderedPoster(post, () => assert.fail("no failure expected"));

  send("auth");
  send("subscribe_presence");
  send("subscribe_rooms");
  await flush();
  assert.deepEqual(started, ["auth"], "next frame must wait for the previous POST");

  finish[0]!();
  await flush();
  assert.deepEqual(started, ["auth", "subscribe_presence"]);

  finish[1]!();
  await flush();
  finish[2]!();
  await flush();
  assert.deepEqual(started, ["auth", "subscribe_presence", "subscribe_rooms"]);
});

test("a failed POST reports once and drops the frames queued behind it", async () => {
  const started: string[] = [];
  let failures = 0;
  const failed = Promise.withResolvers<void>();
  const post = (frame: string) => {
    started.push(frame);
    return frame === "auth" ? Promise.reject(new Error("network")) : Promise.resolve();
  };
  const send = createOrderedPoster(post, () => {
    failures++;
    failed.resolve();
  });

  send("auth");
  send("subscribe_rooms");
  send("rooms_check");
  await failed.promise;
  await flush();
  assert.equal(failures, 1);
  assert.deepEqual(started, ["auth"]);
});
