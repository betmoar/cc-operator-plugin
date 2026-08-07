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

### E4 — the charter's headroom, and which cap actually binds

Measured at `71732ff`, when this spec was written:

| Bound | At 71732ff | Cap |
|---|---|---|
| lines | **149** | 150 |
| bytes | 8194 | 9000 |
| longest non-table line | 83 | 100 |

One line spare — which read as "no new charter section is affordable", and §6
was budgeted against that. **That reading was wrong, and the correction is
measured**: the charter was wrapped at ~75–83 columns against a 100-column cap,
so 13 of those 149 lines were formatting, not content. After a reflow to 95
columns (verified word-for-word identical — see §6.2) the file is 136/150 lines
and 8188/9000 bytes.

The constraint is therefore real but has **moved axis**: ~812 bytes ≈ 8 more
full lines, against 14 spare lines. Bytes bind now, and no further reflow can
buy room — that lever is spent. Budget in bytes; a proposal that counts only
lines is measuring the cap that stopped binding. Everything below is budgeted
against this (§6.2).

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
- It **never refuses the verdict** on any path the gate was actually used on.
  Refusing there would strand real evidence outside the ledger — strictly worse
  than recording it with a caveat. The single exception is the never-armed row
  with no owner to attribute it to; see the third requirement.
- It converts E1 from an invisible hole into a **visible, costly** one. Skipping
  the gate is still possible; it is no longer deniable.

Two implementation requirements, both derived from existing landmines:

- **The prior-row lookup must be bounded**, and read the session fragment
  (`verdicts.d/<owner>.md`), not all of VERDICTS.md. Note what is NOT true: the
  earlier draft claimed `FRAG_MAX_BYTES` already bounds that file. It does not —
  the size refusal exists only inside the `--reconcile` branch
  (`ops-verdict.sh:417-419`); the direct verdict path never stats the fragment.
  G1's lookup would therefore be the **first unbounded read under the lock**,
  which is exactly the PLAYBOOK "touching the lock" step-3 hazard this bullet
  cites. Lift `FRAG_MAX_BYTES` to function scope and apply it to every fragment
  read, and scan in reverse — a fragment is append-only, so the newest row for
  `<id>` is at the tail (the same reverse-tail strategy `statusline.sh` uses).
  Deriving the state from `pending/` instead is not an option: never-armed and
  duplicate/amending BOTH have an absent sentinel, so only the ledger can tell
  them apart.
- **A never-armed verdict with no `--owner` is refused.** The `GATE-EXCEPTION`'s
  what-cell must carry `[sid:<session>]`, and on this path there is no session to
  name: `SOWNER` is empty because there is no sentinel, and no flag was given. An
  untagged (or `[sid:unowned]`) gated line is unowned, and unowned fails CLOSED —
  it would block **every** session until someone presents it, which is precisely
  the cross-session wedge 0.4.0 exists to remove. Refusing is the honest move and
  costs nothing: SessionStart always names the id, so `--owner` is always
  available. Scope it narrowly — the ordinary armed verdict (sentinel present,
  `SOWNER` supplies the owner) and the duplicate/amending row still proceed
  without a flag, exactly as today.

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
  `.operator/.armed/S` (empty marker), **after** the sentinel exists. The reverse
  order opens a window where the marker outlives no sentinel; that direction is
  harmless (stale-true) but the correct order is free.
- `ops-verdict.sh` (verdict **and** `--defer`) → after clearing the sentinel,
  **under the lock it already holds**: remove `.operator/.armed/S` FIRST, then
  rescan `pending/` for any sentinel owned by `S`, and re-create the marker if one
  remains. The order matters and the intuitive one is wrong. Clear → rescan →
  conditionally-remove loses this interleaving:

  ```
  verdict:  clear sentinel
  verdict:  rescan pending/ → empty
  task:                        creates sentinel (O_EXCL, no lock — by design)
  task:                        creates marker
  verdict:  rm .armed/S                          ← marker gone, sentinel present
  ```

  That is stale-FALSE, the one direction the table below calls "the one to
  prevent", and none of the three mitigations addresses it — they are written for
  a desync that persists, not one the recompute itself creates (and mitigation 2,
  "the next verdict corrects it", is circular: the next verdict can lose the same
  race). Remove-then-rescan-then-restore is safe under every interleaving: a
  sentinel created before the rescan is seen by it, one created after brings its
  own marker.
- The hook's entire check is: gate enabled → `[ -e ".operator/.armed/$session" ]`
  **or** `[ -e ".operator/.armed/$session.exempt" ]` (G3). One or two stats. No
  parsing, no byte bounds, no partition, builtins only by construction.

**Why a marker at all, rather than globbing `pending/`.** The hook must answer
"does THIS session hold a task open", not "is `pending/` non-empty" — the
unscoped question lets session B write freely because session A has work open,
reintroducing the cross-session fail-open 0.4.0 closed. Answering the scoped
question means parsing `session_id:` out of a sentinel body, and in this repo
that is not a `grep`: it is `LC_ALL=C`, the `-L` symlink rejection, a NUL probe
before the loop, and a 512-byte bounded read (`ops-stop-hook.sh:140-158`) — sixty
lines that would become a **fourth** copy, on a hook that fires before every
edit. `CLAUDE.md`'s coupling table already carries that duplication as a known
cost at three copies. The derived marker is the cheaper trade, and its desync
directions are analysed below rather than assumed away.

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
   A false block can only reach a project that asked for it. Confirmed as the
   shipping default (Q1, §9): default-on would not close E1 either — `Bash` is
   ungated at any setting — so both options deliver *closable*, and only one of
   them can wedge a session. G1 is default-on and covers the same ground
   retroactively, which makes opt-in G2 a second layer rather than a hole.

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

Two things that phrasing hides, both decided here:

- **`ops-task.sh` does not become a ledger writer.** It takes no lock today, on
  purpose — `set -C` gives it an O_EXCL create and *"no lock needed, the kernel
  arbitrates"* (`ops-task.sh:93`). Every DECISIONS.md append in the repo happens
  inside `ops-verdict.sh` under `lock_acquire`, and `check_lock_parity`
  (`validate_plugin.py:721`) pins that block across the writers that have it.
  Giving the opener a lock copies that block to a third file and puts lock code
  in the path that runs on every task open, for the sake of one rare flag. So
  `--exempt` stays the operator-facing surface and **delegates the write** to
  `ops-verdict.sh`, which already holds the lock and is already the single
  writer. No new lock site, no `check_lock_parity` edit, and the invariant in
  `CLAUDE.md`'s load-bearing map stays literally true.
- **The exemption marker is a distinct file: `.armed/<sid>.exempt`.** It has to
  be, because G2.1's recompute *derives* armed-ness from `pending/` — and an
  exempt session by definition has nothing there, so the recompute would delete
  a plain `.armed/<sid>` the moment any verdict ran. Two marker kinds, two
  lifetimes: `.armed/<sid>` is derived and recomputed under the lock;
  `.armed/<sid>.exempt` is granted and the recompute never touches it. The
  distinction is one the earlier draft assumed without naming.

**An exemption is session-scoped and expires with the session.** A `/clear`
rotates the session id, so the marker becomes unreachable on its own and the
deviation gate has already collected the presentation debt by then. Nothing needs
to sweep it beyond the ordinary ephemera cleanup — and under the v2 allowlist
`.gitignore` (§6.1) it is ignored by construction, like every other file the
plugin creates.

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
- the project's `definition_of_done` from `backlog.config.yml`, **filtered** —
  see below (Q5).

Each becomes a done-criterion in the charter's required shape: **command +
expected output**. An AC that cannot be expressed that way is not yet a
criterion — and the existing `plan` workflow already has the lens that says so
(`testable: "no"`, whose issue detail must name the observable command that
would make it testable). Reuse it: a `testable: no` AC is **rewritten in the
backlog, before lock**, not waved through.

**The DoD filter (Q5, decided).** Applying every `definition_of_done` item to
every task multiplies criteria by task count and makes the bar unreadable;
applying it once per engagement converts it from a done-condition into an
end-of-run check that can fail everything without naming which task failed.
Neither is right, and the same `testable` lens sorts them: a DoD item that yields
a command + expected output **per task** ("the suite passes") belongs in every
task's bar; one that does not ("documentation updated") becomes a **single
engagement-wide AC** rather than N unfalsifiable copies. Point the lens at DoD
items, not only at ACs.

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

### B5 — read task state through a machine interface, never a hand-rolled parser

**Amended 2026-08-08 (issue #17): the original premise is gone, the rule stands.**
This section used to argue that `backlog task list --json` is canonical *because
the frontmatter grammar is the neighbour project's to change*. With the
no-third-party decision (§10, U2) there is no neighbour — we own the grammar — so
that reason no longer applies and cannot be cited.

The rule survives on a different and stronger footing: **a hand-rolled parser is a
silent-breakage surface regardless of who owns the grammar.** Ownership changes
who can break it, not whether the break is silent. The failure this repo keeps
re-learning is the *silent* half (F02's unbounded reads, F30's copy parity, #9's
long rows) — every one of them a reader that kept working while meaning something
different.

Concretely, post-U2, the machine interface is **`gh issue` and its `--json`
output** (see #16): issue state is open/closed, `p0`–`p5` labels are priority.
That is an interface we already depend on, maintained by someone else's tests, and
it has no file for us to mis-parse.

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

**The whole directory, with no carve-out for notes (Q4, decided).** The obvious
objection is that this forbids an implementer from writing `--notes` /
`implementation_notes` back to its own task, which is genuinely useful. The
tempting fix — a field-level rule, notes writable and criteria not — requires
parsing a frontmatter grammar field-by-field, which B5 forbids.

**Amended 2026-08-08 (issue #17):** B5's reason used to be "that grammar is
theirs to change"; post-U2 we own it, so the carve-out must be refused on its own
merits rather than by borrowing a premise that no longer holds. It is, and the
merits are sharper: a field-level rule means the guard's correctness depends on
**parsing the very file the worker is editing.** A worker that can shape that file
can shape how the guard reads it — the F48 vacuous-guard class, with the guard's
input under the guarded party's control. Whole-directory needs no parse, so there
is nothing to subvert. Ownership of the grammar does not change that; if anything
it removes the last excuse for the weaker rule.

It is also unnecessary: **the implementer does not need write access to record a
note.** It reports the note in its REPORT and the operator writes it with
`backlog task edit --notes`. That is the same routing A5 sets for checking an AC
(only after a PASS row) and the same routing G3 takes for its ledger write — the
worker produces the content, the operator performs the act.

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

### B10 — on a large repo, naming the unknowns is task #1, and everything blocks on it

The charter already routes discovery: *surface unknowns before building, not
after* — fuzzy → interview, unfamiliar code → blindspot pass [DOC:spec-unk].
What it does not do is make that routing **structural**. It is a rule the
operator applies by judgment, and the failure mode is silent: an unknown that was
never named does not appear anywhere as a gap. It appears later as a wrong build.

The evidence is this spec. Its two most expensive defects — §6.3 pointing an
implementer at `check_install_set_parity` and `check_scripts`, neither of which
reads `CHARTER_REQUIRED_CLIS`, and the claim that `FRAG_MAX_BYTES` bounds a read
it never reaches — are both **unknowns about existing code written down as
knowns**. On a repo of this size (59 tracked files, 22 code files, ~11K LOC) it
took a review panel with a dedicated claim-check lens to find them, and that lens
died once on a retry cap and had to be re-run on a second model. Scale the
codebase and that class does not get rarer; it gets harder to see.

So: **above a size threshold, the backlog's first task is to name the unknowns,
and every other task is `blockedBy` it.**

- **Shape.** The workflow (§5) inserts the task at ingest time, before
  sequencing. B4's topological sort then does the rest — it is already
  deterministic and already in JS, so "everything blocks on #1" needs no new
  mechanism, just one synthetic node with an edge to every root.
- **Threshold, a number and not a judgment.** The charter's own idiom is that a
  cap trip is *"a defined stop-and-report, not a judgment call"* [D:roadmap-s1];
  a discovery gate that fires on vibes is the thing this rule exists to replace.
  The census must be cheap enough to run unconditionally at ingest — on this repo
  `git ls-files` is ~10ms — and it must be stated in the bar so the human can see
  which side of the line the engagement fell on.
- **Done-condition.** The task closes on a PASS row citing a written unknown
  register, not on "we considered it". Same rule as every other AC: a row without
  evidence is FAIL by definition [D:CHART-def]. The register is the artifact; the
  verdict is the proof it exists.
- **Interaction with the bar (A1/A2).** The unknowns task runs BEFORE the bar is
  locked, or it cannot inform the criteria it exists to correct. That makes it
  the one task whose output legitimately changes the bar — which is not an
  exception to A2, because A2 governs re-locking an *already locked* bar. State
  the ordering explicitly so the two rules cannot be read as contradicting.

Open, and deliberately not decided here — the threshold value. This repo is the
only measured point (59/22/11K) and it is small; a rule calibrated on one sample
is a guess with a number on it. The 4th acceptance criterion below is what turns
it into a measurement.

Acceptance criteria:

1. `ops-backlog.sh --census` prints file count, code-file count and code LOC for
   the repo, and exits 0 in under 1s on a repo of ≥10K files.
2. With the threshold exceeded, the workflow's phase-3 output has the unknowns
   task first and every root task carrying it in `blockedBy`; below the
   threshold, no such task is inserted. Both directions tested.
3. The BAR block records the census numbers and which side of the threshold they
   fell on — so a later reader can tell "no unknowns task" from "the gate did not
   run", which is E1's shape at the plan layer.
4. The threshold itself is set from at least three measured repos of different
   sizes, with the false-positive cost (ceremony on a small repo) and
   false-negative cost (a wrong build on a large one) stated for each. Until then
   the value ships as a documented guess, not as a tuned constant.

### B11 — a register the engagement outgrew is a register that lies

B10 gets the unknowns *named*. B11 is the other half of the same problem, and it
is the one that shows up in every long engagement: **the register is written once
and then drifts out of date silently.** Two drifts, both observed in the field:

- A finding is resolved, but its entry still sits in the open section carrying
  its original *"Done looks like"* prose. A reader — human or agent — cannot tell
  a live finding from a dead one without re-deriving the whole thing.
- An unknown becomes known, and nothing removes it from the unknowns table. *If
  an unknown is known it is no longer unknown.* A table that still lists it is
  not merely stale, it is **wrong about the state of the work**, and it costs the
  next session a re-investigation of a question already answered.

The failure is not carelessness. It is that closing a finding and moving its
entry are two separate acts, and only the first one has a mechanism. So the
second gets done by hand, at the end, by an agent reading the document and
reasoning about which prose is obsolete — expensive, unreliable, and exactly the
kind of bookkeeping that has a machine answer available.

**The ledger already knows.** A PASS row for `<id>#ac<N>` is the fact that the
finding closed; DECISIONS.md holds the deviations and the handoff marks. The
register duplicates that state in prose, and B1's rule is precisely that
duplicated state means one copy is wrong with nothing to say which. B9 already
cross-reads checked ACs against ledger rows for the *backlog*; B11 is the same
cross-read aimed at the **register documents**.

`ops-backlog.sh --audit` gains a register pass. Given a register file (the spec,
a review-findings doc, an unknowns table) it reports, and never edits:

| Finding | Meaning |
|---|---|
| an open-section entry whose id has a PASS row | resolved-but-unmoved — belongs in the closed section |
| an unknowns-table row whose id has a PASS or a DECISIONS resolution | **known, still listed as unknown** — the drift that costs a re-investigation |
| a closed-section entry with no PASS row | closed without evidence — the phantom-done shape (B9), one layer up |
| an entry referencing an id absent from the backlog and the ledger | a dangling cross-reference; the id was renamed or the entry was never real |

**It reports, never rewrites.** The prose that accompanies a moved finding is a
judgment — *why* it closed, what it cost, what it taught — and a mechanical move
would either drop that or fabricate it. What the audit removes is the
*detection* burden, which is the part that is mechanical and the part that gets
skipped. The operator still writes the sentence.

Deliberately not in scope: inferring resolution from prose ("this reads like it's
done"). The only resolution signal is a ledger row, because that is the only one
with evidence behind it — `D:CHART-def` applies to registers exactly as it does
to verdicts.

Acceptance criteria:

1. `ops-backlog.sh --audit --register <file>` prints one line per finding in the
   four kinds above and exits non-zero when any resolved-but-unmoved or
   known-but-listed-unknown row is found; exits 0 on a clean register.
2. Run against this spec at the commit that resolves the panel findings (§8b), it
   reports zero drift — the register and the ledger agree. That is the test that
   the audit is describing reality rather than a format it invented.
3. A register entry whose id has a **FAIL** row is reported as still-open, not as
   resolved. A row's existence is not resolution; its verdict is.
4. The audit never writes to the register: assert the file's hash is unchanged
   across a run that reports findings.

---

## 4. Decisions — locked-goal autonomy (A)

The ask: *judge own decisions without constant sign-offs when the goal is
locked.* The charter is already fairly autonomous on paper (only plan-level
contradictions reach the human). What is missing is the thing that makes
autonomy safe to *actually exercise*: a **closed** list of what still interrupts,
and an integrity pin on the goal so autonomy cannot quietly redefine success.

### A1 — the lock is an artifact, not a mood

```
.operator/bin/ops-verdict.sh --lock-bar <engagement-id> --owner <sid>
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
mood ring. Mechanically: the BAR block's hash is compared against the pin, and on
mismatch a `GATE-EXCEPTION` is written naming the drift.

**Where that comparison runs is a decision, not a detail.** The obvious place is
`ops-verdict.sh`, so a PASS against a drifted bar is refused synchronously. It is
the wrong place, for two reasons that compound:

- **VERDICTS.md has no size bound and no block grammar.** `FRAG_MAX_BYTES` is the
  only bound in the file (`ops-verdict.sh:81`) and it covers fragments, not the
  ledger; `templates/VERDICTS-header.md` defines a 4-cell table with no BAR-block
  delimiters. Hashing "the BAR block" on every verdict is therefore an unbounded
  read inside the critical section — the same PLAYBOOK step-3 hazard G1 was just
  corrected for.
- **A boundary guessed at read time produces false drift.** With no delimiters,
  where the block starts and stops is a heuristic; a row that grows against it,
  or a later tweak to the heuristic, changes the hash without anyone having
  touched the bar. A keystone gate that cries wolf gets switched off, and then it
  guards nothing.

So the hash is computed **once, at lock time**, by `--lock-bar` — which reads the
block before taking the lock, where a full read is legitimate — and the
`BAR-LOCK` line records the hash **and the block's boundary**. Verification moves
to `ops-backlog.sh --audit`: a path that holds no write lock and where a full read
is expected. The lock line becomes the only place the block is ever interpreted.

**The write and the verify live in different files, and that split is the point**
(Q3, decided). The lock is a DECISIONS.md append, so it belongs to the single
writer under the lock it already holds — the same reasoning that put G3's
`--exempt` write there rather than giving `ops-task.sh` a lock. The verify is a
*read*, needs no lock, and must NOT live in the writer: A2.6 pins that
`ops-verdict.sh` computes no hash at all. There is therefore no `ops-bar.sh`; a
CLI that would hold one flag on each side of that split is a CLI whose two halves
belong in two different places.

The cost is real and stated plainly: drift becomes **detected** rather than
**refused**. A PASS against a drifted bar is written and then flagged, instead of
being blocked at the moment of writing. That is the right trade because A2's own
stated goal is to make drift *"detectable rather than arguable"* — an audit that
finds the mismatch and writes the `GATE-EXCEPTION` achieves exactly that, and a
synchronous refusal adds little against an operator who could rewrite the bar
anyway. This is an honesty rail, the same class as the arm gate, not a sandbox.

What makes the trade sound rather than convenient: **the audit is mandatory in
the release path.** `ops-backlog.sh --audit` runs before an engagement's work can
be promoted, so a mismatch cannot reach a merge unseen. An A2 whose audit is
optional would be strictly weaker than the synchronous version; an A2 whose audit
is compulsory at the boundary that matters is not.

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
| 1. **Ingest** | RECON fan-out over `backlog task list --json` + per-task `--plain`; **no agent** for the repo census (B10) | structured task records: id, deps, status, AC list; census numbers |
| 2. **Bar** | JUDGMENT, single | the derived BAR block (B3) — the one artifact the human sees before lock |
| 3. **Sequence** | **no agent** — topo-sort in JS (B4); above the census threshold the unknowns task is the synthetic root every other task blocks on (B10) | ready set, in dependency order; a cycle → R3 |
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
| `scripts/ops-verdict.sh` | G1 retro-gate; `FRAG_MAX_BYTES` to function scope; `.armed/` recompute (remove → rescan → restore) under the existing lock; the `--exempt` GATE-EXCEPTION write delegated here from `ops-task.sh`. **No `FRAG_OWNER` change** — see the §8b retraction |
| `scripts/ops-task.sh` | create `.armed/<sid>` after the sentinel; `--exempt "<reason>"` (G3) — parses and validates, delegates the ledger write |
| `scripts/ops-adopt.sh` | create `.armed/<sid>` |
| `scripts/ops-armgate-hook.sh` | **new** — PreToolUse arm gate (G2), opt-in |
| `scripts/ops-backlog.sh` | **new** — `--audit` (B9, the A2 bar-hash verify, and B11's register pass), `--census` (B10), bar derivation helper (B3), preflight (B8) |
| ~~`scripts/ops-bar.sh`~~ | **Not created** (Q3, decided). The lock write is `ops-verdict.sh --lock-bar`; the verify is `ops-backlog.sh --audit`. One less CLI in the install set, in `check_scripts`, and in the charter |
| `scripts/ops-claims.sh` | `PROTECTED` gains `backlog/` (B7) — the whole directory; worker notes route through the operator (Q4) |
| `scripts/ops-init.sh`, `ops-sessionstart-hook.sh` | install set gains `ops-backlog.sh` and `ops-armgate-hook.sh` only. **No `.gitignore` change:** the v2 allowlist ignores `*` and re-admits only evidence, so `.armed/` — and every ephemera directory added after it — is covered by construction |
| `hooks/hooks.json` | new `PreToolUse` block |
| `workflows/backlog.js` | **new** (§5) |
| `commands/backlog.md` | **new** — where the prose the charter cannot afford lives, incl. B3 bar derivation and the A3 release list |
| `scripts/validate_plugin.py` | see 6.3 |
| `tests/test-scripts.sh` | **§8c is the case list** — every row there is a case here, titled after its id (`G1.4`, `G2.9`, …) so a coupling row can cite it by name. Includes the cases 6.3's rows name: the *"arm gate"* cases and the extended *"ops-claims verifies diff-matches-claims"* cases |
| `tests/test_workflows.mjs` | the B4 sequencing rows (`B4.1`, `B4.2`) and the B10 threshold rows (`B10.2`, `B10.3`) — workflow-level, not shell |
| `CHANGELOG.md` | a `## [x.y.z]` heading in the SAME commit as each `plugin.json` version bump — the release gate fails otherwise (`CLAUDE.md` coupling row) |

### 6.2 The charter budget — measured, and the binding axis has moved

E4 measured the charter at 149/150 lines with 1 line spare, and this section used
to propose paying for 4 new lines by reclaiming prose. That is no longer the
situation, and the reason is worth recording because it changes which cap the
next editor has to respect.

The charter was wrapped at ~75–83 columns against a 100-column cap: 17–25 columns
unused on every line. Reflowing to 95 (5 columns of margin, no words added or
removed) freed **13 lines**:

| | before | after | cap |
|---|---|---|---|
| lines | 149 | **136** | 150 |
| bytes | 8194 | **8188** | 9000 |
| longest non-table line | 83 | **95** | 100 |

Verified content-identical by diffing the word stream, the citation tags, the
headings and the table rows — all four identical — with `validate_plugin.py`
green and the bash suite unchanged at 365/0 **for the reflow commit specifically**
— later work in the same branch adds cases, so a reader comparing against a
current run should expect a higher total and check the delta, not the absolute.
So the four new lines are affordable
without touching a word of existing prose, and the earlier "reclaim ~4 lines"
plan is withdrawn: it would have traded content for room that was already there.

**The binding cap is now bytes, not lines.** 8188/9000 leaves ~812 bytes ≈ 8 full
95-column lines, against 14 spare lines. Reflowing cannot buy any more room —
that lever is spent — so the next addition that does not fit is a genuine
"reclaim or justify" decision rather than a formatting one. Budget in bytes and
measure with `wc -lc`; a proposal that counts only lines is measuring the cap
that stopped binding.

The four lines themselves:

- ENGAGEMENT CONTRACT, +2: when a backlog exists the bar **derives** from its
  ACs + `definition_of_done` (B3); once locked, the operator decides and stops
  only on the release list, by reference to `/cc-operator:backlog` (A3).
- EVIDENCE GATE, +2: gate ids are `<backlog-id>#ac<N>` (B2); an AC is checked
  only after a PASS row (A5).

Raising `CHARTER_MAX_LINES` remains the wrong instinct and is not needed here:
the cap bounds always-on tokens, and F19 added the byte bounds precisely to stop
packing from defeating it. After the reflow the byte bound is doing that job
directly.

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
| the BAR-block hash input or its recorded boundary (A2) | update `ops-verdict.sh --lock-bar` (the only producer) and `ops-backlog.sh --audit` (the only consumer); a hash over a different byte range silently un-pins every locked bar. Note the asymmetry: `ops-verdict.sh` produces the hash but never *compares* it — A2.6 pins that it computes none on the write path |

**New validator obligations.** The earlier draft got this paragraph wrong in both
directions and it is worth stating correctly, because it is the kind of error
that sends an implementer to edit a file that has nothing to do with the change.
`CHARTER_REQUIRED_CLIS` (`validate_plugin.py:75`) has exactly **two** readers:

- `check_charter` (`:213`) — requires a `.operator/bin/<cli>` mention in
  OPERATOR.md for every entry. **Moves with the constant.**
- the `GATE_CLIS` comparison for `ops-compress.mjs` (`:1304`) — the I2.1
  carve-out. **Moves with the constant.**

And two checks the draft named that are **not** coupled to it:

- `check_scripts` (`:421-426`) iterates its own hardcoded tuple. Adding a CLI
  there is a **separate edit**; skip it and the new scripts ship with no `bash -n`
  and no missing-file report. `ops-armgate-hook.sh` is not a charter CLI at all,
  so nothing would ever add it — it must be added by hand.
- `check_install_set_parity` (`:696`) extracts the install set with a regex over
  the shell scripts (`:704`), whose `[^;]*` tail already matches new CLIs. It
  never reads the Python constant and needs no edit.

Also unchanged: `check_lock_parity`. G3 delegates its ledger write to
`ops-verdict.sh` rather than giving `ops-task.sh` a lock, so no new lock site
appears (G3).

Genuinely new: `check_armgate`, pinning the matcher set and asserting `Bash` is
absent from it — the one property whose silent loss would turn a rail into a
wedge. And note the charter-line consequence of the first bullet: every CLI added
to `CHARTER_REQUIRED_CLIS` costs a charter line beyond §6.2's four. That is the
argument for keeping `ops-backlog.sh` OUT of the constant — it is engagement
setup, invoked from `commands/backlog.md`, not session mechanics the operator
needs named in every session's charter. After the reflow the room exists either
way; this is a scoping decision, not a budget one. (`ops-bar.sh` is no longer a
candidate at all — Q3 dissolved it.)

Also new, and a direct consequence of Q3: a check that the bar-hash **comparison**
appears only in `ops-backlog.sh`. `--lock-bar` computes a hash in
`ops-verdict.sh`, so the naive "no `sha` in the writer" assertion is no longer
available — the property to pin is that the writer never *compares*, which is
what keeps the write path free of an unbounded read (A2, A2.6).

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
| The B10 census threshold is the right size | It is calibrated on ONE repo — this one (59 files / 22 code / ~11K LOC), which is small. Until B10's AC4 measures three repos of different sizes, the number ships as a documented guess. Both error directions have a real cost: ceremony on a small repo, a wrong build on a large one. |
| Naming unknowns first prevents the defect class it targets | Untested. The argument is an existence proof (§6.3 and the `FRAG_MAX_BYTES` claim in THIS spec were unknowns written as knowns), not evidence that a mandated discovery task would have caught them. It might have produced a register that missed the same two. |
| §8c's criteria are the right ones | They are testable, which is not the same as sufficient. Each was derived from a decision in this document, so a decision that is itself wrong gets a criterion that passes. §8c closes the "cannot be checked" gap, not the "is correct" one — G1.4 asserts a refusal the spec chose; it cannot tell you the refusal was the right call. |
| An implementer following §8c produces a working feature | Every row is a unit-level assertion. None exercises the composed path — arm → write → verdict → recompute → stop — across two concurrent sessions, which is where this repo's bugs have historically lived (F01, F03, the 0.4.0 ownership work). A green §8c is a floor. |

---

## 8b. Amendments from the review panel (2026-08-07)

This spec was reviewed by the `cc-operator:review` panel at commit `71732ff`
(605 lines). The adversarial seat returned **CONFIRMED** — it reproduced E1 in a
fresh scaffolded repo byte-for-byte, re-measured E4 against HEAD, and confirmed
the regression gates (`validate_plugin` exit 0, bash suite 365/0). Everything the
spec claimed about the *current* code held, except where noted below.

The claim-check lens died on a StructuredOutput retry cap after 43 tool calls and
was re-run separately on a second model. That re-run produced the §6.3 correction
— which is the most consequential change here, and it was found only because the
lens was re-run rather than written off. Recorded because it is evidence for
B10's argument: the defects that survive are the ones a panel finds late or not
at all.

| # | Finding | Where it landed |
|---|---|---|
| 1 | ~~`FRAG_OWNER` resolves to `""` with no owner → fragment is `verdicts.d/.md`, a dotfile invisible to the hook's glob~~ | **WITHDRAWN — the finding was wrong.** See the retraction below. |
| 2 | §6.3 claimed `CHARTER_REQUIRED_CLIS` transitively moves `check_scripts` and `check_install_set_parity`; neither reads it, and it omitted `check_charter`, which does | §6.3, rewritten with the two real readers named |
| 3 | `FRAG_MAX_BYTES` does not bound the read G1 would do — that refusal is only inside `--reconcile` | G1, second requirement |
| 4 | A never-armed verdict with no `--owner` has no sid to tag, and an untagged GATE-EXCEPTION blocks every session | G1, third requirement — refuse, narrowly scoped |
| 5 | A2 hashes an unbounded VERDICTS.md with no block grammar, on every verdict | A2, rewritten: hash at lock time, verify at audit time, mandatory in the release path |
| 6 | G3 made `ops-task.sh` a ledger writer; it deliberately takes no lock | G3, rewritten: `--exempt` delegates the write to `ops-verdict.sh` |
| 7 | G2.1's clear → rescan → remove recompute loses a race with `ops-task.sh` and produces stale-FALSE | G2.1, rewritten: remove → rescan → restore, with the interleaving shown |
| 8 | `.operator/.gitignore` needed an upgrade-path append for `.armed/` | Obsolete — the v2 allowlist ignores `*` and re-admits only evidence |
| 9 | §6.2's +4 omitted the charter lines `check_charter` would force | §6.2, rewritten around the measured reflow; §6.3 records the per-CLI cost |
| 10 | §6.1 omitted `tests/` and `CHANGELOG.md` | §6.1, two rows added |
| 11 | B2's "safe as a fragment name" argues a coupling that does not exist — fragments are named by owner, never by task id | Noted here; B2's identity mapping is unaffected, only its justification |

### Retraction — finding #1 was false (second panel, 2026-08-07)

The amended spec went back through the panel. The feasibility lens refuted
finding #1, and it is right:

```
$ bash -c 'f(){ echo "[${1:-unowned}]"; }; f ""'    → [unowned]
$ bash -c 'f(){ echo "[${1-unowned}]"; }; f ""'     → []
```

`${1:-word}` — **with** the colon — substitutes on unset *or null*. Only the
colonless form is unset-only. `append_fragment` (`ops-verdict.sh:378`) uses the
colon form, so an empty `FRAG_OWNER` lands in `unowned.md`, not `.md`. Confirmed
end-to-end in a fresh scaffold, `ops-verdict.sh` with no `--owner`:

```
$ ls -a .operator/verdicts.d/
.  ..  unowned.md
```

There is no dotfile, no invisible fragment, and no standing bug. The proposed
`FRAG_OWNER="${OWNER:-${SOWNER:-unowned}}"` is a no-op. G1's third requirement is
withdrawn; two remain.

**Q4 is unaffected** and stays. It is about the `[sid:<session>]` tag on the
GATE-EXCEPTION line in DECISIONS.md, not about the fragment filename — an
untagged gated line is still unowned, and unowned still fails closed.

Recorded rather than quietly deleted because of what it cost: finding #1 was a
must-resolve at score 82 in the first panel, was written into this spec as
established fact, and would have sent an implementer to make a no-op edit while
believing a bug was fixed. A review finding is a hypothesis until someone runs
it — the same rule this repo applies to a subagent's "COMPLETE".

Across every proposed section the panel scored testability 35–50 in the first
pass and 85–95 in the second: the sections describe behaviour without a command
and an expected output. §8c closes that.

---

## 8c. Acceptance criteria for the proposed behaviour

The panel's largest finding, twice, is that this document argues well and
specifies untestably. Every decision below gets a command and an expected
result, so an implementer can tell "built" from "believed built" — and so a
reviewer can refute a claim without re-deriving the design.

Format: each row is a command run from a project root and what it must produce.
`$S` is the session id. Rows marked **(new)** describe behaviour that does not
exist yet; rows marked **(regression)** pin behaviour that must not change.

### G1 — the retro-gate

| # | Command | Expected |
|---|---|---|
| G1.1 | open a task, then `ops-verdict.sh t1 crit ev PASS --owner $S` | exit 0; row in VERDICTS.md; **zero** new `GATE-EXCEPTION` lines in DECISIONS.md **(regression)** |
| G1.2 | with `pending/` empty: `ops-verdict.sh never-armed crit ev PASS --owner $S` | exit 0; row appended; **exactly one** `GATE-EXCEPTION` line whose what-cell contains `[sid:$S]` **(new)** |
| G1.3 | repeat G1.2's command a second time | exit 0; row appended; stderr matches `duplicate`/`amending`; **no second** `GATE-EXCEPTION` **(new)** |
| G1.4 | with `pending/` empty and **no** `--owner`: `ops-verdict.sh never-armed crit ev PASS` | **exit non-zero**; VERDICTS.md unchanged (byte-compare); stderr names `--owner` **(new)** |
| G1.5 | armed task, no `--owner`: `ops-verdict.sh t1 crit ev PASS` | exit 0 — the narrow scope of G1.4 is asserted, not assumed **(regression)** |
| G1.6 | a fragment padded past `FRAG_MAX_BYTES`, then a verdict on that session | exit 0 within the lock budget; the read is refused/truncated rather than slurped — assert by timing bound and by the refusal message **(new)** |

### G2 / G2.1 — the arm gate and the armed marker

| # | Command | Expected |
|---|---|---|
| G2.1 | armgate hook with a `Write` payload, `armgate.on` absent | exit 0, no stderr — opt-in default **(new)** |
| G2.2 | `armgate.on` present, no `.armed/$S`, `Write` payload | **exit 2**; stderr names both `ops-task.sh … --owner $S` and the `--exempt` path **(new)** |
| G2.3 | same, with `.armed/$S` present | exit 0 **(new)** |
| G2.4 | same, with only `.armed/$S.exempt` present | exit 0 — the exempt marker arms independently **(new)** |
| G2.5 | `armgate.on` present, payload cwd has no `.operator/` above it | exit 0 — fails open on missing state **(new)** |
| G2.6 | `armgate.on` present, no JSON parser on PATH | exit 0, silent — fails open on infrastructure **(new)** |
| G2.7 | `grep -c '"Bash"' hooks/hooks.json` in the PreToolUse matcher | 0 — `Bash` is never gated; asserted by `check_armgate`, not by reading **(new)** |
| G2.8 | open task for `$S`, verdict it, then `ls .operator/.armed/` | `$S` absent — the recompute removed it **(new)** |
| G2.9 | two tasks open for `$S`, verdict one, then `ls .operator/.armed/` | `$S` **present** — remove-then-rescan-then-restore put it back **(new)** |
| G2.10 | `.armed/$S` deleted by hand, then a verdict on an open task of `$S` | `$S` present again — the recompute is self-healing **(new)** |

### G3 — the exemption

| # | Command | Expected |
|---|---|---|
| G3.1 | `ops-task.sh --exempt "reason" --owner $S` | exit 0; one `GATE-EXCEPTION` line tagged `[sid:$S]` containing `reason`; `.armed/$S.exempt` exists **(new)** |
| G3.2 | `ops-task.sh --exempt` with no reason | exit non-zero; DECISIONS.md unchanged **(new)** |
| G3.3 | after G3.1, run the Stop hook for `$S` | **exit 2** — the exemption owes a presentation **(new)** |
| G3.4 | after G3.1 and a `--mark-handoff`, run the Stop hook | exit 0 **(new)** |
| G3.5 | after G3.1, verdict an unrelated open task of `$S`, then `ls .operator/.armed/` | `$S.exempt` still present — the recompute never touches a granted marker **(new)** |
| G3.6 | `grep -c 'lock_acquire' scripts/ops-task.sh` | 0 — the opener stays lock-free; the write is delegated **(new)** |

### A1 / A2 — the bar lock and its hash

| # | Command | Expected |
|---|---|---|
| A1.1 | `ops-verdict.sh --lock-bar eng-1 --owner $S` | exit 0; one `BAR-LOCK` line carrying a hash, the block boundary, the blast-radius globs, the budget and the caps **(new)** |
| A1.2 | the same command again | exit non-zero — a bar locks once **(new)** |
| A1.3 | `--lock-bar` with no `--owner` | exit non-zero — an unowned BAR-LOCK is the same unowned-blocks-all hazard as G1.4 **(new)** |
| A2.1 | `ops-backlog.sh --audit` on an untouched bar | exit 0; no drift reported **(new)** |
| A2.2 | edit one byte inside the bar block, then `--audit` | exit non-zero naming the drift; one `GATE-EXCEPTION` written **(new)** |
| A2.3 | append 100 rows to VERDICTS.md *outside* the block, then `--audit` | exit 0 — the recorded boundary means growth is not drift **(new)** |
| A2.4 | after A2.2, `ops-verdict.sh <id> crit ev PASS --owner $S` | **exit 0** — the hash is not compared at verdict time; the drift is the audit's to find **(new)** |
| A2.5 | the release path with a drifted bar | exit non-zero — the audit is what refuses, and it runs there by construction **(new)** |
| A2.6 | the hash is computed on the `--lock-bar` path and **compared** nowhere in `ops-verdict.sh` | asserted by a check that the comparison lives only in `ops-backlog.sh`. A bare `grep -c sha` would now fail on `--lock-bar`'s own computation, so the assertion is about the *comparison*, not the string **(new)** |

### B — the backlog integration

| # | Command | Expected |
|---|---|---|
| B2.1 | open a task id `task-42#ac3` | exit 0 — the `#` form passes `check_bare_name` in all three CLIs **(new)** |
| B4.1 | phase-3 on a backlog with `a→b→c` | ready order `a, b, c`, produced with no agent call in the phase **(new)** |
| B4.2 | phase-3 on a backlog with a dependency cycle | the workflow returns an R3 escalation, not an ordering **(new)** |
| B7.1 | worker diff touching `backlog/tasks/x.md`, then `ops-claims.sh --claimed "backlog/tasks/x.md"` | exit non-zero naming `gate-trespass` **(new)** |
| B7.2 | `python3 scripts/validate_plugin.py` after adding `backlog/` to `PROTECTED` in only one of the two pinned sites | exit non-zero — `check_claims` pins the literal AND its application (F30) **(new)** |
| B8.1 | preflight against a `backlog.config.yml` with `autoCommit: true` | exit non-zero; no bar locked **(new)** |
| B9.1 | AC checked with no PASS row, then `ops-backlog.sh --audit` | exit non-zero; output names `phantom done: <id>#ac<N>` **(new)** |
| B9.2 | PASS row with the AC unchecked | reported as `lag`, exit 0 — benign **(new)** |
| B9.3 | AC checked with a FAIL row | exit non-zero; output names `contradiction` **(new)** |
| B10.1 | `ops-backlog.sh --census` on a repo of ≥10K files | exit 0 in under 1s; prints file count, code-file count, code LOC **(new)** |
| B10.2 | phase-3 above the threshold | the unknowns task is first; every root task lists it in `blockedBy` **(new)** |
| B10.3 | phase-3 below the threshold | no unknowns task inserted **(new)** |
| B11.1 | `--audit --register <file>` on a register with a resolved-but-unmoved entry | exit non-zero naming that entry **(new)** |
| B11.2 | same, on a register listing an unknown that has a PASS row | exit non-zero — known, still listed as unknown **(new)** |
| B11.3 | same, where the entry's row is a **FAIL** | reported still-open, not resolved **(new)** |
| B11.4 | hash the register before and after any `--audit --register` run | identical — the audit never writes **(new)** |

Two of these are worth stating as design assertions rather than tests, because
they pin an absence: **G3.6** and **A2.6** both assert that a file does *not*
gain something (a lock, a hash computation). An absence is what silently
reappears under a later edit, which is why each has a grep with an expected count
rather than a prose promise.

---

## 9. Resolved — the five open questions (2026-08-07)

All five were put to the human and decided. Recorded with the reasoning, because
four of them turned on a fact that was not in the original framing.

**Q1 — G2 ships opt-in. CONFIRMED as specified.**
The counter-argument (an opt-in gate does not close E1) is true but not
decisive, because **default-on does not close it either**: `Bash` is ungated by
design, so `bash -c 'cat > f'` walks past the gate at any setting. Both options
deliver *closable*, and only one of them can wedge a session. Precedent is
directly on point — issue #9 was a gate stage shipped default-on that
phantom-blocked every ledger with a long row and whose clearing path was
unreachable. The asymmetry the original framing missed: **G1 is default-on and
covers the same ground retroactively.** A session that bypasses the arm gate
still earns a `GATE-EXCEPTION` at verdict time. Opt-in G2 is a second layer over
a layer that already runs, not a hole. Revisit in 0.8.0 on field evidence.

**Q2 — per-AC sentinels. CONFIRMED as recommended.**
The stated cost was "N open sentinels and an N-row statusline". The second half
is wrong: the statusline renders a **count**, not rows (`op[2]`, `op[1+2*]` —
`statusline.sh:4-6`). A five-criterion task reads `op[5]`, one character wider,
not five lines. What per-AC buys is the thing that matters: each criterion gets
its own evidence row. Per-task + `--keep-open` closes five criteria with one
row, which pushes "which criterion is proven" back into prose in the evidence
cell — the duplication B1 exists to forbid. One consequence to carry into the
implementation: `op[12]` no longer means "12 tasks", and `statusline.sh`'s
header comment should say so when B2 lands.

**Q3 — neither. `ops-bar.sh` is not created.** *(the one that changed)*
The question assumed the lock and the verify travel together. Once A2 moved the
hash off the write path they stopped being one thing:

- the **lock write** is a DECISIONS.md append → belongs to the single writer,
  under the lock it already holds. Same reasoning that decided G3.
- the **verify** is a read → needs no lock, and must not live in the writer,
  which A2.6 pins.

So: `ops-verdict.sh --lock-bar` and `ops-backlog.sh --audit`. A CLI holding one
flag on each side of that split is a CLI whose halves belong in two places. This
removes an install-set entry, a `check_scripts` entry, and a charter line.

The cost, stated: `ops-verdict.sh` is 613 lines and the most dangerous file in
the repo, and this is its fourth flag (`--defer`, `--reconcile`,
`--mark-handoff`, `--lock-bar`). That is the price, and it is deliberate — the
alternative price is a fourth lock site.

**Q4 — `backlog/` stays wholly in `PROTECTED`.**
The proposed escape (a field-level rule: notes writable, criteria not) needs a
parser for the neighbour project's frontmatter grammar, which is exactly what B5
forbids — that grammar is theirs to change, and a hand-rolled parser here is a
silent-breakage surface with no owner. The third way the framing missed: **the
implementer does not need write access to record notes.** It reports them in its
REPORT; the operator writes them with `backlog task edit --notes`. That is the
pattern A5 already sets for checking ACs (only after a PASS row) and the one G3
just took for the ledger write. No parser, no field-level rule, no exception to
B7.

**Q5 — per-task, with a filter.**
Per-engagement was the tempting answer to "a heavy DoD × N tasks makes the bar
unreadable", but it converts the DoD from a done-condition into an end-of-run
check that can fail everything without naming which task failed. B3's own rule
resolves it: every criterion must be **command + expected output**, and an item
that cannot be expressed that way is not yet a criterion. A DoD item that is
per-task testable ("the suite passes") belongs in every task's bar; one that is
not ("documentation updated") becomes a single engagement-wide AC instead of N
unfalsifiable copies. B3 already has the lens that sorts them (`testable: no`) —
it must be aimed at DoD items too, not only at ACs.

---

## 10. Backlog — carried items

Items to schedule once `backlog/` exists (B1–B9). Until the CLI is wired this
section IS the backlog; each entry must be portable to a `backlog task` with its
acceptance criteria intact.

> **Quiet-introduction policy (decided 2026-08-07, refined).** The
> CLI-dependent B-items and B11's register-audit are **deliberately unbuilt.**
> The reason is the issue-#9 lesson one level up: do not build a loud detection
> for a problem the field has not yet demonstrated. The process itself surfaces
> the hard blockers — "speech is silver, silence is golden." Three decisions,
> adjusted after review:
> - **B11 classification (U1) = the backlog-native p1–p5 priority/status
>   indicator.** No invented `[OPEN]`/`[CLOSED]` tag; the status already lives
>   in the priority field. B11 reads that, should it ever be built.
> - **No `backlog.md` dependency (U2, decided).** The functionality is covered
>   in-house, without third-party bloat. **This dissolves B5's premise:** B5
>   said "read through the CLI, never parse the neighbour's grammar yourself"
>   because that grammar was someone else's. Without an external tool *we* are
>   the owner, and that reason (and B7's "the grammar is foreign" rationale)
>   falls away. B5/B7 must be re-read against this before the B-items are built
>   — they are not blockers, but their *"why"* is rewritten.
> - **B10 threshold = end-user-triggered (U3).** "Release posture" is intent,
>   not a code-measurable fact — so the unknowns scan is turned on by the **user
>   declaring** "this is release-bound" at task-open, not inferred from size or
>   file structure. Exploration / MVP / test / wip → exempt (default);
>   release-bound → the scan is a *must*. This is the same model as G2 (opt-in
>   `armgate.on`) and G3 (the user requests the exemption): the trigger is
>   human, the mechanism enforces. Size (B10.1 census) degrades to an
>   informational signal — a proxy that is sometimes right and sometimes not,
>   not a trigger.
> A later reader sees "deliberately quiet, and the preconditions rewritten,"
> not "forgotten."

### BL-1 — cache-aware dispatch: keep cheap-tier seats hitting a warm prefix

**Investigate**, not yet a design. The orchestration layer fans narrow lenses
across cheap tiers (`ops-tiers.sh`: `MECHANICAL=glm-5-turbo`, `RECON=glm-4.5-air`)
and converges on judgment. Every one of those dispatches pays full input price on
a cold prefix, and re-pays it on the next dispatch that shares the same context
but arrives after the provider's cache window has lapsed. The question is whether
dispatch ORDER and PACKET SHAPE can be arranged so a fan-out reuses one warm
prefix instead of paying N cold ones.

What makes this non-obvious, and why it is an investigation rather than a task:

- **The cache is the provider's, not ours.** TTL, the prefix-match rule, and
  whether a cache entry is even per-seat differ per vendor, and this repo routes
  cheap tiers to non-Anthropic ids through cc-proxy. A design that assumes
  Anthropic's semantics would be wrong for exactly the tiers it targets.
- **Prefix stability is a packet property.** The dispatch packet (charter,
  `TASK / TEXT / SCENE / INPUTS / …`) puts per-dispatch text early. If the shared
  material (charter, repo map, shard corpus) is not byte-identical and FIRST,
  there is no prefix to hit — this is the axis a design would have to move, and
  it collides with the packet's fixed field order.
- **It interacts with the compressor.** `ops-compress.mjs` rewrites tool output
  to shrink re-billed input. That is the same cost axis from the other end, and
  its spill/dedup state is session-scoped — a cache design that assumes stable
  earlier turns must account for the compressor having altered them.

Acceptance criteria (each needs a command + expected output before this leaves
the backlog):

1. A measurement of what a fan-out actually costs today: cached vs uncached input
   tokens per seat across one real `review` run, read from the run's own usage
   record — not estimated.
2. A written statement, per routed tier, of that provider's cache TTL and
   prefix-match rule, each with its source.
3. A yes/no on whether packet field order can carry a stable shared prefix
   without breaking `[D:CHART-packet]`; if no, the finding is that the charter
   constrains this and the item closes as won't-do with that reason recorded.
4. If a design follows: a measured before/after on the same fan-out, same
   artifact, with the token delta as evidence.

Explicitly out of scope for the investigation: raising cheap-tier work to a
judgment tier to reuse its cache. Model routing is charter-fixed — correctness of
the product beats token savings, and judgment work never runs below judgment tier
[D:CHART-route]. A cache design that quietly re-routes work is a routing change
wearing a cost argument.

### BL-2 — FDE coverage: map the forward-deployed-engineer skill surface to the charter

**Investigate**, not yet a design. The operator charter is, in industry terms, a
_forward-deployed engineer_ (FDE) framework: it is deployed into a live project,
bridges tool-to-outcome for a specific engagement rather than building a product
in the abstract, and trades tight oversight for high autonomy — "oversight
batched to the handoff" is the spec's own thesis (§0). The question this item
asks is not whether to *become* an FDE framework but where the charter's current
capabilities leave a gap against the FDE skill surface the role is now named for,
and whether closing any gap is worth a feature.

The FDE role, as it is described across current sources (the Palantir-origin
model the AI labs — Anthropic, OpenAI, Cohere — are now cloning; DataCamp,
Glocomms, Invisible Tech, Salesforce; the GeeksforGeeks roadmap the human
pointed at was unreachable at search time, but the role definition converges),
bundles competencies with a known time split — roughly ~40% full-stack build,
~30% enterprise-architecture design, ~30% client-facing discovery/iteration
(fde.academy). The economic thesis behind the AI-lab adoption is load-bearing
for this item: as the *model* commoditizes, deployment + customization becomes
the differentiator (MindStudio, The New Stack). A charter whose value is the
deployment discipline — not the model — is exactly on that axis, which is why
the question is worth asking. Five competencies:

1. **Deployment & integration** — operationalizing a system inside a *customer's
   live environment*, not a clean lab. This maps directly to the charter's "run
   in the user's project, not the plugin repo" stance (the `.operator/bin/`
   install path, the SessionStart id injection). ~40% build share.
2. **Systems glue / enterprise architecture** — APIs, cloud infra, deployment
   pipelines, model-eval / DevOps layers. The charter has the dispatch + review
   + tier machinery but nothing in the gate vocabulary names deployment
   pipelines, evals, or infra state as first-class BAR criteria. ~30% share.
3. **Customer communication & product judgment** — the bridge between a product
   and its client, often the person who "can make or break a launch." This is
   the handoff, and the charter's six-section operator→human handoff is already a
   disciplined version of it. ~30% share.
4. **Operational tuning after deploy** — ongoing evals, pipeline tuning, model
   iteration. The charter's evidence gate stops at a verified done-state; it has
   no notion of a *living* engagement that drifts and needs re-tuning.
5. **Alignment / safety posture** — the Anthropic FDE interview screens for a
   formed opinion on responsible scaling, Constitutional AI, and the
   pre-train/fine-tune/inference distinctions; the role treats safety as a
   competency, not a checkbox. The charter has PRECEDENCE (it wins on conflict
   and logs them) and a `security-review` skill, but no first-class
   "alignment/safety" BAR criterion — the gap the generic sources miss and the
   interview-guide source surfaces.

What makes this non-obvious, and why it is an investigation rather than a task:

- **Most of the surface is already covered by analogy, not by name.** Claiming an
  FDE "gap" risks adding vocabulary the charter already expresses better under
  its own names (the handoff IS the customer-communication competency). The first
  job is to state which FDE competencies are *already* covered and by what
  charter mechanism, so the residual is honest rather than a re-skinning.
- **The genuine residual looks narrow.** The three that do not map cleanly are
  (a) deployment-pipeline / infra-state as first-class gated criteria, (b)
  ongoing tuning of a deployed engagement, and (c) an alignment/safety
  criterion in the BAR (competency 5). (a) and (b) may be better served by the
  backlog-as-charter work (B) than by an FDE feature — the backlog is already the
  "living plan" surface, and a `definition_of_done` item that names a pipeline or
  an eval gate is already expressible (B3). (c) is the open one: is a safety
  criterion a job for the charter's gate, or for the `security-review` skill it
  already invokes? The competency map (AC1) has to answer that honestly, because
  the tempting answer — add a `safety:` BAR field — risks duplicating the
  security-review surface the charter already has, the same state-duplication B1
  forbids.
- **The charter's autonomy bargain is the FDE's too.** An FDE is trusted with
  judgment once the goal is locked; the charter buys that with the arm + verdict
  + deviation gates (G1/G2/G3). The risk in adding "FDE coverage" as a feature is
  duplicating the gate under a new name — the same state-duplication failure B1
  forbids.

Acceptance criteria (each needs a command + expected output before this leaves
the backlog):

1. A written competency map: each of the five FDE competencies above, marked
   `{covered, partial, gap}`, each `covered`/`partial` citing the charter
   mechanism (section + the `[D:…]` or `[DOC:spec-…]` tag) that already provides
   it. The map's purpose is to make the residual falsifiable, not aspirational.
2. For every `gap`, a one-line statement of whether the backlog-as-charter work
   (B3 `definition_of_done`, B9 audit) already closes it — and if so, point at
   the AC. If the gap is not closed by B, it stays on this backlog with a
   candidate command + expected output.
3. A measured statement of the charter's current stopping point on a "living"
   engagement: can the gate express "re-tune after deploy" today, or does a
   re-tuning engagement have to start a fresh BAR? Answer with the mechanism or
   its absence, not an opinion.
4. If a feature follows (not assumed): a candidate mechanism that does NOT
   duplicate the handoff or the evidence gate under a new name — and the AC that
   would discriminate it from "B with a different label."
5. For the alignment/safety competency (5) specifically: a decision on whether a
   safety criterion belongs in the charter's BAR gate, in the `security-review`
   skill, or is already covered by PRECEDENCE. The discriminating question:
   "what does a `safety:` BAR criterion gate that PRECEDENCE + security-review do
   not?" If the answer is "nothing," the item closes as covered-by-existing with
   that recorded, not as a feature.

Explicitly out of scope: renaming the charter's vocabulary to match FDE
industry terms. The charter's names (engagement, verdict, BAR, deviation) are
load-bearing inside the gate; aliasing them to "FDE deployment artifact" etc. is
a documentation cost with no functional return, and it severs the coupling rows
in CLAUDE.md from the code they describe.
