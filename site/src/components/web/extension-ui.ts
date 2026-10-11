// Plan/57 — interactive extension prompts (ask_user / pi-ask, plan review) on
// the web. Wire shapes mirror pi-extension/src/protocol/types.ts
// (ExtensionUiRequestWire / ExtensionUiResponseWire); parsing and response
// building follow the phone (app/lib/protocol/protocol.dart and
// app/lib/ui/chat/widgets/extension_ui_sheet.dart) so the extension sees the
// same frames from either client.

export type ExtensionUiMethod = "select" | "confirm" | "input" | "editor" | "notify";
export type AskQuestionType = "single" | "multi" | "preview";

export interface AskOption {
  value: string;
  label: string;
  description?: string;
  preview?: string;
}

export interface AskQuestion {
  id: string;
  label: string;
  prompt: string;
  type: AskQuestionType;
  required: boolean;
  presentedType?: AskQuestionType;
  options: AskOption[];
}

export interface AskEnrichment {
  flowId: string;
  toolCallId: string | null;
  source: string;
  title: string | null;
  questions: AskQuestion[];
}

/** omp's Plan Review choices (pi-extension `PlanReviewAction`), in omp's order. */
export type PlanReviewAction = "approve_execute" | "approve_compact" | "approve_keep" | "refine" | "save_quit";

export interface PlanReviewOption {
  action: PlanReviewAction;
  label: string;
  /** omp disables `approve_keep` when the context is over 95 % full. */
  disabled: boolean;
}

/** The `plan` envelope of a plan review request (pi-extension `PlanReviewWire`). */
export interface PlanReview {
  planFilePath: string;
  title: string;
  /** The plan's markdown; null when the Pi could not read the file. */
  content: string | null;
  options: PlanReviewOption[];
}

export interface ExtensionUiRequest {
  id: string;
  method: ExtensionUiMethod;
  title?: string;
  message?: string;
  placeholder?: string;
  prefill?: string;
  options: string[];
  notifyType?: string;
  ask?: AskEnrichment;
  plan?: PlanReview;
}

/** pi-ask RemoteAskAnswer — keys stay camelCase inside the `ask` envelope. */
export interface AskAnswerWire {
  values?: string[];
  customText?: string;
  note?: string;
}

export type AskResponseEnrichmentWire =
  | { flow_id: string; kind: "answer"; mode: "submit"; answers: Record<string, AskAnswerWire> }
  | { flow_id: string; kind: "cancel" };

export type ExtensionUiResponseWire = {
  type: "extension_ui_response";
  id: string;
  cancelled?: true;
  value?: string;
  confirmed?: boolean;
  ask?: AskResponseEnrichmentWire;
  /** Plan review answer; `feedback` only for `refine`. Cancel uses `cancelled`. */
  plan?: { action: PlanReviewAction; feedback?: string };
};

const METHODS: readonly ExtensionUiMethod[] = ["select", "confirm", "input", "editor", "notify"];

function optString(v: unknown): string | undefined {
  return typeof v === "string" ? v : undefined;
}

const QUESTION_TYPES: readonly AskQuestionType[] = ["single", "multi", "preview"];

/** Wire fields as received: present or not, any type until checked. */
type Unchecked<K extends string> = Partial<Record<K, unknown>>;

function parseOption(raw: unknown): AskOption | null {
  if (typeof raw !== "object" || raw === null) return null;
  const o = raw as Unchecked<"value" | "label" | "description" | "preview">;
  // Lenient like the bridge: value and label fall back to each other.
  const value = optString(o.value) ?? optString(o.label);
  const label = optString(o.label) ?? value;
  if (!value || !label) return null;
  return { value, label, description: optString(o.description), preview: optString(o.preview) };
}

function parseQuestion(raw: unknown): AskQuestion | null {
  if (typeof raw !== "object" || raw === null) return null;
  const q = raw as Unchecked<"id" | "label" | "prompt" | "type" | "required" | "presentedType" | "options">;
  if (typeof q.id !== "string") return null;
  const prompt = optString(q.prompt) ?? "";
  return {
    id: q.id,
    label: optString(q.label) ?? prompt,
    prompt,
    type: QUESTION_TYPES.find((t) => t === q.type) ?? "single",
    required: q.required === true,
    presentedType: QUESTION_TYPES.find((t) => t === q.presentedType),
    options: (Array.isArray(q.options) ? q.options : []).flatMap((o) => parseOption(o) ?? []),
  };
}

function parseAsk(raw: unknown): AskEnrichment | undefined {
  if (typeof raw !== "object" || raw === null) return undefined;
  const a = raw as Unchecked<"flow_id" | "tool_call_id" | "source" | "title" | "questions">;
  return {
    flowId: optString(a.flow_id) ?? "",
    toolCallId: optString(a.tool_call_id) ?? null,
    source: optString(a.source) ?? "tool",
    title: optString(a.title) ?? null,
    questions: (Array.isArray(a.questions) ? a.questions : []).flatMap((q) => parseQuestion(q) ?? []),
  };
}

const PLAN_ACTIONS: readonly PlanReviewAction[] = ["approve_execute", "approve_compact", "approve_keep", "refine", "save_quit"];

/** The `plan` envelope; undefined when absent or without a usable option (the plain select stays usable). */
function parsePlan(raw: unknown): PlanReview | undefined {
  if (typeof raw !== "object" || raw === null) return undefined;
  const p = raw as Unchecked<"plan_file_path" | "title" | "content" | "options">;
  const options = (Array.isArray(p.options) ? p.options : []).flatMap((o): PlanReviewOption[] => {
    if (typeof o !== "object" || o === null) return [];
    const opt = o as Unchecked<"action" | "label" | "disabled">;
    const action = PLAN_ACTIONS.find((a) => a === opt.action);
    return action ? [{ action, label: optString(opt.label) ?? action, disabled: opt.disabled === true }] : [];
  });
  if (options.length === 0) return undefined;
  return {
    planFilePath: optString(p.plan_file_path) ?? "",
    title: optString(p.title) ?? "",
    content: optString(p.content) ?? null,
    options,
  };
}

/** Inbound `extension_ui_request` → typed request (null when not one). */
export function parseExtensionUiRequest(frame: Record<string, unknown>): ExtensionUiRequest | null {
  if (frame.type !== "extension_ui_request" || typeof frame.id !== "string" || !frame.id) return null;
  // Unknown methods degrade to select, like the phone (ExtensionUiMethod.fromWire).
  const method = METHODS.find((m) => m === frame.method) ?? "select";
  return {
    id: frame.id,
    method,
    title: optString(frame.title),
    message: optString(frame.message),
    placeholder: optString(frame.placeholder),
    prefill: optString(frame.prefill),
    options: Array.isArray(frame.options) ? frame.options.map((o) => String(o)) : [],
    notifyType: optString(frame.notify_type),
    ask: parseAsk(frame.ask),
    plan: parsePlan(frame.plan),
  };
}

// ── the open prompt (chat_viewmodel.dart `_onExtensionUiRequest`) ────────────

export interface PendingPrompt {
  request: ExtensionUiRequest;
  /** submit-result rejection, shown so the user can retry. */
  error: string | null;
}

/**
 * Applies an incoming request to the open prompt. A `notify` with the open
 * prompt's id is either a warning (keep it open, show the message) or the
 * "resolved elsewhere / cancelled" dismiss (close it). Unmatched notifies are
 * ignored; any other request opens or replaces the prompt.
 */
export function applyExtensionUiRequest(
  open: PendingPrompt | null,
  req: ExtensionUiRequest,
): PendingPrompt | null {
  if (req.method !== "notify") return { request: req, error: null };
  if (!open || open.request.id !== req.id) return open;
  if (req.notifyType === "warning" || req.notifyType === "error") {
    return { ...open, error: req.message ? req.message : "Answer was not accepted." };
  }
  return null;
}

// ── answering ────────────────────────────────────────────────────────────────

export interface QuestionDraft {
  selected: string[];
  custom: string;
  note: string;
}

export type AskDraft = Record<string, QuestionDraft>;

export const EMPTY_QUESTION_DRAFT: QuestionDraft = { selected: [], custom: "", note: "" };

export function isMultiQuestion(q: AskQuestion): boolean {
  return q.type === "multi" || q.presentedType === "multi";
}

/** Selects `value` (radio) or toggles it (multi). */
export function toggleOption(draft: QuestionDraft, value: string, multi: boolean): QuestionDraft {
  if (!multi) return { ...draft, selected: [value] };
  const selected = draft.selected.includes(value)
    ? draft.selected.filter((v) => v !== value)
    : [...draft.selected, value];
  return { ...draft, selected };
}

/** Plain (non-ask) answer state: the chosen option or the typed text. */
export interface PlainDraft {
  value: string;
}

export function canSubmit(req: ExtensionUiRequest, ask: AskDraft, plain: PlainDraft): boolean {
  if (req.ask) {
    return req.ask.questions.some((q) => {
      const d = ask[q.id];
      return !!d && (d.selected.length > 0 || d.custom.trim() !== "");
    });
  }
  switch (req.method) {
    case "select":
      return plain.value !== "";
    case "input":
    case "editor":
      return plain.value.trim() !== "";
    case "confirm":
      return true;
    case "notify":
      return false;
  }
}

/**
 * The submit frame. Rich prompts send only the `ask` envelope (pi-ask's
 * structured answers); plain prompts send the SDK value/confirmed shape.
 */
export function buildSubmitResponse(
  req: ExtensionUiRequest,
  ask: AskDraft,
  plain: PlainDraft,
): ExtensionUiResponseWire {
  if (req.ask) {
    const answers: Record<string, AskAnswerWire> = {};
    for (const q of req.ask.questions) {
      const d = ask[q.id] ?? EMPTY_QUESTION_DRAFT;
      const custom = d.custom.trim();
      // pi-ask forbids value + customText on non-multi questions: text wins.
      const values = isMultiQuestion(q) || custom === "" ? d.selected : [];
      if (values.length === 0 && custom === "") continue;
      const answer: AskAnswerWire = {};
      if (values.length > 0) answer.values = [...values];
      if (custom) answer.customText = custom;
      if (d.note.trim()) answer.note = d.note.trim();
      answers[q.id] = answer;
    }
    return {
      type: "extension_ui_response",
      id: req.id,
      ask: { flow_id: req.ask.flowId, kind: "answer", mode: "submit", answers },
    };
  }
  switch (req.method) {
    case "confirm":
      return { type: "extension_ui_response", id: req.id, confirmed: true };
    case "notify":
      return buildCancelResponse(req);
    default:
      return { type: "extension_ui_response", id: req.id, value: plain.value };
  }
}

export function buildCancelResponse(req: ExtensionUiRequest): ExtensionUiResponseWire {
  return {
    type: "extension_ui_response",
    id: req.id,
    cancelled: true,
    ...(req.ask ? { ask: { flow_id: req.ask.flowId, kind: "cancel" as const } } : {}),
  };
}

/** The plan review answer: the chosen option, plus trimmed feedback for `refine` (omitted when empty). */
export function buildPlanResponse(req: ExtensionUiRequest, action: PlanReviewAction, feedback: string): ExtensionUiResponseWire {
  const text = feedback.trim();
  return {
    type: "extension_ui_response",
    id: req.id,
    plan: action === "refine" && text ? { action, feedback: text } : { action },
  };
}
