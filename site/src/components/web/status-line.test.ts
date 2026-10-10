import { test } from "node:test";
import assert from "node:assert/strict";
import {
  contextText,
  contextTone,
  costText,
  formatCount,
  gitCounts,
  modelSegment,
  parseStatusLine,
  runElapsedText,
  statusLineText,
} from "./status-line.ts";

// `status_line` frame the patched extension sent from a scratch omp after one
// turn; the terminal footer at that moment (nerd glyphs dropped):
//   π · Opus 5.5 · xhi · rp-sl/proj · main *1 +1 ?2 · 1.5%/1M · 0.01
const FRAME = {
  type: "status_line",
  cwd: "/tmp/rp-sl/proj",
  path: "rp-sl/proj",
  scratch: true,
  git: { branch: "main", staged: 1, unstaged: 1, untracked: 2 },
  context: { tokens: 14722, window: 1000000, percent: 1.4722000000000002 },
  cost: { total: 0.0064716, subagents: 0, subscription: true, premium_requests: 0 },
  run_started_at: null,
  ts: 1791609929972,
};

test("parses a status_line frame; anything else is ignored", () => {
  const line = parseStatusLine(FRAME);
  assert.deepEqual(line, {
    cwd: "/tmp/rp-sl/proj",
    path: "rp-sl/proj",
    scratch: true,
    git: { branch: "main", staged: 1, unstaged: 1, untracked: 2 },
    context: { tokens: 14722, window: 1000000, percent: 1.4722000000000002 },
    cost: { total: 0.0064716, subagents: 0, subscription: true, premiumRequests: 0 },
    runStartedAt: null,
  });
  assert.equal(parseStatusLine({ type: "agent_activity", jobs: [] }), null);
  assert.equal(parseStatusLine({ type: "status_line" }), null);
  // Outside a repo, and with an unknown percentage.
  const bare = parseStatusLine({ ...FRAME, git: null, context: { tokens: 0, window: 200000, percent: null } });
  assert.equal(bare?.git, null);
  assert.equal(bare?.context.percent, null);
});

test("the row reads like the terminal footer", () => {
  const line = parseStatusLine(FRAME)!;
  assert.equal(
    statusLineText(line, "Claude Opus 5.5", "xhigh", 0),
    "Opus 5.5 · xhi · rp-sl/proj · main *1 +1 ?2 · 1.5%/1M · 0.01"
  );
  // The user's terminal: `Opus 5.5 · xhi · ~/Documents/remote_pi · main · 35.3%/1M`.
  const user = parseStatusLine({
    ...FRAME,
    cwd: "/home/leo/Documents/remote_pi",
    path: "~/Documents/remote_pi",
    scratch: false,
    git: { branch: "main", staged: 0, unstaged: 0, untracked: 0 },
    context: { tokens: 353000, window: 1000000, percent: 35.3 },
    cost: { total: 0, subagents: 0, subscription: false, premium_requests: 0 },
  })!;
  assert.equal(statusLineText(user, "Claude Opus 5.5", "xhigh", 0), "Opus 5.5 · xhi · ~/Documents/remote_pi · main · 35.3%/1M");
  // Mid-run: the π segment's timer leads the row.
  const running = { ...user, runStartedAt: 1_000 };
  assert.equal(statusLineText(running, "Claude Opus 5.5", "xhigh", 13_500), "12s · Opus 5.5 · xhi · ~/Documents/remote_pi · main · 35.3%/1M");
});

test("model + thinking use the Home tile labels", () => {
  assert.deepEqual(modelSegment("Claude Opus 5.5", "xhigh"), { model: "Opus 5.5", thinking: "xhi" });
  assert.deepEqual(modelSegment("Claude Opus 5.5", "auto"), { model: "Opus 5.5", thinking: "auto" });
  assert.deepEqual(modelSegment("gpt-oss-20b", null), { model: "GPT Oss 20b", thinking: null });
  assert.equal(modelSegment(null, "high"), null);
});

test("context: toFixed(1) percent over omp's compact window", () => {
  // Captured: 13121 / 1M at session start, 14722 after one turn.
  assert.equal(contextText({ tokens: 13121, window: 1000000, percent: 1.3121 }), "1.3%/1M");
  assert.equal(contextText({ tokens: 14722, window: 1000000, percent: 1.4722000000000002 }), "1.5%/1M");
  assert.equal(contextText({ tokens: 353000, window: 1000000, percent: 35.3 }), "35.3%/1M");
  assert.equal(contextText({ tokens: 50000, window: 200000, percent: 25 }), "25.0%/200K");
  assert.equal(contextText({ tokens: 0, window: 272000, percent: null }), "272K");
  assert.equal(contextText({ tokens: 4321, window: 0, percent: null }), "4.3K/?");
});

test("formatCount matches omp `_e`", () => {
  assert.equal(formatCount(950), "950");
  assert.equal(formatCount(1000), "1K");
  assert.equal(formatCount(1500), "1.5K");
  assert.equal(formatCount(13121), "13K");
  assert.equal(formatCount(1048576), "1M");
  assert.equal(formatCount(1050000), "1.1M");
  assert.equal(formatCount(2_000_000_000), "2B");
});

test("context colour tier: the 1M window turns red-orange early", () => {
  assert.equal(contextTone(1.5, 1000000), "normal");
  assert.equal(contextTone(15, 1000000), "warning");   // 150K tokens
  assert.equal(contextTone(35.3, 1000000), "purple");  // past 270K: omp's thinkingHigh colour
  assert.equal(contextTone(50, 1000000), "error");     // 500K
  assert.equal(contextTone(49, 200000), "normal");
  assert.equal(contextTone(72, 200000), "purple");
  assert.equal(contextTone(null, 1000000), "normal");
});

test("git counts in omp's order", () => {
  assert.deepEqual(gitCounts({ branch: "main", staged: 1, unstaged: 1, untracked: 2 }).map((c) => c.text), ["*1", "+1", "?2"]);
  assert.deepEqual(gitCounts({ branch: "detached", staged: 0, unstaged: 0, untracked: 0 }), []);
});

test("cost: subscription icon, metered dollars, subagents, hidden at zero", () => {
  assert.deepEqual(costText({ total: 0.0064716, subagents: 0, subscription: true, premiumRequests: 0 }), { subscriptionIcon: true, text: "0.01" });
  assert.deepEqual(costText({ total: 0, subagents: 0, subscription: true, premiumRequests: 0 }), { subscriptionIcon: true, text: "" });
  assert.deepEqual(costText({ total: 1.234, subagents: 0.5, subscription: false, premiumRequests: 3 }), { subscriptionIcon: false, text: "$1.23 (+0.50) ★ 3" });
  assert.equal(costText({ total: 0, subagents: 0, subscription: false, premiumRequests: 0 }), null);
});

test("run timer like omp's π segment", () => {
  assert.equal(runElapsedText(12_900), "12s");
  assert.equal(runElapsedText(185_000), "3m");
  assert.equal(runElapsedText(7_300_000), "2h");
  assert.equal(runElapsedText(500 * 3_600_000), "99h");
});
