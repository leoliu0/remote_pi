import type { WebChatMessage } from "./web-client";

// When the chat list follows new content. "Stick" is the reader's intent: on
// at the bottom, off as soon as they move up, and only reaching the bottom
// again (or sending, or the scroll-to-bottom button) turns it back on.
// Following pins only ever move scrollTop down, so they never unset it.

/** Within this distance of the bottom the list counts as "at the bottom". */
export const STICK_DISTANCE_PX = 40;

export interface ScrollMetrics {
  scrollTop: number;
  scrollHeight: number;
  clientHeight: number;
}

export function distanceFromBottom(m: ScrollMetrics): number {
  return m.scrollHeight - m.scrollTop - m.clientHeight;
}

/**
 * Stick after a scroll event, given the scrollTop of the previous one. Any
 * upward move unsets it (a small trackpad step stays inside the bottom zone),
 * except a clamp to the very bottom when the content got shorter.
 */
export function stickAfterScroll(stick: boolean, prevScrollTop: number, m: ScrollMetrics): boolean {
  const fromBottom = distanceFromBottom(m);
  if (fromBottom <= 1) return true;
  if (m.scrollTop < prevScrollTop) return false;
  return fromBottom <= STICK_DISTANCE_PX ? true : stick;
}

/**
 * Stick after an upward wheel, touch or key gesture, before its scroll event
 * lands. A list already at its top (or with nothing to scroll) keeps following.
 */
export function stickAfterUpIntent(stick: boolean, m: ScrollMetrics): boolean {
  return m.scrollTop > 0 ? false : stick;
}

export function wheelScrollsUp(deltaY: number): boolean {
  return deltaY < 0;
}

/** A finger moving down drags the content up. */
export function touchScrollsUp(prevClientY: number, clientY: number): boolean {
  return clientY > prevClientY;
}

export function keyScrollsUp(key: string, shiftKey: boolean): boolean {
  return key === "PageUp" || key === "Home" || key === "ArrowUp" || (key === " " && shiftKey);
}

/** New user/assistant rows (errors are assistant rows); a streamed delta grows its row in place. */
export function unreadRows(prev: readonly WebChatMessage[], next: readonly WebChatMessage[]): number {
  const seen = new Set(prev.map((m) => m.id));
  return next.filter((m) => (m.role === "user" || m.role === "assistant") && !seen.has(m.id)).length;
}

/** Where the reader is, kept across a history resync that replaces the rows. */
export interface ScrollAnchor {
  /** First row on screen, or null when none is. */
  id: string | null;
  /** Its top relative to the list's top edge. */
  offset: number;
  /** Fallback when the row is gone. */
  fromBottom: number;
}

/** `rows` in order, with top/bottom relative to the list's top edge. */
export function pickAnchor(
  rows: ReadonlyArray<{ id: string; top: number; bottom: number }>,
  fromBottom: number
): ScrollAnchor {
  const row = rows.find((r) => r.bottom > 0);
  return row ? { id: row.id, offset: row.top, fromBottom } : { id: null, offset: 0, fromBottom };
}

/** scrollTop that puts the anchor back; `rowTop` is the anchor row's top now, or null if it is gone. */
export function restoredScrollTop(anchor: ScrollAnchor, rowTop: number | null, m: ScrollMetrics): number {
  if (rowTop !== null) return m.scrollTop + rowTop - anchor.offset;
  return Math.max(0, m.scrollHeight - m.clientHeight - anchor.fromBottom);
}
