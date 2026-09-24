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

2. **Resolve the panel and the tier bindings** — two lines of JSON:

   ```
   bash "${CLAUDE_PLUGIN_ROOT}"/scripts/ops-tiers.sh --panel
   bash "${CLAUDE_PLUGIN_ROOT}"/scripts/ops-tiers.sh --json
   ```

   `--panel` seats the cross-vendor panel declared in `tiers.env` (`PANEL`,
   default Opus + GLM + DeepSeek) against what the proxy routes, falling back
   along `PANEL_FALLBACK` (qwen3.8-max, then a persona-Opus seat) (#172). Its
   stderr notes say which seat fell back and whether the panel is short; relay
   them. Exit 3 means fewer than 2 seats resolved: stop and relay the notes —
   there is no panel to dispatch. The point is that the models DIFFER: a panel on one vendor converges.
   To debate on other models, pass your own ids as `models` instead.

3. **Dispatch** with the panel's `models` and `spares` verbatim:

   ```
   Workflow({ name: "cc-operator:debate", args: {
     case: "<the falsifiable question>",
     models: <panel.models>,
     spares: <panel.spares>,
     tiers: <the JSON from --json> } })
   ```

   A seat that dies at opening is re-seated on the next spare. A `persona:`
   seat is the same model under a different temperament — the result's
   `distinctModels` says how many models actually argued.

**`chose` is always null, by design.** Relay where the positions actually
disagree and what each said would overturn it. A synthesis that reads like a
recommendation is you adding one, and the human asked three models precisely so
that you would not.
