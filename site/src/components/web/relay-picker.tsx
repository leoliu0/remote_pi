"use client";

import { useState } from "react";
import { DEFAULT_RELAY_URL, normalizeRelayUrl, relayUrlValidationMessage } from "./relay-config";
import type { RelayStatus } from "./relay-connection";

interface RelayPickerProps {
  relayUrl: string;
  status?: RelayStatus;
  /** Called with a validated, normalized http(s):// URL. */
  onSave: (url: string) => void;
}

const STATUS_STYLE: Record<RelayStatus, { dot: string; text: string; label: string }> = {
  online: { dot: "bg-[#5fd38a]", text: "text-[#888]", label: "Connected" },
  connecting: { dot: "bg-amber-400 animate-pulse", text: "text-amber-400", label: "Connecting…" },
  offline: { dot: "bg-amber-400", text: "text-amber-400", label: "Offline" },
};

/** Shows the selected relay and lets the user switch it (Home + Settings). */
export function RelayPicker({ relayUrl, status, onSave }: RelayPickerProps) {
  const [editing, setEditing] = useState(false);
  const [draft, setDraft] = useState(relayUrl);
  const [error, setError] = useState<string | null>(null);

  const startEditing = () => {
    setDraft(relayUrl);
    setError(null);
    setEditing(true);
  };

  const save = (raw: string) => {
    const message = relayUrlValidationMessage(raw);
    if (message) {
      setError(message);
      return;
    }
    setEditing(false);
    const url = normalizeRelayUrl(raw);
    if (url !== relayUrl) onSave(url);
  };

  if (!editing) {
    const style = status ? STATUS_STYLE[status] : null;
    return (
      <div className="flex items-center gap-2 min-w-0 text-[11px] font-mono">
        {style && <span className={`w-1.5 h-1.5 rounded-full shrink-0 ${style.dot}`} />}
        <span className="text-[#ccc]">Relay</span>
        {style && <span className={style.text}>· {style.label}</span>}
        <button
          type="button"
          onClick={startEditing}
          title="Change relay server"
          className="min-w-0 truncate text-[#4fc3f7] hover:underline cursor-pointer"
        >
          {relayUrl.replace(/^https?:\/\//, "")}
        </button>
      </div>
    );
  }

  return (
    <form
      className="flex flex-col gap-1.5 w-full font-mono text-[11px]"
      onSubmit={(e) => {
        e.preventDefault();
        save(draft);
      }}
    >
      <div className="flex items-center gap-2">
        <input
          autoFocus
          type="text"
          value={draft}
          onChange={(e) => {
            setDraft(e.target.value);
            setError(null);
          }}
          placeholder="https://my-relay.example.com"
          aria-label="Relay server URL"
          className="flex-1 min-w-0 bg-[#050505] border border-white/15 focus:border-[#4fc3f7] rounded-lg px-2.5 py-1.5 text-xs text-white outline-none"
        />
        <button
          type="submit"
          className="px-2.5 py-1.5 bg-[#4fc3f7] hover:bg-[#38bdf8] text-[#04222e] font-semibold rounded-lg cursor-pointer"
        >
          Save
        </button>
        <button
          type="button"
          onClick={() => setEditing(false)}
          className="px-2 py-1.5 text-[#888] hover:text-white cursor-pointer"
        >
          Cancel
        </button>
      </div>
      <div className="flex items-center justify-between gap-2">
        <span className={error ? "text-red-400" : "text-[#666]"}>
          {error ?? "Sessions are listed from this relay. Saving reconnects."}
        </span>
        {relayUrl !== DEFAULT_RELAY_URL && (
          <button
            type="button"
            onClick={() => save(DEFAULT_RELAY_URL)}
            className="shrink-0 text-[#888] hover:text-white underline cursor-pointer"
          >
            Use default
          </button>
        )}
      </div>
    </form>
  );
}
