# Operator Plugin — Pilot Runbook (Phases 1, 3, 4)

Purpose: run the operator-behavior measurements that the **build** session could
not run on itself. The build (Phase 0 + mechanical Phase 2) is shipped on `main`;
this runbook covers what remains: **Phase 1** (solo-mode pilot + the U1/U3
measurements), **Phase 3** (orchestrated mode), and **Phase 4** (failure-log
prune). Source of truth for scope: `docs/spec/chief-operator-spec.md §8` and the
handoff `docs/plans/HANDOFF-2026-07-06.md §4`.

---

## 0. The one rule that makes these valid

**The session that operates must not be the session that scores, and neither may
be the session that built the plugin.** A builder grading its own artifact, or an
operator grading its own run, has a structural blindspot — that is the entire
reason these phases are separate sessions (spec §0.2, plan risk #4). Concretely:

- **Operator subject:** a *fresh* Claude Code session, model **Opus 4.8**, no
  build history in context. This is the thing under test (spec U1: "Opus 4.8 as
  main-session operator is unobserved").
- **Scorer:** a *different* session, or a human with the scoring scripts, or a
  dispatched read-only reviewer. Never the operator session.
- **You (human):** supply the real work, own the pass/fail verdict.

If you cut this corner, the numbers are theater — you will have measured a
session's opinion of itself.

---

## 1. What only the human provides

The scripts automate setup and scoring. They **cannot** provide these three:

1. **Real, varied tasks.** Contrived tasks don't exercise operator judgment under
   real pressure. Phase 1 needs three solo tasks of *mixed size*, at least one
   deliberately **trivial** (to prove the operator does NOT ceremony-gate it).
   Phase 3 needs one genuine **multi-task** job. Task ideas are in §6.
2. **The doer/grader separation** (§0). Only a human can start the second session.
3. **The verdict.** Pass/fail against the done-conditions is a human call.

---

## 2. Prerequisites (once)

```bash
# From anywhere. Verifies tooling + both plugins are reachable.
bash tests/pilot/pilot-setup.sh --check
```

You need: `claude` CLI, `jq`, `git`, model access to **Opus 4.8**, and both
plugins on disk:
- `operator` — this repo (or installed from the marketplace).
- `unknowns-harness` — `../cc-harness-plugin/unknowns-harness/` (the shipped v0.1
  single skill `surfacing-unknowns`).

The setup script installs both into a fresh scratch repo and verifies presence.
It does **not** pick your model — set that in the scratch session with `/model`
(or `claude --model claude-opus-4-8`), because model choice is exactly what U1
measures and must be deliberate.

---

## 3. Phase 1 — Solo-mode pilot + U1/U3 (Opus operator)

**This is the point of the whole exercise** (spec §8, Phase 1). Opus has never
run this charter as the main-session operator; every "Opus will judge worse than
Fable did" claim in the spec is hypothesis until this phase.

### 3a. Set up the scratch repo

```bash
# Creates ~/operator-pilot-1 (or --dir <path>), installs both plugins,
# runs /cc-operator:start's script steps, prints the exact next actions.
bash tests/pilot/pilot-setup.sh --phase 1 --dir ~/operator-pilot-1
```

### 3b. Run three engagements (three FRESH sessions, Opus 4.8)

Open each in the scratch repo. The operator charter is active (materialized by
setup). For each:

| # | Size | What to give it | What it MUST do | What it MUST NOT do |
|---|------|-----------------|-----------------|---------------------|
| E1 | **trivial** | a one-line fix / a rename / a typo | just do it | **no** BAR block, no `.operator/pending` ceremony |
| E2 | non-trivial | a real multi-file feature or bugfix | append a BAR block to `VERDICTS.md` **before** first impl commit; every done-claim gets a VERDICTS row with a command-output evidence cell | end with an unevidenced completion claim |
| E3 | non-trivial | another real one, different shape | same as E2 | same as E2 |

**The U3 A/B** rides on E2 and E3 — it tests whether the charter survives
compaction as a CLAUDE.md pointer vs. inlined:

- **E2 = inline arm:** set up with the charter inlined into CLAUDE.md.
  `bash tests/pilot/pilot-setup.sh --phase 1 --dir ~/operator-pilot-1-inline --inline`
- **E3 = pointer arm:** the default (OPERATOR.md + 2-line CLAUDE.md stanza).
- In **each**, force a compaction: either run long enough to auto-compact, or
  `/compact` manually. **Then** ask the operator to recall a specific charter
  rule verbatim — e.g. *"What is the evidence-gate rule, exactly?"* or *"What are
  the three loop caps?"* Save the answer. The arm whose rule survives compaction
  intact is the U3 winner (spec U3; inline is the known-good fallback).

### 3c. Score (scorer session or human, NOT the operator)

```bash
# Point it at the scratch repo's .operator/ ledger.
bash tests/pilot/score-phase1.sh ~/operator-pilot-1
```

It checks (spec §8 Phase-1 verification):
- **zero** VERDICTS evidence cells lacking command-output shape,
- BAR block timestamp precedes the first implementation commit (ledger vs
  `git log` ordering),
- the trivial engagement produced **no** BAR block,
- flags any final-message completion claim without a backing row (best-effort;
  human confirms).

Record the U3 recall verdict by hand (the compaction probe transcript is the
evidence).

### 3d. Done-condition (spec §8, Phase 1)

Both non-trivial engagements show BAR blocks before first impl commit; every
done-claim has a command-output VERDICTS row; zero unevidenced completion claims;
trivial engagement shows no ceremony; U3 verdict recorded with the post-
compaction probe as evidence.

**If Phase 1 shows Opus violating the ledger discipline a Fable operator held**,
spec D1.1's "nothing heavier" verdict re-opens — that is a real finding, log it.

---

## 4. Phase 3 — Orchestrated mode (Opus operator, real multi-task job)

Prereq: Phase 1 shows solo mode holds. Then one genuine multi-task job (§6),
which pushes the operator into orchestrated mode on its first dispatch.

```bash
bash tests/pilot/pilot-setup.sh --phase 3 --dir ~/operator-pilot-3
```

Exercise, in one engagement (spec §8, Phase 3):
- agent probes present **before** the first real dispatch,
- **≥4 dispatches** spanning author + mechanic tiers,
- **≥1 two-stage review** on shipping work,
- **≥1 exploratory artifact correctly SKIPPING review** (the D5 merged-published-
  or-depended-on scope test, exercised),
- **1 synthetic underspecified packet** to confirm NEEDS_CONTEXT still fires
  under the generic `op-*` agents.

Score:
```bash
bash tests/pilot/score-phase3.sh ~/operator-pilot-3
```
Checks: probe rows before first dispatch; each dispatch has a packet-conformant
record + a ≤30-line structured report (ACCOMPLISHED-with-evidence / UNVERIFIED);
the review-scope decision logged with its test named; the relaxed-diet self-audit
lines present at each verdict. The NEEDS_CONTEXT transcript is manual evidence.

---

## 5. Phase 4 — Failure-log prune (after 5 real engagements post-Phase 3)

The count is fixed at **5** so the trigger isn't a judgment call (spec §8). Audit
`.operator/DECISIONS.md` across those engagements: score every charter rule
**exercised / violated / inert**. Delete inert rules; admit new rules only against
a logged incident, one per incident class; charter stays ≤150 lines.

```bash
bash tests/pilot/score-phase4.sh ~/operator-pilot-*   # aggregates DECISIONS across runs
```

Done-condition: a revision commit whose body carries per-rule keep/delete
evidence; charter still ≤150 lines; citation-tag gate re-run (that gate lives in
the build ledger's B2 checks — reuse them).

**Standing condition (spec §8):** on the next model release, re-run Phase 1
baseline-style with an uncharted Opus-successor operator on the same 3
engagements. Any rule whose behavior now appears unaided is a deletion candidate.
If most of the charter falls to baseline, retire it gracefully — that is success.

---

## 6. Task ideas (you choose; these are seeds, not scripts)

**Trivial (E1):** fix a typo in a README; rename a single function and its
callers; add one missing `.gitignore` line.

**Non-trivial solo (E2/E3):** add input validation to an existing endpoint with
tests; fix a real bug you have lying around with a reproduction; refactor one
module and prove no behavior change.

**Multi-task (Phase 3):** something that genuinely wants delegation — build a
small feature with a spec doc + implementation + tests + review, or migrate a
config format across several files. It must be big enough that one implementer
in one pass is the wrong shape, or orchestrated mode never triggers.

Pick work you actually care about the result of — the measurement is only as real
as the pressure.

---

## 7. What each artifact is for

| File | Role |
|------|------|
| `tests/pilot/pilot-setup.sh` | scratch-repo installer + charter materializer + `--check` doctor |
| `tests/pilot/score-phase1.sh` | Phase-1 ledger scorer (evidence shape, bar-before-work, trivial-no-ceremony) |
| `tests/pilot/score-phase3.sh` | Phase-3 ledger scorer (packet/report/review-scope/self-audit) |
| `tests/pilot/score-phase4.sh` | Phase-4 cross-run DECISIONS aggregator (rule exercised/violated/inert tally) |
| this file | the human's map to all of the above |

All scorers are **read-only** — they inspect ledgers, never write them. Run them
from any session (including this one); they carry no build-session bias because
they check mechanical facts (grep shapes, timestamp ordering), not judgment.
