import assert from "node:assert/strict";
import { createCipheriv, createPrivateKey, createPublicKey, diffieHellman, hkdfSync } from "node:crypto";
import { describe, it } from "node:test";
import {
  b64uDecode,
  b64uEncode,
  decryptWebLogin,
  deriveWebLoginKey,
  isWebLoginId,
  newWebLoginKeyPair,
  parseWebLoginEnvelope,
  webLoginQrText,
  type WebLoginEnvelope,
} from "./web-login-crypto.ts";

// The phone side, written independently against node:crypto exactly as the
// contract states (X25519 → HKDF-SHA256(empty salt, "remote-pi web-login v1")
// → AES-256-GCM, AAD = id, ct || tag), so these tests check the browser code
// against the protocol rather than against itself.

const PKCS8_X25519 = Buffer.from("302e020100300506032b656e04220420", "hex");
const SPKI_X25519 = Buffer.from("302a300506032b656e032100", "hex");

function phoneEncrypt(opts: {
  browserPk: Uint8Array;
  id: string;
  plaintext: string;
  phoneSk: Uint8Array;
  nonce: Uint8Array;
}): WebLoginEnvelope {
  const privateKey = createPrivateKey({ key: Buffer.concat([PKCS8_X25519, opts.phoneSk]), format: "der", type: "pkcs8" });
  const phonePk = createPublicKey(privateKey).export({ format: "der", type: "spki" }).subarray(-32);
  const publicKey = createPublicKey({ key: Buffer.concat([SPKI_X25519, opts.browserPk]), format: "der", type: "spki" });
  const shared = diffieHellman({ privateKey, publicKey });
  const key = Buffer.from(hkdfSync("sha256", shared, Buffer.alloc(0), Buffer.from("remote-pi web-login v1"), 32));
  const cipher = createCipheriv("aes-256-gcm", key, opts.nonce);
  cipher.setAAD(Buffer.from(opts.id, "utf8"));
  const ct = Buffer.concat([cipher.update(opts.plaintext, "utf8"), cipher.final(), cipher.getAuthTag()]);
  return { epk: b64uEncode(phonePk), nonce: b64uEncode(opts.nonce), ct: b64uEncode(ct) };
}

const ID = "AAECAwQFBgcICQoLDA0ODw"; // b64u of bytes 0..15
const SEED = new Uint8Array(32).map((_, i) => 0xa0 + i);
const RELAY = "wss://relay.example.test";
const PLAINTEXT = JSON.stringify({ v: 1, seed: b64uEncode(SEED), relay: RELAY });

// Fixed vector (deterministic keys + nonce), shared with the app's tests.
const BROWSER_SK = new Uint8Array(32).map((_, i) => i + 1);
const PHONE_SK = new Uint8Array(32).map((_, i) => 0x40 + i);
const NONCE = new Uint8Array(12).map((_, i) => 0xf0 + i);

const KNOWN_KEY_HEX = "ada332798430c328ae751c9d8574332d5405e380bcfee5baf206dc0879cfc141";
const KNOWN_ENVELOPE: WebLoginEnvelope = {
  epk: "eaYx7t4b-cmPEgMs3q3Q56B5OY_HhriMyEbsia-FpRo",
  nonce: "8PHy8_T19vf4-fr7",
  ct:
    "_QoeQ7vzsUcpZLtSx0tv85n--H3AVuE-WgumjGP9bwxYscarWFnbtaKgQPGmFA1LsWeV8BIwtA7IhQvOFAkZ6NWpemcJu90tBZbyE4LHmCEsdx8yIU43OJQwCo1YXDYd7FRmcNGL9Y8Heor4fnWU",
};

function browserPkOf(sk: Uint8Array): Uint8Array {
  const privateKey = createPrivateKey({ key: Buffer.concat([PKCS8_X25519, sk]), format: "der", type: "pkcs8" });
  return new Uint8Array(createPublicKey(privateKey).export({ format: "der", type: "spki" }).subarray(-32));
}

function freshDelivery() {
  const browser = newWebLoginKeyPair();
  const envelope = phoneEncrypt({
    browserPk: browser.publicKey,
    id: ID,
    plaintext: PLAINTEXT,
    phoneSk: crypto.getRandomValues(new Uint8Array(32)),
    nonce: crypto.getRandomValues(new Uint8Array(12)),
  });
  return { browser, envelope };
}

function flipFirstByte(b64u: string): string {
  const bytes = b64uDecode(b64u)!;
  bytes[0] ^= 0x01;
  return b64uEncode(bytes);
}

describe("decryptWebLogin", () => {
  it("decrypts the fixed vector produced by the phone side", () => {
    const envelope = phoneEncrypt({ browserPk: browserPkOf(BROWSER_SK), id: ID, plaintext: PLAINTEXT, phoneSk: PHONE_SK, nonce: NONCE });
    assert.deepEqual(envelope, KNOWN_ENVELOPE);
    const payload = decryptWebLogin(BROWSER_SK, ID, KNOWN_ENVELOPE);
    const key = deriveWebLoginKey(BROWSER_SK, b64uDecode(KNOWN_ENVELOPE.epk)!);
    assert.equal(Buffer.from(key).toString("hex"), KNOWN_KEY_HEX);
    assert.deepEqual(payload.seed, SEED);
    assert.equal(payload.relayUrl, RELAY);
  });

  it("round-trips with a fresh in-memory browser key pair", () => {
    const { browser, envelope } = freshDelivery();
    const payload = decryptWebLogin(browser.secretKey, ID, envelope);
    assert.deepEqual(payload.seed, SEED);
    assert.equal(payload.relayUrl, RELAY);
  });

  it("fails when the AAD/login id differs", () => {
    const { browser, envelope } = freshDelivery();
    assert.throws(() => decryptWebLogin(browser.secretKey, "AAECAwQFBgcICQoLDA0OEA", envelope));
  });

  it("fails on tampered ciphertext, tag, nonce or phone key", () => {
    const { browser, envelope } = freshDelivery();
    const ct = b64uDecode(envelope.ct)!;
    ct[ct.length - 1] ^= 0x80;
    assert.throws(() => decryptWebLogin(browser.secretKey, ID, { ...envelope, ct: b64uEncode(ct) }));
    assert.throws(() => decryptWebLogin(browser.secretKey, ID, { ...envelope, ct: flipFirstByte(envelope.ct) }));
    assert.throws(() => decryptWebLogin(browser.secretKey, ID, { ...envelope, nonce: flipFirstByte(envelope.nonce) }));
    assert.throws(() => decryptWebLogin(browser.secretKey, ID, { ...envelope, epk: flipFirstByte(envelope.epk) }));
  });

  it("fails for another browser's key", () => {
    const { envelope } = freshDelivery();
    assert.throws(() => decryptWebLogin(newWebLoginKeyPair().secretKey, ID, envelope));
  });

  it("validates the plaintext: version, seed length, optional relay", () => {
    const browser = newWebLoginKeyPair();
    const send = (plaintext: string) =>
      phoneEncrypt({ browserPk: browser.publicKey, id: ID, plaintext, phoneSk: PHONE_SK, nonce: NONCE });
    assert.throws(() => decryptWebLogin(browser.secretKey, ID, send(JSON.stringify({ v: 2, seed: b64uEncode(SEED) }))));
    assert.throws(() =>
      decryptWebLogin(browser.secretKey, ID, send(JSON.stringify({ v: 1, seed: b64uEncode(SEED.subarray(0, 16)) }))),
    );
    assert.throws(() => decryptWebLogin(browser.secretKey, ID, send("not json")));
    const noRelay = decryptWebLogin(browser.secretKey, ID, send(JSON.stringify({ v: 1, seed: b64uEncode(SEED), relay: " " })));
    assert.equal(noRelay.relayUrl, null);
  });
});

describe("web-login wire format", () => {
  it("builds the QR text the phone parses", () => {
    const { publicKey } = newWebLoginKeyPair();
    const text = webLoginQrText("178-157-59-181.sslip.io", ID, publicKey);
    const url = new URL(text);
    assert.equal(url.protocol, "remotepi:");
    assert.ok(text.startsWith("remotepi://web-login?"));
    assert.equal(url.searchParams.get("h"), "178-157-59-181.sslip.io");
    assert.equal(url.searchParams.get("id"), ID);
    assert.deepEqual(b64uDecode(url.searchParams.get("pk")!), publicKey);
    assert.doesNotMatch(url.searchParams.get("pk")!, /[+/=]/);
  });

  it("accepts only 16-byte base64url ids", () => {
    assert.ok(isWebLoginId(ID));
    assert.ok(!isWebLoginId(ID + "A"));
    assert.ok(!isWebLoginId("AAECAwQFBgcICQoLDA0OD+"));
    assert.ok(!isWebLoginId("../../etc/passwd"));
  });

  it("validates the envelope shape before storing", () => {
    const { envelope } = freshDelivery();
    assert.deepEqual(parseWebLoginEnvelope(envelope), envelope);
    assert.equal(parseWebLoginEnvelope(null), null);
    assert.equal(parseWebLoginEnvelope([]), null);
    assert.equal(parseWebLoginEnvelope({ ...envelope, epk: b64uEncode(new Uint8Array(31)) }), null);
    assert.equal(parseWebLoginEnvelope({ ...envelope, nonce: b64uEncode(new Uint8Array(16)) }), null);
    assert.equal(parseWebLoginEnvelope({ ...envelope, ct: b64uEncode(new Uint8Array(16)) }), null);
    assert.equal(parseWebLoginEnvelope({ ...envelope, ct: envelope.ct + "=" }), null);
  });

  it("base64url is unpadded and strict", () => {
    assert.equal(b64uEncode(new Uint8Array([0xfb, 0xff])), "-_8");
    assert.deepEqual(b64uDecode("-_8"), new Uint8Array([0xfb, 0xff]));
    assert.equal(b64uDecode("+/8="), null);
    assert.equal(b64uDecode("A"), null);
  });
});
