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
  thinking?: string;
  pairedAt: string;
  lastConnectedAt?: string;
  status?: "working" | "online" | "offline";
  isLive?: boolean;
}

export type MessageRole = "user" | "assistant" | "tool" | "compaction" | "system";

export interface ToolCallData {
  id: string;
  tool: string;
  args?: Record<string, unknown> | null;
  command?: string;
  output?: string;
  result?: unknown;
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

export function toStandardB64(s: string): string {
  let std = s.replace(/-/g, "+").replace(/_/g, "/");
  while (std.length % 4 !== 0) {
    std += "=";
  }
  return std;
}

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
    } else if (trimmed.startsWith("http://") || trimmed.startsWith("https://") || trimmed.startsWith("wss://") || trimmed.startsWith("ws://")) {
      url = new URL(trimmed);
    } else {
      url = new URL(`https://dummy.host/pair?${trimmed}`);
    }

    const epk = url.searchParams.get("epk") || url.searchParams.get("k");
    const token = url.searchParams.get("t") || url.searchParams.get("token");
    const relay = url.searchParams.get("r") || url.searchParams.get("relay") || "ws://178.157.59.181:3000";
    const room = url.searchParams.get("rm") || url.searchParams.get("room") || "main";
    const name = url.searchParams.get("n") || url.searchParams.get("name") || (room === "main" ? "Remote Pi" : room);
    const cwd = url.searchParams.get("cwd") || undefined;

    if (!epk && !token) return null;

    const stdEpk = epk ? toStandardB64(epk) : "";

    return {
      remoteEpk: stdEpk,
      token: token || undefined,
      relayUrl: relay,
      roomId: room,
      name,
      cwd,
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
    const list: PairedSession[] = JSON.parse(raw);
    const cleaned = list.filter(
      (s) =>
        s.id !== "demo_session_1" &&
        !s.id?.startsWith("demo_") &&
        !s.name?.toLowerCase().includes("demo") &&
        !s.device?.toLowerCase().includes("simulated")
    );
    if (cleaned.length !== list.length) {
      localStorage.setItem(STORAGE_KEY_SESSIONS, JSON.stringify(cleaned));
    }
    return cleaned;
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

// ── RELAY CLIENT WITH DIRECT SERVER-SENT BRIDGE ───────────────────────────────

export class RemotePiRelayClient {
  private eventSource: EventSource | null = null;
  private session: PairedSession;
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
  public onRoomMeta?: (meta: { model?: string; thinking?: string; working?: boolean }) => void;
  public onQueuedState?: (items: Array<{ id: string; text: string; editable?: boolean }>) => void;
  constructor(session: PairedSession) {
    this.session = session;
  }

  public async connect(): Promise<void> {
    this.isDisposed = false;
    this.onStateChange?.("connecting");

    try {
      const params = new URLSearchParams({
        sessionId: this.session.id,
        roomId: this.session.roomId || "main",
        remoteEpk: this.session.remoteEpk || "",
        relayUrl: this.session.relayUrl || "",
      });
      const url = `/api/relay-bridge?${params.toString()}`;
      this.eventSource = new EventSource(url);
      this.eventSource.onmessage = (event) => {
        try {
          const payload = JSON.parse(event.data);
          this.handleBridgeEvent(payload);
        } catch (err) {
          console.warn("SSE frame error", err);
        }
      };

      this.eventSource.onerror = (err) => {
        if (this.isDisposed) return;
        console.warn("SSE connection error", err);
        this.onStateChange?.("reconnecting");
        this.onPresenceChange?.("reconnecting");
      };
    } catch (err: unknown) {
      const msg = err instanceof Error ? err.message : "Failed to connect to relay bridge";
      this.onStateChange?.("error", msg);
    }
  }

  private handleBridgeEvent(event: Record<string, unknown>): void {
    if (event.type === "init") {
      this.onStateChange?.("connected");
      if (event.presence) {
        this.onPresenceChange?.(event.presence as PeerPresence);
      }
      return;
    }

    if (event.type === "presence") {
      this.onPresenceChange?.(event.presence as PeerPresence || "offline");
      return;
    }

    if (event.type === "inner" && event.data && typeof event.data === "object") {
      this.handleServerMessage(event.data as Record<string, unknown>);
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

      case "session_history":
        if (Array.isArray(msg.events)) {
          const historyMessages: WebChatMessage[] = [];
          for (let i = 0; i < msg.events.length; i++) {
            const ev = msg.events[i];
            const eventId = (ev.id as string) || (ev.tool_call_id as string);
            const ts = (ev.ts as number) || Date.now();
            if (ev.type === "user_input") {
              historyMessages.push({
                id: eventId || `hist-user-${ts}-${i}`,
                role: "user",
                text: (ev.text as string) || "",
                timestamp: ts,
                status: "sent",
              });
            } else if (ev.type === "agent_message") {
              historyMessages.push({
                id: eventId || `hist-asst-${ts}-${i}`,
                role: "assistant",
                text: (ev.text as string) || "",
                timestamp: ts,
              });
            } else if (ev.type === "tool_request") {
              const toolCallId = (ev.tool_call_id as string) || eventId || `tc_${ts}_${i}`;
              historyMessages.push({
                id: `hist-tool-${toolCallId}-${i}`,
                role: "tool",
                text: `${ev.tool}: ${JSON.stringify(ev.args || {})}`,
                timestamp: ts,
                tool: {
                  id: toolCallId,
                  tool: ev.tool as string,
                  args: ev.args as Record<string, unknown>,
                  command: typeof ev.args?.command === "string" ? ev.args.command : undefined,
                  status: "done",
                },
              });
            } else if (ev.type === "compaction") {
              historyMessages.push({
                id: eventId || `hist-comp-${ts}-${i}`,
                role: "compaction",
                text: (ev.summary as string) || "Context compacted",
                timestamp: ts,
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
          command: typeof (msg.args as Record<string, unknown>)?.command === "string" ? (msg.args as Record<string, unknown>).command as string : undefined,
          status: "pending",
        });
        break;

      case "tool_result":
        this.onToolResult?.(msg.tool_call_id as string, msg.result, msg.error as string | undefined);
        break;

      case "compaction":
        this.onCompaction?.((msg.summary as string) || "Context compacted", (msg.tokens_before as number) || 0);
        break;

      case "room_meta_updated":
      case "room_meta":
        if (msg.meta && typeof msg.meta === "object") {
          const meta = msg.meta as Record<string, unknown>;
          const update = {
            model: typeof meta.model === "string" ? meta.model : undefined,
            thinking: typeof meta.thinking === "string" ? meta.thinking : undefined,
            working: typeof meta.working === "boolean" ? meta.working : undefined,
          };
          if (update.model) this.session.model = update.model;
          if (update.thinking) this.session.thinking = update.thinking;
          this.onRoomMeta?.(update);
        }
        break;

      case "queued_message_state":
        if (Array.isArray(msg.items)) {
          this.onQueuedState?.(msg.items as Array<{ id: string; text: string; editable?: boolean }>);
        } else if (typeof msg.text === "string" && msg.text) {
          this.onQueuedState?.([{ id: (msg.id as string) || "q1", text: msg.text, editable: true }]);
        } else {
          this.onQueuedState?.([]);
        }
        break;
    }
  }
  public async postAction(action: string, payload: Record<string, unknown> = {}): Promise<void> {
    try {
      await fetch("/api/relay-bridge", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          sessionId: this.session.id,
          roomId: this.session.roomId || "main",
          remoteEpk: this.session.remoteEpk,
          relayUrl: this.session.relayUrl,
          action,
          ...payload,
        }),
      });
    } catch (err) {
      console.warn("Failed to post action", err);
    }
  }

  public requestSync(): void {
    this.postAction("sync");
  }

  public sendMessage(text: string): void {
    this.postAction("send_message", { text });
  }

  public queueMessage(text: string): void {
    this.postAction("queue_message", { text });
  }

  public clearQueuedMessage(targetId?: string): void {
    this.postAction("clear_queued", { targetId });
  }

  public approveTool(toolCallId: string, decision: "allow" | "deny"): void {
    this.postAction("approve_tool", { toolCallId, decision });
  }
  public cancelTurn(targetId: string): void {
    this.postAction("cancel", { targetId });
  }

  public disconnect(): void {
    this.isDisposed = true;
    if (this.eventSource) {
      this.eventSource.close();
      this.eventSource = null;
    }
  }
}
