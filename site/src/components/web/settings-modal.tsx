"use client";

import { useState, useEffect } from "react";
import { PairedSession, getSavedSessions, deleteSession } from "./web-client";
import { ToolDisplayMode } from "./quick-actions-modal";

interface SettingsModalProps {
  onClose: () => void;
  onOpenPair: () => void;
  onToolDisplayChange?: (mode: ToolDisplayMode) => void;
}

export function SettingsModal({
  onClose,
  onOpenPair,
  onToolDisplayChange,
}: SettingsModalProps) {
  const [theme, setTheme] = useState<"dark" | "light" | "system">("dark");
  const [fontFamily, setFontFamily] = useState("jetbrains");
  const [fontScale, setFontScale] = useState<"small" | "medium" | "large">("medium");
  const [toolDisplay, setToolDisplay] = useState<ToolDisplayMode>("brief");
  const [relayUrl, setRelayUrl] = useState("ws://178.157.59.181:3000");
  const [savedRelayMsg, setSavedRelayMsg] = useState(false);
  const [peers, setPeers] = useState<PairedSession[]>([]);

  useEffect(() => {
    try {
      const savedTheme = localStorage.getItem("remotepi_theme") as any;
      if (savedTheme) setTheme(savedTheme);

      const savedFont = localStorage.getItem("remotepi_font");
      if (savedFont) setFontFamily(savedFont);

      const savedScale = localStorage.getItem("remotepi_font_scale") as any;
      if (savedScale) setFontScale(savedScale);

      const savedTool = localStorage.getItem("remotepi_tool_display") as any;
      if (savedTool) setToolDisplay(savedTool);

      const savedRelay = localStorage.getItem("remotepi_relay_url");
      if (savedRelay) setRelayUrl(savedRelay);

      setPeers(getSavedSessions());
    } catch {}
  }, []);

  const handleSaveRelay = () => {
    try {
      localStorage.setItem("remotepi_relay_url", relayUrl);
      setSavedRelayMsg(true);
      setTimeout(() => setSavedRelayMsg(false), 2500);
    } catch {}
  };

  const handleResetRelay = () => {
    const defaultRelay = "ws://178.157.59.181:3000";
    setRelayUrl(defaultRelay);
    try {
      localStorage.setItem("remotepi_relay_url", defaultRelay);
      setSavedRelayMsg(true);
      setTimeout(() => setSavedRelayMsg(false), 2500);
    } catch {}
  };

  const handleSetToolDisplay = (mode: ToolDisplayMode) => {
    setToolDisplay(mode);
    try {
      localStorage.setItem("remotepi_tool_display", mode);
      window.dispatchEvent(new Event("tool_display_changed"));
      if (onToolDisplayChange) onToolDisplayChange(mode);
    } catch {}
  };

  const handleRevokePeer = (id: string) => {
    if (confirm("Revoke this pairing? You will need to pair again.")) {
      deleteSession(id);
      setPeers(getSavedSessions());
    }
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
                {[
                  { id: "dark", label: "Dark" },
                  { id: "light", label: "Light" },
                  { id: "system", label: "System" },
                ].map((t) => (
                  <button
                    key={t.id}
                    type="button"
                    onClick={() => {
                      setTheme(t.id as any);
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
                {[
                  { id: "small", label: "Small" },
                  { id: "medium", label: "Medium (Default)" },
                  { id: "large", label: "Large" },
                ].map((s) => (
                  <button
                    key={s.id}
                    type="button"
                    onClick={() => {
                      setFontScale(s.id as any);
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
                {[
                  { id: "brief", label: "Brief", desc: "Compact pill" },
                  { id: "full", label: "Full", desc: "Expanded card" },
                  { id: "hidden", label: "Hidden", desc: "Chat only" },
                ].map((m) => (
                  <button
                    key={m.id}
                    type="button"
                    onClick={() => handleSetToolDisplay(m.id as ToolDisplayMode)}
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
          </div>

          <div className="border-t border-white/10" />

          {/* SECTION 2: RELAY TRANSPORT */}
          <div className="space-y-3">
            <div className="text-[#888] uppercase tracking-widest text-[11px] font-bold">
              Relay Transport
            </div>
            <div>
              <input
                type="text"
                value={relayUrl}
                onChange={(e) => setRelayUrl(e.target.value)}
                placeholder="ws://my-relay.example.com"
                className="w-full bg-[#050505] border border-white/10 focus:border-[#4fc3f7] rounded-xl px-3 py-2 text-xs text-white font-mono focus:outline-none transition-colors"
              />
              <div className="mt-1 text-[10px] text-[#666]">
                Current: {relayUrl}
              </div>
            </div>
            <div className="flex items-center gap-3">
              <button
                type="button"
                onClick={handleSaveRelay}
                className="px-4 py-2 bg-[#4fc3f7] hover:bg-[#38b6eb] text-black text-xs font-semibold rounded-xl font-mono cursor-pointer transition-colors"
              >
                Save
              </button>
              <button
                type="button"
                onClick={handleResetRelay}
                className="text-[#888] hover:text-white text-xs underline cursor-pointer"
              >
                Use default Relay
              </button>
              {savedRelayMsg && (
                <span className="text-[#6CD28A] text-xs animate-in fade-in">✓ Saved</span>
              )}
            </div>
          </div>

          <div className="border-t border-white/10" />

          {/* SECTION 3: PAIRINGS */}
          <div className="space-y-3">
            <div className="flex items-center justify-between">
              <div className="text-[#888] uppercase tracking-widest text-[11px] font-bold">
                Pairings
              </div>
              <button
                type="button"
                onClick={() => {
                  onClose();
                  onOpenPair();
                }}
                className="text-[#4fc3f7] hover:underline text-xs flex items-center gap-1 cursor-pointer"
              >
                <span>+</span> Add pairing
              </button>
            </div>

            {peers.length === 0 ? (
              <div className="text-center py-4 text-[#666]">No saved pairings</div>
            ) : (
              <div className="space-y-2 max-h-40 overflow-y-auto">
                {peers.map((p) => (
                  <div
                    key={p.id}
                    className="p-2.5 rounded-xl bg-white/[0.02] border border-white/5 flex items-center justify-between"
                  >
                    <div className="min-w-0 flex-1">
                      <div className="text-white font-medium truncate">{p.name}</div>
                      <div className="text-[#666] text-[10px] truncate">
                        {p.device} • {p.remoteEpk.slice(0, 8)}…{p.remoteEpk.slice(-4)}
                      </div>
                    </div>
                    <button
                      type="button"
                      onClick={() => handleRevokePeer(p.id)}
                      className="text-red-400 hover:text-red-300 text-xs px-2 py-1 rounded hover:bg-red-500/10 transition-colors cursor-pointer"
                    >
                      Revoke
                    </button>
                  </div>
                ))}
              </div>
            )}
          </div>

          <div className="border-t border-white/10" />

          {/* SECTION 4: ABOUT */}
          <div className="space-y-1 text-[#666] text-[11px]">
            <div className="text-white font-medium">Remote Pi Web 1.0.0</div>
            <div>Decentralized agent mesh protocol • E2E Encrypted</div>
          </div>
        </div>
      </div>
    </div>
  );
}
