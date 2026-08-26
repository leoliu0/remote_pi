import * as ed from "@noble/ed25519";
import { sha512 } from "@noble/hashes/sha2.js";

// Wire SHA-512 into @noble/ed25519
ed.hashes.sha512 = (...messages: Uint8Array[]) => sha512(ed.etc.concatBytes(...messages));

export interface PairedSession {
  id: string;
  name: string;
  device: string;
  remoteEpk: string;
  token?: string;
  relayUrl: string;
  roomId: string;
  cwd?: string;
  model?: string;
  pairedAt: string;
  lastConnectedAt?: string;
}

export type MessageRole = "user" | "assistant" | "tool" | "compaction" | "system";

export interface ToolCallData {
  id: string;
  tool: string;
  args?: Record<string, unknown> | null;
  command?: string;
  output?: string;
  status: "pending" | "allowed" | "denied" | "done" | "error";
  error?: string;
  diff?: {
    file?: string;
    oldContent?: string;
    newContent?: string;
    hunks?: string[];
  };
}

export interface WebChatMessage {
  id: string;
  role: MessageRole;
  text: string;
  timestamp: number;
  image?: {
    data: string;
    mime: string;
  };
  tool?: ToolCallData;
  isStreaming?: boolean;
  status?: "sending" | "sent" | "failed";
  tokensBefore?: number;
  tokensAfter?: number;
}

export type ConnectionState = "disconnected" | "connecting" | "authenticating" | "pairing" | "connected" | "reconnecting" | "error";
export type PeerPresence = "online" | "working" | "reconnecting" | "offline" | "unknown";

// Base64 helpers (Standard RFC 4648 with padding)
export function bytesToBase64(bytes: Uint8Array): string {
  let binary = "";
  const len = bytes.byteLength;
  for (let i = 0; i < len; i++) {
    binary += String.fromCharCode(bytes[i]);
  }
  return btoa(binary);
}

export function base64ToBytes(base64: string): Uint8Array {
  // Normalize url-safe base64 to standard base64
  let std = base64.replace(/-/g, "+").replace(/_/g, "/");
  while (std.length % 4 !== 0) {
    std += "=";
  }
  const binary = atob(std);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) {
    bytes[i] = binary.charCodeAt(i);
  }
  return bytes;
}

// Convert URL-safe base64 to Standard Base64
export function toStandardB64(s: string): string {
  let std = s.replace(/-/g, "+").replace(/_/g, "/");
  while (std.length % 4 !== 0) {
    std += "=";
  }
  return std;
}

export function toUrlSafeB64(s: string): string {
  return s.replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

// Client Keypair Management
const STORAGE_KEY_CLIENT_KEY = "remotepi_web_client_key_v1";

export async function getOrCreateClientKeypair(): Promise<{ publicKey: string; privateKey: Uint8Array }> {
  if (typeof window !== "undefined") {
    try {
      const stored = localStorage.getItem(STORAGE_KEY_CLIENT_KEY);
      if (stored) {
        const privBytes = base64ToBytes(stored);
        const pubBytes = ed.getPublicKey(privBytes);
        return {
          publicKey: bytesToBase64(pubBytes),
          privateKey: privBytes,
        };
      }
    } catch (e) {
      console.warn("Failed to load stored client key", e);
    }
  }

  // Generate fresh keypair
  const privBytes = ed.utils.randomSecretKey();
  const pubBytes = ed.getPublicKey(privBytes);
  const pubB64 = bytesToBase64(pubBytes);

  if (typeof window !== "undefined") {
    try {
      localStorage.setItem(STORAGE_KEY_CLIENT_KEY, bytesToBase64(privBytes));
    } catch {}
  }

  return {
    publicKey: pubB64,
    privateKey: privBytes,
  };
}

export function parsePairUri(uri: string): Partial<PairedSession> | null {
  try {
    const trimmed = uri.trim();
    let url: URL;
    if (trimmed.startsWith("remotepi://")) {
      url = new URL(trimmed.replace("remotepi://", "https://dummy.host/"));
    } else if (trimmed.startsWith("http://") || trimmed.startsWith("https://") || trimmed.startsWith("wss://")) {
      url = new URL(trimmed);
    } else {
      url = new URL(`https://dummy.host/pair?${trimmed}`);
    }

    const epk = url.searchParams.get("epk") || url.searchParams.get("k");
    const token = url.searchParams.get("t") || url.searchParams.get("token");
    const relay = url.searchParams.get("r") || url.searchParams.get("relay") || "wss://relay-rp1.jacobmoura.work";
    const room = url.searchParams.get("rm") || url.searchParams.get("room") || "main";
    const name = url.searchParams.get("n") || url.searchParams.get("name") || (room === "main" ? "Remote Pi" : room);

    if (!epk && !token) return null;

    // Convert to standard base64
    const stdEpk = epk ? toStandardB64(epk) : "";

    return {
      remoteEpk: stdEpk,
      token: token || undefined,
      relayUrl: relay.startsWith("http") ? relay.replace(/^http/, "ws") : relay,
      roomId: room,
      name,
      device: name || `Device (${stdEpk.substring(0, 8)})`,
    };
  } catch {
    return null;
  }
}

const STORAGE_KEY_SESSIONS = "remotepi_web_sessions_v1";
const STORAGE_KEY_ACTIVE = "remotepi_web_active_id_v1";

export function getSavedSessions(): PairedSession[] {
  if (typeof window === "undefined") return [];
  try {
    const raw = localStorage.getItem(STORAGE_KEY_SESSIONS);
    if (!raw) return [];
    return JSON.parse(raw);
  } catch {
    return [];
  }
}

export function saveSession(session: PairedSession): void {
  if (typeof window === "undefined") return;
  try {
    const list = getSavedSessions();
    const idx = list.findIndex((s) => s.id === session.id || (s.remoteEpk === session.remoteEpk && s.roomId === session.roomId));
    if (idx >= 0) {
      list[idx] = { ...list[idx], ...session };
    } else {
      list.unshift(session);
    }
    localStorage.setItem(STORAGE_KEY_SESSIONS, JSON.stringify(list));
    localStorage.setItem(STORAGE_KEY_ACTIVE, session.id);
  } catch (err) {
    console.error("Failed to save session", err);
  }
}

export function deleteSession(id: string): void {
  if (typeof window === "undefined") return;
  try {
    const list = getSavedSessions().filter((s) => s.id !== id);
    localStorage.setItem(STORAGE_KEY_SESSIONS, JSON.stringify(list));
    if (localStorage.getItem(STORAGE_KEY_ACTIVE) === id) {
      localStorage.removeItem(STORAGE_KEY_ACTIVE);
    }
  } catch (err) {
    console.error("Failed to delete session", err);
  }
}

export function getActiveSessionId(): string | null {
  if (typeof window === "undefined") return null;
  return localStorage.getItem(STORAGE_KEY_ACTIVE);
}

export function setActiveSessionId(id: string): void {
  if (typeof window === "undefined") return;
  localStorage.setItem(STORAGE_KEY_ACTIVE, id);
}

// ── REAL RELAY WEBSOCKET CLIENT ───────────────────────────────────────────────

export class RemotePiRelayClient {
  private ws: WebSocket | null = null;
  private session: PairedSession;
  private keypair: { publicKey: string; privateKey: Uint8Array } | null = null;
  private pingTimer: ReturnType<typeof setInterval> | null = null;
  private isDisposed = false;

  public onStateChange?: (state: ConnectionState, error?: string) => void;
  public onPresenceChange?: (presence: PeerPresence) => void;
  public onMessage?: (msg: WebChatMessage) => void;
  public onStreamingChunk?: (chunk: string, inReplyTo: string) => void;
  public onAgentDone?: (inReplyTo: string) => void;
  public onToolRequest?: (tool: ToolCallData) => void;
  public onToolResult?: (toolCallId: string, result: unknown, error?: string) => void;
  public onSessionHistory?: (messages: WebChatMessage[]) => void;
  public onCompaction?: (summary: string, tokensBefore: number) => void;
  public onModelsList?: (models: unknown[], current?: unknown) => void;

  constructor(session: PairedSession) {
    this.session = session;
  }

  public async connect(): Promise<void> {
    this.isDisposed = false;
    this.onStateChange?.("connecting");

    try {
      this.keypair = await getOrCreateClientKeypair();
      let url = this.session.relayUrl || "wss://relay-rp1.jacobmoura.work";
      if (url.startsWith("http://")) url = url.replace("http://", "ws://");
      if (url.startsWith("https://")) url = url.replace("https://", "wss://");
      if (!url.startsWith("ws://") && !url.startsWith("wss://")) {
        url = `wss://${url}`;
      }

      this.ws = new WebSocket(url);

      this.ws.onopen = () => {
        this.onStateChange?.("authenticating");
        // Step 1: Send hello with client pubkey
        const hello = {
          type: "hello",
          pubkey: this.keypair!.publicKey,
        };
        this.ws?.send(JSON.stringify(hello));
      };

      this.ws.onmessage = async (event) => {
        try {
          const raw = typeof event.data === "string" ? event.data : await (event.data as Blob).text();
          const frame = JSON.parse(raw);
          await this.handleFrame(frame);
        } catch (err) {
          console.error("Failed to parse frame", err);
        }
      };

      this.ws.onerror = (err) => {
        console.warn("WebSocket error", err);
        this.onStateChange?.("error", "Relay connection error.");
      };

      this.ws.onclose = () => {
        if (this.isDisposed) return;
        this.onStateChange?.("disconnected");
        this.onPresenceChange?.("offline");
      };
    } catch (err: unknown) {
      console.error("Connection failed", err);
      const msg = err instanceof Error ? err.message : "Failed to initialize keypair or connect.";
      this.onStateChange?.("error", msg);
    }
  }

  private async handleFrame(frame: Record<string, unknown>): Promise<void> {
    // 1. Auth Challenge Handshake
    if (frame.type === "challenge" && typeof frame.nonce === "string") {
      if (!this.keypair) return;
      const nonceBytes = base64ToBytes(frame.nonce);
      const sigBytes = ed.sign(nonceBytes, this.keypair.privateKey);
      const sigB64 = bytesToBase64(sigBytes);
      const auth = {
        type: "auth",
        sig: sigB64,
      };
      this.ws?.send(JSON.stringify(auth));
      return;
    }

    // 2. Auth Completed / Status Online
    if (frame.type === "status" && frame.status === "online") {
      this.onStateChange?.("connected");
      this.onPresenceChange?.("online");
      this.startKeepalive();

      // If token provided, send pair_request
      if (this.session.token) {
        this.sendPairRequest();
      } else {
        // Request history sync
        this.requestSync();
      }
      return;
    }

    // 3. Presence Updates from Relay
    if (frame.type === "peer_online" && typeof frame.peer === "string") {
      const peer = toStandardB64(frame.peer);
      if (peer === this.session.remoteEpk) {
        this.onPresenceChange?.("online");
      }
      return;
    }

    if (frame.type === "peer_offline" && typeof frame.peer === "string") {
      const peer = toStandardB64(frame.peer);
      if (peer === this.session.remoteEpk) {
        this.onPresenceChange?.("offline");
      }
      return;
    }

    // 4. Outer Envelope containing Inner ServerMessage
    if (typeof frame.peer === "string" && typeof frame.ct === "string") {
      try {
        const innerJson = atob(frame.ct);
        const serverMsg = JSON.parse(innerJson);
        this.handleServerMessage(serverMsg);
      } catch (err) {
        console.error("Failed to decode inner message", err);
      }
    }
  }

  private handleServerMessage(msg: Record<string, unknown>): void {
    const type = msg.type;
    switch (type) {
      case "pair_ok":
        this.onStateChange?.("connected");
        this.onPresenceChange?.("online");
        this.requestSync();
        break;

      case "pair_error":
        this.onStateChange?.("error", `Pairing error: ${(msg.message as string) || msg.code}`);
        break;

      case "session_history":
        if (Array.isArray(msg.events)) {
          const historyMessages: WebChatMessage[] = [];
          for (const ev of msg.events) {
            if (ev.type === "user_input") {
              historyMessages.push({
                id: (ev.id as string) || `hist-${ev.ts}`,
                role: "user",
                text: (ev.text as string) || "",
                timestamp: (ev.ts as number) || Date.now(),
                status: "sent",
              });
            } else if (ev.type === "agent_message") {
              historyMessages.push({
                id: `hist-asst-${ev.ts}`,
                role: "assistant",
                text: (ev.text as string) || "",
                timestamp: (ev.ts as number) || Date.now(),
              });
            } else if (ev.type === "tool_request") {
              historyMessages.push({
                id: `hist-tool-${ev.ts}`,
                role: "tool",
                text: `${ev.tool}: ${JSON.stringify(ev.args || {})}`,
                timestamp: (ev.ts as number) || Date.now(),
                tool: {
                  id: ev.tool_call_id as string,
                  tool: ev.tool as string,
                  args: ev.args as Record<string, unknown>,
                  command: typeof ev.args?.command === "string" ? ev.args.command : undefined,
                  status: "done",
                },
              });
            } else if (ev.type === "compaction") {
              historyMessages.push({
                id: `hist-comp-${ev.ts}`,
                role: "compaction",
                text: (ev.summary as string) || "Context compacted",
                timestamp: (ev.ts as number) || Date.now(),
                tokensBefore: ev.tokens_before as number,
              });
            }
          }
          this.onSessionHistory?.(historyMessages);
        }
        break;

      case "user_input":
        this.onMessage?.({
          id: (msg.id as string) || `user-${Date.now()}`,
          role: "user",
          text: (msg.text as string) || "",
          timestamp: Date.now(),
          status: "sent",
        });
        break;

      case "agent_chunk":
        this.onPresenceChange?.("working");
        this.onStreamingChunk?.((msg.delta as string) || "", (msg.in_reply_to as string) || "");
        break;

      case "agent_message":
        this.onPresenceChange?.("online");
        this.onMessage?.({
          id: `asst-${Date.now()}`,
          role: "assistant",
          text: (msg.text as string) || "",
          timestamp: Date.now(),
        });
        break;

      case "agent_done":
        this.onPresenceChange?.("online");
        this.onAgentDone?.((msg.in_reply_to as string) || "");
        break;

      case "tool_request":
        this.onPresenceChange?.("working");
        this.onToolRequest?.({
          id: msg.tool_call_id as string,
          tool: msg.tool as string,
          args: msg.args as Record<string, unknown>,
          command: typeof (msg.args as any)?.command === "string" ? (msg.args as any).command : undefined,
          status: "pending",
        });
        break;

      case "tool_result":
        this.onToolResult?.(msg.tool_call_id as string, msg.result, msg.error as string | undefined);
        break;

      case "compaction":
        this.onCompaction?.((msg.summary as string) || "Context compacted", (msg.tokens_before as number) || 0);
        break;

      case "models_list":
        this.onModelsList?.(Array.isArray(msg.models) ? msg.models : [], msg.current);
        break;
    }
  }

  public sendInner(clientMsg: Record<string, unknown>): void {
    if (!this.ws || this.ws.readyState !== WebSocket.OPEN) return;
    const jsonStr = JSON.stringify(clientMsg);
    const ct = btoa(jsonStr);
    const outer = {
      peer: this.session.remoteEpk,
      room: this.session.roomId || "main",
      ct,
    };
    this.ws.send(JSON.stringify(outer));
  }

  public sendPairRequest(): void {
    this.sendInner({
      type: "pair_request",
      id: `pair_${Date.now()}`,
      token: this.session.token,
      device_name: "Remote Pi Web",
    });
  }

  public requestSync(): void {
    this.sendInner({
      type: "session_sync",
      id: `sync_${Date.now()}`,
      limit: 1000,
    });
  }

  public sendMessage(text: string): void {
    this.sendInner({
      type: "user_message",
      id: `cli_${Date.now()}`,
      text,
    });
  }

  public approveTool(toolCallId: string, decision: "allow" | "deny"): void {
    this.sendInner({
      type: "approve_tool",
      id: `dec_${Date.now()}`,
      tool_call_id: toolCallId,
      decision,
    });
  }

  public cancelTurn(targetId: string): void {
    this.sendInner({
      type: "cancel",
      id: `can_${Date.now()}`,
      target_id: targetId,
    });
  }

  public queueMessage(text: string): void {
    this.sendInner({
      type: "queued_message_set",
      id: `q_${Date.now()}`,
      text,
    });
  }

  public compactContext(): void {
    this.sendInner({
      type: "session_compact",
      id: `act_${Date.now()}`,
    });
  }

  public newSession(): void {
    this.sendInner({
      type: "session_new",
      id: `act_${Date.now()}`,
    });
  }

  public setModel(provider: string, modelId: string): void {
    this.sendInner({
      type: "model_set",
      id: `act_${Date.now()}`,
      provider,
      model_id: modelId,
    });
  }

  public setThinking(level: string): void {
    this.sendInner({
      type: "thinking_set",
      id: `act_${Date.now()}`,
      level,
    });
  }

  private startKeepalive(): void {
    this.stopKeepalive();
    this.pingTimer = setInterval(() => {
      if (this.ws && this.ws.readyState === WebSocket.OPEN) {
        this.sendInner({ type: "ping", id: `p_${Date.now()}` });
      }
    }, 25000);
  }

  private stopKeepalive(): void {
    if (this.pingTimer) {
      clearInterval(this.pingTimer);
      this.pingTimer = null;
    }
  }

  public disconnect(): void {
    this.isDisposed = true;
    this.stopKeepalive();
    if (this.ws) {
      this.ws.close();
      this.ws = null;
    }
  }
}
