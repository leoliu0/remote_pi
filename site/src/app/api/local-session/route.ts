import { NextResponse } from "next/server";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { createHash, randomBytes } from "node:crypto";
import WebSocket from "ws";
import * as ed from "@noble/ed25519";
import { sha512 } from "@noble/hashes/sha2.js";

ed.hashes.sha512 = (...messages: Uint8Array[]) => sha512(ed.etc.concatBytes(...messages));

interface LiveRoomInfo {
  room_id: string;
  name: string;
  cwd?: string;
  model?: string;
  thinking?: string;
  working: boolean;
}

async function queryLiveRelayRooms(relayUrl: string, targetEpk: string): Promise<LiveRoomInfo[]> {
  return new Promise((resolve) => {
    try {
      const privKey = ed.utils.randomSecretKey();
      const pubKey = ed.getPublicKey(privKey);
      const pubKeyB64 = Buffer.from(pubKey).toString("base64");

      const ws = new WebSocket(relayUrl);
      const timeout = setTimeout(() => {
        try { ws.close(); } catch {}
        resolve([]);
      }, 2000);

      ws.on("open", () => {
        ws.send(JSON.stringify({ type: "hello", pubkey: pubKeyB64 }));
      });

      ws.on("message", (data: WebSocket.Data) => {
        try {
          const frame = JSON.parse(data.toString());
          if (frame.type === "challenge" && frame.nonce) {
            const nonce = Buffer.from(frame.nonce, "base64");
            const sig = ed.sign(nonce, privKey);
            ws.send(JSON.stringify({ type: "auth", sig: Buffer.from(sig).toString("base64") }));
            setTimeout(() => {
              ws.send(JSON.stringify({ type: "rooms_check", peers: [targetEpk] }));
            }, 50);
          } else if (frame.type === "rooms" && Array.isArray(frame.rooms)) {
            clearTimeout(timeout);
            try { ws.close(); } catch {}
            resolve(frame.rooms);
          }
        } catch {
          clearTimeout(timeout);
          try { ws.close(); } catch {}
          resolve([]);
        }
      });

      ws.on("error", () => {
        clearTimeout(timeout);
        resolve([]);
      });
    } catch {
      resolve([]);
    }
  });
}

export async function GET() {
  try {
    const homeDir = os.homedir();
    const remoteDir = path.join(homeDir, ".pi", "remote");
    const configPath = path.join(remoteDir, "config.json");
    const peersPath = path.join(remoteDir, "peers.json");
    const agentSessionsDir = path.join(homeDir, ".pi", "agent", "sessions");

    // 1. Relay configuration
    let relayUrl = "ws://178.157.59.181:3000";
    if (fs.existsSync(configPath)) {
      try {
        const cfg = JSON.parse(fs.readFileSync(configPath, "utf8"));
        if (cfg.relay) {
          let r = cfg.relay as string;
          if (r.startsWith("http://")) r = r.replace("http://", "ws://");
          if (r.startsWith("https://")) r = r.replace("https://", "wss://");
          relayUrl = r;
        }
      } catch (err) {
        console.warn("Failed to parse config.json", err);
      }
    }

    // 2. Identity
    let remoteEpk = "vTZygijDajc/5j3QC55NXvDI+Hcigl5tG3QZjQV0wAc=";
    const identityPath = path.join(remoteDir, "identity.json");
    if (fs.existsSync(identityPath)) {
      try {
        const idJson = JSON.parse(fs.readFileSync(identityPath, "utf8"));
        if (idJson.publicKey) remoteEpk = idJson.publicKey;
      } catch {}
    }

    // 3. Query Real Live Rooms from Relay
    const liveRooms = await queryLiveRelayRooms(relayUrl, remoteEpk);
    const liveRoomIds = new Set(liveRooms.map((r) => r.room_id));

    // 4. Read registered peers
    let peersCount = 0;
    if (fs.existsSync(peersPath)) {
      try {
        const peersJson = JSON.parse(fs.readFileSync(peersPath, "utf8"));
        if (Array.isArray(peersJson.peers)) {
          peersCount = peersJson.peers.length;
        }
      } catch {}
    }

    // 5. Build session list: Live active rooms FIRST, then offline historical projects
    const sessions: Array<{
      name: string;
      path: string;
      roomId: string;
      model?: string;
      isLive: boolean;
      isWorking: boolean;
      status: "online" | "working" | "offline";
    }> = [];

    for (const lr of liveRooms) {
      sessions.push({
        name: lr.name || "Remote Pi",
        path: lr.cwd || lr.name,
        roomId: lr.room_id,
        model: lr.model || "Gemini 3.7 Flash",
        isLive: true,
        isWorking: lr.working || false,
        status: lr.working ? "working" : "online",
      });
    }

    // Add historical sessions as offline if not currently live
    if (fs.existsSync(agentSessionsDir)) {
      try {
        const dirs = fs.readdirSync(agentSessionsDir);
        for (const d of dirs.slice(0, 10)) {
          if (d.startsWith("--") && d.endsWith("--")) {
            const rawPath = d.slice(2, -2).replace(/-/g, "/");
            const name = path.basename(rawPath) || rawPath;
            const hash = createHash("sha256").update(rawPath).digest("base64url").slice(0, 12);
            if (!liveRoomIds.has(hash)) {
              sessions.push({
                name,
                path: rawPath,
                roomId: hash,
                model: undefined,
                isLive: false,
                isWorking: false,
                status: "offline",
              });
            }
          }
        }
      } catch {}
    }

    const token = randomBytes(16).toString("base64url");
    const deviceName = `${os.hostname()} (${os.type()})`;

    return NextResponse.json({
      localPiDetected: true,
      deviceName,
      relayUrl,
      remoteEpk,
      token,
      liveRoomsCount: liveRooms.length,
      peersCount,
      sessions,
    });
  } catch (err: any) {
    return NextResponse.json({
      localPiDetected: false,
      error: err?.message || "Failed to inspect local environment",
    });
  }
}
