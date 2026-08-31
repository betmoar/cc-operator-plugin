#!/usr/bin/env node
// ops-compress.mjs — the input-axis token compressor (PostToolUse hook).
//
// Spec: docs/spec/input-axis-compressor.md. Tool output is re-billed on every
// later request in a session, so shrinking it once pays repeatedly (measured
// 2026-08-02: 1.5% of blocks carry 25% of the volume). Runs ONLY in operated
// projects: without `.operator/` there is no spill and no dedup — elide still
// happens, marked "not spilled". The spill contract binds only where the
// charter does, and the charter exists only where `.operator/` does.
//
// STRUCTURE: `compress()` is a PURE function of (payload, {env, cwd}) — every
// tunable is pinnable from a test without mutating global state. I3 (never
// throws) is structural: compress() wraps its whole body in try/catch and
// returns null on ANY failure — a broken compressor degrades to "no savings",
// never to "broken tool pipeline".

import fs from "node:fs";
import path from "node:path";
import crypto from "node:crypto";

// PINNED defaults — read from here by the replay test, never restated there.
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
// Greppable belt-and-braces twin of the allowlist: if a future edit widens
// ELIDABLE by accident, this still refuses the never-compress tools.
const NEVER_COMPRESS = new Set(["Read", "Edit", "Write", "NotebookEdit"]);
// Agent: lossless tiers MAY apply, elide MUST NOT (the verdict-from-report
// flow consumes a subagent's report whole).
const LOSSLESS_ONLY = new Set(["Agent"]);

// I2.2 — the ledger passes through by PATH, not by CLI name: mid-body elision
// of PASS rows is precisely the falsification this plugin exists to prevent.
// Fixed-string, case-sensitive (a metachar in a path would widen the match).
const LEDGER_PATHS = [
  ".operator/VERDICTS.md",
  ".operator/DECISIONS.md",
  ".operator/verdicts.d/",
];
// I2.1 — gate CLIs pass through. Nearly vacuous alone (ops-verdict's output is
// one line); byte-checked against ops-init's install set by check_compressor.
const GATE_CLIS = ["ops-verdict.sh", "ops-task.sh", "ops-adopt.sh", "ops-claims.sh"];

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

// Byte-bounded slice — the repo's standing reader invariant is bytes-not-lines:
// a newline-less multi-MB line is ONE line to a line count and would pass whole.
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
  // Both regexes MUST carry the \x1b anchor (audit F120): the 0.10.0 debloat
  // stripped the raw ESC bytes out of these literals, and without the anchor
  // the OSC pattern's empty alternation matched from the first bare `]` to
  // end-of-string — a 3KB test log came back as one character, no marker, no
  // spill. The OSC body is lazy and needs a real terminator (BEL or ESC-\):
  // an unterminated escape stays visible, which is the lossless direction.
  // eslint-disable-next-line no-control-regex
  let out = text.replace(/\x1b\][^]*?(?:\x07|\x1b\\)/g, "")
    // eslint-disable-next-line no-control-regex
    .replace(/\x1b\[[0-9;?]*[A-Za-z]/g, "");
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
  // NEUTRAL marker (audit F121): elide cannot know whether the caller spilled,
  // and the old "no .operator/, not spilled" text shipped alongside a real
  // "[full output spilled to …]" line — contradictory provenance. The caller's
  // appended line is the single source of spill status.
  parts.push(`\n[… ${dropped} chars elided …]`);
  if (salvaged.length) parts.push(`[salvaged from the elided middle]\n${salvaged.join("\n")}`);
  parts.push(capLines(tail, K.LINE_CHARS));
  return parts.join("\n");
}

// The spill root: `.operator/` must already exist (we never create it — the
// compressor fires wherever the plugin is installed, and a project that never
// ran /cc-operator:start must not wake up to an uninvited `.operator/`).
// Each root carries its OWN `.gitignore` holding `*` so the tree stays clean
// without depending on ops-init ever having run.
function ephemeralRoot(cwd, kind) {
  const opdir = path.join(cwd, ".operator");
  // lstat, not existsSync (audit F122): a symlinked .operator/ would redirect
  // spills (unredacted tool output) and dedup state outside the project —
  // partition.sh refuses a symlinked ledger for the same F65 class. A link is
  // never ours; treat it as "no .operator/" (no spill, no dedup).
  let st = null;
  try { st = fs.lstatSync(opdir); } catch { return null; }
  if (!st.isDirectory()) return null;
  const root = path.join(opdir, kind);
  fs.mkdirSync(root, { recursive: true });
  writeSelfIgnore(root);
  return root;
}

// `*` ignores the directory's whole contents including itself; best-effort —
// a failed ignore must never cost the session its spill.
function writeSelfIgnore(root) {
  try {
    const gi = path.join(root, ".gitignore");
    if (!fs.existsSync(gi)) fs.writeFileSync(gi, "*\n", { mode: 0o600 });
  } catch { /* best effort */ }
}

// F3 — session_id arrives raw from the payload (untrusted). Sanitize to the
// same charset as toolUseId, then verify the resolved path cannot escape
// `base`. A dot-only sid is refused BEFORE the containment test: `.` resolves
// to `base` itself — not a traversal, a COLLAPSE, and the damage is on the
// other side: spill()'s `keep` cleanup unlinks the oldest entries of whatever
// directory it is handed, so a collapsed session prunes every other session's
// spills — which hold UNREDACTED tool output.
function sanitizeSessionId(base, session) {
  const sid = String(session || "nosession").replace(/[^A-Za-z0-9_.-]/g, "_");
  if (/^\.+$/.test(sid)) return "nosession";
  const resolvedBase = path.resolve(base);
  const resolvedDir = path.resolve(base, sid);
  if (sid && resolvedDir !== resolvedBase && resolvedDir.startsWith(resolvedBase + path.sep)) {
    return sid;
  }
  return "nosession";
}

function spill(original, { cwd, session, toolUseId, keep }) {
  try {
    const base = ephemeralRoot(cwd, ".compress-spill");
    if (!base) return null;   // not an operated project — caller marks "not spilled"
    const dir = path.join(base, sanitizeSessionId(base, session));
    fs.mkdirSync(dir, { recursive: true, mode: 0o700 });
    const name = String(toolUseId || `t${Date.now()}`).replace(/[^A-Za-z0-9_.-]/g, "_");
    const file = path.join(dir, name);
    // 0600: the spill holds the UNREDACTED tool output. `writeFileSync`'s mode
    // applies only at creation, so an existing file is re-tightened explicitly.
    fs.writeFileSync(file, original, { mode: 0o600 });
    try { fs.chmodSync(file, 0o600); } catch { /* best effort */ }
    // Bounded: delete oldest past `keep`. F18 — an entry can vanish between
    // readdirSync and statSync (a concurrent spill's own cleanup); an
    // unguarded statSync would throw out of the map into the outer catch,
    // turning a benign race into a full spill FAILURE, so it sorts oldest-first
    // (preferred for deletion) instead.
    const entries = fs.readdirSync(dir)
      .map((f) => {
        try {
          return { f, t: fs.statSync(path.join(dir, f)).mtimeMs };
        } catch {
          return { f, t: -Infinity };
        }
      })
      .sort((a, b) => a.t - b.t);
    for (const e of entries.slice(0, Math.max(0, entries.length - keep))) {
      try { fs.unlinkSync(path.join(dir, e.f)); } catch { /* best effort */ }
    }
    // Relative while the spill lives under cwd (the readable, citable form the
    // charter rule assumes).
    const rel = path.relative(cwd, file);
    return rel.startsWith("..") ? file : rel;
  } catch {
    return null; // spill failure must not break compression, only remove the cite
  }
}

// Dedup is the only STATEFUL tier: a per-(session,tool) SHA-256 of the previous
// output — never the bytes — cleared by the SessionStart hook, including the
// compact re-fire (compaction can prune the prior output from context, and "it
// is already in context" is the marker's whole justification). Skipped entirely
// when the payload carries no session_id or the project is not operated.
function dedupCheck(text, { cwd, session, tool }) {
  if (!session) return false;
  try {
    const base = ephemeralRoot(cwd, ".compress-state");
    if (!base) return false;   // not operated → no dedup; never a false HIT
    const dir = path.join(base, sanitizeSessionId(base, session));
    fs.mkdirSync(dir, { recursive: true, mode: 0o700 });
    const f = path.join(dir, String(tool).replace(/[^A-Za-z0-9_.-]/g, "_"));
    const h = crypto.createHash("sha256").update(text).digest("hex");
    const prev = fs.existsSync(f) ? fs.readFileSync(f, "utf8").trim() : "";
    fs.writeFileSync(f, h, { mode: 0o600 });
    return prev === h;
  } catch {
    return false;
  }
}

// I5 — rebuild the ORIGINAL response shape. Bash results are objects
// {stdout, stderr, ...}, not bare strings; a bare string is rejected on every
// call. An unrecognized shape → skip, never a blind guess.
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

    // Snapshot the combined output BEFORE scrub mutates it — the spill contract
    // is "verbatim original", and spilling the scrubbed text broke it in a
    // second dimension (F50 fixed the stderr loss and inherited this one).
    const combined = text;
    if (env.CC_OPERATOR_COMPRESS_SCRUB !== "0" && text.length > K.SCRUB_MIN) text = scrub(text);

    let spillPath = null;
    if (elidable && text.length > K.MAX_CHARS) {
      spillPath = spill(combined, {
        cwd, session: payload.session_id, toolUseId: payload.tool_use_id, keep: DEFAULTS.SPILL_KEEP,
      });
      text = elide(text, K);
      // A failed spill must not read as a complete output: elided text with no
      // marker is indistinguishable from short text that was never touched —
      // the I2.3 falsification class through the failure path.
      // The no-spill wording must not assert a cause it cannot know (audit
      // F121): a FAILED spill in an operated project took this branch too, and
      // "a project with no .operator/" was then simply false.
      text += spillPath
        ? `\n[full output spilled to ${spillPath} — evidence quoted from this output MUST cite that file]`
        : `\n[output elided with NO spill copy (no .operator/ here, or the spill could not be written) — re-run the command if the elided middle matters]`;
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
