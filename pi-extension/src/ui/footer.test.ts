import { describe, expect, test, vi } from "vitest";
import { updateFooter, type FooterContext, type FooterState } from "./footer.js";

function makeMockCtx(): FooterContext & {
  statusCalls: Array<{ key: string; value: string | undefined }>;
  titleCalls: string[];
} {
  const statusCalls: Array<{ key: string; value: string | undefined }> = [];
  const titleCalls: string[] = [];
  return {
    ui: {
      setStatus: vi.fn().mockImplementation((key: string, value: string | undefined) => {
        statusCalls.push({ key, value });
      }),
      setTitle: vi.fn().mockImplementation((title: string) => {
        titleCalls.push(title);
      }),
    },
    statusCalls,
    titleCalls,
  };
}

describe("updateFooter — footer slots (horizontal single-line rendering)", () => {
  test("session slot shows 'local' when joined to the mesh", () => {
    const ctx = makeMockCtx();
    const state: FooterState = {
      session: "local",
      peerCount: 3,
      relayOn: false,
    };
    updateFooter(ctx, state);
    const statusSlot = ctx.statusCalls.find((c) => c.key === "remote-pi");
    expect(statusSlot?.value).toBe("📡 local (3)");
  });

  test("combines relay and session horizontally on one line", () => {
    const ctx = makeMockCtx();
    const state: FooterState = {
      session: "local",
      peerCount: 1,
      relayOn: true,
      hasPairings: true,
    };
    updateFooter(ctx, state);
    const statusSlot = ctx.statusCalls.find((c) => c.key === "remote-pi");
    expect(statusSlot?.value).toBe("🟢 relay  📡 local (1)");
  });

  test("status slot cleared when nothing active", () => {
    const ctx = makeMockCtx();
    updateFooter(ctx, { relayOn: false });
    const statusSlot = ctx.statusCalls.find((c) => c.key === "remote-pi");
    expect(statusSlot?.value).toBeUndefined();
  });
});

describe("updateFooter — terminal title (post-2026-05-24 two-part format)", () => {
  test("title is `<agent> · On` when relay is up", () => {
    const ctx = makeMockCtx();
    updateFooter(ctx, {
      session: "local",
      peerCount: 2,
      relayOn: true,
      agentName: "backend",
    });
    expect(ctx.titleCalls.at(-1)).toBe("backend · On");
  });

  test("title is `<agent> · Off` when relay is down", () => {
    const ctx = makeMockCtx();
    updateFooter(ctx, {
      session: "local",
      peerCount: 1,
      relayOn: false,
      agentName: "backend",
    });
    expect(ctx.titleCalls.at(-1)).toBe("backend · Off");
  });

  test("broker-assigned name with #N suffix flows through verbatim", () => {
    // Two Pis in the same cwd: the second gets "backend#2" from the broker.
    const ctx = makeMockCtx();
    updateFooter(ctx, {
      session: "local",
      peerCount: 2,
      relayOn: true,
      agentName: "backend#2",
    });
    expect(ctx.titleCalls.at(-1)).toBe("backend#2 · On");
  });

  test("title falls back to 'Pi' when no agentName configured", () => {
    const ctx = makeMockCtx();
    updateFooter(ctx, {
      session: "local",
      peerCount: 1,
      relayOn: false,
    });
    expect(ctx.titleCalls.at(-1)).toBe("Pi · Off");
  });

  test("title never includes the session name (pre-2026-05-24 had `· local ·`)", () => {
    const ctx = makeMockCtx();
    updateFooter(ctx, {
      session: "local",
      peerCount: 0,
      relayOn: true,
      agentName: "foo",
    });
    expect(ctx.titleCalls.at(-1)).not.toContain("local");
  });
});
