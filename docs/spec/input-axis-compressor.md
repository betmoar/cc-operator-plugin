# Spec — input-axis token compressor (PostToolUse hook)

Status: **SPEC ONLY — no implementation exists.** This is the boundary contract that
must be written (it is) and reviewed before a line of hook code is. The reference
implementation is Chisle's `hooks/chisle-compress-output.js` (read directly from
github.com/JayPokale/Chisle; zero-dependency, zero-LLM, deterministic).

## Why

Chisle compresses three token axes: output prose (YAGNI/zero-fluff), output code
(YAGNI ladder), and **input context** (tool output). cc-operator ships the first
(axis 1: prose discipline, in `templates/OPERATOR.md`). This spec is axis 3: a
PostToolUse hook that shrinks what the agent READS. Tool output is re-billed on
every later request in a session, so shrinking it once pays repeatedly — the
highest-leverage unserved efficiency axis (audit F11, 2026-07-30).

## The mechanism

A PostToolUse hook receives `{tool_name, tool_response, session_id}` and may return
`{hookSpecificOutput:{hookEventName:"PostToolUse", updatedToolOutput:<rebuilt>}}`.
The harness validates `updatedToolOutput` against the tool's own output schema before
applying it — a wrong shape is **silently rejected** and the model receives the full
output. Returning nothing (skip) is always safer than emitting a shape the harness
refuses.

Two tiers, applied in order, both deterministic (no LLM, no network):

1. **Scrub** (lossless, output > ~1k chars): strip ANSI/OSC escapes, collapse
   ≥3 blank lines to one, collapse ≥4 identical consecutive lines to one +
   `[repeated N×]`. No information lost.
2. **Elide** (output > threshold, e.g. 8000 chars): keep head (~60 lines) + tail
   (~40 lines); **salvage** error-looking lines from the elided middle (regex on
   error/fail/traceback/panic/denied/refused/timed-out/assert/segfault, capped at
   ~12 lines, each line char-capped), so the one line that mattered in a 3000-line
   build log survives the cut.

Plus **dedup**: a tool output byte-identical to that tool's immediately-previous
output → a short marker. The content is already in context, so the marker loses
nothing — but ONLY within a session (keyed by `session_id`; skipped when the
payload carries none).

No-op rule: if compression does not shrink the output by ≥ ~64 chars, keep the
original. Never credit savings the harness refused to apply.

## Non-negotiable invariants (from Chisle + cc-operator)

### I1 — allowlist, never blocklist
Compress ONLY: `Bash`, `Agent`, `WebFetch`, `WebSearch`, `Grep`, `Glob`, and
read-only `mcp__*`. **`Read`, `Edit`, `Write`, `NotebookEdit` are excluded forever.**
Their output feeds exact-match edits — eliding a `Read` result makes the model
edit against text it never saw (`old_string` matching breaks). An allowlist means a
new tool defaults to *uncompressed/safe*, not *compressed/broken*.

### I2 — the evidence-gate carve-out (cc-operator's addition; Chisle lacks this)
The compressor MUST NOT touch tool output that is, or feeds, the evidence gate. A
compressed verdict trail falsifies the single thing this plugin exists to protect.
Concretely:
- When capturing verdict evidence, the compressor is OFF. (Detection: the operator
  is mid-`ops-verdict` / a sentinel is open and being closed. Spec the exact signal
  before implementation — likely a sentinel-presence or a session-scoped flag.)
- The gate CLIs are on the exclusion list regardless: any `Bash` invocation of
  `.operator/bin/ops-verdict.sh`, `ops-task.sh`, `ops-adopt.sh`, or the plugin's
  own `scripts/ops-*.sh` is passed through untouched. A verdict ledger must render
  verbatim.

This is the rule the prior snapshot said must be written before the hook exists.
It is written now.

### I3 — never throws
A broken hook must not break the tool pipeline. The entire hook body is one
try/catch that swallows and emits nothing on any failure.

### I4 — no-op when no shrink
Keep the original unless the compressed form is meaningfully smaller (≥ ~64 chars).

### I5 — rebuild the original response shape
Bash results are objects `{stdout, stderr, ...}`, not bare strings. Handing back a
bare string is rejected on every call — the hook appears to work, logs savings, and
the model still gets the full output. `rebuildResponse` must return the compressed
text in the original shape (fold `stderr` into the compressed text, then blank it,
to avoid duplication). An unrecognized shape → skip (emit nothing).

## Kill switches / tunables (env)
- `CC_OPERATOR_COMPRESS=0` — global kill switch
- `CC_OPERATOR_COMPRESS_SCRUB=0` — disable lossless scrub tier
- `CC_OPERATOR_COMPRESS_DEDUP=0` — disable duplicate markers
- `CC_OPERATOR_COMPRESS_MAX_CHARS` — outputs at/under this size are not elided
- `CC_OPERATOR_COMPRESS_HEAD_LINES` / `_TAIL_LINES` — head/tail retention

## Validator guardrails (Phase 4, before merge)
1. `hooks/hooks.json` has a PostToolUse entry pointing at the compressor.
2. The exclusion list contains `Read`, `Edit`, `Write`, `NotebookEdit` AND the
   gate-CLI patterns (`ops-verdict`, `ops-task`, `ops-adopt`) — byte-checked against
   the install set in `ops-init.sh` (the same set `CHARTER_REQUIRED_CLIS` tracks).
3. A replay test (Chisle ships `benchmarks/replay-compress.js` as the pattern)
   asserts: compression never mutates Read/Edit/Write output; never throws on
   malformed input; salvages an error line buried mid-log; no-ops under the
   shrink threshold; rebuilds the Bash `{stdout,stderr}` shape correctly.

## Open question (resolve before implementation)
The exact signal for I2's "compressor off when capturing verdict evidence." A
sentinel-presence check is the candidate (a pending sentinel = a task is open =
evidence may be in flight), but a sentinel can be open across many tool calls that
are NOT evidence. Lean: the gate-CLI exclusion list (I2 bullet 2) alone may be
sufficient and far simpler — it covers the verbatim-ledger requirement without a
session-scoped flag. Decide with a live test of what a verdict capture actually
emits.
