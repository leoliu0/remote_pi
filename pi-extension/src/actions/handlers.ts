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
  /** Per-model thinking map (upstream pi ≥0.84). Missing keys = provider
   *  default (supported); an explicit `null` marks the level unsupported. */
  thinkingLevelMap?: Partial<Record<string, string | null>> | null;
  /** omp-only thinking metadata; `efforts` are the levels the model accepts,
   *  in omp's order. Upstream pi models never carry this key. */
  thinking?: { efforts?: readonly string[] } | null;
}

/** All upstream-pi wire thinking levels in picker order. */
const ALL_THINKING_LEVELS: ThinkingLevel[] = [
  "auto", "off", "minimal", "low", "medium", "high", "xhigh", "max",
];
/** omp's effort ladder (`Effort` in omp's catalog); `efforts` only hold these. */
const OMP_EFFORTS: readonly ThinkingLevel[] = [
  "minimal", "low", "medium", "high", "xhigh", "max",
];
export const PROVIDER_ALIASES: Record<string, string[]> = {
  openai: ["openai", "openai-codex"],
  "openai-codex": ["openai-codex", "openai"],
  google: ["google-antigravity", "google", "gemini"],
  "google-antigravity": ["google", "gemini", "google-antigravity"],
  gemini: ["google-antigravity", "google", "gemini"],
  anthropic: ["anthropic-oauth", "anthropic"],
  "anthropic-oauth": ["anthropic", "anthropic-oauth"],
  xai: ["xai-oauth", "xai"],
  "xai-oauth": ["xai", "xai-oauth"],
  kimi: ["kimi-coding", "kimi-code", "moonshotai", "kimi"],
  "kimi-coding": ["kimi-code", "moonshotai", "kimi", "kimi-coding"],
  "kimi-code": ["kimi-coding", "moonshotai", "kimi", "kimi-code"],
};

/** Levels the host lets the user pick for `model`; non-reasoning → ["off"].
 *
 *  omp (`omp`): exactly omp's `getAvailableEffortSelectors()`, the list its
 *  Shift+Tab cycle and `/effort` walk — `["off", "auto", ...thinking.efforts]`
 *  in that order (a model without `thinking` gets `["off", "auto"]`).
 *
 *  upstream pi: pi-ai's `getSupportedThinkingLevels` plus `"auto"` first —
 *  a level mapped to `null` is unsupported, "xhigh"/"max" need an explicit
 *  non-null mapping, the standard levels are supported by default. */
export function supportedThinkingLevels(
  model: Pick<SdkModelLike, "reasoning" | "thinkingLevelMap" | "thinking">,
  omp: boolean = model.thinking !== undefined,
): ThinkingLevel[] {
  if (!model.reasoning) return ["off"];
  if (omp) {
    const efforts = model.thinking?.efforts ?? [];
    return [
      "off",
      "auto",
      ...efforts.filter((e): e is ThinkingLevel => OMP_EFFORTS.includes(e as ThinkingLevel)),
    ];
  }
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
import { existsSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

const _nodeRequire = createRequire(import.meta.url);

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
                // Rows are omp's own registry cache: always the omp rule.
                models.push(wireFromModel({ ...m, provider: m.provider || row.provider_id }, true));
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
  /** `"auto"` is omp's native auto mode; `undefined` clears upstream pi's
   * override (its `thinkingLevel?: Effort` state member). */
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
 *  and the `current` echo, so both stay in lockstep. `omp` selects omp's
 *  thinking-level rule (see `supportedThinkingLevels`); callers holding the
 *  whole catalog pass the host-wide answer. */
export function wireFromModel(
  model: Model<any>,
  omp: boolean = model?.thinking !== undefined,
): WireModel {
  const reasoning = Boolean(model?.reasoning);
  const levels = supportedThinkingLevels(
    { reasoning, thinkingLevelMap: model?.thinkingLevelMap, thinking: model?.thinking },
    omp,
  );
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
  nativeAuto: boolean,
  onThinkingChanged?: (level: ThinkingLevel) => void,
): void {
  runSync(sender, msg, "thinking_set", () => {
    // omp has a native "auto" thinking mode (footer shows "auto", then the
    // level it picks per prompt). Upstream pi has none: its runtime
    // `state.thinkingLevel?: Effort` stores `undefined` for "no override",
    // and an unknown level would be clamped to the lowest supported one.
    // omp treats `undefined` as a concrete level (its footer shows "off").
    pi.setThinkingLevel(msg.level === "auto" && !nativeAuto ? undefined : msg.level);
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

    const candidates: SdkModelLike[] = [];
    const addCandidate = (m: SdkModelLike | undefined | null) => {
      if (!m) return;
      if (!candidates.some((c) => c.provider.toLowerCase() === m.provider.toLowerCase() && c.id.toLowerCase() === m.id.toLowerCase())) {
        candidates.push(m);
      }
    };

    const targetProvider = msg.provider.toLowerCase();
    const targetModelId = msg.model_id.toLowerCase();
    const aliases = PROVIDER_ALIASES[targetProvider] ?? [targetProvider];

    // 1. Available (authenticated) models matching exact targetProvider first
    if (typeof anyReg.getAvailable === "function") {
      try {
        const available: SdkModelLike[] = anyReg.getAvailable();
        for (const m of available) {
          if (m.provider.toLowerCase() === targetProvider && m.id.toLowerCase() === targetModelId) {
            addCandidate(m);
          }
        }
        for (const m of available) {
          if (aliases.includes(m.provider.toLowerCase()) && m.id.toLowerCase() === targetModelId) {
            addCandidate(m);
          }
        }
      } catch {}
    }
    // 2. Direct registry find
    try {
      addCandidate(liveReg.find(msg.provider, msg.model_id));
    } catch {}

    // 3. Provider alias finds (skip targetProvider since step 2 already did it)
    for (const alias of aliases) {
      if (alias.toLowerCase() === targetProvider) continue;
      try {
        addCandidate(liveReg.find(alias, msg.model_id));
      } catch {}
    }
    // 4. Registry getAll search: exact provider first, then aliases
    if (typeof anyReg.getAll === "function") {
      try {
        const all: SdkModelLike[] = anyReg.getAll();
        for (const m of all) {
          if (m.provider.toLowerCase() === targetProvider && m.id.toLowerCase() === targetModelId) {
            addCandidate(m);
          }
        }
        for (const m of all) {
          const providerMatches =
            aliases.includes(m.provider.toLowerCase()) ||
            (targetProvider === "google" && m.provider === "gemini") ||
            (targetProvider === "gemini" && m.provider === "google");
          const idMatches =
            m.id.toLowerCase() === targetModelId ||
            m.id.toLowerCase().includes(targetModelId) ||
            targetModelId.includes(m.id.toLowerCase());
          if (providerMatches && idMatches) {
            addCandidate(m);
          }
        }
      } catch {}
    }

    // 5. Fallback from omp models
    if (process.env["VITEST"] !== "true") {
      const ompModels = _loadOmpModels();
      const match =
        ompModels.find(
          (m) =>
            m.provider.toLowerCase() === targetProvider &&
            (m.id.toLowerCase() === targetModelId ||
              m.name.toLowerCase() === targetModelId ||
              m.id.toLowerCase().includes(targetModelId)),
        ) ??
        ompModels.find(
          (m) =>
            (aliases.includes(m.provider.toLowerCase()) ||
              m.provider.toLowerCase().replace(/-/g, "") === targetProvider.replace(/-/g, "")) &&
            (m.id.toLowerCase() === targetModelId ||
              m.name.toLowerCase() === targetModelId ||
              m.id.toLowerCase().includes(targetModelId)),
        );
      if (match) {
        addCandidate({
          id: match.id,
          name: match.name || match.id,
          provider: match.provider,
          api: match.provider.includes("anthropic")
            ? "anthropic-messages"
            : match.provider.includes("google")
              ? "google-generative-ai"
              : match.provider.includes("codex")
                ? "openai-codex-responses"
                : "openai-completions",
          reasoning: !!match.reasoning,
          input: (match as any).input || ["text", "image"],
          contextWindow: match.context_window || 200000,
          maxTokens: (match as any).max_tokens || 8192,
        } as SdkModelLike);
      }
    }

    if (candidates.length === 0) {
      throw new Error(`model "${msg.provider}/${msg.model_id}" not in registry`);
    }

    let selectedModel: SdkModelLike | undefined;
    let lastError: Error | undefined;

    for (const candidate of candidates) {
      try {
        const success = await pi.setModel(candidate);
        if (success) {
          selectedModel = candidate;
          break;
        }
      } catch (err: any) {
        lastError = err instanceof Error ? err : new Error(String(err));
      }
    }

    if (!selectedModel) {
      if (lastError) throw lastError;
      throw new Error("no auth configured for this model");
    }
    const model = selectedModel;
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
    let regModels: SdkModelLike[] = [];
    try {
      regModels =
        (typeof anyReg.getAvailable === "function"
          ? anyReg.getAvailable()
          : typeof anyReg.getAll === "function"
            ? anyReg.getAll()
            : []) ?? [];
    } catch {}
    let current: SdkModelLike | undefined;
    try {
      current = ctx?.getModel?.();
    } catch {}
    // omp models carry `thinking`, upstream pi models never do. Decide per
    // catalog: some omp reasoning models (xai/grok-4) lack the key yet still
    // get omp's ["off", "auto"].
    const omp = [...regModels, current].some((m) => m?.thinking !== undefined);
    let models: WireModel[] = [];
    try {
      models = regModels.map((m) => wireFromModel(m, omp));
    } catch {}

    if (process.env["VITEST"] !== "true") {
      const ompModels = _loadOmpModels();
      if (ompModels.length > 0) {
        const knownIds = new Set(models.map((m) => m.id.toLowerCase()));
        for (const om of ompModels) {
          if (!knownIds.has(om.id.toLowerCase())) {
            models.push(om);
            knownIds.add(om.id.toLowerCase());
          }
        }
      }
    }

    let currentWire: WireModel | undefined = current ? wireFromModel(current, omp) : undefined;
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
      // Name only, no model metadata: the levels are unknown, so omit
      // `thinking_levels` (clients then offer every level).
      const parts = currentModelName.split("/");
      const provider = parts.length > 1 ? parts[0] : "unknown";
      const id = parts.length > 1 ? parts.slice(1).join("/") : parts[0];
      const reasoning =
        /gemini|claude|gpt-4|gpt-5|k3|deepseek|qwen|o1|o3|r1/i.test(currentModelName);
      currentWire = {
        provider,
        id,
        name: currentModelName,
        reasoning,
        context_window: 200000,
        vision: false,
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
