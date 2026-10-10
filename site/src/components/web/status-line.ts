// omp's footer status row, shown under the composer. Wire contract:
// pi-extension src/protocol/types.ts `StatusLineMessage` (full snapshot per
// frame). Formatting follows omp 18.8.7 packages/tui/src/status-line
// (default preset, left side): `π · model · thinking · path · git · context · cost`.
// Model and thinking come from room meta, labelled like the Home tile.

import { formatModelName, thinkingLabel } from "./session-list.ts";

export interface StatusLineGit {
  branch: string | null;
  staged: number;
  unstaged: number;
  untracked: number;
}

export interface StatusLineContext {
  tokens: number;
  window: number;
  percent: number | null;
}

export interface StatusLineCost {
  total: number;
  subagents: number;
  subscription: boolean;
  premiumRequests: number;
}

export interface StatusLine {
  cwd: string;
  path: string;
  scratch: boolean;
  git: StatusLineGit | null;
  context: StatusLineContext;
  cost: StatusLineCost;
  runStartedAt: number | null;
}

function num(v: unknown): number {
  return typeof v === "number" && Number.isFinite(v) ? v : 0;
}

function rec(v: unknown): Record<string, unknown> | null {
  return v && typeof v === "object" ? (v as Record<string, unknown>) : null;
}

/** `status_line` frame → the row's values (null when not one). */
export function parseStatusLine(frame: Record<string, unknown>): StatusLine | null {
  if (frame.type !== "status_line" || typeof frame.path !== "string") return null;
  const git = rec(frame.git);
  const context = rec(frame.context);
  const cost = rec(frame.cost);
  const percent = context?.percent;
  return {
    cwd: typeof frame.cwd === "string" ? frame.cwd : "",
    path: frame.path,
    scratch: frame.scratch === true,
    git: git
      ? {
          branch: typeof git.branch === "string" && git.branch ? git.branch : null,
          staged: num(git.staged),
          unstaged: num(git.unstaged),
          untracked: num(git.untracked),
        }
      : null,
    context: {
      tokens: num(context?.tokens),
      window: num(context?.window),
      percent: typeof percent === "number" && Number.isFinite(percent) ? percent : null,
    },
    cost: {
      total: num(cost?.total),
      subagents: num(cost?.subagents),
      subscription: cost?.subscription === true,
      premiumRequests: num(cost?.premium_requests),
    },
    runStartedAt: typeof frame.run_started_at === "number" ? frame.run_started_at : null,
  };
}

function oneDecimal(n: number): string {
  const s = n.toFixed(1);
  return s.endsWith(".0") ? s.slice(0, -2) : s;
}

/** omp's compact count (`_e`): `950`, `1.5K`, `35K`, `1M`, `2.5M`, `1B`. */
export function formatCount(n: number): string {
  if (n < 1000) return n.toString();
  if (n < 1e4) return `${oneDecimal(n / 1000)}K`;
  if (n < 1e6) return `${Math.round(n / 1000)}K`;
  if (n < 1e7) return `${oneDecimal(n / 1e6)}M`;
  if (n < 1e9) return `${Math.round(n / 1e6)}M`;
  if (n < 1e10) return `${oneDecimal(n / 1e9)}B`;
  return `${Math.round(n / 1e9)}B`;
}

/** Context segment text: `35.3%/1M`; only the window while the percentage is unknown. */
export function contextText({ tokens, window, percent }: StatusLineContext): string {
  if (percent === null && window > 0) return formatCount(window);
  if (window <= 0) return `${formatCount(tokens)}/?`;
  return `${percent === null ? "?" : `${percent.toFixed(1)}%`}/${formatCount(window)}`;
}

export type ContextTone = "normal" | "warning" | "purple" | "error";

// omp `s4`: a tier starts at a percentage or at a token count, whichever comes first.
const TIERS: ReadonlyArray<{ tone: ContextTone; percent: number; tokens: number }> = [
  { tone: "error", percent: 90, tokens: 500_000 },
  { tone: "purple", percent: 70, tokens: 270_000 },
  { tone: "warning", percent: 50, tokens: 150_000 },
];

/** Colour tier of the context segment. */
export function contextTone(percent: number | null, window: number): ContextTone {
  const p = percent ?? 0;
  if (!Number.isFinite(p) || p <= 0) return "normal";
  for (const tier of TIERS) {
    const start = window > 0 ? Math.min(tier.percent, (tier.tokens / window) * 100) : tier.percent;
    if (p >= start) return tier.tone;
  }
  return "normal";
}

/** `*unstaged +staged ?untracked`, each only when non-zero, in omp's order. */
export function gitCounts(git: StatusLineGit): Array<{ kind: "unstaged" | "staged" | "untracked"; text: string }> {
  const out: Array<{ kind: "unstaged" | "staged" | "untracked"; text: string }> = [];
  if (git.unstaged > 0) out.push({ kind: "unstaged", text: `*${git.unstaged}` });
  if (git.staged > 0) out.push({ kind: "staged", text: `+${git.staged}` });
  if (git.untracked > 0) out.push({ kind: "untracked", text: `?${git.untracked}` });
  return out;
}

/**
 * Cost segment (omp `_$`, nerd preset): `subscription` → the subscription icon
 * in front of the amount (or alone while nothing is spent), else `$0.42`;
 * then `(+subagents)` and `★ premium`. null hides the segment.
 */
export function costText(cost: StatusLineCost): { subscriptionIcon: boolean; text: string } | null {
  const { total, subagents, subscription, premiumRequests } = cost;
  const premium = Math.round((premiumRequests + Number.EPSILON) * 100) / 100;
  if (!total && !subagents && !subscription && !premium) return null;
  const parts: string[] = [];
  if (total || subagents) parts.push(subscription ? total.toFixed(2) : `$${total.toFixed(2)}`);
  if (subagents) parts.push(`(+${subagents.toFixed(2)})`);
  if (premium) parts.push(`★ ${formatCount(premium)}`);
  return { subscriptionIcon: subscription, text: parts.join(" ") };
}

/** omp's run timer next to the spinner: `12s`, `3m`, `2h` (capped at 99h). */
export function runElapsedText(ms: number): string {
  const s = Math.floor(Math.max(0, ms) / 1000);
  if (s < 60) return `${s}s`;
  if (s < 3600) return `${Math.floor(s / 60)}m`;
  return `${Math.min(99, Math.floor(s / 3600))}h`;
}

/** Model segment text from room meta: `Opus 5.5` and `xhi` (null = not shown). */
export function modelSegment(
  rawModel: string | null | undefined,
  rawThinking: string | null | undefined
): { model: string; thinking: string | null } | null {
  const model = rawModel ? formatModelName(rawModel) : "";
  if (!model) return null;
  return { model, thinking: rawThinking ? thinkingLabel(rawThinking) : null };
}

/** Plain-text row, exactly as the terminal prints it minus the icons. */
export function statusLineText(
  line: StatusLine,
  rawModel: string | null | undefined,
  rawThinking: string | null | undefined,
  now: number
): string {
  const segments: string[] = [];
  if (line.runStartedAt !== null) segments.push(runElapsedText(now - line.runStartedAt));
  const m = modelSegment(rawModel, rawThinking);
  if (m) segments.push(m.thinking ? `${m.model} · ${m.thinking}` : m.model);
  segments.push(line.path);
  if (line.git) {
    const git = [line.git.branch ?? "", ...gitCounts(line.git).map((c) => c.text)].filter(Boolean).join(" ");
    if (git) segments.push(git);
  }
  segments.push(contextText(line.context));
  const cost = costText(line.cost);
  if (cost?.text) segments.push(cost.text);
  return segments.join(" · ");
}
