---
description: Run the plan workflow — decompose an approved spec into TDD tasks, then vet each in parallel for feasibility and testability.
argument-hint: "<path to the approved spec, or paste it>"
allowed-tools: Bash(bash "${CLAUDE_PLUGIN_ROOT}"/scripts/ops-tiers.sh:*), Bash(bash "${CLAUDE_PLUGIN_ROOT}"/scripts/ops-testability.sh:*), Read, Write, Workflow
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
   names nothing, use the approved design from this session. Neither carries
   a stamp, a ledger row or north-star linkage — say so when you report.

2. **The north star.** One sentence naming what must be true when this is done,
   followed by a `Missed if: …` clause. The workflow refuses without the clause
   and reads it without a fallback.

   **Take it from the spec's `## North star` section verbatim.** That is what
   makes it the same sentence as the BAR block's:
   `ops-spec.sh --approve <slug> --owner <id>` emitted that block FROM the spec, so
   copying from the spec keeps all three
   in step. For a spec-less invocation there is no such link — read the BAR
   block in `.operator/VERDICTS.md` and copy the sentence rather than writing a
   new one, and say in your report that nothing enforces the match.

3. **Resolve the tier bindings** — one line of JSON, passed through verbatim:

   ```
   bash "${CLAUDE_PLUGIN_ROOT}"/scripts/ops-tiers.sh --json
   ```

4. **Choose the testability lens** (#151):

   ```
   bash "${CLAUDE_PLUGIN_ROOT}"/scripts/ops-testability.sh --available
   ```

   rc 0 → pass `testability: "external"` below: one typed-decision call vets
   every testCycle instead of one MECHANICAL seat per task (measured 24/24 vs
   23/24, ~3000× cheaper — DECISION-ENGINE-PROBES.md, Surface 7). Any other rc
   → omit it; the seat runs as before. Opting in is the user's
   (`CC_OPERATOR_JEV=1`): task titles, files and testCycles leave the machine.

5. **Dispatch:**

   ```
   Workflow({ name: "cc-operator:plan", args: {
     spec: "<the spec content>",
     northStar: "<the sentence> Missed if: <the falsifying condition>",
     tiers: <the JSON from step 3>,
     testability: "external" /* only if step 4 returned rc 0 */ } })
   ```

6. **External testability only:** Write the workflow's result JSON to a
   scratch file and run
   `bash "${CLAUDE_PLUGIN_ROOT}"/scripts/ops-testability.sh --plan <that file>`.
   Its stdout is the plan with `testable`, `blocked` and `vettingIncomplete`
   filled in, and it is the result you review. The workflow returns EVERY task
   in `vettingIncomplete`; this step is the only thing that moves one out, so a
   skipped step 6 leaves nothing clear. rc 3 means some tasks stayed UNVETTED
   (engine down, bad answer, more than 60 tasks) — the plan still prints.

**Read the graph for what it is.** `consumesNoTaskProduces` is not a defect
list — the commonest entry is a task consuming something the project already
provides. `contractsInferred` records every place the decomposer's prose was
parsed rather than declared, and those edges are ESTIMATED. Review the plan
against the spec yourself; that gate is yours, not the workflow's.


**Where the result goes.** The plan is an input to later work, so it belongs in
git: Write it to the path the user names (default `docs/plans/<slug>.md`, beside
the spec it came from). An artifact or shared document is an additional copy
for reading, never the plan of record — a plan that lives only outside the repo
is not diffable and not reviewable in a PR. Ask once per session.
