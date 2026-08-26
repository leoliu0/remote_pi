"use client";

import React, { useState } from "react";

interface MarkdownRendererProps {
  content: string;
  isStreaming?: boolean;
}

export function MarkdownRenderer({ content, isStreaming }: MarkdownRendererProps) {
  const [copiedIndex, setCopiedIndex] = useState<number | null>(null);

  const handleCopy = (code: string, idx: number) => {
    navigator.clipboard.writeText(code);
    setCopiedIndex(idx);
    setTimeout(() => setCopiedIndex(null), 2000);
  };

  // Parse code blocks vs markdown text
  const parts: Array<{ type: "code" | "text"; content: string; language?: string }> = [];
  const codeBlockRegex = /```(\w*)\n([\s\S]*?)```/g;
  let lastIndex = 0;
  let match: RegExpExecArray | null;

  while ((match = codeBlockRegex.exec(content)) !== null) {
    if (match.index > lastIndex) {
      parts.push({
        type: "text",
        content: content.slice(lastIndex, match.index),
      });
    }
    parts.push({
      type: "code",
      language: match[1] || "text",
      content: match[2],
    });
    lastIndex = match.index + match[0].length;
  }

  if (lastIndex < content.length) {
    parts.push({
      type: "text",
      content: content.slice(lastIndex),
    });
  }

  if (parts.length === 0 && content) {
    parts.push({ type: "text", content });
  }

  return (
    <div className="space-y-3 text-sm leading-relaxed text-[#F0F0F0] font-[family-name:var(--ff-body)]">
      {parts.map((part, idx) => {
        if (part.type === "code") {
          return (
            <div
              key={idx}
              className="my-3 rounded-xl bg-[#050505] border border-white/10 overflow-hidden shadow-xs font-mono text-xs"
            >
              <div className="px-3.5 py-1.5 bg-white/[0.03] border-b border-white/5 flex items-center justify-between text-[#888]">
                <span className="text-[11px] font-semibold uppercase tracking-wider text-[#4fc3f7]">
                  {part.language}
                </span>
                <button
                  type="button"
                  onClick={() => handleCopy(part.content, idx)}
                  className="px-2 py-0.5 rounded hover:bg-white/10 text-xs transition-colors flex items-center gap-1 cursor-pointer text-[#a3a3a3] hover:text-white"
                >
                  {copiedIndex === idx ? (
                    <span className="text-[#6CD28A]">✓ Copied</span>
                  ) : (
                    <span>Copy</span>
                  )}
                </button>
              </div>
              <pre className="p-3.5 overflow-x-auto text-[#E0E0E0] leading-relaxed">
                <code>{part.content}</code>
              </pre>
            </div>
          );
        }

        // Render formatted text blocks
        return (
          <div key={idx} className="space-y-2">
            {part.content.split("\n\n").map((paragraph, pIdx) => {
              const trimmed = paragraph.trim();
              if (!trimmed) return null;

              // Headings
              if (trimmed.startsWith("### ")) {
                return (
                  <h3 key={pIdx} className="text-sm font-bold text-white mt-3 mb-1 font-mono flex items-center gap-1.5">
                    <span className="text-[#4fc3f7]">#</span>
                    <span>{renderInline(trimmed.slice(4))}</span>
                  </h3>
                );
              }
              if (trimmed.startsWith("## ")) {
                return (
                  <h2 key={pIdx} className="text-base font-bold text-white mt-4 mb-1.5 font-mono">
                    {renderInline(trimmed.slice(3))}
                  </h2>
                );
              }
              if (trimmed.startsWith("# ")) {
                return (
                  <h1 key={pIdx} className="text-lg font-bold text-white mt-4 mb-2 font-mono">
                    {renderInline(trimmed.slice(2))}
                  </h1>
                );
              }

              // Blockquotes
              if (trimmed.startsWith("> ")) {
                return (
                  <blockquote
                    key={pIdx}
                    className="border-l-2 border-[#4fc3f7]/50 pl-3 py-1 text-[#a3a3a3] italic bg-white/[0.02] rounded-r-lg my-1.5"
                  >
                    {renderInline(trimmed.slice(2))}
                  </blockquote>
                );
              }

              // List items
              if (trimmed.startsWith("- ") || trimmed.startsWith("* ") || /^\d+\.\s/.test(trimmed)) {
                const lines = trimmed.split("\n");
                return (
                  <ul key={pIdx} className="space-y-1 my-1.5 pl-1">
                    {lines.map((line, lIdx) => {
                      const listText = line.replace(/^[-*]\s+|\d+\.\s+/, "");
                      return (
                        <li key={lIdx} className="flex items-start gap-2 text-[#E0E0E0]">
                          <span className="text-[#4fc3f7] mt-1 text-[10px] select-none">•</span>
                          <span className="flex-1">{renderInline(listText)}</span>
                        </li>
                      );
                    })}
                  </ul>
                );
              }

              // Plain paragraph
              return (
                <p key={pIdx} className="text-[#E0E0E0] leading-relaxed">
                  {renderInline(paragraph)}
                </p>
              );
            })}
          </div>
        );
      })}

      {isStreaming && (
        <span className="inline-block w-2 h-4 ml-1 bg-[#00D4FF] animate-pulse align-middle" />
      )}
    </div>
  );
}

// Render bold, italic, inline code
function renderInline(text: string): React.ReactNode {
  const parts: React.ReactNode[] = [];
  const inlineRegex = /(`[^`]+`|\*\*[^*]+\*\*|\*[^*]+\*)/g;
  let lastIndex = 0;
  let match: RegExpExecArray | null;

  while ((match = inlineRegex.exec(text)) !== null) {
    if (match.index > lastIndex) {
      parts.push(text.slice(lastIndex, match.index));
    }
    const token = match[0];
    if (token.startsWith("`") && token.endsWith("`")) {
      parts.push(
        <code
          key={match.index}
          className="px-1.5 py-0.5 rounded bg-white/10 text-[#4fc3f7] font-mono text-[12.5px]"
        >
          {token.slice(1, -1)}
        </code>
      );
    } else if (token.startsWith("**") && token.endsWith("**")) {
      parts.push(
        <strong key={match.index} className="font-semibold text-white">
          {token.slice(2, -2)}
        </strong>
      );
    } else if (token.startsWith("*") && token.endsWith("*")) {
      parts.push(
        <em key={match.index} className="italic text-[#E0E0E0]">
          {token.slice(1, -1)}
        </em>
      );
    }
    lastIndex = match.index + token.length;
  }

  if (lastIndex < text.length) {
    parts.push(text.slice(lastIndex));
  }

  return parts.length === 0 ? text : <>{parts}</>;
}
