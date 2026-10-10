// Folds a room's live chat frames into the message list, the way the phone
// app does (app/lib/data/sync/sync_service.dart):
//
// - `agent_chunk` deltas grow one open assistant segment at the end of the list.
// - `tool_request` closes that segment first, so a turn renders
//   text → tool → text in order, the same as the `session_sync` history.
// - `agent_done` closes the last segment.
// - `agent_message` (sent after `agent_done`) carries the final assistant
//   message. It corrects the turn's trailing segment, or is added when nothing
//   of it was streamed. It is never shown a second time.
//
// Everything here is pure: the view keeps a `ChatState` and applies events.

import type { ToolCallData, WebChatMessage } from "./web-client";
import { splitThinking, stripThinking } from "./thinking.ts";
import { toolOutcome, type ToolOutcome } from "./tool-output.ts";

/** Where the live turn stands within `ChatState.messages`. */
export interface StreamCursor {
  /** `in_reply_to` of the turn being folded; null before any assistant output. */
  replyTo: string | null;
  /** Id of the segment still receiving chunks (always the last message). */
  openId: string | null;
  /** Closed text segments of the current turn, in order. */
  segmentIds: string[];
  /** `segmentIds.length` at this turn's latest tool boundary. */
  segmentsAtLastTool: number;
  /** Monotonic counter that keeps segment ids unique. */
  seq: number;
}

export interface ChatState {
  messages: WebChatMessage[];
  cursor: StreamCursor;
}

export type ChatEvent =
  /** `session_history`: replaces the list (an empty history keeps it). */
  | { type: "history"; messages: WebChatMessage[] }
  /** A user message: the local optimistic send or a `user_input` echo. */
  | { type: "user"; message: WebChatMessage }
  | { type: "chunk"; replyTo: string; delta: string }
  | { type: "done"; replyTo: string }
  /** `agent_message`: the final text of the turn's last assistant message. */
  | { type: "final"; replyTo: string; text: string }
  | { type: "tool_request"; tool: ToolCallData }
  | { type: "tool_result"; toolCallId: string; outcome: ToolOutcome }
  | { type: "compaction"; summary: string; tokensBefore: number };

const IDLE_CURSOR: StreamCursor = { replyTo: null, openId: null, segmentIds: [], segmentsAtLastTool: 0, seq: 0 };

export const EMPTY_CHAT: ChatState = { messages: [], cursor: IDLE_CURSOR };

/** Visible answer text: thinking removed, whitespace collapsed. */
function plainText(text: string): string {
  return stripThinking(text).replace(/\s+/g, " ").trim();
}

function closeSegment(state: ChatState): ChatState {
  const { openId } = state.cursor;
  if (!openId) return state;
  const open = state.messages.find((m) => m.id === openId);
  const cursor = { ...state.cursor, openId: null };
  // A segment with no text and no thinking would render an empty bubble.
  if (!open || open.text.replace(/<\/?think>/gi, "").trim() === "") {
    return { messages: state.messages.filter((m) => m.id !== openId), cursor };
  }
  return {
    messages: state.messages.map((m) => (m.id === openId ? { ...m, isStreaming: false } : m)),
    cursor: { ...cursor, segmentIds: [...cursor.segmentIds, openId] },
  };
}

/** A different `in_reply_to` starts a new turn: close the old one's segment. */
function trackTurn(state: ChatState, replyTo: string): ChatState {
  if (state.cursor.replyTo === replyTo) return state;
  const closed = closeSegment(state);
  return { ...closed, cursor: { ...closed.cursor, replyTo, segmentIds: [], segmentsAtLastTool: 0 } };
}

function appendChunk(state: ChatState, replyTo: string, delta: string, now: number): ChatState {
  const s = trackTurn(state, replyTo);
  const { openId, seq } = s.cursor;
  if (openId) {
    return { ...s, messages: s.messages.map((m) => (m.id === openId ? { ...m, text: m.text + delta } : m)) };
  }
  if (!delta) return s;
  const id = `stream-${replyTo}-${seq}`;
  return {
    messages: [...s.messages, { id, role: "assistant", text: delta, timestamp: now, isStreaming: true }],
    cursor: { ...s.cursor, openId: id, seq: seq + 1 },
  };
}

function applyFinal(state: ChatState, replyTo: string, text: string, now: number): ChatState {
  const s = closeSegment(trackTurn(state, replyTo));
  const want = plainText(text);
  if (!want) return s;
  // Already on screen for this prompt (streamed, or in a history resync).
  const lastUser = s.messages.findLastIndex((m) => m.role === "user");
  if (s.messages.slice(lastUser + 1).some((m) => m.role === "assistant" && plainText(m.text) === want)) return s;

  const { segmentIds, segmentsAtLastTool, seq } = s.cursor;
  const tail = segmentIds.slice(segmentsAtLastTool);
  if (tail.length === 1) {
    // The streamed copy of this message is incomplete: complete it in place.
    const id = tail[0];
    return {
      ...s,
      messages: s.messages.map((m) => {
        if (m.id !== id) return m;
        // Keep the streamed thinking: the final text carries none (history's form).
        const thinking = /<think>/i.test(text)
          ? ""
          : splitThinking(m.text)
              .flatMap((seg) => (seg.kind === "thinking" && seg.text ? [`<think>${seg.text}</think>`] : []))
              .join("\n\n");
        return { ...m, text: thinking ? `${thinking}\n\n${text}` : text };
      }),
    };
  }
  // Several segments, or the turn ended on a tool: the final text belongs to
  // one of them already (the app skips it the same way).
  if (segmentIds.length > 0) return s;
  const id = `stream-${replyTo}-${seq}`;
  return {
    messages: [...s.messages, { id, role: "assistant", text, timestamp: now }],
    cursor: { ...s.cursor, segmentIds: [id], seq: seq + 1 },
  };
}

export function applyChatEvent(state: ChatState, event: ChatEvent, now: number): ChatState {
  switch (event.type) {
    case "history":
      if (event.messages.length === 0) return state;
      return { messages: event.messages, cursor: { ...IDLE_CURSOR, seq: state.cursor.seq } };

    case "user": {
      const { message } = event;
      if (state.messages.some((m) => m.id === message.id)) {
        return { ...state, messages: state.messages.map((m) => (m.id === message.id ? { ...m, ...message } : m)) };
      }
      const s = closeSegment(state);
      return { ...s, messages: [...s.messages, message] };
    }

    case "chunk":
      return appendChunk(state, event.replyTo, event.delta, now);

    case "done":
      return closeSegment(trackTurn(state, event.replyTo));

    case "final":
      return applyFinal(state, event.replyTo, event.text, now);

    case "tool_request": {
      const s = closeSegment(state);
      const cursor = { ...s.cursor, segmentsAtLastTool: s.cursor.segmentIds.length };
      const id = `tool-${event.tool.id}`;
      if (s.messages.some((m) => m.id === id)) return { ...s, cursor };
      const { tool } = event;
      const message: WebChatMessage = {
        id,
        role: "tool",
        text: `${tool.tool}: ${tool.command || JSON.stringify(tool.args || {})}`,
        timestamp: now,
        tool,
      };
      return { messages: [...s.messages, message], cursor };
    }

    case "tool_result": {
      const { output, isError } = event.outcome;
      return {
        ...state,
        messages: state.messages.map((m) =>
          m.tool && m.tool.id === event.toolCallId
            ? { ...m, tool: { ...m.tool, status: isError ? "error" : "done", output } }
            : m
        ),
      };
    }

    case "compaction": {
      const s = closeSegment(state);
      const message: WebChatMessage = {
        id: `comp-${now}`,
        role: "compaction",
        text: event.summary,
        timestamp: now,
        tokensBefore: event.tokensBefore,
      };
      return { ...s, messages: [...s.messages, message] };
    }
  }
}

function toolCallFromFrame(frame: Record<string, unknown>, fallbackId: string): ToolCallData {
  const args = frame.args && typeof frame.args === "object" ? (frame.args as Record<string, unknown>) : undefined;
  return {
    id: (frame.tool_call_id as string) || fallbackId,
    tool: frame.tool as string,
    args,
    command: typeof args?.command === "string" ? args.command : undefined,
    // No result yet → still running; a later tool_result completes it.
    status: "pending",
  };
}

/** `session_history.events` → the message list a resync shows. */
export function historyMessages(events: unknown[], now: number): WebChatMessage[] {
  const out: WebChatMessage[] = [];
  const tools = new Map<string, ToolCallData>();
  events.forEach((raw, i) => {
    if (!raw || typeof raw !== "object") return;
    const ev = raw as Record<string, unknown>;
    const eventId = (ev.id as string) || (ev.tool_call_id as string);
    const ts = (ev.ts as number) || now;
    if (ev.type === "user_input") {
      out.push({ id: eventId || `hist-user-${ts}-${i}`, role: "user", text: (ev.text as string) || "", timestamp: ts, status: "sent" });
    } else if (ev.type === "agent_message") {
      out.push({ id: eventId || `hist-asst-${ts}-${i}`, role: "assistant", text: (ev.text as string) || "", timestamp: ts });
    } else if (ev.type === "tool_request") {
      const tool = toolCallFromFrame(ev, eventId || `tc_${ts}_${i}`);
      tools.set(tool.id, tool);
      out.push({ id: `hist-tool-${tool.id}-${i}`, role: "tool", text: `${ev.tool}: ${JSON.stringify(ev.args || {})}`, timestamp: ts, tool });
    } else if (ev.type === "tool_result") {
      const tool = tools.get(ev.tool_call_id as string);
      if (tool) {
        const { output, isError } = toolOutcome(ev.result, ev.error);
        tool.output = output;
        tool.status = isError ? "error" : "done";
      }
    } else if (ev.type === "compaction") {
      out.push({
        id: eventId || `hist-comp-${ts}-${i}`,
        role: "compaction",
        text: (ev.summary as string) || "Context compacted",
        timestamp: ts,
        tokensBefore: ev.tokens_before as number,
      });
    }
  });
  return out;
}

/** A room frame → the chat event it carries, or null for non-chat frames. */
export function chatEventFromFrame(frame: Record<string, unknown>, now: number): ChatEvent | null {
  switch (frame.type) {
    case "session_history":
      return Array.isArray(frame.events) ? { type: "history", messages: historyMessages(frame.events, now) } : null;
    case "user_input":
      return {
        type: "user",
        message: {
          id: (frame.id as string) || `user-${now}`,
          role: "user",
          text: (frame.text as string) || "",
          timestamp: now,
          status: "sent",
        },
      };
    case "agent_chunk":
      return { type: "chunk", replyTo: (frame.in_reply_to as string) || "", delta: (frame.delta as string) || "" };
    case "agent_done":
      return { type: "done", replyTo: (frame.in_reply_to as string) || "" };
    case "agent_message":
      return { type: "final", replyTo: (frame.in_reply_to as string) || "", text: (frame.text as string) || "" };
    case "tool_request":
      return { type: "tool_request", tool: toolCallFromFrame(frame, "") };
    case "tool_result":
      return { type: "tool_result", toolCallId: frame.tool_call_id as string, outcome: toolOutcome(frame.result, frame.error) };
    case "compaction":
      return {
        type: "compaction",
        summary: (frame.summary as string) || "Context compacted",
        tokensBefore: (frame.tokens_before as number) || 0,
      };
    default:
      return null;
  }
}
