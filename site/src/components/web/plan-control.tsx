"use client";

import { memo, useState } from "react";
import { planControl, type PlanControlItem, type PlanModeAction, type PlanState } from "./plan-state";

// The composer's Plan control (the app's plan quick button): idle "Plan"
// enters plan mode, "Plan ready" re-opens the review, "Planning" / "Plan
// paused" open a menu. Exiting with a plan asks omp's confirm first.

const TONE: Record<PlanState["status"], string> = {
  idle: "text-[#888] border-white/15 hover:text-white hover:bg-white/5",
  active: "text-[#4fc3f7] border-[#4fc3f7]/40 bg-[#4fc3f7]/10 hover:bg-[#4fc3f7]/20",
  paused: "text-amber-300 border-amber-500/40 bg-amber-500/10 hover:bg-amber-500/20",
  review: "text-[#04222e] border-[#4fc3f7] bg-[#4fc3f7] hover:bg-[#38bdf8] font-semibold",
};

export const PlanControl = memo(function PlanControl({
  state,
  onAction,
}: {
  state: PlanState;
  onAction: (action: PlanModeAction) => void;
}) {
  const control = planControl(state);
  const [open, setOpen] = useState(false);
  const [confirming, setConfirming] = useState<PlanControlItem | null>(null);
  // A new status changes what the control offers: drop a menu opened for the old one.
  const [seenStatus, setSeenStatus] = useState(state.status);
  if (state.status !== seenStatus) {
    setSeenStatus(state.status);
    setOpen(false);
    setConfirming(null);
  }

  const close = () => {
    setOpen(false);
    setConfirming(null);
  };
  const pick = (item: PlanControlItem) => {
    if (item.confirm) {
      setConfirming(item);
      setOpen(true);
      return;
    }
    close();
    onAction(item.action);
  };

  return (
    <div className="relative">
      <button
        type="button"
        onClick={() => (control.menu ? (open ? close() : setOpen(true)) : pick(control.items[0]))}
        aria-haspopup={control.menu ? "menu" : undefined}
        aria-expanded={control.menu ? open : undefined}
        title={state.title ? `${control.label}: ${state.title}` : control.label}
        className={`px-2 py-0.5 rounded-lg border text-[11px] font-mono whitespace-nowrap transition-colors cursor-pointer ${TONE[state.status]}`}
      >
        {control.label}
      </button>
      {open && (
        <>
          <button type="button" aria-label="Close plan menu" className="fixed inset-0 z-30 cursor-default" onClick={close} />
          <div
            role="menu"
            className="absolute bottom-full left-0 mb-2 z-40 w-72 bg-[#0e1117] border border-white/15 rounded-xl shadow-2xl p-1.5 text-xs"
          >
            {confirming ? (
              <div className="p-2 space-y-2">
                <div className="text-white">{confirming.confirm}</div>
                <div className="flex gap-2 justify-end">
                  <button
                    type="button"
                    onClick={close}
                    className="px-2.5 py-1 rounded-lg border border-white/20 text-white hover:bg-white/5 cursor-pointer"
                  >
                    Cancel
                  </button>
                  <button
                    type="button"
                    onClick={() => {
                      close();
                      onAction(confirming.action);
                    }}
                    className="px-2.5 py-1 rounded-lg bg-red-500/20 hover:bg-red-500/30 text-red-300 border border-red-500/40 font-semibold cursor-pointer"
                  >
                    {confirming.label}
                  </button>
                </div>
              </div>
            ) : (
              control.items.map((item) => (
                <button
                  key={item.action}
                  type="button"
                  role="menuitem"
                  onClick={() => pick(item)}
                  className="w-full text-left px-2.5 py-1.5 rounded-lg text-white hover:bg-[#4fc3f7]/15 cursor-pointer"
                >
                  {item.label}
                </button>
              ))
            )}
          </div>
        </>
      )}
    </div>
  );
});
