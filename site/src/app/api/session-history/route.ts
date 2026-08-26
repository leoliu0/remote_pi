import { NextRequest, NextResponse } from "next/server";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { createHash } from "node:crypto";

function roomIdForCwd(cwd: string): string {
  let target: string;
  try { target = fs.realpathSync(cwd); } catch { target = cwd; }
  return createHash("sha256").update(target).digest("base64url").slice(0, 12);
}

export async function GET(req: NextRequest) {
  try {
    const { searchParams } = new URL(req.url);
    const roomId = searchParams.get("roomId");
    const cwdParam = searchParams.get("cwd");

    const sessionsDir = path.join(os.homedir(), ".pi", "agent", "sessions");
    if (!fs.existsSync(sessionsDir)) {
      return NextResponse.json({ events: [], messages: [] });
    }

    const folders = fs.readdirSync(sessionsDir);
    let matchedFolder: string | null = null;

    // 1. Match folder by exact cwd or by roomId
    for (const f of folders) {
      const full = path.join(sessionsDir, f);
      try {
        if (fs.statSync(full).isDirectory()) {
          const files = fs.readdirSync(full).filter((x) => x.endsWith(".jsonl"));
          if (files.length > 0) {
            // Read first line to inspect cwd
            const newest = files.sort().pop()!;
            const firstLine = fs.readFileSync(path.join(full, newest), "utf8").split("\n")[0];
            const meta = JSON.parse(firstLine);
            if (meta?.cwd) {
              if (cwdParam && (meta.cwd === cwdParam || meta.cwd.toLowerCase() === cwdParam.toLowerCase())) {
                matchedFolder = full;
                break;
              }
              if (roomId && roomIdForCwd(meta.cwd) === roomId) {
                matchedFolder = full;
                break;
              }
            }
          }
        }
      } catch {}
    }

    // Fallback: search if cwdParam matches directory name encoding
    if (!matchedFolder && cwdParam) {
      const sanitized = "--" + cwdParam.replace(/[\/\\]/g, "-").replace(/^-+|-+$/g, "") + "--";
      const direct = path.join(sessionsDir, sanitized);
      if (fs.existsSync(direct)) {
        matchedFolder = direct;
      }
    }

    if (!matchedFolder) {
      return NextResponse.json({ events: [], messages: [] });
    }

    // Read the newest .jsonl session log
    const files = fs.readdirSync(matchedFolder).filter((x) => x.endsWith(".jsonl")).sort();
    if (files.length === 0) {
      return NextResponse.json({ events: [], messages: [] });
    }

    const newestFile = files[files.length - 1];
    const rawLines = fs.readFileSync(path.join(matchedFolder, newestFile), "utf8").split("\n");

    const messages: Array<{
      id: string;
      role: "user" | "assistant" | "tool" | "compaction";
      text: string;
      timestamp: number;
      tool?: {
        id: string;
        tool: string;
        args: Record<string, unknown>;
        command?: string;
        status: "pending" | "done" | "rejected";
        result?: unknown;
        error?: string;
      };
      tokensBefore?: number;
      status?: "sent" | "failed";
    }> = [];

    for (const line of rawLines) {
      if (!line.trim()) continue;
      try {
        const item = JSON.parse(line);
        if (item.type === "message" && item.message) {
          const m = item.message;
          const ts = m.timestamp || new Date(item.timestamp || Date.now()).getTime();

          if (m.role === "user") {
            const text = Array.isArray(m.content)
              ? m.content.map((c: any) => c.text || "").join("\n")
              : typeof m.content === "string" ? m.content : "";
            if (text) {
              messages.push({
                id: item.id || `user_${ts}`,
                role: "user",
                text,
                timestamp: ts,
                status: "sent",
              });
            }
          } else if (m.role === "assistant") {
            let text = "";
            let toolCall: any = null;

            if (Array.isArray(m.content)) {
              for (const c of m.content) {
                if (c.type === "text") {
                  text += (text ? "\n" : "") + c.text;
                } else if (c.type === "thinking" && c.thinking) {
                  // Keep thinking blocks accessible
                } else if (c.type === "toolCall") {
                  toolCall = c;
                }
              }
            } else if (typeof m.content === "string") {
              text = m.content;
            }

            if (toolCall) {
              messages.push({
                id: item.id || `tool_${ts}`,
                role: "tool",
                text: `${toolCall.name}: ${JSON.stringify(toolCall.arguments || {})}`,
                timestamp: ts,
                tool: {
                  id: toolCall.id,
                  tool: toolCall.name,
                  args: toolCall.arguments || {},
                  command: typeof toolCall.arguments?.command === "string" ? toolCall.arguments.command : undefined,
                  status: "done",
                },
              });
            }

            if (text) {
              messages.push({
                id: item.id || `asst_${ts}`,
                role: "assistant",
                text,
                timestamp: ts,
              });
            }
          } else if (m.role === "toolResult") {
            const toolCallId = m.toolCallId;
            const content = Array.isArray(m.content)
              ? m.content.map((c: any) => c.text || "").join("\n")
              : typeof m.content === "string" ? m.content : JSON.stringify(m.content || "");
            
            // Attach result to previous tool message if found
            const existing = messages.find((x) => x.tool && x.tool.id === toolCallId);
            if (existing && existing.tool) {
              existing.tool.result = content;
              existing.tool.status = m.isError ? "rejected" : "done";
              existing.tool.error = m.isError ? content : undefined;
            }
          } else if (m.role === "compaction") {
            messages.push({
              id: item.id || `comp_${ts}`,
              role: "compaction",
              text: m.content || "Context compacted",
              timestamp: ts,
              tokensBefore: m.tokensBefore,
            });
          }
        }
      } catch {}
    }

    return NextResponse.json({
      ok: true,
      count: messages.length,
      messages,
    });
  } catch (err: any) {
    return NextResponse.json({
      ok: false,
      error: err?.message || "Failed to load session history",
      messages: [],
    });
  }
}
