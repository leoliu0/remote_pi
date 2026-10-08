import { NextRequest, NextResponse } from "next/server";
import { isRelayProxyTargetAllowed } from "@/components/web/relay-proxy-policy";

// Read-only proxy for the relay's `GET /mesh/<owner_pk_hash>` (relays send no
// CORS headers, and https pages cannot fetch http:// relays). The browser
// verifies the owner signature itself, so this route is not trusted with
// anything: it forwards status + body verbatim.

export const dynamic = "force-dynamic";

export async function GET(req: NextRequest) {
  const { searchParams } = new URL(req.url);
  const relay = searchParams.get("relay") ?? "";
  const hash = searchParams.get("hash") ?? "";
  const since = searchParams.get("since");
  if (
    !/^https?:\/\/\S+[^/]$/.test(relay) || !/^[0-9a-f]{64}$/.test(hash) || (since !== null && !/^\d+$/.test(since))
    || !isRelayProxyTargetAllowed(relay, process.env["RELAY_PROXY_HOSTS"])
  ) {
    return NextResponse.json({ ok: false, error: "invalid mesh request" }, { status: 400 });
  }
  try {
    const target = new URL(`${relay}/mesh/${hash}`);
    if (since !== null) target.searchParams.set("since", since);
    const upstream = await fetch(target, { cache: "no-store", signal: AbortSignal.timeout(8000) });
    const body = upstream.status === 304 ? null : await upstream.text();
    return new Response(body, {
      status: upstream.status,
      headers: { "Content-Type": upstream.headers.get("content-type") ?? "text/plain", "Cache-Control": "no-store" },
    });
  } catch {
    return NextResponse.json({ ok: false, error: "relay unreachable" }, { status: 502 });
  }
}
