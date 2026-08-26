import { NextRequest, NextResponse } from "next/server";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import readline from "node:readline";
import { createHash } from "node:crypto";

function roomIdForCwd(cwd: string): string {
  let target: string;
  try { target = fs.realpathSync(cwd); } catch { target = cwd; }
  return createHash("sha256").update(target).digest("base64url").slice(0, 12);
}

interface ParsedMessage {
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
}

async function parseJsonlFile(filePath: string, maxMessages = 200): Promise<ParsedMessage[]> {
  const fileStream = fs.createReadStream(filePath);
  const rl = readline.createInterface({ input: fileStream, crlfDelay: Infinity });

  const rawMessages: ParsedMessage[] = [];
  let count = 0;

  for await (const line of rl) {
    if (!line.trim()) continue;
    try {
      const item = JSON.parse(line);

      // ── Format 1: Claude Code (.claude/projects/*.jsonl) ─────────────────────
      if (item.type === "user" && item.message) {
        const m = item.message;
        let text = "";
        if (typeof m.content === "string") {
          text = m.content;
        } else if (Array.isArray(m.content)) {
          for (const c of m.content) {
            if (c.type === "text" && c.text) {
              text += (text ? "\n" : "") + c.text;
            }
          }
        }
        if (text && !text.startsWith("<command-message>") && !text.startsWith("<local-command-caveat>")) {
          rawMessages.push({
            id: item.uuid || `user_${count++}`,
            role: "user",
            text,
            timestamp: new Date(item.timestamp || Date.now()).getTime(),
            status: "sent",
          });
        }
      } else if (item.message && (item.message.role === "assistant" || item.message.type === "message")) {
        const m = item.message;
        let text = "";
        let toolCall: any = null;

        if (Array.isArray(m.content)) {
          for (const c of m.content) {
            if (c.type === "text" && c.text) {
              text += (text ? "\n" : "") + c.text;
            } else if (c.type === "tool_use") {
              toolCall = c;
            }
          }
        } else if (typeof m.content === "string") {
          text = m.content;
        }

        if (toolCall) {
          rawMessages.push({
            id: toolCall.id || `tool_${count++}`,
            role: "tool",
            text: `${toolCall.name}: ${JSON.stringify(toolCall.input || {})}`,
            timestamp: new Date(item.timestamp || Date.now()).getTime(),
            tool: {
              id: toolCall.id,
              tool: toolCall.name,
              args: toolCall.input || {},
              command: typeof toolCall.input?.command === "string" ? toolCall.input.command : undefined,
              status: "done",
            },
          });
        }

        if (text) {
          rawMessages.push({
            id: m.id || item.uuid || `asst_${count++}`,
            role: "assistant",
            text,
            timestamp: new Date(item.timestamp || Date.now()).getTime(),
          });
        }
      } else if (item.type === "user" && item.toolUseResult) {
        // Tool result attach
        const toolUseId = item.message?.content?.[0]?.tool_use_id;
        const resContent = typeof item.toolUseResult === "string" ? item.toolUseResult : JSON.stringify(item.toolUseResult);
        if (toolUseId) {
          const existing = rawMessages.find((x) => x.tool && x.tool.id === toolUseId);
          if (existing && existing.tool) {
            existing.tool.result = resContent;
            existing.tool.status = "done";
          }
        }
      }

      // ── Format 2: Native Pi Agent (.pi/agent/sessions/*.jsonl) ───────────────
      if (item.type === "message" && item.message) {
        const m = item.message;
        const ts = m.timestamp || new Date(item.timestamp || Date.now()).getTime();

        if (m.role === "user") {
          const text = Array.isArray(m.content)
            ? m.content.map((c: any) => c.text || "").join("\n")
            : typeof m.content === "string" ? m.content : "";
          if (text) {
            rawMessages.push({
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
              } else if (c.type === "toolCall") {
                toolCall = c;
              }
            }
          } else if (typeof m.content === "string") {
            text = m.content;
          }

          if (toolCall) {
            rawMessages.push({
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
            rawMessages.push({
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
          const existing = rawMessages.find((x) => x.tool && x.tool.id === toolCallId);
          if (existing && existing.tool) {
            existing.tool.result = content;
            existing.tool.status = m.isError ? "rejected" : "done";
            existing.tool.error = m.isError ? content : undefined;
          }
        } else if (m.role === "compaction") {
          rawMessages.push({
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

  // Return the latest messages (slice to maxMessages to keep UI responsive)
  return rawMessages.slice(-maxMessages);
}

function findJsonlFilesForCwd(cwdParam: string | null, roomId: string | null): string[] {
  const home = os.homedir();
  const searchDirs = [
    path.join(home, ".claude", "projects"),
    path.join(home, ".pi", "agent", "sessions"),
  ];

  const foundFiles: string[] = [];

  for (const baseDir of searchDirs) {
    if (!fs.existsSync(baseDir)) continue;
    try {
      const entries = fs.readdirSync(baseDir);
      for (const entry of entries) {
        const full = path.join(baseDir, entry);
        if (!fs.statSync(full).isDirectory()) continue;

        // Check if directory name matches cwd
        let isMatch = false;
        if (cwdParam) {
          const normCwd = cwdParam.replace(/[\/\\]/g, "-").replace(/^-+|-+$/g, "").toLowerCase();
          const normEntry = entry.replace(/^-+|-+$/g, "").toLowerCase();
          if (normEntry === normCwd || normEntry.replace(/_/g, "-") === normCwd.replace(/_/g, "-")) {
            isMatch = true;
          }
        }
        const files = fs.readdirSync(full).filter((x) => x.endsWith(".jsonl"));
        if (files.length > 0) {
          if (isMatch) {
            for (const f of files) foundFiles.push(path.join(full, f));
            continue;
          }

          // Inspect first line of newest file
          const newest = files.sort().pop()!;
          const firstLine = fs.readFileSync(path.join(full, newest), "utf8").split("\n")[0];
          try {
            const meta = JSON.parse(firstLine);
            if (meta?.cwd) {
              if (cwdParam && (meta.cwd === cwdParam || meta.cwd.toLowerCase() === cwdParam.toLowerCase())) {
                for (const f of files) foundFiles.push(path.join(full, f));
              } else if (roomId && roomIdForCwd(meta.cwd) === roomId) {
                for (const f of files) foundFiles.push(path.join(full, f));
              }
            }
          } catch {}
        }
      }
    } catch {}
  }

  return foundFiles;
}

export async function GET(req: NextRequest) {
  try {
    const { searchParams } = new URL(req.url);
    const roomId = searchParams.get("roomId");
    const cwdParam = searchParams.get("cwd");

    const matchedFiles = findJsonlFilesForCwd(cwdParam, roomId);

    if (matchedFiles.length === 0) {
      return NextResponse.json({ ok: true, count: 0, messages: [] });
    }

    // Sort by file modified time and parse the latest file
    matchedFiles.sort((a, b) => {
      try {
        return fs.statSync(a).mtimeMs - fs.statSync(b).mtimeMs;
      } catch {
        return 0;
      }
    });

    const targetFile = matchedFiles[matchedFiles.length - 1];
    const messages = await parseJsonlFile(targetFile, 150);

    return NextResponse.json({
      ok: true,
      count: messages.length,
      file: path.basename(targetFile),
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
