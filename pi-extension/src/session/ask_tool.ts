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

type AskResult = { content: Array<{ type: "text"; text: string }>; details: Record<string, unknown> };
type InvokeNativeTool = (params: AskParams, options: { signal?: AbortSignal }) => Promise<AskResult>;

interface PendingAsk {
  flowId: string;
  resolve: (res: AskResult) => void;
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

/** Broadcasts the question to mobile peers; settles on their response or `signal` abort. */
function askRemotely(
  flowId: string,
  questions: AskParams["questions"],
  broadcast: (msg: ServerMessage) => void,
  signal: AbortSignal | undefined,
): Promise<AskResult> {
  // Executor form: `Promise.withResolvers` needs Node 22 / lib es2024; this package targets Node 20.
  return new Promise<AskResult>((resolve, reject) => {
    activeAsks.set(flowId, { flowId, resolve, reject, questions });
    broadcast(createAskRequestWire(flowId, questions));
    signal?.addEventListener(
      "abort",
      () => {
        if (activeAsks.delete(flowId)) {
          broadcastDismiss(flowId);
          reject(new Error("Ask tool aborted"));
        }
      },
      { once: true },
    );
  });
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
      const invokeTool: unknown = context && "invokeTool" in context ? context.invokeTool : undefined;
      // omp-only `ctx.invokeTool` runs the native built-in `ask` this tool shadows; the upstream SDK types lack it.
      const invokeNative = typeof invokeTool === "function" ? (invokeTool as InvokeNativeTool) : undefined;

      // Mobile peer active: offer the question on the phone, and keep the native
      // terminal dialog up too — a paired phone is not proof the user is looking
      // at it. First answer wins; the other side is dismissed.
      if (hasActivePeers()) {
        const flowId = `ask_${toolCallId || Date.now().toString(36)}`;
        const remote = askRemotely(flowId, params.questions, broadcast, signal);
        if (!invokeNative) return remote;

        const localAbort = new AbortController();
        const localSignal = signal ? AbortSignal.any([signal, localAbort.signal]) : localAbort.signal;
        const local = invokeNative(params, { signal: localSignal });
        // The losing side settles after the race (aborted local dialog throws,
        // dismissed mobile ask never resolves); nothing awaits it.
        local.catch(() => {});
        try {
          return await Promise.race([local, remote]);
        } finally {
          localAbort.abort();
          if (activeAsks.delete(flowId)) broadcastDismiss(flowId);
        }
      }

      // No mobile peer: native ask tool when available.
      if (invokeNative) return invokeNative(params, { signal });
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
