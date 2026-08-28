// Relay endpoint resolution.
//
// The app always connects to a SINGLE relay at a time, regardless of
// how many peers it's paired with. The URL is resolved from:
//
//   1. `prefs.relayUrl` (user override, set via Settings or onboarding)
//   2. `kDefaultRelayUrl` (the public community relay)
//
// Canonical scheme on storage is `http://` or `https://` — that is
// what we keep in Preferences and hand to the mesh HTTP client. The
// WebSocket transport calls [toWsRelayUrl] right before opening the
// socket. User input is lenient: `ws://` / `wss://` are converted to
// `http://` / `https://`, and a scheme-less host gets `http://`
// prefixed (see [normalizeRelayUrl]). Other URL schemes are rejected.
//
// `peer.relayUrl` is kept on PeerRecord for legacy QR code payloads but
// is no longer consulted when opening a connection — the resolution is
// global, not per-peer.

import 'package:app/data/preferences/preferences.dart';

/// Public community relay. Hardcoded; not configurable at build time
/// to keep the onboarding flow deterministic.
const String kDefaultRelayUrl = 'https://relay-rp1.jacobmoura.work';

/// User-facing message returned when [isValidRelayUrl] rejects a
/// value. Surfaced verbatim by Settings and Onboarding — keep stable
/// for localization later.
const String kRelayUrlInvalidGeneric =
    'Enter a valid URL starting with https:// (or http:// for local '
    'relays).';

/// Normalizes a user-inputted relay URL:
/// - Trims whitespace and trailing slashes
/// - Converts ws:// to http:// and wss:// to https://
/// - Auto-prefixes http:// if no scheme is present
String normalizeRelayUrl(String raw) {
  var url = raw.trim();
  if (url.startsWith('ws://')) {
    url = 'http://${url.substring(5)}';
  } else if (url.startsWith('wss://')) {
    url = 'https://${url.substring(6)}';
  } else if (!RegExp(r'^[a-zA-Z][a-zA-Z0-9+.-]*://').hasMatch(url)) {
    // Only auto-prefix when there is NO scheme at all — an explicit
    // non-http(s) scheme (ftp://, …) stays untouched so validation
    // rejects it instead of mangling it into `http://ftp/…`.
    url = 'http://$url';
  }
  // Drop trailing slashes, but never into the bare `scheme://` itself
  // (`http:///` must stay `http://` so validation rejects it).
  while (url.endsWith('/') && !url.endsWith('://')) {
    url = url.substring(0, url.length - 1);
  }
  return url;
}

/// Returns the effective relay URL the app should connect to.
/// Falls back to [kDefaultRelayUrl] when no user override is set.
/// Always returns an `http(s)://` URL — caller is responsible for
/// applying [toWsRelayUrl] when opening a WebSocket.
String resolveRelayUrl(Preferences prefs) =>
    prefs.relayUrl ?? kDefaultRelayUrl;

/// Translates the canonical HTTP-form relay URL into the WebSocket
/// form expected by the underlying transport. `https://` → `wss://`,
/// `http://` → `ws://`. Pre-existing `ws(s)://` URLs (legacy QR
/// payloads, old peer records) pass through unchanged so the relay
/// mismatch check in `pair_request_flow` can still compare them.
String toWsRelayUrl(String url) {
  final normalized = normalizeRelayUrl(url);
  if (normalized.startsWith('https://')) return 'wss://${normalized.substring(8)}';
  if (normalized.startsWith('http://')) return 'ws://${normalized.substring(7)}';
  return normalized;
}

/// Validates a candidate relay URL the user typed into Settings or
/// the onboarding form.
bool isValidRelayUrl(String url) {
  final normalized = normalizeRelayUrl(url);
  if (!normalized.startsWith('http://') &&
      !normalized.startsWith('https://')) {
    return false;
  }
  final uri = Uri.tryParse(normalized);
  return uri != null && uri.host.isNotEmpty;
}

/// Returns the user-facing rejection message for [url]. Returns `null`
/// when the URL is valid.
String? relayUrlValidationMessage(String url) {
  if (url.trim().isEmpty) return kRelayUrlInvalidGeneric;
  if (isValidRelayUrl(url)) return null;
  return kRelayUrlInvalidGeneric;
}
