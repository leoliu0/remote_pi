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

export default function WebPage() {
  const [view, setView] = useState<"home" | "chat" | "pair">("home");
  const [activeSession, setActiveSession] = useState<PairedSession | null>(null);
  const [savedSessions, setSavedSessions] = useState<PairedSession[]>([]);
  const [showSessionInfo, setShowSessionInfo] = useState(false);
  const [showQuickActions, setShowQuickActions] = useState(false);
  const [mounted, setMounted] = useState(false);

  useEffect(() => {
    setMounted(true);
    let stored = getSavedSessions();

    // 1. Auto-discover local Pi host sessions & query live status from relay
    fetch("/api/local-session")
      .then((res) => res.json())
      .then((data) => {
        if (data && data.localPiDetected && Array.isArray(data.sessions)) {
          const remoteSessions: PairedSession[] = data.sessions.map((s: any) => ({
            id: `session_${s.roomId}`,
            name: s.name,
            device: data.deviceName,
            remoteEpk: data.remoteEpk,
            token: data.token,
            relayUrl: data.relayUrl,
            roomId: s.roomId,
            cwd: s.path,
            model: s.model,
            status: s.status,
            isLive: s.isLive,
            pairedAt: new Date().toISOString(),
            lastConnectedAt: new Date().toISOString(),
          }));

          // Merge: Live active sessions at top, then saved custom sessions
          const map = new Map<string, PairedSession>();
          for (const s of remoteSessions) {
            map.set(s.id, s);
          }
          for (const s of stored) {
            if (!map.has(s.id)) {
              map.set(s.id, s);
            }
          }

          const combined = Array.from(map.values());
          setSavedSessions(combined);
        } else {
          setSavedSessions(stored);
        }
      })
      .catch(() => {
        setSavedSessions(stored);
      });

    // 2. Check if pairing parameters are provided in URL query
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

  const handleStartDemo = () => {
    const demoSession: PairedSession = {
      id: "demo_session_1",
      name: "Remote Pi (Demo Sandbox)",
      device: "MacBook Pro (Simulated Agent)",
      remoteEpk: "epk_demo_9824_preview_key",
      relayUrl: "ws://178.157.59.181:3000",
      roomId: "workspace/remote-pi",
      status: "online",
      isLive: true,
      pairedAt: new Date().toISOString(),
      lastConnectedAt: new Date().toISOString(),
    };
    saveSession(demoSession);
    setActiveSession(demoSession);
    setActiveSessionId(demoSession.id);
    setSavedSessions(getSavedSessions());
    setView("chat");
  };

  const handleDisconnect = () => {
    setActiveSession(null);
    setView("home");
  };

  const handleQuickAction = (action: string, payload?: string) => {
    if (action === "compact") {
      alert("Session context compaction requested.");
    } else if (action === "new_session") {
      alert("Started new clean session.");
    } else if (action === "set_model") {
      if (activeSession) {
        setActiveSession({ ...activeSession, model: payload });
      }
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
            onOpenSession={handleOpenSession}
            onOpenPairModal={() => setView("pair")}
            onDeleteSession={handleDeleteSession}
            onStartDemo={handleStartDemo}
          />
        )}

        {view === "pair" && (
          <PairScreen
            onPaired={handlePaired}
            savedSessions={savedSessions}
            onSelectSaved={handleOpenSession}
            onDeleteSaved={handleDeleteSession}
            onStartDemo={handleStartDemo}
          />
        )}

        {view === "chat" && activeSession && (
          <WebChat
            session={activeSession}
            onDisconnect={handleDisconnect}
            onOpenSessionInfo={() => setShowSessionInfo(true)}
            onOpenQuickActions={() => setShowQuickActions(true)}
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
          onClose={() => setShowQuickActions(false)}
          onAction={handleQuickAction}
        />
      )}
    </div>
  );
}
