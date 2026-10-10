"use client";

import { useState } from "react";
import { MarkdownRenderer } from "./markdown-renderer";
import { splitThinking, stripThinking } from "./thinking";

/** Muted `Thinking` block: first 2 lines until clicked. */
function ThinkingBlock({ text, open }: { text: string; open: boolean }) {
  const [expanded, setExpanded] = useState(false);
  return (
    <button
      type="button"
      onClick={() => setExpanded((e) => !e)}
      aria-expanded={expanded}
      className="block w-full text-left my-2 pl-3 border-l-2 border-white/10 text-[#5A5A5A] hover:text-[#7A7A7A] cursor-pointer"
    >
      <div className="text-[11px] font-mono flex items-center gap-1.5">
        <span className="text-[10px]">{expanded ? "▾" : "▸"}</span>
        <span>{open ? "Thinking…" : "Thinking"}</span>
      </div>
      {text && (
        <div className={`mt-1 text-[12.5px] italic whitespace-pre-wrap break-words ${expanded ? "" : "line-clamp-2"}`}>
          {text}
        </div>
      )}
    </button>
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
