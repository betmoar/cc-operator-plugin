# Backlog-as-charter, the arm gate, and locked-goal autonomy — design spec

> Status: **proposed**, not implemented. Target 0.7.0 (slice 1) / 0.8.0 (slice 3).
> Register: this is rationale, read on demand — nothing here is loaded at runtime.
> Companion reading: `docs/PLAYBOOK.md` (procedures), `docs/LANDMINES.md` (why),
> `CLAUDE.md` (the coupling map this spec proposes to amend).

## Thesis

Three asks arrived together, and they are one design:

1. Operate an external backlog (`MrLesk/Backlog.md`) **as a charter**, not as a
   to-do list the operator reads and forgets.
2. Close the still-open pilot question: the evidence gate is **opt-in at the
   mechanism level** — nothing forces a sentinel to be opened.
3. Let the operator **judge its own decisions without constant sign-offs once
   the goal is locked**.

They compose into a single sentence, which is the spec's whole claim:

> **The backlog supplies the goal. Locking the bar buys autonomy. The arm gate
> makes every write accountable to an open task. The verdict gate makes every
> "done" accountable to evidence. The deviation gate makes every autonomous
> judgment accountable at handoff.**

Autonomy is not the absence of oversight here. It is oversight **batched to the
handoff** instead of interleaved into every step — and the mechanism that
batches it (the stage-2 deviation gate) already ships. That is the load-bearing
reuse in this design: we are not buying autonomy with trust, we are buying it
with an existing gate that already blocks Stop until the operator presents.

---

## 1. What is actually broken today (measured, not asserted)

### E1 — the gate is opt-in at **both** ends, not just the opening one

The pilot finding recorded in `CLAUDE.md` names half of it. The other half is
worse and is the reason the hole cannot be seen from the ledger:

- **Opening is optional.** Nothing calls `ops-task.sh`. A whole engagement can
  run with `.operator/pending/` empty, and the Stop hook — working exactly as
  designed — allows every stop.
- **Closing does not require having opened.** `ops-verdict.sh:565` is
  `clear_sentinel() { rm -f "$OPDIR/pending/$ID"; }`, and `ownership_gate()`
  (`ops-verdict.sh:545-563`) refuses only on a symlink or an owner *mismatch*.
  With no sentinel present, `sentinel_owner` returns `""`, the mismatch branch
  is skipped, and the row is appended normally.

Reproduced against HEAD (0.6.1) in a fresh scaffold, `pending/` empty
throughout:

```
$ .operator/bin/ops-verdict.sh never-armed-task "some criterion" "some evidence" PASS --owner sessX
recorded never-armed-task = PASS (row appended, sentinel cleared)   # exit 0

$ cat .operator/VERDICTS.md
| Gate | Criterion | Evidence | PASS/FAIL |
|---|---|---|---|
| never-armed-task | some criterion | some evidence | PASS |

$ grep -cE '^[0-9]{4}-[0-9]{2}-[0-9]{2} \| ' .operator/DECISIONS.md
0
```

Note the success message: *"sentinel cleared"* — for a sentinel that never
existed. And the decisions ledger records **nothing**: zero rows by the Stop
hook's own leading-ISO-date discriminator. (The only `GATE-EXCEPTION` string in
the file is the header's kind enum, which issue #9 already taught the scanner to
skip.)

The consequence is the part that matters: **a PASS row is indistinguishable
from a PASS row that never went through the gate.** The ledger cannot answer
"did the gate run for this?" — so the failure is not merely that the gate is
skippable, it is that skipping it leaves **no trace at all**. That is the same
shape as the F48 class (a guard that is vacuous while looking authoritative),
one layer up — and it is why G1 below is the first thing to ship.

### E2 — the engagement contract is prose-deep

`templates/OPERATOR.md` § ENGAGEMENT CONTRACT says a BAR block is *REQUIRED*
before the first implementation action on a multi-file / multi-session /
done-named task. Nothing reads that sentence. It is a guarantee of exactly the
kind the worker-boundary pass (F-A1/F-A3) already converted from prose to
mechanism at the worker seam — `ops-claims.sh` exists because "read-only" was a
tool-list claim rather than an enforced boundary. The operator seam still has
the prose version.

### E3 — the operator authors the done-condition it later judges

Today the operator invents task ids and writes its own BAR block. Even with
perfect discipline, the author of the criteria and the judge of the criteria are
the same agent in the same context. An external backlog fixes this for free: the
acceptance criteria are written down first, in a file, by a different act — and
the operator's job narrows to *adjudicating against them*.

### E4 — the charter has one line of headroom

Measured at HEAD:

| Bound | Now | Cap |
|---|---|---|
| lines | **149** | 150 |
| bytes | 8194 | 9000 |
| longest non-table line | 83 | 100 |

This is a hard design constraint, not a footnote: **no new charter section is
affordable.** Everything below is budgeted against it (§6).

---

## 2. Decisions — closing the gate (G)

Two layers, deliberately unequal in blocking power, shipped in order. The design
rule is the PLAYBOOK's: *fail-open is the only direction that matters* — so the
layer that can never block a write ships first and default-on, and the layer
that can block a write ships opt-in.

### G1 — the retro-gate: an unarmed verdict is recorded as unarmed *(default-on)*

`ops-verdict.sh` learns one new behaviour. At verdict time, under the lock it
already holds, it distinguishes three states of `.operator/pending/<id>`:

| State | Meaning | Action |
|---|---|---|
| sentinel present | armed normally | today's behaviour, unchanged |
| absent, **and** no prior row for `<id>` in this session's fragment | **never armed** | append the row, **and** write a `GATE-EXCEPTION` line to DECISIONS.md |
| absent, **and** a prior row for `<id>` exists | duplicate/amending row | append, warn on stderr, no gated line |

`GATE-EXCEPTION` is already a **gated** kind (`templates/DECISIONS-header.md`):
the stage-2 deviation scan in `ops-stop-hook.sh` blocks Stop until a
`HANDOFF-MARK` presents it. So the retro-gate needs **no new gate machinery** —
it borrows an enforcement seam that already exists and is already tested.

Why this is the right first move:

- It **cannot wedge a session's writes.** It adds a handoff obligation, never a
  refusal. The worst case is a session that must present before stopping.
- It **never refuses the verdict.** Refusing would strand real evidence outside
  the ledger — strictly worse than recording it with a caveat.
- It converts E1 from an invisible hole into a **visible, costly** one. Skipping
  the gate is still possible; it is no longer deniable.

Two implementation requirements, both derived from existing landmines:

- The prior-row lookup must be **bounded** and read the session fragment
  (`verdicts.d/<owner>.md`), not all of VERDICTS.md. `FRAG_MAX_BYTES` already
  bounds that file. Anything unbounded here lengthens the critical section, and
  PLAYBOOK "touching the lock" step 3 forbids that without a re-budget.
- The `GATE-EXCEPTION`'s what-cell carries the `[sid:<session>]` tag, or it is
  unowned and blocks **every** session (the documented unowned-blocks-all rule).

### G2 — the arm gate: PreToolUse blocks the first unarmed write *(opt-in)*

A new `scripts/ops-armgate-hook.sh` on `PreToolUse`, matcher
`Write|Edit|MultiEdit|NotebookEdit`. Contract, in the house style:

```
exit 0 — allow. Cases: no .operator/ above the payload cwd; the gate is not
         enabled; this session is armed; no JSON parser; unreadable state.
exit 2 — deny. This session holds NO open task and is about to mutate a file.
         stderr names the exact command to arm, and the exemption path.
```

**Polarity, stated explicitly because it is the opposite of the Stop hook's.**
The Stop gate fails *closed* on a degenerate sentinel because an unparseable
sentinel is a real open task. The arm gate fails **open** on every
infrastructure failure — no parser, no `.operator/`, unreadable marker — because
a PreToolUse hook that fails closed makes the project **unwritable**, and an
unwritable project cannot even be repaired. Both polarities are right for the
same reason: the failure mode you cannot recover from is the one to avoid.

**Scope: structured file-mutation tools only. `Bash` is deliberately not gated.**
Deciding whether an arbitrary shell command writes is an unwinnable
classification problem with a large false-positive surface on a hook that
*blocks*, and gating Bash risks deadlocking the repair path (`ops-task.sh` is
itself a Bash call). State the consequence honestly rather than papering it:
**this gate is an honesty rail against drift, not a sandbox against a hostile
agent.** A session that wants to evade it can `bash -c 'cat > f'`. The threat
model is forgetting, which is the observed failure, not evasion, which is not.

#### G2.1 — how the hook asks "am I armed?" without a fourth parser

The obvious implementation re-implements the mine/foreign sentinel partition a
**fourth** time (hook, statusline, and now this). `CLAUDE.md`'s coupling table
already carries that duplication as a known cost; a fourth copy on a hook that
runs before *every edit* is worse than the ones we have.

Instead the expensive question is answered by the **writers**, and the hook asks
a cheap one:

- `ops-task.sh --owner S` (success) and `ops-adopt.sh --owner S` → create
  `.operator/.armed/S` (empty marker).
- `ops-verdict.sh` (verdict **and** `--defer`) → after clearing the sentinel,
  **under the lock it already holds**, rescan `pending/` for any sentinel owned
  by `S`; if none remain, remove `.operator/.armed/S`.
- The hook's entire check is: gate enabled → `[ -e ".operator/.armed/$session" ]`.
  One stat. No parsing, no byte bounds, no partition, builtins only by
  construction.

This is a derived cache, and this repo's history is unkind to derived caches
("two components disagreeing about what a task is, silently off" — audit F01).
So the desync polarity is analysed rather than assumed:

| Desync | Effect | Verdict |
|---|---|---|
| marker present, no owned sentinel (stale-true) | gate allows the write | **acceptable** — degrades to exactly today's behaviour; self-heals at the next `ops-verdict.sh` run, which recomputes under the lock |
| marker absent, owned sentinel present (stale-false) | a legitimately-armed session is blocked | **the one to prevent** — see mitigations |

Stale-false mitigations, all three required:

1. The deny message names the recovery verbatim:
   `.operator/bin/ops-adopt.sh --owner <sid> <task-id>` re-stamps ownership
   **and** re-creates the marker — the existing recovery path, not a new one.
2. `ops-verdict.sh` recomputes the marker on every run, so any desync is
   corrected at the next verdict rather than persisting.
3. The gate is **opt-in in 0.7.0** (`.operator/armgate.on`, absent by default).
   A false block can only reach a project that asked for it.

Ownership-scoping is not optional here, and that is why the marker is keyed by
session id: an unscoped "is `pending/` non-empty?" check would let session B
write freely because session A holds a task open — reintroducing precisely the
cross-session fail-open that 0.4.0 exists to close.

### G3 — the exemption pays for itself at the other end

A blocking gate with no override is how sessions wedge, and a wedged session is
this repo's recurring worst outcome ("a guard that makes an existing task
unclosable is worse than the bug it fixes"). So the arm gate ships with an
escape hatch — and the hatch is **not free**:

```
.operator/bin/ops-task.sh --exempt "<reason>" --owner <sid>
```

writes a `GATE-EXCEPTION` line to DECISIONS.md (tagged `[sid:…]`) and creates
the marker. Bypassing the arm gate therefore **owes a handoff presentation**,
enforced by the stage-2 deviation gate that already ships. The hatch is real,
one command, and auditable — which is the same shape `ops-task.sh` gave to
opening a task in 0.3.0.

### G4 — what G1+G2 together do and do not achieve

- **Achieved:** every write is bracketed by an open sentinel (G2) and every
  "done" is bracketed by a row that says whether the gate ran (G1). The loop
  closes.
- **Not achieved until 0.8.0:** with G2 opt-in, the hole is **closable, not
  closed.** Say this plainly in the changelog. The flip to default-on is a
  one-line default change gated on field evidence — the same conservatism the
  issue #9 post-mortem earned (a gate stage shipped default-on that
  phantom-blocked every ledger with a long row, and whose clearing path was
  unreachable).

---

## 3. Decisions — the backlog as the plan of record (B)

Assumption to verify at implementation time: the Backlog.md CLI surface below is
read from its README (2026-08-06). **Pin the version and re-verify every flag
against `backlog --help` before writing code** — a spec that hard-codes a
neighbour project's flags is a spec that rots silently.

### B1 — the backlog is the plan; the ledger is the proof. No state duplication.

`.operator/` never mirrors task state. Status, dependencies, priority, and
acceptance criteria live in `backlog/tasks/*.md` and are read, never copied. The
ledger holds what the backlog structurally cannot: evidence, and the verdict
adjudicated from it. Two files, two jobs, one direction of flow.

The reason this is a rule and not a preference: the moment task state exists in
two places, one of them is wrong and nothing says which. That is E1's shape
again.

### B2 — identity mapping: **one sentinel per acceptance criterion**

Gate id = `<backlog-id>#ac<N>` — e.g. `task-42#ac3`.

Charset check against `check_bare_name` (`ops-task.sh:34-40`): rejects `/`, a
leading `.`, `|`, and newlines. `#` and `-` pass. Safe as a filename, safe as a
fragment name, safe as a ledger cell.

Why per-AC rather than per-task: `ops-verdict.sh` clears the sentinel on the
**first** row it writes. A per-task sentinel would need a new `--keep-open` flag
for intermediate rows — new surface on the single writer, which is the most
dangerous file to widen. Per-AC needs **zero code change** and buys a property
we want anyway: the task is done exactly when its last sentinel clears, so the
Stop gate mechanically enforces *every AC adjudicated*, not merely *the task
touched*.

Cost, stated: N sentinels open at once for an N-criterion task, and the
statusline renders N. That is accurate reporting, not noise — it is the true
count of unadjudicated criteria.

### B3 — the BAR block is **derived**, never authored freehand

For a backlog-driven engagement the BAR block is generated from:

- the task's acceptance criteria (`--ac` items, in file order → `#ac<N>`), plus
- the project's `definition_of_done` from `backlog.config.yml`, applied to every
  task in the engagement.

Each becomes a done-criterion in the charter's required shape: **command +
expected output**. An AC that cannot be expressed that way is not yet a
criterion — and the existing `plan` workflow already has the lens that says so
(`testable: "no"`, whose issue detail must name the observable command that
would make it testable). Reuse it: a `testable: no` AC is **rewritten in the
backlog, before lock**, not waved through.

This is the concrete answer to E3 — the criteria are authored in the backlog and
merely *transcribed* into the bar; the operator's remaining job is adjudication.

### B4 — sequencing is deterministic, not agentic

`dependencies` are topologically sorted **in the workflow script**, in JS. No
agent is asked to order tasks. This follows the Workflow tool's own guidance
(deterministic control flow belongs in the script) and removes a whole class of
non-reproducible plan drift.

A dependency **cycle** is not a scheduling problem — it is a plan-level
contradiction, escalation ladder rung 4, and one of the few things that reaches
the human (§4, R3).

### B5 — read the backlog through its own machine interfaces

`backlog task list --json` / `backlog task <id> --plain` are canonical. We never
parse `backlog/tasks/*.md` ourselves: their frontmatter and section grammar are
the neighbour project's to change, and a hand-rolled parser is a silent-breakage
surface with no owner here.

### B6 — CLI over MCP

Backlog.md ships an MCP server (`backlog mcp start`). Prefer the CLI anyway:
workflow-dispatched subagents carry Bash by construction, whereas
interactively-authenticated MCP servers may be **absent in headless and
scheduled runs** — the exact runs where an unattended backlog engagement is most
valuable. MCP stays supported for interactive use; the CLI is what the workflow
and the gate depend on.

### B7 — `backlog/` joins the standing FORBIDDEN set *(highest-value delta here)*

`ops-claims.sh`'s `PROTECTED=` set makes gate files off-limits to an implementer
unless the task **is** the gate. Acceptance criteria are now gate inputs: an
implementer that can edit `backlog/tasks/*.md` can **edit the criteria it is
being judged against**. That is the F48 class — a vacuous guard — relocated to
the plan layer, and it would be materially harder to spot than a weakened
validator, because the diff looks like ordinary task bookkeeping.

Add `backlog/` to `PROTECTED`. Criteria changes are an operator act, and under a
locked bar they are a **human** act (§4, A2).

Per `CLAUDE.md`, this delta is not a one-line edit: it must move
`validate_plugin.check_claims` (which pins the literal **and** its
`matches_protected` application — F30) and the *"ops-claims verifies
diff-matches-claims"* cases together.

### B8 — `autoCommit` must be off

Backlog.md can commit task-state changes itself. That bypasses the operator's
commit discipline and directly violates F-A13 (a worker-authored commit message
uses the worker's own report sentence). Preflight requires `autoCommit: false`
in `backlog.config.yml` and refuses to lock a bar otherwise.

### B9 — `ops-backlog.sh --audit`: phantom-done detection

The mechanical analogue of `ops-claims.sh`, one layer up. It cross-reads checked
acceptance criteria against VERDICTS.md rows:

| Finding | Meaning | Severity |
|---|---|---|
| AC checked, **no PASS row** for `<id>#ac<N>` | **phantom done** — the exact failure this integration exists to prevent | FAIL-shaped, logged before any other action |
| PASS row, AC unchecked | lag | benign; auto-fixable by re-running the check |
| AC checked, row is FAIL | contradiction | FAIL-shaped |

**It does not become a Stop-hook stage in 0.7.0.** A third ledger in the Stop
gate multiplies the ways a session wedges, and issue #9 is the standing evidence
that a new gate stage's first field contact finds its false positives. Ship it
as a CLI plus a charter rule; promote only on evidence.

---

## 4. Decisions — locked-goal autonomy (A)

The ask: *judge own decisions without constant sign-offs when the goal is
locked.* The charter is already fairly autonomous on paper (only plan-level
contradictions reach the human). What is missing is the thing that makes
autonomy safe to *actually exercise*: a **closed** list of what still interrupts,
and an integrity pin on the goal so autonomy cannot quietly redefine success.

### A1 — the lock is an artifact, not a mood

```
.operator/bin/ops-bar.sh lock <engagement-id>
```

appends a `BAR-LOCK` line to DECISIONS.md carrying:

- the **content hash** of the BAR block in VERDICTS.md,
- the **blast radius** — path globs the engagement may touch,
- the budget (time / cost / iteration) and the three caps,
- the release conditions in force (A3), by reference.

The human's approval is out-of-band (they say go). The lock's job is not to
prove approval happened; it is to make the approved thing **immutable and
identifiable** so later drift is detectable rather than arguable.

### A2 — you cannot re-lock your own goal *(the integrity keystone)*

An operator that may amend its own done-criteria has no gate at all — it has a
mood ring. Mechanically: `ops-verdict.sh` (and `ops-backlog.sh --audit`)
recompute the BAR block's hash against the pin. On mismatch:

- a **PASS** against that bar is refused, and
- a `GATE-EXCEPTION` is written.

The operator's unilateral moves against a locked bar are exactly two: **fail**
it, or **defer** it with a reason. Amending it is a human act. This is what lets
everything else in §4 be permissive without being hollow.

### A3 — the closed release list *(the default inverts)*

Under a locked bar the operator **decides and proceeds**. It stops for the
human only on this list, and the list is closed — if it is not here, it is the
operator's call:

| # | Release condition | Already exists as |
|---|---|---|
| R1 | any of the three caps trips | charter cap table — already "a defined stop-and-report" |
| R2 | the review workflow's adversarial seat returns **REFUTED** | already an unoutvotable hard stop |
| R3 | escalation ladder **rung 4** — the plan itself is wrong (incl. a dependency cycle, B4) | already "only plan-level contradictions reach the human" |
| R4 | BAR-block hash mismatch (A2) | new |
| R5 | work would touch paths outside the locked blast radius | `ops-claims.sh` C3 gate-trespass, re-aimed at the radius |
| R6 | an irreversible act outside the radius (force-push, history rewrite, deleting a result set) | the charter's destination-check clause, promoted to a release condition |

Five of six are existing tripwires renamed into one list. That is the point:
autonomy here is not new permission, it is **the removal of the ad-hoc asking
that was never required in the first place.**

### A4 — autonomy is paid for at the handoff

Every unilateral call under a locked bar is logged:

- routine choices → `DECISION` (a **record** kind: logged, never blocks Stop);
- departures from the plan → `DEVIATION` (a **gated** kind: blocks Stop until
  `ops-verdict.sh --mark-handoff` presents it).

So the human reviews the whole engagement's judgment in **one batch**, at the
handoff, and the stage-2 deviation gate makes that batch unskippable. This is
the sentence worth keeping: *no constant sign-offs* does not mean *no
oversight*; it means oversight is deferred and batched, and a shipped gate
enforces the deferral rather than the operator's good intentions.

### A5 — adjudication is the operator's; the checkbox is derived

`backlog task edit <id> --check-ac <N>` is **never** a hand-edit and never a
worker's act. It runs only after a PASS row exists for `<id>#ac<N>`. The
checkbox is a *rendering* of the ledger, which is what B9's audit checks.

---

## 5. The workflow — `workflows/backlog.js`

Phases, and which are agentic:

| Phase | Tier / mechanism | Output |
|---|---|---|
| 1. **Ingest** | RECON fan-out over `backlog task list --json` + per-task `--plain` | structured task records: id, deps, status, AC list |
| 2. **Bar** | JUDGMENT, single | the derived BAR block (B3) — the one artifact the human sees before lock |
| 3. **Sequence** | **no agent** — topo-sort in JS (B4) | ready set, in dependency order; a cycle → R3 |
| 4. **Execute** | `pipeline()` per ready task: implement (IMPLEMENT) → claims check → review workflow for mergeable work | per-task evidence bundle |
| 5. **Adjudicate** | JUDGMENT, per AC | recommended verdict + the evidence that supports it |

**The workflow never writes the ledger.** Workflow scripts have no filesystem
access, and more importantly `ops-verdict.sh` is the single writer and the
*operator* is its single caller. The workflow produces adjudication **inputs**;
the operator writes the row. That keeps "the operator adjudicates" literally
true rather than rhetorically true, and it keeps the single-writer invariant
that the whole lock design rests on.

Structural requirements inherited from `docs/PLAYBOOK.md` § "Changing a
workflow" — non-negotiable, build-enforced:

- `export const meta = {…}` first; `ROUTABLE` and `BAD_CHARSET` byte-identical
  to the other four; `KNOWN_TIERS` equal to `ops-tiers.sh`'s `TIER_NAMES`
  (all four, as a **code** line — a commented one does not satisfy the check);
  the `A` IIFE args normalizer.
- **`agent()` null is a DEATH, not an empty result** (F31/F32). Phase 1 shards
  and phase 5 adjudicators each need the `dead:` / `vettingIncomplete:` marking,
  and phase 5's terminal call must return an explicit `{error, …}` carrying the
  surviving upstream work. A dead adjudicator must never produce the same shape
  as a clean adjudication.
- Any `agentType` must name a **shipped plugin-root agent** (F22).

---

## 6. Artifact deltas and the charter budget

### 6.1 New / changed files

| File | Change |
|---|---|
| `scripts/ops-verdict.sh` | G1 retro-gate; A2 bar-hash pin; `.armed/` recompute under the existing lock |
| `scripts/ops-task.sh` | create `.armed/<sid>`; `--exempt "<reason>"` (G3) |
| `scripts/ops-adopt.sh` | create `.armed/<sid>` |
| `scripts/ops-armgate-hook.sh` | **new** — PreToolUse arm gate (G2), opt-in |
| `scripts/ops-backlog.sh` | **new** — `--audit` (B9), bar derivation helper (B3), preflight (B8) |
| `scripts/ops-bar.sh` | **new** — `lock` (A1); may instead land as `ops-verdict.sh --lock-bar`, see Q3 |
| `scripts/ops-claims.sh` | `PROTECTED` gains `backlog/` (B7) |
| `scripts/ops-init.sh`, `ops-sessionstart-hook.sh` | install set gains the new CLIs; `.operator/.gitignore` gains `.armed/` |
| `hooks/hooks.json` | new `PreToolUse` block |
| `workflows/backlog.js` | **new** (§5) |
| `commands/backlog.md` | **new** — where the prose the charter cannot afford lives |
| `scripts/validate_plugin.py` | see 6.3 |

### 6.2 The charter budget — 1 line spare (E4)

**Maximum 4 new charter lines**, and they must be paid for. Proposal:

- ENGAGEMENT CONTRACT, +2: when a backlog exists the bar **derives** from its
  ACs + `definition_of_done` (B3); once locked, the operator decides and stops
  only on the release list, by reference to `/cc-operator:backlog` (A3).
- EVIDENCE GATE, +2: gate ids are `<backlog-id>#ac<N>` (B2); an AC is checked
  only after a PASS row (A5).

Paid by reclaiming ~4 lines of ORCHESTRATED-MODE prose, **or** by raising
`CHARTER_MAX_LINES`. Raising the cap is the wrong instinct — the cap bounds
always-on tokens and F19 added the byte bounds precisely to stop packing from
defeating it. Reclaim first; if the reclaim is not clean, that is a finding
about the charter, not a reason to move the line.

Everything else — backlog setup, the release list in full, the audit's output
grammar — lives in `commands/backlog.md`, `skills/chief-operator/SKILL.md`, and
this spec.

### 6.3 Coupling-table rows to add to `CLAUDE.md`

Written in the existing table's shape so they can be pasted:

| If you change…                                        | You must also…                                                                                                                                                                                                 |
| ----------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| the `.armed/<sid>` marker convention                  | update **all three** writers (`ops-task.sh`, `ops-adopt.sh`, `ops-verdict.sh`) and the arm hook's one-stat read; the marker is a derived cache of "this session owns ≥1 pending sentinel" — stale-true must stay fail-OPEN |
| the arm gate's tool matcher in `hooks.json`           | keep `Bash` OUT of it (G2) and update the deny message, `commands/backlog.md`, and the *"arm gate"* cases                                                                                                        |
| the AC↔gate-id convention `<backlog-id>#ac<N>`        | update `ops-backlog.sh --audit`, the charter's EVIDENCE GATE line, and the bar-derivation helper — the id is the join key between two projects' files                                                            |
| `PROTECTED=` in `ops-claims.sh` (now incl. `backlog/`)| the existing row already covers it: `validate_plugin.check_claims` pins the literal AND its `matches_protected` application (F30), plus the *"ops-claims verifies diff-matches-claims"* cases                     |
| the BAR-block hash input (A2)                         | update `ops-bar.sh lock`, `ops-verdict.sh`'s pin check, and `ops-backlog.sh --audit`; a hash over a different byte range silently un-pins every locked bar                                                       |

New validator obligations: `CHARTER_REQUIRED_CLIS` gains the new CLIs, which
transitively moves `check_scripts`, `check_install_set_parity` (pins the
`ops-init.sh` and `ops-sessionstart-hook.sh` lists equal — CR4), and the
`GATE_CLIS` literal in `ops-compress.mjs` (the I2.1 carve-out). A new
`check_armgate` should pin the matcher set and assert `Bash` is absent from it —
the one property whose silent loss would turn a rail into a wedge.

---

## 7. Rollout — three shippable slices

| Slice | Contents | Risk |
|---|---|---|
| **0.7.0** | G1 retro-gate (default-on), B7 `PROTECTED` delta, `ops-backlog.sh --audit`, B8 preflight | low — no new blocking surface; one new gated-kind emitter |
| **0.7.x** | G2 arm gate **opt-in**, G3 exemption, `.armed/` markers, `workflows/backlog.js`, `commands/backlog.md`, charter deltas | medium — first blocking PreToolUse hook in the repo |
| **0.8.0** | flip G2 default-on; consider promoting B9's audit to a Stop stage | high — gated on field evidence from 0.7.x, not on a calendar |

Slice 1 is independently valuable: even with no backlog and no arm gate, G1
alone makes "the gate did not run" a fact the ledger records.

---

## 8. What this does NOT prove

Kept in the PLAYBOOK's register — add to it when a new gap is found.

| Not proven | Why |
|---|---|
| PreToolUse `exit 2` denies the tool call in the running Claude Code build | The Stop hook's exit-2 contract is exercised live; the PreToolUse one is not, here. Needs a live end-to-end check before G2 ships — the same class as the existing "a live SessionStart payload carries `cwd`" row. |
| The arm gate stops a determined agent | It does not, and is not meant to (G2). Bash is ungated by design. |
| The `.armed/` marker cannot desync | It can. The claim is only that the desync direction is analysed and the harmful direction is mitigated three ways (G2.1). |
| Backlog.md's flags are as documented | Read from the README on 2026-08-06 and not executed. Verify against `backlog --help` and pin the version (B-preamble). |
| A locked bar prevents goal drift | It prevents *silent* goal drift. An operator can still fail or defer everything and hand back an honest nothing — which is the intended escape, not a hole. |
| The retro-gate distinguishes "never armed" from "armed in another session" | It reads this session's fragment. A task armed by session A and closed by session B (after `ops-adopt.sh`) is the case to test explicitly. |

---

## 9. Open questions for the human

1. **Q1 — does G2 ship opt-in?** This spec says yes and argues from issue #9.
   The counter-argument is real: an opt-in gate does not close E1, it makes it
   closable. Ship-default-on is defensible if the appetite for a wedged session
   is higher than assumed.
2. **Q2 — per-AC sentinels (B2) vs per-task + `--keep-open`.** Per-AC needs no
   change to the single writer, which is why it is recommended; the cost is N
   open sentinels and an N-row statusline for an N-criterion task. If that reads
   as noise in practice, the trade flips.
3. **Q3 — `ops-bar.sh` as a new CLI, or `ops-verdict.sh --lock-bar`?** A new CLI
   grows the install set and every parity check that pins it. A new flag widens
   the single writer, which is the most dangerous file in the repo. Leaning to
   the flag, on the grounds that the lock is a ledger write and the ledger has
   exactly one writer by design.
4. **Q4 — does `backlog/` in `PROTECTED` (B7) over-restrict?** It forbids an
   implementer from writing `--notes` / `implementation_notes` back to its own
   task, which is a genuinely useful worker behaviour. The alternative is a
   field-level rule (notes writable, acceptance criteria not), which needs a
   parser for the neighbour project's file grammar — squarely against B5.
5. **Q5 — is `definition_of_done` per-engagement or per-task?** B3 applies it to
   every task in the engagement. If a project's DoD is heavyweight, that
   multiplies criteria by task count and the bar becomes unreadable.
