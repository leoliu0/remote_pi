// Web sign-in, WhatsApp-Web style: the browser shows a QR with a one-time
// login id and an ephemeral X25519 public key; the phone app scans it and
// posts the owner seed to `/api/web-login/<id>`, end-to-end encrypted:
//
//   X25519(phone eph, browser eph) → HKDF-SHA256(salt = empty,
//   info = "remote-pi web-login v1", 32 bytes) → AES-256-GCM
//   (12-byte nonce, AAD = UTF-8 login id, output = ciphertext || 16-byte tag)
//
// The server only relays the opaque envelope. The browser's private key lives
// in memory for the lifetime of one QR code and is never stored.
//
// Imports only @noble packages so the node test runner can load it directly.

import { gcm } from "@noble/ciphers/aes.js";
import { x25519 } from "@noble/curves/ed25519.js";
import { hkdf } from "@noble/hashes/hkdf.js";
import { sha256 } from "@noble/hashes/sha2.js";

export const WEB_LOGIN_INFO = "remote-pi web-login v1";
/** Server-side lifetime of a login id; the QR is replaced when it runs out. */
export const WEB_LOGIN_TTL_MS = 120_000;
export const WEB_LOGIN_ID_BYTES = 16;

const NONCE_BYTES = 12;
const TAG_BYTES = 16;
const KEY_BYTES = 32;
const SEED_BYTES = 32;

// ── base64url (no padding) ───────────────────────────────────────────────────

export function b64uEncode(bytes: Uint8Array): string {
  let binary = "";
  for (let i = 0; i < bytes.byteLength; i++) binary += String.fromCharCode(bytes[i]);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

/** Strict: only the url-safe alphabet without padding; null on anything else. */
export function b64uDecode(text: string): Uint8Array | null {
  if (!/^[A-Za-z0-9_-]*$/.test(text) || text.length % 4 === 1) return null;
  let std = text.replace(/-/g, "+").replace(/_/g, "/");
  while (std.length % 4 !== 0) std += "=";
  const binary = atob(std);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
  return bytes;
}

/** A login id is exactly 16 random bytes, base64url-encoded (22 chars). */
export function isWebLoginId(id: string): boolean {
  return /^[A-Za-z0-9_-]{22}$/.test(id) && b64uDecode(id)?.length === WEB_LOGIN_ID_BYTES;
}

// ── envelope (what the phone posts and the server stores verbatim) ───────────

export interface WebLoginEnvelope {
  /** Phone's ephemeral X25519 public key (32 bytes). */
  epk: string;
  /** AES-GCM nonce (12 bytes). */
  nonce: string;
  /** AES-GCM ciphertext || 16-byte tag. */
  ct: string;
}

/** Shape check shared by the server (before storing) and the browser. */
export function parseWebLoginEnvelope(value: unknown): WebLoginEnvelope | null {
  if (typeof value !== "object" || value === null || Array.isArray(value)) return null;
  const { epk, nonce, ct } = value as Record<string, unknown>;
  if (typeof epk !== "string" || typeof nonce !== "string" || typeof ct !== "string") return null;
  if (b64uDecode(epk)?.length !== 32 || b64uDecode(nonce)?.length !== NONCE_BYTES) return null;
  const ctBytes = b64uDecode(ct);
  if (!ctBytes || ctBytes.length <= TAG_BYTES) return null;
  return { epk, nonce, ct };
}

// ── browser side ─────────────────────────────────────────────────────────────

export interface WebLoginKeyPair {
  secretKey: Uint8Array;
  publicKey: Uint8Array;
}

export function newWebLoginKeyPair(): WebLoginKeyPair {
  const { secretKey, publicKey } = x25519.keygen();
  return { secretKey, publicKey };
}

/** The text the browser renders as a QR code for the phone to scan. */
export function webLoginQrText(host: string, id: string, publicKey: Uint8Array): string {
  return `remotepi://web-login?h=${encodeURIComponent(host)}&id=${id}&pk=${b64uEncode(publicKey)}`;
}

/** X25519 → HKDF-SHA256 (empty salt, contract info) → 32-byte AES key. */
export function deriveWebLoginKey(secretKey: Uint8Array, peerPublicKey: Uint8Array): Uint8Array {
  const shared = x25519.getSharedSecret(secretKey, peerPublicKey);
  return hkdf(sha256, shared, new Uint8Array(0), new TextEncoder().encode(WEB_LOGIN_INFO), KEY_BYTES);
}

export interface WebLoginPayload {
  /** 32-byte Ed25519 owner seed. */
  seed: Uint8Array;
  /** Relay the phone is using, or null when absent/blank. */
  relayUrl: string | null;
}

/**
 * Decrypts and validates a delivered envelope for login `id`. Throws on any
 * failure (wrong key, wrong id/AAD, tampering, malformed plaintext).
 */
export function decryptWebLogin(secretKey: Uint8Array, id: string, envelope: WebLoginEnvelope): WebLoginPayload {
  const epk = b64uDecode(envelope.epk);
  const nonce = b64uDecode(envelope.nonce);
  const ct = b64uDecode(envelope.ct);
  if (!epk || epk.length !== 32 || !nonce || nonce.length !== NONCE_BYTES || !ct || ct.length <= TAG_BYTES) {
    throw new Error("malformed web-login envelope");
  }
  const key = deriveWebLoginKey(secretKey, epk);
  const plaintext = gcm(key, nonce, new TextEncoder().encode(id)).decrypt(ct);
  const payload = JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(plaintext)) as Record<string, unknown>;
  if (typeof payload !== "object" || payload === null || payload.v !== 1) {
    throw new Error("unsupported web-login payload version");
  }
  const seed = typeof payload.seed === "string" ? b64uDecode(payload.seed) : null;
  if (!seed || seed.length !== SEED_BYTES) throw new Error("web-login seed is not 32 bytes");
  const relay = typeof payload.relay === "string" ? payload.relay.trim() : "";
  return { seed, relayUrl: relay || null };
}
