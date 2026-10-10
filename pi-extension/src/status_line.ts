/**
 * omp's footer status row, mirrored for clients as `status_line` snapshots.
 *
 * Rules come from omp 18.8.7 `packages/tui/src/status-line/segments.ts`
 * (default preset): path (`ICl`/`kXo`/`$8s`), git (`PCl`), context
 * (`HCl`/`EI`) and cost (`qCl`/`EXo`). Model + thinking are not part of the
 * snapshot: they already ride room_meta (model_meta.ts). Clients format the
 * raw numbers; only the path is finished here, because it depends on this
 * machine's home and temp dirs.
 */
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { realpathSync } from "node:fs";
import { homedir, tmpdir } from "node:os";
import { isAbsolute, join, relative, resolve } from "node:path";
import type {
  ServerMessage,
  StatusLineContext,
  StatusLineCost,
  StatusLineGit,
  StatusLineMessage,
} from "./protocol/types.js";

/** At most one broadcast per second. */
export const STATUS_LINE_MIN_INTERVAL_MS = 1_000;
/** `git status` re-runs at most this often (plus forced runs at turn end). */
export const GIT_REFRESH_MS = 3_000;
/** omp's `segmentOptions.path.maxLength` default. */
const PATH_MAX_LENGTH = 40;
const execFileAsync = promisify(execFile);

/** Where omp looks when it shortens the path segment. */
export interface PathRoots {
  home: string;
  /** omp `CCl`: a cwd inside one of these is a "scratch" dir. */
  scratch: string[];
  /** omp `stripWorkPrefix` roots. */
  work: string[];
  realpath: (path: string) => string;
}

export function defaultPathRoots(): PathRoots {
  const home = homedir();
  return {
    home,
    scratch: [tmpdir(), join(home, "tmp"), "/tmp", "/var/tmp"],
    work: [join(home, "Projects"), join(home, "repos"), "/work"],
    realpath: (path) => {
      try { return realpathSync(resolve(path)); } catch { return resolve(path); }
    },
  };
}

/** omp `GTe`: `target` relative to `root`, "" when equal, null when outside. */
function relativeInside(root: string, target: string): string | null {
  const rel = relative(root, target);
  return rel !== "" && (rel.startsWith("..") || isAbsolute(rel)) ? null : rel;
}

/** The path segment text omp prints for `cwd`. */
export function footerPath(cwd: string, roots: PathRoots): { path: string; scratch: boolean } {
  const real = roots.realpath(cwd);
  let path = cwd;
  let scratch = false;
  for (const root of roots.scratch) {
    const rel = relativeInside(roots.realpath(root), real);
    if (rel !== null) {
      scratch = true;
      path = rel || cwd;
      break;
    }
  }
  if (!scratch) {
    for (const root of roots.work) {
      const rel = relativeInside(roots.realpath(root), real);
      if (rel) {
        path = rel;
        break;
      }
    }
  }
  // omp `it`: the home dir as a whole leading segment becomes `~`.
  const { home } = roots;
  if (home.length > 1 && path.startsWith(home) && (path.length === home.length || path[home.length] === "/" || path[home.length] === "\\")) {
    path = `~${path.slice(home.length).replaceAll("\\", "/")}`;
  }
  if (path.length > PATH_MAX_LENGTH) path = `…${path.slice(-(PATH_MAX_LENGTH - 1))}`;
  return { path, scratch };
}

/**
 * `git status --porcelain=v2 --branch` → omp's git segment values. omp shows a
 * ref HEAD by its branch name and anything else as `detached`; staged and
 * unstaged count the index / worktree side of each changed entry (an
 * unmerged `UU` entry counts on both, as omp shows `*1 +1`).
 */
export function parseGitStatus(out: string): StatusLineGit {
  const git: StatusLineGit = { branch: null, staged: 0, unstaged: 0, untracked: 0 };
  for (const line of out.split("\n")) {
    if (line.startsWith("# branch.head ")) {
      const head = line.slice("# branch.head ".length);
      git.branch = head === "(detached)" ? "detached" : head;
    } else if (line.startsWith("1 ") || line.startsWith("2 ") || line.startsWith("u ")) {
      if (line[2] !== ".") git.staged++;
      if (line[3] !== ".") git.unstaged++;
    } else if (line.startsWith("? ")) {
      git.untracked++;
    }
  }
  return git;
}

/** Runs `git status` in `cwd`; null outside a repo (or without git). */
export async function readGitStatus(cwd: string): Promise<StatusLineGit | null> {
  try {
    const { stdout } = await execFileAsync(
      "git",
      ["--no-optional-locks", "status", "--porcelain=v2", "--branch"],
      { cwd, timeout: 5_000, maxBuffer: 16 * 1024 * 1024, windowsHide: true },
    );
    return parseGitStatus(stdout);
  } catch {
    return null;
  }
}

function record(value: unknown): Record<string, unknown> | undefined {
  return value && typeof value === "object" ? (value as Record<string, unknown>) : undefined;
}

function finite(value: unknown): number | undefined {
  return typeof value === "number" && Number.isFinite(value) ? value : undefined;
}

/**
 * `ctx.getContextUsage()` the way omp's status line reads it: the window
 * falls back to the model's, and only an explicit `percent: null` (unknown,
 * e.g. right after compaction) leaves the percentage unknown.
 */
export function contextFromUsage(usage: unknown, modelWindow: number | undefined): StatusLineContext {
  const u = record(usage);
  const tokens = finite(u?.tokens) ?? 0;
  const window = finite(u?.contextWindow) || modelWindow || 0;
  const percent = window > 0 && u?.percent !== null ? (tokens / window) * 100 : null;
  return { tokens, window, percent };
}

/** `sessionManager.getUsageStatistics()` → omp's cost segment inputs. */
export function costFromUsage(stats: unknown, subscription: boolean): StatusLineCost {
  const s = record(stats);
  const cost = finite(s?.cost) ?? 0;
  const subagents = finite(s?.subagentCost) ?? 0;
  return {
    total: Math.max(0, cost - subagents),
    subagents,
    subscription,
    premium_requests: finite(s?.premiumRequests) ?? 0,
  };
}

/**
 * Last `git status` per cwd. `get` never blocks; `refresh` starts at most one
 * read at a time, no more than every `GIT_REFRESH_MS` unless forced, and
 * calls `onChange` when the result differs. A refresh asked for during a
 * read runs right after it; a read that straddles `reset` is dropped.
 */
export class GitStatusCache {
  #cwd: string | null = null;
  #value: StatusLineGit | null = null;
  #readAt = Number.NEGATIVE_INFINITY;
  #reading: string | null = null;
  #queued: string | null = null;
  #generation = 0;

  constructor(
    private readonly read: (cwd: string) => Promise<StatusLineGit | null>,
    private readonly onChange: () => void,
    private readonly now: () => number = () => Date.now(),
  ) {}

  get(cwd: string): StatusLineGit | null {
    return cwd === this.#cwd ? this.#value : null;
  }

  refresh(cwd: string, force = false): void {
    if (this.#reading !== null) {
      if (force || cwd !== this.#reading) this.#queued = cwd;
      return;
    }
    if (!force && cwd === this.#cwd && this.now() - this.#readAt < GIT_REFRESH_MS) return;
    const generation = this.#generation;
    this.#reading = cwd;
    this.#readAt = this.now();
    void this.read(cwd)
      .catch(() => null)
      .then((value) => {
        if (generation !== this.#generation) return;
        this.#reading = null;
        const changed = cwd !== this.#cwd || JSON.stringify(value) !== JSON.stringify(this.#value);
        this.#cwd = cwd;
        this.#value = value;
        if (changed) this.onChange();
        const next = this.#queued;
        this.#queued = null;
        if (next !== null) this.refresh(next, true);
      });
  }

  reset(): void {
    this.#generation++;
    this.#cwd = null;
    this.#value = null;
    this.#readAt = Number.NEGATIVE_INFINITY;
    this.#reading = null;
    this.#queued = null;
  }
}

/**
 * Throttled, deduplicated `status_line` fan-out (same shape as
 * `ActivityBroadcaster`): the first change after a quiet second goes out at
 * once, later ones coalesce into one trailing send. `build` returns null
 * while there is no main session to describe.
 */
export class StatusLineBroadcaster {
  #lastKey = "";
  #lastSentAt = Number.NEGATIVE_INFINITY;
  #timer: NodeJS.Timeout | null = null;

  constructor(
    private readonly build: () => StatusLineMessage | null,
    private readonly send: (msg: ServerMessage) => void,
    private readonly canSend: () => boolean,
    private readonly now: () => number = () => Date.now(),
  ) {}

  /** Current snapshot for a single owner (attach / session_sync). */
  message(): StatusLineMessage | null {
    return this.build();
  }

  schedule(): void {
    if (this.#timer) return;
    const wait = this.#lastSentAt + STATUS_LINE_MIN_INTERVAL_MS - this.now();
    if (wait <= 0) {
      this.flush();
      return;
    }
    this.#timer = setTimeout(() => {
      this.#timer = null;
      this.flush();
    }, wait);
    this.#timer.unref?.();
  }

  /** Sends now if the snapshot changed since the last broadcast. */
  flush(): void {
    if (this.#timer) {
      clearTimeout(this.#timer);
      this.#timer = null;
    }
    if (!this.canSend()) return;
    const msg = this.build();
    if (!msg) return;
    const key = JSON.stringify({ ...msg, ts: 0 });
    if (key === this.#lastKey) return;
    this.#lastKey = key;
    this.#lastSentAt = this.now();
    this.send(msg);
  }

  /** Forget send history (session replaced); cancels a pending send. */
  reset(): void {
    clearTimeout(this.#timer ?? undefined);
    this.#timer = null;
    this.#lastKey = "";
    this.#lastSentAt = Number.NEGATIVE_INFINITY;
  }
}
