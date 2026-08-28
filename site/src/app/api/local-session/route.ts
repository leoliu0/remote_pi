import { NextResponse } from "next/server";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { createHash, randomBytes } from "node:crypto";
import WebSocket from "ws";
import * as ed from "@noble/ed25519";
import { sha512 } from "@noble/hashes/sha2.js";

// Wire SHA-512 into @noble/ed25519
ed.hashes.sha512 = (...messages: Uint8Array[]) => sha512(ed.etc.concatBytes(...messages));

const PEER_DEVICES: Record<string, string> = {
  "vTZygijDajc/5j3QC55NXvDI+Hcigl5tG3QZjQV0wAc=": "x3d",
  "B5qrLfEnAjdF1X3lcAzpJ/RqaknlWcEuqV5e/SZYg0Y=": "uts",
};

function getKnownPeers(): Array<{ epk: string; device: string }> {
  const homeDir = os.homedir();
  const peers: Array<{ epk: string; device: string }> = [
    { epk: "vTZygijDajc/5j3QC55NXvDI+Hcigl5tG3QZjQV0wAc=", device: "x3d" },
    { epk: "B5qrLfEnAjdF1X3lcAzpJ/RqaknlWcEuqV5e/SZYg0Y=", device: "uts" },
  ];

  try {
    const peersPath = path.join(homeDir, ".pi", "remote", "peers.json");
    if (fs.existsSync(peersPath)) {
      const raw = JSON.parse(fs.readFileSync(peersPath, "utf8"));
      if (Array.isArray(raw.peers)) {
        for (const p of raw.peers) {
          if (p.remote_epk && !peers.some((x) => x.epk === p.remote_epk)) {
            peers.push({
              epk: p.remote_epk,
              device: p.name || PEER_DEVICES[p.remote_epk] || "Remote Host",
            });
          }
        }
      }
    }
  } catch {}

  return peers;
}

interface RelayRoom {
  room_id: string;
  name?: string;
  cwd?: string;
  model?: string;
  started_at?: number;
  thinking?: string;
  working?: boolean;
}

interface MultiQueryResult {
  isRelayConnected: boolean;
  roomsByPeer: Record<string, RelayRoom[]>;
  presenceByPeer: Record<string, boolean>;
  roomsComplete: boolean;
}

async function queryRelayPeers(
  relayUrl: string,
  peers: Array<{ epk: string; device: string }>
): Promise<MultiQueryResult> {
  const { promise, resolve } = Promise.withResolvers<MultiQueryResult>();
  let settled = false;

  const wsUrl = relayUrl.replace(/^http:\/\//, "ws://").replace(/^https:\/\//, "wss://");
  const ws = new WebSocket(wsUrl);

  const clientPriv = new Uint8Array(randomBytes(32));
  const clientPub = await ed.getPublicKeyAsync(clientPriv);
  const clientPubB64 = Buffer.from(clientPub).toString("base64");

  const epkList = peers.map((p) => p.epk);
  const roomsByPeer: Record<string, RelayRoom[]> = {};
  const presenceByPeer: Record<string, boolean> = {};
  const roomsReceived = new Set<string>();

  const snapshot = (connected: boolean): MultiQueryResult => ({
    isRelayConnected: connected,
    roomsByPeer: { ...roomsByPeer },
    presenceByPeer: { ...presenceByPeer },
    roomsComplete: epkList.length === 0 || epkList.every((epk) => roomsReceived.has(epk)),
  });

  const finish = (result: MultiQueryResult) => {
    if (settled) return;
    settled = true;
    clearTimeout(timeout);
    try { ws.close(); } catch {}
    resolve(result);
  };

  const timeout = setTimeout(() => {
    finish(snapshot(roomsReceived.size > 0));
  }, 1500);

  ws.on("error", () => {
    if (roomsReceived.size > 0) {
      finish(snapshot(true));
    } else {
      finish({
        isRelayConnected: false,
        roomsByPeer: {},
        presenceByPeer: {},
        roomsComplete: false,
      });
    }
  });

  ws.on("open", () => {
    ws.send(JSON.stringify({ type: "hello", pubkey: clientPubB64 }));
  });

  ws.on("message", async (data: Buffer | string) => {
    try {
      const msg = JSON.parse(data.toString());
      if (msg.type === "challenge") {
        const nonce = new Uint8Array(Buffer.from(msg.nonce, "base64"));
        const sig = await ed.signAsync(nonce, clientPriv);
        const sigB64 = Buffer.from(sig).toString("base64");
        ws.send(JSON.stringify({ type: "auth", sig: sigB64 }));

        ws.send(JSON.stringify({ type: "subscribe_presence", peers: epkList }));
        ws.send(JSON.stringify({ type: "subscribe_rooms", peers: epkList }));
        ws.send(JSON.stringify({ type: "presence_check", peers: epkList }));
        ws.send(JSON.stringify({ type: "rooms_check", peers: epkList }));
      } else if (msg.type === "presence") {
        if (Array.isArray(msg.states)) {
          for (const s of msg.states) {
            presenceByPeer[s.peer] = !!s.online;
          }
        }
      } else if (msg.type === "rooms") {
        if (msg.peer && Array.isArray(msg.rooms)) {
          roomsByPeer[msg.peer] = msg.rooms;
          roomsReceived.add(msg.peer);
          if (epkList.length > 0 && epkList.every((epk) => roomsReceived.has(epk))) {
            finish(snapshot(true));
          }
        }
      }
    } catch {}
  });

  return promise;
}

export async function GET() {
  try {
    const relayUrl = process.env.REMOTE_PI_RELAY_URL || "ws://178.157.59.181:3000";
    const knownPeers = getKnownPeers();
    const { isRelayConnected, roomsByPeer, roomsComplete } = await queryRelayPeers(relayUrl, knownPeers);

    // Read default thinking level from local Pi settings
    let defaultThinking = "high";
    try {
      const p = path.join(os.homedir(), ".pi", "agent", "settings.json");
      if (fs.existsSync(p)) {
        const d = JSON.parse(fs.readFileSync(p, "utf8"));
        if (d.defaultThinkingLevel) defaultThinking = d.defaultThinkingLevel;
      }
    } catch {}

    const sessions: any[] = [];
    const seenRoomIds = new Set<string>();

    // 1. Live sessions from relay for all machines (x3d, uts, etc.)
    for (const p of knownPeers) {
      const rooms = roomsByPeer[p.epk] || [];
      for (const r of rooms) {
        seenRoomIds.add(r.room_id);
        const isWorking = !!r.working;
        const status: "working" | "online" | "offline" = isWorking ? "working" : "online";
        sessions.push({
          id: `${p.epk}_${r.room_id}`,
          name: r.name || (r.cwd ? path.basename(r.cwd) : r.room_id),
          device: p.device,
          remoteEpk: p.epk,
          relayUrl,
          roomId: r.room_id,
          cwd: r.cwd,
          model: r.model || "Gemini 3.7 Flash",
          thinking: r.thinking || defaultThinking,
          status,
          isLive: true,
          pairedAt: r.started_at ? new Date(r.started_at).toISOString() : new Date().toISOString(),
          lastConnectedAt: new Date().toISOString(),
        });
      }
    }

    // 2. Derive known offline project sessions
    const knownCandidates = [
      { dir: path.join(os.homedir(), "da", "Dropbox", "Shared", "AI_examiner"), device: "uts" },
      { dir: path.join(os.homedir(), "da", "Dropbox", "RF"), device: "x3d" },
      { dir: path.join(os.homedir(), "da", "Dropbox", "scripts", "projects", "remote-pi"), device: "x3d" },
      { dir: path.join(os.homedir(), "da", "Dropbox", "Apps", "Overleaf", "AI_Policy_Slides"), device: "x3d" },
      { dir: path.join(os.homedir(), "da", "Dropbox", "Apps", "Overleaf", "product_and_instown"), device: "x3d" },
      { dir: path.join(os.homedir(), "da", "Dropbox", "Chris-Leo-Corla"), device: "x3d" },
      { dir: path.join(os.homedir(), "da", "Dropbox", "2.process_innovation"), device: "x3d" },
      { dir: path.join(os.homedir(), "da", "Dropbox", "3.clean_innovation"), device: "x3d" },
    ];

    function roomIdForCwd(cwd: string): string {
      let target: string;
      try { target = fs.realpathSync(cwd); } catch { target = cwd; }
      return createHash("sha256").update(target).digest("base64url").slice(0, 12);
    }

    for (const item of knownCandidates) {
      try {
        if (fs.existsSync(item.dir)) {
          const rId = roomIdForCwd(item.dir);
          if (!seenRoomIds.has(rId)) {
            seenRoomIds.add(rId);
            const baseName = path.basename(item.dir);
            const peerInfo = knownPeers.find((x) => x.device.toLowerCase() === item.device.toLowerCase()) || knownPeers[0];
            sessions.push({
              id: `${peerInfo.epk}_${rId}`,
              name: baseName,
              device: item.device,
              remoteEpk: peerInfo.epk,
              relayUrl,
              roomId: rId,
              cwd: item.dir,
              thinking: defaultThinking,
              status: "offline",
              isLive: false,
              pairedAt: new Date().toISOString(),
              lastConnectedAt: new Date().toISOString(),
            });
          }
        }
      } catch {}
    }

    return NextResponse.json({
      localPiDetected: true,
      relayConnected: isRelayConnected,
      roomsComplete,
      device: "Remote Pi",
      remoteEpk: knownPeers[0]?.epk,
      relayUrl,
      sessions,
    });
  } catch (err: any) {
    return NextResponse.json({
      localPiDetected: false,
      relayConnected: false,
      roomsComplete: false,
      error: err?.message || "Failed to inspect local environment",
      sessions: [],
    });
  }
}
