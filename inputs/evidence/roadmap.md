# unknowns-harness — Verdict + Roadmap (v0.2 capstone, 2026-07-06)

Source of record: `evals/results/DECISIONS.md`, `evals/SCORECARD.md`,
`evals/results/GATES.md`, `docs/superpowers/plans/v0.2-work-order.md`. Every
claim below traces to a ledger entry, scorecard row, or scenario ID. All
decisions are made; this is the standing instruction set for the next session.

## 1. Final verdict — v0.2 NOT SHIPPED

**v0.1 (main, 0e25606) remains current.** v0.2 lives on `chore/v0.2-work-order`,
un-merged.

Ship bar (v0.2-work-order.md:109-110): routes ≥7/8 held, trace 8/8, S6 3-run
stability, S14 table demonstrated, negatives silent.

Achieved (re-run 2, SCORECARD.md:37-57; DECISIONS.md 41-42):

| Bar element | Result | Verdict |
|---|---|---|
| Routes ≥7/8 | 7/8 (S6 miss closed) | PASS |
| Negatives silent | 3/3 (S9, S10, S15) | PASS |
| S6 3-run stability | route + first-mutation stable | PASS |
| Trace 8/8 | 5/8 | FAIL |
| S14 table demonstrated | absent both rounds | FAIL |
| S13 halt integrity | REGRESSED — false completion | FAIL |

S13 is the disqualifier: in re-run 2 the session invented a wire contract for
the deliberately-unimplementable registry item instead of halting; v0.1 and
run-1 both halted correctly (DECISIONS.md 41).

**Deciding rationale (DECISIONS.md 42):** two edit rounds showed a treadmill —
each round's fixes regressed neighbors. B1 consolidation broke trace emission
(6/8 → 4/8, DECISIONS.md 28-29); the completion trigger widened activation but
never produced the table; S13 flipped from correct-halt to false-completion.
Conservative stop per charter rather than a round 3 on unstable ground.

## 2. What v0.2 banked (kept on `chore/v0.2-work-order`)

The mechanism diagnoses are the real value of the cycle:

- **(a) Trace emission is governed by response-ending type, not text
  placement** (DECISIONS.md 40; SCORECARD.md:57). Artifact-ending positives
  emit 5/5 (S4, S5, S6, S7, S8); question-ending positives emit 0/3 (S1, S2,
  S3) — sessions treat a question-ending as non-final, so the close-with-trace
  rule never fires. Hypothesis rests on 8 transcripts; **probe before building
  on it** (Section 3 entry condition).
- **(b) S2/brainstorm activation is stochastic** (DECISIONS.md 33, 37, 38).
  Four probes, four outcomes: dataviz-skill collision → no-fire →
  correct-route-but-landmine-hijack → no-fire. Independently, the bare baseline
  emitted 5 directions unaided (DECISIONS.md 38) — the technique's delta is
  framing, not divergence.
- **(c) Headless evals cannot exclude user-level skills** (DECISIONS.md 33-35).
  OAuth token is keychain-bound so `CLAUDE_CONFIG_DIR` severs auth;
  `--setting-sources` does not gate skill loading (15 user skills present under
  every value). Consequence: absolute trigger rates are environment-relative;
  baseline-vs-green deltas stay internally consistent (same contamination both
  sides).

Harness hardening kept on branch: per-scenario fixture overlays (C1,
DECISIONS.md 21), versioned output dirs (`evals/results/v0.2/`, DECISIONS.md
25), scenarios S14 + S15, the first-mutation notes rule (DECISIONS.md 31), and
the B-series skill-text polish (DECISIONS.md 36).

Costs: v0.2 cycle $25.11 (v0.2 $12.50 + v0.2r2 $12.61, SCORECARD.md:83-85);
program total **$79.48 across 117 runs** (SCORECARD.md:85).

## 3. v0.3 — CONDITIONAL (run only if the entry condition holds)

**Entry condition:** a probe confirms the question-ending hypothesis (finding
2a). Cheap: 2-3 probes of S1/S3 asking a mid-stream question, check whether the
T/A/O trace emits. If the hypothesis does not hold, do not open v0.3 on trace.

Scope, strictly ordered:

1. **Trace binding.** Move the requirement from "close the final response" to
   "every turn-ending response, question or artifact." ONE edit. Probe S1/S3
   before and after (SCORECARD.md:61).
2. **Completion-evidence cluster.** S12, S13, S14 are one class — the
   self-verification route. The technique's reference must make halt-vs-guess
   the explicit fork on unimplementable items, and the claims/evidence table
   the explicit vehicle for DONE claims. **S13's regression is the must-fix**:
   it is a product-integrity issue — the ninth technique producing a false
   completion is worse than the technique not existing (DECISIONS.md 41).
3. **Brainstorm-prototype prune decision.** Baseline does 5 directions unaided
   (DECISIONS.md 38); the exactly-four contract missed at 3, 5, and 6 across
   runs (SCORECARD.md:42). Options at the decision point: relax the contract to
   "≥3 labeled + steal/skip framing" (keeps the framing delta, drops the
   arbitrary count), or delete the technique and its scenario (S2). Do NOT
   iterate S2 further — loop cap spent at 4 iterations (DECISIONS.md 38).

**Exit bar for v0.3:** trace 8/8 on positives; S13 halts on the planted trap;
S14 ships the table; no neighbor regression (S1-S12 hold); negatives 3/3.
**Budget cap:** if v0.3 exceeds ~$30 eval spend without meeting bar, invoke
Stop condition 1.

## 4. Stop conditions — when NOT to continue

This section is the point of the document.

1. **Third treadmill round.** If v0.3's edits regress any previously-passing
   scenario again, STOP editing skill text permanently. The residual failures
   sit at the model-capability frontier (mid-work compliance under competing
   incentives); prose cannot buy them, and each attempt costs neighbors
   (DECISIONS.md 42 established the pattern over two rounds).
2. **Model-release re-baseline (standing, C3).** On the next model release,
   re-run baseline S1-S15 WITHOUT the plugin. Any technique whose baseline now
   meets its Output contract unaided is deleted (SCORECARD.md:102-112,
   v0.2-work-order.md:95-99). If MOST techniques fall to baseline, retire the
   harness gracefully — that is success (the model absorbed the behavior), not
   failure.
3. **Environment ceiling.** Absolute trigger-rate measurement stays out of
   scope until the platform supports skill isolation in headless mode
   (DECISIONS.md 35). Do not build more scenario workarounds for skill
   collision — S2's four iterations were the loop-cap lesson.
4. **Economics.** v0.1 shipped at $54.37 (SCORECARD.md:31); v0.2 spent $25.11
   and shipped nothing behavioral. Each future cycle needs a pre-declared bar
   and budget; no open-ended tuning.

## 5. Not-doing list (explicit anti-scope)

- No `when_to_use` widening without a paired negative scenario (S15 was added
  precisely to guard the completion-trigger widening, DECISIONS.md 36).
- No scenario rewrites past 2 iterations.
- No full re-runs without stream probes first (final-message transcripts
  systematically under-show mid-run behavior, GATES.md:67).
- No dynamic context injection unless a v0.3-style targeted fix fails first —
  cost recurs on every activation (DECISIONS.md 15, 30-31).
