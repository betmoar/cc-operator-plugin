# Gate Evidence Ledger

## Gate 0 — Preamble (Preflight, 2026-07-05)

| Gate | Criterion | Evidence | PASS/FAIL |
|---|---|---|---|
| PF | branch not main/master | `git branch --show-current` → build/unknowns-harness | PASS |
| PF | 3 agent files present | `ls .claude/agents/` → harness-author.md harness-mechanic.md harness-reviewer.md | PASS |
| PF | harness-author probe | "claude-opus-4-8[1m] READY" | PASS |
| PF | harness-mechanic probe | "claude-sonnet-4-6 READY" | PASS |
| PF | harness-reviewer probe | "claude-opus-4-8[1m] READY" | PASS |
| PF | runner syntax | `bash -n scripts/run-eval.sh` → SYNTAX OK | PASS |
| PF | CLI flags | --output-format/--allowedTools in help; --max-turns accepted in live JSON probe (num_turns:1 returned) | PASS |
| PF | plan file exists | test -f docs/superpowers/plans/unknowns-harness-implementation-plan.md → present | PASS |
| PF | ledgers initialized | GATES.md, DECISIONS.md, costs.csv w/ header | PASS |

## Gate 0 — Baseline evals (2026-07-05)

| Gate | Criterion | Evidence | PASS/FAIL |
|---|---|---|---|
| 0 | 10 baseline result files exist | `ls evals/results/baseline/*-result.md \| wc -l` → 10 | PASS |
| 0 | SUMMARY.md exists | committed in "evals: baseline results and failure-pattern summary" | PASS |
| 0 | ≥5 recurring failure patterns named | reviewer verdict: 5 patterns (no-persistence, build-framing flips recon, unevidenced completion, uncalibrated questions, post-hoc assumptions) + 2 dead-weight axes flagged | PASS |

Self-audit: (a) reads outside rule 1 since last gate? NO (plan file once; ls/wc/tail/grep-on-csv gate checks; 300-char head of S6.txt to confirm non-empty output after retry — logging as borderline, it was a gate-recovery check not content ingestion). (b) implemented inline? NO (runner fix + fixtures dispatched to mechanic).

## Gate 1 — Plugin hygiene (2026-07-05)

| Gate | Criterion | Evidence | PASS/FAIL |
|---|---|---|---|
| 1 | plugin installs | run-eval.sh green S10 copied skills into isolated ws; session completed: "S10,green,0.0856,1,3484", no error | PASS |
| 1 | /doctor clean (proxy) | headless /doctor unavailable; proxy: both frontmatter blocks parse (reviewer/mechanic inspection), descriptions 331/427 chars (python re-measure; earlier awk gave garbage) — under the ~1024 truncation threshold; deviation logged | PASS |
| 1 | both SKILL.md < 500 lines | wc -l → 95, 119 | PASS |
| 1 | zero claude-citation | `grep -r claude-citation unknowns-harness/ \| wc -l` → 0 | PASS |
| 1 | reference count = 8 | `ls references/ \| wc -l` → 8 | PASS |
| 1 | all refs have Failure modes | `grep -L "## Failure modes" references/*.md \| wc -l` → 0 | PASS |

Self-audit: (a) reads outside rule 1? NO (gate checks were wc/grep/ls/awk lines only). (b) implemented inline? NO.

## Gate 2 — GREEN triggering + routing (2026-07-05)

| Gate | Criterion | Evidence | PASS/FAIL |
|---|---|---|---|
| 2 | ≥7/8 positives trigger+route | reviewer v0.1.5 verdicts: triggers 8/8, routes 7/8 (S1,S3,S4,S5,S6,S7,S8 y; S2 partial); S6 probe-confirmed notes-file Write with correct headings | PASS |
| 2 | 2/2 negatives silent | reviewer: S9/S10 direct answers, no ceremony, both runs | PASS |
| 2 | F13 decision logged w/ miss count | DECISIONS.md 2026-07-05 2.1: collapse executed on 6/10 misses (confound noted honestly); post-collapse trajectory 2→3→5→7/8 | PASS |
| 2 | remaining miss has written hypothesis | DELTA.md v0.1.5: S2 four-directions buried mid-contract; deferred to Phase 7 | PASS |

Self-audit: (a) reads outside rule 1? YES — logged: 5-line Read of S6.json to diagnose 3x runner failure (harness plumbing, not product content); grep-count checks on SKILL.md for review verification. (b) implemented inline? YES — logged: 2-line sed raising --max-turns in both runner scripts (DEVIATION in DECISIONS.md). Both were gate-recovery plumbing; product files untouched by orchestrator.

## Gate 3 — ReAct observation gate (2026-07-06)

| Gate | Criterion | Evidence | PASS/FAIL |
|---|---|---|---|
| 3 | S11 passes (Observation catches mid-course surprise, re-routes) | probe stream S11.stream.jsonl: literal "Thought:/Action:/Observation:" block in discovery artifact; blindspot surfaced "exporter.ts... exportChunked... 500k rows" conflict; zero Writes — session stopped at the surfaced conflict and asked, instead of plowing on (mechanic stream analysis, reviewer criteria) | PASS |
| 3 | S1–S10 no regression | reviewer regression pass: routes 7/8 (S1,S2,S3,S4,S5,S7,S8; S2 improved partial→y), negatives 2/2 — equals Gate-2 bar; composition shifted (S6 y→n, artifact variance) | PASS |

Notes: trace emission 6/8 after template fix (was 0/8 as prose). S6 notes-file creation is variance-prone across runs (created in Gate-2 probe, missing in this run) — carried to Phase 4, whose lifecycle section directly targets it.
Self-audit: (a) reads outside rule 1? YES — logged: read S11 fixture exporter.ts (52 lines) to adjudicate reviewer's fixture-mismatch flag before authorizing the fix; 5-line Read of S6.json earlier (already logged Gate 2). (b) implemented inline? YES — logged: turn-cap sed 40→80 (DEVIATION in DECISIONS.md).

## Gate 4 — Reflexion memory loop (2026-07-06)

| Gate | Criterion | Evidence | PASS/FAIL |
|---|---|---|---|
| 4 | S12 passes with cited behavioral evidence that prior notes altered attempt-2 behavior | probe stream S12.stream.jsonl (mechanic analysis): notes file Read at position 5 of 12, BEFORE any Write; assistant text: "Must stream — never buffer the full array. exportRows() OOM'd prod at 1.2GB; wire through exportChunked instead" citing "prior deviation notes from attempt #1"; CSV Edit routes "row-by-row through exportChunked rather than buffering" | PASS |

Notes: first scored run's final-message .txt was FAIL-scored (C1/C4 invisible in last message); stream probe supplied the mid-run evidence — deviation read, restated as constraint, honored in the written code. Scoring caveat: final-message transcripts systematically under-show mid-run behavior; stream probes are the authoritative source for behavioral gates.
Self-audit: (a) reads outside rule 1? NO. (b) implemented inline? NO.

## Gate 5 — Model-side self-verification (2026-07-06)

| Gate | Criterion | Evidence | PASS/FAIL |
|---|---|---|---|
| 5 | S13 passes (unimplementable item → unverified/deviation, not claimed done) | reviewer: "zero precedent anywhere in the repo... no HTTP client, no registry module" surfaced explicitly; no completion claimed; also caught item-4/spec contradiction. PASS high confidence | PASS |
| 5 | zero unevidenced completion claims in eval transcripts | reviewer scan S1–S13: S1,S3,S4,S6,S7,S11,S13 question-endings exempt; S2,S5,S8 artifact-writes self-evidenced; S9,S10 negatives; S12 prior violation ("Implementation is done." w/o evidence) re-run on Phase-5 skill → fresh transcript makes no completion claim, all substantive claims cite spec lines/absence evidence | PASS |

Notes (honest limitation): no transcript yet positively demonstrates the claims-vs-evidence TABLE on an actual done-claim — S12/S13 sessions halted at surfaced contradictions before claiming done (which is the desired conservative behavior, but the table mechanism itself is exercised only in the reference's worked example). Logged as a Phase-7 scorecard item.
Self-audit: (a) reads outside rule 1? NO. (b) implemented inline? NO.

## Gate 6 — Fork decision (2026-07-06)

| Gate | Criterion | Evidence | PASS/FAIL |
|---|---|---|---|
| 6 | context measurement exists OR logged no-fork decision with numbers | evals/results/v0.2/FORK-DECISION.md: S1 exploration ~1,986 tok (0.99% of 200k), S11-as-S4-proxy ~6,100 tok (3.05%) vs ~20% plan threshold → NO FORK | PASS |

Self-audit: (a) reads outside rule 1? NO (numbers came from mechanic dispatch). (b) implemented inline? Wrote FORK-DECISION.md + ledger rows — orchestrator-reserved decision artifact per charter (gate verdicts and reserved decisions are mine to record).

## Gate 7 — Scorecard + prune (2026-07-06)

| Gate | Criterion | Evidence | PASS/FAIL |
|---|---|---|---|
| 7 | scorecard populated incl. costs.csv fold-in | evals/SCORECARD.md: v0.1 actuals (recall 100%, precision 100%, routing 87.5%, unverified-claims 0, trace 6/8) + cost table (baseline 14 runs $12.36, green 74 runs $42.01, total $54.37) | PASS |
| 7 | ≥1 prune keep/delete decision with evidence | SCORECARD.md Prune decisions: quiz.md KEEP with baseline-vs-contract evidence (baseline S8 strong review but no quiz artifact); 8 others KEEP w/ utilization + Gate-0 pattern evidence | PASS |

Self-audit: (a) reads outside rule 1? NO. (b) implemented inline? Appended prune-decision block to SCORECARD.md — orchestrator-reserved decision artifact.
