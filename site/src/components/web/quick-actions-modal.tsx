"use client";

import { useEffect, useState } from "react";
import { thinkingChoices, type ModelsCatalogue, type RoomAction, type WireModel } from "./web-client";
import { modelRowLabel, thinkingLabel } from "./session-list";

export type ToolDisplayMode = "brief" | "full" | "hidden";

interface QuickActionsModalProps {
  /** Display name from the relay's room meta, shown until `list_models` answers. */
  activeModel?: string;
  activeThinking?: string;
  toolDisplay?: ToolDisplayMode;
  onClose: () => void;
  /** Sends a typed action; failures surface through the page (app: snackbar). */
  onAction: (action: RoomAction) => void;
  /** `list_models` → the Pi's real catalogue (app: QuickActionsViewModel.loadModels). */
  onLoadModels: () => Promise<ModelsCatalogue>;
  onSetToolDisplay: (mode: ToolDisplayMode) => void;
}

const modelKey = (m: Pick<WireModel, "provider" | "id">) => `${m.provider}/${m.id}`;

export function QuickActionsModal({
  activeModel,
  activeThinking = "medium",
  toolDisplay = "brief",
  onClose,
  onAction,
  onLoadModels,
  onSetToolDisplay,
}: QuickActionsModalProps) {
  const [catalogue, setCatalogue] = useState<ModelsCatalogue | null>(null);
  const [modelsError, setModelsError] = useState<string | null>(null);
  const [selectedModel, setSelectedModel] = useState<WireModel | null>(null);
  const [selectedThinking, setSelectedThinking] = useState(activeThinking);
  const [selectedToolDisplay, setSelectedToolDisplay] = useState<ToolDisplayMode>(toolDisplay);
  const [showModelPicker, setShowModelPicker] = useState(false);

  useEffect(() => {
    let alive = true;
    onLoadModels().then(
      (result) => {
        if (!alive) return;
        setCatalogue(result);
        setSelectedModel((picked) => picked ?? result.current);
      },
      (err: unknown) => {
        if (alive) setModelsError(err instanceof Error ? err.message : String(err));
      }
    );
    return () => {
      alive = false;
    };
  }, [onLoadModels]);

  const thinkingLevels = thinkingChoices(selectedModel);
  // A model without the thinking surface greys the row out, as in the app.
  const thinkingDisabled = selectedModel?.reasoning === false;
  const toolDisplayOptions: Array<{ id: ToolDisplayMode; label: string; desc: string }> = [
    { id: "brief", label: "Brief", desc: "Compact pill" },
    { id: "full", label: "Full", desc: "Expanded card" },
    { id: "hidden", label: "Hidden", desc: "Chat only" },
  ];

  const currentModelName = modelRowLabel(selectedModel?.name ?? activeModel);
  const currentModelTag = selectedModel?.provider ?? "";

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
              onAction({ action: "compact" });
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
                onAction({ action: "new_session" });
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
                  <span className="font-medium text-white text-xs truncate">{currentModelName}</span>
                </div>
                {currentModelTag && (
                  <span className="text-[10px] px-2 py-0.5 rounded bg-[#4fc3f7]/15 text-[#4fc3f7] font-semibold shrink-0">
                    {currentModelTag}
                  </span>
                )}
              </button>
            ) : (
              <div className="grid grid-cols-1 gap-1.5 max-h-44 overflow-y-auto pr-1 animate-in fade-in">
                {modelsError && <div className="p-2 text-red-300">Couldn&apos;t load models: {modelsError}</div>}
                {!modelsError && !catalogue && <div className="p-2 text-[#888]">Loading models…</div>}
                {catalogue && catalogue.models.length === 0 && <div className="p-2 text-[#888]">The Pi reported no models.</div>}
                {catalogue?.models.map((m) => {
                  const isSelected = selectedModel !== null && modelKey(selectedModel) === modelKey(m);
                  return (
                    <button
                      key={modelKey(m)}
                      type="button"
                      onClick={() => {
                        setSelectedModel(m);
                        onAction({ action: "set_model", provider: m.provider, modelId: m.id });
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
                        {m.provider}
                        {m.reasoning ? " · reasoning" : ""}
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
                {thinkingLabel(selectedThinking)}
              </span>
            </div>
            <div className="grid grid-cols-4 sm:grid-cols-8 gap-1">
              {thinkingLevels.map((level) => (
                <button
                  key={level}
                  type="button"
                  disabled={thinkingDisabled}
                  onClick={() => {
                    setSelectedThinking(level);
                    onAction({ action: "set_thinking", thinking: level });
                  }}
                  className={`py-1.5 px-0.5 text-center rounded-lg border text-[11px] font-mono transition-all cursor-pointer disabled:cursor-not-allowed disabled:opacity-40 ${
                    selectedThinking === level
                      ? "bg-[#4fc3f7]/20 border-[#4fc3f7]/50 text-[#4fc3f7] font-bold"
                      : "bg-white/[0.02] border-white/10 text-[#888] hover:text-white hover:bg-white/5"
                  }`}
                >
                  {thinkingLabel(level)}
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
                    onSetToolDisplay(opt.id);
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
