// Browser-side relay link — the web counterpart of the app's ConnectionManager
// transport. One WebSocket per selected relay, authenticated with the owner
// key the phone handed over at sign-in (hello → challenge → auth, same as the
// app's WsTransport), carrying:
//   - relay control frames (presence / rooms) for the paired PCs
//   - opaque `{peer, room, ct}` envelopes to and from each Pi room
//
// Pages served over https cannot open `ws://` sockets (mixed content), so for
// that combination the socket is tunnelled through `/api/relay-tunnel`, a
// byte pipe that never sees the owner key.

import { base64ToBytes, bytesToBase64, signWithOwner, type OwnerIdentity } from "./mesh";
import { createOrderedPoster } from "./ordered-poster";
import { toWsRelayUrl } from "./relay-config";
import { toStandardB64 } from "./session-list";

// ── socket (direct or tunnelled) ─────────────────────────────────────────────

interface RelaySocket {
  onopen: (() => void) | null;
  onmessage: ((text: string) => void) | null;
  onclose: (() => void) | null;
  send(text: string): void;
  close(): void;
}

function openDirectSocket(wsUrl: string): RelaySocket {
  const ws = new WebSocket(wsUrl);
  const socket: RelaySocket = {
    onopen: null,
    onmessage: null,
    onclose: null,
    send: (text) => ws.send(text),
    close: () => ws.close(),
  };
  ws.onopen = () => socket.onopen?.();
  ws.onmessage = (e) => {
    if (typeof e.data === "string") socket.onmessage?.(e.data);
  };
  ws.onclose = () => socket.onclose?.();
  return socket;
}

function openTunnelSocket(wsUrl: string): RelaySocket {
  const id = randomId("tun");
  const source = new EventSource(`/api/relay-tunnel?${new URLSearchParams({ id, url: wsUrl })}`);
  let closed = false;
  // Frames must reach the relay in order (`auth` before subscriptions), so
  // each POST waits for the previous one.
  const post = createOrderedPoster(
    (frame) =>
      fetch("/api/relay-tunnel", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ id, frame }),
      }),
    () => finish(),
  );
  const socket: RelaySocket = {
    onopen: null,
    onmessage: null,
    onclose: null,
    send: (frame) => {
      if (!closed) post(frame);
    },
    close: () => finish(),
  };
  const finish = () => {
    if (closed) return;
    closed = true;
    source.close();
    void fetch(`/api/relay-tunnel?${new URLSearchParams({ id })}`, { method: "DELETE" }).catch(() => {});
    socket.onclose?.();
  };
  source.onmessage = (e) => {
    const event = JSON.parse(e.data) as { t: "open" | "msg" | "close"; d?: string };
    if (event.t === "open") socket.onopen?.();
    else if (event.t === "msg" && typeof event.d === "string") socket.onmessage?.(event.d);
    else finish();
  };
  source.onerror = () => finish();
  return socket;
}

function randomId(prefix: string): string {
  const bytes = new Uint8Array(8);
  crypto.getRandomValues(bytes);
  return `${prefix}_${Date.now().toString(36)}_${Array.from(bytes, (b) => b.toString(16).padStart(2, "0")).join("")}`;
}

// ── connection ───────────────────────────────────────────────────────────────

export type RelayStatus = "connecting" | "online" | "offline";
export type InnerFrame = Record<string, unknown>;

const RETRY_DELAYS_MS = [1000, 2000, 4000, 8000, 15000];

export class RelayConnection {
  readonly relayUrl: string;
  private readonly identity: OwnerIdentity;
  private socket: RelaySocket | null = null;
  private status: RelayStatus = "offline";
  private peers: string[] = [];
  private retryAttempt = 0;
  private retryTimer: number | null = null;
  private stopped = true;
  private readonly statusListeners = new Set<(status: RelayStatus) => void>();
  private readonly controlListeners = new Set<(frame: unknown) => void>();
  private readonly innerListeners = new Set<(peer: string, room: string, inner: InnerFrame) => void>();

  constructor(relayUrl: string, identity: OwnerIdentity) {
    this.relayUrl = relayUrl;
    this.identity = identity;
  }

  get currentStatus(): RelayStatus {
    return this.status;
  }

  start(): void {
    if (!this.stopped) return;
    this.stopped = false;
    this.open();
  }

  stop(): void {
    this.stopped = true;
    clearTimeout(this.retryTimer ?? undefined);
    this.retryTimer = null;
    const socket = this.socket;
    this.socket = null;
    socket?.close();
    this.setStatus("offline");
  }

  /**
   * Subscribe the relay to presence + rooms for `epks` (replayed on every
   * reconnect). Checks only go out for a non-empty list: an empty
   * `rooms_check` would return every room on the relay.
   */
  setPeers(epks: string[]): void {
    this.peers = Array.from(new Set(epks.map(toStandardB64)));
    if (this.status === "online") this.sendSubscriptions();
  }

  onStatus(listener: (status: RelayStatus) => void): () => void {
    this.statusListeners.add(listener);
    return () => this.statusListeners.delete(listener);
  }

  /** Raw relay control frames (anything with a top-level `type`). */
  onControl(listener: (frame: unknown) => void): () => void {
    this.controlListeners.add(listener);
    return () => this.controlListeners.delete(listener);
  }

  /** Decoded envelopes from Pi rooms. `room` is the sender's room id. */
  onInner(listener: (peer: string, room: string, inner: InnerFrame) => void): () => void {
    this.innerListeners.add(listener);
    return () => this.innerListeners.delete(listener);
  }

  /** Sends one inner message to `(peer, room)`. False when the link is down. */
  sendInner(peer: string, room: string, inner: InnerFrame): boolean {
    if (this.status !== "online" || !this.socket) return false;
    const ct = bytesToBase64(new TextEncoder().encode(JSON.stringify(inner)));
    this.socket.send(JSON.stringify({ peer: toStandardB64(peer), room, ct }));
    return true;
  }

  private open(): void {
    this.setStatus("connecting");
    const wsUrl = toWsRelayUrl(this.relayUrl);
    const needsTunnel = window.location.protocol === "https:" && wsUrl.startsWith("ws://");
    let socket: RelaySocket;
    try {
      socket = needsTunnel ? openTunnelSocket(wsUrl) : openDirectSocket(wsUrl);
    } catch (err) {
      console.warn("Relay socket failed to open", err);
      this.setStatus("offline");
      this.scheduleRetry();
      return;
    }
    this.socket = socket;
    socket.onopen = () => {
      if (this.socket === socket) {
        // `room_id: main` — clients register on the canonical room, like the app.
        socket.send(JSON.stringify({ type: "hello", pubkey: this.identity.publicKey, room_id: "main" }));
      }
    };
    socket.onmessage = (text) => {
      if (this.socket === socket) this.handleText(socket, text);
    };
    socket.onclose = () => {
      if (this.socket !== socket) return;
      this.socket = null;
      this.setStatus("offline");
      this.scheduleRetry();
    };
  }

  private handleText(socket: RelaySocket, text: string): void {
    let frame: Record<string, unknown>;
    try {
      frame = JSON.parse(text);
    } catch {
      return;
    }
    if (typeof frame.type === "string") {
      if (frame.type === "challenge" && typeof frame.nonce === "string") {
        const sig = signWithOwner(this.identity, base64ToBytes(frame.nonce));
        socket.send(JSON.stringify({ type: "auth", sig: bytesToBase64(sig) }));
        this.retryAttempt = 0;
        this.setStatus("online");
        this.sendSubscriptions();
        return;
      }
      for (const l of this.controlListeners) l(frame);
      return;
    }
    if (typeof frame.peer !== "string" || typeof frame.ct !== "string") return;
    let inner: InnerFrame;
    try {
      inner = JSON.parse(new TextDecoder().decode(base64ToBytes(frame.ct)));
    } catch {
      return;
    }
    const room = typeof frame.room === "string" ? frame.room : "main";
    for (const l of this.innerListeners) l(frame.peer, room, inner);
  }

  private sendSubscriptions(): void {
    const socket = this.socket;
    if (!socket) return;
    socket.send(JSON.stringify({ type: "subscribe_presence", peers: this.peers }));
    socket.send(JSON.stringify({ type: "subscribe_rooms", peers: this.peers }));
    if (this.peers.length === 0) return;
    socket.send(JSON.stringify({ type: "presence_check", peers: this.peers }));
    socket.send(JSON.stringify({ type: "rooms_check", peers: this.peers }));
  }

  private scheduleRetry(): void {
    if (this.stopped || this.retryTimer) return;
    const delay = RETRY_DELAYS_MS[Math.min(this.retryAttempt, RETRY_DELAYS_MS.length - 1)];
    this.retryAttempt++;
    this.retryTimer = window.setTimeout(() => {
      this.retryTimer = null;
      if (!this.stopped) this.open();
    }, delay);
  }

  private setStatus(status: RelayStatus): void {
    if (this.status === status) return;
    this.status = status;
    for (const l of this.statusListeners) l(status);
  }
}
