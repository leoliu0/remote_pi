import { test } from "node:test";
import assert from "node:assert/strict";
import { normalizeMath, prepareMarkdown } from "./markdown-text.ts";

test("closes an unfinished code fence so streaming text stays inside the block", () => {
  assert.equal(prepareMarkdown("Here:\n```ts\nconst a = 1;"), "Here:\n```ts\nconst a = 1;\n```");
  assert.equal(prepareMarkdown("~~~\nx"), "~~~\nx\n~~~");
  // A longer opener needs an equally long closer; a shorter run inside is content.
  assert.equal(prepareMarkdown("````md\n```js\nx\n```"), "````md\n```js\nx\n```\n````");
  // Indented fence inside a list item keeps its indentation.
  assert.equal(prepareMarkdown("1. step\n   ```bash\n   ls"), "1. step\n   ```bash\n   ls\n   ```");
});

test("leaves balanced fences and inline triple backticks alone", () => {
  const closed = "```ts\nconst a = 1;\n```\n\nafter";
  assert.equal(prepareMarkdown(closed), closed);
  assert.equal(prepareMarkdown("use ``` inside prose"), "use ``` inside prose");
  // A closing fence may not carry an info string, so "```js" inside a block is content.
  assert.equal(prepareMarkdown("```\n```js\nx"), "```\n```js\nx\n```");
  // An info string named after an Object.prototype key is not a math fence.
  assert.equal(prepareMarkdown("```constructor\nx\n```"), "```constructor\nx\n```");
});

test("renders \\( \\) and \\[ \\] delimiters as remark-math dollars", () => {
  assert.equal(normalizeMath("area \\(\\pi r^2\\) here"), "area $\\pi r^2$ here");
  assert.equal(normalizeMath("\\[\n\\hat\\beta = (X'X)^{-1}X'y\n\\]"), "$$\n\\hat\\beta = (X'X)^{-1}X'y\n$$");
  assert.equal(normalizeMath("see \\[x+1\\] inline"), "see $$x+1$$ inline");
});

test("puts standalone display math on its own fence lines", () => {
  assert.equal(normalizeMath("$$\\int_0^1 x\\,dx$$"), "$$\n\\int_0^1 x\\,dx\n$$");
  assert.equal(normalizeMath("intro\n\n$$ a = b $$\n\nafter"), "intro\n\n$$\na = b\n$$\n\nafter");
  // Inside a list item the indentation is kept on every line.
  assert.equal(normalizeMath("- item\n  $$x^2$$"), "- item\n  $$\n  x^2\n  $$");
});

test("keeps currency and prose dollars as literal text", () => {
  assert.equal(normalizeMath("costs $100 and $50 more"), "costs \\$100 and \\$50 more");
  assert.equal(normalizeMath("$5 or $10"), "\\$5 or \\$10");
  // Every dollar that is not part of accepted math is escaped, so remark-math cannot pair it.
  assert.equal(normalizeMath("pay $ 5 now"), "pay \\$ 5 now");
  assert.equal(normalizeMath("between $the cat and the$ dog"), "between \\$the cat and the\\$ dog");
  assert.equal(normalizeMath("already \\$5 escaped"), "already \\$5 escaped");
  // Real inline math survives the guards.
  assert.equal(normalizeMath("$E = mc^2$ and $x_i$"), "$E = mc^2$ and $x_i$");
  assert.equal(normalizeMath("growth of $2x + 1$"), "growth of $2x + 1$");
});

test("escapes an unmatched $$ so a half-streamed formula is plain text", () => {
  assert.equal(normalizeMath("Formula:\n$$\n\\frac{a}{"), "Formula:\n\\$\\$\n\\frac{a}{");
});

test("rejects over-long inline and display spans like the app", () => {
  const longInline = `$${"a+".repeat(70)}$`;
  assert.equal(normalizeMath(longInline), `\\$${"a+".repeat(70)}\\$`);
  const longDisplay = `$$${"x".repeat(401)}$$`;
  assert.equal(normalizeMath(longDisplay), `\\$\\$${"x".repeat(401)}\\$\\$`);
});

test("never touches dollars or delimiters inside code", () => {
  assert.equal(normalizeMath("run `echo $HOME $PATH` now"), "run `echo $HOME $PATH` now");
  assert.equal(normalizeMath("``a $1 ` $2``"), "``a $1 ` $2``");
});

test("prepareMarkdown skips fenced code, converts math fences, and closes open fences", () => {
  assert.equal(
    prepareMarkdown("Cost $5 or $9\n```bash\necho $5 $9\n```"),
    "Cost \\$5 or \\$9\n```bash\necho $5 $9\n```",
  );
  assert.equal(prepareMarkdown("```latex\n\\sum_i x_i\n```"), "$$\n\\sum_i x_i\n$$");
  assert.equal(prepareMarkdown("```math\nx^2"), "$$\nx^2\n$$");
  assert.equal(prepareMarkdown("Patch:\n```ts\nconst a = `$x$`;"), "Patch:\n```ts\nconst a = `$x$`;\n```");
});

test("prepareMarkdown drops ```thinking fences and normalises CRLF", () => {
  assert.equal(prepareMarkdown("a\r\n```thinking\nsecret\n```\r\nb"), "a\n\nb");
});
