# Spec — unknowns integration (cc-unknowns folded into the operator)

**Date:** 2026-07-31
**Status:** approved design, implemented
**Source:** cc-unknowns-plugin `skills/surfacing-unknowns` (retired into this plugin)

## Why

The charter goal is a self-contained cc-operator whose sole external dependency
is cc-proxy. cc-unknowns (the `surfacing-unknowns` skill — the "unknowns harness")
was a separate plugin shipping 9 discovery techniques. Per the 2026-07-31
decision, it is **baked into the workflows + charter, not shipped as a skill** —
the operator itself is the unknowns harness. This spec is the `[DOC:spec-unk]`
target the charter's Discovery discipline cites.

## The integration: 6 techniques already lived in the workflows

The workflows shipped on `feat/orchestration-layer` already implement the
majority of cc-unknowns' techniques. The integration makes that explicit (route
to the workflow, do not duplicate) rather than re-adding them as prose:

| cc-unknowns technique | cc-operator owner | Notes |
|---|---|---|
| Blindspot pass | `workflows/brainstorm.js` (b) | the blindspot lens already sweeps for what exists that a design would duplicate |
| Brainstorm & multi-direction prototype | `workflows/brainstorm.js` (a) | the N divergent directions, cheap tier |
| Reference (source-code-first) | `workflows/brainstorm.js` (c) | the references lens |
| Decision-first implementation plan | `workflows/plan.js` | decomposition + per-task vetting |
| Self-verification audit | `workflows/review.js` | the adversarial seat re-runs DONE MEANS |
| Pre-merge comprehension quiz | `workflows/review.js` | the panel + adversarial verify on merge-bound work |

## The 3 genuinely-new techniques, now charter/workflow rules

These had no workflow home and are added as operator discipline:

1. **Interview** (fuzzy-requirements stage). The operator asks one question at a
   time, highest architectural blast radius first, waiting between each. No
   batching; order by consequence. Ends in a decisions table + a ready-to-paste
   prompt baking in every answer. This is the pre-brainstorm stage; it runs when
   requirements are still a vague paragraph, before the brainstorm workflow fans
   out. Charter rule: "fuzzy → interview."

2. **Implementation notes / Deviations** (build stage). Edge-case departures from
   the plan are logged under **Deviations** in DECISIONS.md — conservative choice
   taken + why — not silently absorbed. This reuses the existing DECISIONS.md
   ledger rather than a separate notes file. Charter rule: "build departures →
   Deviations in DECISIONS.md."

3. **Thought/Action/Observation trace** (every technique). After every technique
   the operator emits a three-line trace in the response: Thought (unknown
   targeted) / Action (technique, scope) / Observation (what it revealed, which
   quadrant an unknown moved to). The Observation decides the next move; never
   chain two techniques without one. Charter rule: "After each technique emit a
   Thought/Action/Observation trace."

## The four quadrants (the classification, kept as mental model)

- Known knowns — stated in the prompt; actionable.
- Known unknowns — the user knows they're undecided; ask or plan.
- Unknown knowns — obvious-once-seen, never written down; surface via prototypes/brainstorm.
- Unknown unknowns — not considered; surface via a blindspot pass.

Only quadrant 1 reaches prompts by default; 2–4 are where rework hides.

## Reframe-stop

A surfaced unknown that invalidates the task's framing → the operator STOPS and
proposes the reframe to the human before continuing. Never optimize a plan for
the wrong problem. Charter rule.

## Out of scope
- A separate `skills/` entry — explicitly rejected; the operator is the harness.
- Pitch-doc — folds into the existing `/cc-operator:handoff` command, not a new technique here.
- Re-dispatching discovery the user has already closed (stage-matched routing
  prevents this: "ready → plan" does not restart interview).
