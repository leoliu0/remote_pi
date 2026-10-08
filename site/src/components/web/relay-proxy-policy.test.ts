import { test } from "node:test";
import assert from "node:assert/strict";
import { isRelayProxyTargetAllowed } from "./relay-proxy-policy.ts";

test("public deployment: only listed relay hosts are proxied", () => {
  const allow = "178.157.59.181, relay.example.com:8443";
  assert.equal(isRelayProxyTargetAllowed("ws://178.157.59.181", allow), true);
  assert.equal(isRelayProxyTargetAllowed("http://178.157.59.181/mesh/ab", allow), true);
  assert.equal(isRelayProxyTargetAllowed("wss://relay.example.com:8443", allow), true);
  assert.equal(isRelayProxyTargetAllowed("wss://relay.example.com", allow), false);
  assert.equal(isRelayProxyTargetAllowed("ws://127.0.0.1:3000", allow), false);
  assert.equal(isRelayProxyTargetAllowed("ws://178.157.59.181.evil.com", allow), false);
  assert.equal(isRelayProxyTargetAllowed("file:///etc/passwd", allow), false);
  assert.equal(isRelayProxyTargetAllowed("not a url", allow), false);
});

test("unset list allows any ws/http relay (local development)", () => {
  assert.equal(isRelayProxyTargetAllowed("ws://localhost:3000", undefined), true);
  assert.equal(isRelayProxyTargetAllowed("ftp://x", undefined), false);
});
