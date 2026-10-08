// Which relays the server-side proxies (`/api/relay-tunnel`, `/api/relay-mesh`)
// may reach. They exist only because https pages can't open ws:// sockets or
// fetch http:// relays without CORS; on a public deployment an unrestricted
// target turns the site into an open proxy. `RELAY_PROXY_HOSTS` is a
// comma-separated list of `host` or `host:port` (e.g. `178.157.59.181`).
// Unset means unrestricted, which is only meant for local development.

export function isRelayProxyTargetAllowed(target: string, allowList: string | undefined): boolean {
  let url: URL;
  try {
    url = new URL(target);
  } catch {
    return false;
  }
  if (!["ws:", "wss:", "http:", "https:"].includes(url.protocol)) return false;
  if (allowList === undefined || allowList.trim() === "") return true;
  const allowed = allowList.split(",").map((h) => h.trim().toLowerCase()).filter(Boolean);
  const host = url.hostname.toLowerCase();
  return allowed.includes(host) || (url.port !== "" && allowed.includes(`${host}:${url.port}`));
}
