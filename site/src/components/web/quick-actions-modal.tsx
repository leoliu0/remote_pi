"use client";

import { useState } from "react";

interface QuickActionsModalProps {
  onClose: () => void;
  onAction: (action: string, payload?: string) => void;
}

export function QuickActionsModal({ onClose, onAction }: QuickActionsModalProps) {
  const [selectedModel, setSelectedModel] = useState("anthropic/claude-3-7-sonnet");
  const [selectedThinking, setSelectedThinking] = useState("medium");

  const models = [
    { id: "anthropic/claude-3-7-sonnet", name: "Claude 3.7 Sonnet (Hybrid)", tag: "Recommended" },
    { id: "anthropic/claude-3-5-sonnet", name: "Claude 3.5 Sonnet", tag: "Fast" },
    { id: "openai/gpt-4o", name: "GPT-4o", tag: "OpenAI" },
    { id: "openai/o3-mini", name: "o3-mini", tag: "Reasoning" },
    { id: "google/gemini-2.0-flash", name: "Gemini 2.0 Flash", tag: "Fast" },
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
        <div className="px-5 py-4 border-b border-white/10 flex items-center justify-between">
          <div className="text-sm font-semibold text-white font-mono flex items-center gap-2">
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

        <div className="p-5 space-y-5 text-xs font-mono">
          {/* Action 1: Model Selection */}
          <div>
            <div className="text-[#888] mb-2 uppercase tracking-wider text-[10px]">Active Model</div>
            <div className="space-y-1.5">
              {models.map((m) => (
                <button
                  key={m.id}
                  type="button"
                  onClick={() => {
                    setSelectedModel(m.id);
                    onAction("set_model", m.id);
                  }}
                  className={`w-full p-2.5 rounded-xl border flex items-center justify-between transition-all cursor-pointer ${
                    selectedModel === m.id
                      ? "bg-[#4fc3f7]/15 border-[#4fc3f7]/50 text-white"
                      : "bg-white/[0.02] border-white/5 text-[#a3a3a3] hover:text-white hover:bg-white/5"
                  }`}
                >
                  <div className="flex items-center gap-2">
                    <span className={`w-2 h-2 rounded-full ${selectedModel === m.id ? "bg-[#4fc3f7]" : "bg-transparent"}`} />
                    <span className="font-medium text-xs">{m.name}</span>
                  </div>
                  <span className="text-[10px] px-1.5 py-0.5 rounded bg-white/10 text-[#888]">{m.tag}</span>
                </button>
              ))}
            </div>
          </div>

          {/* Action 2: Thinking Budget */}
          <div>
            <div className="text-[#888] mb-2 uppercase tracking-wider text-[10px]">Thinking Level</div>
            <div className="grid grid-cols-4 gap-1.5">
              {thinkingLevels.map((t) => (
                <button
                  key={t.id}
                  type="button"
                  onClick={() => {
                    setSelectedThinking(t.id);
                    onAction("set_thinking", t.id);
                  }}
                  className={`py-2 px-1 text-center rounded-lg border text-[11px] transition-all cursor-pointer ${
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
            <div className="text-[#888] mb-2 uppercase tracking-wider text-[10px]">Operations</div>
            <div className="grid grid-cols-2 gap-2">
              <button
                type="button"
                onClick={() => {
                  onAction("compact");
                  onClose();
                }}
                className="p-2.5 rounded-xl bg-white/[0.03] hover:bg-white/10 border border-white/10 text-white text-xs font-mono transition-colors flex items-center justify-center gap-1.5 cursor-pointer"
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
                className="p-2.5 rounded-xl bg-red-500/10 hover:bg-red-500/20 border border-red-500/30 text-red-300 text-xs font-mono transition-colors flex items-center justify-center gap-1.5 cursor-pointer"
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
