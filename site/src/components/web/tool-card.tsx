"use client";

import type { ToolCallData } from "./web-client";
import { argRows, bashCard, toolSummary } from "./tool-output";

const STATUS_COLOR: Record<ToolCallData["status"], string> = {
  pending: "#00D4FF",
  done: "#6CD28A",
  error: "#E5484D",
};

const STATUS_LABEL: Record<ToolCallData["status"], string> = {
  pending: "RUNNING",
  done: "DONE",
  error: "FAILED",
};

const STATUS_ICON: Record<ToolCallData["status"], string> = {
  pending: "⏳",
  done: "✓",
  error: "✗",
};

const ERROR_TEXT = "text-[#E5484D]";

/** Brief mode: one pill with the tool name and its intent (else command). */
export function ToolPill({ tool, onExpand }: { tool: ToolCallData; onExpand: () => void }) {
  const color = STATUS_COLOR[tool.status];
  const summary = toolSummary(tool.args);
  return (
    <div className="my-1.5 max-w-[95%] sm:max-w-[90%]">
      <button
        type="button"
        onClick={onExpand}
        className="w-full text-left rounded-lg bg-[#050505] px-3 py-1.5 transition-all flex items-center justify-between gap-2 cursor-pointer group hover:bg-[#0f0f0f]"
        style={{ border: `1px solid ${color}55` }}
      >
        <div className="flex items-center gap-2 min-w-0 font-mono text-xs">
          <span className="font-bold shrink-0" style={{ color }}>
            &gt;_ {tool.tool.toUpperCase()}
          </span>
          {summary ? (
            <span className="text-[#A3A3A3] font-normal truncate text-[11px] max-w-[200px] sm:max-w-[420px]">
              {summary}
            </span>
          ) : (
            <span className="text-[#666] italic text-[11px]">
              {tool.status === "pending" ? "running…" : "completed"}
            </span>
          )}
        </div>
        <div className="flex items-center gap-2 shrink-0 font-mono text-xs">
          <span className="font-bold text-xs" style={{ color }}>
            {STATUS_ICON[tool.status]}
          </span>
          <span className="text-[#666] group-hover:text-white transition-colors text-[10px]">▾</span>
        </div>
      </button>
    </div>
  );
}

function OutputLabel() {
  return (
    <div className="flex items-center gap-2 text-[10px] tracking-wider text-[#6B6B6B] font-mono">
      <span className="h-px flex-1 bg-[#1F1F1F]" />
      <span>Output</span>
      <span className="h-px flex-1 bg-[#1F1F1F]" />
    </div>
  );
}

function BashBody({ tool }: { tool: ToolCallData }) {
  const card = bashCard(tool.args, tool.output ?? null);
  return (
    <div className="p-3 bg-[#050505] font-mono text-xs space-y-2">
      <pre className="whitespace-pre-wrap break-words text-white">
        <span className="text-[#6CD28A] select-none">$ </span>
        {card.command}
      </pre>
      {card.intent && <div className="text-[#8A8A8A] whitespace-pre-wrap break-words">{card.intent}</div>}
      {card.cwd && <div className="text-[#6B6B6B] whitespace-pre-wrap break-all">in {card.cwd}</div>}
      {card.body !== null && (
        <>
          <OutputLabel />
          <pre
            className={`whitespace-pre-wrap break-words max-h-96 overflow-y-auto ${
              tool.status === "error" ? ERROR_TEXT : "text-[#C8C8C8]"
            }`}
          >
            {card.body}
          </pre>
        </>
      )}
      {(card.footer.text || card.footer.exit) && (
        <div className="text-[11px] text-[#6B6B6B]">
          {card.footer.text}
          {card.footer.exit && (
            <>
              {card.footer.text && " | "}
              <span className={ERROR_TEXT}>{card.footer.exit}</span>
            </>
          )}
        </div>
      )}
    </div>
  );
}

function GenericBody({ tool }: { tool: ToolCallData }) {
  const rows = argRows(tool.args);
  return (
    <div className="p-3 bg-[#050505] font-mono text-xs space-y-2">
      {rows.length > 0 && (
        <div className="grid grid-cols-[max-content_1fr] gap-x-3 gap-y-1">
          {rows.map((r) => (
            <div key={r.key} className="contents">
              <span className="text-[#6B6B6B]">{r.key}</span>
              <pre className="whitespace-pre-wrap break-words text-white/85 max-h-60 overflow-y-auto">{r.value}</pre>
            </div>
          ))}
        </div>
      )}
      {tool.diff?.hunks && (
        <div className="space-y-0.5 overflow-x-auto">
          {tool.diff.hunks.map((line, i) => (
            <div
              key={i}
              className={`px-2 py-0.5 rounded ${
                line.startsWith("+")
                  ? "bg-[#6CD28A]/15 text-[#6CD28A] font-semibold"
                  : line.startsWith("-")
                  ? "bg-[#E5484D]/15 text-[#E5484D]"
                  : "text-[#8A8A8A]"
              }`}
            >
              {line}
            </div>
          ))}
        </div>
      )}
      {tool.output !== undefined ? (
        <>
          <OutputLabel />
          <pre
            className={`whitespace-pre-wrap break-words max-h-96 overflow-y-auto ${
              tool.status === "error" ? ERROR_TEXT : "text-[#C8C8C8]"
            }`}
          >
            {tool.output.trim() === "" ? "(no output)" : tool.output}
          </pre>
        </>
      ) : (
        <div className="text-[11px] text-[#6B6B6B]">Running…</div>
      )}
    </div>
  );
}

/** Full mode: the whole call — bash like the terminal, other tools as args + output. */
export function ToolFullCard({ tool, onCollapse }: { tool: ToolCallData; onCollapse?: () => void }) {
  const color = STATUS_COLOR[tool.status];
  return (
    <div className="my-2 max-w-[95%] sm:max-w-[90%]">
      <div
        className="rounded-xl bg-[#0A0A0A] overflow-hidden transition-all"
        style={{ border: `1px solid ${color}`, boxShadow: `0 0 16px ${color}1F` }}
      >
        <div
          className={`px-3.5 py-2 bg-white/[0.02] border-b border-[#1A1A1A] flex items-center justify-between ${
            onCollapse ? "cursor-pointer" : ""
          }`}
          onClick={onCollapse}
        >
          <div className="flex items-center gap-2 font-mono text-xs font-bold" style={{ color }}>
            <span>&gt;_</span>
            <span className="tracking-wide uppercase">{tool.tool}</span>
          </div>
          <div className="flex items-center gap-2">
            <span className="text-[11px] font-mono font-bold tracking-wider" style={{ color }}>
              {STATUS_LABEL[tool.status]}
            </span>
            {onCollapse && <span className="text-[#888] text-[10px]">▲</span>}
          </div>
        </div>
        {tool.tool.toLowerCase() === "bash" ? <BashBody tool={tool} /> : <GenericBody tool={tool} />}
      </div>
    </div>
  );
}
