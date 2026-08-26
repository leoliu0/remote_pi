import { NextRequest, NextResponse } from "next/server";
import WebSocket from "ws";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { createHash } from "node:crypto";
import * as ed from "@noble/ed25519";
import { sha512 } from "@noble/hashes/sha2.js";

ed.hashes.sha512 = (...messages: Uint8Array[]) => sha512(ed.etc.concatBytes(...messages));

// In-memory relay connection state for active web clients
interface RelayState {
  ws: WebSocket | null;
  connected: boolean;
  authenticated: boolean;
  presence: "online" | "working" | "offline";
  messages: Array<Record<string, unknown>>;
  listeners: Array<(event: Record<string, unknown>) => void>;
  privKey: Uint8Array | null;
  pubKeyB64: string | null;
  relayUrl: string;
  targetEpk: string;
  roomId: string;
}

const activeRelays = new Map<string, RelayState>();

function getLocalConfig(): { relayUrl: string; targetEpk: string } {
  let relayUrl = "ws://178.157.59.181:3000";
  let targetEpk = "vTZygijDajc/5j3QC55NXvDI+Hcigl5tG3QZjQV0wAc=";

  try {
    const configPath = path.join(os.homedir(), ".pi", "remote", "config.json");
    if (fs.existsSync(configPath)) {
      const cfg = JSON.parse(fs.readFileSync(configPath, "utf8"));
      if (cfg.relay) {
        let r = cfg.relay as string;
        if (r.startsWith("http://")) r = r.replace("http://", "ws://");
        if (r.startsWith("https://")) r = r.replace("https://", "wss://");
        relayUrl = r;
      }
    }
  } catch {}

  return { relayUrl, targetEpk };
}

function getOrCreateRelay(sessionId: string, targetEpk: string, relayUrl: string, roomId = "main"): RelayState {
  let state = activeRelays.get(sessionId);
  if (state && state.ws && (state.ws.readyState === WebSocket.OPEN || state.ws.readyState === WebSocket.CONNECTING)) {
    return state;
  }

  const privKey = ed.utils.randomSecretKey();
  const pubKey = ed.getPublicKey(privKey);
  const pubKeyB64 = Buffer.from(pubKey).toString("base64");

  state = {
    ws: null,
    connected: false,
    authenticated: false,
    presence: "offline",
    messages: [],
    listeners: [],
    privKey,
    pubKeyB64,
    relayUrl,
    targetEpk,
    roomId,
  };
  activeRelays.set(sessionId, state);

  try {
    const ws = new WebSocket(relayUrl);
    state.ws = ws;

    ws.on("open", () => {
      state!.connected = true;
      ws.send(JSON.stringify({ type: "hello", pubkey: pubKeyB64 }));
    });

    ws.on("message", (data: WebSocket.Data) => {
      try {
        const raw = data.toString();
        const frame = JSON.parse(raw);

        // 1. Challenge Response
        if (frame.type === "challenge" && frame.nonce) {
          const nonce = Buffer.from(frame.nonce, "base64");
          const sig = ed.sign(nonce, privKey);
          const sigB64 = Buffer.from(sig).toString("base64");
          ws.send(JSON.stringify({ type: "auth", sig: sigB64 }));
          state!.authenticated = true;

          // Subscribe presence & rooms & sync history
          setTimeout(() => {
            ws.send(JSON.stringify({ type: "subscribe_presence", peers: [targetEpk] }));
            ws.send(JSON.stringify({ type: "subscribe_rooms", peers: [targetEpk] }));
            ws.send(JSON.stringify({ type: "presence_check", peers: [targetEpk] }));
            ws.send(JSON.stringify({ type: "rooms_check", peers: [targetEpk] }));

            // Send session_sync inner
            const syncPayload = { type: "session_sync", id: `sync_${Date.now()}`, limit: 1000 };
            const outer = {
              peer: targetEpk,
              room: roomId,
              ct: Buffer.from(JSON.stringify(syncPayload)).toString("base64"),
            };
            ws.send(JSON.stringify(outer));
          }, 50);
          return;
        }

        // 2. Room & Presence Broadcasts (Per-Room Liveness - Mobile Parity)
        if (frame.type === "room_meta_updated") {
          if (frame.room_id === state!.roomId) {
            state!.presence = frame.meta?.working ? "working" : "online";
            broadcast(state!, { type: "presence", presence: state!.presence });
          }
          broadcast(state!, {
            type: "room_meta_updated",
            peer: frame.peer,
            roomId: frame.room_id,
            meta: frame.meta,
          });
          return;
        }

        if (frame.type === "room_announced") {
          if (frame.room_id === state!.roomId) {
            state!.presence = "online";
            broadcast(state!, { type: "presence", presence: "online" });
          }
          broadcast(state!, {
            type: "room_announced",
            peer: frame.peer,
            room: frame,
          });
          return;
        }

        if (frame.type === "room_ended") {
          if (frame.room_id === state!.roomId) {
            state!.presence = "offline";
            broadcast(state!, { type: "presence", presence: "offline" });
          }
          broadcast(state!, {
            type: "room_ended",
            peer: frame.peer,
            roomId: frame.room_id,
          });
          return;
        }

        if (frame.type === "rooms") {
          if (Array.isArray(frame.rooms)) {
            const liveRoom = frame.rooms.find((r: any) => r.room_id === state!.roomId);
            if (liveRoom) {
              state!.presence = liveRoom.working ? "working" : "online";
            } else {
              state!.presence = "offline";
            }
            broadcast(state!, { type: "presence", presence: state!.presence });
          }
          broadcast(state!, {
            type: "rooms",
            peer: frame.peer,
            rooms: frame.rooms,
          });
          return;
        }

        if (frame.type === "peer_offline") {
          state!.presence = "offline";
          broadcast(state!, { type: "presence", presence: "offline" });
          return;
        }

        if (frame.type === "presence") {
          broadcast(state!, { type: "presence_states", states: frame.states });
          return;
        }
        // 3. Inner frames
        if (frame.peer && frame.ct) {
          const innerStr = Buffer.from(frame.ct, "base64").toString("utf8");
          const inner = JSON.parse(innerStr);
          broadcast(state!, { type: "inner", data: inner });
        }
      } catch (err) {
        console.warn("Relay frame error", err);
      }
    });

    ws.on("error", (err: Error) => {
      console.warn("Relay WS error", err);
      broadcast(state!, { type: "error", message: err.message });
    });

    ws.on("close", () => {
      state!.connected = false;
      state!.authenticated = false;
      broadcast(state!, { type: "presence", presence: "offline" });
    });
  } catch (err: any) {
    console.error("Failed to connect to relay", err);
  }

  return state;
}

function broadcast(state: RelayState, event: Record<string, unknown>) {
  for (const l of state.listeners) {
    try {
      l(event);
    } catch {}
  }
}

// ── GET: SSE Event Stream ─────────────────────────────────────────────────────

export async function GET(req: NextRequest) {
  const { searchParams } = new URL(req.url);
  const sessionId = searchParams.get("sessionId") || "default_web_client";
  const { relayUrl: defaultRelay, targetEpk: defaultTarget } = getLocalConfig();
  const targetEpk = searchParams.get("remoteEpk") || defaultTarget;
  const relayUrl = searchParams.get("relayUrl") || defaultRelay;
  const roomId = searchParams.get("roomId") || "main";

  const state = getOrCreateRelay(sessionId, targetEpk, relayUrl, roomId);
  const encoder = new TextEncoder();
  const stream = new ReadableStream({
    start(controller) {
      // Send initial status
      controller.enqueue(
        encoder.encode(`data: ${JSON.stringify({ type: "init", presence: state.presence, connected: state.connected })}\n\n`)
      );

      const listener = (event: Record<string, unknown>) => {
        controller.enqueue(encoder.encode(`data: ${JSON.stringify(event)}\n\n`));
      };

      state.listeners.push(listener);

      // Keepalive ping every 15s
      const timer = setInterval(() => {
        try {
          controller.enqueue(encoder.encode(`: ping\n\n`));
        } catch {
          clearInterval(timer);
        }
      }, 15000);

      req.signal.addEventListener("abort", () => {
        clearInterval(timer);
        state.listeners = state.listeners.filter((l) => l !== listener);
      });
    },
  });

  return new Response(stream, {
    headers: {
      "Content-Type": "text/event-stream",
      "Cache-Control": "no-cache, no-transform",
      Connection: "keep-alive",
    },
  });
}

// ── POST: Send Message / Action to Pi ─────────────────────────────────────────

export async function POST(req: NextRequest) {
  try {
    const body = await req.json();
    const sessionId = body.sessionId || "default_web_client";
    const { relayUrl: defaultRelay, targetEpk: defaultTarget } = getLocalConfig();
    const targetEpk = body.remoteEpk || defaultTarget;
    const relayUrl = body.relayUrl || defaultRelay;
    const roomId = body.roomId || "main";

    const state = getOrCreateRelay(sessionId, targetEpk, relayUrl, roomId);
    if (body.action === "send_message" && body.text) {
      const payload = {
        type: "user_message",
        id: `cli_${Date.now()}`,
        text: body.text,
      };
      sendToRelay(state, payload);
      return NextResponse.json({ ok: true, id: payload.id });
    }

    if (body.action === "approve_tool" && body.toolCallId) {
      const payload = {
        type: "approve_tool",
        id: `dec_${Date.now()}`,
        tool_call_id: body.toolCallId,
        decision: body.decision || "allow",
      };
      sendToRelay(state, payload);
      return NextResponse.json({ ok: true });
    }

    if (body.action === "cancel" && body.targetId) {
      const payload = {
        type: "cancel",
        id: `can_${Date.now()}`,
        target_id: body.targetId,
      };
      sendToRelay(state, payload);
      return NextResponse.json({ ok: true });
    }

    if (body.action === "sync") {
      const payload = {
        type: "session_sync",
        id: `sync_${Date.now()}`,
        limit: 1000,
      };
      sendToRelay(state, payload);
      return NextResponse.json({ ok: true });
    }

    return NextResponse.json({ ok: false, error: "Unknown action" }, { status: 400 });
  } catch (err: any) {
    return NextResponse.json({ ok: false, error: err?.message || "Internal error" }, { status: 500 });
  }
}

function sendToRelay(state: RelayState, payload: Record<string, unknown>) {
  if (!state.ws || state.ws.readyState !== WebSocket.OPEN) return;
  const outer = {
    peer: state.targetEpk,
    room: state.roomId,
    ct: Buffer.from(JSON.stringify(payload)).toString("base64"),
  };
  state.ws.send(JSON.stringify(outer));
}
