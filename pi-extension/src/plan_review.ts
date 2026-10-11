// omp plan mode on the paired clients (app + web).
//
// omp finishes planning when the agent writes the plan's slug to
// `xd://propose`; the `write` result carries `details.xdev.inner =
// { planFilePath, title, planExists }`, omp aborts the turn and opens its
// "Plan Review" overlay. The overlay is a TUI component (not `ctx.ui.select`),
// so no extension API can answer it. This module forwards the review to the
// clients (plan markdown + omp's exact choices) and answers it the way a
// terminal user does: with the overlay's own keys. Plan state (omp's
// `mode_change` entries) is mirrored to the clients as `plan_state`.
//
// The overlay always opens with its action list focused and the first option
// selected, so the key sequences below are exact for an untouched overlay.
// When the terminal user has pressed keys since it opened, the overlay is
// closed (Esc) and re-opened with `/plan-review` before the keys are sent.

import { existsSync, readdirSync, readFileSync, statSync } from "node:fs";
import { tmpdir } from "node:os";
import { isAbsolute, join, resolve, sep } from "node:path";
import { z } from "zod";

import type {
  ExtensionUiResponseWire,
  PlanReviewAction,
  PlanReviewAnswerWire,
  PlanReviewOptionWire,
  PlanStatus,
  ServerMessage,
} from "./protocol/types.js";

export const PLAN_REVIEW_ID_PREFIX = "plan-review:";

/** omp's plan mode (`/plan`, the plan review overlay, its confirms) exists
 *  only in its interactive TUI: RPC mode, which remote-pi daemons run, has no
 *  `/plan` command and never opens a plan review. */
export const PLAN_MODE_NEEDS_TERMINAL =
  "omp's plan mode needs its interactive terminal (TUI). This agent runs headless (daemon / RPC mode), so /plan and the plan review are not available here.";

const DOWN = "\x1b[B";
const UP = "\x1b[A";
const ENTER = "\r";
const ESC = "\x1b";

/** Keys from the overlay's initial state to each choice, then Enter. Down
 *  stops on the last option ("Save and quit"), so `refine`/`save_quit` never
 *  depend on whether omp disabled "keep context". */
const OVERLAY_KEYS: Record<PlanReviewAction, readonly string[]> = {
  approve_execute: [ENTER],
  approve_compact: [DOWN, ENTER],
  approve_keep: [DOWN, DOWN, ENTER],
  refine: [DOWN, DOWN, DOWN, DOWN, DOWN, UP, ENTER],
  save_quit: [DOWN, DOWN, DOWN, DOWN, DOWN, ENTER],
};

/** omp's option labels, in overlay order (interactive-mode handlePlanApproval). */
const LABELS: Record<Exclude<PlanReviewAction, "approve_keep">, string> = {
  approve_execute: "Approve and execute",
  approve_compact: "Approve and compact context",
  refine: "Refine plan",
  save_quit: "Save and quit",
};
const KEEP_LABEL = "Approve and keep context";
/** omp disables "keep context" above this context fill (percent). */
const KEEP_CONTEXT_MAX_PERCENT = 95;

/** Gap between injected key chunks; omp's input parser waits ~50 ms after a
 *  lone Esc before treating it as Esc, so Esc gets a longer gap. */
const KEY_GAP_MS = 60;
const ESC_GAP_MS = 200;
/** Two Escs closer than 500 ms on omp's idle editor open the tree selector. */
const ESC_REPEAT_MS = 650;
/** omp shows the overlay right after the propose turn's agent_end / the
 *  `/plan-review` input; give it time to take focus before keys go in. */
const OVERLAY_SETTLE_MS = 400;
/** "Save and quit" asks for a path in a second overlay; Enter keeps omp's
 *  suggestion. */
const SAVE_PATH_SETTLE_MS = 800;
/** omp's "Exit plan mode?" confirm (Yes is preselected). */
const EXIT_CONFIRM_SETTLE_MS = 400;
/** Our own keys echo through the terminal input listener for a moment. */
const SELF_INPUT_WINDOW_MS = 250;
/** Max `/plan` steps one plan_mode request may take (plan → paused → none). */
const MAX_MODE_STEPS = 3;
const MODE_STEP_MS = 700;

export type OmpPlanMode = "plan" | "plan_paused" | "none";

export interface ContextUsage {
  tokens: number | null;
  contextWindow: number | null;
  percent: number | null;
}

export interface PlanReviewHost {
  broadcast(msg: ServerMessage): void;
  /** omp runs an interactive terminal whose input we can drive. */
  hasTerminal(): boolean;
  /** The agent is not running (omp's overlay only exists while idle). */
  isIdle(): boolean;
  /** Feed raw keys to omp's terminal input, as a keypress would. */
  pressKeys(keys: string): void;
  /** Submit one line through omp's editor (slash commands); false on failure. */
  typeLine(text: string): boolean;
  /** Send `text` as the user's next prompt, visible on every client. */
  submitPrompt(text: string): void;
  /** omp's current plan mode (latest `mode_change` entry). */
  mode(): OmpPlanMode;
  readPlan(planFilePath: string): string | null;
  /** omp's "Exit plan mode?" condition: a non-empty plan file exists. */
  hasPlanFile(planFilePath: string | null): boolean;
  /** The newest local `*plan.md` (what `/plan-review` opens). */
  latestPlanFile(): string | null;
  contextUsage(): ContextUsage | null;
  setTimer(fn: () => void, ms: number): void;
  now(): number;
}

interface Review {
  id: string;
  planFilePath: string;
  title: string;
  content: string | null;
  options: PlanReviewOptionWire[];
  /** The overlay has taken focus (keys can go in). */
  open: boolean;
  /** Terminal keys arrived since it opened: its cursor is unknown. */
  touched: boolean;
}

type Choice = { action: PlanReviewAction | "cancel"; feedback?: string };

export interface PlanReviewController {
  /** tool_execution_end — opens a review on omp's propose result. */
  onToolEnd(event: { toolName?: unknown; toolCallId?: unknown; isError?: unknown; result?: unknown }): void;
  onAgentStart(): void;
  onAgentEnd(): void;
  /** session_switch / session_start / session_compact. */
  onSessionChange(): void;
  /** `input` event (terminal typing and injected lines alike). */
  onInput(text: string): void;
  /** Raw terminal input (ctx.ui.onTerminalInput). */
  onTerminalInput(data: string): void;
  /** Re-read omp's mode; publishes `plan_state` on change. */
  refresh(): void;
  /** Routes a client answer; false when `msg` is not a plan review answer. */
  respond(msg: ExtensionUiResponseWire): boolean;
  /** Client `plan_mode` action; resolves to an error message or null. */
  planMode(action: "enter" | "exit" | "review"): string | null;
  /** Frames a (re)syncing client needs: state, then the open review. */
  syncFrames(): ServerMessage[];
  /** omp's plan review overlay has the terminal's focus: a line typed into
   *  omp's editor now would land on the overlay (Enter picks an option). */
  reviewOpen(): boolean;
}

/** omp's `xd://propose` result (`write` tool, `details.xdev`) — the fields
 *  omp's own interactive handler checks before opening the review. */
const ProposeResult = z.object({
  details: z.object({
    xdev: z.object({
      tool: z.literal("propose"),
      mode: z.literal("execute"),
      inner: z.object({ planFilePath: z.string(), title: z.string(), planExists: z.boolean() }),
    }),
  }),
});

export function proposedPlan(result: unknown): { planFilePath: string; title: string } | null {
  const parsed = ProposeResult.safeParse(result);
  if (!parsed.success) return null;
  const { planFilePath, title } = parsed.data.details.xdev.inner;
  return { planFilePath, title };
}

/** "19k", "1.5k", "1m" — omp's compact token counts in the keep-context label. */
export function compactTokens(n: number): string {
  const v = Math.max(0, Math.round(n));
  if (v < 1000) return String(v);
  if (v < 1_000_000) return v < 10_000 ? `${trimFixed(v / 1000)}k` : `${Math.round(v / 1000)}k`;
  return `${trimFixed(v / 1_000_000)}m`;
}

function trimFixed(x: number): string {
  return x.toFixed(1).replace(/\.0$/, "");
}

/** omp's option list for the current context fill. */
export function planReviewOptions(usage: ContextUsage | null): PlanReviewOptionWire[] {
  const keepLabel =
    usage && usage.tokens !== null && usage.contextWindow
      ? `${KEEP_LABEL} (~${compactTokens(usage.tokens)} / ${compactTokens(usage.contextWindow)})`
      : KEEP_LABEL;
  const keepDisabled = usage?.percent != null && usage.percent > KEEP_CONTEXT_MAX_PERCENT;
  return [
    { action: "approve_execute", label: LABELS.approve_execute },
    { action: "approve_compact", label: LABELS.approve_compact },
    keepDisabled
      ? { action: "approve_keep", label: keepLabel, disabled: true }
      : { action: "approve_keep", label: keepLabel },
    { action: "refine", label: LABELS.refine },
    { action: "save_quit", label: LABELS.save_quit },
  ];
}

const PlanAnswer = z.object({
  action: z.enum(["approve_execute", "approve_compact", "approve_keep", "refine", "save_quit"]),
  feedback: z.string().optional(),
});

/** A client's answer → the overlay choice (rich `plan`, cancel, or a bare
 *  select label from a client that only knows the plain select). */
function choiceOf(msg: ExtensionUiResponseWire, options: readonly PlanReviewOptionWire[]): Choice | null {
  if ("cancelled" in msg && msg.cancelled === true) return { action: "cancel" };
  if ("plan" in msg) {
    const parsed = PlanAnswer.safeParse(msg.plan);
    if (!parsed.success) return null;
    const { action } = parsed.data;
    const feedback = parsed.data.feedback?.trim() ?? "";
    return action === "refine" && feedback ? { action, feedback } : { action };
  }
  if ("value" in msg && typeof msg.value === "string") {
    const match = options.find((o) => o.label === msg.value) ??
      options.find((o) => o.action === "approve_keep" && msg.value.startsWith(KEEP_LABEL));
    return match ? { action: match.action } : null;
  }
  return null;
}

export function createPlanReview(host: PlanReviewHost): PlanReviewController {
  let review: Review | null = null;
  /** The last review's id + plan, kept after it closes so a late client
   *  answer to it can re-open the overlay. */
  let lastReview: { id: string; planFilePath: string; title: string } | null = null;
  /** Answer received before the overlay took focus. */
  let pending: { id: string; choice: Choice } | null = null;
  let selfInputUntil = 0;
  /** Last broadcast `plan_state`. Clients get the state with every
   *  session_sync, so an unchanged idle state is never broadcast. */
  let published: string | null = JSON.stringify({ type: "plan_state", status: "idle" });
  let modeTarget: { mode: "plan" | "none"; steps: number; nextAt: number } | null = null;
  let reopenSeq = 0;

  function notify(id: string, message: string, warning = false): void {
    host.broadcast({
      type: "extension_ui_request",
      id,
      method: "notify",
      message,
      ...(warning ? { notify_type: "warning" as const } : {}),
    });
  }

  function requestFrame(r: Review): ServerMessage {
    return {
      type: "extension_ui_request",
      id: r.id,
      method: "select",
      title: `Plan ready for review: ${r.title}`,
      options: r.options.map((o) => o.label),
      plan: {
        plan_file_path: r.planFilePath,
        title: r.title,
        content: r.content,
        options: r.options,
      },
    };
  }

  function stateFrame(): ServerMessage {
    const mode = host.mode();
    const status: PlanStatus = review
      ? "review"
      : mode === "plan"
        ? "active"
        : mode === "plan_paused"
          ? "paused"
          : "idle";
    // While planning, name the plan omp would review (and whose presence
    // makes omp ask "Exit plan mode?"): the last proposal, else the newest
    // local plan file.
    const latest = status === "active" && !lastReview ? host.latestPlanFile() : null;
    const plan = review ?? (status === "active" ? lastReview : null) ??
      (latest ? { planFilePath: latest, title: planTitle(latest) } : null);
    return plan
      ? { type: "plan_state", status, plan_file_path: plan.planFilePath, title: plan.title }
      : { type: "plan_state", status };
  }

  function publish(): void {
    const frame = stateFrame();
    const key = JSON.stringify(frame);
    if (key === published) return;
    published = key;
    host.broadcast(frame);
  }

  function openReview(id: string, planFilePath: string, title: string, openAfterMs: number | null): void {
    if (review && review.id !== id) notify(review.id, "A newer plan replaced this one.");
    review = {
      id,
      planFilePath,
      title,
      content: host.readPlan(planFilePath),
      options: planReviewOptions(host.contextUsage()),
      open: false,
      touched: false,
    };
    lastReview = { id, planFilePath, title };
    host.broadcast(requestFrame(review));
    publish();
    if (openAfterMs !== null) settleOpen(review, openAfterMs);
  }

  function settleOpen(r: Review, ms: number): void {
    host.setTimer(() => {
      if (review !== r) return;
      r.open = true;
      const queued = pending;
      pending = null;
      if (queued) apply(r, queued.choice);
    }, ms);
  }

  function closeReview(message: string): void {
    if (!review) return;
    const id = review.id;
    review = null;
    pending = null;
    notify(id, message);
    publish();
  }

  /** Sends `keys` one chunk at a time, then `after`. */
  function press(keys: readonly string[], after?: () => void): void {
    let delay = 0;
    for (const key of keys) {
      host.setTimer(() => {
        selfInputUntil = host.now() + SELF_INPUT_WINDOW_MS;
        host.pressKeys(key);
      }, delay);
      delay += key === ESC ? ESC_GAP_MS : KEY_GAP_MS;
    }
    if (after) host.setTimer(after, delay);
  }

  /** Esc, pause, Esc: closes the overlay even when one of its note editors is
   *  open (that takes the first Esc). On omp's idle editor two Escs this far
   *  apart do nothing (closer than 500 ms they open the tree selector). */
  function escapeOverlay(after: () => void): void {
    press([ESC]);
    host.setTimer(() => press([ESC], () => host.setTimer(after, ESC_REPEAT_MS)), ESC_REPEAT_MS);
  }

  function apply(r: Review, choice: Choice): void {
    if (choice.action === "cancel") {
      if (r.touched) escapeOverlay(() => {});
      else press([ESC]);
      closeReview("Plan review closed — still planning.");
      return;
    }
    const action = choice.action;
    const option = r.options.find((o) => o.action === action);
    if (option?.disabled) {
      notify(r.id, `"${option.label}" is disabled: the context is too full.`, true);
      return;
    }
    press(OVERLAY_KEYS[action], () => {
      if (action === "save_quit") host.setTimer(() => host.pressKeys(ENTER), SAVE_PATH_SETTLE_MS);
      if (action === "refine" && choice.feedback) host.submitPrompt(choice.feedback);
    });
    closeReview(
      action === "refine"
        ? "Refining the plan."
        : action === "save_quit"
          ? "Plan saved; plan mode closed."
          : "Plan approved.",
    );
  }

  /** The overlay's state is unknown (the terminal used it, or it may have been
   *  closed there): close it, re-open it fresh with `/plan-review`, then apply
   *  the choice once it has focus (onInput → settleOpen → pending). */
  function reopenAndApply(id: string, choice: Choice): void {
    pending = { id, choice };
    escapeOverlay(() => {
      if (pending?.id === id && !host.typeLine("/plan-review")) {
        pending = null;
        notify(id, "Could not reach the terminal to open the plan review.", true);
      }
    });
  }

  /** One `/plan` toward `modeTarget` (plan → plan_paused → none, or back);
   *  false when the terminal could not take it. */
  function stepMode(): boolean {
    if (!modeTarget) return true;
    const mode = host.mode();
    const reached = modeTarget.mode === "plan" ? mode === "plan" : mode === "none";
    if (reached || modeTarget.steps >= MAX_MODE_STEPS) {
      modeTarget = null;
      return true;
    }
    if (host.now() < modeTarget.nextAt) return true;
    modeTarget.steps += 1;
    modeTarget.nextAt = host.now() + MODE_STEP_MS;
    // omp asks "Exit plan mode?" (Yes preselected) when a plan file exists.
    const confirmExit = mode === "plan" && host.hasPlanFile(lastReview?.planFilePath ?? null);
    if (!host.typeLine("/plan")) {
      modeTarget = null;
      return false;
    }
    if (confirmExit) host.setTimer(() => host.pressKeys(ENTER), EXIT_CONFIRM_SETTLE_MS);
    host.setTimer(() => controller.refresh(), MODE_STEP_MS);
    return true;
  }

  const controller: PlanReviewController = {
    onToolEnd(event) {
      if (event.toolName !== "write" || event.isError === true) return;
      const plan = proposedPlan(event.result);
      if (!plan) return;
      const callId = typeof event.toolCallId === "string" ? event.toolCallId : String(host.now());
      // omp opens the overlay once the aborted turn ends (onAgentEnd).
      openReview(`${PLAN_REVIEW_ID_PREFIX}${callId}`, plan.planFilePath, plan.title, null);
    },

    onAgentStart() {
      if (review) closeReview(host.mode() === "plan" ? "Plan review closed." : "Plan approved.");
      publish();
    },

    onAgentEnd() {
      if (review && !review.open) settleOpen(review, OVERLAY_SETTLE_MS);
      publish();
    },

    onSessionChange() {
      if (review) closeReview(host.mode() === "plan" ? "Plan review closed." : "Plan approved.");
      if (host.mode() !== "plan") lastReview = null;
      publish();
    },

    onInput(text) {
      const line = text.trim();
      if (line === "/plan-review") {
        if (host.mode() !== "plan") return;
        const path = host.latestPlanFile() ?? lastReview?.planFilePath;
        if (!path) return;
        const title = lastReview?.planFilePath === path ? lastReview.title : planTitle(path);
        const id = pending?.id ?? `${PLAN_REVIEW_ID_PREFIX}reopen-${host.now()}-${++reopenSeq}`;
        if (review?.id === id) review = null; // same client prompt: replace in place
        openReview(id, path, title, OVERLAY_SETTLE_MS);
        return;
      }
      // Anything else typed into omp's editor means the overlay is closed.
      if (review) closeReview("Plan review closed in the terminal.");
      if (line === "/plan" || line.startsWith("/plan ")) host.setTimer(() => controller.refresh(), MODE_STEP_MS);
    },

    onTerminalInput(data) {
      if (!review?.open || host.now() < selfInputUntil) return;
      review.touched = true;
      // A lone Esc on the overlay is omp's cancel (back to planning). If it
      // only closed a note editor inside the overlay, a later client answer
      // still works: it closes and re-opens the overlay first.
      if (data === ESC) closeReview("Plan review closed in the terminal.");
    },

    refresh() {
      if (review && host.mode() !== "plan") {
        closeReview("Plan approved.");
      }
      if (host.mode() !== "plan" && !review) lastReview = null;
      stepMode();
      publish();
    },

    respond(msg) {
      if (!msg.id.startsWith(PLAN_REVIEW_ID_PREFIX)) return false;
      const current = review?.id === msg.id ? review : null;
      const choice = choiceOf(msg, current?.options ?? planReviewOptions(host.contextUsage()));
      if (!choice) {
        notify(msg.id, "Unknown plan review choice.", true);
        return true;
      }
      if (host.mode() !== "plan") {
        notify(msg.id, "Plan mode is no longer active.");
        return true;
      }
      if (!host.hasTerminal()) {
        notify(msg.id, PLAN_MODE_NEEDS_TERMINAL, true);
        return true;
      }
      if (current) {
        if (!current.open) pending = { id: msg.id, choice };
        else if (!current.touched || choice.action === "cancel") apply(current, choice);
        else reopenAndApply(msg.id, choice);
        return true;
      }
      if (review || lastReview?.id !== msg.id || !host.isIdle()) {
        notify(msg.id, "This plan review is out of date.");
        return true;
      }
      // The review was closed in the terminal (Esc) but the client still
      // wants it: re-open omp's overlay and apply the choice there.
      if (choice.action === "cancel") {
        notify(msg.id, "Plan review closed — still planning.");
        return true;
      }
      reopenAndApply(msg.id, choice);
      return true;
    },

    planMode(action) {
      const mode = host.mode();
      if (action === "review") {
        if (mode !== "plan") return "Plan mode is not active.";
        if (review) {
          host.broadcast(requestFrame(review));
          return null;
        }
        if (!host.latestPlanFile() && !lastReview) return "No plan to review yet.";
        return host.typeLine("/plan-review") ? null : "Could not reach the terminal.";
      }
      const target = action === "enter" ? "plan" : "none";
      if ((target === "plan" && mode === "plan") || (target === "none" && mode === "none")) return null;
      if (!host.hasTerminal()) return PLAN_MODE_NEEDS_TERMINAL;
      modeTarget = { mode: target, steps: 0, nextAt: 0 };
      if (review) {
        // `/plan` must not reach an open overlay (its Enter would pick an
        // option): close the overlay first.
        closeReview("Plan mode closed.");
        modeTarget.nextAt = Number.POSITIVE_INFINITY;
        escapeOverlay(() => {
          if (modeTarget) modeTarget.nextAt = 0;
          controller.refresh();
        });
        return null;
      }
      return stepMode() ? null : "Could not reach the terminal.";
    },

    syncFrames() {
      const frames: ServerMessage[] = [stateFrame()];
      if (review) frames.push(requestFrame(review));
      return frames;
    },

    reviewOpen() {
      return review?.open === true;
    },
  };
  return controller;
}

function planTitle(planFilePath: string): string {
  const name = planFilePath.replace(/^local:\/\//, "").split(/[\\/]/).pop() ?? planFilePath;
  return name.replace(/-?plan\.md$/i, "") || name;
}

// ── omp session state readers (host side) ───────────────────────────────────

/** The slice of omp's SessionManager this module reads. */
interface SessionManagerLike {
  /** omp session entries; `mode_change` entries carry the mode (`plan`, `plan_paused`, `none`, `goal`, …). */
  getEntries?: () => ReadonlyArray<{ type?: string; mode?: string }>;
  getArtifactsDir?: () => string | null | undefined;
  getSessionId?: () => string | null | undefined;
}

/** omp's plan mode: the latest `mode_change` entry (`plan`, `plan_paused`,
 *  or anything else = off). A new session has none. */
export function ompPlanMode(sessionManager: unknown): OmpPlanMode {
  const sm = sessionManager as SessionManagerLike | null | undefined;
  let entries: ReadonlyArray<{ type?: string; mode?: string }> | undefined;
  try {
    entries = sm?.getEntries?.();
  } catch {
    return "none";
  }
  if (!Array.isArray(entries)) return "none";
  for (let i = entries.length - 1; i >= 0; i--) {
    const entry = entries[i];
    if (entry?.type === "mode_change") {
      return entry.mode === "plan" || entry.mode === "plan_paused" ? entry.mode : "none";
    }
  }
  return "none";
}

/** omp's `local://` root for the session (omp: `<artifacts dir>/local`, else
 *  `<tmp>/omp-local/<session id>`). */
export function ompLocalRoot(sessionManager: unknown): string | null {
  const sm = sessionManager as SessionManagerLike | null | undefined;
  try {
    const artifacts = sm?.getArtifactsDir?.();
    if (artifacts) return resolve(artifacts, "local");
    const id = (sm?.getSessionId?.() ?? "session").replace(/[^a-zA-Z0-9_.-]/g, "_");
    return join(tmpdir(), "omp-local", id && id !== "." && id !== ".." ? id : "session");
  } catch {
    return null;
  }
}

/** Absolute path of an omp plan path (`local://x.md`, absolute, or cwd-relative). */
export function resolvePlanPath(planFilePath: string, sessionManager: unknown, cwd: string): string | null {
  if (planFilePath.startsWith("local://")) {
    const root = ompLocalRoot(sessionManager);
    if (!root) return null;
    const full = resolve(root, planFilePath.slice("local://".length));
    return full === root || full.startsWith(root + sep) ? full : null;
  }
  return isAbsolute(planFilePath) ? planFilePath : resolve(cwd, planFilePath);
}

export function readPlanFile(planFilePath: string, sessionManager: unknown, cwd: string): string | null {
  const full = resolvePlanPath(planFilePath, sessionManager, cwd);
  if (!full) return null;
  try {
    return readFileSync(full, "utf8");
  } catch {
    return null;
  }
}

/** Local `*plan.md` files, newest first (omp's `/plan-review` order). */
export function localPlanFiles(sessionManager: unknown): string[] {
  const root = ompLocalRoot(sessionManager);
  if (!root || !existsSync(root)) return [];
  try {
    return readdirSync(root, { withFileTypes: true })
      .filter((d) => d.isFile() && /plan\.md$/i.test(d.name))
      .map((d) => ({ name: d.name, mtime: statSync(join(root, d.name)).mtimeMs }))
      .sort((a, b) => b.mtime - a.mtime)
      .map((f) => `local://${f.name}`);
  } catch {
    return [];
  }
}
