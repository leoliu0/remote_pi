import {
  bytesToBase64,
  base64ToBytes,
  identityFromSeed,
  ownerPkHash,
  verifyMeshEnvelope,
  type OwnerIdentity,
  type VerifiedMesh,
} from "./mesh.ts";
import type { InnerFrame, RelayConnection, RelayStatus } from "./relay-connection";
import { normalizeRelayUrl } from "./relay-config.ts";
import { toStandardB64, type PeerRecord, type RoomInfo } from "./session-list.ts";
import { chatEventFromFrame, type ChatEvent } from "./chat-stream.ts";
import { parseExtensionUiRequest, type ExtensionUiRequest, type ExtensionUiResponseWire } from "./extension-ui.ts";
import { parseAgentActivity, type AgentActivityJob } from "./activity.ts";

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
  | { action: "send_message"; id: string; text: string }
  | { action: "queue_message"; text: string }
  | { action: "clear_queued"; targetId?: string }
  | { action: "cancel"; targetId: string }
  | { action: "sync" }
  | { action: "list_models" }
  | { action: "set_model"; provider: string; modelId: string }
  | { action: "set_thinking"; thinking: string }
  | { action: "compact" }
  | { action: "new_session" };

// Keeps action ids unique within one millisecond: replies are matched by id.
let actionSeq = 0;

export function buildRoomCommand(cmd: RoomCommand): InnerFrame {
  const now = Date.now();
  const actionId = `act_${now}_${++actionSeq}`;
  switch (cmd.action) {
    case "send_message":
      return { type: "user_message", id: cmd.id, text: cmd.text };
    case "queue_message":
      return { type: "queued_message_set", id: `q_${now}`, text: cmd.text };
    case "clear_queued":
      return { type: "queued_message_clear", id: `cq_${now}`, target_id: cmd.targetId };
    case "cancel":
      return { type: "cancel", id: `can_${now}`, target_id: cmd.targetId };
    case "sync":
      return { type: "session_sync", id: `sync_${now}`, limit: 1000 };
    case "list_models":
      return { type: "list_models", id: actionId };
    case "set_model":
      return { type: "model_set", id: actionId, provider: cmd.provider, model_id: cmd.modelId };
    case "set_thinking":
      return { type: "thinking_set", id: actionId, level: cmd.thinking };
    case "compact":
      return { type: "session_compact", id: actionId };
    case "new_session":
      return { type: "session_new", id: actionId };
  }
}

// ── typed actions (quick actions sheet; the app's ActionsRepository) ────────

/** One `models_list` row (pi-extension protocol/types.ts `WireModel`). */
export interface WireModel {
  id: string;
  name: string;
  provider: string;
  reasoning: boolean;
  context_window: number;
  vision: boolean;
  thinking_levels?: string[];
}

export interface ModelsCatalogue {
  models: WireModel[];
  current: WireModel | null;
}

function parseWireModel(raw: unknown): WireModel | null {
  if (!raw || typeof raw !== "object") return null;
  const m = raw as Record<string, unknown>;
  if (typeof m.id !== "string" || typeof m.provider !== "string") return null;
  return {
    id: m.id,
    name: typeof m.name === "string" && m.name ? m.name : m.id,
    provider: m.provider,
    reasoning: m.reasoning === true,
    context_window: typeof m.context_window === "number" ? m.context_window : 0,
    vision: m.vision === true,
    ...(Array.isArray(m.thinking_levels)
      ? { thinking_levels: m.thinking_levels.filter((l): l is string => typeof l === "string") }
      : {}),
  };
}

/** `models_list` → the picker's catalogue (`current` is the model the Pi uses now). */
export function parseModelsList(frame: Record<string, unknown>): ModelsCatalogue | null {
  if (frame.type !== "models_list" || !Array.isArray(frame.models)) return null;
  return {
    models: frame.models.map(parseWireModel).filter((m): m is WireModel => m !== null),
    current: parseWireModel(frame.current),
  };
}

const ALL_THINKING_LEVELS = ["auto", "off", "minimal", "low", "medium", "high", "xhigh", "max"];

/**
 * Thinking levels the sheet offers for `model`: its `thinking_levels` when the
 * Pi sent them, else every level (app QuickActionsViewModel.supportedThinkingLevels).
 */
export function thinkingChoices(model: WireModel | null): string[] {
  const levels = model?.thinking_levels;
  return levels && levels.length > 0 ? levels : ALL_THINKING_LEVELS;
}

/**
 * The reply a typed action waits for: `action_ok` / `models_list`, or the
 * failure an `action_error` (or an `error` for `list_models`) carries.
 */
export type ActionReply =
  | { inReplyTo: string; ok: true; frame: Record<string, unknown> }
  | { inReplyTo: string; ok: false; error: string };

export function actionReplyFromFrame(frame: Record<string, unknown>): ActionReply | null {
  const inReplyTo = typeof frame.in_reply_to === "string" ? frame.in_reply_to : null;
  if (!inReplyTo) return null;
  switch (frame.type) {
    case "action_ok":
    case "models_list":
      return { inReplyTo, ok: true, frame };
    case "action_error":
      return { inReplyTo, ok: false, error: typeof frame.error === "string" && frame.error ? frame.error : "action failed" };
    case "error":
      return { inReplyTo, ok: false, error: typeof frame.message === "string" && frame.message ? frame.message : String(frame.code ?? "error") };
    default:
      return null;
  }
}

/** Same budget as the app's ActionsRepository. */
export const ACTION_TIMEOUT_MS = 15_000;

/** The typed actions the quick actions sheet sends. */
export type RoomAction = Extract<RoomCommand, { action: "list_models" | "set_model" | "set_thinking" | "compact" | "new_session" }>;

/**
 * Sends one typed action to `(peer, room)` and resolves with its reply frame,
 * or rejects with the Pi's error text (`action_error`), "timeout", or
 * "Not connected" — never silently, so the UI can surface every failure.
 */
export function requestRoomAction(
  conn: Pick<RelayConnection, "onInner" | "sendInner">,
  peer: string,
  room: string,
  cmd: RoomAction,
  timeoutMs = ACTION_TIMEOUT_MS
): Promise<Record<string, unknown>> {
  const frame = buildRoomCommand(cmd);
  const id = frame.id as string;
  const wantPeer = toStandardB64(peer);
  const { promise, resolve, reject } = Promise.withResolvers<Record<string, unknown>>();
  const timer = setTimeout(() => {
    unsubscribe();
    reject(new Error("timeout"));
  }, timeoutMs);
  const unsubscribe = conn.onInner((fromPeer, fromRoom, inner) => {
    if (toStandardB64(fromPeer) !== wantPeer || fromRoom !== room) return;
    const reply = actionReplyFromFrame(inner);
    if (!reply || reply.inReplyTo !== id) return;
    unsubscribe();
    clearTimeout(timer);
    if (reply.ok) resolve(reply.frame);
    else reject(new Error(reply.error));
  });
  if (!conn.sendInner(peer, room, frame)) {
    unsubscribe();
    clearTimeout(timer);
    reject(new Error("Not connected"));
  }
  return promise;
}

/** `skills_list` → the Pi's live skills, for the slash menu. */
export interface WireSkill {
  name: string;
  description: string;
}

export function parseSkillsList(frame: Record<string, unknown>): WireSkill[] | null {
  if (frame.type !== "skills_list" || !Array.isArray(frame.skills)) return null;
  return frame.skills.flatMap((raw) => {
    if (!raw || typeof raw !== "object") return [];
    const s = raw as Record<string, unknown>;
    if (typeof s.name !== "string" || !s.name) return [];
    return [{ name: s.name, description: typeof s.description === "string" ? s.description : "" }];
  });
}

// ── chat client bound to one (PC, room) over the shared relay link ──────────

/** Callbacks a chat view registers when it binds a client to its room. */
export interface ChatClientEvents {
  onPresenceChange?: (presence: PeerPresence) => void;
  /** Chat timeline frames (history, user, chunks, tools, final text), folded by chat-stream.ts. */
  onChatEvent?: (event: ChatEvent) => void;
  /** Plan/57 — interactive prompt (ask_user / plan review) or its notify dismiss. */
  onExtensionUiRequest?: (req: ExtensionUiRequest) => void;
  /** `skills_list` (sent after every session_sync): the Pi's skills for the slash menu. */
  onSkills?: (skills: WireSkill[]) => void;
  onQueuedState?: (items: Array<{ id: string; text: string; editable?: boolean }>) => void;
  /** Full `agent_activity` snapshot: replaces the panel's rows. */
  onActivity?: (jobs: AgentActivityJob[]) => void;
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
    const chat = chatEventFromFrame(msg, Date.now());
    if (chat) this.events.onChatEvent?.(chat);
    switch (msg.type) {
      case "agent_chunk":
      case "tool_request":
        this.events.onPresenceChange?.("working");
        break;

      // A prompt echo starts the turn (app: UserInput → _setWorking(true));
      // a steer joins the running turn instead.
      case "user_input":
      case "user_message":
        if (msg.streaming_behavior !== "steer") this.events.onPresenceChange?.("working");
        break;

      // The turn is over: `error` and `cancelled` stop it like `agent_done`
      // (app: _setWorking(false)); `bye` means the Pi itself went away.
      case "agent_message":
      case "agent_done":
      case "error":
      case "cancelled":
        this.events.onPresenceChange?.("online");
        break;

      case "bye":
        this.events.onPresenceChange?.("offline");
        break;

      case "skills_list": {
        const skills = parseSkillsList(msg);
        if (skills) this.events.onSkills?.(skills);
        break;
      }

      case "extension_ui_request": {
        const req = parseExtensionUiRequest(msg);
        if (req) this.events.onExtensionUiRequest?.(req);
        break;
      }

      case "queued_message_state":
        if (Array.isArray(msg.items)) {
          this.events.onQueuedState?.(msg.items as Array<{ id: string; text: string; editable?: boolean }>);
        } else if (typeof msg.text === "string" && msg.text) {
          this.events.onQueuedState?.([{ id: (msg.id as string) || "q1", text: msg.text, editable: true }]);
        } else {
          this.events.onQueuedState?.([]);
        }
        break;

      case "agent_activity": {
        const jobs = parseAgentActivity(msg);
        if (jobs) this.events.onActivity?.(jobs);
        break;
      }
    }
  }

  public requestSync(): void {
    this.send(buildRoomCommand({ action: "sync" }));
  }

  /**
   * Sends `text` and returns the optimistic bubble for it. Both carry the same
   * id, so the Pi's `user_message` echo (and a history resync) confirms that
   * bubble instead of adding a second one.
   */
  public sendMessage(text: string): WebChatMessage {
    const now = Date.now();
    const id = `cli_${now}`;
    this.send(buildRoomCommand({ action: "send_message", id, text }));
    return { id, role: "user", text, timestamp: now, status: "sending" };
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
