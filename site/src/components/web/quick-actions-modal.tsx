"use client";

import { useState } from "react";

export type ToolDisplayMode = "brief" | "full" | "hidden";

interface QuickActionsModalProps {
  activeModel?: string;
  activeThinking?: string;
  toolDisplay?: ToolDisplayMode;
  onClose: () => void;
  onAction: (action: string, payload?: string) => void;
  onSetToolDisplay?: (mode: ToolDisplayMode) => void;
}

export function QuickActionsModal({
  activeModel,
  activeThinking = "medium",
  toolDisplay = "brief",
  onClose,
  onAction,
  onSetToolDisplay,
}: QuickActionsModalProps) {
  const normalizeModel = (m?: string) => {
    if (!m) return "google/gemini-3.7-flash";
    const lower = m.toLowerCase();
    if (lower.includes("gemini 3.7") || lower.includes("gemini-3.7") || lower.includes("flash")) {
      return "google/gemini-3.7-flash";
    }
    if (lower.includes("gemini 2.5") || lower.includes("gemini-2.5") || lower.includes("pro")) {
      return "google/gemini-2.5-pro";
    }
    if (lower.includes("3.7") || lower.includes("3-7") || lower.includes("sonnet 3.7")) {
      return "anthropic/claude-3-7-sonnet";
    }
    if (lower.includes("3.5") || lower.includes("3-5") || lower.includes("sonnet")) {
      return "anthropic/claude-3-5-sonnet";
    }
    if (lower.includes("o3") || lower.includes("o3-mini")) {
      return "openai/o3-mini";
    }
    if (lower.includes("gpt-4") || lower.includes("4o")) {
      return "openai/gpt-4o";
    }
    if (lower.includes("qwen")) {
      return "qwen/qwen-2.5-72b";
    }
    if (lower.includes("deepseek") || lower.includes("r1")) {
      return "deepseek/deepseek-r1";
    }
    return m;
  };

  const normalizeThinking = (t?: string) => {
    if (!t) return "medium";
    const lower = t.toLowerCase();
    if (lower === "min" || lower === "minimal") return "minimal";
    if (lower === "low") return "low";
    if (lower === "med" || lower === "medium") return "medium";
    if (lower === "high") return "high";
    if (lower === "x" || lower === "xhigh" || lower === "extra-high") return "xhigh";
    if (lower === "off" || lower === "none" || lower === "0") return "off";
    return "medium";
  };

  const [selectedModel, setSelectedModel] = useState(normalizeModel(activeModel));
  const [selectedThinking, setSelectedThinking] = useState(normalizeThinking(activeThinking));
  const [selectedToolDisplay, setSelectedToolDisplay] = useState<ToolDisplayMode>(toolDisplay);
  const [showModelPicker, setShowModelPicker] = useState(false);

  const models = [
    { id: "google/gemini-3.7-flash", name: "Gemini 3.7 Flash", tag: "Default", provider: "Google" },
    { id: "google/gemini-2.5-pro", name: "Gemini 2.5 Pro", tag: "Deep Reasoning", provider: "Google" },
    { id: "anthropic/claude-3-7-sonnet", name: "Claude 3.7 Sonnet", tag: "Hybrid", provider: "Anthropic" },
    { id: "anthropic/claude-3-5-sonnet", name: "Claude 3.5 Sonnet", tag: "Coding", provider: "Anthropic" },
    { id: "openai/gpt-4o", name: "GPT-4o", tag: "OpenAI", provider: "OpenAI" },
    { id: "openai/o3-mini", name: "o3-mini", tag: "Reasoning", provider: "OpenAI" },
    { id: "deepseek/deepseek-r1", name: "DeepSeek R1", tag: "Reasoning", provider: "DeepSeek" },
    { id: "qwen/qwen-2.5-72b", name: "Qwen 2.5 72B", tag: "Fast", provider: "Qwen" },
  ];

  const thinkingLevels = [
    { id: "auto", label: "auto" },
    { id: "off", label: "off" },
    { id: "minimal", label: "min" },
    { id: "low", label: "low" },
    { id: "medium", label: "med" },
    { id: "high", label: "high" },
    { id: "xhigh", label: "xh" },
    { id: "max", label: "max" },
  ];
  const toolDisplayOptions: Array<{ id: ToolDisplayMode; label: string; desc: string }> = [
    { id: "brief", label: "Brief", desc: "Compact pill" },
    { id: "full", label: "Full", desc: "Expanded card" },
    { id: "hidden", label: "Hidden", desc: "Chat only" },
  ];

  const currentModelObj = models.find((m) => m.id === selectedModel) || {
    id: selectedModel,
    name: selectedModel,
    tag: "Custom",
  };

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center p-4 bg-black/80 backdrop-blur-sm animate-in fade-in duration-150">
      <div className="bg-[#0e1117] border border-white/15 rounded-2xl w-full max-w-md overflow-hidden shadow-2xl">
        {/* Header matching quick_actions_sheet.dart */}
        <div className="px-5 py-3.5 border-b border-white/10 flex items-center justify-between">
          <div className="text-xs font-semibold text-white font-mono flex items-center gap-2">
            <span className="text-[#4fc3f7]">⚡</span>
            <span>Quick actions</span>
          </div>
          <button
            type="button"
            onClick={onClose}
            className="text-[#888] hover:text-white p-1 rounded-lg hover:bg-white/5 transition-colors cursor-pointer"
          >
            ✕
          </button>
        </div>

        <div className="p-4 space-y-3.5 text-xs font-mono">
          {/* 1. COMPACT CONTEXT (Item 1 in mobile quick_actions_sheet.dart) */}
          <button
            type="button"
            onClick={() => {
              onAction("compact");
              onClose();
            }}
            className="w-full p-3 rounded-xl bg-white/[0.02] hover:bg-white/5 border border-white/10 text-left transition-all flex items-center justify-between group cursor-pointer"
          >
            <div className="flex items-center gap-3">
              <div className="w-8 h-8 rounded-lg bg-[#4fc3f7]/10 border border-[#4fc3f7]/20 flex items-center justify-center text-[#4fc3f7] shrink-0">
                <svg className="w-4 h-4" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
                  <path d="M4 14h6v6m10-10h-6V4m0 6 7-7M10 14l-7 7" />
                </svg>
              </div>
              <div>
                <div className="font-semibold text-white group-hover:text-[#4fc3f7] transition-colors">
                  Compact context
                </div>
                <div className="text-[#888] text-[11px]">
                  Summarize old turns to free room.
                </div>
              </div>
            </div>
            <span className="text-[#666] group-hover:text-white transition-colors">›</span>
          </button>

          {/* 2. NEW SESSION (Item 2 in mobile quick_actions_sheet.dart) */}
          <button
            type="button"
            onClick={() => {
              if (confirm("Start a new session?\n\nThis clears the Pi-side conversation history. The current thread cannot be resumed.")) {
                onAction("new_session");
                onClose();
              }
            }}
            className="w-full p-3 rounded-xl bg-red-500/[0.03] hover:bg-red-500/10 border border-red-500/20 text-left transition-all flex items-center justify-between group cursor-pointer"
          >
            <div className="flex items-center gap-3">
              <div className="w-8 h-8 rounded-lg bg-red-500/10 border border-red-500/30 flex items-center justify-center text-red-400 shrink-0">
                <svg className="w-4 h-4" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
                  <path d="M12 3v18M3 12h18" />
                </svg>
              </div>
              <div>
                <div className="font-semibold text-red-300 group-hover:text-red-200 transition-colors">
                  New session
                </div>
                <div className="text-[#888] text-[11px]">
                  Clears the conversation on the Pi.
                </div>
              </div>
            </div>
            <span className="text-[#666] group-hover:text-white transition-colors">›</span>
          </button>

          <div className="border-t border-white/10" />

          {/* 3. MODEL ROW (Item 3 in mobile quick_actions_sheet.dart) */}
          <div>
            <div className="text-[#888] mb-2 uppercase tracking-wider text-[10px] flex items-center justify-between">
              <span>Model</span>
              <button
                type="button"
                onClick={() => setShowModelPicker(!showModelPicker)}
                className="text-[#4fc3f7] hover:underline text-[10px] cursor-pointer"
              >
                {showModelPicker ? "Collapse" : "Change"}
              </button>
            </div>

            {!showModelPicker ? (
              <button
                type="button"
                onClick={() => setShowModelPicker(true)}
                className="w-full p-2.5 rounded-xl bg-white/[0.02] hover:bg-white/5 border border-white/10 flex items-center justify-between cursor-pointer group"
              >
                <div className="flex items-center gap-2.5 min-w-0">
                  <span className="w-2.5 h-2.5 rounded-full bg-[#4fc3f7] shrink-0" />
                  <span className="font-medium text-white text-xs truncate">{currentModelObj.name}</span>
                </div>
                <span className="text-[10px] px-2 py-0.5 rounded bg-[#4fc3f7]/15 text-[#4fc3f7] font-semibold shrink-0">
                  {currentModelObj.tag}
                </span>
              </button>
            ) : (
              <div className="grid grid-cols-1 gap-1.5 max-h-44 overflow-y-auto pr-1 animate-in fade-in">
                {models.map((m) => {
                  const isSelected = selectedModel === m.id;
                  return (
                    <button
                      key={m.id}
                      type="button"
                      onClick={() => {
                        setSelectedModel(m.id);
                        onAction("set_model", m.id);
                        setShowModelPicker(false);
                      }}
                      className={`w-full p-2 rounded-xl border flex items-center justify-between transition-all cursor-pointer ${
                        isSelected
                          ? "bg-[#4fc3f7]/15 border-[#4fc3f7]/60 text-white"
                          : "bg-white/[0.02] border-white/5 text-[#a3a3a3] hover:text-white hover:bg-white/5"
                      }`}
                    >
                      <div className="flex items-center gap-2 min-w-0">
                        <span className={`w-2 h-2 rounded-full shrink-0 ${isSelected ? "bg-[#4fc3f7]" : "bg-white/10"}`} />
                        <span className="font-medium text-xs truncate">{m.name}</span>
                      </div>
                      <span className="text-[10px] px-1.5 py-0.2 rounded bg-white/10 text-[#888] shrink-0 ml-2">
                        {m.tag}
                      </span>
                    </button>
                  );
                })}
              </div>
            )}
          </div>

          <div className="border-t border-white/10" />

          {/* 4. THINKING BUDGET (Item 4 in mobile quick_actions_sheet.dart) */}
          <div>
            <div className="text-[#888] mb-1.5 uppercase tracking-wider text-[10px] flex items-center justify-between">
              <span>Thinking</span>
              <span className="text-[10px] text-[#4fc3f7] font-semibold">
                {selectedThinking}
              </span>
            </div>
            <div className="grid grid-cols-4 sm:grid-cols-8 gap-1">
              {thinkingLevels.map((t) => (
                <button
                  key={t.id}
                  type="button"
                  onClick={() => {
                    setSelectedThinking(t.id);
                    onAction("set_thinking", t.id);
                  }}
                  className={`py-1.5 px-0.5 text-center rounded-lg border text-[11px] font-mono transition-all cursor-pointer ${
                    selectedThinking === t.id
                      ? "bg-[#4fc3f7]/20 border-[#4fc3f7]/50 text-[#4fc3f7] font-bold"
                      : "bg-white/[0.02] border-white/10 text-[#888] hover:text-white hover:bg-white/5"
                  }`}
                >
                  {t.label}
                </button>
              ))}
            </div>
          </div>
          <div className="border-t border-white/10" />

          {/* 5. TOOL CALLS DISPLAY (Item 5) */}
          <div>
            <div className="text-[#888] mb-1.5 uppercase tracking-wider text-[10px] flex items-center justify-between">
              <span>Tool Calls Mode</span>
              <span className="text-[10px] text-[#4fc3f7]">
                {selectedToolDisplay === "brief"
                  ? "Brief (Default Pill)"
                  : selectedToolDisplay === "full"
                  ? "Full (Expanded)"
                  : "Hidden"}
              </span>
            </div>
            <div className="grid grid-cols-3 gap-1.5">
              {toolDisplayOptions.map((opt) => (
                <button
                  key={opt.id}
                  type="button"
                  onClick={() => {
                    setSelectedToolDisplay(opt.id);
                    if (onSetToolDisplay) onSetToolDisplay(opt.id);
                    onAction("set_tool_display", opt.id);
                  }}
                  className={`py-1.5 px-1.5 text-center rounded-lg border text-xs transition-all cursor-pointer ${
                    selectedToolDisplay === opt.id
                      ? "bg-[#4fc3f7]/20 border-[#4fc3f7]/50 text-[#4fc3f7] font-semibold"
                      : "bg-white/[0.02] border-white/10 text-[#888] hover:text-white hover:bg-white/5"
                  }`}
                >
                  <div className="font-medium">{opt.label}</div>
                  <div className="text-[9px] text-[#888] truncate">{opt.desc}</div>
                </button>
              ))}
            </div>
          </div>
        </div>
      </div>
    </div>
  );
}
