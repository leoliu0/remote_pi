import assert from "node:assert/strict";
import { describe, it } from "node:test";
import * as ed from "@noble/ed25519";
import {
  base64ToBytes,
  bytesToBase64,
  identityFromSeed,
  ownerPkHash,
  parseSignInFragment,
  verifyMeshEnvelope,
  type MeshEnvelope,
} from "./mesh.ts";

const seed = new Uint8Array(32).map((_, i) => i + 1);
const owner = identityFromSeed(seed);
const pcA = bytesToBase64(new Uint8Array(32).fill(7));
const pcB = bytesToBase64(new Uint8Array(32).fill(9));

function b64url(bytes: Uint8Array): string {
  return bytesToBase64(bytes).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

/** Builds an envelope the way the app's MeshBlob.signWith does (sorted keys). */
function envelope(
  members: Array<Record<string, unknown>>,
  opts: { version?: number; ownerPk?: Uint8Array; signer?: Uint8Array } = {},
): MeshEnvelope {
  const blob = JSON.stringify({
    issued_at: 1_700_000_000_000,
    members,
    owner_pk: bytesToBase64(opts.ownerPk ?? owner.publicKeyBytes),
    version: opts.version ?? 3,
  });
  const bytes = new TextEncoder().encode(blob);
  return { blob: bytesToBase64(bytes), sig: bytesToBase64(ed.sign(bytes, opts.signer ?? seed)) };
}

const member = (epk: string, nickname?: string) => ({
  nickname,
  paired_at: "2026-10-01T00:00:00.000Z",
  relay_url: "http://178.157.59.181",
  remote_epk: epk,
});

describe("parseSignInFragment", () => {
  it("decodes the base64url seed and the encoded relay", () => {
    const link = parseSignInFragment(`#k=${b64url(seed)}&r=${encodeURIComponent("http://178.157.59.181")}`);
    assert.ok(link && link.ok);
    assert.deepEqual(link.seed, seed);
    assert.equal(link.relayUrl, "http://178.157.59.181");
  });

  it("ignores fragments without k and rejects seeds that are not 32 bytes", () => {
    assert.equal(parseSignInFragment("#section-2"), null);
    assert.equal(parseSignInFragment(""), null);
    const short = parseSignInFragment(`#k=${b64url(new Uint8Array(16))}`);
    assert.ok(short && !short.ok);
  });

  it("derives the same Ed25519 public key as the app's newKeyPairFromSeed", () => {
    assert.deepEqual(owner.publicKeyBytes, ed.getPublicKey(seed));
    assert.equal(base64ToBytes(owner.publicKey).length, 32);
  });
});

describe("verifyMeshEnvelope", () => {
  it("accepts a correctly signed blob and canonicalises member epks", () => {
    const urlSafe = b64url(base64ToBytes(pcA));
    const mesh = verifyMeshEnvelope(envelope([member(urlSafe, "x3d"), member(pcB)]), owner.publicKeyBytes, 3);
    assert.ok(mesh);
    assert.equal(mesh.version, 3);
    assert.deepEqual(
      mesh.members.map((m) => [m.remoteEpk, m.nickname]),
      [[pcA, "x3d"], [pcB, null]],
    );
  });

  it("rejects a signature by another key", () => {
    const forged = envelope([member(pcA)], { signer: new Uint8Array(32).fill(42) });
    assert.equal(verifyMeshEnvelope(forged, owner.publicKeyBytes), null);
  });

  it("rejects a blob for another owner even if self-consistent", () => {
    const otherSeed = new Uint8Array(32).fill(5);
    const other = envelope([member(pcA)], { ownerPk: ed.getPublicKey(otherSeed), signer: otherSeed });
    assert.equal(verifyMeshEnvelope(other, owner.publicKeyBytes), null);
  });

  it("rejects tampered bytes, version mismatches and duplicate PCs", () => {
    const env = envelope([member(pcA)]);
    const tampered = new TextDecoder().decode(base64ToBytes(env.blob)).replace("x3d", "x3e").replace('"version":3', '"version":4');
    assert.equal(verifyMeshEnvelope({ ...env, blob: bytesToBase64(new TextEncoder().encode(tampered)) }, owner.publicKeyBytes), null);
    assert.equal(verifyMeshEnvelope(env, owner.publicKeyBytes, 4), null);
    assert.equal(verifyMeshEnvelope(envelope([member(pcA), member(pcA)]), owner.publicKeyBytes), null);
  });

  it("an empty member list is a valid 'no PCs' mesh", () => {
    assert.deepEqual(verifyMeshEnvelope(envelope([]), owner.publicKeyBytes)?.members, []);
  });
});

describe("ownerPkHash", () => {
  it("is the lowercase hex SHA-256 of the raw pubkey", () => {
    assert.equal(ownerPkHash(new Uint8Array(0)), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855");
    assert.match(ownerPkHash(owner.publicKeyBytes), /^[0-9a-f]{64}$/);
  });
});
