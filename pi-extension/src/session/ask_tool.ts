import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";
import type {
  AskAnswerWire,
  AskOptionWire,
  AskQuestionWire,
  ExtensionUiRequestWire,
  ExtensionUiResponseWire,
  ServerMessage,
} from "../protocol/types.js";

const OptionItemSchema = Type.Object({
  label: Type.String({ description: "display label" }),
  description: Type.Optional(Type.String({ description: "optional explanatory text displayed below the label" })),
  preview: Type.Optional(Type.String({ description: "optional rich preview content for interactive ask dialogs" })),
});

const QuestionItemSchema = Type.Object({
  id: Type.String({ description: "question id" }),
  question: Type.String({ description: "question text" }),
  header: Type.Optional(Type.String({ description: "optional short display chip for rich ask dialogs" })),
  options: Type.Array(OptionItemSchema, { description: "available options" }),
  multi: Type.Optional(Type.Boolean({ description: "allow multiple selections" })),
  recommended: Type.Optional(Type.Number({ description: "recommended option index" })),
});

export const AskParamsSchema = Type.Object({
  questions: Type.Array(QuestionItemSchema, { description: "questions to ask" }),
});

export interface AskParams {
  questions: Array<{
    id: string;
    question: string;
    header?: string;
    options: Array<{
      label: string;
      description?: string;
      preview?: string;
    }>;
    multi?: boolean;
    recommended?: number;
  }>;
}

interface PendingAsk {
  flowId: string;
  resolve: (res: { content: Array<{ type: "text"; text: string }>; details: Record<string, unknown> }) => void;
  reject: (err: Error) => void;
  questions: AskParams["questions"];
}

const activeAsks = new Map<string, PendingAsk>();
let _broadcastFn: ((msg: ServerMessage) => void) | null = null;

function broadcastDismiss(flowId: string): void {
  if (!_broadcastFn) return;
  _broadcastFn({
    type: "extension_ui_request",
    id: flowId,
    method: "notify",
    message: "Clarification resolved.",
  });
}

export function getPendingAskRequests(): ServerMessage[] {
  const reqs: ServerMessage[] = [];
  for (const ask of activeAsks.values()) {
    reqs.push(createAskRequestWire(ask.flowId, ask.questions));
  }
  return reqs;
}

export function handleAskResponse(msg: ExtensionUiResponseWire): boolean {
  const ask = activeAsks.get(msg.id);
  if (!ask) return false;

  activeAsks.delete(msg.id);

  if ("cancelled" in msg && msg.cancelled === true) {
    ask.resolve({
      content: [{ type: "text", text: "User cancelled the selection" }],
      details: { cancelled: true },
    });
    broadcastDismiss(msg.id);
    return true;
  }

  const askData = msg.ask;
  if (askData && askData.kind === "cancel") {
    ask.resolve({
      content: [{ type: "text", text: "User cancelled the selection" }],
      details: { cancelled: true },
    });
    broadcastDismiss(msg.id);
    return true;
  }

  if (askData && askData.kind === "answer") {
    const lines: string[] = [];
    for (const q of ask.questions) {
      const ans = askData.answers[q.id];
      if (!ans) continue;
      if (ans.values && ans.values.length > 0) {
        lines.push(`User selected: ${ans.values.join(", ")}`);
      } else if (ans.customText) {
        lines.push(`User provided custom input: ${ans.customText}`);
      }
      if (ans.note) {
        lines.push(`User added note: ${ans.note}`);
      }
    }
    const text = lines.length > 0 ? lines.join("\n") : "User answered via mobile app.";
    ask.resolve({
      content: [{ type: "text", text }],
      details: { answers: askData.answers },
    });
    broadcastDismiss(msg.id);
    return true;
  }

  if ("value" in msg && typeof msg.value === "string") {
    ask.resolve({
      content: [{ type: "text", text: `User selected: ${msg.value}` }],
      details: { selected: msg.value },
    });
    broadcastDismiss(msg.id);
    return true;
  }

  ask.resolve({
    content: [{ type: "text", text: "User confirmed" }],
    details: {},
  });
  broadcastDismiss(msg.id);
  return true;
}

function createAskRequestWire(flowId: string, questions: AskParams["questions"]): ExtensionUiRequestWire {
  const wireQuestions: AskQuestionWire[] = questions.map((q) => {
    const options: AskOptionWire[] = q.options.map((o) => ({
      value: o.label,
      label: o.label,
      description: o.description,
      preview: o.preview,
    }));
    return {
      id: q.id,
      label: q.header || q.question,
      prompt: q.question,
      type: q.multi ? "multi" : "single",
      required: true,
      options,
    };
  });

  const first = wireQuestions[0];
  const title = first?.prompt ?? "Question";
  const optionLabels = first?.options.map((o) => o.label) ?? [];

  return {
    type: "extension_ui_request",
    id: flowId,
    method: "select",
    title,
    options: optionLabels,
    ask: {
      flow_id: flowId,
      tool_call_id: flowId,
      source: "tool",
      title,
      questions: wireQuestions,
    },
  };
}

export function registerAskWrapperTool(
  pi: ExtensionAPI,
  broadcast: (msg: ServerMessage) => void,
  hasActivePeers: () => boolean,
): void {
  _broadcastFn = broadcast;

  pi.registerTool<typeof AskParamsSchema, Record<string, unknown>>({
    name: "ask",
    label: "Ask",
    description: "Ask the user clarifying questions during execution.",
    parameters: AskParamsSchema,
    execute: async (toolCallId, params, signal, _onUpdate, context) => {
      // If mobile peer is active, bridge to mobile modal
      if (hasActivePeers()) {
        const flowId = `ask_${toolCallId || Date.now().toString(36)}`;
        const req = createAskRequestWire(flowId, params.questions);
        broadcast(req);

        let resolve!: (res: { content: Array<{ type: "text"; text: string }>; details: Record<string, unknown> }) => void;
        let reject!: (err: Error) => void;
        const promise = new Promise<{
          content: Array<{ type: "text"; text: string }>;
          details: Record<string, unknown>;
        }>((res, rej) => {
          resolve = res;
          reject = rej;
        });

        const pending: PendingAsk = {
          flowId,
          resolve,
          reject,
          questions: params.questions,
        };
        activeAsks.set(flowId, pending);

        if (signal) {
          signal.addEventListener("abort", () => {
            if (activeAsks.delete(flowId)) {
              broadcastDismiss(flowId);
              reject(new Error("Ask tool aborted"));
            }
          });
        }
        return promise;
      }

      // If no mobile peer is active, delegate to native ask tool if available
      const invokeTool = (context as { invokeTool?: (p: unknown, opt?: unknown) => Promise<unknown> })?.invokeTool;
      if (typeof invokeTool === "function") {
        return invokeTool(params, { signal }) as Promise<{
          content: Array<{ type: "text"; text: string }>;
          details: Record<string, unknown>;
        }>;
      }
      // Fallback if headless / no peer
      const questionsSummary = params.questions.map((q) => q.question).join("; ");
      return {
        content: [{
          type: "text",
          text: `[No interactive client attached to answer: "${questionsSummary}". Using default / proceeding without user selection.]`,
        }],
        details: { unprompted: true },
      };
    },
  });
}
