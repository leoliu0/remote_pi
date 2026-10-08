import { NextRequest } from "next/server";
import { isWebLoginId, parseWebLoginEnvelope } from "@/components/web/web-login-crypto";
import { WEB_LOGIN_MAX_BODY_BYTES, webLoginStore } from "@/components/web/web-login-store";

// POST: the phone delivers the encrypted owner seed for a login id (once).
// GET:  the browser polls for it; the envelope is handed out exactly once.
// The body is end-to-end encrypted to the browser's QR key; it is stored and
// returned verbatim and never decrypted here.

export const dynamic = "force-dynamic";

const NO_STORE = { "Cache-Control": "no-store" };

type Params = { params: Promise<{ id: string }> };

export async function POST(req: NextRequest, { params }: Params) {
  const { id } = await params;
  if (!isWebLoginId(id)) return new Response(null, { status: 404, headers: NO_STORE });
  if (Number(req.headers.get("content-length") ?? 0) > WEB_LOGIN_MAX_BODY_BYTES) {
    return new Response(null, { status: 413, headers: NO_STORE });
  }
  const bytes = new Uint8Array(await req.arrayBuffer());
  if (bytes.byteLength > WEB_LOGIN_MAX_BODY_BYTES) return new Response(null, { status: 413, headers: NO_STORE });
  let body: string;
  try {
    body = new TextDecoder("utf-8", { fatal: true }).decode(bytes);
    if (!parseWebLoginEnvelope(JSON.parse(body))) throw new Error("not a web-login envelope");
  } catch {
    return new Response(null, { status: 400, headers: NO_STORE });
  }
  const status = webLoginStore().deliver(id, body);
  return new Response(null, { status, headers: NO_STORE });
}

export async function GET(_req: NextRequest, { params }: Params) {
  const { id } = await params;
  const result = isWebLoginId(id) ? webLoginStore().poll(id) : { status: 404 as const };
  if (result.status !== 200) return new Response(null, { status: result.status, headers: NO_STORE });
  return new Response(result.body, { status: 200, headers: { ...NO_STORE, "Content-Type": "application/json" } });
}
