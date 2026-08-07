# UNKNOWNS — the open register (0.7.0)

What this repo does **not** know, stated so a later reader can act on it without
re-deriving it. Every entry carries the same four fields, and the rule for all of
them is the charter's: *a row without evidence is FAIL by definition*
[D:CHART-def]. "We considered it" closes nothing; a command and its output does.

Companion registers: `docs/spec/backlog-charter.md` §8 ("What this does NOT
prove") is the per-claim residual for that spec; `docs/LANDMINES.md` is the
already-hit failure classes. This file is the **forward-looking** one — things
still unresolved as of 0.7.0.

Status vocabulary: **OPEN** (no answer yet) · **MEASURED** (answered by a number,
which may be uncomfortable) · **DECIDED** (a choice was made and recorded;
listed here because the choice has consequences a reader must know).

---

## U1 — the arm gate has never executed in a real session *(OPEN, blocking a merge claim)*

**What is unknown.** Whether the harness actually denies a `Write`/`Edit` when
`ops-armgate-hook.sh` exits 2. Every G2 case asserts the hook's own exit code;
none asserts the harness's interpretation of it.

**Why it is not already answered.** The plugin loads from GitHub, cached — the
live wiring for this machine is `cc-operator/0.6.1`, whose `hooks.json` declares
exactly `SessionStart`, `Stop`, `PostToolUse`. There is **no `PreToolUse` entry
in any cached version**, so no session on this machine has ever run the arm gate.
The dev tree is not the loaded plugin, and hooks are read at session start, so
editing the tree mid-session changes nothing.

Verify the claim:

```
python3 -c "import json;print(list(json.load(open(
  '$HOME/.claude/plugins/cache/betmoar/cc-operator/0.6.1/hooks/hooks.json'))['hooks'].keys()))"
# → ['SessionStart', 'Stop', 'PostToolUse']
```

**What would close it.** A session started against a plugin root that carries the
`PreToolUse` block, in a project with `.operator/armgate.on` present and no open
task, attempting an `Edit`. Two things must be observed, not one: that the edit
is **refused**, and that the refusal message reaching the model is the hook's
stderr. A denial that surfaces as a generic error teaches the operator nothing.

**Until then.** The PR body and CHANGELOG say the gate is tested at the hook's
exit code only. Do not upgrade that wording to "the gate blocks" on the strength
of the suite — the suite cannot see the harness.

---

## U2 — the crash window between a verdict row and its GATE-EXCEPTION *(OPEN, deliberate)*

**What is unknown.** Nothing, in fact — this one is *understood* and unfixed,
which is why it is here rather than in a bug tracker.

`ops-verdict.sh` writes the fragment row, the VERDICTS row, then the
`GATE-EXCEPTION`. Those are separate appends. A crash between them leaves a row
whose audit line never landed, and the retry classifies it `duplicate` — so a
genuine gate bypass keeps its PASS row and loses its exception. That is the exact
failure G1 exists to prevent, reached through a crash window instead of a
swallowed error.

**Why the obvious guard is not there.** It was built and reverted. Downgrading to
`duplicate` only when a `GATE-EXCEPTION` exists sounds right, but an **armed**
first verdict also leaves a row with no exception, so the guard reclassified every
ordinary armed-then-amended verdict as never-armed and wrote a spurious exception.
Case G1.7 caught it. "Prior row without exception" genuinely cannot distinguish
crash-interrupted from ordinary-amended; nothing in the fragment carries that bit.

**What would close it.** Making the pair atomic — writing the exception *before*
the row, or journaling both under one lock+fsync. That changes the single writer's
ordering contract, which is the most dangerous file in the repo, so it earns its
own slice and its own bar rather than a patch appended to this one.

**Recorded in code** at `scripts/ops-verdict.sh` (search `RESIDUAL`), so the next
reader of `retro_gate` meets it there and not only here.

---

## U3 — `--census` is over its own stated bound *(MEASURED, uncomfortable)*

**What is known, and it is worse than previously written down.** B10 AC1 says
`--census` exits 0 "in under 1s" on a repo of ≥10K files. Measured on a synthetic
12K-file repo:

```
cd <12k-file repo> && /usr/bin/time -p ops-backlog.sh --census
# real 1.62      ← over the 1s bound
```

Earlier notes in this engagement quoted ~1.06s. That figure is stale; the honest
number is above. The bound has never been met since the correctness fix that made
an unreadable file report `PARTIAL` instead of silently undercounting.

**The trade that produced it.** Detecting a partial read requires capturing
`cat`'s stderr, because BSD `xargs` does **not** propagate a child's failure
through its exit status (measured — an exit-status check would have been a guard
that never fires). That capture costs a temp file and a pass. Correctness was
chosen over the bound deliberately; the bound was authored before the guarantee
existed.

**What would close it.** Either a faster partial-read signal that does not cost a
pass, or an amended AC that states the real budget with the reason. Do not quietly
relax the number — the point of a bound is that it is falsifiable.

---

## U4 — the p1–p5 status field has no definition *(OPEN, first design step)*

**What is unknown.** U1-of-the-backlog decided B11 reads "the backlog-native
p1–p5 priority/status indicator". U2 then decided there is **no `backlog.md`
dependency** — the functionality is covered in-house. Together those mean *we* now
own a task-status grammar that has never been specified: which states exist, what
transitions are legal, and where the field lives (an own `backlog/` tree with our
grammar, or a field under `.operator/`).

**Why it matters more than it looks.** It is new schema surface in a repo whose
documented failure class is duplicated state (B1: "the moment task state exists in
two places, one of them is wrong and nothing says which").

**What would close it.** A written grammar with the states enumerated and one
worked example, before any B-item that reads it is built.

---

## U5 — B5 and B7's rationale has been dissolved *(DECIDED, consequence outstanding)*

**What changed.** B5 said *never parse the neighbour's grammar yourself*, and B7's
whole-directory `PROTECTED` rule leaned on the same "that grammar is someone
else's" reasoning. With the no-third-party decision, we are the owner — so the
stated reason for both is gone.

**What is NOT gone.** The interests they protect: a worker must not be able to
edit the criteria it is judged against (B7), and the grammar must not rot silently
(B5). Those still hold; only the *why* needs rewriting.

**What would close it.** Re-read B5/B7 against in-house ownership and restate
their rationale before the B-items are built. Neither is a blocker; both are
load-bearing prose that currently argues from a premise that no longer applies.

---

## U6 — the B10 trigger is a declaration, not a measurement *(DECIDED, by design)*

The unknowns scan fires when the **user declares** the project release-bound at
task-open — not inferred from repo size or file structure. Same shape as G2's
opt-in switch and G3's requested exemption: the trigger is human, the mechanism
enforces.

Consequence a reader must know: the census (U3) is therefore an **informational**
signal, not a gate input. Its threshold was never calibrated (one measured repo),
and under this decision it does not need to be — but any future text that treats
the census number as a trigger is describing a design that was rejected.

---

## How to close an entry

1. Run the command in **What would close it** and capture its output.
2. Record a verdict row citing that output
   (`.operator/bin/ops-verdict.sh <id> <criterion> <evidence> PASS|FAIL --owner <sid>`).
3. Move the entry to a `## Closed` section here with the row id — do **not**
   delete it. An unknown that turns out to be a non-issue is itself evidence, and
   the next reader needs to know the question was asked.

The audit that detects a resolved-but-unmoved entry (B11) is not built; the
quiet-introduction policy says build it when a real register drifts, not before.
Until then this step is done by hand, and that is the honest state.
