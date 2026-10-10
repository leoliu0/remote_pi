// Pure text preparation for the assistant markdown renderer. No React here so
// node:test can exercise it directly (markdown-text.test.ts).
//
// The parser (react-markdown + remark-gfm + remark-math) handles the grammar;
// this module only fixes what it cannot know about chat text:
//  - `\(..\)` / `\[..\]` LaTeX delimiters, which remark-math does not read;
//  - stray `$` (currency, prose) that remark-math would pair into "math";
//  - ```math / ```latex / ```tex fences, which the phone app renders as math;
//  - a code fence left open by a stream that has not finished yet.
// The math acceptance rules mirror app/lib/ui/chat/widgets/agent_markdown.dart.

interface Fence {
  indent: string;
  marker: string;
  lang: string;
}

const FENCE_OPEN = /^([ \t]*)(`{3,}|~{3,})(.*)$/;
const MATH_FENCE_LANGS: Record<string, true> = { math: true, latex: true, tex: true };
const MAX_INLINE_MATH = 120;
const MAX_DISPLAY_MATH = 400;

function parseFenceOpen(line: string): Fence | null {
  const m = FENCE_OPEN.exec(line);
  if (!m) return null;
  const [, indent, marker, rest] = m;
  // CommonMark: a backtick fence's info string may not contain a backtick.
  if (marker[0] === "`" && rest.includes("`")) return null;
  return { indent, marker, lang: rest.trim().split(/\s+/)[0]?.toLowerCase() ?? "" };
}

function closesFence(line: string, fence: Fence): boolean {
  const trimmed = line.trim();
  const ch = fence.marker[0];
  let n = 0;
  while (n < trimmed.length && trimmed[n] === ch) n++;
  return n >= fence.marker.length && n === trimmed.length;
}

/** App guard: is the body of a `$..$` span real math rather than prose/currency? */
function acceptInlineMath(body: string): boolean {
  const t = body.trim();
  if (!t || t.length > MAX_INLINE_MATH) return false;
  if (/^\d[\d,.]*$/.test(t)) return false;
  if (/^\d/.test(t) && !/[\\=^_<>+\-*/]/.test(t)) return false;
  if (t.includes(" ") && !/[\\=^_<>+\-*/{}()]/.test(t)) return false;
  return true;
}

// `$` + non-space body without `$`/newline + `$` not preceded by space or `\`.
const INLINE_DOLLAR = /^\$(?!\s)([^$\n]+?)(?<![\s\\])\$/;

/**
 * Rewrites LaTeX delimiters into the `$` / `$$` form remark-math reads and
 * escapes every other `$`, so only spans the app would render become math.
 * Code spans are copied verbatim. Fenced code must be removed by the caller.
 */
export function normalizeMath(src: string): string {
  if (!src.includes("$") && !src.includes("\\(") && !src.includes("\\[")) return src;
  let out = "";
  let i = 0;

  const emitDisplay = (body: string, end: number) => {
    const lineStart = out.lastIndexOf("\n") + 1;
    const prefix = out.slice(lineStart);
    const restOfLine = src.slice(end, src.indexOf("\n", end) === -1 ? src.length : src.indexOf("\n", end));
    if (/^[ \t]*$/.test(prefix) && /^[ \t]*$/.test(restOfLine)) {
      // Standalone: emit a `$$` block so it renders as display math, keeping
      // the indentation that places it inside a list item.
      const lines = body
        .split("\n")
        .map((l) => l.trim())
        .filter(Boolean)
        .map((l) => prefix + l);
      out += `$$\n${lines.join("\n")}\n${prefix}$$`;
      i = end + restOfLine.length;
    } else {
      out += `$$${body.trim()}$$`;
      i = end;
    }
  };

  while (i < src.length) {
    const ch = src[i];

    if (ch === "`") {
      let n = 1;
      while (src[i + n] === "`") n++;
      const run = "`".repeat(n);
      const close = new RegExp(`(?<!\`)${run}(?!\`)`, "g");
      close.lastIndex = i + n;
      const m = close.exec(src);
      const end = m ? m.index + n : i + n;
      out += src.slice(i, end);
      i = end;
      continue;
    }

    if (ch === "\\") {
      const next = src[i + 1];
      if (next === "(" || next === "[") {
        const closer = next === "(" ? "\\)" : "\\]";
        const end = src.indexOf(closer, i + 2);
        const body = end === -1 ? "" : src.slice(i + 2, end);
        if (next === "(" && end !== -1 && acceptInlineMath(body)) {
          out += `$${body.trim()}$`;
          i = end + 2;
          continue;
        }
        if (next === "[" && end !== -1 && body.trim() && body.length <= MAX_DISPLAY_MATH) {
          emitDisplay(body, end + 2);
          continue;
        }
      }
      out += src.slice(i, i + 2);
      i += 2;
      continue;
    }

    if (ch === "$") {
      if (src[i + 1] === "$") {
        const end = src.indexOf("$$", i + 2);
        const body = end === -1 ? "" : src.slice(i + 2, end);
        if (end !== -1 && body.trim() && body.length <= MAX_DISPLAY_MATH) {
          emitDisplay(body, end + 2);
        } else {
          out += "\\$\\$";
          i += 2;
        }
        continue;
      }
      const m = INLINE_DOLLAR.exec(src.slice(i, i + MAX_INLINE_MATH + 4));
      if (m && acceptInlineMath(m[1])) {
        out += m[0];
        i += m[0].length;
        continue;
      }
      out += "\\$";
      i++;
      continue;
    }

    out += ch;
    i++;
  }
  return out;
}

/**
 * Full preparation pass: normalises line endings, drops ```thinking fences,
 * turns math fences into `$$` blocks, normalises math in prose only, and
 * closes a code fence left open by a stream.
 */
export function prepareMarkdown(text: string): string {
  const src = (text || "").replace(/\r\n?/g, "\n").replace(/```thinking[\s\S]*?```/gi, "");
  const out: string[] = [];
  let prose: string[] = [];
  const flushProse = () => {
    if (prose.length) out.push(normalizeMath(prose.join("\n")));
    prose = [];
  };

  const lines = src.split("\n");
  for (let i = 0; i < lines.length; i++) {
    const fence = parseFenceOpen(lines[i]);
    if (!fence) {
      prose.push(lines[i]);
      continue;
    }
    flushProse();
    const opener = lines[i];
    const body: string[] = [];
    let closed = false;
    for (i++; i < lines.length; i++) {
      if (closesFence(lines[i], fence)) {
        closed = true;
        break;
      }
      body.push(lines[i]);
    }
    if (MATH_FENCE_LANGS[fence.lang] === true) {
      out.push(`${fence.indent}$$`, ...body, `${fence.indent}$$`);
    } else {
      out.push(opener);
      // A stream can stop mid-block: close the fence so later text stays code.
      out.push(...body, closed ? lines[i] : `${fence.indent}${fence.marker}`);
    }
  }
  flushProse();
  return out.join("\n").trim();
}
