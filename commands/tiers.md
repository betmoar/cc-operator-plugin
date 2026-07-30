---
description: Show the resolved tier→model table with provenance, or apply a one-off tier override for this session. Wraps the tier resolver — the command adds no logic; the resolver's charset and cc-proxy routability guards are the validation.
argument-hint: "[set NAME=model-id]"
allowed-tools: Bash(bash "${CLAUDE_PLUGIN_ROOT}"/scripts/ops-tiers.sh:*)
---

A thin wrapper over `ops-tiers.sh`. Resolve tiers from the layered config
(baked defaults → `~/.claude/cc-operator/tiers.env` → `.operator/tiers.env`
→ `--set`), then relay the resolver's output verbatim — never summarize,
reformat, or edit it. The command validates nothing itself; the resolver's
charset guard and cc-proxy routability check (`^glm-|/|^claude-`) are the
validation, applied before any id reaches a dispatch.

Two branches, selected by `$ARGUMENTS`:

1. **Empty or absent** — print the resolved table with provenance:

   ```
   bash "${CLAUDE_PLUGIN_ROOT}"/scripts/ops-tiers.sh --show
   ```

   Relays stdout and stderr unchanged. The `SOURCE` column shows which layer
   won for each tier (`default` / `user` / `project` / `--set`).

2. **`set NAME=model-id`** — apply a one-off override for this invocation
   only (it is NOT written to any tiers.env):

   ```
   bash "${CLAUDE_PLUGIN_ROOT}"/scripts/ops-tiers.sh --set NAME=model-id --show
   ```

   Pass `--set`'s exit code through. A non-zero exit means the resolver
   refused the id (unroutable shape, unknown tier name, or a character
   outside the model-id charset) — report its message unchanged and stop. To
   persist an override across sessions, edit
   `~/.claude/cc-operator/tiers.env` or `.operator/tiers.env` directly.

Any other `$ARGUMENTS` — print the `argument-hint` and stop.

The four tiers: `JUDGMENT` (opus-class review/verdict), `IMPLEMENT`
(sonnet-class authoring), `MECHANICAL` (cheap lenses, crawls, generation),
`RECON` (haiku-class search). See `docs/spec/2026-07-29-workflow-orchestration-design.md`.
