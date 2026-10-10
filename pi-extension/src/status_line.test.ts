import { afterEach, describe, expect, test, vi } from "vitest";
import {
  GitStatusCache,
  STATUS_LINE_MIN_INTERVAL_MS,
  StatusLineBroadcaster,
  contextFromUsage,
  costFromUsage,
  footerPath,
  parseGitStatus,
  type PathRoots,
} from "./status_line.js";
import type { ServerMessage, StatusLineGit, StatusLineMessage } from "./protocol/types.js";

// Values captured from a scratch omp 18.8.7 (HOME=/tmp/rp-sl/home, cwd
// /tmp/rp-sl/proj, Opus 5.5 xhigh) next to the footer it printed:
//   π · ⬢ Opus 5.5 · ◕ xhi · 🗑 rp-sl/proj · ⑂ main ?2 · ◫ 1.5%/1M ⟲ · 󰙺 0.01

const identity = (p: string): string => p;
const ROOTS: PathRoots = {
  home: "/home/leo",
  scratch: ["/tmp", "/home/leo/tmp", "/tmp", "/var/tmp"],
  work: ["/home/leo/Projects", "/home/leo/repos", "/work"],
  realpath: identity,
};

describe("footerPath (omp path segment)", () => {
  test("a cwd under a temp root is shown relative to it, with the scratch icon", () => {
    // Footer: `🗑 rp-sl/proj`.
    expect(footerPath("/tmp/rp-sl/proj", ROOTS)).toEqual({ path: "rp-sl/proj", scratch: true });
  });

  test("the temp root itself keeps its full path", () => {
    expect(footerPath("/tmp", ROOTS)).toEqual({ path: "/tmp", scratch: true });
  });

  test("home becomes ~ (the user's footer: ~/Documents/remote_pi)", () => {
    expect(footerPath("/home/leo/Documents/remote_pi", ROOTS)).toEqual({ path: "~/Documents/remote_pi", scratch: false });
    expect(footerPath("/home/leo", ROOTS)).toEqual({ path: "~", scratch: false });
    // Only a whole leading segment matches.
    expect(footerPath("/home/leonard/x", ROOTS)).toEqual({ path: "/home/leonard/x", scratch: false });
  });

  test("work roots are stripped, but not when the cwd IS the root", () => {
    expect(footerPath("/home/leo/Projects/acme/api", ROOTS)).toEqual({ path: "acme/api", scratch: false });
    expect(footerPath("/home/leo/Projects", ROOTS)).toEqual({ path: "~/Projects", scratch: false });
    expect(footerPath("/work/svc", ROOTS)).toEqual({ path: "svc", scratch: false });
  });

  test("over 40 chars keeps the tail behind a leading …", () => {
    const cwd = "/srv/build/agents/remote-pi/packages/extension/src/protocol";
    const { path } = footerPath(cwd, ROOTS);
    expect(path).toBe("…mote-pi/packages/extension/src/protocol");
    expect(path).toHaveLength(40);
  });

  test("roots are compared by realpath, the display uses the cwd", () => {
    const roots: PathRoots = { ...ROOTS, scratch: ["/private/tmp"], realpath: (p) => p.replace(/^\/tmp/, "/private/tmp") };
    expect(footerPath("/tmp/rp-sl/proj", roots)).toEqual({ path: "rp-sl/proj", scratch: true });
  });
});

describe("parseGitStatus (omp git segment)", () => {
  test("clean branch with untracked entries → `main ?2`", () => {
    // `git status --porcelain=v2 --branch` in the scratch repo (?? .pi/, ?? a.txt).
    const out = "# branch.oid (initial)\n# branch.head main\n? .pi/\n? a.txt\n";
    expect(parseGitStatus(out)).toEqual({ branch: "main", staged: 0, unstaged: 0, untracked: 2 });
  });

  test("modified + added + untracked → `main *1 +1 ?2`", () => {
    const out = [
      "# branch.oid a44a8a9a33aa5fd930ea31422fae5dd0dd6e1d5c",
      "# branch.head main",
      "1 .M N... 100644 100644 100644 45b983be36b73c0788dc9cbcb76cbb80fc7bb057 45b983be36b73c0788dc9cbcb76cbb80fc7bb057 a.txt",
      "1 A. N... 000000 100644 100644 0000000000000000000000000000000000000000 b4785957bc986dc39c629de9fac9df46972c00fc b.txt",
      "? .pi/",
      "? c.txt",
      "",
    ].join("\n");
    expect(parseGitStatus(out)).toEqual({ branch: "main", staged: 1, unstaged: 1, untracked: 2 });
  });

  test("a renamed + modified entry counts on both sides; a branch switch shows the new name", () => {
    const out = "# branch.head feat/status-line\n2 RM N... 100644 100644 100644 aaa bbb R100 new.txt\told.txt\n";
    expect(parseGitStatus(out)).toEqual({ branch: "feat/status-line", staged: 1, unstaged: 1, untracked: 0 });
  });

  test("detached HEAD reads `detached`", () => {
    const out = "# branch.oid a44a8a9a33aa5fd930ea31422fae5dd0dd6e1d5c\n# branch.head (detached)\n";
    expect(parseGitStatus(out)?.branch).toBe("detached");
  });

  test("an unmerged entry counts as staged AND unstaged → `feat/status-line *1 +1 ?2`", () => {
    // Merge conflict on m.txt in the scratch repo; omp printed `*1 +1 ?2`.
    const out = [
      "# branch.oid 7e601a63d2d4ffc8b24543ea5853c1a1a5b9b7a0",
      "# branch.head feat/status-line",
      "u UU N... 100644 100644 100644 100644 df967b96a579e45a18b8251732d16804b2e56a55 7e7e3a8a2b0d5a4b6f0e6a8b6f0b2c7f2b2b1a3c 9b2a8f0f6d0f3e2c1a0b9c8d7e6f5a4b3c2d1e0f m.txt",
      "? .pi/",
      "? c.txt",
      "",
    ].join("\n");
    expect(parseGitStatus(out)).toEqual({ branch: "feat/status-line", staged: 1, unstaged: 1, untracked: 2 });
  });
});

describe("contextFromUsage (omp context_pct segment)", () => {
  test("ctx.getContextUsage() before and after one turn", () => {
    // Footer `1.3%/1M` at session_start, `1.5%/1M` after "Reply with just the word ok.".
    expect(contextFromUsage({ tokens: 13121, contextWindow: 1000000, percent: 1.3121 }, 1000000))
      .toEqual({ tokens: 13121, window: 1000000, percent: 1.3121 });
    const after = contextFromUsage({ tokens: 14722, contextWindow: 1000000, percent: 1.4722000000000002 }, 1000000);
    expect(after.percent?.toFixed(1)).toBe("1.5");
  });

  test("unknown percent stays null; a missing usage falls back to the model window", () => {
    expect(contextFromUsage({ tokens: 0, contextWindow: 200000, percent: null }, 200000))
      .toEqual({ tokens: 0, window: 200000, percent: null });
    expect(contextFromUsage(undefined, 272000)).toEqual({ tokens: 0, window: 272000, percent: 0 });
    expect(contextFromUsage(undefined, undefined)).toEqual({ tokens: 0, window: 0, percent: null });
  });
});

describe("costFromUsage (omp cost segment)", () => {
  test("subscription session after one turn → `󰙺 0.01`", () => {
    const stats = {
      input: 4, output: 4, cacheRead: 14278, cacheWrite: 440, totalTokens: 14726,
      orchestrationInput: 0, orchestrationOutput: 0, orchestrationCacheRead: 0,
      premiumRequests: 0, cost: 0.0064716, subagentCost: 0,
    };
    expect(costFromUsage(stats, true)).toEqual({ total: 0.0064716, subagents: 0, subscription: true, premium_requests: 0 });
  });

  test("subagent spend is split out of the total", () => {
    expect(costFromUsage({ cost: 1.5, subagentCost: 0.5, premiumRequests: 3 }, false))
      .toEqual({ total: 1, subagents: 0.5, subscription: false, premium_requests: 3 });
    expect(costFromUsage(undefined, false)).toEqual({ total: 0, subagents: 0, subscription: false, premium_requests: 0 });
  });
});

function snapshot(over: Partial<StatusLineMessage> = {}): StatusLineMessage {
  return {
    type: "status_line",
    cwd: "/tmp/rp-sl/proj",
    path: "rp-sl/proj",
    scratch: true,
    git: { branch: "main", staged: 0, unstaged: 0, untracked: 2 },
    context: { tokens: 13121, window: 1000000, percent: 1.3121 },
    cost: { total: 0, subagents: 0, subscription: true, premium_requests: 0 },
    run_started_at: null,
    ts: 0,
    ...over,
  };
}

describe("StatusLineBroadcaster", () => {
  afterEach(() => vi.useRealTimers());

  test("first change goes out at once, later ones coalesce to ≤1/s, identical snapshots never repeat", () => {
    vi.useFakeTimers();
    let current = snapshot();
    const sent: ServerMessage[] = [];
    const b = new StatusLineBroadcaster(() => ({ ...current, ts: Date.now() }), (m) => sent.push(m), () => true);

    b.schedule();
    expect(sent).toHaveLength(1);
    b.schedule();  // nothing changed
    vi.advanceTimersByTime(STATUS_LINE_MIN_INTERVAL_MS);
    expect(sent).toHaveLength(1);

    current = snapshot({ context: { tokens: 14722, window: 1000000, percent: 1.4722 } });
    b.schedule();
    expect(sent).toHaveLength(2);  // quiet for a full interval: immediate
    current = snapshot({ git: { branch: "feat/status-line", staged: 0, unstaged: 0, untracked: 2 } });
    b.schedule();
    current = snapshot({ git: { branch: "detached", staged: 0, unstaged: 0, untracked: 2 } });
    b.schedule();
    expect(sent).toHaveLength(2);
    vi.advanceTimersByTime(STATUS_LINE_MIN_INTERVAL_MS);
    expect(sent).toHaveLength(3);
    expect((sent[2] as StatusLineMessage).git?.branch).toBe("detached");
  });

  test("nothing is sent while no owner is attached; null (no session) is never sent", () => {
    let attached = false;
    let current: StatusLineMessage | null = snapshot();
    const sent: ServerMessage[] = [];
    const b = new StatusLineBroadcaster(() => current, (m) => sent.push(m), () => attached);
    b.flush();
    expect(sent).toEqual([]);
    attached = true;
    current = null;
    b.flush();
    expect(sent).toEqual([]);
    current = snapshot();
    b.flush();
    expect(sent).toHaveLength(1);
    b.reset();
    b.flush();  // after a reset the same snapshot goes out again
    expect(sent).toHaveLength(2);
  });
});

describe("GitStatusCache", () => {
  test("refreshes at most every interval, reports changes, and forgets a stale cwd", async () => {
    let now = 0;
    let result: StatusLineGit | null = { branch: "main", staged: 0, unstaged: 0, untracked: 0 };
    const read = vi.fn(async (): Promise<StatusLineGit | null> => result);
    const changed = vi.fn();
    const cache = new GitStatusCache(read, changed, () => now);

    expect(cache.get("/r")).toBeNull();
    cache.refresh("/r");
    await vi.waitFor(() => expect(changed).toHaveBeenCalledTimes(1));
    expect(cache.get("/r")?.branch).toBe("main");

    cache.refresh("/r");  // within the interval: no new read
    expect(read).toHaveBeenCalledTimes(1);

    now += 10_000;
    cache.refresh("/r");  // same value: no change callback
    await vi.waitFor(() => expect(read).toHaveBeenCalledTimes(2));
    await Promise.resolve();
    expect(changed).toHaveBeenCalledTimes(1);

    result = { branch: "feat", staged: 0, unstaged: 0, untracked: 0 };
    cache.refresh("/r", true);  // forced (turn end): ignores the interval
    await vi.waitFor(() => expect(cache.get("/r")?.branch).toBe("feat"));
    expect(changed).toHaveBeenCalledTimes(2);

    expect(cache.get("/elsewhere")).toBeNull();
  });

  test("a read in flight across reset() or for another cwd never leaves a stale value", async () => {
    const pending: Array<{ cwd: string; done: (git: StatusLineGit | null) => void }> = [];
    const read = (cwd: string): Promise<StatusLineGit | null> => {
      const { promise, resolve } = Promise.withResolvers<StatusLineGit | null>();
      pending.push({ cwd, done: resolve });
      return promise;
    };
    const cache = new GitStatusCache(read, () => undefined);

    cache.refresh("/old");
    cache.reset();  // session replaced mid-read
    cache.refresh("/new");
    expect(pending.map((p) => p.cwd)).toEqual(["/old", "/new"]);
    pending[0].done({ branch: "old", staged: 0, unstaged: 0, untracked: 0 });
    pending[1].done({ branch: "main", staged: 0, unstaged: 0, untracked: 2 });
    await vi.waitFor(() => expect(cache.get("/new")?.branch).toBe("main"));
    expect(cache.get("/old")).toBeNull();

    cache.refresh("/new", true);
    cache.refresh("/other");  // asked for while /new is read: runs right after
    pending[2].done({ branch: "main", staged: 0, unstaged: 0, untracked: 2 });
    await vi.waitFor(() => expect(pending).toHaveLength(4));
    expect(pending[3].cwd).toBe("/other");
  });
});
