"use client";

import { useState } from "react";
import { MarkdownRenderer } from "./markdown-renderer";
import { splitThinking, stripThinking } from "./thinking";

/**
 * Muted `Thinking` block. With the setting on, the trace is shown in full;
 * the header collapses it to 2 lines. The trace sits outside the button so
 * it can be selected and copied.
 */
function ThinkingBlock({ text, open }: { text: string; open: boolean }) {
  const [expanded, setExpanded] = useState(true);
  return (
    <div className="my-2 pl-3 border-l-2 border-white/15 text-[#8A8A8A]">
      <button
        type="button"
        onClick={() => setExpanded((e) => !e)}
        aria-expanded={expanded}
        className="text-[12px] font-mono flex items-center gap-1.5 hover:text-[#B0B0B0] cursor-pointer"
      >
        <span className="text-[11px]">{expanded ? "▾" : "▸"}</span>
        <span>{open ? "Thinking…" : "Thinking"}</span>
      </button>
      {text && (
        <div className={`mt-1 text-[13.5px] leading-relaxed italic whitespace-pre-wrap break-words select-text ${expanded ? "" : "line-clamp-2"}`}>
          {text}
        </div>
      )}
    </div>
  );
}

/** An assistant message with its `<think>` sections shown as blocks or stripped. */
export function AssistantContent({
  text,
  isStreaming,
  showThinking,
}: {
  text: string;
  isStreaming?: boolean;
  showThinking: boolean;
}) {
  if (!showThinking) return <MarkdownRenderer content={stripThinking(text)} isStreaming={isStreaming} />;
  const segments = splitThinking(text);
  if (segments.length === 0) return <MarkdownRenderer content="" isStreaming={isStreaming} />;
  return (
    <>
      {segments.map((s, i) =>
        s.kind === "thinking" ? (
          <ThinkingBlock key={i} text={s.text} open={s.open && !!isStreaming} />
        ) : (
          <MarkdownRenderer key={i} content={s.text} isStreaming={isStreaming && i === segments.length - 1} />
        ),
      )}
    </>
  );
}
