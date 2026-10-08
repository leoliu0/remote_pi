"use client";

import { useEffect, useEffectEvent, useMemo, useState } from "react";
import qrcode from "qrcode-generator";
import { RelayPicker } from "./relay-picker";
import {
  decryptWebLogin,
  newWebLoginKeyPair,
  parseWebLoginEnvelope,
  WEB_LOGIN_TTL_MS,
  webLoginQrText,
  type WebLoginPayload,
} from "./web-login-crypto";

interface SignInScreenProps {
  relayUrl: string;
  onRelayChange: (url: string) => void;
  /** The phone delivered (and the browser decrypted) the owner key. */
  onSignedIn: (payload: WebLoginPayload) => void;
}

const POLL_MS = 1000;
const RETRY_MS = 5000;

interface LoginCode {
  qrText: string;
  expiresAt: number;
}

type SignInError = "unreachable" | "decrypt";

const ERROR_TEXT: Record<SignInError, string> = {
  unreachable: "Couldn't reach the sign-in service. Retrying…",
  decrypt: "Sign-in failed: the reply from your phone couldn't be decrypted. Scan the new code to try again.",
};

function QrCode({ text }: { text: string }) {
  const { size, path } = useMemo(() => {
    const qr = qrcode(0, "M");
    qr.addData(text);
    qr.make();
    const count = qr.getModuleCount();
    let d = "";
    for (let row = 0; row < count; row++) {
      for (let col = 0; col < count; col++) {
        if (qr.isDark(row, col)) d += `M${col} ${row}h1v1h-1z`;
      }
    }
    return { size: count, path: d };
  }, [text]);
  return (
    <svg
      viewBox={`-4 -4 ${size + 8} ${size + 8}`}
      className="w-60 h-60 rounded-lg bg-white"
      shapeRendering="crispEdges"
      role="img"
      aria-label="Sign-in QR code"
    >
      <path d={path} fill="#000" />
    </svg>
  );
}

/**
 * The only screen a signed-out browser sees: a QR code the phone app scans to
 * hand this browser the owner key, end-to-end encrypted to a key pair that
 * exists only in this effect's memory (see web-login-crypto.ts).
 */
export function SignInScreen({ relayUrl, onRelayChange, onSignedIn }: SignInScreenProps) {
  const [attempt, setAttempt] = useState(0);
  const [code, setCode] = useState<LoginCode | null>(null);
  const [error, setError] = useState<SignInError | null>(null);
  const [now, setNow] = useState(() => Date.now());
  const signedIn = useEffectEvent(onSignedIn);

  // One login id + ephemeral key pair per attempt; a new attempt replaces the
  // QR when the id expires, the server forgets it, or decryption fails.
  useEffect(() => {
    let cancelled = false;
    let timer: number | undefined;
    const keyPair = newWebLoginKeyPair();
    const restart = () => {
      if (cancelled) return;
      setCode(null);
      setAttempt((a) => a + 1);
    };

    const start = async () => {
      let id: string;
      try {
        const res = await fetch("/api/web-login", { method: "POST", cache: "no-store" });
        if (!res.ok) throw new Error(`HTTP ${res.status}`);
        ({ id } = (await res.json()) as { id: string });
      } catch {
        if (cancelled) return;
        setCode(null);
        setError("unreachable");
        timer = window.setTimeout(restart, RETRY_MS);
        return;
      }
      if (cancelled) return;
      const expiresAt = Date.now() + WEB_LOGIN_TTL_MS;
      setCode({ qrText: webLoginQrText(window.location.host, id, keyPair.publicKey), expiresAt });
      setError((e) => (e === "unreachable" ? null : e));

      const poll = async () => {
        if (Date.now() >= expiresAt) {
          setError(null);
          return restart();
        }
        let res: Response | null = null;
        try {
          res = await fetch(`/api/web-login/${id}`, { cache: "no-store" });
        } catch {
          // Transient network failure: keep polling until the id expires.
        }
        if (cancelled) return;
        if (res?.status === 404) {
          setError(null);
          return restart();
        }
        if (res?.status === 200) {
          let payload: WebLoginPayload;
          try {
            const envelope = parseWebLoginEnvelope(await res.json());
            if (!envelope) throw new Error("malformed envelope");
            payload = decryptWebLogin(keyPair.secretKey, id, envelope);
          } catch {
            if (cancelled) return;
            setError("decrypt");
            return restart();
          }
          if (!cancelled) signedIn(payload);
          return;
        }
        timer = window.setTimeout(poll, POLL_MS);
      };
      timer = window.setTimeout(poll, POLL_MS);
    };

    void start();
    return () => {
      cancelled = true;
      clearTimeout(timer);
    };
  }, [attempt]);

  useEffect(() => {
    const tick = window.setInterval(() => setNow(Date.now()), 1000);
    return () => clearInterval(tick);
  }, []);

  const secondsLeft = code ? Math.max(0, Math.ceil((code.expiresAt - now) / 1000)) : 0;

  return (
    <div className="flex-1 flex items-center justify-center px-4 py-16 font-mono">
      <div className="w-full max-w-sm flex flex-col gap-6">
        <div className="text-center">
          <div className="text-3xl font-bold text-white">
            <span className="text-[#4fc3f7]">π</span> Remote Pi
          </div>
          <div className="mt-6 text-sm text-white leading-relaxed">
            Open Remote Pi on your phone → <span className="text-[#4fc3f7]">Settings</span> →{" "}
            <span className="text-[#4fc3f7]">Sign in on web</span> → scan this code
          </div>
        </div>
        <div className="flex flex-col items-center gap-2">
          {code ? (
            <QrCode text={code.qrText} />
          ) : (
            <div className="w-60 h-60 rounded-lg border border-white/10 flex items-center justify-center">
              <div className="w-5 h-5 border-2 border-[#4fc3f7] border-t-transparent rounded-full animate-spin" />
            </div>
          )}
          <div className="h-4 flex items-center gap-2 text-[11px] text-white/50">
            {code && (
              <>
                <span>New code in {secondsLeft}s</span>
                <span>·</span>
                <button
                  type="button"
                  className="text-[#4fc3f7] hover:underline"
                  onClick={() => {
                    setCode(null);
                    setError(null);
                    setAttempt((a) => a + 1);
                  }}
                >
                  Refresh
                </button>
              </>
            )}
          </div>
        </div>
        {error && (
          <div className="p-2.5 rounded-lg bg-red-500/10 border border-red-500/30 text-red-400 text-[11px]">
            {ERROR_TEXT[error]}
          </div>
        )}
        <div className="p-3 rounded-xl border border-white/10 bg-[#0b0e14]">
          <RelayPicker key={relayUrl} relayUrl={relayUrl} onSave={onRelayChange} />
        </div>
      </div>
    </div>
  );
}
