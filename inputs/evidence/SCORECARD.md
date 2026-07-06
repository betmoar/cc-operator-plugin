Per release, from eval transcripts + real usage:
- Trigger precision (negatives silent) / recall (positives fire): target ≥ 90% each
- Routing accuracy (intended technique chosen): target ≥ 85%
- Deviations per build (S6/S12): trending DOWN across attempts = memory loop working
- Unverified-claim rate at completion (S13): target 0
- Technique utilization: any reference unloaded across a full release cycle
  of real use is a deletion candidate

## v0.1 actuals (2026-07-06)

| Metric | Result | Target | Status |
|---|---|---|---|
| Trigger recall | 8/8 positives (100%) | ≥ 90% | PASS |
| Trigger precision | 2/2 negatives silent (100%) | ≥ 90% | PASS |
| Routing accuracy | 7/8 (87.5%) — S6 residual miss; S2 improved to full | ≥ 85% | PASS |
| S11 observation gate | PASS (trace + halt-at-conflict) | PASS | PASS |
| S12 Reflexion gate | PASS (notes read pre-Write, deviation honored) | PASS | PASS |
| S13 completion gate | PASS (impossibility surfaced, no unevidenced done-claim) | PASS | PASS |
| Unverified-claim rate | 0 in final transcript set (S12 prior violation cured on re-run) | 0 | PASS |
| T/A/O trace emission | 6/8 | — | INFO |
| Technique utilization | blindspot, brainstorm, interview, reference-port, implementation-plan, implementation-notes, pitch-doc, quiz, self-verification all exercised at least once across S1–S13 | no unused | No deletion candidates |

## Cost telemetry (fold-in from costs.csv)

Computed from `evals/results/costs.csv` (88 runs total).

| Mode | Runs | Total cost (USD) | Mean cost/run (USD) | Mean turns/run |
|---|---|---|---|---|
| baseline | 14 | $12.3606 | $0.8829 | 21.6 |
| green | 74 | $42.0133 | $0.5677 | 18.3 |
| **Total** | **88** | **$54.3739** | — | — |

Green runs averaged 36% lower cost per run than baseline, consistent with the skill providing relevant context that reduces exploratory tool use.

## v0.2 cycle (2026-07-06) — NOT SHIPPED

### Re-run 2 (v0.2r2) final scores — S1–S15

| Scenario | Verdict | Note |
|---|---|---|
| S1 | PARTIAL | Behavior correct; trace omitted |
| S2 | FAIL | 6 directions vs 4; activation stochastic (3, 5, 6 across runs) |
| S3 | PARTIAL | No trace |
| S4 | PASS | — |
| S5 | PASS | — |
| S6 | PASS | First-mutation rule honored |
| S7 | PASS | — |
| S8 | PASS | — |
| S9 | silent | Negative guard PASS |
| S10 | silent | Negative guard PASS |
| S11 | PARTIAL | Verify-halt correct; re-route not visible |
| S12 | PARTIAL | Honest verification; open decisions silently resolved |
| S13 | FAIL | REGRESSION: false completion, guessed wire contract; halted correctly in v0.1 and r1 |
| S14 | FAIL | No claims/evidence table; checkmarks asserted unverified (2 rounds) |
| S15 | silent | New negative guard PASS |

Aggregates: routes 7/8 held; negatives 3/3; trace 5/8 — pattern: artifact-ending positives 5/5 emit, question-ending positives 0/3 omit; completion-evidence class 0/2.

### Key findings

- Trace emission is determined by response ending type, not text placement: bind to end-of-turn in v0.3.
- S2/brainstorm: activation stochastic across 4 probes (dataviz collision → no-fire → landmine hijack → no-fire); bare baseline emitted 5 directions unaided → prune-review candidate.
- Eval env cannot exclude user-level skills (keychain-bound auth blocks CLAUDE_CONFIG_DIR isolation; --setting-sources doesn't gate skills) — absolute trigger rates are environment-relative; deltas remain valid.
- Edit treadmill observed: each round's fixes regressed neighbors (B1 consolidation broke trace; completion trigger didn't move S14; S13 flipped to false completion in r2).
- v0.2 wins kept on branch: S6 route+ordering stable, fixture isolation (overlays), S15 negative guard, first-mutation rule, B-series polish.

### Cost fold-in (cumulative through v0.2r2)

Computed via:
```python
import csv; from collections import defaultdict
totals = defaultdict(lambda: {'cost': 0.0, 'runs': 0})
with open('evals/results/costs.csv') as f:
    for row in csv.DictReader(f):
        totals[row['mode']]['cost'] += float(row['cost_usd'] or 0)
        totals[row['mode']]['runs'] += 1
```

Output:
```
baseline:  runs=14, total=$12.3606, mean=$0.8829
green:     runs=74, total=$42.0133, mean=$0.5677
v0.2:      runs=14, total=$12.4970, mean=$0.8926
v0.2r2:    runs=15, total=$12.6129, mean=$0.8409
GRAND TOTAL: runs=117, total=$79.4837
```

| Mode | Runs | Total cost (USD) | Mean cost/run (USD) |
|---|---|---|---|
| baseline | 14 | $12.3606 | $0.8829 |
| green (v0.1) | 74 | $42.0133 | $0.5677 |
| v0.2 | 14 | $12.4970 | $0.8926 |
| v0.2r2 | 15 | $12.6129 | $0.8409 |
| **Grand total** | **117** | **$79.4837** | — |

Note: v0.2/v0.2r2 costs are per-run comparable to baseline (both ran without the edit-treadmill fix). Green (v0.1) mean remains the low-water mark at $0.57/run.

### Decision

v0.2 NOT shipped. v0.1 remains current. S2 prune-review, trace binding, S13/S14 completion-evidence class carried to v0.3 backlog.

## Prune decisions (v0.1, 2026-07-06 — orchestrator)
- **quiz.md: KEEP.** Strongest deletion candidate — Phase-0 baseline S8 review was
  the baseline's best output ("gold-standard" evidencing per reviewer). But the
  baseline produced no comprehension-quiz artifact (walkthrough only); the contract's
  quiz half appeared only after the skill (green S8: walkthrough + 4-question quiz,
  merge gated). Baseline does NOT match the output contract unaided → keep.
- **All other eight: KEEP.** Every reference exercised ≥1× across S1–S13
  (utilization row above); Phase-0 baselines matched no technique's full output
  contract (Gate-0 SUMMARY: 5 failure patterns; persistence, build-framing flip,
  question calibration, assumption timing all baseline-absent).
- Next prune trigger per policy: first model-release re-baseline.
