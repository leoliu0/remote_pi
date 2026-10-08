import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { isWebLoginId, WEB_LOGIN_TTL_MS } from "./web-login-crypto.ts";
import { WebLoginStore } from "./web-login-store.ts";

const BODY = '{"epk":"e","nonce":"n","ct":"c"}';

function storeWithClock(opts: { maxPending?: number } = {}) {
  const clock = { now: 1_000_000 };
  const store = new WebLoginStore({ now: () => clock.now, ...opts });
  return { store, clock };
}

describe("WebLoginStore", () => {
  it("issues 16-byte base64url ids with a 120 s TTL", () => {
    const { store } = storeWithClock();
    const id = store.create();
    assert.ok(id && isWebLoginId(id));
    assert.notEqual(store.create(), id);
    assert.equal(WEB_LOGIN_TTL_MS, 120_000);
  });

  it("polls 204 until delivered, hands the body out exactly once, then 404", () => {
    const { store } = storeWithClock();
    const id = store.create()!;
    assert.deepEqual(store.poll(id), { status: 204 });
    assert.equal(store.deliver(id, BODY), 204);
    assert.deepEqual(store.poll(id), { status: 200, body: BODY });
    assert.deepEqual(store.poll(id), { status: 404 });
  });

  it("accepts one delivery per id: a second one is 409, before and after pickup", () => {
    const { store } = storeWithClock();
    const id = store.create()!;
    assert.equal(store.deliver(id, BODY), 204);
    assert.equal(store.deliver(id, '{"other":1}'), 409);
    assert.deepEqual(store.poll(id), { status: 200, body: BODY });
    assert.equal(store.deliver(id, BODY), 409);
  });

  it("returns 404 for unknown ids", () => {
    const { store } = storeWithClock();
    assert.equal(store.deliver("AAECAwQFBgcICQoLDA0ODw", BODY), 404);
    assert.deepEqual(store.poll("AAECAwQFBgcICQoLDA0ODw"), { status: 404 });
  });

  it("expires ids after the TTL, delivered or not, and sweeps them", () => {
    const { store, clock } = storeWithClock();
    const waiting = store.create()!;
    const delivered = store.create()!;
    assert.equal(store.deliver(delivered, BODY), 204);
    clock.now += WEB_LOGIN_TTL_MS - 1;
    assert.deepEqual(store.poll(waiting), { status: 204 });
    clock.now += 1;
    assert.deepEqual(store.poll(waiting), { status: 404 });
    assert.equal(store.deliver(waiting, BODY), 404);
    assert.deepEqual(store.poll(delivered), { status: 404 });
    assert.equal(store.size, 0);
  });

  it("caps pending ids and frees slots as they expire", () => {
    const { store, clock } = storeWithClock({ maxPending: 2 });
    assert.ok(store.create());
    assert.ok(store.create());
    assert.equal(store.create(), null);
    clock.now += WEB_LOGIN_TTL_MS;
    assert.ok(store.create());
    assert.equal(store.size, 1);
  });
});
