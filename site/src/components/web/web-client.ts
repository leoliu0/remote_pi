import {
  bytesToBase64,
  base64ToBytes,
  identityFromSeed,
  ownerPkHash,
  verifyMeshEnvelope,
  type OwnerIdentity,
  type VerifiedMesh,
} from "./mesh";
import type { InnerFrame, RelayConnection, RelayStatus } from "./relay-connection";
import { normalizeRelayUrl } from "./relay-config";
import { toStandardB64, type PeerRecord, type RoomInfo } from "./session-list";
import { toolOutcome, type ToolOutcome } from "./tool-output";
import { parseExtensionUiRequest, type ExtensionUiRequest, type ExtensionUiResponseWire } from "./extension-ui";

/** The room a chat is bound to — built from a Home tile when it is opened. */
export interface PairedSession {
  id: string;
  name: string;
  device: string;
  remoteEpk: string;
  relayUrl: string;
  roomId: string;
  cwd?: string;
  model?: string;
  thinking?: string;
  pairedAt: string;
  status?: "working" | "online" | "offline";
  isLive?: boolean;
}

export type MessageRole = "user" | "assistant" | "tool" | "compaction" | "system";

export interface ToolCallData {
  id: string;
  tool: string;
  args?: Record<string, unknown> | null;
  command?: string;
  /** Normalised result/error text (tool-output.ts `toolOutcome`); unset while running. */
  output?: string;
  status: "pending" | "done" | "error";
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

export type PeerPresence = "online" | "working" | "reconnecting" | "offline" | "unknown";

// ── local persistence ────────────────────────────────────────────────────────

const STORAGE_KEY_OWNER_SEED = "remotepi_web_owner_seed_v1";
const STORAGE_KEY_ROOMS = "remotepi_web_rooms_v1";
const STORAGE_PREFIX_MESH = "remotepi_web_mesh_v1:";
// Keys written by earlier web builds (self-minted key, server-bridge sessions).
const LEGACY_KEYS = ["remotepi_web_client_key_v1", "remotepi_web_sessions_v1", "remotepi_web_active_id_v1"];

function readJson(key: string): unknown {
  try {
    const raw = localStorage.getItem(key);
    return raw ? JSON.parse(raw) : null;
  } catch {
    return null;
  }
}

/** The owner identity the phone handed over, or null when signed out. */
export function loadOwnerIdentity(): OwnerIdentity | null {
  try {
    const stored = localStorage.getItem(STORAGE_KEY_OWNER_SEED);
    if (!stored) return null;
    const seed = base64ToBytes(stored);
    return seed.length === 32 ? identityFromSeed(seed) : null;
  } catch {
    return null;
  }
}

export function saveOwnerSeed(seed: Uint8Array): OwnerIdentity {
  localStorage.setItem(STORAGE_KEY_OWNER_SEED, bytesToBase64(seed));
  return identityFromSeed(seed);
}

/** Wipes the owner key and everything learned with it. Keeps the relay choice. */
export function signOut(): void {
  const keys: string[] = [];
  for (let i = 0; i < localStorage.length; i++) {
    const key = localStorage.key(i);
    if (key?.startsWith(STORAGE_PREFIX_MESH)) keys.push(key);
  }
  for (const key of [...keys, STORAGE_KEY_OWNER_SEED, STORAGE_KEY_ROOMS, ...LEGACY_KEYS]) {
    localStorage.removeItem(key);
  }
}

/** Cached rooms per PC so Home shows last-seen tiles before the relay answers. */
export function loadCachedRooms(): Record<string, RoomInfo[]> {
  const rooms = readJson(STORAGE_KEY_ROOMS);
  return rooms && typeof rooms === "object" && !Array.isArray(rooms) ? (rooms as Record<string, RoomInfo[]>) : {};
}

export function saveCachedRooms(roomsByPeer: Record<string, RoomInfo[]>): void {
  try {
    localStorage.setItem(STORAGE_KEY_ROOMS, JSON.stringify(roomsByPeer));
  } catch {}
}

// ── paired PCs from the signed mesh blob (mesh_sync_service.dart) ───────────

interface StoredMesh {
  blob: string;
  sig: string;
  version: number;
}

function meshStorageKey(identity: OwnerIdentity, relayUrl: string): string {
  return `${STORAGE_PREFIX_MESH}${identity.publicKey}:${normalizeRelayUrl(relayUrl)}`;
}

/** Last verified membership for (owner, relay), re-verified on every read. */
export function loadVerifiedMesh(identity: OwnerIdentity, relayUrl: string): VerifiedMesh | null {
  const stored = readJson(meshStorageKey(identity, relayUrl));
  if (!stored || typeof stored !== "object") return null;
  const { blob, sig, version } = stored as Partial<StoredMesh>;
  if (typeof blob !== "string" || typeof sig !== "string" || typeof version !== "number") return null;
  return verifyMeshEnvelope({ blob, sig }, identity.publicKeyBytes, version);
}

export type MeshSyncResult =
  | { kind: "updated"; mesh: VerifiedMesh }
  | { kind: "unchanged" }
  | { kind: "failed"; reason: string };

/**
 * Pulls `GET /mesh/<hash>` from the relay (through `/api/relay-mesh`, since
 * relays send no CORS headers) and accepts it only when the owner signature
 * verifies and the version moves forward.
 */
export async function syncMesh(identity: OwnerIdentity, relayUrl: string): Promise<MeshSyncResult> {
  const known = loadVerifiedMesh(identity, relayUrl);
  const params = new URLSearchParams({ relay: normalizeRelayUrl(relayUrl), hash: ownerPkHash(identity.publicKeyBytes) });
  if (known) params.set("since", String(known.version));
  let res: Response;
  try {
    res = await fetch(`/api/relay-mesh?${params}`, { cache: "no-store" });
  } catch (err) {
    return { kind: "failed", reason: err instanceof Error ? err.message : "network error" };
  }
  // 304: nothing newer; 404: this owner never published (no PCs yet).
  if (res.status === 304 || res.status === 404) return { kind: "unchanged" };
  if (res.status !== 200) return { kind: "failed", reason: `relay answered ${res.status}` };
  const body: unknown = await res.json().catch(() => null);
  if (!body || typeof body !== "object") return { kind: "failed", reason: "mesh response is not JSON" };
  const { blob, sig, version } = body as Partial<StoredMesh>;
  if (typeof blob !== "string" || typeof sig !== "string" || typeof version !== "number") {
    return { kind: "failed", reason: "mesh response is malformed" };
  }
  const mesh = verifyMeshEnvelope({ blob, sig }, identity.publicKeyBytes, version);
  if (!mesh) return { kind: "failed", reason: "mesh signature does not verify for this owner" };
  if (known && mesh.version <= known.version) return { kind: "failed", reason: "mesh version rolled back" };
  try {
    const stored: StoredMesh = { blob, sig, version };
    localStorage.setItem(meshStorageKey(identity, relayUrl), JSON.stringify(stored));
  } catch {}
  return { kind: "updated", mesh };
}

/** Mesh members → Home's PC records (storage.dart mesh projection). */
export function peersFromMesh(mesh: VerifiedMesh | null): PeerRecord[] {
  return (mesh?.members ?? []).map((m) => ({
    remoteEpk: toStandardB64(m.remoteEpk),
    sessionName: m.nickname ?? "remote_pi",
    nickname: m.nickname ?? undefined,
    relayUrl: m.relayUrl,
    pairedAt: m.pairedAt,
  }));
}

// ── room commands (inner messages the Pi accepts) ────────────────────────────

export type RoomCommand =
  | { action: "send_message"; text: string }
  | { action: "queue_message"; text: string }
  | { action: "clear_queued"; targetId?: string }
  | { action: "cancel"; targetId: string }
  | { action: "sync" }
  | { action: "set_model"; model: string }
  | { action: "set_thinking"; thinking: string }
  | { action: "compact" }
  | { action: "new_session" };

export function buildRoomCommand(cmd: RoomCommand): InnerFrame {
  const now = Date.now();
  switch (cmd.action) {
    case "send_message":
      return { type: "user_message", id: `cli_${now}`, text: cmd.text };
    case "queue_message":
      return { type: "queued_message_set", id: `q_${now}`, text: cmd.text };
    case "clear_queued":
      return { type: "queued_message_clear", id: `cq_${now}`, target_id: cmd.targetId };
    case "cancel":
      return { type: "cancel", id: `can_${now}`, target_id: cmd.targetId };
    case "sync":
      return { type: "session_sync", id: `sync_${now}`, limit: 1000 };
    case "set_model": {
      const [provider, modelId] = cmd.model.includes("/") ? cmd.model.split("/") : ["google", cmd.model];
      return { type: "model_set", id: `act_${now}`, provider, model_id: modelId };
    }
    case "set_thinking":
      return { type: "thinking_set", id: `act_${now}`, level: cmd.thinking };
    case "compact":
      return { type: "session_compact", id: `act_${now}` };
    case "new_session":
      return { type: "session_new", id: `act_${now}` };
  }
}

// ── chat client bound to one (PC, room) over the shared relay link ──────────

/** Callbacks a chat view registers when it binds a client to its room. */
export interface ChatClientEvents {
  onPresenceChange?: (presence: PeerPresence) => void;
  onMessage?: (msg: WebChatMessage) => void;
  onStreamingChunk?: (chunk: string, inReplyTo: string) => void;
  onAgentDone?: (inReplyTo: string) => void;
  onToolRequest?: (tool: ToolCallData) => void;
  onToolResult?: (toolCallId: string, outcome: ToolOutcome) => void;
  /** Plan/57 — interactive prompt (ask_user / plan review) or its notify dismiss. */
  onExtensionUiRequest?: (req: ExtensionUiRequest) => void;
  onSessionHistory?: (messages: WebChatMessage[]) => void;
  onCompaction?: (summary: string, tokensBefore: number) => void;
  onRoomMeta?: (meta: { model?: string; thinking?: string; working?: boolean }) => void;
  onQueuedState?: (items: Array<{ id: string; text: string; editable?: boolean }>) => void;
}

export class RemotePiRelayClient {
  private readonly conn: RelayConnection;
  private readonly session: PairedSession;
  private readonly peer: string;
  private pending: InnerFrame[] = [];
  private unsubscribers: Array<() => void> = [];
  private events: ChatClientEvents = {};

  constructor(conn: RelayConnection, session: PairedSession) {
    this.conn = conn;
    this.session = session;
    this.peer = toStandardB64(session.remoteEpk);
  }

  public connect(events: ChatClientEvents): void {
    this.disconnect();
    this.events = events;
    this.unsubscribers.push(
      this.conn.onInner((peer, room, inner) => {
        // Strict (peer, room) isolation: other rooms share this socket.
        if (toStandardB64(peer) !== this.peer || room !== this.session.roomId) return;
        this.handleServerMessage(inner);
      }),
      this.conn.onStatus((status) => this.handleStatus(status)),
    );
    this.handleStatus(this.conn.currentStatus);
  }

  public disconnect(): void {
    this.unsubscribers.forEach((u) => u());
    this.unsubscribers = [];
    this.pending = [];
    this.events = {};
  }

  /** Every (re)connect flushes queued sends and re-syncs history, like the app. */
  private handleStatus(status: RelayStatus): void {
    if (status !== "online") return;
    const queued = this.pending;
    this.pending = [];
    for (const inner of queued) this.send(inner);
    this.requestSync();
  }

  private send(inner: InnerFrame): void {
    if (!this.conn.sendInner(this.peer, this.session.roomId, inner)) this.pending.push(inner);
  }

  private handleServerMessage(msg: Record<string, unknown>): void {
    const type = msg.type;
    switch (type) {
      case "session_history":
        if (Array.isArray(msg.events)) {
          const historyMessages: WebChatMessage[] = [];
          const historyTools = new Map<string, ToolCallData>();
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
              const tool: ToolCallData = {
                id: toolCallId,
                tool: ev.tool as string,
                args: ev.args as Record<string, unknown>,
                command: typeof ev.args?.command === "string" ? ev.args.command : undefined,
                // No result yet in history → still running; the live tool_result completes it.
                status: "pending",
              };
              historyTools.set(toolCallId, tool);
              historyMessages.push({
                id: `hist-tool-${toolCallId}-${i}`,
                role: "tool",
                text: `${ev.tool}: ${JSON.stringify(ev.args || {})}`,
                timestamp: ts,
                tool,
              });
            } else if (ev.type === "tool_result") {
              const tool = historyTools.get(ev.tool_call_id as string);
              if (tool) {
                const { output, isError } = toolOutcome(ev.result, ev.error);
                tool.output = output;
                tool.status = isError ? "error" : "done";
              }
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
          this.events.onSessionHistory?.(historyMessages);
        }
        break;

      case "user_input":
        this.events.onMessage?.({
          id: (msg.id as string) || `user-${Date.now()}`,
          role: "user",
          text: (msg.text as string) || "",
          timestamp: Date.now(),
          status: "sent",
        });
        break;

      case "agent_chunk":
        this.events.onPresenceChange?.("working");
        this.events.onStreamingChunk?.((msg.delta as string) || "", (msg.in_reply_to as string) || "");
        break;

      case "agent_message":
        this.events.onPresenceChange?.("online");
        this.events.onMessage?.({
          id: `asst-${Date.now()}`,
          role: "assistant",
          text: (msg.text as string) || "",
          timestamp: Date.now(),
        });
        break;

      case "agent_done":
        this.events.onPresenceChange?.("online");
        this.events.onAgentDone?.((msg.in_reply_to as string) || "");
        break;

      case "tool_request": {
        const args = msg.args && typeof msg.args === "object" ? (msg.args as Record<string, unknown>) : undefined;
        this.events.onPresenceChange?.("working");
        this.events.onToolRequest?.({
          id: msg.tool_call_id as string,
          tool: msg.tool as string,
          args,
          command: typeof args?.command === "string" ? args.command : undefined,
          status: "pending",
        });
        break;
      }

      case "tool_result":
        this.events.onToolResult?.(msg.tool_call_id as string, toolOutcome(msg.result, msg.error));
        break;

      case "extension_ui_request": {
        const req = parseExtensionUiRequest(msg);
        if (req) this.events.onExtensionUiRequest?.(req);
        break;
      }

      case "compaction":
        this.events.onCompaction?.((msg.summary as string) || "Context compacted", (msg.tokens_before as number) || 0);
        break;

      case "room_meta_updated":
      case "room_meta":
        if (msg.meta && typeof msg.meta === "object") {
          const meta = msg.meta as Record<string, unknown>;
          this.events.onRoomMeta?.({
            model: typeof meta.model === "string" ? meta.model : undefined,
            thinking: typeof meta.thinking === "string" ? meta.thinking : undefined,
            working: typeof meta.working === "boolean" ? meta.working : undefined,
          });
        }
        break;

      case "queued_message_state":
        if (Array.isArray(msg.items)) {
          this.events.onQueuedState?.(msg.items as Array<{ id: string; text: string; editable?: boolean }>);
        } else if (typeof msg.text === "string" && msg.text) {
          this.events.onQueuedState?.([{ id: (msg.id as string) || "q1", text: msg.text, editable: true }]);
        } else {
          this.events.onQueuedState?.([]);
        }
        break;
    }
  }

  public requestSync(): void {
    this.send(buildRoomCommand({ action: "sync" }));
  }

  public sendMessage(text: string): void {
    this.send(buildRoomCommand({ action: "send_message", text }));
  }

  public queueMessage(text: string): void {
    this.send(buildRoomCommand({ action: "queue_message", text }));
  }

  public clearQueuedMessage(targetId?: string): void {
    this.send(buildRoomCommand({ action: "clear_queued", targetId }));
  }

  /**
   * Plan/57 — answer or cancel an extension prompt. Sent only on a live link
   * (false otherwise) so a retry after reconnect never double-submits.
   */
  public respondExtensionUi(resp: ExtensionUiResponseWire): boolean {
    return this.conn.sendInner(this.peer, this.session.roomId, { ...resp });
  }

  public cancelTurn(targetId: string): void {
    this.send(buildRoomCommand({ action: "cancel", targetId }));
  }
}
