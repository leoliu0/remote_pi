"use client";

import { useState, useEffect, useRef } from "react";
import {
  WebChatMessage,
  PairedSession,
  PeerPresence,
  ConnectionState,
  ToolCallData,
  RemotePiRelayClient,
} from "./web-client";

interface WebChatProps {
  session: PairedSession;
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
  onDisconnect,
  onOpenSessionInfo,
  onOpenQuickActions,
  onOpenSettings,
}: WebChatProps) {
  const [messages, setMessages] = useState<WebChatMessage[]>([]);
  const [inputText, setInputText] = useState("");
  const [isWorking, setIsWorking] = useState(session.status === "working");
  const [presence, setPresence] = useState<PeerPresence>(
    session.status || (session.isLive ? "online" : "offline")
  );
  const [connState, setConnState] = useState<ConnectionState>("connecting");
  const [connError, setConnError] = useState<string | null>(null);
  const [showScrollBottom, setShowScrollBottom] = useState(false);
  const [unreadCount, setUnreadCount] = useState(0);
  const [history, setHistory] = useState<string[]>([]);
  const [historyIndex, setHistoryIndex] = useState(-1);
  const [slashMenuOpen, setSlashMenuOpen] = useState(false);
  const [copiedId, setCopiedId] = useState<string | null>(null);
  const [toolDisplay, setToolDisplay] = useState<"brief" | "full" | "hidden">("brief");
  const [expandedTools, setExpandedTools] = useState<Set<string>>(new Set());

  const scrollContainerRef = useRef<HTMLDivElement>(null);
  const inputRef = useRef<HTMLTextAreaElement>(null);
  const clientRef = useRef<RemotePiRelayClient | null>(null);
  const activeStreamIdRef = useRef<string | null>(null);

  // Initialize Real WebSocket Relay Client & Load Session History
  useEffect(() => {
    try {
      const savedMode = localStorage.getItem("remotepi_tool_display");
      if (savedMode === "brief" || savedMode === "full" || savedMode === "hidden") {
        setToolDisplay(savedMode);
      }
    } catch {}

    const handleStorageChange = () => {
      try {
        const savedMode = localStorage.getItem("remotepi_tool_display");
        if (savedMode === "brief" || savedMode === "full" || savedMode === "hidden") {
          setToolDisplay(savedMode);
        }
      } catch {}
    };
    window.addEventListener("tool_display_changed", handleStorageChange);

    setMessages([]);
    // 1. Load on-disk / cached history immediately
    fetch(`/api/session-history?roomId=${encodeURIComponent(session.roomId)}&cwd=${encodeURIComponent(session.cwd || "")}`)
      .then((res) => res.json())
      .then((data) => {
        if (data && data.ok && Array.isArray(data.messages) && data.messages.length > 0) {
          setMessages(data.messages);
          setTimeout(() => scrollToBottom(false), 50);
        }
      })
      .catch(() => {});

    const client = new RemotePiRelayClient(session);
    clientRef.current = client;
    client.onStateChange = (state, err) => {
      setConnState(state);
      if (err) setConnError(err);
      if (state === "connected") {
        setConnError(null);
      } else if (state === "disconnected" || state === "error") {
        setPresence("offline");
      }
    };

    client.onPresenceChange = (p) => {
      setPresence(p);
      setIsWorking(p === "working");
    };

    client.onSessionHistory = (histMsgs) => {
      if (histMsgs.length > 0) {
        setMessages(histMsgs);
        setTimeout(() => scrollToBottom(false), 50);
      }
    };

    client.onMessage = (msg) => {
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
    };

    client.onStreamingChunk = (delta, inReplyTo) => {
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
    };

    client.onAgentDone = (inReplyTo) => {
      setIsWorking(false);
      activeStreamIdRef.current = null;
      setMessages((prev) =>
        prev.map((m) => (m.id === `stream-${inReplyTo}` ? { ...m, isStreaming: false } : m))
      );
      setTimeout(() => scrollToBottom(true), 50);
    };

    client.onToolRequest = (tool) => {
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
    };

    client.onToolResult = (toolCallId, result, error) => {
      setMessages((prev) =>
        prev.map((m) => {
          if (m.tool && m.tool.id === toolCallId) {
            return {
              ...m,
              tool: {
                ...m.tool,
                status: error ? "error" : "done",
                error,
                output: typeof result === "string" ? result : JSON.stringify(result, null, 2),
              },
            };
          }
          return m;
        })
      );
    };

    client.onCompaction = (summary, tokensBefore) => {
      const compMsg: WebChatMessage = {
        id: `comp-${Date.now()}`,
        role: "compaction",
        text: summary,
        timestamp: Date.now(),
        tokensBefore,
      };
      setMessages((prev) => [...prev, compMsg]);
    };

    client.connect();

    return () => {
      window.removeEventListener("tool_display_changed", handleStorageChange);
      client.disconnect();
    };
  }, [session]);

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
    scrollContainerRef.current.scrollTo({
      top: scrollContainerRef.current.scrollHeight,
      behavior: smooth ? "smooth" : "auto",
    });
    setUnreadCount(0);
    setShowScrollBottom(false);
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

    // Auto-scroll to bottom immediately
    setTimeout(() => scrollToBottom(true), 50);

    // Send to WebSocket
    if (clientRef.current) {
      clientRef.current.sendMessage(text);
    }
  };

  const handleToolDecision = (toolCallId: string, decision: "allow" | "deny") => {
    if (clientRef.current) {
      clientRef.current.approveTool(toolCallId, decision);
    }
    setMessages((prev) =>
      prev.map((m) => {
        if (m.tool && m.tool.id === toolCallId) {
          return {
            ...m,
            tool: {
              ...m.tool,
              status: decision === "allow" ? "done" : "denied",
              output: decision === "allow" ? "Approved by user." : "Denied by user.",
            },
          };
        }
        return m;
      })
    );
  };

  const handleCancelTurn = () => {
    if (clientRef.current && activeStreamIdRef.current) {
      clientRef.current.cancelTurn(activeStreamIdRef.current);
    }
  };

  const handleKeyDown = (e: React.KeyboardEvent<HTMLTextAreaElement>) => {
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
    <div className="flex flex-col h-screen max-w-5xl mx-auto w-full bg-[#08090d] border-x border-white/10 relative">
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

      {/* Connection Notice / Error Banner */}
      {connError && (
        <div className="px-4 py-2 bg-red-500/15 border-b border-red-500/30 text-red-300 text-xs font-mono flex items-center justify-between">
          <div className="flex items-center gap-2">
            <span>⚠️</span>
            <span>{connError}</span>
          </div>
          <button
            type="button"
            onClick={() => clientRef.current?.connect()}
            className="underline hover:text-white cursor-pointer"
          >
            Retry
          </button>
        </div>
      )}

      {/* 2. CHAT TIMELINE / MESSAGE LIST */}
      <div
        ref={scrollContainerRef}
        onScroll={handleScroll}
        className="flex-1 overflow-y-auto p-4 sm:p-6 space-y-4 relative scroll-smooth"
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

          return visibleMessages.map((m) => {
          const toolStatus = m.tool?.status || "done";
          const toolColor =
            toolStatus === "pending"
              ? "#00D4FF"
              : toolStatus === "done"
              ? "#6CD28A"
              : toolStatus === "denied"
              ? "#6B6B6B"
              : "#E5484D";

          const statusLabel =
            toolStatus === "pending"
              ? "RUNNING"
              : toolStatus === "done"
              ? "DONE"
              : toolStatus === "denied"
              ? "DENIED"
              : "FAILED";

          return (
            <div key={m.id} className="w-full">
              {/* USER BUBBLE (Mobile Parity: #1A1A1A pill) */}
              {m.role === "user" && (
                <div className="flex justify-end mb-2.5">
                  <div className="max-w-[85%] sm:max-w-[75%] rounded-2xl rounded-tr-sm bg-[#1A1A1A] border border-[#262626] px-4 py-2.5 text-white text-sm shadow-xs">
                    <div className="whitespace-pre-wrap font-[family-name:var(--ff-body)]">{m.text}</div>
                    <div className="mt-1 text-[10px] text-[#8A8A8A] text-right font-mono flex items-center justify-end gap-1.5">
                      <span>{new Date(m.timestamp).toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" })}</span>
                      {m.status === "sending" && <span className="text-[#6B6B6B]">⏳</span>}
                      {m.status === "sent" && <span className="text-[#6CD28A]">✓</span>}
                    </div>
                  </div>
                </div>
              )}

              {/* ASSISTANT MESSAGE */}
              {m.role === "assistant" && (
                <div className="flex justify-start mb-2.5">
                  <div className="w-full max-w-[95%] sm:max-w-[90%] text-sm text-[#F0F0F0] leading-relaxed">
                    <div className="bg-[#0A0A0A] border border-[#1A1A1A] rounded-2xl p-4 shadow-xs">
                      <div className="whitespace-pre-wrap font-[family-name:var(--ff-body)] text-sm leading-relaxed">
                        {m.text}
                        {m.isStreaming && (
                          <span className="inline-block w-2 h-4 ml-1 bg-[#00D4FF] animate-pulse align-middle" />
                        )}
                      </div>
                    </div>
                  </div>
                </div>
              )}

              {/* TOOL CALL CARD (Mobile Parity: ToolRequestCard with Status Border & Glow) */}
              {/* TOOL CALL CARD (Mobile Parity: Brief Pill / Full Card) */}
              {m.role === "tool" && m.tool && toolDisplay !== "hidden" && (() => {
                const toolKey = m.id || `${m.tool?.id || "tool"}_${m.timestamp}`;
                const isExpanded = toolDisplay === "full" || expandedTools.has(toolKey);
                const summary: string =
                  typeof m.tool.command === "string" && m.tool.command
                    ? m.tool.command
                    : m.tool.args && typeof m.tool.args === "object"
                    ? String(
                        (m.tool.args as Record<string, any>).path ||
                          (m.tool.args as Record<string, any>).pattern ||
                          (m.tool.args as Record<string, any>).query ||
                          (m.tool.args as Record<string, any>).command ||
                          JSON.stringify(m.tool.args)
                      )
                    : typeof m.tool.args === "string"
                    ? m.tool.args
                    : "";
                if (!isExpanded) {
                  return (
                    <div key={toolKey} className="my-1.5 max-w-[95%] sm:max-w-[90%]">
                      <button
                        type="button"
                        onClick={() => {
                          setExpandedTools((prev) => {
                            const next = new Set(prev);
                            next.add(toolKey);
                            return next;
                          });
                        }}
                        className="w-full text-left rounded-lg bg-[#050505] px-3 py-1.5 transition-all flex items-center justify-between gap-2 cursor-pointer group hover:bg-[#0f0f0f]"
                        style={{
                          border: `1px solid ${toolColor}55`,
                        }}
                      >
                        <div className="flex items-center gap-2 min-w-0 font-mono text-xs">
                          <span className="font-bold shrink-0" style={{ color: toolColor }}>
                            &gt;_ {m.tool.tool.toUpperCase()}
                          </span>
                          {summary ? (
                            <span className="text-[#A3A3A3] font-normal truncate text-[11px] max-w-[200px] sm:max-w-[420px]">
                              {summary}
                            </span>
                          ) : (
                            <span className="text-[#666] italic text-[11px]">
                              {toolStatus === "pending" ? "waiting for approval…" : "completed"}
                            </span>
                          )}
                        </div>
                        <div className="flex items-center gap-2 shrink-0 font-mono text-xs">
                          {toolStatus === "pending" && (
                            <span className="text-[10px] text-[#E5B800] bg-[#E5B800]/15 px-1.5 py-0.5 rounded font-semibold">
                              Action Required
                            </span>
                          )}
                          <span className="font-bold text-xs" style={{ color: toolColor }}>
                            {toolStatus === "done"
                              ? "✓"
                              : toolStatus === "error"
                              ? "✗"
                              : toolStatus === "denied"
                              ? "⊘"
                              : "⏳"}
                          </span>
                          <span className="text-[#666] group-hover:text-white transition-colors text-[10px]">
                            ▾
                          </span>
                        </div>
                      </button>
                    </div>
                  );
                }

                return (
                  <div key={toolKey} className="my-2 max-w-[95%] sm:max-w-[90%]">
                    <div
                      className="rounded-xl bg-[#0A0A0A] overflow-hidden transition-all"
                      style={{
                        border: `1px solid ${toolColor}`,
                        boxShadow: `0 0 16px ${toolColor}1F`,
                      }}
                    >
                      {/* Tool Header */}
                      <div
                        className="px-3.5 py-2 bg-white/[0.02] border-b border-[#1A1A1A] flex items-center justify-between cursor-pointer"
                        onClick={() => {
                          if (toolDisplay === "brief") {
                            setExpandedTools((prev) => {
                              const next = new Set(prev);
                              next.delete(toolKey);
                              return next;
                            });
                          }
                        }}
                      >
                        <div className="flex items-center gap-2 font-mono text-xs font-bold" style={{ color: toolColor }}>
                          <span>&gt;_</span>
                          <span className="tracking-wide uppercase">{m.tool.tool}</span>
                          {m.tool.command && (
                            <span className="text-[#8A8A8A] font-normal font-mono truncate max-w-[180px] sm:max-w-[360px]">
                              {m.tool.command}
                            </span>
                          )}
                        </div>

                        <div className="flex items-center gap-2">
                          {toolStatus === "pending" && (
                            <div className="flex items-center gap-1.5" onClick={(e) => e.stopPropagation()}>
                              <button
                                type="button"
                                onClick={() => handleToolDecision(m.tool!.id, "allow")}
                                className="px-2 py-0.5 bg-[#6CD28A] hover:bg-[#5bc078] text-[#000000] text-xs font-semibold rounded font-mono cursor-pointer transition-colors"
                              >
                                Approve
                              </button>
                              <button
                                type="button"
                                onClick={() => handleToolDecision(m.tool!.id, "deny")}
                                className="px-2 py-0.5 bg-red-500/20 hover:bg-red-500/30 text-[#E5484D] text-xs font-semibold rounded border border-[#E5484D]/40 font-mono cursor-pointer transition-colors"
                              >
                                Deny
                              </button>
                            </div>
                          )}

                          <span className="text-[11px] font-mono font-bold tracking-wider" style={{ color: toolColor }}>
                            {statusLabel}
                          </span>
                          {toolDisplay === "brief" && (
                            <span className="text-[#888] text-[10px]">▲</span>
                          )}
                        </div>
                      </div>

                      {/* Tool Command / Args Box */}
                      {m.tool.args && Object.keys(m.tool.args).length > 0 && !m.tool.command && (
                        <div className="p-2.5 bg-[#050505] font-mono text-xs text-[#8A8A8A] border-b border-[#1A1A1A] overflow-x-auto">
                          <pre className="text-white/80">{JSON.stringify(m.tool.args, null, 2)}</pre>
                        </div>
                      )}

                      {/* Tool Diff / Output View */}
                      {m.tool.diff && m.tool.diff.hunks && (
                        <div className="p-3 bg-[#050505] font-mono text-xs overflow-x-auto space-y-0.5 border-t border-[#1A1A1A]">
                          {m.tool.diff.hunks.map((line, i) => (
                            <div
                              key={i}
                              className={`px-2 py-0.5 rounded ${
                                line.startsWith("+")
                                  ? "bg-[#6CD28A]/15 text-[#6CD28A] font-semibold"
                                : line.startsWith("-")
                                ? "bg-[#E5484D]/15 text-[#E5484D]"
                                : "text-[#8A8A8A]"
                            }`}
                          >
                            {line}
                          </div>
                        ))}
                      </div>
                    )}

                    {/* Tool Output Result */}
                    {m.tool.result !== undefined && m.tool.result !== null && (
                      <div className="p-3 bg-[#050505] font-mono text-xs text-[#8A8A8A] whitespace-pre-wrap max-h-56 overflow-y-auto border-t border-[#1A1A1A]">
                        {typeof m.tool.result === "string" ? m.tool.result : JSON.stringify(m.tool.result, null, 2)}
                      </div>
                    )}
                  </div>
                </div>
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
          <div className="flex items-center justify-between text-xs font-mono text-[#4fc3f7] py-2 px-3 rounded-xl bg-[#4fc3f7]/10 border border-[#4fc3f7]/20 w-fit animate-pulse">
            <div className="flex items-center gap-2">
              <span className="w-2 h-2 rounded-full bg-[#4fc3f7]" />
              Agent is working…
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

      {/* 5. COMPACT BOTTOM COMPOSER */}
      <div className="p-2 sm:px-4 sm:py-2 border-t border-white/10 bg-[#0a0c10]/95 backdrop-blur-md shrink-0">
        <div className="relative flex items-center gap-2 rounded-xl bg-black/60 border border-white/15 focus-within:border-[#4fc3f7]/60 focus-within:ring-1 focus-within:ring-[#4fc3f7]/60 px-2.5 py-1.5 transition-all">
          {/* Left Action Buttons matching Flutter InputBar */}
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
                ? "Agent is working… type to steer or queue"
                : "Type a prompt, or / for commands…"
            }
            className="flex-1 bg-transparent py-1 px-1 text-sm text-white placeholder:text-[#555] font-[family-name:var(--ff-body)] resize-none outline-none max-h-32 min-h-[26px] leading-relaxed"
          />

          {/* Right Buttons */}
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
  );
}
