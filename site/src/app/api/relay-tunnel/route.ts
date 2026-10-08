import { NextRequest, NextResponse } from "next/server";
import WebSocket from "ws";
import { isRelayProxyTargetAllowed } from "@/components/web/relay-proxy-policy";

// Byte pipe between a browser and a plain `ws://` relay for pages served over
// https (browsers block mixed-content sockets). The browser still performs the
// relay handshake with its own owner key; this route only forwards text
// frames and never parses or stores them.
//
//   GET    ?id&url  → SSE: {t:"open"} | {t:"msg", d:<frame>} | {t:"close"}
//   POST   {id, frame} → forwards one text frame to the relay
//   DELETE ?id      → closes the relay socket

export const dynamic = "force-dynamic";

const tunnels = new Map<string, WebSocket>();

function sse(event: { t: "open" | "msg" | "close"; d?: string }): Uint8Array {
  return new TextEncoder().encode(`data: ${JSON.stringify(event)}\n\n`);
}

export async function GET(req: NextRequest) {
  const { searchParams } = new URL(req.url);
  const id = searchParams.get("id");
  const url = searchParams.get("url");
  if (
    !id || !url || !/^wss?:\/\/[^/\s]+/.test(url) || tunnels.has(id)
    || !isRelayProxyTargetAllowed(url, process.env["RELAY_PROXY_HOSTS"])
  ) {
    return NextResponse.json({ ok: false, error: "invalid tunnel request" }, { status: 400 });
  }

  const ws = new WebSocket(url);
  tunnels.set(id, ws);

  const stream = new ReadableStream<Uint8Array>({
    start(controller) {
      let ended = false;
      const end = () => {
        if (ended) return;
        ended = true;
        clearInterval(keepalive);
        tunnels.delete(id);
        try {
          controller.enqueue(sse({ t: "close" }));
          controller.close();
        } catch {}
        ws.close();
      };
      const keepalive = setInterval(() => {
        try {
          controller.enqueue(new TextEncoder().encode(": ping\n\n"));
        } catch {
          end();
        }
      }, 15_000);

      ws.on("open", () => controller.enqueue(sse({ t: "open" })));
      ws.on("message", (data: WebSocket.RawData, isBinary: boolean) => {
        if (!isBinary) controller.enqueue(sse({ t: "msg", d: data.toString() }));
      });
      ws.on("error", end);
      ws.on("close", end);
      req.signal.addEventListener("abort", end);
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

export async function POST(req: NextRequest) {
  const body = (await req.json().catch(() => null)) as { id?: unknown; frame?: unknown } | null;
  const ws = typeof body?.id === "string" ? tunnels.get(body.id) : undefined;
  if (!ws || ws.readyState !== WebSocket.OPEN || typeof body?.frame !== "string") {
    return NextResponse.json({ ok: false }, { status: 404 });
  }
  ws.send(body.frame);
  return NextResponse.json({ ok: true });
}

export async function DELETE(req: NextRequest) {
  const id = new URL(req.url).searchParams.get("id");
  if (id) tunnels.get(id)?.close();
  return NextResponse.json({ ok: true });
}
