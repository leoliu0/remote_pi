// Relay endpoint resolution — mirrors app/lib/data/transport/relay_config.dart.
//
// The web client talks to a SINGLE relay at a time. The URL is the user's
// override (localStorage) or DEFAULT_RELAY_URL. Storage keeps the canonical
// http(s):// form; the WebSocket transport converts with `toWsRelayUrl`.
//
// No runtime imports: the node test runner loads this file directly.

export const DEFAULT_RELAY_URL = "http://178.157.59.181";

export const RELAY_URL_INVALID_MESSAGE =
  "Enter a valid URL starting with https:// (or http:// for local relays).";

const STORAGE_KEY_RELAY_URL = "remotepi_relay_url";

/**
 * Trims whitespace and trailing slashes, maps ws(s):// to http(s)://, and
 * prefixes http:// when no scheme is present. Other schemes stay untouched so
 * validation rejects them.
 */
export function normalizeRelayUrl(raw: string): string {
  let url = raw.trim();
  if (url.startsWith("ws://")) {
    url = `http://${url.substring(5)}`;
  } else if (url.startsWith("wss://")) {
    url = `https://${url.substring(6)}`;
  } else if (!/^[a-zA-Z][a-zA-Z0-9+.-]*:\/\//.test(url)) {
    url = `http://${url}`;
  }
  while (url.endsWith("/") && !url.endsWith("://")) {
    url = url.substring(0, url.length - 1);
  }
  return url;
}

/** `https://` → `wss://`, `http://` → `ws://`. */
export function toWsRelayUrl(url: string): string {
  const normalized = normalizeRelayUrl(url);
  if (normalized.startsWith("https://")) return `wss://${normalized.substring(8)}`;
  if (normalized.startsWith("http://")) return `ws://${normalized.substring(7)}`;
  return normalized;
}

export function isValidRelayUrl(url: string): boolean {
  const normalized = normalizeRelayUrl(url);
  if (!normalized.startsWith("http://") && !normalized.startsWith("https://")) return false;
  try {
    return new URL(normalized).hostname.length > 0;
  } catch {
    return false;
  }
}

/** User-facing rejection message, or `null` when the URL is valid. */
export function relayUrlValidationMessage(url: string): string | null {
  if (url.trim() === "" || !isValidRelayUrl(url)) return RELAY_URL_INVALID_MESSAGE;
  return null;
}

/** The user's relay override, else the default. Always http(s)://. */
export function resolveRelayUrl(): string {
  if (typeof window === "undefined") return DEFAULT_RELAY_URL;
  try {
    const saved = localStorage.getItem(STORAGE_KEY_RELAY_URL);
    if (saved && isValidRelayUrl(saved)) return normalizeRelayUrl(saved);
  } catch {}
  return DEFAULT_RELAY_URL;
}

/** Persists the relay override; `null` (or the default) clears it. */
export function saveRelayUrl(url: string | null): void {
  try {
    if (url === null || normalizeRelayUrl(url) === DEFAULT_RELAY_URL) {
      localStorage.removeItem(STORAGE_KEY_RELAY_URL);
    } else {
      localStorage.setItem(STORAGE_KEY_RELAY_URL, normalizeRelayUrl(url));
    }
  } catch {}
}
