"use client";

import { useState, useEffect, useLayoutEffect, useMemo, useRef } from "react";
import {
  WebChatMessage,
  PairedSession,
  PeerPresence,
  RemotePiRelayClient,
} from "./web-client";
import { AssistantContent } from "./thinking-block";
import { readShowThinking, SHOW_THINKING_EVENT } from "./thinking";
import { AgentsBottomPanel, AgentsSideColumn } from "./activity-panel";
import { EMPTY_BOARD, applyActivitySnapshot, clearFinished, type AgentBoard } from "./activity";
import { BrailleSpinner } from "./braille-spinner";
import type { RelayConnection } from "./relay-connection";
import { workingLabel } from "./working-label";
import { ToolFullCard, ToolPill } from "./tool-card";
import { ExtensionUiPrompt } from "./extension-ui-prompt";
import { applyExtensionUiRequest, type ExtensionUiResponseWire, type PendingPrompt } from "./extension-ui";

type ToolDisplay = "brief" | "full" | "hidden";

function readToolDisplay(): ToolDisplay {
  try {
    const saved = localStorage.getItem("remotepi_tool_display");
    if (saved === "brief" || saved === "full" || saved === "hidden") return saved;
  } catch {}
  return "brief";
}

interface WebChatProps {
  session: PairedSession;
  connection: RelayConnection;
  /** This room's state from the relay's room/presence frames (Home's source of truth). */
  roomPresence: PeerPresence;
  onDisconnect: () => void;
  onOpenSessionInfo: () => void;
  onOpenQuickActions: () => void;
  onOpenSettings?: () => void;
}

const READ_ONLY_TOOLS = new Set([
  "read",
  "grep",
  "glob",
  "find",
  "ls",
  "view",
  "cat",
  "head",
  "tail",
  "web_search",
  "google_web_search",
  "mcp__read",
  "mcp__grep",
  "mcp__glob",
  "mcp__gemini_search_google_web_search",
]);

export function WebChat({
  session,
  connection,
  roomPresence,
  onDisconnect,
  onOpenSessionInfo,
  onOpenQuickActions,
  onOpenSettings,
}: WebChatProps) {
  const [messages, setMessages] = useState<WebChatMessage[]>([]);
  const [inputText, setInputText] = useState("");
  const [isWorking, setIsWorking] = useState(roomPresence === "working");
  const [presence, setPresence] = useState<PeerPresence>(roomPresence);
  // Relay room/meta frames win over in-chat signals whenever they change.
  const [syncedRoomPresence, setSyncedRoomPresence] = useState(roomPresence);
  if (roomPresence !== syncedRoomPresence) {
    setSyncedRoomPresence(roomPresence);
    setPresence(roomPresence);
    setIsWorking(roomPresence === "working");
  }
  const [showScrollBottom, setShowScrollBottom] = useState(false);
  const [unreadCount, setUnreadCount] = useState(0);
  const [history, setHistory] = useState<string[]>([]);
  const [historyIndex, setHistoryIndex] = useState(-1);
  const [slashMenuOpen, setSlashMenuOpen] = useState(false);
  const [copiedId, setCopiedId] = useState<string | null>(null);
  const [toolDisplay, setToolDisplay] = useState<ToolDisplay>(readToolDisplay);
  const [expandedTools, setExpandedTools] = useState<Set<string>>(new Set());
  const [pendingPrompt, setPendingPrompt] = useState<PendingPrompt | null>(null);
  const [queuedItems, setQueuedItems] = useState<Array<{ id: string; text: string; editable?: boolean }>>([]);
  const [showThinking, setShowThinking] = useState(readShowThinking);
  // The Agents board belongs to the client (room) it came from, so switching
  // sessions never shows the previous room's jobs.
  const [agents, setAgents] = useState<{ client: RemotePiRelayClient | null; board: AgentBoard }>({
    client: null,
    board: EMPTY_BOARD,
  });

  const scrollContainerRef = useRef<HTMLDivElement>(null);
  const isInitialLoadRef = useRef(true);
  const inputRef = useRef<HTMLTextAreaElement>(null);
  // Composer grows with its text like the app's (minLines 1 → maxLines, then
  // scrolls). Desktop has room, so allow up to ~10 lines.
  useLayoutEffect(() => {
    const el = inputRef.current;
    if (!el) return;
    el.style.height = "auto";
    const max = 240;
    el.style.height = `${Math.min(el.scrollHeight, max)}px`;
    el.style.overflowY = el.scrollHeight > max ? "auto" : "hidden";
  }, [inputText]);
  // Built during render (no side effects in the constructor); the effect below
  // wires callbacks and subscribes it to the shared relay link.
  const client = useMemo(() => new RemotePiRelayClient(connection, session), [connection, session]);
  const agentBoard = agents.client === client ? agents.board : EMPTY_BOARD;
  // Synchronously position at the bottom before browser paints
  useLayoutEffect(() => {
    if (isInitialLoadRef.current && messages.length > 0 && scrollContainerRef.current) {
      scrollContainerRef.current.scrollTop = scrollContainerRef.current.scrollHeight;
      isInitialLoadRef.current = false;
    }
  }, [messages]);
  const activeStreamIdRef = useRef<string | null>(null);

  // Scroll detection for "Scroll to bottom" button
  const handleScroll = () => {
    if (!scrollContainerRef.current) return;
    const { scrollTop, scrollHeight, clientHeight } = scrollContainerRef.current;
    const distanceFromBottom = scrollHeight - scrollTop - clientHeight;
    const isFar = distanceFromBottom > 120;
    setShowScrollBottom(isFar);
    if (!isFar) setUnreadCount(0);
  };

  const scrollToBottom = (smooth = true) => {
    if (!scrollContainerRef.current) return;
    if (!smooth) {
      scrollContainerRef.current.scrollTop = scrollContainerRef.current.scrollHeight;
    } else {
      scrollContainerRef.current.scrollTo({
        top: scrollContainerRef.current.scrollHeight,
        behavior: "smooth",
      });
    }
    setUnreadCount(0);
    setShowScrollBottom(false);
  };

  // Bind the chat client to this room; history arrives via session_sync, like the app.
  useEffect(() => {
    const handleStorageChange = () => setToolDisplay(readToolDisplay());
    const handleShowThinkingChange = () => setShowThinking(readShowThinking());
    window.addEventListener("tool_display_changed", handleStorageChange);
    window.addEventListener(SHOW_THINKING_EVENT, handleShowThinkingChange);

    client.connect({
      onPresenceChange: (p) => {
        setPresence(p);
        setIsWorking(p === "working");
      },

      onSessionHistory: (histMsgs) => {
        // Prompts still open on the Pi are replayed right after the history,
        // so one resolved while this tab was away must not linger.
        setPendingPrompt(null);
        if (histMsgs.length > 0) {
          setMessages(histMsgs);
          requestAnimationFrame(() => {
            if (scrollContainerRef.current) {
              scrollContainerRef.current.scrollTop = scrollContainerRef.current.scrollHeight;
            }
          });
        }
      },

      onMessage: (msg) => {
        setMessages((prev) => {
          // If message with same id exists, update it; otherwise append
          const exists = prev.some((m) => m.id === msg.id);
          if (exists) {
            return prev.map((m) => (m.id === msg.id ? { ...m, ...msg } : m));
          }
          return [...prev, msg];
        });

        // Increment unread count if user is scrolled up
        if (scrollContainerRef.current) {
          const { scrollTop, scrollHeight, clientHeight } = scrollContainerRef.current;
          if (scrollHeight - scrollTop - clientHeight > 120) {
            setUnreadCount((c) => c + 1);
          } else {
            setTimeout(() => scrollToBottom(true), 50);
          }
        }
      },

      onStreamingChunk: (delta, inReplyTo) => {
        activeStreamIdRef.current = inReplyTo;
        setIsWorking(true);
        setMessages((prev) => {
          const streamMsgId = `stream-${inReplyTo}`;
          const existingIdx = prev.findIndex((m) => m.id === streamMsgId);
          if (existingIdx >= 0) {
            const updated = [...prev];
            updated[existingIdx] = {
              ...updated[existingIdx],
              text: updated[existingIdx].text + delta,
              isStreaming: true,
            };
            return updated;
          } else {
            return [
              ...prev,
              {
                id: streamMsgId,
                role: "assistant",
                text: delta,
                timestamp: Date.now(),
                isStreaming: true,
              },
            ];
          }
        });

        // Auto-scroll if near bottom
        if (scrollContainerRef.current) {
          const { scrollTop, scrollHeight, clientHeight } = scrollContainerRef.current;
          if (scrollHeight - scrollTop - clientHeight <= 120) {
            scrollToBottom(true);
          }
        }
      },

      onAgentDone: (inReplyTo) => {
        setIsWorking(false);
        activeStreamIdRef.current = null;
        setMessages((prev) =>
          prev.map((m) => (m.id === `stream-${inReplyTo}` ? { ...m, isStreaming: false } : m))
        );
        setTimeout(() => scrollToBottom(true), 50);
      },

      onToolRequest: (tool) => {
        setIsWorking(true);
        const toolMsg: WebChatMessage = {
          id: `tool-${tool.id}`,
          role: "tool",
          text: `${tool.tool}: ${tool.command || JSON.stringify(tool.args || {})}`,
          timestamp: Date.now(),
          tool,
        };
        setMessages((prev) => [...prev, toolMsg]);
        setTimeout(() => scrollToBottom(true), 50);
      },

      onToolResult: (toolCallId, { output, isError }) => {
        setMessages((prev) =>
          prev.map((m) =>
            m.tool && m.tool.id === toolCallId
              ? { ...m, tool: { ...m.tool, status: isError ? "error" : "done", output } }
              : m
          )
        );
      },

      onExtensionUiRequest: (req) => {
        setPendingPrompt((open) => applyExtensionUiRequest(open, req));
      },

      onCompaction: (summary, tokensBefore) => {
        const compMsg: WebChatMessage = {
          id: `comp-${Date.now()}`,
          role: "compaction",
          text: summary,
          timestamp: Date.now(),
          tokensBefore,
        };
        setMessages((prev) => [...prev, compMsg]);
      },

      onQueuedState: (items) => {
        setQueuedItems(items);
      },

      onActivity: (jobs) => {
        setAgents((prev) => ({
          client,
          board: applyActivitySnapshot(prev.client === client ? prev.board : EMPTY_BOARD, jobs, Date.now()),
        }));
      },
    });

    return () => {
      window.removeEventListener("tool_display_changed", handleStorageChange);
      window.removeEventListener(SHOW_THINKING_EVENT, handleShowThinkingChange);
      client.disconnect();
    };
  }, [client]);

  const handleQueueMessage = () => {
    const text = inputText.trim();
    if (!text) return;
    client.queueMessage(text);
    setInputText("");
  };

  const handleEditQueued = (item: { id: string; text: string }) => {
    client.clearQueuedMessage(item.id);
    setInputText(item.text);
    inputRef.current?.focus();
  };

  const handleClearQueued = (id: string) => {
    client.clearQueuedMessage(id);
    setQueuedItems((prev) => prev.filter((q) => q.id !== id));
  };

  // Send message over WebSocket
  const handleSendMessage = () => {
    const text = inputText.trim();
    if (!text) return;

    // Optimistically add user message to list
    const userMsg: WebChatMessage = {
      id: `cli_${Date.now()}`,
      role: "user",
      text,
      timestamp: Date.now(),
      status: "sending",
    };

    setMessages((prev) => [...prev, userMsg]);
    setHistory((prev) => [text, ...prev.filter((h) => h !== text)]);
    setHistoryIndex(-1);
    setInputText("");
    setSlashMenuOpen(false);
    // A new message starts a fresh Finished list (running rows stay).
    setAgents((prev) => ({ ...prev, board: clearFinished(prev.board) }));

    // Auto-scroll to bottom immediately
    setTimeout(() => scrollToBottom(true), 50);

    // Send to WebSocket
    client.sendMessage(text);
  };

  const handleCancelTurn = () => {
    if (activeStreamIdRef.current) {
      client.cancelTurn(activeStreamIdRef.current);
    }
  };

  const handlePromptRespond = (resp: ExtensionUiResponseWire): boolean => {
    const sent = client.respondExtensionUi(resp);
    setPendingPrompt((open) =>
      open && open.request.id === resp.id
        ? { ...open, error: sent ? null : "Not connected — check the link to Pi and retry." }
        : open
    );
    return sent;
  };

  const handleKeyDown = (e: React.KeyboardEvent<HTMLTextAreaElement>) => {
    // Ctrl+Enter or Cmd+Enter: Queue message for next turn
    if (e.key === "Enter" && (e.ctrlKey || e.metaKey)) {
      e.preventDefault();
      handleQueueMessage();
      return;
    }

    // Plain Enter (without Shift/Ctrl/Cmd): Send / Steer message
    if (e.key === "Enter" && !e.shiftKey) {
      e.preventDefault();
      handleSendMessage();
      return;
    }
    if (e.key === "ArrowUp" && inputText === "" && history.length > 0) {
      e.preventDefault();
      const nextIdx = Math.min(historyIndex + 1, history.length - 1);
      setHistoryIndex(nextIdx);
      setInputText(history[nextIdx] || "");
      return;
    }

    if (e.key === "ArrowDown" && historyIndex >= 0) {
      e.preventDefault();
      const nextIdx = historyIndex - 1;
      setHistoryIndex(nextIdx);
      setInputText(nextIdx >= 0 ? history[nextIdx] : "");
      return;
    }

    if (e.key === "/" && inputText === "") {
      setSlashMenuOpen(true);
    } else if (inputText.length > 0 && !inputText.startsWith("/")) {
      setSlashMenuOpen(false);
    }
  };

  const copyText = (text: string, id: string) => {
    navigator.clipboard.writeText(text);
    setCopiedId(id);
    setTimeout(() => setCopiedId(null), 2000);
  };

  return (
    <div className="flex h-screen w-full max-w-5xl lg:max-w-[calc(64rem+300px)] mx-auto">
    <div className="flex flex-col flex-1 min-w-0 bg-[#08090d] border-x border-white/10 relative">
      {/* 1. TOP APP BAR */}
      <div className="h-14 px-4 border-b border-white/10 bg-[#0a0c10]/95 backdrop-blur-md flex items-center justify-between shrink-0 z-20">
        <div className="flex items-center gap-3 min-w-0">
          <button
            type="button"
            onClick={onDisconnect}
            className="p-1.5 -ml-1 text-[#888] hover:text-white hover:bg-white/10 rounded-lg transition-colors cursor-pointer"
            title="Back to Sessions"
          >
            <svg className="w-5 h-5" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
              <polyline points="15 18 9 12 15 6" />
            </svg>
          </button>

          <div className="min-w-0">
            <div className="text-sm font-semibold text-white truncate font-mono flex items-center gap-2">
              <span>{session.name || "Remote Pi"}</span>
              <span className="text-[10px] px-1.5 py-0.5 rounded bg-white/10 text-[#888] font-normal">
                {session.roomId}
              </span>
            </div>
            <div className="flex items-center gap-2 text-xs text-[#888] font-mono">
              <span className="truncate max-w-[140px] sm:max-w-[220px]">{session.device}</span>
              <span className="text-[#444]">&bull;</span>
              <div className="flex items-center gap-1.5">
                <span
                  className={`w-2 h-2 rounded-full ${
                    isWorking
                      ? "bg-[#4fc3f7] animate-pulse"
                      : presence === "online"
                      ? "bg-[#5fd38a]"
                      : presence === "reconnecting"
                      ? "bg-amber-400 animate-pulse"
                      : "bg-[#888]"
                  }`}
                />
                <span
                  className={`text-[11px] ${
                    isWorking
                      ? "text-[#4fc3f7]"
                      : presence === "online"
                      ? "text-[#5fd38a]"
                      : presence === "reconnecting"
                      ? "text-amber-400"
                      : "text-[#888]"
                  }`}
                >
                  {isWorking ? "working…" : presence}
                </span>
              </div>
            </div>
          </div>
        </div>

        {/* Top Actions */}
        {/* Top Actions matching Flutter ChatTopBar */}
        <div className="flex items-center gap-1">
          <button
            type="button"
            onClick={onOpenQuickActions}
            className="p-2 text-[#4fc3f7] hover:bg-[#4fc3f7]/10 rounded-lg transition-colors cursor-pointer"
            title="Quick Actions"
          >
            <svg className="w-4 h-4" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
              <polygon points="13 2 3 14 12 14 11 22 21 10 12 10 13 2" />
            </svg>
          </button>

          <button
            type="button"
            onClick={onOpenSessionInfo}
            className="p-2 text-[#888] hover:text-white hover:bg-white/10 rounded-lg transition-colors cursor-pointer"
            title="Session Info"
          >
            <svg className="w-4 h-4" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
              <circle cx="12" cy="12" r="10" />
              <line x1="12" y1="16" x2="12" y2="12" />
              <line x1="12" y1="8" x2="12.01" y2="8" />
            </svg>
          </button>

          {onOpenSettings && (
            <button
              type="button"
              onClick={onOpenSettings}
              className="p-2 text-[#888] hover:text-white hover:bg-white/10 rounded-lg transition-colors cursor-pointer"
              title="Settings"
            >
              <svg className="w-4 h-4" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
                <circle cx="12" cy="12" r="3" />
                <path d="M19.4 15a1.65 1.65 0 0 0 .33 1.82l.06.06a2 2 0 0 1 0 2.83 2 2 0 0 1-2.83 0l-.06-.06a1.65 1.65 0 0 0-1.82-.33 1.65 1.65 0 0 0-1 1.51V21a2 2 0 0 1-2 2 2 2 0 0 1-2-2v-.09A1.65 1.65 0 0 0 9 19.4a1.65 1.65 0 0 0-1.82.33l-.06.06a2 2 0 0 1-2.83 0 2 2 0 0 1 0-2.83l.06-.06a1.65 1.65 0 0 0 .33-1.82 1.65 1.65 0 0 0-1.51-1H3a2 2 0 0 1-2-2 2 2 0 0 1 2-2h.09A1.65 1.65 0 0 0 4.6 9a1.65 1.65 0 0 0-.33-1.82l-.06-.06a2 2 0 0 1 0-2.83 2 2 0 0 1 2.83 0l.06.06a1.65 1.65 0 0 0 1.82.33H9a1.65 1.65 0 0 0 1-1.51V3a2 2 0 0 1 2-2 2 2 0 0 1 2 2v.09a1.65 1.65 0 0 0 1 1.51 1.65 1.65 0 0 0 1.82-.33l.06-.06a2 2 0 0 1 2.83 0 2 2 0 0 1 0 2.83l-.06.06a1.65 1.65 0 0 0-.33 1.82V9a1.65 1.65 0 0 0 1.51 1H21a2 2 0 0 1 2 2 2 2 0 0 1-2 2h-.09a1.65 1.65 0 0 0-1.51 1z" />
              </svg>
            </button>
          )}
        </div>
      </div>

      {/* 2. CHAT TIMELINE / MESSAGE LIST */}
      <div
        ref={(el) => {
          scrollContainerRef.current = el;
          if (el && isInitialLoadRef.current && messages.length > 0) {
            el.scrollTop = el.scrollHeight;
          }
        }}
        onScroll={handleScroll}
        className="flex-1 overflow-y-auto p-4 sm:p-6 space-y-4 relative"
      >
        {(() => {
          const visibleMessages = messages.filter((m) => {
            if (m.role !== "tool") return true;
            if (toolDisplay === "hidden") return false;
            if (toolDisplay === "brief" && m.tool) {
              const toolName = m.tool.tool.toLowerCase();
              return !READ_ONLY_TOOLS.has(toolName);
            }
            return true;
          });

          if (visibleMessages.length === 0) {
            return (
              <div className="flex flex-col items-center justify-center h-full text-center p-6 text-[#777]">
                <div className="w-12 h-12 rounded-2xl bg-white/5 border border-white/10 flex items-center justify-center text-[#4fc3f7] mb-3">
                  <svg className="w-6 h-6" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
                    <polyline points="4 17 10 11 4 5" />
                    <line x1="12" y1="19" x2="20" y2="19" />
                  </svg>
                </div>
                <div className="text-sm font-medium text-white">No messages yet</div>
                <div className="text-xs text-[#666] font-mono mt-1">
                  Send a prompt below to interact with your Pi agent.
                </div>
              </div>
            );
          }

          return visibleMessages.map((m, idx) => {
          return (
            <div key={`${m.id || m.timestamp}_${idx}`} className="w-full">
              {/* USER BUBBLE (Mobile Parity: Capped width, #1A1A1A pill) */}
              {m.role === "user" && (
                <div className="flex justify-end mb-3">
                  <div className="max-w-[340px] sm:max-w-[420px] rounded-2xl rounded-tr-sm bg-[#1A1A1A] border border-[#262626] px-4 py-2.5 text-white text-sm shadow-xs select-text">
                    <div className="whitespace-pre-wrap font-mono text-sm leading-relaxed">{m.text}</div>
                    <div className="mt-1 text-[10px] text-[#8A8A8A] text-right font-mono flex items-center justify-end gap-1.5">
                      <span>{new Date(m.timestamp).toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" })}</span>
                      {m.status === "sending" && <span className="text-[#6B6B6B]">⏳</span>}
                      {m.status === "sent" && <span className="text-[#6CD28A]">✓</span>}
                    </div>
                  </div>
                </div>
              )}

              {/* ASSISTANT MESSAGE (Mobile Parity: Full-width Native Markdown) */}
              {m.role === "assistant" && (
                <div className="w-full my-2 text-sm leading-relaxed select-text">
                  <AssistantContent text={m.text} isStreaming={m.isStreaming} showThinking={showThinking} />
                </div>
              )}

              {/* TOOL CALL (Mobile Parity: Brief Pill / Full Card) */}
              {m.role === "tool" && m.tool && toolDisplay !== "hidden" && (() => {
                const toolKey = m.id || `${m.tool.id || "tool"}_${m.timestamp}`;
                const setExpanded = (expanded: boolean) =>
                  setExpandedTools((prev) => {
                    const next = new Set(prev);
                    if (expanded) next.add(toolKey);
                    else next.delete(toolKey);
                    return next;
                  });
                if (toolDisplay === "full") return <ToolFullCard tool={m.tool} />;
                return expandedTools.has(toolKey) ? (
                  <ToolFullCard tool={m.tool} onCollapse={() => setExpanded(false)} />
                ) : (
                  <ToolPill tool={m.tool} onExpand={() => setExpanded(true)} />
                );
              })()}

              {/* COMPACTION MESSAGE (Mobile Parity: Pill with ModelBadge tokens) */}
              {m.role === "compaction" && (
                <div className="my-3 flex justify-center">
                  <div className="px-3 py-1 rounded-full bg-[#161616] border border-[#1F1F1F] text-xs font-mono text-[#8A8A8A] flex items-center gap-1.5">
                    <span>📦</span>
                    <span>{m.text}</span>
                    {m.tokensBefore && <span className="text-[#6B6B6B]">({m.tokensBefore.toLocaleString()} tokens)</span>}
                  </div>
                </div>
              )}
            </div>
          );
        });
      })()}

        {isWorking && (
          <div className="flex items-center justify-between text-xs font-mono text-[#4fc3f7] py-2 px-3 rounded-xl bg-[#4fc3f7]/10 border border-[#4fc3f7]/20 w-full sm:w-fit max-w-full">
            <div className="flex items-center gap-2 min-w-0">
              <BrailleSpinner />
              <span className="truncate">{workingLabel(messages)}</span>
            </div>
            <button
              type="button"
              onClick={handleCancelTurn}
              className="ml-4 text-red-400 hover:text-red-300 underline cursor-pointer"
            >
              Stop
            </button>
          </div>
        )}
      </div>

      {/* Plan/57 — interactive extension prompt (ask_user / plan review) */}
      {pendingPrompt && (
        <ExtensionUiPrompt key={pendingPrompt.request.id} prompt={pendingPrompt} onRespond={handlePromptRespond} />
      )}

      {/* 3. FLOATING "SCROLL TO BOTTOM" BUTTON */}
      {showScrollBottom && (
        <button
          type="button"
          onClick={() => scrollToBottom(true)}
          className="absolute right-6 bottom-24 z-30 p-2.5 rounded-full bg-[#16202c] hover:bg-[#1e2c3c] border border-[#4fc3f7]/40 text-white shadow-xl transition-all hover:scale-105 active:scale-95 cursor-pointer flex items-center justify-center group"
          title="Scroll to bottom"
        >
          <svg className="w-5 h-5 text-[#4fc3f7] group-hover:translate-y-0.5 transition-transform" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.5">
            <line x1="12" y1="5" x2="12" y2="19" />
            <polyline points="19 12 12 19 5 12" />
          </svg>
          {unreadCount > 0 && (
            <span className="absolute -top-1 -right-1 w-4 h-4 rounded-full bg-[#4fc3f7] text-[#04222e] text-[10px] font-bold flex items-center justify-center">
              {unreadCount}
            </span>
          )}
        </button>
      )}

      {/* 4. SLASH COMMAND MENU OVERLAY */}
      {slashMenuOpen && (
        <div className="absolute left-4 right-4 bottom-24 bg-[#0e1117] border border-white/15 rounded-xl shadow-2xl overflow-hidden z-20 font-mono text-xs">
          <div className="p-2 bg-white/5 border-b border-white/10 text-[#888]">Available Commands</div>
          {[
            { cmd: "/init", desc: "Initialize workspace rules and AGENTS.md" },
            { cmd: "/plan", desc: "Generate architecture and task breakdown" },
            { cmd: "/clear", desc: "Clear active timeline mirror" },
            { cmd: "/model", desc: "Switch reasoning model" },
            { cmd: "/help", desc: "Show Remote Pi command guide" },
          ].map((item) => (
            <button
              key={item.cmd}
              type="button"
              onClick={() => {
                setInputText(`${item.cmd} `);
                setSlashMenuOpen(false);
                inputRef.current?.focus();
              }}
              className="w-full text-left px-3 py-2 hover:bg-[#4fc3f7]/15 flex items-center justify-between text-white cursor-pointer transition-colors"
            >
              <span className="text-[#4fc3f7] font-semibold">{item.cmd}</span>
              <span className="text-[#888]">{item.desc}</span>
            </button>
          ))}
        </div>
      )}

      {/* Narrow screens: Agents panel above the composer (wide screens use the side column) */}
      <AgentsBottomPanel board={agentBoard} />

      {/* 5. COMPACT BOTTOM COMPOSER */}
      <div className="p-2 sm:px-4 sm:py-2 border-t border-white/10 bg-[#0a0c10]/95 backdrop-blur-md shrink-0">
        {/* Queued Message Previews matching Flutter InputBar */}
        {queuedItems.length > 0 && (
          <div className="mb-2 space-y-1.5">
            {queuedItems.map((q) => (
              <div
                key={q.id}
                className="p-2 px-3 rounded-xl bg-amber-500/10 border border-amber-500/30 text-amber-200 text-xs font-mono flex items-center justify-between shadow-xs animate-in fade-in"
              >
                <div className="flex items-center gap-2 min-w-0">
                  <span className="text-amber-400">⏳</span>
                  <span className="font-semibold text-[11px] text-amber-400">Queued:</span>
                  <span className="truncate text-amber-100">{q.text}</span>
                </div>
                <div className="flex items-center gap-2 shrink-0">
                  <button
                    type="button"
                    onClick={() => handleEditQueued(q)}
                    className="px-2 py-0.5 rounded bg-amber-500/20 hover:bg-amber-500/30 text-amber-200 hover:text-white cursor-pointer transition-colors"
                  >
                    Edit
                  </button>
                  <button
                    type="button"
                    onClick={() => handleClearQueued(q.id)}
                    className="p-1 text-amber-400 hover:text-white cursor-pointer"
                    title="Remove from queue"
                  >
                    ✕
                  </button>
                </div>
              </div>
            ))}
          </div>
        )}

        <div className="relative flex items-end gap-2 rounded-xl bg-black/60 border border-white/15 focus-within:border-[#4fc3f7]/60 focus-within:ring-1 focus-within:ring-[#4fc3f7]/60 px-2.5 py-1.5 transition-all">
          <div className="flex items-center gap-0.5 shrink-0">
            {/* Quick Actions icon visible when input is empty (matching Flutter) */}
            {!inputText && (
              <button
                type="button"
                onClick={onOpenQuickActions}
                className="p-1.5 text-[#4fc3f7] hover:bg-[#4fc3f7]/10 rounded-lg transition-colors cursor-pointer"
                title="Quick Actions"
              >
                <svg className="w-4 h-4" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
                  <polygon points="13 2 3 14 12 14 11 22 21 10 12 10 13 2" />
                </svg>
              </button>
            )}
            <button
              type="button"
              onClick={() => alert("Image attachment: paste directly from clipboard or drag into chat.")}
              className="p-1.5 text-[#888] hover:text-white hover:bg-white/5 rounded-lg transition-colors cursor-pointer"
              title="Attach file"
            >
              <svg className="w-4 h-4" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
                <path d="M21.44 11.05l-9.19 9.19a6 6 0 0 1-8.49-8.49l9.19-9.19a4 4 0 0 1 5.66 5.66l-9.2 9.19a2 2 0 0 1-2.83-2.83l8.49-8.48" />
              </svg>
            </button>
            <button
              type="button"
              onClick={() => setSlashMenuOpen((s) => !s)}
              className="p-1.5 text-[#888] hover:text-[#4fc3f7] hover:bg-white/5 rounded-lg text-xs font-mono font-bold transition-colors cursor-pointer"
              title="Slash commands"
            >
              /
            </button>
          </div>

          {/* Compact Input */}
          <textarea
            ref={inputRef}
            rows={1}
            value={inputText}
            onChange={(e) => setInputText(e.target.value)}
            onKeyDown={handleKeyDown}
            placeholder={
              isWorking
                ? "Agent is working… Enter to steer, Ctrl+Enter to queue"
                : "Type a prompt, or / for commands…"
            }
            className="flex-1 self-center bg-transparent py-1 px-1 text-sm text-white placeholder:text-[#555] font-[family-name:var(--ff-body)] resize-none outline-none min-h-[26px] leading-relaxed"
          />

          {/* Right Buttons */}
          {/* Right Buttons matching Flutter InputBar */}
          <div className="flex items-center gap-1.5 shrink-0">
            {isWorking && (
              <button
                type="button"
                onClick={handleCancelTurn}
                className="px-2.5 py-1 bg-red-500/20 hover:bg-red-500/30 text-red-300 border border-red-500/40 rounded-lg text-xs font-mono font-semibold transition-all cursor-pointer"
              >
                Stop
              </button>
            )}

            {isWorking && inputText.trim() && (
              <button
                type="button"
                onClick={handleQueueMessage}
                className="px-2.5 py-1.5 bg-[#4fc3f7]/15 hover:bg-[#4fc3f7]/25 text-[#4fc3f7] border border-[#4fc3f7]/40 rounded-lg text-xs font-mono font-semibold transition-all cursor-pointer flex items-center gap-1 shadow-xs"
                title="Queue for next turn (Ctrl+Enter)"
              >
                <svg className="w-3.5 h-3.5" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
                  <line x1="8" y1="6" x2="21" y2="6" />
                  <line x1="8" y1="12" x2="21" y2="12" />
                  <line x1="8" y1="18" x2="16" y2="18" />
                  <line x1="3" y1="6" x2="3.01" y2="6" />
                  <line x1="3" y1="12" x2="3.01" y2="12" />
                  <line x1="3" y1="18" x2="3.01" y2="18" />
                </svg>
                <span className="hidden sm:inline">Queue</span>
              </button>
            )}

            <button
              type="button"
              onClick={() => handleSendMessage()}
              disabled={!inputText.trim()}
              className="p-2 sm:px-3 sm:py-1.5 bg-[#4fc3f7] hover:bg-[#38bdf8] active:scale-95 text-[#04222e] font-semibold text-xs rounded-lg transition-all cursor-pointer flex items-center gap-1 shadow-sm disabled:opacity-40 disabled:cursor-not-allowed"
              title={isWorking ? "Steer agent" : "Send message"}
            >
              <span className="hidden sm:inline">{isWorking ? "Steer" : "Send"}</span>
              <svg className="w-3.5 h-3.5" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.5">
                <line x1="22" y1="2" x2="11" y2="13" />
                <polygon points="22 2 15 22 11 13 2 9 22 2" />
              </svg>
            </button>
          </div>
        </div>
      </div>
    </div>
    {/* Wide screens: persistent Agents column */}
    <AgentsSideColumn board={agentBoard} />
    </div>
  );
}
