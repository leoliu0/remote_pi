import { test } from "node:test";
import assert from "node:assert/strict";
import { slashMenuItems } from "./slash-commands.ts";

// pi-extension index.ts:6119-6123 `skills_list.skills: {name, description}[]`.
test("the Pi's skills follow the commands, never listed twice (app filterSlashCommands)", () => {
  const items = slashMenuItems([
    { name: "pdf", description: "Read and create PDFs" },
    { name: "plan", description: "a skill named like a command" },
  ]);
  assert.deepEqual(items.slice(-1), [{ cmd: "/pdf", desc: "Read and create PDFs", category: "Skill" }]);
  assert.equal(items.filter((i) => i.cmd === "/plan").length, 1);
  assert.equal(items.find((i) => i.cmd === "/plan")?.category, "Command");
  assert.ok(slashMenuItems([]).every((i) => i.category === "Command"));
});
