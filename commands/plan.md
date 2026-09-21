---
description: Run the plan workflow — decompose an approved spec into TDD tasks, then vet each in parallel for feasibility and testability.
argument-hint: "<path to the approved spec, or paste it>"
allowed-tools: Bash(bash "${CLAUDE_PLUGIN_ROOT}"/scripts/ops-tiers.sh:*), Read, Workflow
---

Plan `$ARGUMENTS` with the plan workflow. It refuses without both required
arguments, before any dispatch — so assemble them first.

1. **The spec.** If `$ARGUMENTS` is a slug with a spec at
   `.operator/specs/<slug>.md`, Read it — and **refuse to proceed unless its
   `Status:` line reads `APPROVED`**. An unapproved sketch is not a spec:
   decomposing one produces a plan for work nobody agreed to, and the Status
   line is the only thing that distinguishes them. Run
   `/cc-operator:spec <slug>` to finish and approve it first.

   If `$ARGUMENTS` names some other file, Read it and pass its content; if it
   names nothing, use the approved design from this session. Both of those are
   the pre-#155 path and carry no stamp, no ledger row and no north-star
   linkage — say so when you report.

2. **The north star.** One sentence naming what must be true when this is done,
   followed by a `Missed if: …` clause. The workflow refuses without the clause
   and reads it without a fallback.

   **Take it from the spec's `## North star` section verbatim.** That is what
   makes it the same sentence as the BAR block's: `ops-spec.sh --approve`
   emitted that block FROM the spec, so copying from the spec keeps all three
   in step. For a spec-less invocation there is no such link — read the BAR
   block in `.operator/VERDICTS.md` and copy the sentence rather than writing a
   new one, and say in your report that nothing enforces the match.

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
