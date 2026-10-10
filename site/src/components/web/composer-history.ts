// Composer message history (Up/Down recall), ported from the app's InputBar
// (app/lib/ui/chat/widgets/input_bar.dart: _combinedHistory,
// _recallPreviousMessage, _recallNextMessage). Pure; web-chat.tsx owns the state.

/** Browsing position. `index` counts back from the newest entry (0 = newest); -1 = not browsing. */
export interface HistoryNav {
  index: number;
  /** What was in the composer before the first recall; restored when stepping past the newest. */
  savedDraft: string;
}

export const HISTORY_IDLE: HistoryNav = { index: -1, savedDraft: "" };

export interface Recall {
  nav: HistoryNav;
  /** New composer text; the caret goes to its end. */
  text: string;
}

export interface ComposerInput {
  text: string;
  selectionStart: number;
  selectionEnd: number;
}

function pushTrimmed(list: string[], raw: string): void {
  const t = raw.trim();
  if (t && list[list.length - 1] !== t) list.push(t);
}

/**
 * Oldest → newest: the chat's user messages, then texts sent or queued from
 * this tab, trimmed, with consecutive duplicates collapsed. A local text that
 * has already reached the chat (sends show up there immediately, queued ones
 * once delivered) is counted once, not twice.
 */
export function buildComposerHistory(chatUserTexts: readonly string[], localTexts: readonly string[]): string[] {
  const list: string[] = [];
  const inChat = new Map<string, number>();
  for (const raw of chatUserTexts) {
    pushTrimmed(list, raw);
    const t = raw.trim();
    if (t) inChat.set(t, (inChat.get(t) ?? 0) + 1);
  }
  for (const raw of localTexts) {
    const t = raw.trim();
    const pending = inChat.get(t) ?? 0;
    if (pending > 0) {
      inChat.set(t, pending - 1);
      continue;
    }
    pushTrimmed(list, t);
  }
  return list;
}

/** One step older; the first step saves `currentText` as the draft. Stays put at the oldest. */
export function recallOlder(history: readonly string[], nav: HistoryNav, currentText: string): Recall | null {
  if (history.length === 0) return null;
  if (nav.index + 1 >= history.length) return { nav, text: currentText };
  const index = nav.index + 1;
  const savedDraft = nav.index === -1 ? currentText : nav.savedDraft;
  return { nav: { index, savedDraft }, text: history[history.length - 1 - index] };
}

/** One step newer; past the newest, leaves history mode and restores the saved draft. */
export function recallNewer(history: readonly string[], nav: HistoryNav): Recall | null {
  if (nav.index < 0) return null;
  const index = Math.min(nav.index - 1, history.length - 1);
  if (index < 0) return { nav: HISTORY_IDLE, text: nav.savedDraft };
  return { nav: { index, savedDraft: nav.savedDraft }, text: history[history.length - 1 - index] };
}

/**
 * Plain ArrowUp/ArrowDown in the composer. Returns the recall to apply, or
 * null to let the textarea move the caret (multi-line editing, nothing to recall).
 */
export function historyKey(
  key: string,
  input: ComposerInput,
  history: readonly string[],
  nav: HistoryNav,
): Recall | null {
  // Up only from the first line, Down only from the last; elsewhere the caret moves.
  if (key === "ArrowUp") {
    if (input.text.slice(0, input.selectionStart).includes("\n")) return null;
    return recallOlder(history, nav, input.text);
  }
  if (key === "ArrowDown") {
    if (nav.index < 0 || input.text.slice(input.selectionEnd).includes("\n")) return null;
    return recallNewer(history, nav);
  }
  return null;
}

export interface HistoryHint {
  label: string;
  canGoOlder: boolean;
  /** The Down step's action: another message, or back to the draft. */
  newerLabel: "Newer" | "Clear";
}

/** The app's 'History n/N' bar while browsing; null otherwise. */
export function historyHint(history: readonly string[], nav: HistoryNav): HistoryHint | null {
  if (nav.index < 0 || history.length === 0) return null;
  return {
    label: `History ${nav.index + 1}/${history.length}`,
    canGoOlder: nav.index + 1 < history.length,
    newerLabel: nav.index > 0 ? "Newer" : "Clear",
  };
}
