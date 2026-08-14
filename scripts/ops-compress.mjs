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
import os from "node:os";
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
// Both ephemera roots below are created with `recursive: true`, which CREATES
// `.operator/` itself when it is absent. The compressor is a PostToolUse hook: it
// fires in every project where the plugin is merely INSTALLED, including ones
// that never ran /cc-operator:start. So the naive path materialized a `.operator/`
// — and, because `ops-init.sh` never ran there, one with no `.gitignore` — in
// unrelated repos, showing up as untracked dirty state the user never asked for.
//
// Containment, both halves required:
//   (A) self-sufficient ignore. Each ephemera root carries its OWN `.gitignore`
//       holding `*`, written at creation. It does not depend on ops-init or the
//       SessionStart append ever having run, so the tree stays clean even in a
//       project that has no `.operator/.gitignore` at all.
//   (B) no uninvited directory. When `.operator/` does not exist we do NOT create
//       it; the root moves to the system tempdir, keyed by a hash of cwd so two
//       projects never share one. Spill/dedup keep working (the charter's
//       spilled-to cite names whatever path is returned) without leaving a
//       footprint in a project that never opted in.
//   (C) not readable by other local users. The tempdir branch is the one that
//       leaves the project, and `os.tmpdir()` is `/tmp` on Linux — world-
//       writable and shared, where the CI runners live. The key is
//       sha256(cwd)[0:16]: derivable by anyone who can guess the checkout path,
//       with no secret in it. Under default modes (dirs 0755, files 0644) any
//       local user could READ pre-scrub tool output — the unredacted text, which
//       is exactly what the spill exists to preserve. Worse, `mkdirSync` follows
//       symlinks, so a user who pre-creates the shared `cc-operator` root as a
//       symlink redirects every later spill into a directory they control
//       (demonstrated 2026-08-12, Copilot review of PR #12). So: the shared
//       segment carries the uid, each level is created 0700 and verified to be a
//       real directory we own, and spill files are written 0600.
const TMP_ROOT_NAME = `cc-operator-${typeof process.getuid === "function"
  ? process.getuid() : "nouid"}`;

// Create `dir` with mode 0700 and refuse anything that is not a directory we
// just made or already own. Returns false when the path cannot be trusted, and
// the caller degrades rather than writing into an attacker-chosen location.
function secureMkdir(dir) {
  try {
    fs.mkdirSync(dir, { recursive: true, mode: 0o700 });
  } catch (e) {
    if (e.code !== "EEXIST") return false;
  }
  let st;
  try {
    st = fs.lstatSync(dir);           // lstat: a symlink must NOT be followed
  } catch { return false; }
  if (!st.isDirectory()) return false;
  if (typeof process.getuid === "function" && st.uid !== process.getuid()) return false;
  // Tighten an existing directory that predates this change (it was 0755).
  if ((st.mode & 0o077) !== 0) {
    try { fs.chmodSync(dir, 0o700); } catch { return false; }
  }
  return true;
}

function ephemeralRoot(cwd, kind) {
  const opdir = path.join(cwd, ".operator");
  const inProject = fs.existsSync(opdir);
  if (inProject) {
    const root = path.join(opdir, kind);
    fs.mkdirSync(root, { recursive: true });
    writeSelfIgnore(root);
    return root;
  }
  // Outside a project: every segment below the tempdir is ours, 0700, checked.
  const hash = crypto.createHash("sha256").update(cwd).digest("hex").slice(0, 16);
  const base = path.join(os.tmpdir(), TMP_ROOT_NAME);
  const keyed = path.join(base, hash);
  const root = path.join(keyed, kind);
  if (!secureMkdir(base) || !secureMkdir(keyed) || !secureMkdir(root)) return null;
  writeSelfIgnore(root);
  return root;
}

// `*` ignores the directory's whole contents including itself; idempotent, and
// best-effort because a failed ignore must never cost the session its spill.
function writeSelfIgnore(root) {
  try {
    const gi = path.join(root, ".gitignore");
    if (!fs.existsSync(gi)) fs.writeFileSync(gi, "*\n", { mode: 0o600 });
  } catch { /* best effort — containment is a nicety, the spill is the contract */ }
}

// F3 — session_id arrives raw from the payload (untrusted). Sanitize to the
// same charset as toolUseId, then verify the resolved path cannot escape
// `base` (a defense-in-depth belt for the charset allowlist, not a
// substitute for it) — anything that fails either check falls back to
// "nosession" rather than ever joining an attacker-controlled path segment.
// A dot-only sid is refused BEFORE the containment test, because containment is
// the wrong question for it: `.` resolves to `base` itself, which is inside
// `base` and so passed — the sid then names no subdirectory at all and every
// session shares one bucket. That is not a traversal (`..` was already caught,
// it resolves outside), it is a COLLAPSE, and the damage is on the other side:
// spill()'s `keep` cleanup unlinks the oldest entries of whatever directory it
// is handed, so a collapsed session prunes every other session's spills — and
// those hold UNREDACTED tool output. `...` and longer runs are refused for the
// same reason they are refused everywhere else: a name that is only dots is
// never a session id our harness emits, so admitting it buys nothing.
// (Copilot review of PR #56, round 2. `session_id` is raw payload — the same
// untrusted input F3 was about.)
function sanitizeSessionId(base, session) {
  const sid = String(session || "nosession").replace(/[^A-Za-z0-9_.-]/g, "_");
  if (/^\.+$/.test(sid)) return "nosession";
  const resolvedBase = path.resolve(base);
  const resolvedDir = path.resolve(base, sid);
  // `resolvedDir === resolvedBase` can no longer be reached by a dot-only sid;
  // it stays because path.resolve may still collapse some future input to it,
  // and returning a sid that names `base` is what the line above now forbids.
  if (sid && resolvedDir !== resolvedBase && resolvedDir.startsWith(resolvedBase + path.sep)) {
    return sid;
  }
  return "nosession";
}

function spill(original, { cwd, session, toolUseId, keep }) {
  try {
    // null = the root could not be established as ours (a hijacked tempdir
    // path). No spill is better than pre-scrub output written somewhere another
    // user chose; the caller drops the cite and compression continues.
    const base = ephemeralRoot(cwd, ".compress-spill");
    if (!base) return null;
    const dir = path.join(base, sanitizeSessionId(base, session));
    fs.mkdirSync(dir, { recursive: true, mode: 0o700 });
    const name = String(toolUseId || `t${Date.now()}`).replace(/[^A-Za-z0-9_.-]/g, "_");
    const file = path.join(dir, name);
    // 0600: the spill holds the UNREDACTED tool output. `writeFileSync`'s mode
    // applies only at creation, so an existing file is re-tightened explicitly.
    fs.writeFileSync(file, original, { mode: 0o600 });
    try { fs.chmodSync(file, 0o600); } catch { /* best effort */ }
    // Bounded: delete oldest past `keep`. A spill directory that grows without
    // limit is a disk leak in a long session.
    const entries = fs.readdirSync(dir)
      .map((f) => {
        // F18 — an entry can vanish between readdirSync and statSync (a
        // concurrent spill's own cleanup). An unguarded statSync throws out
        // of the map into spill()'s outer catch, turning a benign race into
        // a full spill FAILURE. Sort it oldest-first so it is preferred for
        // deletion rather than kept.
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
    // charter rule assumes); absolute once it does not, because a `../../..`
    // walk out of the project is neither readable nor stable to cite.
    const rel = path.relative(cwd, file);
    return rel.startsWith("..") ? file : rel;
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
    const base = ephemeralRoot(cwd, ".compress-state");
    if (!base) return false;   // no trusted root → no dedup; never a false HIT
    // F3 — same untrusted session_id as spill(); "nosession" here just means
    // dedup degrades to a shared bucket, never a false HIT across sessions
    // and never a path outside `base`.
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
      // A failed spill must not read as a complete output: elided text with no
      // marker is indistinguishable from short text that was never touched —
      // the I2.3 falsification class through the failure path (pr-review
      // finding, 2026-08-03). Mark the failure explicitly instead.
      text += spillPath
        ? `\n[full output spilled to ${spillPath} — evidence quoted from this output MUST cite that file]`
        : `\n[output TRUNCATED and the spill to disk FAILED — no full copy exists; re-run the command if the elided middle matters]`;
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
