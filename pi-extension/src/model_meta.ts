/**
 * The model and thinking level that room_meta publishes, derived from live
 * session state exactly as omp's status-line `model` segment renders them.
 * Every client must show what the terminal footer shows.
 *
 * omp footer rules (omp v18 status-line `model` segment):
 *   - model label: `model.name || model.id`, with a leading "Claude " dropped.
 *     The wire keeps the registry name (Quick Actions match it against
 *     `WireModel.name`); clients drop the prefix when they render it.
 *   - no thinking shown when the model has no `thinking` metadata.
 *   - auto thinking: the level auto resolved for the current prompt, or
 *     "auto" until the first prompt after auto was (re)armed.
 *   - otherwise: `thinkingLevel ?? "off"`.
 *
 * Extensions only see `getThinkingLevel()` (the effective level), not omp's
 * `isAutoThinking` / `autoResolvedThinkingLevel()`, so auto state is read from
 * the session branch:
 *   - omp writes `thinking_level_change { thinkingLevel, configured }`;
 *     `configured: "auto"` means auto. A new omp session in auto writes no
 *     thinking entry at all (every non-auto session writes one), so a branch
 *     without one is auto too.
 *   - auto is resolved once a user message follows the last
 *     `model_change` / `thinking_level_change`: omp resolves the level right
 *     before it persists the prompt, and resets it on every model or
 *     thinking change and on session restore (hence `sessionStartLeafId`).
 * Upstream pi has no auto mode and no `model.thinking`; there the level is
 * `getThinkingLevel()` for reasoning models.
 */

import type { ThinkingLevel } from "./protocol/types.js";

export interface LiveModel {
  name?: string;
  id?: string;
  reasoning?: boolean;
  /** omp-only thinking metadata; the footer hides the level without it. */
  thinking?: unknown;
}

export interface ModelMeta {
  /** Registry display name, e.g. "Claude Opus 5.5". Undefined: no model yet. */
  model: string | undefined;
  /** Level the footer shows; null when it shows none; undefined when unknown. */
  thinking: ThinkingLevel | null | undefined;
}

const CONCRETE_LEVELS: readonly ThinkingLevel[] = [
  "off", "minimal", "low", "medium", "high", "xhigh", "max",
];

function entryField(entry: unknown, key: string): unknown {
  return entry !== null && typeof entry === "object" ? Reflect.get(entry, key) : undefined;
}

export function modelMetaFromSession(input: {
  model: LiveModel | undefined;
  /** `pi.getThinkingLevel()`: the effective (auto-resolved) level. */
  thinkingLevel: unknown;
  /** `sessionManager.getBranch()`. */
  branch: readonly unknown[];
  /** Leaf entry id when this process bound the session (session_start). */
  sessionStartLeafId: string | undefined;
}): ModelMeta {
  const { model, thinkingLevel, branch, sessionStartLeafId } = input;
  if (!model) return { model: undefined, thinking: undefined };
  const name = model.name || model.id || undefined;
  const omp = model.thinking !== undefined;
  if (!(omp ? Boolean(model.thinking) : Boolean(model.reasoning))) {
    return { model: name, thinking: null };
  }
  const effective = CONCRETE_LEVELS.find((level) => level === thinkingLevel);
  if (!omp) return { model: name, thinking: effective ?? "off" };

  let configured: unknown = undefined;
  let sawThinkingEntry = false;
  let lastArm = -1;
  let lastUser = -1;
  let boundary = -1;
  branch.forEach((entry, index) => {
    const type = entryField(entry, "type");
    if (type === "thinking_level_change") {
      sawThinkingEntry = true;
      configured = entryField(entry, "configured");
      lastArm = index;
    } else if (type === "model_change") {
      lastArm = index;
    } else if (type === "message" && entryField(entryField(entry, "message"), "role") === "user") {
      lastUser = index;
    }
    if (sessionStartLeafId !== undefined && entryField(entry, "id") === sessionStartLeafId) {
      boundary = index;
    }
  });

  const auto = sawThinkingEntry ? configured === "auto" : true;
  if (!auto) return { model: name, thinking: effective ?? "off" };
  const resolved = lastUser > Math.max(lastArm, boundary);
  return { model: name, thinking: resolved ? effective ?? "auto" : "auto" };
}
