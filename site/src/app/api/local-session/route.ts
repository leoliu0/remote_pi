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
function getLocalEpk(): { publicKey: string; privateKey: string; keypairFound: boolean } {
  const homeDir = os.homedir();
  const candidates = [
    path.join(homeDir, ".pi", "remote", "identity.json"),
    path.join(homeDir, ".config", "remote-pi", "identity.json"),
    path.join(homeDir, ".pi", "remote", "config.json"),
    path.join(homeDir, ".config", "remote-pi", "config.json"),
  ];

  for (const p of candidates) {
    try {
      if (fs.existsSync(p)) {
        const raw = JSON.parse(fs.readFileSync(p, "utf8"));
        const pub = raw?.publicKey || raw?.public_key;
        const priv = raw?.privateKey || raw?.private_key;
        if (pub && priv) {
          return {
            publicKey: pub,
            privateKey: priv,
            keypairFound: true,
          };
        }
      }
    } catch {}
  }
  return { publicKey: "", privateKey: "", keypairFound: false };
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

interface QueryResult {
  isRelayConnected: boolean;
  rooms: RelayRoom[];
  peerOnline: boolean;
}

async function queryRelay(
  relayUrl: string,
  targetEpk: string,
  keyInfo: { publicKey: string; privateKey: string }
): Promise<QueryResult> {
  const { promise, resolve } = Promise.withResolvers<QueryResult>();

  const wsUrl = relayUrl.replace(/^http:\/\//, "ws://").replace(/^https:\/\//, "wss://");
  const ws = new WebSocket(wsUrl);

  const clientPriv = new Uint8Array(randomBytes(32));
  const clientPub = await ed.getPublicKeyAsync(clientPriv);
  const clientPubB64 = Buffer.from(clientPub).toString("base64");

  const timeout = setTimeout(() => {
    try { ws.close(); } catch {}
    resolve({ isRelayConnected: false, rooms: [], peerOnline: false });
  }, 3000);

  let peerOnline = false;
  let rooms: RelayRoom[] = [];

  ws.on("error", () => {
    clearTimeout(timeout);
    resolve({ isRelayConnected: false, rooms: [], peerOnline: false });
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

        // Subscribe & query rooms & presence immediately
        ws.send(JSON.stringify({ type: "subscribe_presence", peers: [targetEpk] }));
        ws.send(JSON.stringify({ type: "subscribe_rooms", peers: [targetEpk] }));
        ws.send(JSON.stringify({ type: "presence_check", peers: [targetEpk] }));
        ws.send(JSON.stringify({ type: "rooms_check", peers: [targetEpk] }));
      } else if (msg.type === "presence") {
        if (Array.isArray(msg.states)) {
          const st = msg.states.find((s: any) => s.peer === targetEpk);
          if (st && st.online) peerOnline = true;
        }
      } else if (msg.type === "rooms") {
        if (Array.isArray(msg.rooms)) {
          rooms = msg.rooms;
        }
        clearTimeout(timeout);
        try { ws.close(); } catch {}
        resolve({ isRelayConnected: true, rooms, peerOnline });
      }
    } catch {}
  });

  return promise;
}

export async function GET() {
  try {
    const keyInfo = getLocalEpk();
    const relayUrl = process.env.REMOTE_PI_RELAY_URL || "ws://178.157.59.181:3000";
    const hostName = os.hostname() || "Remote Pi";

    if (!keyInfo.keypairFound || !keyInfo.publicKey) {
      return NextResponse.json({
        localPiDetected: false,
        relayConnected: false,
        device: hostName,
        sessions: [],
      });
    }

    const { isRelayConnected, rooms } = await queryRelay(relayUrl, keyInfo.publicKey, {
      publicKey: keyInfo.publicKey,
      privateKey: keyInfo.privateKey,
    });

    // 1. Live sessions from relay
    const liveRoomIds = new Set(rooms.map((r) => r.room_id));
    const sessions: any[] = rooms.map((r) => {
      const isWorking = !!r.working;
      const status: "working" | "online" | "offline" = isWorking ? "working" : "online";
      return {
        id: `${keyInfo.publicKey}_${r.room_id}`,
        name: r.name || (r.cwd ? path.basename(r.cwd) : r.room_id),
        device: hostName,
        remoteEpk: keyInfo.publicKey,
        relayUrl,
        roomId: r.room_id,
        cwd: r.cwd,
        model: r.model || "Gemini 3.7 Flash",
        status,
        isLive: true,
        pairedAt: r.started_at ? new Date(r.started_at).toISOString() : new Date().toISOString(),
        lastConnectedAt: new Date().toISOString(),
      };
    });

    // 2. Derive known offline project sessions (e.g. AI_examiner, etc.)
    const knownCandidates = [
      path.join(os.homedir(), "da", "Dropbox", "Shared", "AI_examiner"),
      path.join(os.homedir(), "da", "Dropbox", "Apps", "Overleaf", "AI_examiner"),
      path.join(os.homedir(), "da", "Dropbox", "RF"),
      path.join(os.homedir(), "da", "Dropbox", "scripts", "projects", "remote-pi"),
      path.join(os.homedir(), "da", "Dropbox", "Apps", "Overleaf", "AI_Policy_Slides"),
      path.join(os.homedir(), "da", "Dropbox", "Apps", "Overleaf", "product_and_instown"),
      path.join(os.homedir(), "da", "Dropbox", "Chris-Leo-Corla"),
      path.join(os.homedir(), "da", "Dropbox", "2.process_innovation"),
      path.join(os.homedir(), "da", "Dropbox", "3.clean_innovation"),
    ];

    function roomIdForCwd(cwd: string): string {
      let target: string;
      try { target = fs.realpathSync(cwd); } catch { target = cwd; }
      return createHash("sha256").update(target).digest("base64url").slice(0, 12);
    }

    const seenRooms = new Set(liveRoomIds);
    for (const dir of knownCandidates) {
      try {
        if (fs.existsSync(dir)) {
          const rId = roomIdForCwd(dir);
          if (!seenRooms.has(rId)) {
            seenRooms.add(rId);
            const baseName = path.basename(dir);
            sessions.push({
              id: `${keyInfo.publicKey}_${rId}`,
              name: baseName,
              device: hostName,
              remoteEpk: keyInfo.publicKey,
              relayUrl,
              roomId: rId,
              cwd: dir,
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
      device: hostName,
      remoteEpk: keyInfo.publicKey,
      relayUrl,
      sessions,
    });
  } catch (err: any) {
    return NextResponse.json({
      localPiDetected: false,
      relayConnected: false,
      error: err?.message || "Failed to inspect local environment",
      sessions: [],
    });
  }
}
