#!/usr/bin/env node
// ops-compress.mjs — the input-axis token compressor (PostToolUse hook).
//
// Spec: docs/spec/input-axis-compressor.md. Tool output is re-billed on every
// later request in a session, so shrinking it once pays repeatedly. Measured on
// this project's own transcripts (2026-08-02, 10 sessions, 2340 tool_result
// blocks): 1.5% of blocks carry 25% of the volume, and eliding them saves ~12.6%
// of all re-billed characters. That skew is why an 8000-char threshold is the
// right knob — it touches 35 blocks and leaves 2305 alone.
//
// STRUCTURE: `compress()` is a PURE function of (payload, {env, cwd}) — no
// process.env reads, no implicit cwd — so every tunable is pinned from a test
// without mutating global state. The CLI wrapper at the bottom is the only part
// that touches the process. Node, not bash: the payload is JSON and the harness
// wants JSON back; bash 3.2 string handling would be the wrong tool, and this
// runs out-of-band from the shell readers the repo's bash-3.2 rule governs.
//
// I3 (never throws) is structural, not aspirational: `compress()` wraps its
// whole body in try/catch and returns null on ANY failure, and the CLI wrapper
// does the same again. A broken compressor must degrade to "no savings", never
// to "broken tool pipeline".

import fs from "node:fs";
import path from "node:path";
import crypto from "node:crypto";

// PINNED defaults. The spec requires the replay test to assert against these
// exact numbers rather than a tilde, so they live here once and the test reads
// them from here — two copies of a constant is one copy too many.
export const DEFAULTS = {
  SCRUB_MIN: 1024,
  MAX_CHARS: 8000,
  HEAD_BYTES: 6144,
  TAIL_BYTES: 4096,
  LINE_CHARS: 400,
  SALVAGE_LINES: 12,
  MIN_SHRINK: 64,
  SPILL_KEEP: 50,
};

// I1 — ALLOWLIST, never blocklist. A tool absent from this list defaults to
// uncompressed/safe. `Read`/`Edit`/`Write`/`NotebookEdit` are excluded forever:
// their output feeds exact-match edits, and eliding a Read makes the model edit
// against text it never saw. `mcp__*` is excluded entirely — the payload carries
// no read-only indicator, and a name-pattern guess (get|list|read) rots.
const ELIDABLE = new Set(["Bash", "WebFetch", "WebSearch", "Grep", "Glob"]);
// The allowlist above already excludes everything else by construction, so this
// set changes no behaviour — it exists to make the never-compress tools GREPPABLE
// and to give the failure mode a name at the point of decision. A reader (or
// validate_plugin.check_compressor) asking "is Read safe?" gets a literal answer
// here instead of having to prove a negative about the allowlist. Belt and
// braces: if a future edit widens ELIDABLE by accident, this still refuses.
const NEVER_COMPRESS = new Set(["Read", "Edit", "Write", "NotebookEdit"]);
// Agent: lossless tiers MAY apply, elide MUST NOT. A subagent's report is what
// the operator's verdict-from-report flow consumes; head/tail-eliding it breaks
// that flow exactly the way eliding a Read breaks edits.
const LOSSLESS_ONLY = new Set(["Agent"]);

// I2.2 — the ledger passes through by PATH, not by CLI name. Rendering the
// ledger is `cat`/`grep`/`tail` of the FILE; a mature ledger crosses the elide
// threshold past ~100 rows, and mid-body elision of PASS rows is precisely the
// falsification this plugin exists to prevent. Fixed-string, case-sensitive —
// no regex, because a metachar in a path would silently widen the match.
const LEDGER_PATHS = [
  ".operator/VERDICTS.md",
  ".operator/DECISIONS.md",
  ".operator/verdicts.d/",
];
// I2.1 — gate CLIs pass through. Nearly vacuous on its own (ops-verdict's output
// is one line, far under any threshold); listed for hygiene, and byte-checked
// against ops-init.sh's install set by validate_plugin.check_compressor.
const GATE_CLIS = ["ops-verdict.sh", "ops-task.sh", "ops-adopt.sh"];

// Salvage regex: the one line that mattered in a 3000-line build log. `not ok`
// is in here by name because TAP's failure marker contains no error WORD — a
// salvage list built from English error vocabulary misses every TAP failure,
// which is how a FAIL becomes a recorded PASS.
const SALVAGE_RE =
  /error|fail|traceback|panic|denied|refused|timed?[ -]out|assert|segfault|not ok|exception|fatal/i;

const num = (env, key, dflt) => {
  const v = env[`CC_OPERATOR_COMPRESS_${key}`];
  if (v == null || v === "") return dflt;
  const n = Number(v);
  return Number.isFinite(n) && n >= 0 ? n : dflt;
};

// Byte-bounded slice. The repo's standing reader invariant is bytes-not-lines
// (check_reader_bounds enforces it on every shell reader): a newline-less
// multi-MB line is ONE line to a line count and gets passed through whole.
const headBytes = (s, n) => Buffer.from(s, "utf8").subarray(0, n).toString("utf8");
const tailBytes = (s, n) => {
  const b = Buffer.from(s, "utf8");
  return b.subarray(Math.max(0, b.length - n)).toString("utf8");
};

const capLines = (s, cap) =>
  s.split("\n").map((l) => (l.length > cap ? l.slice(0, cap) + "…" : l)).join("\n");

// Tier 1 — SCRUB (lossless): ANSI/OSC escapes, ≥3 blank lines → 1, ≥4 identical
// consecutive lines → 1 + a count. No information lost, so it is safe on the
// LOSSLESS_ONLY tools too.
function scrub(text) {
  // eslint-disable-next-line no-control-regex
  let out = text.replace(/\][^]*(?:|\\)/g, "")
    // eslint-disable-next-line no-control-regex
    .replace(/\[[0-9;?]*[A-Za-z]/g, "");
  out = out.replace(/(?:[ \t]*\n){3,}/g, "\n\n");
  const lines = out.split("\n");
  const kept = [];
  let i = 0;
  while (i < lines.length) {
    let j = i;
    while (j + 1 < lines.length && lines[j + 1] === lines[i]) j++;
    const run = j - i + 1;
    kept.push(lines[i]);
    if (run >= 4) kept.push(`[repeated ${run}×]`);
    i = j + 1;
  }
  return kept.join("\n");
}

// Tier 2 — ELIDE: head + tail in BYTES, with salvage from the dropped middle.
function elide(text, K) {
  const head = headBytes(text, K.HEAD_BYTES);
  const tail = tailBytes(text, K.TAIL_BYTES);
  const midStart = head.length;
  const midEnd = text.length - tail.length;
  const middle = midEnd > midStart ? text.slice(midStart, midEnd) : "";
  const salvaged = [];
  if (middle) {
    for (const line of middle.split("\n")) {
      if (salvaged.length >= K.SALVAGE_LINES) break;
      if (SALVAGE_RE.test(line)) {
        salvaged.push(line.length > K.LINE_CHARS ? line.slice(0, K.LINE_CHARS) + "…" : line);
      }
    }
  }
  const dropped = Math.max(0, middle.length);
  const parts = [capLines(head, K.LINE_CHARS)];
  parts.push(`\n[… ${dropped} chars elided …]`);
  if (salvaged.length) parts.push(`[salvaged from the elided middle]\n${salvaged.join("\n")}`);
  parts.push(capLines(tail, K.LINE_CHARS));
  return parts.join("\n");
}

// I2.3 — spill-and-cite. Whenever the elide tier fires, the VERBATIM original is
// written to a session-scoped spill file and the compressed output names it. The
// charter rule that makes this binding: evidence taken from compressed output
// MUST cite the spill file. Without this, a mid-log failure that misses the
// salvage regex can turn a FAIL into a recorded PASS — the falsification I2
// exists to prevent, and the reason the gate-CLI exclusion alone was vacuous.
function spill(original, { cwd, session, toolUseId, keep }) {
  try {
    const dir = path.join(cwd, ".operator", ".compress-spill", session || "nosession");
    fs.mkdirSync(dir, { recursive: true });
    const name = String(toolUseId || `t${Date.now()}`).replace(/[^A-Za-z0-9_.-]/g, "_");
    const file = path.join(dir, name);
    fs.writeFileSync(file, original);
    // Bounded: delete oldest past `keep`. A spill directory that grows without
    // limit is a disk leak in a long session.
    const entries = fs.readdirSync(dir)
      .map((f) => ({ f, t: fs.statSync(path.join(dir, f)).mtimeMs }))
      .sort((a, b) => a.t - b.t);
    for (const e of entries.slice(0, Math.max(0, entries.length - keep))) {
      try { fs.unlinkSync(path.join(dir, e.f)); } catch { /* best effort */ }
    }
    return path.relative(cwd, file);
  } catch {
    return null; // spill failure must not break compression, only remove the cite
  }
}

// Dedup is the only STATEFUL tier, so its state is specced: a per-(session,tool)
// SHA-256 of the previous output — never the bytes — cleared by the SessionStart
// hook, including the compact re-fire (compaction can prune the prior output
// from context, and "it is already in context" is the marker's whole
// justification). Skipped entirely when the payload carries no session_id.
function dedupCheck(text, { cwd, session, tool }) {
  if (!session) return false;
  try {
    const dir = path.join(cwd, ".operator", ".compress-state", session);
    fs.mkdirSync(dir, { recursive: true });
    const f = path.join(dir, String(tool).replace(/[^A-Za-z0-9_.-]/g, "_"));
    const h = crypto.createHash("sha256").update(text).digest("hex");
    const prev = fs.existsSync(f) ? fs.readFileSync(f, "utf8").trim() : "";
    fs.writeFileSync(f, h);
    return prev === h;
  } catch {
    return false;
  }
}

// I5 — rebuild the ORIGINAL response shape. Bash results are objects
// {stdout, stderr, ...}, not bare strings; handing back a bare string is
// rejected on every call — the hook errors visibly while the model still gets
// the full output. An unrecognized shape → skip, never a blind guess.
function readShape(resp) {
  if (typeof resp === "string") return { kind: "string", text: resp };
  if (resp && typeof resp === "object" && !Array.isArray(resp)) {
    if (typeof resp.stdout === "string") {
      return { kind: "bash", text: resp.stdout, stderr: typeof resp.stderr === "string" ? resp.stderr : "" };
    }
    if (typeof resp.content === "string") return { kind: "content", text: resp.content };
  }
  return null;
}

function rebuild(shape, resp, text) {
  if (shape.kind === "string") return text;
  if (shape.kind === "bash") return { ...resp, stdout: text, stderr: "" };
  if (shape.kind === "content") return { ...resp, content: text };
  return null;
}

export function compress(payload, opts = {}) {
  try {
    const env = opts.env ?? {};
    const cwd = opts.cwd ?? process.cwd();
    if (env.CC_OPERATOR_COMPRESS === "0") return null;
    if (!payload || typeof payload !== "object" || Array.isArray(payload)) return null;

    const tool = payload.tool_name;
    if (typeof tool !== "string") return null;
    // I1: the named never-compress set first, then the allowlist. The explicit
    // check is redundant with the allowlist today and stays anyway: it is the
    // one that survives someone widening ELIDABLE without reading this far.
    if (NEVER_COMPRESS.has(tool)) return null;
    if (tool.startsWith("mcp__")) return null;
    // I1: unknown tool → uncompressed/safe.
    const elidable = ELIDABLE.has(tool);
    const losslessOnly = LOSSLESS_ONLY.has(tool);
    if (!elidable && !losslessOnly) return null;

    const shape = readShape(payload.tool_response);
    if (!shape) return null;

    // I2.1/I2.2 — the evidence-gate carve-out, checked on the COMMAND string by
    // fixed-string substring match. A Grep whose target path names the ledger
    // takes the same exit.
    const cmd = String(payload.tool_input?.command ?? payload.tool_input?.pattern ?? "") +
      " " + String(payload.tool_input?.path ?? "");
    if (LEDGER_PATHS.some((p) => cmd.includes(p))) return null;
    if (GATE_CLIS.some((c) => cmd.includes(c))) return null;

    const K = {
      SCRUB_MIN: num(env, "SCRUB_MIN", DEFAULTS.SCRUB_MIN),
      MAX_CHARS: num(env, "MAX_CHARS", DEFAULTS.MAX_CHARS),
      HEAD_BYTES: num(env, "HEAD_BYTES", DEFAULTS.HEAD_BYTES),
      TAIL_BYTES: num(env, "TAIL_BYTES", DEFAULTS.TAIL_BYTES),
      LINE_CHARS: num(env, "LINE_CHARS", DEFAULTS.LINE_CHARS),
      SALVAGE_LINES: num(env, "SALVAGE_LINES", DEFAULTS.SALVAGE_LINES),
      MIN_SHRINK: num(env, "MIN_SHRINK", DEFAULTS.MIN_SHRINK),
    };

    const original = shape.text;
    // stderr is folded into the compressed text then blanked, so the content
    // survives without being duplicated across two fields.
    let text = shape.kind === "bash" && shape.stderr ? `${original}\n${shape.stderr}` : original;
    const beforeLen = text.length;

    if (env.CC_OPERATOR_COMPRESS_DEDUP !== "0" && text.length >= K.SCRUB_MIN) {
      if (dedupCheck(text, { cwd, session: payload.session_id, tool })) {
        const marker = `[identical to this tool's previous output — unchanged, ${beforeLen} chars]`;
        const out = rebuild(shape, payload.tool_response, marker);
        return out == null ? null : {
          hookSpecificOutput: { hookEventName: "PostToolUse", updatedToolOutput: out },
        };
      }
    }

    // Snapshot the combined output (stdout + folded stderr) BEFORE scrub mutates
    // it. The spill contract (I2.3, the comment at spill()) is "verbatim
    // original" — collapsing repeats and stripping ANSI is a lossy transform, so
    // spilling the scrubbed `text` broke it in a second dimension: the operator
    // citing the spill could no longer recover byte-identical output. The F50
    // fix (spilling `text` not `original`) fixed the stderr loss but inherited
    // this scrub loss. Spill the pre-scrub snapshot; elide the scrubbed text
    // (pr-review finding 6, 2026-08-03).
    const combined = text;
    if (env.CC_OPERATOR_COMPRESS_SCRUB !== "0" && text.length > K.SCRUB_MIN) text = scrub(text);

    let spillPath = null;
    if (elidable && text.length > K.MAX_CHARS) {
      spillPath = spill(combined, {
        cwd, session: payload.session_id, toolUseId: payload.tool_use_id, keep: DEFAULTS.SPILL_KEEP,
      });
      text = elide(text, K);
      if (spillPath) text += `\n[full output spilled to ${spillPath} — evidence quoted from this output MUST cite that file]`;
    }

    // I4 — never credit savings the harness refused to apply.
    if (beforeLen - text.length < K.MIN_SHRINK) return null;

    const out = rebuild(shape, payload.tool_response, text);
    if (out == null) return null;
    return { hookSpecificOutput: { hookEventName: "PostToolUse", updatedToolOutput: out } };
  } catch {
    return null; // I3 — never throws.
  }
}

// ── CLI wrapper: the only part that touches the process ─────────────────────
// Emit nothing on any failure. Returning nothing (skip) is always safer than
// emitting a shape the harness refuses.
const isMain = process.argv[1] && import.meta.url === pathToFileURLSafe(process.argv[1]);
function pathToFileURLSafe(p) {
  try { return new URL(`file://${path.resolve(p)}`).href; } catch { return ""; }
}
if (isMain) {
  let raw = "";
  process.stdin.setEncoding("utf8");
  process.stdin.on("data", (c) => { raw += c; });
  process.stdin.on("end", () => {
    try {
      const out = compress(JSON.parse(raw), { env: process.env, cwd: process.cwd() });
      if (out) process.stdout.write(JSON.stringify(out));
    } catch { /* I3 */ }
    process.exit(0);
  });
  process.stdin.on("error", () => process.exit(0));
}
