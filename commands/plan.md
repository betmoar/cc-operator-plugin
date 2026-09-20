---
description: Run the plan workflow — decompose an approved spec into TDD tasks, then vet each in parallel for feasibility and testability.
argument-hint: "<path to the approved spec, or paste it>"
allowed-tools: Bash(bash "${CLAUDE_PLUGIN_ROOT}"/scripts/ops-tiers.sh:*), Read, Workflow
---

Plan `$ARGUMENTS` with the plan workflow. It refuses without both required
arguments, before any dispatch — so assemble them first.

1. **The spec.** If `$ARGUMENTS` names a file, Read it and pass its content. If
   it does not, use the approved design from this session. An unapproved sketch
   is not a spec: decomposing one produces a plan for work nobody agreed to.

2. **The north star.** One sentence naming what must be true when this is done,
   followed by a `Missed if: …` clause. The workflow refuses without the clause
   and reads it without a fallback.

   **It must be the SAME sentence as the BAR block's** in
   `.operator/VERDICTS.md`. There is no mechanism keeping the two in step today
   (`docs/CYCLE.md` §2) — if they differ, the plan is vetted against a goal the
   ledger never agreed to, and nothing reports the difference. Read the BAR
   block and copy the sentence rather than writing a new one.

3. **Resolve the tier bindings** — one line of JSON, passed through verbatim:

   ```
   bash "${CLAUDE_PLUGIN_ROOT}"/scripts/ops-tiers.sh --json
   ```

4. **Dispatch:**

   ```
   Workflow({ name: "cc-operator:plan", args: {
     spec: "<the spec content>",
     northStar: "<the sentence> Missed if: <the falsifying condition>",
     tiers: <the JSON from step 3> } })
   ```

**Read the graph for what it is.** `consumesNoTaskProduces` is not a defect
list — the commonest entry is a task consuming something the project already
provides. `contractsInferred` records every place the decomposer's prose was
parsed rather than declared, and those edges are ESTIMATED. Review the plan
against the spec yourself; that gate is yours, not the workflow's.
