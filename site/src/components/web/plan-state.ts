// omp plan mode as the web shows it. Wire contract: pi-extension
// src/protocol/types.ts `{type:"plan_state"}` (PlanStatus) and the
// `{type:"plan_mode"}` typed action. Room meta never carries the plan (the
// relay drops it), so `plan_state` frames are the only source.

export type PlanStatus = "idle" | "active" | "paused" | "review";

export interface PlanState {
  status: PlanStatus;
  /** Present while a proposed plan exists (lets "Planning" offer Review plan). */
  planFilePath: string | null;
  title: string | null;
}

/** `plan_mode` action: `enter` = /plan, `exit` = /plan until idle, `review` = /plan-review. */
export type PlanModeAction = "enter" | "exit" | "review";

/** omp's own confirm text; the client asks it before exiting with a plan. */
export const EXIT_PLAN_CONFIRM = "Exit plan mode? This exits plan mode without approving a plan.";

const STATUSES: readonly PlanStatus[] = ["idle", "active", "paused", "review"];

/** `plan_state` frame → state (null when not one). */
export function parsePlanState(frame: Record<string, unknown>): PlanState | null {
  if (frame.type !== "plan_state") return null;
  const status = STATUSES.find((s) => s === frame.status);
  if (!status) return null;
  const path = frame.plan_file_path;
  const title = frame.title;
  return {
    status,
    planFilePath: typeof path === "string" && path ? path : null,
    title: typeof title === "string" && title ? title : null,
  };
}

export interface PlanControlItem {
  action: PlanModeAction;
  label: string;
  /** Asked before sending (null = send directly). */
  confirm: string | null;
}

/** The composer's Plan control: one click (`menu: false`, single item) or a menu. */
export interface PlanControl {
  label: string;
  menu: boolean;
  items: PlanControlItem[];
}

/** What the Plan control offers for `state` (the app's plan quick button). */
export function planControl(state: PlanState): PlanControl {
  const exit: PlanControlItem = {
    action: "exit",
    label: "Exit plan mode",
    confirm: state.planFilePath ? EXIT_PLAN_CONFIRM : null,
  };
  const review: PlanControlItem = { action: "review", label: "Review plan", confirm: null };
  switch (state.status) {
    case "idle":
      return { label: "Plan", menu: false, items: [{ action: "enter", label: "Enter plan mode", confirm: null }] };
    case "review":
      return { label: "Plan ready", menu: false, items: [review] };
    case "active":
      return { label: "Planning", menu: true, items: state.planFilePath ? [review, exit] : [exit] };
    case "paused":
      return { label: "Plan paused", menu: true, items: [exit] };
  }
}
