import assert from "node:assert/strict";
import { describe, it } from "node:test";
import {
  DEFAULT_RELAY_URL,
  isValidRelayUrl,
  normalizeRelayUrl,
  relayUrlValidationMessage,
  toWsRelayUrl,
} from "./relay-config.ts";

describe("relay URL handling (app relay_config.dart)", () => {
  it("normalises user input to http(s)", () => {
    assert.equal(normalizeRelayUrl(" ws://178.157.59.181:3000/ "), "http://178.157.59.181:3000");
    assert.equal(normalizeRelayUrl("wss://relay.example.com"), "https://relay.example.com");
    assert.equal(normalizeRelayUrl("relay.example.com//"), "http://relay.example.com");
    assert.equal(normalizeRelayUrl("ftp://x"), "ftp://x");
  });

  it("maps to the WebSocket scheme for the transport", () => {
    assert.equal(toWsRelayUrl(DEFAULT_RELAY_URL), "ws://178.157.59.181");
    assert.equal(toWsRelayUrl("https://relay.example.com/"), "wss://relay.example.com");
  });

  it("validates like the app", () => {
    assert.equal(isValidRelayUrl("http://178.157.59.181"), true);
    assert.equal(isValidRelayUrl("ftp://x"), false);
    assert.equal(isValidRelayUrl("http://"), false);
    assert.notEqual(relayUrlValidationMessage("   "), null);
    assert.equal(relayUrlValidationMessage("my-relay.local:8080"), null);
  });
});
