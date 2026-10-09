"use client";

import { useState } from "react";
import type { RelayStatus } from "./relay-connection";
import { RelayPicker } from "./relay-picker";
import { peerLabel, type PeerRecord } from "./session-list";
import { ToolDisplayMode } from "./quick-actions-modal";
import { readShowThinking, writeShowThinking } from "./thinking";

interface SettingsModalProps {
  onClose: () => void;
  relayUrl: string;
  relayStatus: RelayStatus;
  onRelayChange: (url: string) => void;
  peers: PeerRecord[];
  /** Fingerprint of the signed-in owner key (standard base64). */
  ownerPublicKey: string;
  onSignOut: () => void;
}

type Theme = "dark" | "light" | "system";
type FontScale = "small" | "medium" | "large";

const THEMES: Array<{ id: Theme; label: string }> = [
  { id: "dark", label: "Dark" },
  { id: "light", label: "Light" },
  { id: "system", label: "System" },
];

const FONT_SCALES: Array<{ id: FontScale; label: string }> = [
  { id: "small", label: "Small" },
  { id: "medium", label: "Medium (Default)" },
  { id: "large", label: "Large" },
];

const TOOL_DISPLAYS: Array<{ id: ToolDisplayMode; label: string; desc: string }> = [
  { id: "brief", label: "Brief", desc: "Compact pill" },
  { id: "full", label: "Full", desc: "Expanded card" },
  { id: "hidden", label: "Hidden", desc: "Chat only" },
];

function readChoice<T extends string>(key: string, options: Array<{ id: T }>, fallback: T): T {
  try {
    const saved = localStorage.getItem(key);
    return options.find((o) => o.id === saved)?.id ?? fallback;
  } catch {
    return fallback;
  }
}

export function SettingsModal({
  onClose,
  relayUrl,
  relayStatus,
  onRelayChange,
  peers,
  ownerPublicKey,
  onSignOut,
}: SettingsModalProps) {
  const [theme, setTheme] = useState<Theme>(() => readChoice("remotepi_theme", THEMES, "dark"));
  const [fontScale, setFontScale] = useState<FontScale>(() => readChoice("remotepi_font_scale", FONT_SCALES, "medium"));
  const [toolDisplay, setToolDisplay] = useState<ToolDisplayMode>(() =>
    readChoice("remotepi_tool_display", TOOL_DISPLAYS, "brief"),
  );
  const [showThinking, setShowThinking] = useState(readShowThinking);

  const handleSetToolDisplay = (mode: ToolDisplayMode) => {
    setToolDisplay(mode);
    try {
      localStorage.setItem("remotepi_tool_display", mode);
      window.dispatchEvent(new Event("tool_display_changed"));
    } catch {}
  };

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center p-4 bg-black/80 backdrop-blur-sm animate-in fade-in duration-150">
      <div className="bg-[#0e1117] border border-white/15 rounded-2xl w-full max-w-lg overflow-hidden shadow-2xl max-h-[90vh] flex flex-col">
        {/* Modal Header */}
        <div className="px-5 py-4 border-b border-white/10 flex items-center justify-between shrink-0">
          <div className="text-sm font-semibold text-white font-mono flex items-center gap-2">
            <span className="text-[#4fc3f7]">⚙</span>
            <span>Settings</span>
          </div>
          <button
            type="button"
            onClick={onClose}
            className="text-[#888] hover:text-white p-1 rounded-lg hover:bg-white/5 transition-colors cursor-pointer"
          >
            ✕
          </button>
        </div>

        {/* Modal Body */}
        <div className="p-5 overflow-y-auto space-y-6 text-xs font-mono">
          {/* SECTION 1: DISPLAY */}
          <div className="space-y-4">
            <div className="text-[#888] uppercase tracking-widest text-[11px] font-bold">
              Display
            </div>

            {/* Theme */}
            <div>
              <div className="text-[#ccc] mb-1.5 font-medium">Theme</div>
              <div className="grid grid-cols-3 gap-2">
                {THEMES.map((t) => (
                  <button
                    key={t.id}
                    type="button"
                    onClick={() => {
                      setTheme(t.id);
                      localStorage.setItem("remotepi_theme", t.id);
                    }}
                    className={`py-2 px-3 text-center rounded-xl border transition-all cursor-pointer ${
                      theme === t.id
                        ? "bg-[#4fc3f7]/20 border-[#4fc3f7]/50 text-[#4fc3f7] font-semibold"
                        : "bg-white/[0.02] border-white/10 text-[#888] hover:text-white hover:bg-white/5"
                    }`}
                  >
                    {t.label}
                  </button>
                ))}
              </div>
            </div>

            {/* Font Scale */}
            <div>
              <div className="text-[#ccc] mb-1.5 font-medium">Text Size</div>
              <div className="grid grid-cols-3 gap-2">
                {FONT_SCALES.map((s) => (
                  <button
                    key={s.id}
                    type="button"
                    onClick={() => {
                      setFontScale(s.id);
                      localStorage.setItem("remotepi_font_scale", s.id);
                    }}
                    className={`py-2 px-3 text-center rounded-xl border transition-all cursor-pointer ${
                      fontScale === s.id
                        ? "bg-[#4fc3f7]/20 border-[#4fc3f7]/50 text-[#4fc3f7] font-semibold"
                        : "bg-white/[0.02] border-white/10 text-[#888] hover:text-white hover:bg-white/5"
                    }`}
                  >
                    {s.label}
                  </button>
                ))}
              </div>
            </div>

            {/* Tool Calls Display */}
            <div>
              <div className="text-[#ccc] mb-1 font-medium">Tool Calls in Chat</div>
              <div className="text-[#888] text-[11px] mb-2 leading-relaxed">
                Full shows entire code blocks; Brief shows compact expandable pills; Hidden hides tools.
              </div>
              <div className="grid grid-cols-3 gap-2">
                {TOOL_DISPLAYS.map((m) => (
                  <button
                    key={m.id}
                    type="button"
                    onClick={() => handleSetToolDisplay(m.id)}
                    className={`py-2 px-2 text-center rounded-xl border transition-all cursor-pointer ${
                      toolDisplay === m.id
                        ? "bg-[#4fc3f7]/20 border-[#4fc3f7]/50 text-[#4fc3f7] font-semibold"
                        : "bg-white/[0.02] border-white/10 text-[#888] hover:text-white hover:bg-white/5"
                    }`}
                  >
                    <div className="font-medium">{m.label}</div>
                    <div className="text-[10px] text-[#888]">{m.desc}</div>
                  </button>
                ))}
              </div>
            </div>

            {/* Thinking traces (independent of the tool display mode) */}
            <label className="flex items-center justify-between gap-3 cursor-pointer">
              <div>
                <div className="text-[#ccc] font-medium">Show thinking traces</div>
                <div className="text-[#888] text-[11px] leading-relaxed">
                  Show the agent&apos;s reasoning as a collapsible Thinking block.
                </div>
              </div>
              <input
                type="checkbox"
                role="switch"
                checked={showThinking}
                onChange={(e) => {
                  setShowThinking(e.target.checked);
                  writeShowThinking(e.target.checked);
                }}
                className="w-4 h-4 accent-[#4fc3f7] cursor-pointer shrink-0"
              />
            </label>
          </div>

          <div className="border-t border-white/10" />

          {/* SECTION 2: RELAY */}
          <div className="space-y-3">
            <div className="text-[#888] uppercase tracking-widest text-[11px] font-bold">
              Relay
            </div>
            <RelayPicker key={relayUrl} relayUrl={relayUrl} status={relayStatus} onSave={onRelayChange} />
          </div>

          <div className="border-t border-white/10" />

          {/* SECTION 3: PAIRED PCs (from the owner's signed mesh, managed on the phone) */}
          <div className="space-y-3">
            <div className="text-[#888] uppercase tracking-widest text-[11px] font-bold">
              Paired PCs
            </div>
            {peers.length === 0 ? (
              <div className="text-center py-4 text-[#666]">No paired PCs</div>
            ) : (
              <div className="space-y-2 max-h-40 overflow-y-auto">
                {peers.map((p) => (
                  <div key={p.remoteEpk} className="p-2.5 rounded-xl bg-white/[0.02] border border-white/5">
                    <div className="text-white font-medium truncate">{peerLabel(p)}</div>
                    <div className="text-[#666] text-[10px] truncate">
                      {p.remoteEpk.slice(0, 8)}…{p.remoteEpk.slice(-4)} • paired {new Date(p.pairedAt).toLocaleDateString()}
                    </div>
                  </div>
                ))}
              </div>
            )}
            <div className="text-[10px] text-[#666]">Pair or remove PCs in the Remote Pi app on your phone.</div>
          </div>

          <div className="border-t border-white/10" />

          {/* SECTION 4: ACCOUNT */}
          <div className="space-y-2">
            <div className="text-[#888] uppercase tracking-widest text-[11px] font-bold">Account</div>
            <div className="text-[10px] text-[#666] truncate">
              Signed in as {ownerPublicKey.slice(0, 8)}…{ownerPublicKey.slice(-4)}
            </div>
            <button
              type="button"
              onClick={() => {
                if (confirm("Sign out of Remote Pi on this browser? You can sign in again from your phone.")) onSignOut();
              }}
              className="px-3 py-1.5 text-red-400 hover:text-red-300 border border-red-500/30 hover:bg-red-500/10 rounded-lg text-xs cursor-pointer"
            >
              Sign out
            </button>
          </div>

          <div className="border-t border-white/10" />

          {/* SECTION 5: ABOUT */}
          <div className="space-y-1 text-[#666] text-[11px]">
            <div className="text-white font-medium">Remote Pi Web 1.0.0</div>
            <div>Agent mesh over the Remote Pi relay</div>
          </div>
        </div>
      </div>
    </div>
  );
}
