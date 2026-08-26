"use client";

import { PairedSession } from "./web-client";

interface SessionInfoModalProps {
  session: PairedSession;
  onClose: () => void;
}

export function SessionInfoModal({ session, onClose }: SessionInfoModalProps) {
  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center p-4 bg-black/80 backdrop-blur-sm animate-in fade-in duration-150">
      <div className="bg-[#0e1117] border border-white/15 rounded-2xl w-full max-w-md overflow-hidden shadow-2xl">
        <div className="px-5 py-4 border-b border-white/10 flex items-center justify-between">
          <div className="text-sm font-semibold text-white font-mono">Session Info</div>
          <button
            type="button"
            onClick={onClose}
            className="text-[#888] hover:text-white p-1 rounded-lg hover:bg-white/5 transition-colors cursor-pointer"
          >
            ✕
          </button>
        </div>

        <div className="p-5 space-y-3.5 text-xs font-mono">
          <div className="flex justify-between items-center py-1 border-b border-white/5">
            <span className="text-[#888]">Device Name</span>
            <span className="text-white font-medium">{session.device}</span>
          </div>
          <div className="flex justify-between items-center py-1 border-b border-white/5">
            <span className="text-[#888]">Room / Path</span>
            <span className="text-[#4fc3f7] font-medium">{session.roomId}</span>
          </div>
          <div className="flex justify-between items-center py-1 border-b border-white/5">
            <span className="text-[#888]">Remote EPK</span>
            <span className="text-white truncate max-w-[200px]" title={session.remoteEpk}>
              {session.remoteEpk.substring(0, 16)}…
            </span>
          </div>
          <div className="flex justify-between items-center py-1 border-b border-white/5">
            <span className="text-[#888]">Relay Server</span>
            <span className="text-[#888] truncate max-w-[200px]">{session.relayUrl}</span>
          </div>
          <div className="flex justify-between items-center py-1 border-b border-white/5">
            <span className="text-[#888]">Paired At</span>
            <span className="text-[#888]">{new Date(session.pairedAt).toLocaleDateString()}</span>
          </div>
          <div className="flex justify-between items-center py-1">
            <span className="text-[#888]">Protocol</span>
            <span className="text-[#5fd38a]">v2 (Encrypted WSS)</span>
          </div>
        </div>

        <div className="p-4 bg-black/40 border-t border-white/10 flex justify-end">
          <button
            type="button"
            onClick={onClose}
            className="px-4 py-2 bg-[#4fc3f7] hover:bg-[#38bdf8] text-[#04222e] font-semibold rounded-xl text-xs transition-colors cursor-pointer"
          >
            Done
          </button>
        </div>
      </div>
    </div>
  );
}
