"use client";

import { RelayPicker } from "./relay-picker";

interface SignInScreenProps {
  relayUrl: string;
  onRelayChange: (url: string) => void;
  /** Shown when a sign-in link was present but unusable. */
  error?: string | null;
}

/** The only screen a signed-out browser sees: sign in from the phone app. */
export function SignInScreen({ relayUrl, onRelayChange, error }: SignInScreenProps) {
  return (
    <div className="flex-1 flex items-center justify-center px-4 py-16 font-mono">
      <div className="w-full max-w-sm flex flex-col gap-6">
        <div className="text-center">
          <div className="text-3xl font-bold text-white">
            <span className="text-[#4fc3f7]">π</span> Remote Pi
          </div>
          <div className="mt-6 text-sm text-white leading-relaxed">
            Open Remote Pi on your phone → <span className="text-[#4fc3f7]">Settings</span> →{" "}
            <span className="text-[#4fc3f7]">Sign in on web</span>
          </div>
        </div>
        {error && (
          <div className="p-2.5 rounded-lg bg-red-500/10 border border-red-500/30 text-red-400 text-[11px]">{error}</div>
        )}
        <div className="p-3 rounded-xl border border-white/10 bg-[#0b0e14]">
          <RelayPicker key={relayUrl} relayUrl={relayUrl} onSave={onRelayChange} />
        </div>
      </div>
    </div>
  );
}
