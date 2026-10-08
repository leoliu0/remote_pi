"use client";

import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import {
  buildRoomCommand,
  loadCachedRooms,
  loadOwnerIdentity,
  loadVerifiedMesh,
  PairedSession,
  peersFromMesh,
  PeerPresence,
  saveCachedRooms,
  saveOwnerSeed,
  signOut,
  syncMesh,
  type RoomCommand,
} from "@/components/web/web-client";
import { parseSignInFragment, type OwnerIdentity } from "@/components/web/mesh";
import { RelayConnection, type RelayStatus } from "@/components/web/relay-connection";
import { isValidRelayUrl, normalizeRelayUrl, resolveRelayUrl, saveRelayUrl } from "@/components/web/relay-config";
import {
  applyControl,
  clearLiveState,
  commitWorkingOff,
  emptyRoomsState,
  isRoomLive,
  isRoomWorking,
  markRoomViewed,
  parseControlFrame,
  peerLabel,
  roomDisplayName,
  roomKey,
  WORKING_OFF_DEBOUNCE_MS,
  type HomeItem,
  type PeerRecord,
  type RoomsState,
} from "@/components/web/session-list";
import { HomeView } from "@/components/web/home-view";
import { SignInScreen } from "@/components/web/sign-in-screen";
import { WebChat } from "@/components/web/web-chat";
import { SessionInfoModal } from "@/components/web/session-info-modal";
import { QuickActionsModal } from "@/components/web/quick-actions-modal";
import { SettingsModal } from "@/components/web/settings-modal";

type View = "boot" | "signin" | "home" | "chat";

/** Same cadence as the app's MeshSyncService.startPolling. */
const MESH_POLL_MS = 60_000;

/**
 * Consumes a phone-generated sign-in link (`#k=<seed>&r=<relay>`): stores the
 * owner seed + relay and strips the fragment before anything else runs.
 * Returns an error message for a damaged link, else null.
 */
function consumeSignInFragment(): string | null {
  const link = parseSignInFragment(window.location.hash);
  if (!link) return null;
  window.history.replaceState(null, document.title, window.location.pathname + window.location.search);
  if (!link.ok) return link.error;
  // A different owner must not inherit the previous owner's cached PCs/rooms.
  const current = loadOwnerIdentity();
  if (current && !current.seed.every((b, i) => b === link.seed[i])) signOut();
  saveOwnerSeed(link.seed);
  if (link.relayUrl && isValidRelayUrl(link.relayUrl)) saveRelayUrl(normalizeRelayUrl(link.relayUrl));
  return null;
}

export default function WebPage() {
  const [view, setView] = useState<View>("boot");
  const [identity, setIdentity] = useState<OwnerIdentity | null>(null);
  const [signInError, setSignInError] = useState<string | null>(null);
  const [relayUrl, setRelayUrl] = useState<string | null>(null);
  const [relayStatus, setRelayStatus] = useState<RelayStatus>("offline");
  const [peers, setPeers] = useState<PeerRecord[]>([]);
  const [peersLoading, setPeersLoading] = useState(true);
  const [rooms, setRooms] = useState<RoomsState>(() => emptyRoomsState());
  const [activeSession, setActiveSession] = useState<PairedSession | null>(null);
  const [showSessionInfo, setShowSessionInfo] = useState(false);
  const [showQuickActions, setShowQuickActions] = useState(false);
  const [showSettings, setShowSettings] = useState(false);

  // Control frames and debounce timers need the latest state synchronously.
  const roomsRef = useRef(rooms);
  const activeKeyRef = useRef<string | null>(null);

  const updateRooms = useCallback((next: RoomsState) => {
    if (next === roomsRef.current) return;
    roomsRef.current = next;
    setRooms(next);
  }, []);

  /** Shows the last verified PC list for (owner, relay) until the relay answers. */
  const showCachedPeers = useCallback((owner: OwnerIdentity | null, relay: string) => {
    const cached = owner ? loadVerifiedMesh(owner, relay) : null;
    setPeers(peersFromMesh(cached));
    setPeersLoading(owner !== null && cached === null);
  }, []);

  // Boot: a sign-in link wins; otherwise the stored owner key goes straight
  // to Home, and a browser without one sees only the sign-in screen.
  const boot = useCallback(() => {
    const error = consumeSignInFragment();
    const owner = loadOwnerIdentity();
    const relay = resolveRelayUrl();
    roomsRef.current = emptyRoomsState(owner ? loadCachedRooms() : {});
    setRooms(roomsRef.current);
    showCachedPeers(owner, relay);
    setSignInError(error);
    setIdentity(owner);
    setRelayUrl(relay);
    setView(owner ? "home" : "signin");
  }, [showCachedPeers]);

  useEffect(() => {
    boot();
    // A sign-in link pasted into an already-open tab only changes the hash.
    const onHashChange = () => {
      if (parseSignInFragment(window.location.hash)) boot();
    };
    window.addEventListener("hashchange", onHashChange);
    return () => window.removeEventListener("hashchange", onHashChange);
  }, [boot]);

  // Paired PCs: the relay's current signed mesh blob, re-polled like the app.
  useEffect(() => {
    if (!identity || !relayUrl) return;
    let cancelled = false;
    const pull = async () => {
      const result = await syncMesh(identity, relayUrl);
      if (cancelled) return;
      if (result.kind === "updated") setPeers(peersFromMesh(result.mesh));
      else if (result.kind === "failed") console.warn("Mesh sync failed:", result.reason);
      setPeersLoading(false);
    };
    void pull();
    const poll = window.setInterval(() => void pull(), MESH_POLL_MS);
    return () => {
      cancelled = true;
      clearInterval(poll);
    };
  }, [identity, relayUrl]);

  // One relay link per (owner, relay); switching relay tears it down and
  // clears everything the old relay reported (cached rooms stay).
  const connection = useMemo(
    () => (identity && relayUrl ? new RelayConnection(relayUrl, identity) : null),
    [identity, relayUrl],
  );
  useEffect(() => {
    if (!connection) return;
    const conn = connection;
    const timers = new Set<number>();
    const offStatus = conn.onStatus(setRelayStatus);
    const offControl = conn.onControl((raw) => {
      const frame = parseControlFrame(raw);
      if (!frame) return;
      const result = applyControl(roomsRef.current, frame);
      updateRooms(result.state);
      const pending = result.scheduleWorkingOff;
      if (pending) {
        const timer = window.setTimeout(() => {
          timers.delete(timer);
          updateRooms(commitWorkingOff(roomsRef.current, pending.key, pending.token, activeKeyRef.current));
        }, WORKING_OFF_DEBOUNCE_MS);
        timers.add(timer);
      }
    });
    conn.start();
    return () => {
      offStatus();
      offControl();
      timers.forEach((t) => clearTimeout(t));
      conn.stop();
      updateRooms(clearLiveState(roomsRef.current));
      setRelayStatus("offline");
    };
  }, [connection, updateRooms]);

  useEffect(() => {
    connection?.setPeers(peers.map((p) => p.remoteEpk));
  }, [connection, peers]);

  useEffect(() => {
    if (identity) saveCachedRooms(rooms.roomsByPeer);
  }, [identity, rooms.roomsByPeer]);

  const handleRelayChange = (url: string) => {
    saveRelayUrl(url);
    showCachedPeers(identity, url);
    setRelayUrl(url);
  };

  const handleSignOut = () => {
    signOut();
    roomsRef.current = emptyRoomsState();
    setRooms(roomsRef.current);
    activeKeyRef.current = null;
    setActiveSession(null);
    setPeers([]);
    setShowSettings(false);
    setShowQuickActions(false);
    setShowSessionInfo(false);
    setIdentity(null);
    setView("signin");
  };

  const handleOpenItem = (item: HomeItem) => {
    const { peer, room } = item;
    const connected = relayStatus === "online";
    const working = isRoomWorking(rooms, connected, peer.remoteEpk, room.roomId);
    const live = isRoomLive(rooms, connected, peer.remoteEpk, room.roomId);
    activeKeyRef.current = roomKey(peer.remoteEpk, room.roomId);
    updateRooms(markRoomViewed(roomsRef.current, peer.remoteEpk, room.roomId));
    setActiveSession({
      id: `${peer.remoteEpk}_${room.roomId}`,
      name: roomDisplayName(peer, room),
      device: peerLabel(peer),
      remoteEpk: peer.remoteEpk,
      relayUrl: relayUrl ?? "",
      roomId: room.roomId,
      cwd: room.cwd ?? undefined,
      model: room.model ?? undefined,
      thinking: room.thinking ?? undefined,
      pairedAt: peer.pairedAt,
      status: working ? "working" : live ? "online" : "offline",
      isLive: live || working,
    });
    setView("chat");
  };

  const handleCloseChat = () => {
    if (activeSession) updateRooms(markRoomViewed(roomsRef.current, activeSession.remoteEpk, activeSession.roomId));
    activeKeyRef.current = null;
    setActiveSession(null);
    setView("home");
  };

  const handleQuickAction = (action: string, payload?: string) => {
    if (!activeSession || !connection) return;
    const send = (cmd: RoomCommand) =>
      connection.sendInner(activeSession.remoteEpk, activeSession.roomId, buildRoomCommand(cmd));
    if (action === "set_model" && payload) {
      send({ action: "set_model", model: payload });
    } else if (action === "set_thinking" && payload) {
      send({ action: "set_thinking", thinking: payload });
    } else if (action === "compact") {
      send({ action: "compact" });
    } else if (action === "new_session") {
      send({ action: "new_session" });
    } else if (action === "set_tool_display" && payload) {
      try {
        localStorage.setItem("remotepi_tool_display", payload);
        window.dispatchEvent(new Event("tool_display_changed"));
      } catch {}
    }
  };

  if (view === "boot" || !relayUrl) {
    return (
      <div className="min-h-screen bg-black text-white flex items-center justify-center font-mono text-sm">
        <div className="flex items-center gap-2 text-[#4fc3f7]">
          <div className="w-4 h-4 border-2 border-[#4fc3f7] border-t-transparent rounded-full animate-spin" />
          Loading Remote Pi Web…
        </div>
      </div>
    );
  }

  if (view === "signin" || !identity) {
    return <SignInScreen relayUrl={relayUrl} onRelayChange={handleRelayChange} error={signInError} />;
  }

  const connected = relayStatus === "online";
  // Model/thinking come from the relay's room meta (same source as Home).
  const activeRoom = activeSession
    ? rooms.roomsByPeer[activeSession.remoteEpk]?.find((r) => r.roomId === activeSession.roomId)
    : undefined;
  let roomPresence: PeerPresence = "unknown";
  if (activeSession) {
    roomPresence = isRoomWorking(rooms, connected, activeSession.remoteEpk, activeSession.roomId)
      ? "working"
      : isRoomLive(rooms, connected, activeSession.remoteEpk, activeSession.roomId)
        ? "online"
        : connected
          ? "offline"
          : "reconnecting";
  }

  return (
    <div className="flex-1 flex flex-col selection:bg-[#4fc3f7]/20 selection:text-[#4fc3f7]">
      <div className="flex-1 flex flex-col">
        {view === "home" && (
          <HomeView
            peers={peers}
            peersLoading={peersLoading}
            rooms={rooms}
            relayUrl={relayUrl}
            relayStatus={relayStatus}
            onRelayChange={handleRelayChange}
            onOpenItem={handleOpenItem}
            onOpenSettings={() => setShowSettings(true)}
          />
        )}

        {view === "chat" && activeSession && connection && (
          <WebChat
            key={activeSession.id}
            session={activeSession}
            connection={connection}
            roomPresence={roomPresence}
            onDisconnect={handleCloseChat}
            onOpenSessionInfo={() => setShowSessionInfo(true)}
            onOpenQuickActions={() => setShowQuickActions(true)}
            onOpenSettings={() => setShowSettings(true)}
          />
        )}
      </div>

      {showSessionInfo && activeSession && (
        <SessionInfoModal session={activeSession} onClose={() => setShowSessionInfo(false)} />
      )}

      {showQuickActions && (
        <QuickActionsModal
          activeModel={activeRoom?.model ?? activeSession?.model}
          activeThinking={activeRoom?.thinking ?? activeSession?.thinking}
          onClose={() => setShowQuickActions(false)}
          onAction={handleQuickAction}
        />
      )}

      {showSettings && (
        <SettingsModal
          onClose={() => setShowSettings(false)}
          relayUrl={relayUrl}
          relayStatus={relayStatus}
          onRelayChange={handleRelayChange}
          peers={peers}
          ownerPublicKey={identity.publicKey}
          onSignOut={handleSignOut}
        />
      )}
    </div>
  );
}
