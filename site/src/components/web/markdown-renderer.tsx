"use client";

import { memo, useMemo, useState } from "react";
import ReactMarkdown, { type Components, type ExtraProps, type Options } from "react-markdown";
import remarkGfm from "remark-gfm";
import remarkMath from "remark-math";
import rehypeKatex from "rehype-katex";
import rehypeHighlight from "rehype-highlight";
import { common } from "lowlight";
import dart from "highlight.js/lib/languages/dart";
import dockerfile from "highlight.js/lib/languages/dockerfile";
import "katex/dist/katex.min.css";
import "./markdown-renderer.css";
import { prepareMarkdown } from "./markdown-text";

type HastElement = NonNullable<ExtraProps["node"]>;
type HastChild = HastElement["children"][number];

interface MarkdownRendererProps {
  content: string;
  isStreaming?: boolean;
}

// GFM (tables, task lists, strikethrough, autolinks) + math, like the phone
// app's AgentMarkdown. KaTeX runs before highlight.js so math fences become
// formulas instead of highlighted code. Raw HTML stays literal text.
const REMARK_PLUGINS: Options["remarkPlugins"] = [remarkGfm, remarkMath];
const REHYPE_PLUGINS: Options["rehypePlugins"] = [
  [rehypeKatex, { errorColor: "#ff8a80" }],
  [
    rehypeHighlight,
    {
      languages: { ...common, dart, dockerfile },
      plainText: ["text", "txt", "plain", "output", "log"],
    },
  ],
];

function hastText(node: HastChild): string {
  if (node.type === "text") return node.value;
  if (node.type === "element") return node.children.map(hastText).join("");
  return "";
}

function CopyButton({ code }: { code: string }) {
  const [copied, setCopied] = useState(false);
  return (
    <button
      type="button"
      onClick={() => {
        void navigator.clipboard?.writeText(code).then(() => {
          setCopied(true);
          setTimeout(() => setCopied(false), 1500);
        });
      }}
      className="md-copy"
      aria-label="Copy code"
    >
      {copied ? <span className="text-[#6CD28A]">✓ Copied</span> : "Copy"}
    </button>
  );
}

const COMPONENTS: Components = {
  pre({ node, children }) {
    const code = node?.children.find((c): c is HastElement => c.type === "element" && c.tagName === "code");
    const cls = code?.properties.className;
    const lang = (Array.isArray(cls) ? cls : [])
      .map(String)
      .find((c) => c.startsWith("language-"))
      ?.slice("language-".length);
    const text = code ? hastText(code).replace(/\n$/, "") : "";
    return (
      <div className="md-code">
        <div className="md-code-head">
          <span>{lang || "code"}</span>
          <CopyButton code={text} />
        </div>
        <pre>{children}</pre>
      </div>
    );
  },
  table({ children }) {
    return (
      <div className="md-table">
        <table>{children}</table>
      </div>
    );
  },
  a({ href, children }) {
    return (
      <a href={href} target="_blank" rel="noopener noreferrer">
        {children}
      </a>
    );
  },
};

export const MarkdownRenderer = memo(function MarkdownRenderer({ content, isStreaming }: MarkdownRendererProps) {
  // `<think>` sections are split out before this (thinking-block.tsx).
  const source = useMemo(() => prepareMarkdown(content), [content]);

  if (!source && !isStreaming) return null;
  return (
    <div className="md-prose">
      <ReactMarkdown remarkPlugins={REMARK_PLUGINS} rehypePlugins={REHYPE_PLUGINS} components={COMPONENTS}>
        {source}
      </ReactMarkdown>
      {isStreaming && <span className="md-cursor" aria-hidden />}
    </div>
  );
});
