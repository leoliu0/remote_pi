"use client";

import { useState } from "react";

interface QuickActionsModalProps {
  activeModel?: string;
  activeThinking?: string;
  onClose: () => void;
  onAction: (action: string, payload?: string) => void;
}

export function QuickActionsModal({
  activeModel,
  activeThinking = "medium",
  onClose,
  onAction,
}: QuickActionsModalProps) {
  // Normalize initial active model
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

  const [selectedModel, setSelectedModel] = useState(normalizeModel(activeModel));
  const [selectedThinking, setSelectedThinking] = useState(activeThinking);

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
    { id: "off", label: "Off" },
    { id: "low", label: "Low (1k)" },
    { id: "medium", label: "Medium (4k)" },
    { id: "high", label: "High (16k)" },
  ];

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center p-4 bg-black/80 backdrop-blur-sm animate-in fade-in duration-150">
      <div className="bg-[#0e1117] border border-white/15 rounded-2xl w-full max-w-md overflow-hidden shadow-2xl">
        <div className="px-5 py-3.5 border-b border-white/10 flex items-center justify-between">
          <div className="text-xs font-semibold text-white font-mono flex items-center gap-2">
            <span className="text-[#4fc3f7]">⚡</span>
            <span>Quick Actions</span>
          </div>
          <button
            type="button"
            onClick={onClose}
            className="text-[#888] hover:text-white p-1 rounded-lg hover:bg-white/5 transition-colors cursor-pointer"
          >
            ✕
          </button>
        </div>

        <div className="p-4 space-y-4 text-xs font-mono">
          {/* Action 1: Model Selection */}
          <div>
            <div className="text-[#888] mb-2 uppercase tracking-wider text-[10px]">Active Model</div>
            <div className="grid grid-cols-1 gap-1.5 max-h-52 overflow-y-auto pr-1">
              {models.map((m) => {
                const isSelected = selectedModel === m.id || normalizeModel(activeModel) === m.id;
                return (
                  <button
                    key={m.id}
                    type="button"
                    onClick={() => {
                      setSelectedModel(m.id);
                      onAction("set_model", m.id);
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
          </div>

          {/* Action 2: Thinking Budget */}
          <div>
            <div className="text-[#888] mb-1.5 uppercase tracking-wider text-[10px]">Thinking Level</div>
            <div className="grid grid-cols-4 gap-1.5">
              {thinkingLevels.map((t) => (
                <button
                  key={t.id}
                  type="button"
                  onClick={() => {
                    setSelectedThinking(t.id);
                    onAction("set_thinking", t.id);
                  }}
                  className={`py-1.5 px-1 text-center rounded-lg border text-[11px] transition-all cursor-pointer ${
                    selectedThinking === t.id
                      ? "bg-[#4fc3f7]/20 border-[#4fc3f7]/50 text-[#4fc3f7] font-semibold"
                      : "bg-white/[0.02] border-white/10 text-[#888] hover:text-white hover:bg-white/5"
                  }`}
                >
                  {t.label}
                </button>
              ))}
            </div>
          </div>

          {/* Action 3: Session Operations */}
          <div>
            <div className="text-[#888] mb-1.5 uppercase tracking-wider text-[10px]">Operations</div>
            <div className="grid grid-cols-2 gap-2">
              <button
                type="button"
                onClick={() => {
                  onAction("compact");
                  onClose();
                }}
                className="p-2 rounded-xl bg-white/[0.03] hover:bg-white/10 border border-white/10 text-white text-xs font-mono transition-colors flex items-center justify-center gap-1.5 cursor-pointer"
              >
                <span>📦</span>
                <span>Compact Context</span>
              </button>
              <button
                type="button"
                onClick={() => {
                  if (confirm("Start a new clean session? This resets current message context.")) {
                    onAction("new_session");
                    onClose();
                  }
                }}
                className="p-2 rounded-xl bg-red-500/10 hover:bg-red-500/20 border border-red-500/30 text-red-300 text-xs font-mono transition-colors flex items-center justify-center gap-1.5 cursor-pointer"
              >
                <span>✨</span>
                <span>New Session</span>
              </button>
            </div>
          </div>
        </div>
      </div>
    </div>
  );
}
