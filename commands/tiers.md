---
description: Resolve tier→model bindings, apply one-off overrides, or render project-layer agents so plain Agent dispatch can run on a configured cc-proxy model. Wraps the resolver (ops-tiers.sh) and renderer (ops-render.sh) — the command adds no logic; those scripts' charset and cc-proxy routability guards are the validation.
argument-hint: "[set NAME=model-id | render | revert | check]"
allowed-tools: Bash(bash "${CLAUDE_PLUGIN_ROOT}"/scripts/ops-tiers.sh:*), Bash(bash "${CLAUDE_PLUGIN_ROOT}"/scripts/ops-render.sh:*)
---

A thin wrapper over `ops-tiers.sh` (resolve) and `ops-render.sh` (render). It
adds no logic and validates nothing itself — those scripts' charset guard and
cc-proxy routability check (`^glm-|/|^claude-`) are the validation, applied
before any id reaches a dispatch. Relay their output verbatim — never summarize,
reformat, or edit it. Pass every non-zero exit code through unchanged and stop.

## Resolve branches (ops-tiers.sh — the tier→model table)

Selected by `$ARGUMENTS`:

1. **Empty or absent** — print the resolved tier table with provenance:

   ```
   bash "${CLAUDE_PLUGIN_ROOT}"/scripts/ops-tiers.sh --show
   ```

   The `SOURCE` column shows which layer won (`default` / `user` / `project` /
   `--set`).

2. **`set NAME=model-id`** — apply a one-off override for this invocation only
   (it is NOT written to any tiers.env):

   ```
   bash "${CLAUDE_PLUGIN_ROOT}"/scripts/ops-tiers.sh --set NAME=model-id --show
   ```

   To persist an override across sessions, edit
   `~/.claude/cc-operator/tiers.env` or `.operator/tiers.env` directly.

## Render branches (ops-render.sh — plain-Agent model flexibility)

Plain `Agent` dispatch reads an agent file's `model:` frontmatter at session
start, NOT per-call. These branches render project-layer agent files
(`.claude/agents/op-*.md`) that shadow the plugin-root agents, so a directly-
dispatched seat runs on a configured cc-proxy model without a workflow wrapping
it. Edit `.operator/tiers.env` to set the bindings first.

3. **`render`** — render `.claude/agents/op-*.md` from the templates + the
   resolved tier config:

   ```
   bash "${CLAUDE_PLUGIN_ROOT}"/scripts/ops-render.sh
   ```

4. **`revert`** — remove the project-layer agents (fall back to plugin-root):

   ```
   bash "${CLAUDE_PLUGIN_ROOT}"/scripts/ops-render.sh --revert
   ```

5. **`check`** — render to a temp dir + liveness-probe each model id; write
   nothing. Use before `render` to catch a typo'd or dead id:

   ```
   bash "${CLAUDE_PLUGIN_ROOT}"/scripts/ops-render.sh --check
   ```

**`render` and `revert` require a session restart to take effect** — agent
files are read at session start, not reloaded mid-session. The scripts say so in
their output; relay that line. If `$CLAUDE_CODE_SUBAGENT_MODEL` is set it
OVERRIDES the rendered binding at dispatch (spec M7) — the renderer warns; relay
that too and tell the operator to unset it.

Any other `$ARGUMENTS` — print the `argument-hint` and stop.

The four tiers: `JUDGMENT` (opus-class review/verdict), `IMPLEMENT`
(sonnet-class authoring), `MECHANICAL` (cheap lenses, crawls, generation),
`RECON` (haiku-class search). See `docs/spec/2026-07-29-workflow-orchestration-design.md`
and `docs/spec/2026-07-28-cc-operator-orchestration-design.md` §3.4 (renderer).
