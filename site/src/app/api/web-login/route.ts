import { NextResponse } from "next/server";
import { webLoginStore } from "@/components/web/web-login-store";

// Starts a QR web sign-in: hands the browser a fresh one-time login id.
// See web-login-crypto.ts for the protocol.

export const dynamic = "force-dynamic";

export function POST() {
  const id = webLoginStore().create();
  if (!id) {
    return NextResponse.json({ error: "too many pending sign-ins" }, { status: 503, headers: { "Cache-Control": "no-store" } });
  }
  return NextResponse.json({ id }, { headers: { "Cache-Control": "no-store" } });
}
