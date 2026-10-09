"use client";

import { useEffect, useRef, useState } from "react";
import {
  EMPTY_QUESTION_DRAFT,
  buildCancelResponse,
  buildSubmitResponse,
  canSubmit,
  isMultiQuestion,
  toggleOption,
  type AskDraft,
  type AskQuestion,
  type ExtensionUiResponseWire,
  type PendingPrompt,
  type QuestionDraft,
} from "./extension-ui";

// Plan/57 — web counterpart of the phone's ExtensionUiSheet: a modal over the
// chat that answers an extension_ui_request. It stays open after Submit until
// the extension's notify dismiss arrives (or a warning re-enables it), with
// the phone's 10 s "still waiting" backstop.

const SUBMIT_BACKSTOP_MS = 10_000;

interface Props {
  prompt: PendingPrompt;
  /** Sends the response; false when the relay link is down (nothing sent). */
  onRespond: (resp: ExtensionUiResponseWire) => boolean;
}

export function ExtensionUiPrompt({ prompt, onRespond }: Props) {
  const req = prompt.request;
  const ask = req.ask;
  const [askDraft, setAskDraft] = useState<AskDraft>({});
  const [plain, setPlain] = useState(req.method === "editor" ? req.prefill ?? "" : "");
  const [submitting, setSubmitting] = useState(false);
  const [awaitHint, setAwaitHint] = useState(false);
  const backstop = useRef<number | null>(null);

  // A rejection for this request stops the spinner so the user can retry.
  const [seenError, setSeenError] = useState(prompt.error);
  if (prompt.error !== seenError) {
    setSeenError(prompt.error);
    if (prompt.error) {
      setSubmitting(false);
      setAwaitHint(false);
    }
  }

  useEffect(() => () => window.clearTimeout(backstop.current ?? undefined), []);

  const send = (resp: ExtensionUiResponseWire) => {
    setSubmitting(true);
    setAwaitHint(false);
    if (!onRespond(resp)) {
      setSubmitting(false);
      return;
    }
    window.clearTimeout(backstop.current ?? undefined);
    backstop.current = window.setTimeout(() => {
      setSubmitting(false);
      setAwaitHint(true);
    }, SUBMIT_BACKSTOP_MS);
  };

  const plainDraft = { value: plain };
  const submittable = canSubmit(req, askDraft, plainDraft);
  const submit = () => {
    if (submittable && !submitting) send(buildSubmitResponse(req, askDraft, plainDraft));
  };
  const cancel = () => {
    if (!submitting) send(buildCancelResponse(req));
  };

  const updateQuestion = (qid: string, next: (d: QuestionDraft) => QuestionDraft) =>
    setAskDraft((prev) => ({ ...prev, [qid]: next(prev[qid] ?? EMPTY_QUESTION_DRAFT) }));

  const title = req.title ?? ask?.title ?? "Clarification needed";

  return (
    <div
      className="absolute inset-0 z-40 bg-black/70 backdrop-blur-sm flex items-end sm:items-center justify-center p-0 sm:p-6"
      role="dialog"
      aria-modal="true"
      aria-label={title}
      onKeyDown={(e) => {
        if (e.key === "Escape") cancel();
      }}
    >
      <div className="w-full sm:max-w-2xl max-h-full flex flex-col bg-[#0e1117] border border-white/15 sm:rounded-2xl shadow-2xl">
        <div className="px-4 py-3 border-b border-white/10 flex items-center gap-3">
          <button
            type="button"
            onClick={cancel}
            disabled={submitting}
            title="Cancel"
            className="p-1 text-[#888] hover:text-white disabled:opacity-40 cursor-pointer"
          >
            ✕
          </button>
          <div className="text-sm font-semibold text-white">{title}</div>
        </div>

        <div className="flex-1 overflow-y-auto p-4 space-y-6">
          {ask
            ? ask.questions.map((q) => (
                <Question
                  key={q.id}
                  question={q}
                  draft={askDraft[q.id] ?? EMPTY_QUESTION_DRAFT}
                  disabled={submitting}
                  onChange={(next) => updateQuestion(q.id, next)}
                />
              ))
            : (
              <PlainBody
                method={req.method}
                message={req.message}
                options={req.options}
                placeholder={req.placeholder}
                value={plain}
                disabled={submitting}
                onChange={setPlain}
              />
            )}
        </div>

        <div className="px-4 py-3 border-t border-white/10 space-y-2">
          {prompt.error ? (
            <div className="text-[13px] text-[#E5484D]">{prompt.error}</div>
          ) : awaitHint ? (
            <div className="text-[13px] text-amber-400">
              Still waiting for desktop agent to confirm receipt. You can retry or cancel.
            </div>
          ) : null}
          <div className="flex gap-3">
            <button
              type="button"
              onClick={cancel}
              disabled={submitting}
              className="flex-1 py-2 rounded-lg border border-white/20 text-sm text-white hover:bg-white/5 disabled:opacity-40 cursor-pointer"
            >
              Cancel
            </button>
            <button
              type="button"
              onClick={submit}
              disabled={!submittable || submitting}
              className="flex-1 py-2 rounded-lg bg-[#4fc3f7] text-[#04222e] text-sm font-semibold hover:bg-[#38bdf8] disabled:opacity-40 cursor-pointer"
            >
              {submitting ? "Sending…" : req.method === "confirm" && !ask ? "Confirm" : "Submit"}
            </button>
          </div>
        </div>
      </div>
    </div>
  );
}

function Question({
  question: q,
  draft,
  disabled,
  onChange,
}: {
  question: AskQuestion;
  draft: QuestionDraft;
  disabled: boolean;
  onChange: (next: (d: QuestionDraft) => QuestionDraft) => void;
}) {
  const multi = isMultiQuestion(q);
  return (
    <div className="space-y-3">
      <div>
        <div className="flex items-start gap-2">
          <div className="flex-1 text-[15px] text-white whitespace-pre-wrap">{q.prompt}</div>
          {q.required && <span className="text-[11px] text-[#4fc3f7] mt-1">required</span>}
          {multi && <span className="text-[11px] text-[#888] mt-1">multi</span>}
        </div>
        {q.label && q.label !== q.prompt && <div className="text-[11px] text-[#888] mt-0.5">{q.label}</div>}
      </div>

      {q.options.map((o) => {
        const selected = draft.selected.includes(o.value);
        return (
          <button
            key={o.value}
            type="button"
            disabled={disabled}
            onClick={() => onChange((d) => toggleOption(d, o.value, multi))}
            aria-pressed={selected}
            className={`w-full text-left rounded-xl px-3 py-2.5 border transition-colors cursor-pointer disabled:cursor-default ${
              selected ? "border-[#4fc3f7] bg-[#4fc3f7]/10" : "border-white/10 bg-white/[0.03] hover:bg-white/[0.06]"
            }`}
          >
            <div className="flex items-center gap-2.5">
              <span className={`text-base ${selected ? "text-[#4fc3f7]" : "text-[#666]"}`}>
                {multi ? (selected ? "☑" : "☐") : selected ? "◉" : "○"}
              </span>
              <span className="text-sm font-semibold text-white">{o.label}</span>
            </div>
            {o.description && <div className="text-[13px] text-[#999] mt-1 pl-7">{o.description}</div>}
            {q.type === "preview" && o.preview && (
              <pre className="mt-2 ml-7 p-2.5 rounded-lg bg-black/60 border border-white/10 text-xs text-white/85 font-mono whitespace-pre-wrap break-words max-h-80 overflow-y-auto">
                {o.preview}
              </pre>
            )}
          </button>
        );
      })}

      <input
        type="text"
        value={draft.custom}
        disabled={disabled}
        onChange={(e) => {
          const custom = e.target.value;
          onChange((d) => ({ ...d, custom }));
        }}
        placeholder="Type your own…"
        className="w-full rounded-lg bg-black/40 border border-white/15 px-3 py-2 text-sm text-white placeholder:text-[#555] outline-none focus:border-[#4fc3f7]/60"
      />
      <input
        type="text"
        value={draft.note}
        disabled={disabled}
        onChange={(e) => {
          const note = e.target.value;
          onChange((d) => ({ ...d, note }));
        }}
        placeholder="Add a note (optional)"
        className="w-full rounded-lg bg-black/20 border border-white/10 px-3 py-1.5 text-xs text-white placeholder:text-[#555] outline-none focus:border-[#4fc3f7]/60"
      />
    </div>
  );
}

function PlainBody({
  method,
  message,
  options,
  placeholder,
  value,
  disabled,
  onChange,
}: {
  method: PendingPrompt["request"]["method"];
  message?: string;
  options: string[];
  placeholder?: string;
  value: string;
  disabled: boolean;
  onChange: (v: string) => void;
}) {
  return (
    <div className="space-y-4">
      {message && <div className="text-[15px] text-white whitespace-pre-wrap">{message}</div>}
      {method === "select" &&
        options.map((opt) => (
          <label key={opt} className="flex items-center gap-2.5 text-sm text-white cursor-pointer">
            <input
              type="radio"
              name="extension-ui-select"
              checked={value === opt}
              disabled={disabled}
              onChange={() => onChange(opt)}
            />
            {opt}
          </label>
        ))}
      {(method === "input" || method === "editor") && (
        <textarea
          value={value}
          disabled={disabled}
          rows={method === "editor" ? 10 : 5}
          placeholder={placeholder ?? ""}
          onChange={(e) => onChange(e.target.value)}
          className="w-full rounded-lg bg-black/40 border border-white/15 px-3 py-2 text-sm text-white font-mono placeholder:text-[#555] outline-none focus:border-[#4fc3f7]/60"
        />
      )}
      {method === "confirm" && <div className="text-sm text-[#aaa]">Please confirm.</div>}
    </div>
  );
}
