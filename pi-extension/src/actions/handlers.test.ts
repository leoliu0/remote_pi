/**
 * Plan/28 Wave B — unit tests for action handlers.
 *
 * Each handler gets:
 *   - happy path → asserts `action_ok` (or `models_list`) shape
 *   - failure path → asserts `action_error` with structured `error` field
 *
 * No global state; everything passes through `ActionPi`/`ActionCtx`/
 * `ActionModelRegistry` interfaces — easy fakes, fast (synchronous where
 * possible).
 */

import { describe, expect, test, vi } from "vitest";
import {
  handleSessionCompact,
  handleSessionNew,
  handleModelSet,
  handleThinkingSet,
  handleListModels,
  wireFromModel,
  type ActionCtx,
  type ActionPi,
  type ActionModelRegistry,
  type SdkModelLike,
} from "./handlers.js";
import type { ServerMessage } from "../protocol/types.js";
import ompCapture from "./omp_thinking.fixture.json" with { type: "json" };

function makeSender() {
  const sent: ServerMessage[] = [];
  return {
    sent,
    send(msg: ServerMessage): void {
      sent.push(msg);
    },
  };
}

function fakePi(overrides: Partial<ActionPi> = {}): ActionPi {
  return {
    setModel: async () => true,
    setThinkingLevel: () => {},
    ...overrides,
  };
}

/** Upstream-pi-shaped model: no omp `thinking` key and no `thinkingLevelMap`,
 *  so pi-ai's rule applies — standard levels only, no "xhigh"/"max". */
const sampleModel: SdkModelLike = {
  id: "claude-opus-4-7",
  name: "Claude Opus 4.7",
  provider: "anthropic",
  reasoning: true,
  contextWindow: 200_000,
};

function fakeRegistry(catalog: SdkModelLike[]): ActionModelRegistry {
  let refreshed = 0;
  return {
    refresh: () => { refreshed += 1; },
    getAvailable: () => catalog,
    find: (provider, modelId) =>
      catalog.find((m) => m.provider === provider && m.id === modelId),
    // expose refresh counter via a closure read for tests that care
    get _refreshes() { return refreshed; },
  } as ActionModelRegistry & { _refreshes: number };
}

// ── session_compact ────────────────────────────────────────────────────────

describe("handleSessionCompact", () => {
  test("calls ctx.compact() with an English-summary instruction and replies action_ok", () => {
    const compactArgs: unknown[] = [];
    const ctx: ActionCtx = { compact: (opts) => { compactArgs.push(opts); } };
    const sender = makeSender();
    handleSessionCompact(ctx, sender, { type: "session_compact", id: "r1" });
    expect(compactArgs).toHaveLength(1);
    // The summary must be forced to English (surfaced via the `compaction` msg).
    expect(JSON.stringify(compactArgs[0])).toMatch(/English/i);
    expect(sender.sent).toEqual([
      { type: "action_ok", in_reply_to: "r1", action: "session_compact" },
    ]);
  });

  test("returns action_error when ctx is null", () => {
    const sender = makeSender();
    handleSessionCompact(null, sender, { type: "session_compact", id: "r1" });
    expect(sender.sent).toHaveLength(1);
    expect(sender.sent[0]).toMatchObject({
      type: "action_error",
      in_reply_to: "r1",
      action: "session_compact",
      error: expect.stringContaining("compact unavailable"),
    });
  });

  test("returns action_error when ctx.compact throws", () => {
    const ctx: ActionCtx = { compact: () => { throw new Error("boom"); } };
    const sender = makeSender();
    handleSessionCompact(ctx, sender, { type: "session_compact", id: "r1" });
    expect(sender.sent[0]).toMatchObject({
      type: "action_error",
      error: "boom",
    });
  });
});

// ── session_new ────────────────────────────────────────────────────────────

describe("handleSessionNew", () => {
  test("happy path → action_ok + returns true (drives Pi-side reset)", async () => {
    const ctx: ActionCtx = { newSession: async () => ({ cancelled: false }) };
    const sender = makeSender();
    const created = await handleSessionNew(ctx, sender, { type: "session_new", id: "r2" });
    expect(created).toBe(true);
    expect(sender.sent).toEqual([
      { type: "action_ok", in_reply_to: "r2", action: "session_new" },
    ]);
  });

  test("cancelled by extension hook → action_error + returns false (no reset)", async () => {
    const ctx: ActionCtx = { newSession: async () => ({ cancelled: true }) };
    const sender = makeSender();
    const created = await handleSessionNew(ctx, sender, { type: "session_new", id: "r2" });
    expect(created).toBe(false);
    expect(sender.sent[0]).toMatchObject({
      type: "action_error",
      action: "session_new",
      error: expect.stringContaining("cancelled"),
    });
  });

  test("ctx without newSession → action_error + returns false (no reset)", async () => {
    const sender = makeSender();
    const created = await handleSessionNew({}, sender, { type: "session_new", id: "r2" });
    expect(created).toBe(false);
    expect(sender.sent[0]).toMatchObject({
      type: "action_error",
      error: expect.stringContaining("newSession unavailable"),
    });
  });

  test("re-captures the fresh withSession ctx via onReplaced (avoids stale ctx)", async () => {
    // Simulate the SDK invoking withSession with a fresh, command-capable ctx
    // bound to the replacement session — exactly what makes the captured ctx
    // stale. handleSessionNew must forward that fresh ctx to onReplaced.
    const freshCtx: ActionCtx = {
      compact: () => undefined,
      newSession: async () => ({ cancelled: false }),
    };
    const ctx: ActionCtx = {
      newSession: async (opts) => {
        await opts?.withSession?.(freshCtx);
        return { cancelled: false };
      },
    };
    const sender = makeSender();
    let recaptured: ActionCtx | null = null;
    const created = await handleSessionNew(
      ctx,
      sender,
      { type: "session_new", id: "r2" },
      (c) => { recaptured = c; },
    );
    expect(created).toBe(true);
    expect(recaptured).toBe(freshCtx);
  });
});

// ── thinking_set ───────────────────────────────────────────────────────────

describe("handleThinkingSet", () => {
  test("forwards level to pi.setThinkingLevel and replies action_ok", () => {
    const calls: string[] = [];
    const pi = fakePi({ setThinkingLevel: (lvl) => { calls.push(lvl); } });
    const sender = makeSender();
    handleThinkingSet(pi, sender, { type: "thinking_set", id: "r3", level: "high" }, true);
    expect(calls).toEqual(["high"]);
    expect(sender.sent).toEqual([
      { type: "action_ok", in_reply_to: "r3", action: "thinking_set" },
    ]);
  });

  test("upstream pi: auto clears the override (undefined) on pi.setThinkingLevel", () => {
    const calls: (string | undefined)[] = [];
    const pi = fakePi({ setThinkingLevel: (lvl) => { calls.push(lvl); } });
    const sender = makeSender();
    handleThinkingSet(pi, sender, { type: "thinking_set", id: "r3", level: "auto" }, false);
    expect(calls).toEqual([undefined]);
    expect(sender.sent).toEqual([
      { type: "action_ok", in_reply_to: "r3", action: "thinking_set" },
    ]);
  });

  test("omp: auto selects omp's native auto mode (undefined renders as \"off\" in its footer)", () => {
    const calls: (string | undefined)[] = [];
    const pi = fakePi({ setThinkingLevel: (lvl) => { calls.push(lvl); } });
    const sender = makeSender();
    handleThinkingSet(pi, sender, { type: "thinking_set", id: "r4", level: "auto" }, true);
    expect(calls).toEqual(["auto"]);
    expect(sender.sent).toEqual([
      { type: "action_ok", in_reply_to: "r4", action: "thinking_set" },
    ]);
  });

  test("setThinkingLevel throwing surfaces as action_error", () => {
    const pi = fakePi({ setThinkingLevel: () => { throw new Error("nope"); } });
    const sender = makeSender();
    handleThinkingSet(pi, sender, { type: "thinking_set", id: "r3", level: "low" }, true);
    expect(sender.sent[0]).toMatchObject({
      type: "action_error",
      action: "thinking_set",
      error: "nope",
    });
  });
});

// ── model_set ──────────────────────────────────────────────────────────────

describe("handleModelSet", () => {
  test("happy path → refreshes, looks up, sets, action_ok", async () => {
    const reg = fakeRegistry([sampleModel]);
    const setModelArgs: SdkModelLike[] = [];
    const pi = fakePi({
      setModel: async (m) => { setModelArgs.push(m as SdkModelLike); return true; },
    });
    const sender = makeSender();
    await handleModelSet(pi, null, reg, sender, {
      type: "model_set", id: "r4", provider: "anthropic", model_id: "claude-opus-4-7",
    });
    expect(setModelArgs).toHaveLength(1);
    expect(setModelArgs[0].id).toBe("claude-opus-4-7");
    expect(sender.sent[0]).toMatchObject({
      type: "action_ok", action: "model_set",
    });
  });

  test("unknown model → action_error", async () => {
    const reg = fakeRegistry([sampleModel]);
    const sender = makeSender();
    await handleModelSet(fakePi(), null, reg, sender, {
      type: "model_set", id: "r4", provider: "anthropic", model_id: "nope-3",
    });
    expect(sender.sent[0]).toMatchObject({
      type: "action_error",
      error: expect.stringContaining("not in registry"),
    });
  });

  test("setModel returning false (no auth) → action_error", async () => {
    const reg = fakeRegistry([sampleModel]);
    const pi = fakePi({ setModel: async () => false });
    const sender = makeSender();
    await handleModelSet(pi, null, reg, sender, {
      type: "model_set", id: "r4", provider: "anthropic", model_id: "claude-opus-4-7",
    });
    expect(sender.sent[0]).toMatchObject({
      type: "action_error",
      error: expect.stringContaining("no auth configured"),
    });
  });

  test("persists the change via onPersist after a successful live set", async () => {
    const reg = fakeRegistry([sampleModel]);
    const pi = fakePi({ setModel: async () => true });
    const sender = makeSender();
    const persisted: Array<{ provider: string; modelId: string }> = [];
    await handleModelSet(
      pi, null, reg, sender,
      { type: "model_set", id: "r4", provider: "anthropic", model_id: "claude-opus-4-7" },
      (provider, modelId) => persisted.push({ provider, modelId }),
    );
    // onPersist receives the resolved model's provider/id so it survives restart.
    expect(persisted).toEqual([{ provider: "anthropic", modelId: "claude-opus-4-7" }]);
  });

  test("does NOT persist when the live set fails (no auth)", async () => {
    const reg = fakeRegistry([sampleModel]);
    const pi = fakePi({ setModel: async () => false });
    const sender = makeSender();
    let persistCalls = 0;
    await handleModelSet(
      pi, null, reg, sender,
      { type: "model_set", id: "r4", provider: "anthropic", model_id: "claude-opus-4-7" },
      () => { persistCalls += 1; },
    );
    expect(persistCalls).toBe(0);
    expect(sender.sent[0]).toMatchObject({ type: "action_error" });
  });

  test("does NOT persist when the model is unknown", async () => {
    const reg = fakeRegistry([sampleModel]);
    const sender = makeSender();
    let persistCalls = 0;
    await handleModelSet(
      fakePi(), null, reg, sender,
      { type: "model_set", id: "r4", provider: "anthropic", model_id: "nope-3" },
      () => { persistCalls += 1; },
    );
    expect(persistCalls).toBe(0);
  });

  test("falls back to authenticated provider alias (e.g. openai -> openai-codex)", async () => {
    const codexModel: SdkModelLike = {
      id: "gpt-5.6-sol",
      name: "GPT-5.6 Sol",
      provider: "openai-codex",
      reasoning: true,
      contextWindow: 128000,
    };
    const unauthModel: SdkModelLike = {
      id: "gpt-5.6-sol",
      name: "GPT-5.6 Sol",
      provider: "openai",
      reasoning: true,
      contextWindow: 128000,
    };
    const reg = {
      refresh: vi.fn(),
      find: vi.fn((provider: string, id: string) => {
        if (provider === "openai" && id === "gpt-5.6-sol") return unauthModel;
        if (provider === "openai-codex" && id === "gpt-5.6-sol") return codexModel;
        return undefined;
      }),
      getAll: () => [unauthModel, codexModel],
      getAvailable: () => [codexModel],
    } as unknown as ActionModelRegistry;

    const setModelCalls: SdkModelLike[] = [];
    const pi = fakePi({
      setModel: async (m) => {
        setModelCalls.push(m);
        return m.provider === "openai-codex";
      },
    });

    const sender = makeSender();
    const persisted: Array<{ provider: string; modelId: string }> = [];
    await handleModelSet(
      pi,
      null,
      reg,
      sender,
      { type: "model_set", id: "r_alias", provider: "openai", model_id: "gpt-5.6-sol" },
      (p, m) => persisted.push({ provider: p, modelId: m }),
    );

    expect(sender.sent[0]).toMatchObject({ type: "action_ok", action: "model_set" });
    expect(persisted).toEqual([{ provider: "openai-codex", modelId: "gpt-5.6-sol" }]);
  });

  test("exact requested provider is prioritized over alias (e.g. openai-codex -> selects openai-codex, not openai)", async () => {
    const codexModel: SdkModelLike = {
      id: "gpt-6-astra",
      name: "GPT-6 Astra",
      provider: "openai-codex",
      reasoning: true,
      contextWindow: 272000,
    };
    const apiModel: SdkModelLike = {
      id: "gpt-6-astra",
      name: "GPT-6 Astra",
      provider: "openai",
      reasoning: true,
      contextWindow: 272000,
    };
    const reg = {
      refresh: vi.fn(),
      find: vi.fn((provider: string, id: string) => {
        if (provider === "openai-codex" && id === "gpt-6-astra") return codexModel;
        if (provider === "openai" && id === "gpt-6-astra") return apiModel;
        return undefined;
      }),
      getAll: () => [apiModel, codexModel],
      getAvailable: () => [apiModel, codexModel],
    } as unknown as ActionModelRegistry;

    const setModelCalls: SdkModelLike[] = [];
    const pi = fakePi({
      setModel: async (m) => {
        setModelCalls.push(m);
        return true;
      },
    });

    const sender = makeSender();
    const persisted: Array<{ provider: string; modelId: string }> = [];
    await handleModelSet(
      pi,
      null,
      reg,
      sender,
      { type: "model_set", id: "r_exact", provider: "openai-codex", model_id: "gpt-6-astra" },
      (p, m) => persisted.push({ provider: p, modelId: m }),
    );

    expect(sender.sent[0]).toMatchObject({ type: "action_ok", action: "model_set" });
    expect(persisted).toEqual([{ provider: "openai-codex", modelId: "gpt-6-astra" }]);
    expect(setModelCalls[0].provider).toBe("openai-codex");
  });
});

// ── list_models ────────────────────────────────────────────────────────────

describe("handleListModels", () => {
  test("returns wire-shaped catalog with current echo when ctx.getModel is set", () => {
    const reg = fakeRegistry([sampleModel]);
    const ctx: ActionCtx = { getModel: () => sampleModel };
    const sender = makeSender();
    handleListModels(ctx, reg, sender, { type: "list_models", id: "r5" });
    const reply = sender.sent[0];
    expect(reply.type).toBe("models_list");
    if (reply.type !== "models_list") throw new Error("type guard");
    expect(reply.in_reply_to).toBe("r5");
    expect(reply.models).toEqual([
      {
        id: "claude-opus-4-7",
        name: "Claude Opus 4.7",
        provider: "anthropic",
        reasoning: true,
        context_window: 200_000,
        vision: false,
        thinking_levels: ["auto", "off", "minimal", "low", "medium", "high"],
      },
    ]);
    expect(reply.current).toEqual(reply.models[0]);
  });

  test("omits `current` when ctx.getModel is undefined", () => {
    const reg = fakeRegistry([sampleModel]);
    const sender = makeSender();
    handleListModels(null, reg, sender, { type: "list_models", id: "r5" });
    const reply = sender.sent[0];
    expect(reply.type).toBe("models_list");
    if (reply.type !== "models_list") throw new Error("type guard");
    expect(reply.current).toBeUndefined();
  });

  test("name-only current (no model metadata) omits thinking_levels", () => {
    const sender = makeSender();
    handleListModels(null, fakeRegistry([]), sender, { type: "list_models", id: "r5" }, "anthropic/claude-opus-5-5");
    const reply = sender.sent[0];
    if (reply.type !== "models_list") throw new Error("type guard");
    expect(reply.current).toMatchObject({ provider: "anthropic", id: "claude-opus-5-5", reasoning: true });
    expect(reply.current).not.toHaveProperty("thinking_levels");
  });

  test("prefers ctx.modelRegistry over the fallback registry", () => {
    const fallback = fakeRegistry([sampleModel]);
    const liveModel: SdkModelLike = {
      id: "gpt-oss-20b",
      name: "GPT OSS 20B",
      provider: "lemonade",
      reasoning: false,
      contextWindow: 131_072,
    };
    const live = fakeRegistry([liveModel]);
    const ctx: ActionCtx = { modelRegistry: live };
    const sender = makeSender();
    handleListModels(ctx, fallback, sender, { type: "list_models", id: "r5" });
    const reply = sender.sent[0];
    expect(reply.type).toBe("models_list");
    if (reply.type !== "models_list") throw new Error("type guard");
    expect(reply.models).toEqual([
      {
        id: "gpt-oss-20b",
        name: "GPT OSS 20B",
        provider: "lemonade",
        reasoning: false,
        context_window: 131_072,
        vision: false,
        thinking_levels: ["off"],
      },
    ]);
  });

  test("registry refresh failure surfaces as error envelope", () => {
    const reg: ActionModelRegistry = {
      refresh: () => { throw new Error("models.json malformed"); },
      getAvailable: () => [],
      find: () => undefined,
    };
    const sender = makeSender();
    handleListModels(null, reg, sender, { type: "list_models", id: "r5" });
    expect(sender.sent[0]).toMatchObject({
      type: "error",
      in_reply_to: "r5",
      code: "internal_error",
      message: expect.stringContaining("models.json malformed"),
    });
  });
});

// ── wireFromModel ──────────────────────────────────────────────────────────

describe("wireFromModel", () => {
  test("maps SDK Model fields to wire schema 1:1 (camelCase → snake_case)", () => {
    expect(wireFromModel(sampleModel)).toEqual({
      id: "claude-opus-4-7",
      name: "Claude Opus 4.7",
      provider: "anthropic",
      reasoning: true,
      context_window: 200_000,
      vision: false,  // sampleModel has no `input` → text-only
      thinking_levels: ["auto", "off", "minimal", "low", "medium", "high"],
    });
  });

  // Plan/30: `vision` reflects whether the model's `input` includes "image".
  test("vision=true when model.input includes \"image\"", () => {
    const visionModel: SdkModelLike = { ...sampleModel, input: ["text", "image"] };
    expect(wireFromModel(visionModel).vision).toBe(true);
  });

  test("vision=false when model.input is text-only", () => {
    const textOnly: SdkModelLike = { ...sampleModel, input: ["text"] };
    expect(wireFromModel(textOnly).vision).toBe(false);
  });

  test("Gemini 3.7 Flash: off mapped to null -> only minimal..high (no off, no max)", () => {
    const gemini: SdkModelLike = {
      ...sampleModel,
      id: "gemini-3.7-flash",
      name: "Gemini 3.7 Flash",
      reasoning: true,
      thinkingLevelMap: { off: null },
    };
    expect(wireFromModel(gemini).thinking_levels).toEqual([
      "auto", "minimal", "low", "medium", "high",
    ]);
  });

  test("Kimi K3: off, minimal, medium, xhigh mapped to null -> only low, high, max", () => {
    const k3: SdkModelLike = {
      ...sampleModel,
      id: "k3",
      name: "Kimi K3",
      reasoning: true,
      thinkingLevelMap: {
        off: null,
        minimal: null,
        low: "low",
        medium: null,
        high: "high",
        xhigh: null,
        max: "max",
      },
    };
    expect(wireFromModel(k3).thinking_levels).toEqual([
      "auto", "low", "high", "max",
    ]);
  });

  test("DeepSeek V4 Pro: supports off, high, max", () => {
    const dsv4: SdkModelLike = {
      ...sampleModel,
      id: "deepseek-v4-pro",
      reasoning: true,
      thinkingLevelMap: {
        minimal: null,
        low: null,
        medium: null,
        high: "high",
        xhigh: null,
        max: "max",
      },
    };
    expect(wireFromModel(dsv4).thinking_levels).toEqual([
      "auto", "off", "high", "max",
    ]);
  });

  test("thinking_levels is ['off'] for non-reasoning models", () => {
    expect(wireFromModel({ ...sampleModel, reasoning: false }).thinking_levels)
      .toEqual(["off"]);
  });
});

// ── thinking levels on omp hosts ───────────────────────────────────────────

/** A live omp v18.8.7 registry Model plus its captured Shift+Tab cycle. */
type OmpCapturedModel = SdkModelLike & { cycle: string[] };
const ompModels = ompCapture.models as unknown as OmpCapturedModel[];

/** The levels omp offers, in omp's order: the captured cycle rotated to start
 *  at "off" (omp's first selector), de-duplicated. omp offers nothing for a
 *  non-reasoning model; the wire contract then is ["off"]. */
function ompCycleLevels(cycle: string[]): string[] {
  if (cycle.length === 0) return ["off"];
  const start = cycle.indexOf("off");
  return [...new Set([...cycle.slice(start), ...cycle.slice(0, start)])];
}

describe("thinking levels match omp's Shift+Tab cycle (live omp v18.8.7 models)", () => {
  test("sanity: the captured cycles are the expected omp ladders", () => {
    expect(Object.fromEntries(ompModels.map((m) => [m.id, ompCycleLevels(m.cycle)]))).toEqual({
      "claude-opus-5-5": ["off", "auto", "low", "medium", "high", "xhigh", "max"],
      "claude-sonnet-4-5": ["off", "auto", "minimal", "low", "medium", "high", "xhigh"],
      "glm-5.2": ["off", "auto", "high", "max"],
      "grok-4": ["off", "auto"],
      "gemma2-9b-it": ["off"],
    });
  });

  for (const model of ompModels) {
    test(`models_list: ${model.provider}/${model.id} offers ${ompCycleLevels(model.cycle).join(" ")}`, () => {
      const reg = fakeRegistry(ompModels);
      const ctx: ActionCtx = { getModel: () => model };
      const sender = makeSender();
      handleListModels(ctx, reg, sender, { type: "list_models", id: "r6" });
      const reply = sender.sent[0];
      if (reply.type !== "models_list") throw new Error("type guard");
      const expected = ompCycleLevels(model.cycle);
      expect(reply.models.find((m) => m.id === model.id)?.thinking_levels).toEqual(expected);
      expect(reply.current?.thinking_levels).toEqual(expected);
    });
  }

  test("production defect: Opus 5.5 alone offers xhigh and max (per-model omp metadata)", () => {
    const opus = ompModels.find((m) => m.id === "claude-opus-5-5")!;
    expect(wireFromModel(opus).thinking_levels).toEqual([
      "off", "auto", "low", "medium", "high", "xhigh", "max",
    ]);
  });
});
