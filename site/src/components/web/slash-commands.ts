// The composer's slash menu: built-in commands, then the skills the Pi
// reports in `skills_list` (app/lib/ui/chat/widgets/slash_commands.dart
// `filterSlashCommands`: a skill named like a command is not listed twice).

import type { WireSkill } from "./web-client";

export interface SlashMenuItem {
  cmd: string;
  desc: string;
  category: "Command" | "Skill";
}

const COMMANDS: SlashMenuItem[] = [
  { cmd: "/init", desc: "Initialize project configuration & guidelines (CLAUDE.md)", category: "Command" },
  { cmd: "/plan", desc: "Toggle plan mode (agent plans before executing)", category: "Command" },
  { cmd: "/clear", desc: "Clear the conversation context in place, keeping the session", category: "Command" },
  { cmd: "/model", desc: "Switch model for this session", category: "Command" },
  { cmd: "/help", desc: "Show available commands, skills, and usage guide", category: "Command" },
];

export function slashMenuItems(skills: readonly WireSkill[]): SlashMenuItem[] {
  const items = [...COMMANDS];
  for (const skill of skills) {
    const cmd = `/${skill.name}`;
    if (items.some((item) => item.cmd === cmd)) continue;
    items.push({ cmd, desc: skill.description, category: "Skill" });
  }
  return items;
}
