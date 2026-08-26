"use client";

import { useState, useEffect } from "react";
import { SiteHeader } from "@/components/header";
import {
  PairedSession,
  getSavedSessions,
  deleteSession,
  saveSession,
  getActiveSessionId,
  setActiveSessionId,
  INITIAL_DEMO_MESSAGES,
} from "@/components/web/web-client";
import { PairScreen } from "@/components/web/pair-screen";
import { WebChat } from "@/components/web/web-chat";
import { SessionInfoModal } from "@/components/web/session-info-modal";
import { QuickActionsModal } from "@/components/web/quick-actions-modal";

export default function WebPage() {
  const [activeSession, setActiveSession] = useState<PairedSession | null>(null);
  const [savedSessions, setSavedSessions] = useState<PairedSession[]>([]);
  const [showSessionInfo, setShowSessionInfo] = useState(false);
  const [showQuickActions, setShowQuickActions] = useState(false);
  const [mounted, setMounted] = useState(false);

  useEffect(() => {
    setMounted(true);
    const sessions = getSavedSessions();
    setSavedSessions(sessions);

    const activeId = getActiveSessionId();
    if (activeId) {
      const found = sessions.find((s) => s.id === activeId);
      if (found) setActiveSession(found);
    }
  }, []);

  const handlePaired = (session: PairedSession) => {
    setActiveSession(session);
    setActiveSessionId(session.id);
    setSavedSessions(getSavedSessions());
  };

  const handleSelectSaved = (session: PairedSession) => {
    setActiveSession(session);
    setActiveSessionId(session.id);
  };

  const handleDeleteSaved = (id: string) => {
    deleteSession(id);
    setSavedSessions(getSavedSessions());
    if (activeSession?.id === id) {
      setActiveSession(null);
    }
  };

  const handleStartDemo = () => {
    const demoSession: PairedSession = {
      id: "demo_session_1",
      name: "Remote Pi (Demo)",
      device: "MacBook Pro (Demo Agent)",
      remoteEpk: "epk_demo_9824_preview_key",
      relayUrl: "wss://relay-rp1.jacobmoura.work",
      roomId: "workspace/remote-pi",
      pairedAt: new Date().toISOString(),
      lastConnectedAt: new Date().toISOString(),
    };
    saveSession(demoSession);
    setActiveSession(demoSession);
    setActiveSessionId(demoSession.id);
    setSavedSessions(getSavedSessions());
  };

  const handleDisconnect = () => {
    setActiveSession(null);
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
    <div className="min-h-screen bg-[#050608] text-white flex flex-col selection:bg-[#4fc3f7]/20 selection:text-[#4fc3f7]">
      <SiteHeader />

      <main className="flex-1 flex flex-col">
        {!activeSession ? (
          <PairScreen
            onPaired={handlePaired}
            savedSessions={savedSessions}
            onSelectSaved={handleSelectSaved}
            onDeleteSaved={handleDeleteSaved}
            onStartDemo={handleStartDemo}
          />
        ) : (
          <WebChat
            session={activeSession}
            onDisconnect={handleDisconnect}
            onOpenSessionInfo={() => setShowSessionInfo(true)}
            onOpenQuickActions={() => setShowQuickActions(true)}
          />
        )}
      </main>

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
