import { describe, expect, test } from "vitest";
import { modelMetaFromSession, type LiveModel } from "./model_meta.js";
import capture from "./model_meta.fixture.json" with { type: "json" };

const models: Record<string, LiveModel> = capture.models;

describe("modelMetaFromSession mirrors the omp footer (captured session)", () => {
  for (const step of capture.steps) {
    test(`${step.scenario}: footer "${step.footer}"`, () => {
      const meta = modelMetaFromSession({
        model: models[step.model],
        thinkingLevel: step.getThinkingLevel,
        branch: capture.branch.slice(0, step.branchEnd),
        sessionStartLeafId: "5f8f1378",
      });
      // The wire keeps the registry name; clients drop "Claude " like the footer.
      expect(meta.model).toBe(models[step.model]!.name);
      expect(meta.thinking).toBe(step.expected);
    });
  }

  test("a resumed session shows auto until its next prompt (omp resets the resolved level)", () => {
    const branch = capture.branch.slice(0, 21);
    const meta = modelMetaFromSession({
      model: models["sonnet"],
      thinkingLevel: "low",
      branch,
      sessionStartLeafId: "bf571136",  // leaf when `omp -c` bound the session
    });
    expect(meta.thinking).toBe("auto");
  });

  test("a new session started in auto has no thinking entry and shows auto", () => {
    // `omp --thinking auto`: omp skips the init thinking_level_change in auto.
    const meta = modelMetaFromSession({
      model: models["opus"],
      thinkingLevel: "high",
      branch: capture.branch.slice(0, 1),
      sessionStartLeafId: "bc59aa52",
    });
    expect(meta.thinking).toBe("auto");
  });

  test("model without thinking metadata: the footer shows no level", () => {
    const { thinking: _omit, ...plain } = models["opus"]!;
    const meta = modelMetaFromSession({
      model: { ...plain, reasoning: false },
      thinkingLevel: "off",
      branch: capture.branch.slice(0, 2),
      sessionStartLeafId: undefined,
    });
    expect(meta).toEqual({ model: "Claude Opus 5.5", thinking: null });
  });

  test("upstream pi (no `thinking` metadata, reasoning model) reports getThinkingLevel()", () => {
    const meta = modelMetaFromSession({
      model: { id: "gpt-5", name: "GPT-5", reasoning: true },
      thinkingLevel: "medium",
      branch: [{ type: "thinking_level_change", thinkingLevel: "medium" }],
      sessionStartLeafId: undefined,
    });
    expect(meta).toEqual({ model: "GPT-5", thinking: "medium" });
  });

  test("no model yet: nothing to publish", () => {
    expect(modelMetaFromSession({
      model: undefined, thinkingLevel: "high", branch: [], sessionStartLeafId: undefined,
    })).toEqual({ model: undefined, thinking: undefined });
  });
});
