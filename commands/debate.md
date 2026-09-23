---
description: Run the debate workflow — 2-5 named models argue the same case over three blind rounds, then a neutral synthesis. It never picks a winner; you decide.
argument-hint: "<the question, stated so a position on it is falsifiable>"
allowed-tools: Bash(bash "${CLAUDE_PLUGIN_ROOT}"/scripts/ops-tiers.sh:*), Workflow
---

Debate `$ARGUMENTS`.

**Use this only when the decision turns on judgment rather than evidence you
could go and measure.** If the question can be settled by running something, run
it — a debate is the expensive way to be told what a command would have said.

1. **State the case so a position on it is falsifiable.** "Which storage should
   we use?" produces four seats agreeing at different lengths. "Should the spec
   artifact live under `.operator/` given the allowlist migration it forces?"
   produces positions that can lose.

2. **Choose the models — the point is that they DIFFER.** Resolve the ids:

   ```
   bash "${CLAUDE_PLUGIN_ROOT}"/scripts/ops-tiers.sh --json
   ```

   Pick 2-5 distinct ids from the resolved map or from what the proxy routes.
   Two entries that resolve to the same model is one model agreeing with
   itself, three times, at full price.

3. **Dispatch:**

   ```
   Workflow({ name: "cc-operator:debate", args: {
     case: "<the falsifiable question>",
     models: ["<id>", "<id>", "<id>"],
     tiers: <the JSON from step 2> } })
   ```

**`chose` is always null, by design.** Relay where the positions actually
disagree and what each said would overturn it. A synthesis that reads like a
recommendation is you adding one, and the human asked three models precisely so
that you would not.
