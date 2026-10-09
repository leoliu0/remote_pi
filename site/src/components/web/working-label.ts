import type { WebChatMessage } from "./web-client";

// Port of the phone's working banner label (app/lib/ui/chat/chat_page.dart):
// show what the agent is doing right now, the same text the terminal shows.
// omp tools carry an intent (`i`, e.g. "Waiting for sleep completion") that the
// TUI prints; otherwise derive a label from the tool and its main argument.
// Only tools after the latest user message count, so an older turn's intent
// never leaks into a fresh one.

function truncate(s: string, max = 35): string {
  const clean = s.trim().replace(/\s+/g, " ");
  return clean.length <= max ? clean : `${clean.slice(0, max)}…`;
}

function str(args: Record<string, unknown> | null | undefined, key: string): string | null {
  const v = args?.[key];
  return typeof v === "string" ? v : null;
}

export function workingLabel(messages: readonly WebChatMessage[]): string {
  for (let i = messages.length - 1; i >= 0; i--) {
    const m = messages[i];
    if (!m) continue;
    if (m.role === "user") break;
    if (m.role !== "tool" || !m.tool) continue;
    const args = m.tool.args;
    const intent = str(args, "i")?.trim();
    if (intent) return intent;
    const path = str(args, "path");
    const command = str(args, "command") ?? m.tool.command ?? null;
    switch (m.tool.tool.toLowerCase()) {
      case "read": return path ? `Reading ${truncate(path)}` : "Reading file…";
      case "bash": return command ? `Running: ${truncate(command)}` : "Running command…";
      case "edit": return path ? `Editing ${truncate(path)}` : "Editing file…";
      case "write": return path ? `Writing ${truncate(path)}` : "Writing file…";
      case "grep": {
        const pattern = str(args, "pattern");
        return pattern ? `Searching "${truncate(pattern)}"` : "Searching files…";
      }
      case "glob": return path ? `Finding: ${truncate(path)}` : "Finding files…";
      case "task": return "Running subagents…";
      case "eval": {
        const title = str(args, "title");
        return title ? `Evaluating: ${truncate(title)}` : "Evaluating code…";
      }
      case "hub": return "Coordinating mesh agents…";
      case "todo": return "Updating tasks…";
      case "ask": return "Waiting for user input…";
      default: return `Executing ${m.tool.tool}…`;
    }
  }
  return "Working…";
}
