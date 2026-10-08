// Owner identity + signed mesh membership for the web client.
//
// The phone app hands the browser its owner key through a sign-in link
// (`/web#k=<seed>&r=<relay>`). With that key the browser authenticates to the
// relay exactly like the app, and reads the owner's paired PCs from the
// relay's signed mesh blob (`GET /mesh/<sha256(owner_pk) hex>`), verified the
// way app/lib/data/mesh/mesh_sync_service.dart does.
//
// Imports only @noble packages so the node test runner can load it directly.

import * as ed from "@noble/ed25519";
import { sha256, sha512 } from "@noble/hashes/sha2.js";

// Synchronous SHA-512 so signing/verifying also works outside secure contexts.
ed.hashes.sha512 = (...messages: Uint8Array[]) => sha512(ed.etc.concatBytes(...messages));

// ── base64 ───────────────────────────────────────────────────────────────────

export function bytesToBase64(bytes: Uint8Array): string {
  let binary = "";
  for (let i = 0; i < bytes.byteLength; i++) binary += String.fromCharCode(bytes[i]);
  return btoa(binary);
}

/** Accepts standard or url-safe base64, with or without padding. */
export function base64ToBytes(base64: string): Uint8Array {
  let std = base64.replace(/-/g, "+").replace(/_/g, "/");
  while (std.length % 4 !== 0) std += "=";
  const binary = atob(std);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
  return bytes;
}

// ── owner identity ───────────────────────────────────────────────────────────

export interface OwnerIdentity {
  /** 32-byte Ed25519 seed (the app's `ownerSk`). */
  seed: Uint8Array;
  publicKeyBytes: Uint8Array;
  /** Standard base64 — what the relay registry and PCs know us by. */
  publicKey: string;
}

export function identityFromSeed(seed: Uint8Array): OwnerIdentity {
  const publicKeyBytes = ed.getPublicKey(seed);
  return { seed, publicKeyBytes, publicKey: bytesToBase64(publicKeyBytes) };
}

export function signWithOwner(identity: OwnerIdentity, message: Uint8Array): Uint8Array {
  return ed.sign(message, identity.seed);
}

export type SignInLink =
  | { ok: true; seed: Uint8Array; relayUrl: string | null }
  | { ok: false; error: string };

/**
 * Parses the sign-in fragment `#k=<base64url seed>&r=<relay>`. Returns null
 * when the fragment carries no `k` (not a sign-in link).
 */
export function parseSignInFragment(hash: string): SignInLink | null {
  const params = new URLSearchParams(hash.replace(/^#/, ""));
  const k = params.get("k");
  if (k === null) return null;
  let seed: Uint8Array;
  try {
    seed = base64ToBytes(k);
  } catch {
    return { ok: false, error: "This sign-in link is damaged. Generate a new one on your phone." };
  }
  if (seed.length !== 32) {
    return { ok: false, error: "This sign-in link is damaged. Generate a new one on your phone." };
  }
  const r = params.get("r");
  return { ok: true, seed, relayUrl: r && r.trim() ? r.trim() : null };
}

// ── mesh blob ────────────────────────────────────────────────────────────────

export interface MeshEnvelope {
  /** base64 canonical JSON bytes, exactly as signed. */
  blob: string;
  /** base64 Ed25519 signature over the blob bytes. */
  sig: string;
}

export interface MeshMember {
  remoteEpk: string;
  relayUrl: string;
  pairedAt: string;
  nickname: string | null;
}

export interface VerifiedMesh {
  version: number;
  issuedAt: number;
  members: MeshMember[];
}

/** Hex SHA-256 of the raw owner pubkey — the `/mesh/<hash>` path segment. */
export function ownerPkHash(ownerPk: Uint8Array): string {
  return Array.from(sha256(ownerPk), (b) => b.toString(16).padStart(2, "0")).join("");
}

function sameBytes(a: Uint8Array, b: Uint8Array): boolean {
  return a.length === b.length && a.every((x, i) => x === b[i]);
}

/**
 * Verifies a mesh envelope for `ownerPk`: valid Ed25519 signature over the
 * exact blob bytes, blob owner equals us, version matches the relay's record
 * (when given), and the member list is well-formed with no duplicate PCs.
 * Returns null when any check fails.
 */
export function verifyMeshEnvelope(
  envelope: MeshEnvelope,
  ownerPk: Uint8Array,
  responseVersion?: number,
): VerifiedMesh | null {
  let blobBytes: Uint8Array;
  let sig: Uint8Array;
  let root: unknown;
  try {
    blobBytes = base64ToBytes(envelope.blob);
    sig = base64ToBytes(envelope.sig);
    root = JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(blobBytes));
  } catch {
    return null;
  }
  if (root === null || typeof root !== "object" || Array.isArray(root)) return null;
  const fields = root as Record<string, unknown>;
  const { version, issued_at: issuedAt, owner_pk: ownerPkB64, members: rawMembers } = fields;
  if (typeof version !== "number" || !Number.isInteger(version) || version <= 0) return null;
  if (typeof issuedAt !== "number" || !Number.isInteger(issuedAt)) return null;
  if (typeof ownerPkB64 !== "string" || !Array.isArray(rawMembers)) return null;

  let blobOwner: Uint8Array;
  try {
    blobOwner = base64ToBytes(ownerPkB64);
  } catch {
    return null;
  }
  if (blobOwner.length !== 32 || !sameBytes(blobOwner, ownerPk)) return null;
  try {
    if (!ed.verify(sig, blobBytes, blobOwner)) return null;
  } catch {
    return null;
  }
  if (responseVersion !== undefined && version !== responseVersion) return null;

  const members: MeshMember[] = [];
  const seen = new Set<string>();
  for (const raw of rawMembers) {
    if (raw === null || typeof raw !== "object" || Array.isArray(raw)) return null;
    const m = raw as Record<string, unknown>;
    const { remote_epk: remoteEpk, relay_url: relayUrl, paired_at: pairedAt, nickname } = m;
    if (typeof remoteEpk !== "string" || typeof relayUrl !== "string" || typeof pairedAt !== "string") return null;
    if (nickname !== undefined && nickname !== null && typeof nickname !== "string") return null;
    let epkBytes: Uint8Array;
    try {
      epkBytes = base64ToBytes(remoteEpk);
    } catch {
      return null;
    }
    if (epkBytes.length !== 32) return null;
    const canonical = bytesToBase64(epkBytes);
    if (seen.has(canonical)) return null;
    seen.add(canonical);
    members.push({ remoteEpk: canonical, relayUrl, pairedAt, nickname: typeof nickname === "string" ? nickname : null });
  }
  members.sort((a, b) => (a.remoteEpk < b.remoteEpk ? -1 : a.remoteEpk > b.remoteEpk ? 1 : 0));
  return { version, issuedAt, members };
}
