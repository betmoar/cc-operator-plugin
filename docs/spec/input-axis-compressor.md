# Spec — input-axis token compressor (PostToolUse hook)

Status: **IMPLEMENTED (2026-08-02)** — `scripts/ops-compress.mjs`, wired as a
PostToolUse hook in `hooks/hooks.json`, guarded by
`validate_plugin.check_compressor`, covered by `tests/test_compress.mjs` (53
cases, one per invariant).

**Extends:** `2026-07-29-workflow-orchestration-design.md` §7 — this is that
design's *input* axis. The output axis (charter caps, workflows costing nothing
until invoked) shipped there; §7 is now complete.

### Why it was built, measured rather than assumed (2026-08-02)

The decision to build was gated on a measurement, not on the spec's assertion.
Across 10 sessions of this project's own transcripts, 2340 `tool_result` blocks,
2,215,751 chars in context:

| | |
|---|---|
| blocks over the 8000-char threshold | **35 — 1.5% of blocks** |
| share of all in-context chars they carry | **25.1%** |
| one-time elide saving | 197,272 chars ≈ 49 K tokens (8.9%) |
| **re-billed** chars (a block is re-sent every turn until reset) | 809,809,530 |
| **saving on the re-billed axis** | **102,015,025 chars ≈ 12.6%** |

Median block: 265 chars; mean 946. That skew is what makes the 8000 threshold
right — it touches 35 blocks and leaves 2305 alone. Two honest caveats: the
re-billing figure ignores prompt caching, so the absolute number is an upper
bound (the 12.6% *ratio* is what carries); and 4 chars/token is the usual rule
of thumb, not a measurement on this corpus.

A correctness motive was considered and **rejected**: the maintainer confirmed
the compressor was always specified for throughput and cost, not to protect the
evidence gate from falsification. I2 is therefore a safety property of a
cost-motivated feature, not its justification — which is exactly why I2.3
(spill-and-cite) is non-negotiable rather than optional.

### Review history worth keeping

A 5-direction brainstorm panel (8 agents, 2026-08-02) unanimously declined this
document's PostToolUse architecture, on the grounds that no such hook existed in
the plugin. **That objection was wrong**, and the record should say so: the
event and its `updatedToolOutput` field are both documented and supported
(docs.claude.com/en/docs/claude-code/hooks). The panel reasoned from the
plugin's own `hooks.json` (SessionStart + Stop) rather than the harness
contract, and the operator relayed that conclusion without checking the docs.
The panel's *other* findings held and are reflected in the implementation:
`check_cell` already refuses newlines in an evidence cell (so I2's ledger
protection is about `cat`/`grep` of the FILE, which is what I2.2 covers), the
charter's 150-line cap forced a same-commit reflow of the EVIDENCE GATE section,
and `.operator/.gitignore` is written only when absent — so `ops-init.sh` now
appends the compressor exclusions idempotently on upgrade.

The reference implementation named below is Chisle's
`hooks/chisle-compress-output.js` (read directly from github.com/JayPokale/Chisle;
zero-dependency, zero-LLM, deterministic). It remains a good reference for the
*mechanism*; the disagreement is about the *boundary*, not the algorithm.

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
applying it — a wrong shape is **rejected with a visible hook error** and the model
receives the full output (the rejection is loud in the transcript, not silent —
audit F27.10; the failure mode is still "no savings", never "broken output").
Returning nothing (skip) is always safer than emitting a shape the harness refuses.

Two tiers, applied in order, both deterministic (no LLM, no network). Defaults are
PINNED (the tunables table below names the knobs; the replay test asserts against
these exact numbers — a test against a tilde is not a test, audit F25/F27):

1. **Scrub** (lossless, output > `SCRUB_MIN`=1024 chars): strip ANSI/OSC escapes,
   collapse ≥3 blank lines to one, collapse ≥4 identical consecutive lines to one +
   `[repeated N×]`. No information lost.
2. **Elide** (output > `MAX_CHARS`=8000): keep head + tail, bounded in **BYTES,
   not lines** — `HEAD_BYTES`=6144, `TAIL_BYTES`=4096, with a per-line cap of
   `LINE_CHARS`=400 (a newline-less multi-MB line is one "line" to a line count;
   bytes-not-lines is this repo's standing reader invariant — check_reader_bounds
   enforces the same rule on every shell reader). **Salvage** error-looking lines
   from the elided middle (regex on error/fail/traceback/panic/denied/refused/
   timed-out/assert/segfault/`not ok`, capped at `SALVAGE_LINES`=12, each line
   capped at `LINE_CHARS`), so the one line that mattered in a 3000-line build
   log survives the cut.

Plus **dedup**: a tool output byte-identical to that tool's immediately-previous
output → a short marker. Dedup is the only STATEFUL tier, so its state is specced
(audit F25): a per-`(session_id, tool_name)` SHA-256 of the previous output (never
the bytes themselves), in `.operator/.compress-state/<session_id>`, size-bounded
(one hash per tool), skipped when the payload carries no `session_id`, and
**cleared by the SessionStart hook** — including the compact re-fire, because
compaction can prune the prior output from context, and "the content is already
in context" is the marker's entire justification (audit F27.11).

No-op rule: if compression does not shrink the output by ≥ `MIN_SHRINK`=64 chars,
keep the original. Never credit savings the harness refused to apply.

## Non-negotiable invariants (from Chisle + cc-operator)

### I1 — allowlist, never blocklist
Compress ONLY: `Bash`, `WebFetch`, `WebSearch`, `Grep`, `Glob`.
**`Read`, `Edit`, `Write`, `NotebookEdit` are excluded forever.**
Their output feeds exact-match edits — eliding a `Read` result makes the model
edit against text it never saw (`old_string` matching breaks). An allowlist means a
new tool defaults to *uncompressed/safe*, not *compressed/broken*.

Two entries the first draft allowlisted are now excluded, for the Read reason
applied to their own consumers (audit F25):
- **`Agent` — excluded from the elide tier.** A subagent's report is what the
  operator's verdict-from-report flow consumes; head/tail-eliding it breaks that
  flow exactly the way eliding `Read` breaks edits. Scrub + dedup MAY apply
  (lossless); elide MUST NOT.
- **`mcp__*` — excluded entirely.** "Read-only `mcp__*`" is unimplementable: the
  PostToolUse payload carries no read-only indicator, and a name-pattern list
  (`get|list|read|search`) is a guess that rots. The allowlist philosophy already
  gives the right default — unknown tool = uncompressed/safe.

### I2 — the evidence-gate carve-out (cc-operator's addition; Chisle lacks this)
The compressor MUST NOT touch tool output that is, or feeds, the evidence gate. A
compressed verdict trail falsifies the single thing this plugin exists to protect.

The invariant has three parts, because the evidence flows through three surfaces
(audit F16/F24 — the first draft covered only the first and thought it covered
all three):

1. **The gate CLIs pass through untouched.** Any `Bash` invocation of
   `.operator/bin/ops-verdict.sh`, `ops-task.sh`, `ops-adopt.sh`, or the plugin's
   own `scripts/ops-*.sh`. (Note: this alone is nearly vacuous for protection —
   ops-verdict's own output is one line, far under any threshold. It is listed
   for hygiene, not as the mechanism.)
2. **The ledger files pass through untouched, by PATH not by CLI name.** Any
   `Bash` command whose command string references `.operator/VERDICTS.md`,
   `.operator/DECISIONS.md`, or `.operator/verdicts.d/` — fixed-string,
   case-sensitive substring match on the command. Rendering the ledger is
   `cat`/`grep`/`tail` of the FILE, not a CLI invocation; a mature ledger
   (~80 B/row) crosses the elide threshold past ~100 rows, and mid-body elision
   of PASS rows is exactly the falsification this invariant forbids. (The `Grep`
   TOOL is on the I1 allowlist — its carve-out mirrors this: a Grep whose target
   path matches the ledger paths passes through.)
3. **The upstream evidence feed survives verbatim or stays recoverable.** The
   real flow is: operator runs tests via plain Bash (allowlisted, elidable) →
   quotes evidence FROM that output into ops-verdict ARGV. The evidence is
   compressed BEFORE any gate CLI runs, and a mid-log failure that misses the
   salvage regex (TAP `not ok 12` matches no salvage token) can turn a FAIL
   into a recorded PASS. Neither CLI-exclusion nor sentinel-presence solves
   this cleanly (sentinel-presence would disable compression for the whole task
   lifetime, nullifying the feature during operated work). The mechanism:
   **spill-and-cite** — whenever the elide tier fires, write the uncompressed
   original to a session-scoped spill file
   (`.operator/.compress-spill/<session>/<tool_use_id>`) and append one marker
   line to the compressed output naming that path. Evidence quoted into a
   verdict can then cite the verbatim artifact, and the charter's verdict rule
   gains: *evidence taken from compressed output MUST cite the spill file.*
   Spill files are bounded (delete oldest past ~50 per session) and cleared on
   SessionStart.

### I3 — never throws
A broken hook must not break the tool pipeline. The entire hook body is one
try/catch that swallows and emits nothing on any failure.

### I4 — no-op when no shrink
Keep the original unless the compressed form is meaningfully smaller
(≥ `MIN_SHRINK`=64 chars).

### I5 — rebuild the original response shape
Bash results are objects `{stdout, stderr, ...}`, not bare strings. Handing back a
bare string is rejected on every call — the hook errors visibly on each attempt
while the model still gets the full output (see The mechanism: rejection is loud,
the net effect is "no savings"). `rebuildResponse` must return the compressed
text in the original shape (fold `stderr` into the compressed text, then blank it,
to avoid duplication). An unrecognized shape → skip (emit nothing).

## Kill switches / tunables (env — defaults pinned in The mechanism)
- `CC_OPERATOR_COMPRESS=0` — global kill switch
- `CC_OPERATOR_COMPRESS_SCRUB=0` — disable lossless scrub tier (SCRUB_MIN=1024)
- `CC_OPERATOR_COMPRESS_DEDUP=0` — disable duplicate markers
- `CC_OPERATOR_COMPRESS_MAX_CHARS` — elide threshold (default 8000)
- `CC_OPERATOR_COMPRESS_HEAD_BYTES` / `_TAIL_BYTES` — retention (6144 / 4096)
- `CC_OPERATOR_COMPRESS_LINE_CHARS` — per-line cap (400)
- `CC_OPERATOR_COMPRESS_SALVAGE_LINES` — salvage cap (12)
- `CC_OPERATOR_COMPRESS_MIN_SHRINK` — no-op floor (64)

## Validator guardrails (Phase 4, before merge)
1. `hooks/hooks.json` has a PostToolUse entry pointing at the compressor.
2. The exclusion list contains `Read`, `Edit`, `Write`, `NotebookEdit`, `Agent`
   (elide), all `mcp__*`, the gate-CLI patterns (`ops-verdict`, `ops-task`,
   `ops-adopt` — byte-checked against the install set in `ops-init.sh`, the same
   set `CHARTER_REQUIRED_CLIS` tracks) AND the ledger paths
   (`.operator/VERDICTS.md`, `.operator/DECISIONS.md`, `.operator/verdicts.d/`
   — fixed-string match, byte-checked the same way).
3. A replay test (Chisle ships `benchmarks/replay-compress.js` as the pattern)
   asserts against the PINNED defaults: compression never mutates
   Read/Edit/Write/Agent-elide/mcp output; never throws on malformed input;
   salvages an error line buried mid-log INCLUDING a TAP `not ok` line; no-ops
   at exactly MIN_SHRINK-1; rebuilds the Bash `{stdout,stderr}` shape correctly;
   a single newline-less multi-MB line is byte-capped in head/tail retention;
   an elide emits the spill file and its marker line (I2.3); ledger-path Bash
   commands pass through untouched (I2.2).

## Resolved (was the open question)
The I2 signal question is closed by I2.3's spill-and-cite (audit F16): the
gate-CLI exclusion alone was vacuous (protects a one-line output), and
sentinel-presence would disable compression for a task's whole lifetime. The
compressor stays ON during operated work; the elide tier preserves a verbatim
spill the evidence must cite. What remains before implementation is only the
charter edit that makes the citation rule binding (one line in OPERATOR.md's
verdict discipline) — bundle it with the hook, same commit.
