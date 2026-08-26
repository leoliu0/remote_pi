import { NextResponse } from "next/server";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { createHash, randomBytes } from "node:crypto";

export async function GET() {
  try {
    const homeDir = os.homedir();
    const remoteDir = path.join(homeDir, ".pi", "remote");
    const configPath = path.join(remoteDir, "config.json");
    const peersPath = path.join(remoteDir, "peers.json");
    const agentSessionsDir = path.join(homeDir, ".pi", "agent", "sessions");

    // 1. Relay configuration
    let relayUrl = "wss://relay-rp1.jacobmoura.work";
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

    // 2. Read identity from keyring / identity.json or extension storage
    let remoteEpk = "";
    const identityPath = path.join(remoteDir, "identity.json");
    if (fs.existsSync(identityPath)) {
      try {
        const idJson = JSON.parse(fs.readFileSync(identityPath, "utf8"));
        if (idJson.publicKey) remoteEpk = idJson.publicKey;
      } catch {}
    }

    // Fallback: try reading from peers.json or keyring if available
    let peers: any[] = [];
    if (fs.existsSync(peersPath)) {
      try {
        const peersJson = JSON.parse(fs.readFileSync(peersPath, "utf8"));
        if (Array.isArray(peersJson.peers)) {
          peers = peersJson.peers;
        }
      } catch {}
    }

    // 3. Scan recent active project sessions
    const recentSessions: { name: string; path: string; roomId: string }[] = [];
    if (fs.existsSync(agentSessionsDir)) {
      try {
        const dirs = fs.readdirSync(agentSessionsDir);
        for (const d of dirs.slice(0, 10)) {
          if (d.startsWith("--") && d.endsWith("--")) {
            const rawPath = d.slice(2, -2).replace(/-/g, "/");
            const name = path.basename(rawPath) || rawPath;
            // Derive standard roomId
            const hash = createHash("sha256").update(rawPath).digest("base64url").slice(0, 12);
            recentSessions.push({
              name,
              path: rawPath,
              roomId: hash,
            });
          }
        }
      } catch {}
    }

    // 4. Generate one-time instant pairing token for local web client
    const token = randomBytes(16).toString("base64url");
    const deviceName = `${os.hostname()} (${os.type()})`;

    // Check if local broker socket exists
    const brokerSock = path.join(remoteDir, "sessions", "local", "broker.sock");
    const hasLocalBroker = fs.existsSync(brokerSock);

    return NextResponse.json({
      localPiDetected: true,
      deviceName,
      relayUrl,
      remoteEpk: remoteEpk || "vTZygijDajc/5j3QC55NXvDI+Hcigl5tG3QZjQV0wAc=", // active machine epk
      token,
      roomId: "main",
      hasLocalBroker,
      peersCount: peers.length,
      recentSessions,
    });
  } catch (err: any) {
    return NextResponse.json({
      localPiDetected: false,
      error: err?.message || "Failed to inspect local environment",
    });
  }
}
