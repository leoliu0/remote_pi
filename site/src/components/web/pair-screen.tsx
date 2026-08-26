"use client";

import { useState } from "react";
import { parsePairUri, saveSession, PairedSession } from "./web-client";

interface PairScreenProps {
  onPaired: (session: PairedSession) => void;
  savedSessions: PairedSession[];
  onSelectSaved: (session: PairedSession) => void;
  onDeleteSaved: (id: string) => void;
  onStartDemo: () => void;
}

export function PairScreen({
  onPaired,
  savedSessions,
  onSelectSaved,
  onDeleteSaved,
  onStartDemo,
}: PairScreenProps) {
  const [tab, setTab] = useState<"paste" | "manual" | "saved" | "qr">("paste");
  const [pairText, setPairText] = useState("");
  const [error, setError] = useState<string | null>(null);

  // Manual fields
  const [deviceName, setDeviceName] = useState("MacBook / Workstation");
  const [epk, setEpk] = useState("");
  const [token, setToken] = useState("");
  const [relayUrl, setRelayUrl] = useState("wss://relay-rp1.jacobmoura.work");
  const [roomId, setRoomId] = useState("main");
  const [isPairing, setIsPairing] = useState(false);

  const handlePasteSubmit = (e: React.FormEvent) => {
    e.preventDefault();
    setError(null);
    if (!pairText.trim()) {
      setError("Please enter or paste your Remote Pi pairing URI or token.");
      return;
    }

    const parsed = parsePairUri(pairText);
    if (!parsed || !parsed.remoteEpk) {
      setError("Could not parse pairing code. Ensure it starts with remotepi://pair or contains epk & token parameters.");
      return;
    }

    setIsPairing(true);
    const session: PairedSession = {
      id: `session_${Date.now()}_${Math.random().toString(36).substring(2, 7)}`,
      name: parsed.name || "Remote Pi",
      device: parsed.device || "Remote Host",
      remoteEpk: parsed.remoteEpk,
      token: parsed.token,
      relayUrl: parsed.relayUrl || "wss://relay-rp1.jacobmoura.work",
      roomId: parsed.roomId || "main",
      pairedAt: new Date().toISOString(),
      lastConnectedAt: new Date().toISOString(),
    };

    saveSession(session);
    setTimeout(() => {
      setIsPairing(false);
      onPaired(session);
    }, 600);
  };

  const handleManualSubmit = (e: React.FormEvent) => {
    e.preventDefault();
    setError(null);
    if (!epk.trim()) {
      setError("Public Key (EPK) is required.");
      return;
    }

    setIsPairing(true);
    const session: PairedSession = {
      id: `session_${Date.now()}_${Math.random().toString(36).substring(2, 7)}`,
      name: roomId === "main" ? "Remote Pi" : roomId,
      device: deviceName.trim() || "Remote Device",
      remoteEpk: epk.trim(),
      token: token.trim() || undefined,
      relayUrl: relayUrl.trim() || "wss://relay-rp1.jacobmoura.work",
      roomId: roomId.trim() || "main",
      pairedAt: new Date().toISOString(),
      lastConnectedAt: new Date().toISOString(),
    };

    saveSession(session);
    setTimeout(() => {
      setIsPairing(false);
      onPaired(session);
    }, 600);
  };

  return (
    <div className="relative min-h-[calc(100vh-80px)] flex flex-col items-center justify-center p-4 sm:p-6 md:p-8">
      {/* Ambient background glows */}
      <div className="absolute top-1/4 left-1/2 -translate-x-1/2 -translate-y-1/2 w-[600px] h-[350px] bg-[#4fc3f7]/10 blur-[120px] pointer-events-none rounded-full" />
      <div className="absolute bottom-10 right-1/4 w-[400px] h-[250px] bg-[#5fd38a]/5 blur-[100px] pointer-events-none rounded-full" />

      <div className="w-full max-w-[620px] relative z-10">
        {/* Header Branding */}
        <div className="text-center mb-8">
          <div className="inline-flex items-center gap-2 px-3 py-1 rounded-full bg-[#4fc3f7]/10 border border-[#4fc3f7]/30 text-[#4fc3f7] text-xs font-mono mb-4 tracking-wide uppercase">
            <span className="w-2 h-2 rounded-full bg-[#4fc3f7] animate-pulse" />
            Remote Pi Web Portal
          </div>
          <h1 className="text-3xl sm:text-4xl font-bold tracking-tight text-white font-[family-name:var(--ff-display)]">
            Login & Connect
          </h1>
          <p className="mt-2 text-sm sm:text-base text-[#a3a3a3] max-w-[460px] mx-auto font-[family-name:var(--ff-body)]">
            Pair your browser directly with your local Pi coding agent over encrypted WebSockets.
          </p>
        </div>

        {/* Card Frame */}
        <div className="bg-[#0a0c10]/90 backdrop-blur-xl border border-white/10 rounded-2xl shadow-2xl overflow-hidden">
          {/* Tabs */}
          <div className="flex border-b border-white/10 bg-black/40 p-1.5 gap-1">
            <button
              type="button"
              onClick={() => { setTab("paste"); setError(null); }}
              className={`flex-1 py-2.5 px-3 text-xs sm:text-sm font-medium rounded-xl transition-all ${
                tab === "paste"
                  ? "bg-[#4fc3f7]/15 text-[#4fc3f7] border border-[#4fc3f7]/30 shadow-sm"
                  : "text-[#a3a3a3] hover:text-white hover:bg-white/5"
              }`}
            >
              Paste Pairing Code
            </button>
            <button
              type="button"
              onClick={() => { setTab("manual"); setError(null); }}
              className={`flex-1 py-2.5 px-3 text-xs sm:text-sm font-medium rounded-xl transition-all ${
                tab === "manual"
                  ? "bg-[#4fc3f7]/15 text-[#4fc3f7] border border-[#4fc3f7]/30 shadow-sm"
                  : "text-[#a3a3a3] hover:text-white hover:bg-white/5"
              }`}
            >
              Manual Details
            </button>
            {savedSessions.length > 0 && (
              <button
                type="button"
                onClick={() => { setTab("saved"); setError(null); }}
                className={`flex-1 py-2.5 px-3 text-xs sm:text-sm font-medium rounded-xl transition-all flex items-center justify-center gap-1.5 ${
                  tab === "saved"
                    ? "bg-[#4fc3f7]/15 text-[#4fc3f7] border border-[#4fc3f7]/30 shadow-sm"
                    : "text-[#a3a3a3] hover:text-white hover:bg-white/5"
                }`}
              >
                Saved ({savedSessions.length})
              </button>
            )}
          </div>

          <div className="p-6 sm:p-8">
            {error && (
              <div className="mb-6 p-3.5 rounded-xl bg-red-500/10 border border-red-500/30 text-red-400 text-xs sm:text-sm font-mono flex items-start gap-2.5">
                <svg className="w-5 h-5 shrink-0 mt-0.5 text-red-400" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
                  <circle cx="12" cy="12" r="10" />
                  <line x1="12" y1="8" x2="12" y2="12" />
                  <line x1="12" y1="16" x2="12.01" y2="16" />
                </svg>
                <div className="flex-1">{error}</div>
              </div>
            )}

            {/* TAB: PASTE */}
            {tab === "paste" && (
              <form onSubmit={handlePasteSubmit} className="space-y-5">
                <div>
                  <label className="block text-xs font-mono text-[#a3a3a3] uppercase tracking-wider mb-2">
                    QR Code Payload / Pairing URL
                  </label>
                  <div className="relative">
                    <textarea
                      rows={4}
                      value={pairText}
                      onChange={(e) => setPairText(e.target.value)}
                      placeholder="Paste remotepi://pair?epk=...&t=... or raw code from terminal /remote-pi"
                      className="w-full bg-black/60 border border-white/15 focus:border-[#4fc3f7] focus:ring-1 focus:ring-[#4fc3f7] rounded-xl px-4 py-3 text-white text-xs sm:text-sm font-mono placeholder:text-[#555] transition-all resize-none outline-none"
                    />
                  </div>
                  <div className="flex items-center justify-between mt-2 text-xs text-[#777] font-mono">
                    <span>How to get: run <code className="text-[#4fc3f7] font-bold">/remote-pi</code> in Pi</span>
                    <button
                      type="button"
                      onClick={async () => {
                        try {
                          const clip = await navigator.clipboard.readText();
                          if (clip) setPairText(clip);
                        } catch {
                          setError("Clipboard read permission denied. Please paste manually.");
                        }
                      }}
                      className="text-[#4fc3f7] hover:underline cursor-pointer flex items-center gap-1"
                    >
                      Paste from clipboard
                    </button>
                  </div>
                </div>

                <button
                  type="submit"
                  disabled={isPairing}
                  className="w-full py-3.5 px-4 bg-[#4fc3f7] hover:bg-[#38bdf8] active:scale-[0.99] text-[#04222e] font-semibold rounded-xl text-sm transition-all duration-150 flex items-center justify-center gap-2 cursor-pointer shadow-lg shadow-[#4fc3f7]/20 disabled:opacity-50"
                >
                  {isPairing ? (
                    <>
                      <div className="w-4 h-4 border-2 border-[#04222e] border-t-transparent rounded-full animate-spin" />
                      Connecting to Relay…
                    </>
                  ) : (
                    <>
                      Connect to Agent
                      <svg className="w-4 h-4" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.5">
                        <line x1="5" y1="12" x2="19" y2="12" />
                        <polyline points="12 5 19 12 12 19" />
                      </svg>
                    </>
                  )}
                </button>
              </form>
            )}

            {/* TAB: MANUAL */}
            {tab === "manual" && (
              <form onSubmit={handleManualSubmit} className="space-y-4">
                <div className="grid grid-cols-1 sm:grid-cols-2 gap-4">
                  <div>
                    <label className="block text-xs font-mono text-[#a3a3a3] mb-1.5">Device Label</label>
                    <input
                      type="text"
                      value={deviceName}
                      onChange={(e) => setDeviceName(e.target.value)}
                      placeholder="My Mac / Workstation"
                      className="w-full bg-black/60 border border-white/15 focus:border-[#4fc3f7] rounded-xl px-3.5 py-2.5 text-white text-xs sm:text-sm font-mono outline-none"
                    />
                  </div>
                  <div>
                    <label className="block text-xs font-mono text-[#a3a3a3] mb-1.5">Room ID</label>
                    <input
                      type="text"
                      value={roomId}
                      onChange={(e) => setRoomId(e.target.value)}
                      placeholder="main"
                      className="w-full bg-black/60 border border-white/15 focus:border-[#4fc3f7] rounded-xl px-3.5 py-2.5 text-white text-xs sm:text-sm font-mono outline-none"
                    />
                  </div>
                </div>

                <div>
                  <label className="block text-xs font-mono text-[#a3a3a3] mb-1.5">Public Key (EPK)</label>
                  <input
                    type="text"
                    value={epk}
                    onChange={(e) => setEpk(e.target.value)}
                    placeholder="Peer EPK (base64 string)"
                    className="w-full bg-black/60 border border-white/15 focus:border-[#4fc3f7] rounded-xl px-3.5 py-2.5 text-white text-xs sm:text-sm font-mono outline-none"
                  />
                </div>

                <div>
                  <label className="block text-xs font-mono text-[#a3a3a3] mb-1.5">Pairing Token (optional)</label>
                  <input
                    type="text"
                    value={token}
                    onChange={(e) => setToken(e.target.value)}
                    placeholder="One-time secret token"
                    className="w-full bg-black/60 border border-white/15 focus:border-[#4fc3f7] rounded-xl px-3.5 py-2.5 text-white text-xs sm:text-sm font-mono outline-none"
                  />
                </div>

                <div>
                  <label className="block text-xs font-mono text-[#a3a3a3] mb-1.5">Relay WebSocket URL</label>
                  <input
                    type="text"
                    value={relayUrl}
                    onChange={(e) => setRelayUrl(e.target.value)}
                    placeholder="wss://relay-rp1.jacobmoura.work"
                    className="w-full bg-black/60 border border-white/15 focus:border-[#4fc3f7] rounded-xl px-3.5 py-2.5 text-white text-xs sm:text-sm font-mono outline-none"
                  />
                </div>

                <button
                  type="submit"
                  disabled={isPairing}
                  className="w-full mt-2 py-3.5 px-4 bg-[#4fc3f7] hover:bg-[#38bdf8] text-[#04222e] font-semibold rounded-xl text-sm transition-all flex items-center justify-center gap-2 cursor-pointer shadow-lg shadow-[#4fc3f7]/20"
                >
                  {isPairing ? "Connecting…" : "Connect with Credentials"}
                </button>
              </form>
            )}

            {/* TAB: SAVED */}
            {tab === "saved" && (
              <div className="space-y-3">
                <div className="text-xs text-[#a3a3a3] font-mono mb-2">
                  Previously paired machines saved in this browser:
                </div>
                {savedSessions.map((s) => (
                  <div
                    key={s.id}
                    className="flex items-center justify-between p-3.5 rounded-xl bg-white/[0.03] border border-white/10 hover:border-[#4fc3f7]/40 transition-all group"
                  >
                    <button
                      type="button"
                      onClick={() => onSelectSaved(s)}
                      className="flex items-center gap-3 text-left flex-1 cursor-pointer"
                    >
                      <div className="w-9 h-9 rounded-lg bg-[#4fc3f7]/15 border border-[#4fc3f7]/30 flex items-center justify-center text-[#4fc3f7]">
                        <svg className="w-5 h-5" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
                          <rect x="2" y="3" width="20" height="14" rx="2" ry="2" />
                          <line x1="8" y1="21" x2="16" y2="21" />
                          <line x1="12" y1="17" x2="12" y2="21" />
                        </svg>
                      </div>
                      <div>
                        <div className="text-sm font-semibold text-white group-hover:text-[#4fc3f7] transition-colors">
                          {s.device}
                        </div>
                        <div className="text-xs text-[#888] font-mono">
                          {s.roomId} &bull; {s.remoteEpk.substring(0, 12)}…
                        </div>
                      </div>
                    </button>

                    <div className="flex items-center gap-2">
                      <button
                        type="button"
                        onClick={() => onSelectSaved(s)}
                        className="px-3 py-1.5 bg-[#4fc3f7]/20 hover:bg-[#4fc3f7] text-[#4fc3f7] hover:text-[#04222e] rounded-lg text-xs font-mono font-medium transition-all cursor-pointer"
                      >
                        Connect
                      </button>
                      <button
                        type="button"
                        onClick={() => onDeleteSaved(s.id)}
                        className="p-1.5 text-[#666] hover:text-red-400 hover:bg-red-500/10 rounded-lg transition-colors cursor-pointer"
                        title="Remove session"
                      >
                        <svg className="w-4 h-4" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
                          <polyline points="3 6 5 6 21 6" />
                          <path d="M19 6v14a2 2 0 0 1-2 2H7a2 2 0 0 1-2-2V6m3 0V4a2 2 0 0 1 2-2h4a2 2 0 0 1 2 2v2" />
                        </svg>
                      </button>
                    </div>
                  </div>
                ))}
              </div>
            )}

            {/* Quick Demo Footer */}
            <div className="mt-6 pt-5 border-t border-white/10 flex flex-col sm:flex-row items-center justify-between gap-3 text-xs text-[#888]">
              <span>Don't have Pi running right now?</span>
              <button
                type="button"
                onClick={onStartDemo}
                className="text-[#4fc3f7] hover:text-white px-3 py-1.5 rounded-lg bg-[#4fc3f7]/10 hover:bg-[#4fc3f7]/20 border border-[#4fc3f7]/30 transition-all font-mono cursor-pointer flex items-center gap-1.5"
              >
                <span className="w-1.5 h-1.5 rounded-full bg-[#5fd38a]" />
                Explore Demo Chat
              </button>
            </div>
          </div>
        </div>

        {/* Instruction Note */}
        <div className="mt-6 bg-[#0a0a0a]/60 border border-white/5 rounded-xl p-4 text-xs font-mono text-[#888] flex items-center justify-between">
          <div className="flex items-center gap-2">
            <span className="text-[#5fd38a]">●</span>
            <span>Desktop: Install extension via <code className="text-[#4fc3f7]">pi install npm:remote-pi</code></span>
          </div>
          <span className="text-[#555] hidden sm:inline">E2E WebSocket Relay</span>
        </div>
      </div>
    </div>
  );
}
