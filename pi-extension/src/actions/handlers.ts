/**
 * Plan/28 Wave B — typed action handlers.
 *
 * Each handler maps one `ClientMessage` action to a public Pi SDK call,
 * and replies with `action_ok` or `action_error`. Handlers take their
 * dependencies as parameters so the index.ts wiring is one-liner and
 * unit tests can pass fakes without touching global state.
 *
 * `models_list` lives next door because it shares the `ModelRegistry`
 * helper and the same wire vocabulary.
 *
 * SDK API surface used (see plan/28 Wave 0 for the full table):
 *
 *   - `ctx.compact()`            — non-blocking, fires `session_compact`
 *                                  event when done
 *   - `ctx.newSession()`         — only on `ExtensionCommandContext`;
 *                                  resolves with `{cancelled}` flag
 *   - `pi.setModel(model)`       — returns `false` if no auth configured
 *   - `pi.setThinkingLevel(lvl)` — synchronous
 *   - `ctx.getModel()`           — optional, undefined before first turn
 *   - `ModelRegistry.{refresh,getAvailable,find}` — see `registry.ts`
 */

import type {
  ClientMessage,
  ServerMessage,
  WireModel,
  ActionName,
  ThinkingLevel,
} from "../protocol/types.js";
/**
 * Structural subset of the SDK's `Model<Api>` interface (defined in
 * `@earendil-works/pi-ai`, which is a transitive dep — not re-exported by
 * `@earendil-works/pi-coding-agent`'s main entry). Capturing just the
 * fields we touch keeps the handler decoupled from the SDK's full Model
 * surface and avoids a direct dep on `pi-ai`.
 */
export interface SdkModelLike {
  id: string;
  name: string;
  provider: string;
  reasoning: boolean;
  contextWindow: number;
  /** Plan/30: accepted input modalities. The SDK's `Model.input` is
   *  `("text" | "image")[]`; we read `includes("image")` for the `vision`
   *  flag. Optional here so tests can omit it (treated as text-only). */
  input?: ("text" | "image")[];
  /** Per-model thinking map (pi ≥0.84). Missing keys = provider default
   *  (supported); an explicit `null` marks the level unsupported. */
  thinkingLevelMap?: Partial<Record<string, string | null>>;
}

/** All wire thinking levels in picker order. */
const ALL_THINKING_LEVELS: ThinkingLevel[] = [
  "auto", "off", "minimal", "low", "medium", "high", "xhigh", "max",
];

/** Levels a model supports, matching Pi-AI's getSupportedThinkingLevels:
 *  - non-reasoning models only support ["off"]
 *  - reasoning models support ["auto", ...]
 *  - levels explicitly mapped to null are unsupported (e.g. "off": null in Gemini 3.7 Flash)
 *  - "xhigh" and "max" require an explicit non-null mapping in thinkingLevelMap
 *  - standard levels ("off", "minimal", "low", "medium", "high") are supported by default
 */
export function supportedThinkingLevels(
  model: Pick<SdkModelLike, "reasoning" | "thinkingLevelMap">,
): ThinkingLevel[] {
  if (!model.reasoning) return ["off"];
  const map = model.thinkingLevelMap;
  return ALL_THINKING_LEVELS.filter((level) => {
    if (level === "auto") return true;
    const mapped = map?.[level];
    if (mapped === null) return false;
    if (level === "xhigh" || level === "max") return mapped !== undefined;
    return true;
  });
}
import { createRequire } from "node:module";
import { existsSync, readdirSync, readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

const _nodeRequire = createRequire(import.meta.url);

let _cachedBuiltinMaps: Map<string, Partial<Record<string, string | null>>> | null = null;

function _loadBuiltinThinkingMaps(): Map<string, Partial<Record<string, string | null>>> {
  if (_cachedBuiltinMaps) return _cachedBuiltinMaps;
  const maps = new Map<string, Partial<Record<string, string | null>>>();
  try {
    const candidates = [
      "/home/leo/.npm-global/lib/node_modules/@earendil-works/pi-coding-agent/node_modules/@earendil-works/pi-ai/dist/providers/data",
      join(homedir(), ".npm-global", "lib", "node_modules", "@earendil-works", "pi-coding-agent", "node_modules", "@earendil-works", "pi-ai", "dist", "providers", "data"),
    ];
    for (const p of candidates) {
      if (existsSync(p)) {
        for (const file of readdirSync(p)) {
          if (!file.endsWith(".json")) continue;
          try {
            const content = JSON.parse(readFileSync(join(p, file), "utf8")) as Record<string, unknown>;
            for (const val of Object.values(content)) {
              if (val && typeof val === "object") {
                for (const [mid, m] of Object.entries(val as Record<string, unknown>)) {
                  if (m && typeof m === "object" && (m as { thinkingLevelMap?: unknown }).thinkingLevelMap) {
                    const tmap = (m as { thinkingLevelMap: Partial<Record<string, string | null>> }).thinkingLevelMap;
                    maps.set(mid.toLowerCase(), tmap);
                    if (mid.includes("/")) {
                      maps.set(mid.split("/").pop()!.toLowerCase(), tmap);
                    }
                  }
                }
              }
            }
          } catch {}
        }
        break;
      }
    }
  } catch {}
  _cachedBuiltinMaps = maps;
  return maps;
}

export function _resolveThinkingLevelMap(
  id?: string,
  provider?: string,
  explicitMap?: Partial<Record<string, string | null>>,
): Partial<Record<string, string | null>> | undefined {
  if (explicitMap) return explicitMap;
  const cleanId = (id || "").toLowerCase();
  const cleanBase = cleanId.includes("/") ? cleanId.split("/").pop()! : cleanId;
  const builtin = _loadBuiltinThinkingMaps();
  return builtin.get(cleanId) || builtin.get(cleanBase);
}

export function _loadOmpModels(): WireModel[] {
  const models: WireModel[] = [];
  try {
    const home = homedir();
    const dbPath = join(home, ".omp", "agent", "models.db");
    if (existsSync(dbPath)) {
      let DatabaseSync: (new (path: string) => {
        prepare: (sql: string) => {
          all: () => Array<{ provider_id: string; models: string }>;
        };
      }) | undefined;
      try {
        DatabaseSync = _nodeRequire("node:sqlite").DatabaseSync;
      } catch {}
      if (DatabaseSync) {
        const db = new DatabaseSync(dbPath);
        const rows = db.prepare("SELECT provider_id, models FROM model_cache").all();
        for (const row of rows) {
          try {
            const list = JSON.parse(row.models);
            if (Array.isArray(list)) {
              for (const m of list) {
                if (!m || typeof m !== "object") continue;
                const reasoning = Boolean(m.reasoning || m.thinking);
                const thinkingLevelMap = _resolveThinkingLevelMap(
                  m.id,
                  m.provider || row.provider_id,
                  m.thinkingLevelMap as Partial<Record<string, string | null>> | undefined,
                );
                const levels = supportedThinkingLevels({
                  reasoning,
                  thinkingLevelMap,
                });
                models.push({
                  id: m.id || "unknown",
                  name: m.name || m.id || "unknown",
                  provider: m.provider || row.provider_id || "unknown",
                  reasoning,
                  context_window: typeof m.contextWindow === "number" ? m.contextWindow : 128000,
                  vision: Boolean(m.input && Array.isArray(m.input) && m.input.includes("image")),
                  thinking_levels: levels,
                });
              }
            }
          } catch {}
        }
      }
    }
  } catch {}
  return models;
}
// `Model` is the alias used throughout the file. Real SDK models structurally
// satisfy this — `pi.setModel(model)` accepts them because TypeScript
// validates structurally at the call site (the SDK's full Model has more
// fields than we declare here, which is fine for an input parameter).
type Model<_TApi = unknown> = SdkModelLike;

/**
 * Minimal channel surface needed to reply. Mirrors `PlainPeerChannel`'s
 * `.send` signature; tests pass an array-backed fake.
 */
export interface ActionReplySender {
  send(msg: ServerMessage): void;
}

/**
 * Narrow shape of the `ExtensionAPI` surface action handlers actually
 * call. Lets the test layer stub just these without rebuilding the full
 * SDK type (which has 30+ methods we don't use here).
 */
export interface ActionPi {
  setModel(model: Model<any>): Promise<boolean>;
  /** `undefined` clears the override ("auto") — the SDK's
   * `thinkingLevel?: Effort` state member. */
  setThinkingLevel(level: ThinkingLevel | undefined): void;
}

/**
 * Narrow shape of the per-call context. Drawn from the union of
 * `ExtensionContextActions` (compact, getModel) and
 * `ExtensionCommandContextActions` (newSession), since index.ts caches
 * the most-recent ctx and that's typically the command one.
 *
 * All fields are optional so a missing method (e.g. when only a plain
 * `ExtensionContext` was seen) becomes a typed `action_error` instead of
 * a runtime TypeError.
 */
export interface ActionCtx {
  compact?: (options?: object) => void;
  /**
   * Starts a new session. `withSession` is the SDK's blessed hook for
   * post-replacement work: it receives a FRESH, command-capable ctx bound to
   * the new session. The SDK marks any ctx captured BEFORE this call stale, so
   * callers must re-capture via `withSession` rather than reuse the old ctx.
   */
  newSession?: (options?: {
    withSession?: (ctx: ActionCtx) => Promise<void>;
  }) => Promise<{ cancelled: boolean }>;
  getModel?: () => Model<any> | undefined;
  /**
   * Live session registry from Pi's extension ctx. Includes providers/models
   * registered dynamically via `pi.registerProvider(...)`, unlike the fallback
   * disk-backed registry remote-pi can build on its own.
   */
  modelRegistry?: ActionModelRegistry;
}

/**
 * Minimal shape of the registry surface. Maps 1:1 onto `ModelRegistry`
 * but lets tests fake catalogs without instantiating the real one.
 */
export interface ActionModelRegistry {
  refresh(): void;
  getAvailable(): Model<any>[];
  find(provider: string, modelId: string): Model<any> | undefined;
}

/** Project a SDK `Model<Api>` onto the wire schema. Shared by list_models
 *  and the `current` echo, so both stay in lockstep. */
export function wireFromModel(model: Model<any>): WireModel {
  const reasoning = Boolean(model?.reasoning);
  const thinkingLevelMap = _resolveThinkingLevelMap(
    model?.id,
    model?.provider,
    model?.thinkingLevelMap,
  );
  const levels = supportedThinkingLevels({ reasoning, thinkingLevelMap });
  return {
    id: model?.id || "unknown",
    name: model?.name || model?.id || "unknown",
    provider: model?.provider || "unknown",
    reasoning,
    context_window: typeof model?.contextWindow === "number" ? model.contextWindow : 128000,
    vision: Boolean(model?.input && Array.isArray(model.input) && model.input.includes("image")),
    thinking_levels: levels,
  };
}

// ── ack helpers ────────────────────────────────────────────────────────────

function ok(sender: ActionReplySender, msg: { id: string }, action: ActionName): void {
  sender.send({ type: "action_ok", in_reply_to: msg.id, action });
}

function fail(
  sender: ActionReplySender,
  msg: { id: string },
  action: ActionName,
  err: unknown,
): void {
  const error = err instanceof Error ? err.message : String(err);
  sender.send({ type: "action_error", in_reply_to: msg.id, action, error });
}

/** Run a synchronous action with uniform success/failure replies. */
function runSync(
  sender: ActionReplySender,
  msg: { id: string },
  action: ActionName,
  body: () => void,
): void {
  try {
    body();
    ok(sender, msg, action);
  } catch (e) {
    fail(sender, msg, action, e);
  }
}

/** Run an async action with uniform success/failure replies. */
async function runAsync(
  sender: ActionReplySender,
  msg: { id: string },
  action: ActionName,
  body: () => Promise<void>,
): Promise<boolean> {
  try {
    await body();
    ok(sender, msg, action);
    return true;
  } catch (e) {
    fail(sender, msg, action, e);
    return false;
  }
}

// ── individual handlers ───────────────────────────────────────────────────

type SessionCompactMsg = Extract<ClientMessage, { type: "session_compact" }>;
type SessionNewMsg = Extract<ClientMessage, { type: "session_new" }>;
type ModelSetMsg = Extract<ClientMessage, { type: "model_set" }>;
type ThinkingSetMsg = Extract<ClientMessage, { type: "thinking_set" }>;
type ListModelsMsg = Extract<ClientMessage, { type: "list_models" }>;

export function handleSessionCompact(
  ctx: ActionCtx | null,
  sender: ActionReplySender,
  msg: SessionCompactMsg,
): void {
  runSync(sender, msg, "session_compact", () => {
    if (!ctx?.compact) throw new Error("compact unavailable (no active session ctx)");
    // Force the summary to English regardless of the conversation language —
    // the summary is surfaced to the app via the `compaction` message, which
    // is an English-only surface. `customInstructions` is appended to the SDK's
    // compaction prompt (best-effort: the model writes the summary).
    ctx.compact({
      customInstructions:
        "Always write a brief, concise compaction summary in English (1-2 sentences maximum), even if the conversation is in another language.",
    });
  });
}

export async function handleSessionNew(
  ctx: ActionCtx | null,
  sender: ActionReplySender,
  msg: SessionNewMsg,
  onReplaced?: (freshCtx: ActionCtx) => void,
): Promise<boolean> {
  // Returns true only when a fresh session was actually created. index.ts
  // keys the Pi-side reset (clear _messageBuffer, restamp _sessionStartedAt,
  // fan out an empty session_history) off this signal — a `cancelled`/errored
  // new-session must NOT reset, so we return runAsync's success boolean.
  return runAsync(sender, msg, "session_new", async () => {
    if (!ctx?.newSession) throw new Error("newSession unavailable (no command ctx yet)");
    // newSession marks the caller's captured ctx (index.ts's `_lastCtx`) STALE
    // — reusing it later throws "stale after session replacement" (the
    // compact-after-New-session crash). `withSession` hands back a fresh,
    // command-capable ctx bound to the new session; forward it via onReplaced
    // so the caller re-captures and keeps later actions off the stale ctx.
    const result = await ctx.newSession({
      withSession: async (freshCtx) => { onReplaced?.(freshCtx); },
    });
    // `cancelled: true` happens when the SDK's hook chain vetoes the new
    // session (e.g. an extension's `session_before_switch` returned a
    // refusal). Surface as a typed error rather than silent success.
    if (result.cancelled) throw new Error("cancelled by extension hook");
  });
}

export function handleThinkingSet(
  pi: ActionPi,
  sender: ActionReplySender,
  msg: ThinkingSetMsg,
  onThinkingChanged?: (level: ThinkingLevel) => void,
): void {
  runSync(sender, msg, "thinking_set", () => {
    // "auto" = clear the override so the model runs at its native default.
    // The SDK's ThinkingLevel union has no "inherit" member — the type is
    // `"off" | ... | "max"` and the runtime `state.thinkingLevel?: Effort`
    // stores `undefined` for "no override". Passing "inherit" through would
    // fall into clampThinkingLevel's unknown-level branch and snap to the
    // lowest supported level (e.g. "minimal" on Gemini 3.7 Flash).
    pi.setThinkingLevel(msg.level === "auto" ? undefined : msg.level);
    onThinkingChanged?.(msg.level);
  });
}

export async function handleReloadPlugins(
  ctx: ActionCtx | null | undefined,
  sender: ActionReplySender,
  msg: { id: string },
): Promise<void> {
  await runAsync(sender, msg, "reload_plugins", async () => {
    try {
      ctx?.modelRegistry?.refresh();
    } catch {}
    try {
      const anyCtx = ctx as any;
      if (typeof anyCtx?.reloadExtensions === "function") {
        await anyCtx.reloadExtensions();
      } else if (typeof anyCtx?.discoverAndLoadExtensions === "function") {
        await anyCtx.discoverAndLoadExtensions();
      }
    } catch {}
  });
}

export async function handleModelSet(
  pi: ActionPi | null | undefined,
  ctx: ActionCtx | null | undefined,
  reg: ActionModelRegistry,
  sender: ActionReplySender,
  msg: ModelSetMsg,
  onPersist?: (provider: string, modelId: string) => void,
  onModelChanged?: (name: string) => void,
): Promise<void> {
  await runAsync(sender, msg, "model_set", async () => {
    if (!pi || typeof pi.setModel !== "function") {
      throw new Error("Pi agent runtime is not ready to change models");
    }
    const liveReg = ctx?.modelRegistry ?? reg;
    liveReg.refresh();
    const anyReg = liveReg as any;
    let model: SdkModelLike | undefined;
    try {
      model = liveReg.find(msg.provider, msg.model_id);
    } catch {}
    if (!model && typeof anyReg.getAll === "function") {
      try {
        const all: SdkModelLike[] = anyReg.getAll();
        model = all.find(
          (m: SdkModelLike) =>
            (m.provider.toLowerCase() === msg.provider.toLowerCase() ||
              (msg.provider === "google" && m.provider === "gemini") ||
              (msg.provider === "gemini" && m.provider === "google")) &&
            (m.id.toLowerCase() === msg.model_id.toLowerCase() ||
              m.id.toLowerCase().includes(msg.model_id.toLowerCase()) ||
              msg.model_id.toLowerCase().includes(m.id.toLowerCase()))
        );
      } catch {}
    }
    if (!model && process.env["VITEST"] !== "true") {
      const ompModels = _loadOmpModels();
      const match = ompModels.find(
        (m) =>
          (m.provider.toLowerCase() === msg.provider.toLowerCase() ||
            m.provider.toLowerCase().replace(/-/g, "") === msg.provider.toLowerCase().replace(/-/g, "")) &&
          (m.id.toLowerCase() === msg.model_id.toLowerCase() ||
            m.name.toLowerCase() === msg.model_id.toLowerCase() ||
            m.id.toLowerCase().includes(msg.model_id.toLowerCase()))
      );
      if (match) {
        model = {
          id: match.id,
          name: match.name || match.id,
          provider: match.provider,
          api: match.provider.includes("anthropic")
            ? "anthropic-messages"
            : match.provider.includes("google")
              ? "google-generative-ai"
              : "openai-completions",
          reasoning: !!match.reasoning,
          input: (match as any).input || ["text", "image"],
          contextWindow: match.context_window || 200000,
          maxTokens: (match as any).max_tokens || 8192,
        } as SdkModelLike;
      }
    }
    if (!model) {
      throw new Error(`model "${msg.provider}/${msg.model_id}" not in registry`);
    }
    let success = false;
    try {
      success = await pi.setModel(model);
    } catch (err: any) {
      throw new Error(`Failed to set model: ${err?.message || String(err)}`);
    }
    if (!success) throw new Error("no auth configured for this model");
    const friendlyName = model.name ?? model.id;
    try {
      onPersist?.(model.provider, model.id);
    } catch {}
    try {
      onModelChanged?.(friendlyName);
    } catch {}
  });
}

export function handleListModels(
  ctx: ActionCtx | null,
  reg: ActionModelRegistry,
  sender: ActionReplySender,
  msg: ListModelsMsg,
  currentModelName?: string,
): void {
  try {
    const liveReg = ctx?.modelRegistry ?? reg;
    liveReg.refresh();
    const anyReg = liveReg as any;
    let models: WireModel[] = [];
    try {
      const regModels =
        typeof anyReg.getAvailable === "function"
          ? anyReg.getAvailable()
          : typeof anyReg.getAll === "function"
            ? anyReg.getAll()
            : [];
      models = (regModels ?? []).map(wireFromModel);
    } catch {}

    if (process.env["VITEST"] !== "true") {
      const ompModels = _loadOmpModels();
      if (ompModels.length > 0) {
        const known = new Set(models.map((m) => `${m.provider}:${m.id}`));
        for (const om of ompModels) {
          if (!known.has(`${om.provider}:${om.id}`)) {
            models.push(om);
            known.add(`${om.provider}:${om.id}`);
          }
        }
      }
    }

    let current: SdkModelLike | undefined;
    try {
      current = ctx?.getModel?.();
    } catch {}
    let currentWire: WireModel | undefined = current ? wireFromModel(current) : undefined;
    if (!currentWire && currentModelName && models.length > 0) {
      currentWire = models.find(
        (m) =>
          m.name.toLowerCase() === currentModelName.toLowerCase() ||
          m.id.toLowerCase() === currentModelName.toLowerCase() ||
          `${m.provider}/${m.id}`.toLowerCase() === currentModelName.toLowerCase() ||
          `${m.provider}:${m.id}`.toLowerCase() === currentModelName.toLowerCase() ||
          currentModelName.toLowerCase().endsWith(`/${m.id.toLowerCase()}`)
      );
    }
    if (!currentWire && currentModelName) {
      const parts = currentModelName.split("/");
      const provider = parts.length > 1 ? parts[0] : "unknown";
      const id = parts.length > 1 ? parts.slice(1).join("/") : parts[0];
      const thinkingLevelMap = _resolveThinkingLevelMap(id, provider);
      const reasoning =
        Boolean(thinkingLevelMap) ||
        /gemini|claude|gpt-4|gpt-5|k3|deepseek|qwen|o1|o3|r1/i.test(currentModelName);
      const levels = supportedThinkingLevels({ reasoning, thinkingLevelMap });
      currentWire = {
        provider,
        id,
        name: currentModelName,
        reasoning,
        context_window: 200000,
        vision: false,
        thinking_levels: levels,
      };
      models.unshift(currentWire);
    }
    sender.send({
      type: "models_list",
      in_reply_to: msg.id,
      models,
      current: currentWire,
    });
  } catch (e) {
    sender.send({
      type: "error",
      in_reply_to: msg.id,
      code: "internal_error",
      message: e instanceof Error ? e.message : String(e),
    });
  }
}
