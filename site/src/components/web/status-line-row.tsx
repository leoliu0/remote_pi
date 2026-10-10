"use client";

import { useEffect, useState, type ReactNode } from "react";
import { BrailleSpinner } from "./braille-spinner";
import {
  contextText,
  contextTone,
  costText,
  gitCounts,
  modelSegment,
  runElapsedText,
  statusLineText,
  type ContextTone,
  type StatusLine,
} from "./status-line";

// omp's dark-ember theme colours for the status line.
const SEP = "#5c6370";
const MODEL = "#ff6f61";
const PATH = "#5f8dd3";
const GIT_CLEAN = "#98c379";
const GIT_DIRTY = "#e5c07b";
const COUNT: Record<"unstaged" | "staged" | "untracked", string> = {
  unstaged: "#d7af00",
  staged: "#008700",
  untracked: "#00afff",
};
const COST = "#ff5faf";
const CONTEXT: Record<ContextTone, string> = {
  normal: "#abb2bf",
  warning: "#e5c07b",
  purple: "#ff6f61",
  error: "#e06c75",
};

function Icon({ children, title }: { children: ReactNode; title?: string }) {
  return (
    <svg
      className="w-3 h-3 shrink-0"
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth="2"
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden={title ? undefined : true}
    >
      {title && <title>{title}</title>}
      {children}
    </svg>
  );
}

// omp's nerd symbols for thinking are circle slices (min ⅛ … xhi full), fire for max.
const THINKING_SLICE: Record<string, number> = { minimal: 1 / 8, low: 2 / 8, medium: 4 / 8, high: 6 / 8, xhigh: 1 };

function ThinkingIcon({ level }: { level: string }) {
  if (level === "max") {
    return (
      <Icon>
        <path d="M8.5 14.5A2.5 2.5 0 0 0 11 12c0-1.38-.5-2-1-3-1.07-2.14-.22-4.05 2-6 .5 2.5 2 4.9 4 6.5 2 1.6 3 3.5 3 5.5a7 7 0 1 1-14 0c0-1.15.43-2.29 1-3a2.5 2.5 0 0 0 2.5 2.5z" />
      </Icon>
    );
  }
  if (level === "off") {
    return (
      <Icon>
        <circle cx="12" cy="12" r="9" />
        <path d="m5.6 5.6 12.8 12.8" />
      </Icon>
    );
  }
  const slice = THINKING_SLICE[level];
  if (slice === undefined) {
    // auto (unresolved) and unknown levels: omp's autoPending shuffle glyph.
    return (
      <Icon>
        <path d="m18 14 4 4-4 4" />
        <path d="m18 2 4 4-4 4" />
        <path d="M2 18h1.97a4 4 0 0 0 3.3-1.7l5.46-8.6a4 4 0 0 1 3.3-1.7H22" />
        <path d="M2 6h1.97a4 4 0 0 1 3.3 1.7l.53.8" />
        <path d="M22 18h-6.04a4 4 0 0 1-3.3-1.8l-.36-.45" />
      </Icon>
    );
  }
  const angle = slice * 2 * Math.PI;
  const x = 12 + 9 * Math.sin(angle);
  const y = 12 - 9 * Math.cos(angle);
  return (
    <Icon>
      <circle cx="12" cy="12" r="9" />
      {slice >= 1 ? (
        <circle cx="12" cy="12" r="9" fill="currentColor" stroke="none" />
      ) : (
        <path d={`M12 12 L12 3 A9 9 0 ${slice > 0.5 ? 1 : 0} 1 ${x.toFixed(2)} ${y.toFixed(2)} Z`} fill="currentColor" stroke="none" />
      )}
    </Icon>
  );
}

/**
 * One segment with its leading `·`, kept whole: the row is one line tall and
 * wraps, so a segment that no longer fits drops out of sight instead of being
 * cut (omp drops trailing segments the same way).
 */
function Seg({
  color,
  className = "shrink-0",
  title,
  children,
}: {
  color: string;
  className?: string;
  title?: string;
  children: ReactNode;
}) {
  return (
    <span className={`inline-flex items-center ${className}`} style={{ color }} title={title}>
      <span aria-hidden className="px-1" style={{ color: SEP }}>
        ·
      </span>
      <span className="inline-flex items-center gap-1 min-w-0">{children}</span>
    </span>
  );
}

/** Ticks once a second while the agent runs (π segment timer). */
function useRunNow(runStartedAt: number | null): number {
  const [now, setNow] = useState(() => Date.now());
  useEffect(() => {
    if (runStartedAt === null) return;
    const tick = () => setNow(Date.now());
    const first = setTimeout(tick, 0);
    const every = setInterval(tick, 1000);
    return () => {
      clearTimeout(first);
      clearInterval(every);
    };
  }, [runStartedAt]);
  return now;
}

/** The terminal's footer row under the composer: `π · model · thinking · path · git · context · cost`. */
export function StatusLineRow({
  line,
  model,
  thinking,
}: {
  line: StatusLine;
  model?: string | null;
  thinking?: string | null;
}) {
  const now = useRunNow(line.runStartedAt);
  const m = modelSegment(model, thinking);
  const git = line.git;
  const counts = git ? gitCounts(git) : [];
  const cost = costText(line.cost);
  return (
    <div
      role="status"
      aria-label={statusLineText(line, model, thinking, now)}
      data-testid="status-line"
      className="mt-1 px-1 h-5 flex flex-wrap items-center min-w-0 overflow-hidden whitespace-nowrap font-mono text-[11px] leading-5"
    >
      <span className="inline-flex items-center gap-1 shrink-0" style={{ color: SEP }}>
        {line.runStartedAt !== null ? (
          <>
            <BrailleSpinner />
            <span>{runElapsedText(now - line.runStartedAt)}</span>
          </>
        ) : (
          <span aria-hidden>π</span>
        )}
      </span>
      {m && (
        <Seg color={MODEL}>
          <Icon>
            <rect x="4" y="4" width="16" height="16" rx="2" />
            <rect x="9" y="9" width="6" height="6" />
            <path d="M15 2v2M15 20v2M2 15h2M2 9h2M20 15h2M20 9h2M9 2v2M9 20v2" />
          </Icon>
          <span>{m.model}</span>
        </Seg>
      )}
      {m?.thinking && thinking && (
        <Seg color={MODEL}>
          <ThinkingIcon level={thinking} />
          <span>{m.thinking}</span>
        </Seg>
      )}
      {/* The path gives way first: it shrinks to ~10ch (head clipped, like
          omp's leading `…`) before any later segment drops. */}
      <Seg color={PATH} className="min-w-0 grow basis-[10ch] max-w-max" title={line.cwd}>
        {line.scratch ? (
          <Icon>
            <path d="M3 6h18M19 6v14c0 1-1 2-2 2H7c-1 0-2-1-2-2V6M8 6V4c0-1 1-2 2-2h4c1 0 2 1 2 2v2" />
          </Icon>
        ) : (
          <Icon>
            <path d="m6 14 1.5-2.9A2 2 0 0 1 9.24 10H20a2 2 0 0 1 1.94 2.5l-1.54 6a2 2 0 0 1-1.95 1.5H4a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h3.9a2 2 0 0 1 1.69.9l.81 1.2a2 2 0 0 0 1.67.9H18a2 2 0 0 1 2 2v2" />
          </Icon>
        )}
        <span dir="rtl" className="truncate min-w-0">
          <bdi dir="ltr">{line.path}</bdi>
        </span>
      </Seg>
      {git && (git.branch || counts.length > 0) && (
        <Seg color={counts.length > 0 ? GIT_DIRTY : GIT_CLEAN}>
          <Icon>
            <circle cx="12" cy="18" r="3" />
            <circle cx="6" cy="6" r="3" />
            <circle cx="18" cy="6" r="3" />
            <path d="M18 9v2c0 .6-.4 1-1 1H7c-.6 0-1-.4-1-1V9" />
            <path d="M12 12v3" />
          </Icon>
          {git.branch && <span className="truncate max-w-[16ch]">{git.branch}</span>}
          {counts.map((c) => (
            <span key={c.kind} style={{ color: COUNT[c.kind] }}>
              {c.text}
            </span>
          ))}
        </Seg>
      )}
      <Seg color={CONTEXT[contextTone(line.context.percent, line.context.window)]}>
        <Icon>
          <path d="M3 5.5 10.5 4.5v7H3zM12.5 4.2 21 3v8.5h-8.5zM3 12.5h7.5v7L3 18.5zM12.5 12.5H21V21l-8.5-1.2z" fill="currentColor" stroke="none" />
        </Icon>
        <span>{contextText(line.context)}</span>
      </Seg>
      {cost && (
        <Seg color={COST}>
          {cost.subscriptionIcon && (
            <Icon title="Subscription">
              <rect x="2" y="5" width="20" height="14" rx="2" />
              <path d="M2 10h20" />
            </Icon>
          )}
          {cost.text && <span>{cost.text}</span>}
        </Seg>
      )}
    </div>
  );
}
