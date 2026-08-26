export interface PairedSession {
  id: string;
  name: string;
  device: string;
  remoteEpk: string;
  token?: string;
  relayUrl: string;
  roomId: string;
  cwd?: string;
  model?: string;
  pairedAt: string;
  lastConnectedAt?: string;
}

export type MessageRole = "user" | "assistant" | "tool" | "compaction" | "system";

export interface ToolCallData {
  id: string;
  tool: string;
  args?: Record<string, unknown> | null;
  command?: string;
  output?: string;
  status: "pending" | "allowed" | "denied" | "done" | "error";
  error?: string;
  diff?: {
    file?: string;
    oldContent?: string;
    newContent?: string;
    hunks?: string[];
  };
}

export interface WebChatMessage {
  id: string;
  role: MessageRole;
  text: string;
  timestamp: number;
  image?: {
    data: string;
    mime: string;
  };
  tool?: ToolCallData;
  isStreaming?: boolean;
  status?: "sending" | "sent" | "failed";
  tokensBefore?: number;
  tokensAfter?: number;
}

export type ConnectionState = "disconnected" | "connecting" | "pairing" | "connected" | "reconnecting" | "error";
export type PeerPresence = "online" | "working" | "offline" | "unknown";

export function parsePairUri(uri: string): Partial<PairedSession> | null {
  try {
    const trimmed = uri.trim();
    let url: URL;
    if (trimmed.startsWith("remotepi://")) {
      url = new URL(trimmed.replace("remotepi://", "https://dummy.host/"));
    } else if (trimmed.startsWith("http://") || trimmed.startsWith("https://") || trimmed.startsWith("wss://")) {
      url = new URL(trimmed);
    } else {
      // Try parsing query string directly
      url = new URL(`https://dummy.host/pair?${trimmed}`);
    }

    const epk = url.searchParams.get("epk") || url.searchParams.get("k");
    const token = url.searchParams.get("t") || url.searchParams.get("token");
    const relay = url.searchParams.get("r") || url.searchParams.get("relay") || "wss://relay-rp1.jacobmoura.work";
    const room = url.searchParams.get("rm") || url.searchParams.get("room") || "main";

    if (!epk && !token) return null;

    return {
      remoteEpk: epk || "",
      token: token || undefined,
      relayUrl: relay,
      roomId: room,
      name: room === "main" ? "Remote Pi" : room,
      device: epk ? `Device (${epk.substring(0, 8)})` : "MacBook / Linux",
    };
  } catch {
    return null;
  }
}

const STORAGE_KEY_SESSIONS = "remotepi_web_sessions_v1";
const STORAGE_KEY_ACTIVE = "remotepi_web_active_id_v1";

export function getSavedSessions(): PairedSession[] {
  if (typeof window === "undefined") return [];
  try {
    const raw = localStorage.getItem(STORAGE_KEY_SESSIONS);
    if (!raw) return [];
    return JSON.parse(raw);
  } catch {
    return [];
  }
}

export function saveSession(session: PairedSession): void {
  if (typeof window === "undefined") return;
  try {
    const list = getSavedSessions();
    const idx = list.findIndex((s) => s.id === session.id || (s.remoteEpk === session.remoteEpk && s.roomId === session.roomId));
    if (idx >= 0) {
      list[idx] = { ...list[idx], ...session };
    } else {
      list.unshift(session);
    }
    localStorage.setItem(STORAGE_KEY_SESSIONS, JSON.stringify(list));
    localStorage.setItem(STORAGE_KEY_ACTIVE, session.id);
  } catch (err) {
    console.error("Failed to save session", err);
  }
}

export function deleteSession(id: string): void {
  if (typeof window === "undefined") return;
  try {
    const list = getSavedSessions().filter((s) => s.id !== id);
    localStorage.setItem(STORAGE_KEY_SESSIONS, JSON.stringify(list));
    if (localStorage.getItem(STORAGE_KEY_ACTIVE) === id) {
      localStorage.removeItem(STORAGE_KEY_ACTIVE);
    }
  } catch (err) {
    console.error("Failed to delete session", err);
  }
}

export function getActiveSessionId(): string | null {
  if (typeof window === "undefined") return null;
  return localStorage.getItem(STORAGE_KEY_ACTIVE);
}

export function setActiveSessionId(id: string): void {
  if (typeof window === "undefined") return;
  localStorage.setItem(STORAGE_KEY_ACTIVE, id);
}

export const INITIAL_DEMO_MESSAGES: WebChatMessage[] = [
  {
    id: "m-1",
    role: "user",
    text: "Can you analyze the repository architecture and check our tests?",
    timestamp: Date.now() - 120000,
    status: "sent",
  },
  {
    id: "m-2",
    role: "tool",
    text: "bash: cd app && flutter test",
    timestamp: Date.now() - 100000,
    tool: {
      id: "t-1",
      tool: "bash",
      command: "cd app && flutter test",
      output: "00:07 +583: All tests passed!\nWall time: 10.16 seconds",
      status: "done",
    },
  },
  {
    id: "m-3",
    role: "tool",
    text: "edit: app/lib/ui/chat/chat_page.dart",
    timestamp: Date.now() - 80000,
    tool: {
      id: "t-2",
      tool: "edit",
      command: "edit app/lib/ui/chat/chat_page.dart",
      status: "done",
      diff: {
        file: "app/lib/ui/chat/chat_page.dart",
        hunks: [
          "- class ChatPage extends StatelessWidget {",
          "+ class ChatPage extends StatefulWidget {",
          "+   final ScrollController _scrollController = ScrollController();",
          "+   // Auto-scrolls on send and renders _ScrollToBottomButton",
        ],
      },
    },
  },
  {
    id: "m-4",
    role: "assistant",
    text: "All **583 unit and widget tests** are green!\n\nHere is a summary of the latest updates:\n- **Auto-scroll to bottom**: `onSend` and `onSetQueued` now smoothly animate down to latest messages.\n- **Floating button**: `_ScrollToBottomButton` with animated scale & opacity appears when browsing chat history.\n\nReady for your next command.",
    timestamp: Date.now() - 60000,
  },
];
