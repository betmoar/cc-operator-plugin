# Worker-boundary enforcement — SSSF adoptions + Deviation-gate

Design, 2026-08-03, **revision 2** (rev 1 was REFUTED by the review panel:
stage-3 mechanism impossible in the workflow sandbox, wrong seat list,
DEVIATION shape contradicting the shipped ledger schema, no session scoping,
mark-write outside the lock — all corrected below). Source material:
`docs/audits/gap-analysis-sssf-2026-08-03.md` (findings F-A1, F-A2, F-A3,
F-A6, F-A13) and the Deviation-gate discussion of the same session. Status:
**approved design, pre-plan**.

## Problem

Two classes of guarantee in the cc-operator factory are prompt-deep where they
should be code-deep:

1. **Worker claims are verified by operator reading, not mechanically.** A
   dispatch report's ACCOMPLISHED list is prose; nothing compares it to the
   actual diff. A worker can claim files it never touched, touch files it never
   claimed, or edit the gate that grades it (`scripts/validate_plugin.py`,
   `tests/`) — the F48 class shipped four times by the *maintainer*; a worker
   would be harder to catch. (Gap analysis F-A3, F-A2, F-A1.)
2. **Operator-taken decisions can reach the end of a session unpresented.** The
   charter tells the operator when to escalate (ladder rung 4, reframe-
   invalidating unknowns), but nothing structurally prevents deciding alone and
   summarizing at the end — or never. The Stop hook only checks sentinels.

SSSF (disler/super-simple-software-factory) demonstrates the first class costs
~100 LOC to enforce in code (`gates.py`, `writes:` rollback, `protected_files`).
The second class is absent in SSSF (its README's "what it deliberately does
not do" list includes the human-in-the-loop approval phase — cited from the
SSSF clone's README.md, not from the gap-analysis doc) and unenforced here —
this design closes ours.

## Non-goals

- No judging *whether* a decision should have been escalated — that stays
  charter judgment. The gate forces presentation, not permission.
- No human-ack authentication. Handoff-clears was chosen over an ACK line
  because an operator can self-serve any ACK marker anyway; forcing the
  presentation is the enforceable part.
- No SSSF runtime machinery: no envelopes, no SQLite trace, no per-phase cost
  metering (gap analysis F-A12, F-A5 — rejected).
- No change to the tier system: `ops-tiers.sh`, `ops-render.sh`, `tiers.env`,
  and workflow routing are untouched — the tree check trusts no seat
  classification anyway (rev 2), so it is doubly orthogonal to models.
- No new config files, directories, or shared runtime modules. The workflow
  scripts themselves are untouched by F-A1 (rev 2: the sandbox cannot run
  git; the check lives in the operator's post-dispatch step). The only
  workflow edit in this design is the verifier prompt line in review.js.

## Design

Three stages, each independently shippable, each landing gate-green
(validator 0 + full suites). Stage order is evidence-ranked: stage 1 builds
the structured-line + bounded-reader conventions stage 2 copies; hook changes
(stage 2) get an isolated review cycle per the F48 lesson.

### Stage 1 — `ops-claims.sh` (F-A3 diff-matches-claims + F-A2 grader protection)

A fourth gate CLI, installed into `.operator/bin/` by `ops-init.sh` alongside
verdict/task/adopt (which extends the CHARTER_REQUIRED_CLIS / install-set
coupling row in CLAUDE.md).

**Report contract change.** The dispatch packet's REPORT section gains one
required line:

```
CHANGED: <repo-relative-path> <path> …   |   CHANGED: none
```

**Invocation** (operator, on a DONE report):

```
.operator/bin/ops-claims.sh --claimed "<space-separated paths>" \
    [--since <sha>] [--gate-task]
```

`--since` defaults to HEAD as of dispatch (operator records the sha in the
packet; the plan defines the exact default). Actual changes = union of
`git diff --name-only <since>` and untracked paths from
`git status --porcelain`.

**Checks, each emitting `{item, ok, note}`-style lines** (SSSF's
evidence-per-check shape — a green run answers *what was verified*, and the
PASS verdict row cites the output):

| # | Name | Fails when | Catches |
|---|---|---|---|
| C1 | unclaimed-change | a touched file is not in the claimed list | "did Y, said X" |
| C2 | phantom-claim | a claimed file has no actual change | "reported done, touched nothing" |

Path matching (all three checks alike): a claimed or protected path ending in
`/` matches by prefix; any other path matches exactly. So `CHANGED: tests/`
is satisfied by a diff touching `tests/test-scripts.sh`, and the protected
set's `tests/` covers every file under it.
| C3 | gate-trespass | any touched path is under the protected set, without `--gate-task` | worker editing its own grader |

Exit non-zero on any failed check, naming it. Protected set (literal in the
script): `scripts/validate_plugin.py`, `tests/`, `.operator/bin/`, `hooks/`,
`scripts/ops-*.sh`. `.operator/` ledger paths are exempt from C1 (verdict rows
are expected side-effects of any dispatch).

**Rules inherited from the existing CLIs:** bash 3.2 compatible, builtins +
git only, byte-bounded reads per the PLAYBOOK reader procedure, claimed paths
under the same charset discipline as task ids (no newlines, no `|`, no leading
dot, no traversal). A new `validate_plugin.check_claims` pins the protected-set
literal and its application (guard parity — the F30 lesson: pinned to a
canonical literal AND applied at a call site; four-way copy parity alone is
insufficient).

**Charter/PLAYBOOK edits:** the packet REPORT template gains the CHANGED line;
the standing FORBIDDEN default (gate files off-limits to implementers unless
the task *is* the gate) is documented in the packet template and PLAYBOOK.
The charter is at its 150-line cap — the plan decides what single line lands
there vs what goes to PLAYBOOK, and re-runs the charter validator.

### Stage 2 — Deviation-gate (unpresented decisions block Stop)

**Ledger convention — builds on the SHIPPED schema, not a new one.**
DECISIONS.md already has a pipe-delimited line format
(`templates/DECISIONS-header.md`):

```
<ISO-date> | <engagement.task> | <DEVIATION|ESCALATION|…> | <what> | <why>
```

Deviations continue to use exactly that shape — no new line kind. Two
extensions:

1. **Session scoping**: a deviation the gate should track carries the owning
   session id in the `<what>` cell as a leading `[sid:<session-id>]` tag
   (written by the operator, who has the id from SessionStart). A deviation
   line without a sid tag is **legacy/unowned** and is treated like an unowned
   sentinel: it blocks every session (fail closed, same polarity and same
   rationale as the sentinel default — pre-gate lines are real unpresented
   decisions).
2. **The mark**: presenting clears via a new line *kind* in the existing
   pipe schema — `HANDOFF-MARK` in the kind column:

```
<ISO-date> | <engagement> | HANDOFF-MARK | [sid:<session-id>] <ISO-8601 ts> | handoff presented
```

**Single-writer discipline preserved**: the mark is written by
`ops-verdict.sh --mark-handoff --owner <sid>` — the owner is REQUIRED
non-empty and passes `check_owner_name` (an empty sid would write an unowned
mark, which under the partition would clear *every* session's deviations — a
privilege inversion; refused at the CLI). Symmetrically, the hook IGNORES a
HANDOFF-MARK whose sid tag is missing or empty: marks fail *closed* (never
clear more than their owner), the opposite polarity from deviations (which
fail *open*-to-blocking when untagged) — both err toward blocking. A new
flag on the existing
single writer, inside the same `lock_acquire`/`lock_release` critical section
its `--defer` path already uses for DECISIONS.md writes. The handoff command
(`commands/handoff.md`) invokes it; its `allowed-tools` gains the
`.operator/bin/ops-verdict.sh` grant it currently lacks (today it has only
`Bash(git:*), Read, Write`). DEVIATION lines themselves remain
operator-authored prose appends, as today — the gate reads them, the mark
mutation goes through the locked CLI.

**Hook rule** (`ops-stop-hook.sh`, alongside the sentinel partition, same
mine/foreign split): block the stop (exit 2) iff there exists a DEVIATION
line that is (a) **mine** (its sid tag equals this session's id) or
(b) **unowned** (no sid tag), positioned *after* the last HANDOFF-MARK line
that is mine-or-unowned — file position, not timestamp comparison. Foreign
deviations (sid ≠ mine) are reported on stderr and never block — the 0.4.0
concurrency partition applied to the second ledger. stderr names the blocking
lines and the remedy: present them (via `/cc-operator:handoff` or in the
reply), then `ops-verdict.sh --mark-handoff --owner <sid>`. The existing
`stop_hook_active` loop-guard applies unchanged.

**Failure polarity — deliberately opposite the sentinel default, documented in
the file:** an unreadable or absent DECISIONS.md **fails open** (no block).
Rationale: a missing ledger is a plugin/scaffold problem, not evidence of an
unpresented decision — same reasoning as the existing no-parser fail-open. A
malformed DEVIATION line (over-long, NUL, CRLF) degrades to *counted as
unpresented* (fail toward the honest warning) — the reader is byte-bounded
(`read -r -n 512`, NUL probe looping the whole file per the F55 lesson).

This makes the hook the first DECISIONS.md parser in the plugin: PLAYBOOK's
"adding a reader" procedure gains the entry, and `check_reader_bounds` covers
the new read sites. One bound differs from the sentinel readers and the plan
must set it explicitly: sentinel parsers stop at line 20 (owner is line 1 by
construction), but DEVIATION/HANDOFF-MARK lines are position-arbitrary, so
this is a whole-file scan needing an aggregate cap (line count and/or total
bytes) — most acutely in the statusline mirror, which runs on the ~300ms
render timer.

**Statusline mirror** (coupling-table obligation: the bar renders the same
partition the hook runs, or it lies): a dim `dev[N]` segment counts
*mine + unowned* unpresented deviations — the same partition the hook blocks
on, foreign excluded, exactly as the `op[…]` segment mirrors the sentinel
partition. Dim, not red — an unpresented deviation blocks *stop*, not current
work. Same bounded-reader rules; renders nothing when N=0.

### Stage 3 — Read-only-seat tree check (F-A1) + PLAYBOOK rules (F-A6, F-A13)

**F-A1, corrected mechanism (rev 2).** Rev 1 placed the tree check inside the
workflow scripts — impossible: the workflow sandbox has no `process`, `fs`,
`require`, or `import` (measured, `workflows/review.js:13-15`; orchestration
spec M5: *only spawned agents touch disk*). The check moves to **the
operator's own post-dispatch step**, where disk access exists:

- `ops-claims.sh` (stage 1) gains `--expect-clean`: asserts
  `git status --porcelain` output is empty apart from `.operator/` ledger
  paths, emitting the same `{item, ok, note}` evidence lines. One flag on the
  stage-1 CLI — no new script, no workflow change.
- The charter's ORCHESTRATED-MODE dispatch procedure (or PLAYBOOK, per the
  line budget) gains the rule: *after any workflow or read-only dispatch
  returns, run `ops-claims.sh --expect-clean`; drift is a FAIL-shaped finding
  logged before any other action.* Operator-layer discipline backed by a
  mechanical check — the same shape as the existing diff-stat obligation, now
  with a command attached.

**Corrected seat facts (rev 2).** The write-capable exposure in the workflows
is real and *larger* than rev 1 claimed: the dominant lens seat in
brainstorm/crawl/plan is **op-author** (`agents/op-author.md`: tools include
Write, Edit, Bash), dispatched as a nominally read-only lens at
`workflows/brainstorm.js:118` (direction lenses), `brainstorm.js:244`
(converge), `crawl.js:191` (merge), and `plan.js:142` (decompose). The
genuinely write-free seat *files* are op-scout and op-brainstorm (no Bash) —
op-brainstorm is dispatched by no workflow today, and op-crawler /
op-reviewer / op-verifier all carry Bash (shell-write capable, identical
frontmatter: `tools: Read, Grep, Glob, Bash` + `disallowedTools: Write,
Edit, NotebookEdit`). Consequence: the tree check
treats **every** workflow run as needing `--expect-clean` rather than
trusting any seat classification. Seat definition files stay unchanged; they
are capability declarations, not enforcement.

**F-A1, review workflow extra** (kept from rev 1 — and possible, because the
verifier is an *agent*, and agents touch disk): the verifier prompt gains one
refutation target: "confirm the working tree contains no changes beyond the
reviewed artifact set".

**F-A6 (PLAYBOOK rule):** *a fix after a green gate re-runs the gate; the
verdict cites the post-fix run.* **F-A13 (PLAYBOOK rule):** *a worker-authored
commit message uses the worker's own report sentence, never operator
paraphrase.* No code for either.

## Coupling-table impact (CLAUDE.md rows to update per stage)

- Stage 1: `.operator/bin` install-set row (+ops-claims.sh → charter paths,
  stop-hook fallback message, install test case, `CHARTER_REQUIRED_CLIS`* and
  `check_scripts`); new row for the protected-set literal ↔ `check_claims`.
  (*The plan verifies whether ops-claims.sh joins CHARTER_REQUIRED_CLIS or a
  separate install-set list — charter line budget decides.)
- Stage 2: mine/foreign partition row extends to the deviation partition
  (hook ↔ statusline ↔ the `[sid:]` tag convention — three readers of one
  rule); PLAYBOOK reader-procedure entry for DECISIONS.md;
  `ops-verdict.sh --mark-handoff` joins the lock/fragment row;
  `commands/handoff.md` allowed-tools row; **`templates/DECISIONS-header.md`
  kind enum gains `HANDOFF-MARK`** (the shipped enum does not include it —
  without this edit the new kind is illegal under the template this design
  claims to build on), and the plan adds a `check_decisions_schema` pin in
  the `check_ledger_schema` pattern so the now-parsed schema cannot drift
  green (today only the VERDICTS header is pinned).
- Stage 3: dispatch-procedure prose (charter or PLAYBOOK) ↔ the
  `--expect-clean` flag; verifier prompt target in `workflows/review.js`.

## Error handling summary

Every new check fails toward the honest warning: claims mismatch → non-zero
with named check; gate trespass → non-zero unless `--gate-task`;
`--expect-clean` drift → non-zero naming the paths; unreadable DECISIONS.md →
open (documented polarity inversion); malformed or untagged deviation line →
counted as unowned = blocking; foreign deviation → reported, never blocking.
No new silent paths.

## Testing

All mutation-verified (revert the fix → a named case fails), per stage:

- **Stage 1 (bash + pytest):** C1/C2/C3 each red and green; `CHANGED: none`;
  untracked-file detection; ledger-path exemption; charset/NUL/traversal abuse
  on `--claimed`; `--gate-task` bypass; `--expect-clean` green on clean tree /
  red on stray file / ledger-exempt; `check_claims` parity guard (drop a
  protected path from the literal → validator fires; neuter the call site →
  fires).
- **Stage 2 (bash):** mine-deviation-after-mark blocks; mark-after-deviation
  clears; no-mark + mine deviation blocks; **foreign deviation never blocks
  and is reported**; **untagged (legacy) deviation blocks every session**;
  mark by another session does not clear mine; empty/absent DECISIONS.md
  opens; CRLF/NUL/over-long deviation lines block (degrade-to-blocking);
  `--mark-handoff` writes under the lock (concurrent-append case) and refuses
  without `--owner`; loop-guard interaction; statusline `dev[N]` mirror cases
  (mine+unowned counted, foreign excluded, N=0 renders nothing).
- **Stage 3 (bash + node):** `--expect-clean` cases live in stage 1's suite;
  review workflow test asserts the verifier prompt carries the tree-check
  refutation target (prompt-content assertion, F40-style against the LENSES
  table); PLAYBOOK rule presence greps.

Release bar per stage commit: validator 0 · compress · workflows · pytest ·
bash suites all green · shellcheck 0.

## Decisions log

From the brainstorm:

| Question | Decision |
|---|---|
| Spec scope | all six items, one spec, staged |
| F-A1 home | operator post-dispatch step (`--expect-clean`) + verifier target |
| Deviation clearing | handoff-clears (no human-ack line) |
| F-A3 claim source | structured `CHANGED:` line in the report contract |
| F-A2 depth | mechanical, via the same ops-claims.sh |
| Stage order | claims-CLI → deviation-gate → prose/verifier |

From the panel review (rev 1 → rev 2):

| REFUTED finding | Correction |
|---|---|
| in-workflow git check impossible (sandbox has no fs/process) | moved to operator post-dispatch: `ops-claims.sh --expect-clean` |
| seat list wrong (op-author write-capable + dominant; op-brainstorm undispatched) | seat facts corrected; every workflow run gets `--expect-clean`, no seat trust |
| DEVIATION shape contradicted shipped pipe schema | reuses the shipped schema; sid via `[sid:]` tag in the what-cell |
| no session scoping (foreign deviation would block all) | mine+unowned block, foreign reports — the 0.4.0 partition |
| HANDOFF-MARK written outside the lock | mark goes through `ops-verdict.sh --mark-handoff` inside the existing critical section |
| SSSF quote cited to the wrong doc | citation corrected to the SSSF clone's README |
