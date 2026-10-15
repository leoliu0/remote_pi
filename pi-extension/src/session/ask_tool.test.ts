import { describe, it, expect, vi, beforeEach } from "vitest";
import {
  registerAskWrapperTool,
  handleAskResponse,
  getPendingAskRequests,
  AskParamsSchema,
} from "./ask_tool.js";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import type { ServerMessage, ExtensionUiRequestWire } from "../protocol/types.js";

describe("ask_tool", () => {
  let registeredTool: any = null;
  const mockPi: ExtensionAPI = {
    registerTool: vi.fn((tool: any) => {
      registeredTool = tool;
    }),
  } as unknown as ExtensionAPI;

  beforeEach(() => {
    registeredTool = null;
    vi.clearAllMocks();
  });

  it("registers ask tool with schema and description", () => {
    registerAskWrapperTool(mockPi, vi.fn(), () => false);
    expect(mockPi.registerTool).toHaveBeenCalled();
    expect(registeredTool.name).toBe("ask");
    expect(registeredTool.parameters).toBe(AskParamsSchema);
  });

  it("delegates to context.invokeTool when no active peers", async () => {
    const invokeTool = vi.fn().mockResolvedValue({
      content: [{ type: "text", text: "CLI answer" }],
      details: {},
    });
    registerAskWrapperTool(mockPi, vi.fn(), () => false);

    const result = await registeredTool.execute(
      "call_1",
      { questions: [{ id: "q1", question: "Continue?", options: [{ label: "Yes" }] }] },
      undefined,
      undefined,
      { invokeTool },
    );

    expect(invokeTool).toHaveBeenCalled();
    expect(result).toEqual({
      content: [{ type: "text", text: "CLI answer" }],
      details: {},
    });
  });

  it("broadcasts extension_ui_request and waits for mobile response when active peers exist", async () => {
    const broadcasts: ServerMessage[] = [];
    const broadcast = (msg: ServerMessage) => broadcasts.push(msg);

    registerAskWrapperTool(mockPi, broadcast, () => true);

    const executePromise = registeredTool.execute(
      "call_123",
      {
        questions: [
          {
            id: "auth",
            question: "Which auth?",
            header: "Auth Method",
            options: [
              { label: "JWT", description: "JSON Web Tokens" },
              { label: "OAuth", description: "OAuth 2.0" },
            ],
          },
        ],
      },
      undefined,
      undefined,
      {},
    );

    expect(broadcasts).toHaveLength(1);
    const req = broadcasts[0] as ExtensionUiRequestWire;
    expect(req.type).toBe("extension_ui_request");
    expect(req.id).toBe("ask_call_123");
    expect(req.ask?.questions[0].id).toBe("auth");
    expect(req.ask?.questions[0].options).toHaveLength(2);

    // Pending requests should include it
    expect(getPendingAskRequests()).toHaveLength(1);

    // Simulate mobile answering
    const handled = handleAskResponse({
      type: "extension_ui_response",
      id: "ask_call_123",
      ask: {
        flow_id: "ask_call_123",
        kind: "answer",
        answers: {
          auth: { values: ["JWT"] },
        },
      },
    });

    expect(handled).toBe(true);
    const res = await executePromise;
    expect(res.content[0].text).toContain("User selected: JWT");
    expect(getPendingAskRequests()).toHaveLength(0);

    // Should have broadcasted dismiss notify to mobile
    const dismissNotify = broadcasts.find((m) => m.type === "extension_ui_request" && m.id === "ask_call_123" && m.method === "notify");
    expect(dismissNotify).toBeDefined();
  });

  it("handles cancel response correctly", async () => {
    const broadcasts: ServerMessage[] = [];
    registerAskWrapperTool(mockPi, (m) => broadcasts.push(m), () => true);

    const executePromise = registeredTool.execute(
      "call_cancel",
      { questions: [{ id: "q1", question: "Proceed?", options: [{ label: "Yes" }] }] },
      undefined,
      undefined,
      {},
    );

    handleAskResponse({
      type: "extension_ui_response",
      id: "ask_call_cancel",
      cancelled: true,
    });

    const res = await executePromise;
    expect(res.content[0].text).toContain("User cancelled");
    expect(res.details.cancelled).toBe(true);
  });

  it("shows the native dialog alongside the mobile ask; a local answer dismisses the phone", async () => {
    const broadcasts: ServerMessage[] = [];
    let localSignal: AbortSignal | undefined;
    const invokeTool = vi.fn((_params: unknown, opts: { signal?: AbortSignal }) => {
      localSignal = opts.signal;
      return Promise.resolve({ content: [{ type: "text", text: "User selected: Yes" }], details: {} });
    });
    registerAskWrapperTool(mockPi, (m) => broadcasts.push(m), () => true);

    const res = await registeredTool.execute(
      "call_local",
      { questions: [{ id: "q1", question: "Proceed?", options: [{ label: "Yes" }] }] },
      undefined,
      undefined,
      { invokeTool },
    );

    expect(invokeTool).toHaveBeenCalledTimes(1);
    expect(res.content[0].text).toBe("User selected: Yes");
    expect(localSignal?.aborted).toBe(true);
    expect(getPendingAskRequests()).toHaveLength(0);
    expect(broadcasts.map((m) => m.type === "extension_ui_request" && m.method)).toEqual(["select", "notify"]);
    // A late phone answer no longer matches a pending ask.
    expect(handleAskResponse({ type: "extension_ui_response", id: "ask_call_local", value: "Yes" })).toBe(false);
  });

  it("a mobile answer closes the native dialog", async () => {
    let localSignal: AbortSignal | undefined;
    const invokeTool = vi.fn(
      (_params: unknown, opts: { signal?: AbortSignal }) =>
        new Promise((_resolve, reject) => {
          localSignal = opts.signal;
          opts.signal?.addEventListener("abort", () => reject(new Error("Ask input was cancelled")));
        }),
    );
    registerAskWrapperTool(mockPi, vi.fn(), () => true);

    const executePromise = registeredTool.execute(
      "call_remote",
      { questions: [{ id: "q1", question: "Proceed?", options: [{ label: "Yes" }, { label: "No" }] }] },
      undefined,
      undefined,
      { invokeTool },
    );
    expect(localSignal?.aborted).toBe(false);

    handleAskResponse({
      type: "extension_ui_response",
      id: "ask_call_remote",
      ask: { flow_id: "ask_call_remote", kind: "answer", answers: { q1: { values: ["No"] } } },
    });

    const res = await executePromise;
    expect(res.content[0].text).toBe("User selected: No");
    expect(localSignal?.aborted).toBe(true);
  });
});
