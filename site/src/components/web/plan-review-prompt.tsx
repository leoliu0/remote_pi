"use client";

import { useState } from "react";
import { MarkdownRenderer } from "./markdown-renderer";
import { PromptNotice, usePromptSend } from "./extension-ui-prompt";
import {
  buildCancelResponse,
  buildPlanResponse,
  type ExtensionUiResponseWire,
  type PendingPrompt,
  type PlanReview,
} from "./extension-ui";

// omp's TUI-only "Plan Review" overlay on the web: the plan as markdown and
// omp's choices in its order. A choice sends at once (the terminal's Enter);
// the prompt stays open until the same-id notify closes it, like
// ExtensionUiPrompt. Cancel is omp's Esc: close the review, keep planning.

interface Props {
  prompt: PendingPrompt;
  plan: PlanReview;
  /** Sends the response; false when the relay link is down (nothing sent). */
  onRespond: (resp: ExtensionUiResponseWire) => boolean;
}

export function PlanReviewPrompt({ prompt, plan, onRespond }: Props) {
  const req = prompt.request;
  const [feedback, setFeedback] = useState("");
  const { submitting, awaitHint, send } = usePromptSend(prompt, onRespond);
  const cancel = () => {
    if (!submitting) send(buildCancelResponse(req));
  };
  const showsRefine = plan.options.some((o) => o.action === "refine");

  return (
    <div
      className="absolute inset-0 z-40 bg-black/70 backdrop-blur-sm flex items-end sm:items-center justify-center p-0 sm:p-6"
      role="dialog"
      aria-modal="true"
      aria-label="Plan ready for review"
      onKeyDown={(e) => {
        if (e.key === "Escape") cancel();
      }}
    >
      <div className="w-full sm:max-w-3xl max-h-full flex flex-col bg-[#0e1117] border border-white/15 sm:rounded-2xl shadow-2xl">
        <div className="px-4 py-3 border-b border-white/10 flex items-center gap-3">
          <div className="min-w-0 flex-1">
            <div className="text-sm font-semibold text-white">Plan ready for review</div>
            <div className="text-xs text-[#888] font-mono truncate">
              {plan.title && <span className="text-[#4fc3f7]">{plan.title}</span>}
              {plan.title && plan.planFilePath && <span className="text-[#444]"> · </span>}
              {plan.planFilePath}
            </div>
          </div>
          <button
            type="button"
            onClick={cancel}
            disabled={submitting}
            title="Close the review and keep planning"
            aria-label="Keep planning"
            className="p-1 text-[#888] hover:text-white disabled:opacity-40 cursor-pointer"
          >
            ✕
          </button>
        </div>

        <div className="flex-1 min-h-0 overflow-y-auto p-4">
          {plan.content === null ? (
            <div className="text-sm text-[#E5484D]">
              The plan file could not be read: <span className="font-mono">{plan.planFilePath}</span>
            </div>
          ) : (
            <MarkdownRenderer content={plan.content} />
          )}
        </div>

        <div className="px-4 py-3 border-t border-white/10 space-y-2">
          <div className="text-xs text-[#888]">Plan mode - next step</div>
          <div className="flex flex-col gap-1.5">
            {plan.options.map((o) => (
              <button
                key={o.action}
                type="button"
                onClick={() => send(buildPlanResponse(req, o.action, feedback))}
                disabled={o.disabled || submitting}
                className="w-full text-left px-3 py-2 rounded-lg border border-white/15 text-sm text-white hover:bg-[#4fc3f7]/10 hover:border-[#4fc3f7]/50 disabled:opacity-40 disabled:hover:bg-transparent disabled:hover:border-white/15 disabled:cursor-not-allowed cursor-pointer transition-colors flex items-center justify-between gap-3"
              >
                <span>{o.label}</span>
                {o.disabled && <span className="text-[11px] text-[#888]">context too full</span>}
              </button>
            ))}
          </div>
          {showsRefine && (
            <textarea
              value={feedback}
              onChange={(e) => setFeedback(e.target.value)}
              disabled={submitting}
              rows={2}
              placeholder="Optional: what should the agent change? (sent with Refine plan)"
              className="w-full rounded-lg bg-black/40 border border-white/15 px-3 py-2 text-sm text-white placeholder:text-[#555] outline-none focus:border-[#4fc3f7]/60 resize-y"
            />
          )}
          <PromptNotice error={prompt.error} awaitHint={awaitHint} />
          <button
            type="button"
            onClick={cancel}
            disabled={submitting}
            className="w-full py-2 rounded-lg border border-white/20 text-sm text-white hover:bg-white/5 disabled:opacity-40 cursor-pointer"
          >
            {submitting ? "Sending…" : "Keep planning"}
          </button>
        </div>
      </div>
    </div>
  );
}
