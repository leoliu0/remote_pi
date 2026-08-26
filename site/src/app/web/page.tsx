"use client";

import { useState, useEffect } from "react";
import {
  PairedSession,
  parsePairUri,
  getSavedSessions,
  deleteSession,
  saveSession,
  setActiveSessionId,
} from "@/components/web/web-client";
import { HomeView } from "@/components/web/home-view";
import { PairScreen } from "@/components/web/pair-screen";
import { WebChat } from "@/components/web/web-chat";
import { SessionInfoModal } from "@/components/web/session-info-modal";
import { QuickActionsModal } from "@/components/web/quick-actions-modal";
import { SettingsModal } from "@/components/web/settings-modal";
export default function WebPage() {
  const [view, setView] = useState<"home" | "chat" | "pair">("home");
  const [activeSession, setActiveSession] = useState<PairedSession | null>(null);
  const [savedSessions, setSavedSessions] = useState<PairedSession[]>([]);
  const [isRelayConnected, setIsRelayConnected] = useState(true);
  const [deviceName, setDeviceName] = useState("Remote Pi");
  const [showSessionInfo, setShowSessionInfo] = useState(false);
  const [showQuickActions, setShowQuickActions] = useState(false);
  const [showSettings, setShowSettings] = useState(false);
  const [mounted, setMounted] = useState(false);

  // Helper to refresh session list
  const refreshSessions = () => {
    const stored = getSavedSessions();
    fetch("/api/local-session")
      .then((res) => res.json())
      .then((data) => {
        if (data && data.localPiDetected && Array.isArray(data.sessions)) {
          if (typeof data.relayConnected === "boolean") {
            setIsRelayConnected(data.relayConnected);
          }
          if (data.device) {
            setDeviceName(data.device);
          }
          const remoteSessions: PairedSession[] = data.sessions.map((s: any) => ({
            id: s.id || `session_${s.roomId}`,
            name: s.name,
            device: s.device || data.device || "Remote Pi",
            remoteEpk: s.remoteEpk || data.remoteEpk,
            token: s.token,
            relayUrl: s.relayUrl || data.relayUrl,
            roomId: s.roomId,
            cwd: s.cwd,
            model: s.model,
            status: s.status,
            isLive: s.isLive,
            pairedAt: s.pairedAt || new Date().toISOString(),
            lastConnectedAt: new Date().toISOString(),
          }));

          // Merge: Live active sessions from relay are authoritative (keyed by roomId)
          const map = new Map<string, PairedSession>();
          for (const s of remoteSessions) {
            map.set(s.roomId, s);
          }
          for (const s of stored) {
            if (!map.has(s.roomId)) {
              map.set(s.roomId, s);
            }
          }
          const sortSessions = (list: PairedSession[]) =>
            [...list].sort((a, b) => {
              const rank = (s: PairedSession) =>
                s.status === "working" ? 0 : s.isLive || s.status === "online" ? 1 : 2;
              const rankDiff = rank(a) - rank(b);
              if (rankDiff !== 0) return rankDiff;
              const nameA = (a.name || a.roomId || "").toLowerCase();
              const nameB = (b.name || b.roomId || "").toLowerCase();
              if (nameA !== nameB) return nameA.localeCompare(nameB);
              return (a.roomId || "").localeCompare(b.roomId || "");
            });

          const next = sortSessions(Array.from(map.values()));
          setSavedSessions((prev) => {
            if (prev.length === next.length) {
              let same = true;
              for (let i = 0; i < prev.length; i++) {
                if (
                  prev[i].id !== next[i].id ||
                  prev[i].status !== next[i].status ||
                  prev[i].model !== next[i].model ||
                  prev[i].isLive !== next[i].isLive
                ) {
                  same = false;
                  break;
                }
              }
              if (same) return prev;
            }
            return next;
          });
        } else {
          setSavedSessions(stored);
        }
      })
      .catch(() => {
        setSavedSessions(stored);
      });
  };

  useEffect(() => {
    setMounted(true);
    refreshSessions();

    // 1. Live SSE Presence & Room Broadcast Stream (Zero Latency)
    let sse: EventSource | null = null;
    try {
      sse = new EventSource("/api/relay-bridge?sessionId=home_realtime_presence");

      sse.onmessage = (e) => {
        try {
          const event = JSON.parse(e.data);

          // Real-time turn start / turn end (working: true/false)
          if (event.type === "room_meta_updated" && event.roomId) {
            setSavedSessions((prev) => {
              let changed = false;
              const next = prev.map((s) => {
                if (s.roomId === event.roomId) {
                  const isWorking = !!event.meta?.working;
                  const newStatus: "working" | "online" = isWorking ? "working" : "online";
                  const newModel = event.meta?.model || s.model;
                  if (s.status !== newStatus || s.model !== newModel) {
                    changed = true;
                    return {
                      ...s,
                      status: newStatus,
                      model: newModel,
                      isLive: true,
                    };
                  }
                }
                return s;
              });
              return changed ? next : prev;
            });
          } else if (event.type === "room_announced" || event.type === "rooms") {
            refreshSessions();
          } else if (event.type === "room_ended" && event.roomId) {
            setSavedSessions((prev) =>
              prev.map((s) => {
                if (s.roomId === event.roomId) {
                  return { ...s, status: "offline", isLive: false };
                }
                return s;
              })
            );
          } else if (event.type === "presence") {
            setIsRelayConnected(event.presence === "online");
          }
        } catch {}
      };
    } catch {}

    // 2. Periodic sync backstop (every 2.5s)
    const interval = setInterval(refreshSessions, 2500);

    // 3. Check if pairing parameters are provided in URL query
    if (typeof window !== "undefined" && window.location.search) {
      const search = window.location.search;
      const params = new URLSearchParams(search);
      const pairParam = params.get("pair") || search;
      const parsed = parsePairUri(pairParam);
      if (parsed && parsed.remoteEpk) {
        const session: PairedSession = {
          id: `session_${Date.now()}`,
          name: parsed.name || "Remote Pi",
          device: parsed.device || "Remote Host",
          remoteEpk: parsed.remoteEpk,
          token: parsed.token,
          relayUrl: parsed.relayUrl || "ws://178.157.59.181:3000",
          roomId: parsed.roomId || "main",
          pairedAt: new Date().toISOString(),
          lastConnectedAt: new Date().toISOString(),
        };
        saveSession(session);
        setActiveSession(session);
        setActiveSessionId(session.id);
        setView("chat");
        window.history.replaceState({}, document.title, window.location.pathname);
      }
    }

    return () => {
      clearInterval(interval);
      if (sse) sse.close();
    };
  }, []);

  const handleOpenSession = (session: PairedSession) => {
    setActiveSession(session);
    setActiveSessionId(session.id);
    setView("chat");
  };

  const handlePaired = (session: PairedSession) => {
    setActiveSession(session);
    setActiveSessionId(session.id);
    setSavedSessions(getSavedSessions());
    setView("chat");
  };

  const handleDeleteSession = (id: string) => {
    deleteSession(id);
    setSavedSessions((prev) => prev.filter((s) => s.id !== id));
    if (activeSession?.id === id) {
      setActiveSession(null);
      setView("home");
    }
  };


  const handleDisconnect = () => {
    setActiveSession(null);
    setView("home");
  };

  const handleQuickAction = async (action: string, payload?: string) => {
    if (!activeSession) return;
    try {
      if (action === "set_model" && payload) {
        setActiveSession({ ...activeSession, model: payload });
        await fetch("/api/relay-bridge", {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({
            sessionId: activeSession.id,
            roomId: activeSession.roomId,
            remoteEpk: activeSession.remoteEpk,
            relayUrl: activeSession.relayUrl,
            action: "set_model",
            model: payload,
          }),
        });
      } else if (action === "set_thinking" && payload) {
        setActiveSession({ ...activeSession, thinking: payload });
        await fetch("/api/relay-bridge", {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({
            sessionId: activeSession.id,
            roomId: activeSession.roomId,
            remoteEpk: activeSession.remoteEpk,
            relayUrl: activeSession.relayUrl,
            action: "set_thinking",
            thinking: payload,
          }),
        });
      } else if (action === "compact") {
        await fetch("/api/relay-bridge", {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({
            sessionId: activeSession.id,
            roomId: activeSession.roomId,
            remoteEpk: activeSession.remoteEpk,
            relayUrl: activeSession.relayUrl,
            action: "compact",
          }),
        });
      } else if (action === "new_session") {
        await fetch("/api/relay-bridge", {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({
            sessionId: activeSession.id,
            roomId: activeSession.roomId,
            remoteEpk: activeSession.remoteEpk,
            relayUrl: activeSession.relayUrl,
            action: "new_session",
          }),
        });
      } else if (action === "set_tool_display" && payload) {
        try {
          localStorage.setItem("remotepi_tool_display", payload);
          window.dispatchEvent(new Event("tool_display_changed"));
        } catch {}
      }
    } catch (err) {
      console.warn("Failed to dispatch quick action", err);
    }
  };

  if (!mounted) {
    return (
      <div className="min-h-screen bg-black text-white flex items-center justify-center font-mono text-sm">
        <div className="flex items-center gap-2 text-[#4fc3f7]">
          <div className="w-4 h-4 border-2 border-[#4fc3f7] border-t-transparent rounded-full animate-spin" />
          Loading Remote Pi Web…
        </div>
      </div>
    );
  }

  return (
    <div className="flex-1 flex flex-col selection:bg-[#4fc3f7]/20 selection:text-[#4fc3f7]">
      <div className="flex-1 flex flex-col">
        {view === "home" && (
          <HomeView
            sessions={savedSessions}
            isRelayConnected={isRelayConnected}
            deviceName={deviceName}
            onOpenSession={handleOpenSession}
            onOpenPairModal={() => setView("pair")}
            onOpenSettings={() => setShowSettings(true)}
            onDeleteSession={handleDeleteSession}
          />
        )}

        {view === "pair" && (
          <PairScreen
            onPaired={handlePaired}
            savedSessions={savedSessions}
            onSelectSaved={handleOpenSession}
            onDeleteSaved={handleDeleteSession}
          />
        )}

        {view === "chat" && activeSession && (
          <WebChat
            key={activeSession.id}
            session={activeSession}
            onDisconnect={handleDisconnect}
            onOpenSessionInfo={() => setShowSessionInfo(true)}
            onOpenQuickActions={() => setShowQuickActions(true)}
            onOpenSettings={() => setShowSettings(true)}
          />
        )}
      </div>

      {/* Modals */}
      {showSessionInfo && activeSession && (
        <SessionInfoModal
          session={activeSession}
          onClose={() => setShowSessionInfo(false)}
        />
      )}

      {showQuickActions && (
        <QuickActionsModal
          activeModel={activeSession?.model}
          activeThinking={activeSession?.thinking}
          onClose={() => setShowQuickActions(false)}
          onAction={handleQuickAction}
        />
      )}
      {showSettings && (
        <SettingsModal
          onClose={() => setShowSettings(false)}
          onOpenPair={() => {
            setShowSettings(false);
            setView("pair");
          }}
        />
      )}
    </div>
  );
}
