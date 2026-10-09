// Pure helpers behind the chat's tool cards. The live `tool_result` frame and
// the replayed history event carry the same fields (`result` on success,
// `error` on failure — pi-extension `_stringifyToolResult`), so both paths
// normalise through `toolOutcome` and the card renders one `output` string.
//
// The bash card mirrors the terminal's Full mode and the phone's card (same
// strings on both sides):
//   $ <command>
//   <intent>            (muted, when args.i is set)
//   in <cwd>            (muted, when args.cwd is set)
//   Output
//   <body | (no output)>
//   Wall: 0.00s | Timeout: 300s | exit 127      (exit only when non-zero, red)

export interface ToolOutcome {
  output: string;
  isError: boolean;
}

function stringify(value: unknown): string {
  if (value === undefined || value === null) return "";
  if (typeof value === "string") return value;
  try {
    return JSON.stringify(value, null, 2) ?? String(value);
  } catch {
    return String(value);
  }
}

/** One `tool_result` (live or history) → the text the card shows. */
export function toolOutcome(result: unknown, error: unknown): ToolOutcome {
  if (error !== undefined && error !== null) return { output: stringify(error), isError: true };
  return { output: stringify(result), isError: false };
}

export interface BashOutput {
  /** Output with the trailing wall-time / exit-code lines removed. */
  body: string;
  wallSeconds: number | null;
  exitCode: number | null;
}

const WALL_LINE = /^Wall time: (\d+(?:\.\d+)?) seconds$/;
const EXIT_LINE = /^Command exited with code (-?\d+)$/;

/** Splits the bash tool text into its body and the trailing status lines. */
export function parseBashOutput(text: string): BashOutput {
  const lines = text.replace(/\r\n/g, "\n").split("\n");
  let wallSeconds: number | null = null;
  let exitCode: number | null = null;
  for (;;) {
    while (lines.length > 0 && lines[lines.length - 1].trim() === "") lines.pop();
    const last = lines.length > 0 ? lines[lines.length - 1].trim() : "";
    const wall = WALL_LINE.exec(last);
    const exit = EXIT_LINE.exec(last);
    if (wall && wallSeconds === null) wallSeconds = Number(wall[1]);
    else if (exit && exitCode === null) exitCode = Number(exit[1]);
    else break;
    lines.pop();
  }
  return { body: lines.join("\n"), wallSeconds, exitCode };
}

/** `args.timeout` in seconds, when the call carried one. */
export function bashTimeoutSeconds(args: Record<string, unknown> | null | undefined): number | null {
  const raw = args?.timeout;
  const n = typeof raw === "number" ? raw : typeof raw === "string" && raw.trim() ? Number(raw) : NaN;
  return Number.isFinite(n) ? n : null;
}

export interface BashFooter {
  /** `Wall: 0.00s | Timeout: 300s`, or `Running…` while the call is pending. */
  text: string;
  /** `exit 127` when the exit code is non-zero (rendered red), else null. */
  exit: string | null;
}

export function bashFooter(parsed: BashOutput | null, timeoutSeconds: number | null): BashFooter {
  if (!parsed) return { text: "Running…", exit: null };
  const parts: string[] = [];
  if (parsed.wallSeconds !== null) parts.push(`Wall: ${parsed.wallSeconds.toFixed(2)}s`);
  if (timeoutSeconds !== null) parts.push(`Timeout: ${timeoutSeconds}s`);
  const exit = parsed.exitCode !== null && parsed.exitCode !== 0 ? `exit ${parsed.exitCode}` : null;
  return { text: parts.join(" | "), exit };
}

/** The footer as one line, e.g. `Wall: 0.00s | Timeout: 300s | exit 127`. */
export function bashFooterLine(footer: BashFooter): string {
  return [footer.text, footer.exit].filter((s): s is string => !!s).join(" | ");
}

export interface BashCard {
  command: string;
  intent: string | null;
  cwd: string | null;
  /** Null while the call is still running. */
  body: string | null;
  footer: BashFooter;
}

function argString(args: Record<string, unknown> | null | undefined, key: string): string | null {
  const v = args?.[key];
  return typeof v === "string" && v.trim() ? v : null;
}

/** Everything the bash Full card shows, from the call's args and its output. */
export function bashCard(
  args: Record<string, unknown> | null | undefined,
  output: string | null,
): BashCard {
  const parsed = output === null ? null : parseBashOutput(output);
  return {
    command: argString(args, "command") ?? "",
    intent: argString(args, "i")?.trim() ?? null,
    cwd: argString(args, "cwd"),
    body: parsed === null ? null : parsed.body.trim() === "" ? "(no output)" : parsed.body,
    footer: bashFooter(parsed, bashTimeoutSeconds(args)),
  };
}

export interface ArgRow {
  key: string;
  value: string;
}

/** Tool args as readable key/value rows; nested values fall back to JSON. */
export function argRows(args: Record<string, unknown> | null | undefined): ArgRow[] {
  if (!args) return [];
  return Object.entries(args).map(([key, v]) => ({
    key,
    value: typeof v === "string" ? v : v === undefined ? "" : (JSON.stringify(v, null, 2) ?? String(v)),
  }));
}

/** Brief-pill summary: the intent the terminal prints, else the main argument. */
export function toolSummary(args: Record<string, unknown> | null | undefined): string {
  for (const key of ["i", "command", "path", "pattern", "query", "url"]) {
    const v = argString(args, key);
    if (v) return v.trim();
  }
  return args && Object.keys(args).length > 0 ? JSON.stringify(args) : "";
}
