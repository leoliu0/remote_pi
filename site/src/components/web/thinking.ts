// Thinking traces in assistant text. pi-extension wraps the model's reasoning
// in `<think>…</think>` inside the streamed text; while a turn streams, the
// closing tag may not have arrived yet. The web shows these sections as a
// collapsible `Thinking` block (Settings → Show thinking traces) or strips
// them, independent of the tool display mode.

export interface TextSegment {
  kind: "text";
  text: string;
}

export interface ThinkingSegment {
  kind: "thinking";
  text: string;
  /** True while the closing `</think>` has not arrived (still streaming). */
  open: boolean;
}

export type MessageSegment = TextSegment | ThinkingSegment;

const OPEN_TAG = "<think>";
const CLOSE_TAG = "</think>";

/** Splits assistant text into plain and thinking segments, in order. Empty segments are dropped. */
export function splitThinking(text: string): MessageSegment[] {
  const segments: MessageSegment[] = [];
  const lower = text.toLowerCase();
  const pushText = (raw: string) => {
    // A closing tag without its opener (stream joined mid-trace) is noise.
    const clean = raw.replace(/<\/think>/gi, "").trim();
    if (clean) segments.push({ kind: "text", text: clean });
  };
  let pos = 0;
  while (pos < text.length) {
    const open = lower.indexOf(OPEN_TAG, pos);
    if (open < 0) {
      pushText(text.slice(pos));
      break;
    }
    pushText(text.slice(pos, open));
    const bodyStart = open + OPEN_TAG.length;
    const close = lower.indexOf(CLOSE_TAG, bodyStart);
    const body = text.slice(bodyStart, close < 0 ? text.length : close).trim();
    if (body || close < 0) segments.push({ kind: "thinking", text: body, open: close < 0 });
    if (close < 0) break;
    pos = close + CLOSE_TAG.length;
  }
  return segments;
}

/** The text with every thinking section (closed or still open) removed. */
export function stripThinking(text: string): string {
  return splitThinking(text)
    .flatMap((s) => (s.kind === "text" ? [s.text] : []))
    .join("\n\n");
}

export const SHOW_THINKING_KEY = "remotepi_show_thinking";
export const SHOW_THINKING_EVENT = "show_thinking_changed";

/** Settings → Show thinking traces. Default ON. */
export function readShowThinking(): boolean {
  try {
    return localStorage.getItem(SHOW_THINKING_KEY) !== "false";
  } catch {
    return true;
  }
}

export function writeShowThinking(show: boolean): void {
  try {
    localStorage.setItem(SHOW_THINKING_KEY, show ? "true" : "false");
    window.dispatchEvent(new Event(SHOW_THINKING_EVENT));
  } catch {}
}
