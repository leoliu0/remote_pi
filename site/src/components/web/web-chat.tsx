"use client";

import { useState, useEffect, useRef, useTransition } from "react";
import { WebChatMessage, PairedSession, PeerPresence } from "./web-client";

interface WebChatProps {
  session: PairedSession;
  onDisconnect: () => void;
  onOpenSessionInfo: () => void;
  onOpenQuickActions: () => void;
}

export function WebChat({
  session,
  onDisconnect,
  onOpenSessionInfo,
  onOpenQuickActions,
}: WebChatProps) {
  const [messages, setMessages] = useState<WebChatMessage[]>([]);
  const [inputText, setInputText] = useState("");
  const [isWorking, setIsWorking] = useState(false);
  const [presence, setPresence] = useState<PeerPresence>("online");
  const [showScrollBottom, setShowScrollBottom] = useState(false);
  const [unreadCount, setUnreadCount] = useState(0);
  const [history, setHistory] = useState<string[]>([]);
  const [historyIndex, setHistoryIndex] = useState(-1);
  const [slashMenuOpen, setSlashMenuOpen] = useState(false);
  const [copiedId, setCopiedId] = useState<string | null>(null);

  const scrollContainerRef = useRef<HTMLDivElement>(null);
  const inputRef = useRef<HTMLTextAreaElement>(null);
  const [, startTransition] = useTransition();

  // Initialize with initial conversation
  useEffect(() => {
    setMessages([
      {
        id: "msg-welcome",
        role: "assistant",
        text: `Connected to **${session.device}** (${session.roomId}). Remote Pi Web Client is ready.\n\nYou can send instructions, run commands, and approve tool calls directly from this browser window.`,
        timestamp: Date.now(),
      },
    ]);
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

  // Send message
  const handleSendMessage = (textToSend?: string) => {
    const text = (textToSend ?? inputText).trim();
    if (!text) return;

    const userMsg: WebChatMessage = {
      id: `msg-${Date.now()}`,
      role: "user",
      text,
      timestamp: Date.now(),
      status: "sent",
    };

    setMessages((prev) => [...prev, userMsg]);
    setHistory((prev) => [text, ...prev.filter((h) => h !== text)]);
    setHistoryIndex(-1);
    setInputText("");
    setSlashMenuOpen(false);
    setIsWorking(true);

    // Auto-scroll to bottom immediately
    setTimeout(() => scrollToBottom(true), 50);

    // Simulate Agent Turn Execution
    setTimeout(() => {
      // Step 1: Tool Execution or Streaming Response
      if (text.toLowerCase().includes("test") || text.toLowerCase().includes("check")) {
        const toolMsg: WebChatMessage = {
          id: `msg-tool-${Date.now()}`,
          role: "tool",
          text: "bash: pnpm test",
          timestamp: Date.now(),
          tool: {
            id: `t-${Date.now()}`,
            tool: "bash",
            command: "pnpm test",
            output: "✓ 583 tests passed (0 failures)",
            status: "done",
          },
        };
        setMessages((prev) => [...prev, toolMsg]);
        setTimeout(() => scrollToBottom(true), 50);
      } else if (text.toLowerCase().includes("edit") || text.toLowerCase().includes("fix")) {
        const toolMsg: WebChatMessage = {
          id: `msg-tool-${Date.now()}`,
          role: "tool",
          text: "edit: src/app/web/page.tsx",
          timestamp: Date.now(),
          tool: {
            id: `t-${Date.now()}`,
            tool: "edit",
            command: "edit src/app/web/page.tsx",
            status: "done",
            diff: {
              file: "src/app/web/page.tsx",
              hunks: [
                "- // Previous implementation",
                "+ // Auto-scroll to bottom on send enabled",
                "+ const isScrollBottomActive = true;",
              ],
            },
          },
        };
        setMessages((prev) => [...prev, toolMsg]);
        setTimeout(() => scrollToBottom(true), 50);
      }

      // Step 2: Final Assistant Response
      setTimeout(() => {
        const replyText = `I processed your request for **${session.device}**:\n\n` +
          `\`\`\`typescript\n// Operation completed successfully\nconst status = "OK";\nconsole.log("Remote Pi Web Client active");\n\`\`\`\n\n` +
          `All changes are synchronized with your desktop session.`;

        const assistantMsg: WebChatMessage = {
          id: `msg-asst-${Date.now()}`,
          role: "assistant",
          text: replyText,
          timestamp: Date.now(),
        };

        setMessages((prev) => [...prev, assistantMsg]);
        setIsWorking(false);
        setTimeout(() => scrollToBottom(true), 50);
      }, 1000);
    }, 600);
  };

  // Keyboard navigation for history recall and sending
  const handleKeyDown = (e: React.KeyboardEvent<HTMLTextAreaElement>) => {
    if (e.key === "Enter" && !e.shiftKey) {
      e.preventDefault();
      handleSendMessage();
      return;
    }

    // Up arrow for command history
    if (e.key === "ArrowUp" && inputText === "" && history.length > 0) {
      e.preventDefault();
      const nextIdx = Math.min(historyIndex + 1, history.length - 1);
      setHistoryIndex(nextIdx);
      setInputText(history[nextIdx] || "");
      return;
    }

    // Down arrow for command history
    if (e.key === "ArrowDown" && historyIndex >= 0) {
      e.preventDefault();
      const nextIdx = historyIndex - 1;
      setHistoryIndex(nextIdx);
      setInputText(nextIdx >= 0 ? history[nextIdx] : "");
      return;
    }

    // Slash command trigger
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

  const handleToolDecision = (msgId: string, decision: "allowed" | "denied") => {
    setMessages((prev) =>
      prev.map((m) => {
        if (m.id === msgId && m.tool) {
          return {
            ...m,
            tool: {
              ...m.tool,
              status: decision === "allowed" ? "done" : "denied",
              output: decision === "allowed" ? "Execution approved by user via Web Client." : "Execution denied by user.",
            },
          };
        }
        return m;
      })
    );
  };

  return (
    <div className="flex flex-col h-[calc(100vh-80px)] max-w-5xl mx-auto w-full bg-[#08090d] border-x border-white/10 relative">
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
                      : "bg-[#888]"
                  }`}
                />
                <span
                  className={`text-[11px] ${
                    isWorking ? "text-[#4fc3f7]" : presence === "online" ? "text-[#5fd38a]" : "text-[#888]"
                  }`}
                >
                  {isWorking ? "working…" : presence}
                </span>
              </div>
            </div>
          </div>
        </div>

        {/* Top Actions */}
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

          <button
            type="button"
            onClick={onDisconnect}
            className="p-2 text-[#888] hover:text-red-400 hover:bg-red-500/10 rounded-lg transition-colors cursor-pointer"
            title="Disconnect"
          >
            <svg className="w-4 h-4" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
              <path d="M18.36 6.64a9 9 0 1 1-12.73 0" />
              <line x1="12" y1="2" x2="12" y2="12" />
            </svg>
          </button>
        </div>
      </div>

      {/* 2. CHAT TIMELINE / MESSAGE LIST */}
      <div
        ref={scrollContainerRef}
        onScroll={handleScroll}
        className="flex-1 overflow-y-auto p-4 sm:p-6 space-y-4 relative scroll-smooth"
      >
        {messages.map((m) => (
          <div key={m.id} className="w-full">
            {/* USER BUBBLE */}
            {m.role === "user" && (
              <div className="flex justify-end mb-2">
                <div className="max-w-[85%] sm:max-w-[75%] rounded-2xl rounded-tr-sm bg-[#16202c] border border-[#4fc3f7]/25 px-4 py-3 text-white text-sm shadow-md">
                  <div className="whitespace-pre-wrap font-[family-name:var(--ff-body)]">{m.text}</div>
                  <div className="mt-1 text-[10px] text-[#4fc3f7]/70 text-right font-mono">
                    {new Date(m.timestamp).toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" })}
                  </div>
                </div>
              </div>
            )}

            {/* ASSISTANT MESSAGE */}
            {m.role === "assistant" && (
              <div className="flex justify-start mb-2">
                <div className="w-full max-w-[92%] sm:max-w-[88%] text-sm text-[#e0e0e0] leading-relaxed">
                  <div className="bg-[#0e1117] border border-white/10 rounded-2xl px-4 py-3.5 shadow-sm">
                    <div className="whitespace-pre-wrap font-[family-name:var(--ff-body)] text-sm prose prose-invert max-w-none">
                      {m.text}
                    </div>
                  </div>
                </div>
              </div>
            )}

            {/* TOOL CALL CARD */}
            {m.role === "tool" && m.tool && (
              <div className="my-2 max-w-[92%] sm:max-w-[88%]">
                <div className="rounded-xl border border-white/15 bg-[#0b0d13] overflow-hidden shadow-sm">
                  {/* Tool Header */}
                  <div className="px-3.5 py-2.5 bg-white/[0.04] border-b border-white/10 flex items-center justify-between">
                    <div className="flex items-center gap-2 font-mono text-xs text-[#4fc3f7]">
                      <span className="w-2 h-2 rounded-full bg-[#4fc3f7]" />
                      <span className="font-semibold uppercase">{m.tool.tool}</span>
                      <span className="text-[#888] truncate max-w-[200px] sm:max-w-[340px]">{m.tool.command}</span>
                    </div>

                    <div className="flex items-center gap-2">
                      {m.tool.status === "pending" && (
                        <div className="flex items-center gap-1.5">
                          <button
                            type="button"
                            onClick={() => handleToolDecision(m.id, "allowed")}
                            className="px-2.5 py-1 bg-[#5fd38a] hover:bg-[#4bc275] text-[#04222e] text-xs font-semibold rounded cursor-pointer transition-colors"
                          >
                            Approve
                          </button>
                          <button
                            type="button"
                            onClick={() => handleToolDecision(m.id, "denied")}
                            className="px-2.5 py-1 bg-red-500/20 hover:bg-red-500/30 text-red-400 text-xs font-semibold rounded border border-red-500/40 cursor-pointer transition-colors"
                          >
                            Deny
                          </button>
                        </div>
                      )}
                      {m.tool.status === "done" && (
                        <span className="text-[11px] font-mono text-[#5fd38a] flex items-center gap-1">
                          ✓ Done
                        </span>
                      )}
                      {m.tool.status === "denied" && (
                        <span className="text-[11px] font-mono text-red-400">✗ Denied</span>
                      )}
                    </div>
                  </div>

                  {/* Tool Diff / Output View */}
                  {m.tool.diff && m.tool.diff.hunks && (
                    <div className="p-3 bg-black/70 font-mono text-xs overflow-x-auto space-y-0.5">
                      {m.tool.diff.hunks.map((line, i) => (
                        <div
                          key={i}
                          className={`px-2 py-0.5 rounded ${
                            line.startsWith("+")
                              ? "bg-emerald-500/15 text-emerald-300 font-semibold"
                              : line.startsWith("-")
                              ? "bg-red-500/15 text-red-300"
                              : "text-[#888]"
                          }`}
                        >
                          {line}
                        </div>
                      ))}
                    </div>
                  )}

                  {m.tool.output && (
                    <div className="p-3 bg-black/60 font-mono text-xs text-[#a3a3a3] whitespace-pre-wrap max-h-48 overflow-y-auto border-t border-white/5">
                      {m.tool.output}
                    </div>
                  )}
                </div>
              </div>
            )}
          </div>
        ))}

        {isWorking && (
          <div className="flex items-center gap-2 text-xs font-mono text-[#4fc3f7] py-2 px-3 rounded-xl bg-[#4fc3f7]/10 border border-[#4fc3f7]/20 w-fit animate-pulse">
            <span className="w-2 h-2 rounded-full bg-[#4fc3f7]" />
            Agent is thinking & writing…
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

      {/* 5. BOTTOM COMPOSER */}
      <div className="p-3 sm:p-4 border-t border-white/10 bg-[#0a0c10]/95 backdrop-blur-md shrink-0">
        <div className="relative flex flex-col rounded-2xl bg-black/60 border border-white/15 focus-within:border-[#4fc3f7]/60 focus-within:ring-1 focus-within:ring-[#4fc3f7]/60 transition-all">
          <textarea
            ref={inputRef}
            rows={2}
            value={inputText}
            onChange={(e) => setInputText(e.target.value)}
            onKeyDown={handleKeyDown}
            placeholder="Type a message, run a task, or type / for commands…"
            className="w-full bg-transparent p-3 text-sm text-white placeholder:text-[#555] font-[family-name:var(--ff-body)] resize-none outline-none max-h-40"
          />

          <div className="flex items-center justify-between px-3 pb-2.5 pt-1">
            <div className="flex items-center gap-1">
              <button
                type="button"
                onClick={() => setSlashMenuOpen((s) => !s)}
                className="p-1.5 text-[#888] hover:text-[#4fc3f7] hover:bg-white/5 rounded-lg text-xs font-mono transition-colors cursor-pointer"
                title="Slash commands"
              >
                /
              </button>
              <button
                type="button"
                onClick={() => alert("Image attachment: drag & drop into chat or paste directly from clipboard.")}
                className="p-1.5 text-[#888] hover:text-white hover:bg-white/5 rounded-lg transition-colors cursor-pointer"
                title="Attach file"
              >
                <svg className="w-4 h-4" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
                  <path d="M21.44 11.05l-9.19 9.19a6 6 0 0 1-8.49-8.49l9.19-9.19a4 4 0 0 1 5.66 5.66l-9.2 9.19a2 2 0 0 1-2.83-2.83l8.49-8.48" />
                </svg>
              </button>
            </div>

            <div className="flex items-center gap-2">
              <span className="text-[11px] text-[#555] font-mono hidden sm:inline">
                Enter to send &bull; Shift+Enter newline
              </span>

              <button
                type="button"
                onClick={() => handleSendMessage()}
                disabled={!inputText.trim() && !isWorking}
                className="px-4 py-2 bg-[#4fc3f7] hover:bg-[#38bdf8] active:scale-95 text-[#04222e] font-semibold text-xs rounded-xl transition-all cursor-pointer flex items-center gap-1.5 shadow-md shadow-[#4fc3f7]/20 disabled:opacity-40 disabled:cursor-not-allowed"
              >
                <span>Send</span>
                <svg className="w-3.5 h-3.5" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.5">
                  <line x1="22" y1="2" x2="11" y2="13" />
                  <polygon points="22 2 15 22 11 13 2 9 22 2" />
                </svg>
              </button>
            </div>
          </div>
        </div>
      </div>
    </div>
  );
}
