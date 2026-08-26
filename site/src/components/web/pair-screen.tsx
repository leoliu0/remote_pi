"use client";

import { useState, useEffect } from "react";
import { parsePairUri, saveSession, PairedSession } from "./web-client";

interface LocalSessionInfo {
  localPiDetected: boolean;
  deviceName: string;
  relayUrl: string;
  remoteEpk: string;
  token: string;
  roomId: string;
  hasLocalBroker: boolean;
  peersCount: number;
  recentSessions: { name: string; path: string; roomId: string }[];
}

interface PairScreenProps {
  onPaired: (session: PairedSession) => void;
  savedSessions: PairedSession[];
  onSelectSaved: (session: PairedSession) => void;
  onDeleteSaved: (id: string) => void;
}

export function PairScreen({
  onPaired,
  savedSessions,
  onSelectSaved,
  onDeleteSaved,
}: PairScreenProps) {
  const [tab, setTab] = useState<"local" | "paste" | "manual" | "saved">("local");
  const [pairText, setPairText] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [localInfo, setLocalInfo] = useState<LocalSessionInfo | null>(null);
  const [selectedRoom, setSelectedRoom] = useState("main");
  const [selectedRoomName, setSelectedRoomName] = useState("Remote Pi (main)");

  // Manual fields
  const [deviceName, setDeviceName] = useState("MacBook / Workstation");
  const [epk, setEpk] = useState("");
  const [token, setToken] = useState("");
  const [relayUrl, setRelayUrl] = useState("ws://178.157.59.181:3000");
  const [roomId, setRoomId] = useState("main");
  const [isPairing, setIsPairing] = useState(false);

  // Detect local Pi session automatically
  useEffect(() => {
    fetch("/api/local-session")
      .then((res) => res.json())
      .then((data: LocalSessionInfo) => {
        if (data && data.localPiDetected) {
          setLocalInfo(data);
          setRelayUrl(data.relayUrl);
          setEpk(data.remoteEpk);
          setToken(data.token);
          setDeviceName(data.deviceName);
        } else {
          setTab("paste");
        }
      })
      .catch(() => {
        setTab("paste");
      });
  }, []);

  const handleConnectLocal = (targetRoomId = selectedRoom, targetName = selectedRoomName) => {
    if (!localInfo) return;
    setIsPairing(true);

    const session: PairedSession = {
      id: `local_${Date.now()}`,
      name: targetName,
      device: localInfo.deviceName,
      remoteEpk: localInfo.remoteEpk,
      token: localInfo.token,
      relayUrl: localInfo.relayUrl,
      roomId: targetRoomId,
      pairedAt: new Date().toISOString(),
      lastConnectedAt: new Date().toISOString(),
    };

    saveSession(session);
    setTimeout(() => {
      setIsPairing(false);
      onPaired(session);
    }, 400);
  };

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
      relayUrl: parsed.relayUrl || localInfo?.relayUrl || "ws://178.157.59.181:3000",
      roomId: parsed.roomId || "main",
      pairedAt: new Date().toISOString(),
      lastConnectedAt: new Date().toISOString(),
    };

    saveSession(session);
    setTimeout(() => {
      setIsPairing(false);
      onPaired(session);
    }, 400);
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
      relayUrl: relayUrl.trim() || localInfo?.relayUrl || "ws://178.157.59.181:3000",
      roomId: roomId.trim() || "main",
      pairedAt: new Date().toISOString(),
      lastConnectedAt: new Date().toISOString(),
    };

    saveSession(session);
    setTimeout(() => {
      setIsPairing(false);
      onPaired(session);
    }, 400);
  };

  return (
    <div className="relative min-h-[calc(100vh-80px)] flex flex-col items-center justify-center p-4 sm:p-6 md:p-8">
      {/* Ambient backdrop glow */}
      <div className="absolute top-1/4 left-1/2 -translate-x-1/2 -translate-y-1/2 w-[600px] h-[350px] bg-[#4fc3f7]/10 blur-[120px] pointer-events-none rounded-full" />
      <div className="absolute bottom-10 right-1/4 w-[400px] h-[250px] bg-[#5fd38a]/5 blur-[100px] pointer-events-none rounded-full" />

      <div className="w-full max-w-[640px] relative z-10">
        {/* Header Branding */}
        <div className="text-center mb-8">
          <div className="inline-flex items-center gap-2 px-3 py-1 rounded-full bg-[#4fc3f7]/10 border border-[#4fc3f7]/30 text-[#4fc3f7] text-xs font-mono mb-4 tracking-wide uppercase">
            <span className="w-2 h-2 rounded-full bg-[#4fc3f7] animate-pulse" />
            Remote Pi Web Portal
          </div>
          <h1 className="text-3xl sm:text-4xl font-bold tracking-tight text-white font-[family-name:var(--ff-display)]">
            Login & Pair Session
          </h1>
          <p className="mt-2 text-sm sm:text-base text-[#a3a3a3] max-w-[480px] mx-auto font-[family-name:var(--ff-body)]">
            Connect directly to your active Pi agent sessions over encrypted WebSockets.
          </p>
        </div>

        {/* Card Frame */}
        <div className="bg-[#0a0c10]/95 backdrop-blur-xl border border-white/10 rounded-2xl shadow-2xl overflow-hidden">
          {/* Tabs */}
          <div className="flex border-b border-white/10 bg-black/40 p-1.5 gap-1">
            {localInfo && (
              <button
                type="button"
                onClick={() => { setTab("local"); setError(null); }}
                className={`flex-1 py-2.5 px-3 text-xs sm:text-sm font-medium rounded-xl transition-all flex items-center justify-center gap-1.5 cursor-pointer ${
                  tab === "local"
                    ? "bg-[#4fc3f7]/20 text-[#4fc3f7] border border-[#4fc3f7]/40 shadow-sm"
                    : "text-[#a3a3a3] hover:text-white hover:bg-white/5"
                }`}
              >
                <span className="w-2 h-2 rounded-full bg-[#5fd38a]" />
                Local Pi Session
              </button>
            )}
            <button
              type="button"
              onClick={() => { setTab("paste"); setError(null); }}
              className={`flex-1 py-2.5 px-3 text-xs sm:text-sm font-medium rounded-xl transition-all cursor-pointer ${
                tab === "paste"
                  ? "bg-[#4fc3f7]/20 text-[#4fc3f7] border border-[#4fc3f7]/40 shadow-sm"
                  : "text-[#a3a3a3] hover:text-white hover:bg-white/5"
              }`}
            >
              Paste QR / Code
            </button>
            <button
              type="button"
              onClick={() => { setTab("manual"); setError(null); }}
              className={`flex-1 py-2.5 px-3 text-xs sm:text-sm font-medium rounded-xl transition-all cursor-pointer ${
                tab === "manual"
                  ? "bg-[#4fc3f7]/20 text-[#4fc3f7] border border-[#4fc3f7]/40 shadow-sm"
                  : "text-[#a3a3a3] hover:text-white hover:bg-white/5"
              }`}
            >
              Manual
            </button>
            {savedSessions.length > 0 && (
              <button
                type="button"
                onClick={() => { setTab("saved"); setError(null); }}
                className={`flex-1 py-2.5 px-3 text-xs sm:text-sm font-medium rounded-xl transition-all flex items-center justify-center gap-1.5 cursor-pointer ${
                  tab === "saved"
                    ? "bg-[#4fc3f7]/20 text-[#4fc3f7] border border-[#4fc3f7]/40 shadow-sm"
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

            {/* TAB: LOCAL PI DETECTED */}
            {tab === "local" && localInfo && (
              <div className="space-y-5">
                <div className="p-4 rounded-xl bg-[#4fc3f7]/10 border border-[#4fc3f7]/30 flex flex-col gap-3">
                  <div className="flex items-center justify-between">
                    <div className="flex items-center gap-2 font-mono text-sm text-white font-semibold">
                      <span className="w-2.5 h-2.5 rounded-full bg-[#5fd38a] animate-pulse" />
                      <span>{localInfo.deviceName}</span>
                    </div>
                    <span className="text-[11px] px-2 py-0.5 rounded-md bg-[#4fc3f7]/20 text-[#4fc3f7] font-mono">
                      Active Host
                    </span>
                  </div>

                  <div className="grid grid-cols-2 gap-2 text-xs font-mono text-[#a3a3a3]">
                    <div>
                      <span className="text-[#666]">Relay:</span> {localInfo.relayUrl}
                    </div>
                    <div>
                      <span className="text-[#666]">EPK:</span> {localInfo.remoteEpk.substring(0, 12)}…
                    </div>
                  </div>
                </div>

                {/* Recent Workspace Sessions */}
                {localInfo.recentSessions.length > 0 && (
                  <div>
                    <label className="block text-xs font-mono text-[#a3a3a3] uppercase tracking-wider mb-2">
                      Select Workspace / Project:
                    </label>
                    <div className="grid grid-cols-1 sm:grid-cols-2 gap-2 max-h-48 overflow-y-auto pr-1">
                      <button
                        type="button"
                        onClick={() => {
                          setSelectedRoom("main");
                          setSelectedRoomName("Remote Pi (main)");
                        }}
                        className={`p-3 rounded-xl border text-left font-mono text-xs transition-all cursor-pointer ${
                          selectedRoom === "main"
                            ? "bg-[#4fc3f7]/15 border-[#4fc3f7] text-white"
                            : "bg-white/[0.02] border-white/10 text-[#888] hover:text-white hover:bg-white/5"
                        }`}
                      >
                        <div className="font-semibold text-white">Default Session</div>
                        <div className="text-[10px] text-[#666]">main room</div>
                      </button>

                      {localInfo.recentSessions.slice(0, 5).map((s) => (
                        <button
                          key={s.roomId}
                          type="button"
                          onClick={() => {
                            setSelectedRoom(s.roomId);
                            setSelectedRoomName(s.name);
                          }}
                          className={`p-3 rounded-xl border text-left font-mono text-xs transition-all cursor-pointer ${
                            selectedRoom === s.roomId
                              ? "bg-[#4fc3f7]/15 border-[#4fc3f7] text-white"
                              : "bg-white/[0.02] border-white/10 text-[#888] hover:text-white hover:bg-white/5"
                          }`}
                        >
                          <div className="font-semibold text-white truncate">{s.name}</div>
                          <div className="text-[10px] text-[#666] truncate">{s.path}</div>
                        </button>
                      ))}
                    </div>
                  </div>
                )}

                <button
                  type="button"
                  onClick={() => handleConnectLocal()}
                  disabled={isPairing}
                  className="w-full py-3.5 px-4 bg-[#4fc3f7] hover:bg-[#38bdf8] active:scale-[0.99] text-[#04222e] font-semibold rounded-xl text-sm transition-all duration-150 flex items-center justify-center gap-2 cursor-pointer shadow-lg shadow-[#4fc3f7]/20 disabled:opacity-50"
                >
                  {isPairing ? (
                    <>
                      <div className="w-4 h-4 border-2 border-[#04222e] border-t-transparent rounded-full animate-spin" />
                      Connecting to Local Pi…
                    </>
                  ) : (
                    <>
                      <span>⚡</span>
                      <span>Connect to {selectedRoomName}</span>
                      <svg className="w-4 h-4" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.5">
                        <line x1="5" y1="12" x2="19" y2="12" />
                        <polyline points="12 5 19 12 12 19" />
                      </svg>
                    </>
                  )}
                </button>
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
                    placeholder="ws://178.157.59.181:3000"
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
                          {s.name || s.device}
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

          </div>
        </div>

        {/* Instruction Note */}
        <div className="mt-6 bg-[#0a0c10]/80 border border-white/10 rounded-xl p-4 text-xs font-mono text-[#888] flex items-center justify-between">
          <div className="flex items-center gap-2">
            <span className="text-[#5fd38a]">●</span>
            <span>Relay Configured: <code className="text-[#4fc3f7]">{localInfo?.relayUrl || "ws://178.157.59.181:3000"}</code></span>
          </div>
          <span className="text-[#555] hidden sm:inline">Encrypted WSS Handshake</span>
        </div>
      </div>
    </div>
  );
}
