// In-memory mailbox behind `/api/web-login`: one login id per QR code, at most
// one encrypted delivery per id, picked up by the browser exactly once. The
// server never sees a key — it stores the phone's opaque envelope verbatim.

import { b64uEncode, WEB_LOGIN_ID_BYTES, WEB_LOGIN_TTL_MS } from "./web-login-crypto.ts";

export const WEB_LOGIN_MAX_PENDING = 1000;
/** Largest accepted delivery body, in bytes. */
export const WEB_LOGIN_MAX_BODY_BYTES = 4096;

type Entry =
  | { state: "pending"; expiresAt: number }
  | { state: "delivered"; expiresAt: number; body: string }
  /** Picked up: kept until expiry so a late re-delivery still gets 409. */
  | { state: "consumed"; expiresAt: number };

export type DeliverResult = 204 | 404 | 409;
export type PollResult = { status: 204 } | { status: 200; body: string } | { status: 404 };

export interface WebLoginStoreOptions {
  ttlMs?: number;
  maxPending?: number;
  now?: () => number;
  newId?: () => string;
}

export class WebLoginStore {
  private readonly entries = new Map<string, Entry>();
  private readonly ttlMs: number;
  private readonly maxPending: number;
  private readonly now: () => number;
  private readonly newId: () => string;

  constructor(opts: WebLoginStoreOptions = {}) {
    this.ttlMs = opts.ttlMs ?? WEB_LOGIN_TTL_MS;
    this.maxPending = opts.maxPending ?? WEB_LOGIN_MAX_PENDING;
    this.now = opts.now ?? Date.now;
    this.newId = opts.newId ?? (() => b64uEncode(crypto.getRandomValues(new Uint8Array(WEB_LOGIN_ID_BYTES))));
  }

  get size(): number {
    return this.entries.size;
  }

  /** Drops every expired id. */
  sweep(): void {
    const now = this.now();
    for (const [id, entry] of this.entries) {
      if (entry.expiresAt <= now) this.entries.delete(id);
    }
  }

  /** New login id, or null when the store is full. */
  create(): string | null {
    this.sweep();
    if (this.entries.size >= this.maxPending) return null;
    let id = this.newId();
    while (this.entries.has(id)) id = this.newId();
    this.entries.set(id, { state: "pending", expiresAt: this.now() + this.ttlMs });
    return id;
  }

  /** Phone side: stores the envelope once. */
  deliver(id: string, body: string): DeliverResult {
    const entry = this.live(id);
    if (!entry) return 404;
    if (entry.state !== "pending") return 409;
    this.entries.set(id, { state: "delivered", expiresAt: entry.expiresAt, body });
    return 204;
  }

  /** Browser side: 204 while waiting, the envelope exactly once, then 404. */
  poll(id: string): PollResult {
    const entry = this.live(id);
    if (!entry || entry.state === "consumed") return { status: 404 };
    if (entry.state === "pending") return { status: 204 };
    this.entries.set(id, { state: "consumed", expiresAt: entry.expiresAt });
    return { status: 200, body: entry.body };
  }

  private live(id: string): Entry | null {
    this.sweep();
    return this.entries.get(id) ?? null;
  }
}

const GLOBAL_KEY = Symbol.for("remotepi.webLoginStore");

/**
 * Process-wide store. Pinned on globalThis so both route modules (and dev
 * hot reloads) share one map.
 */
export function webLoginStore(): WebLoginStore {
  const g = globalThis as unknown as Record<symbol, WebLoginStore | undefined>;
  return (g[GLOBAL_KEY] ??= new WebLoginStore());
}
