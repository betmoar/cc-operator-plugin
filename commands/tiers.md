---
description: Resolve tier→model bindings, apply one-off overrides, or render project-layer agents so plain Agent dispatch can run on a configured cc-proxy model. Wraps the resolver (ops-tiers.sh) and renderer (ops-render.sh) — the command adds no logic; those scripts' charset guard is the validation.
argument-hint: "[set NAME=model-id | suggest | render | revert | check]"
allowed-tools: Bash(bash "${CLAUDE_PLUGIN_ROOT}"/scripts/ops-tiers.sh:*), Bash(bash "${CLAUDE_PLUGIN_ROOT}"/scripts/ops-render.sh:*)
---

A thin wrapper over `ops-tiers.sh` (resolve) and `ops-render.sh` (render). It
adds no logic and validates nothing itself — those scripts' charset guard is
the validation, applied before any id reaches a dispatch. It is a
WELL-FORMEDNESS check and nothing more: since 0.8.3 operator does not decide
which model ids exist, so an id it has never heard of resolves and cc-proxy
routes it or refuses it. Relay their output verbatim — never summarize,
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

3. **`suggest`** — report which bindings a graded model dominates (#153). It is
   report-only and changes nothing:

   ```
   bash "${CLAUDE_PLUGIN_ROOT}"/scripts/ops-tiers.sh --suggest
   ```

   It reads cc-proxy's `~/.claude/cc-proxy/grades.json`. A binding is DOMINATED
   when another graded model scores at least as high and costs no more on input
   or output. That is not "the cheapest model above a floor", which would put
   every tier on one model. With no table it prints a note and exits 0, because
   cc-proxy is optional. To act on a suggestion, repoint the tier in `tiers.env`.

## Render branches (ops-render.sh — plain-Agent model flexibility)

Plain `Agent` dispatch reads an agent file's `model:` frontmatter at session
start, NOT per-call. These branches render project-layer agent files
(`.claude/agents/op-*.md`) that shadow the plugin-root agents, so a directly-
dispatched seat runs on a configured cc-proxy model without a workflow wrapping
it. Edit `.operator/tiers.env` to set the bindings first.

> **Until you render, `tiers.env` does not reach a plain `Agent` dispatch** —
> and nothing warns you (#55). Every shipped `agents/op-<seat>.md` carries a
> hardcoded Anthropic alias in its frontmatter (`op-mechanic: sonnet`,
> `op-verifier: opus`, `op-reviewer: opus`), and that alias wins at dispatch
> time. So an operator who has set `mechanic → IMPLEMENT → deepseek-v4-flash`
> and has not rendered runs every `op-mechanic` dispatch on `sonnet`.
>
> The call site cannot fix it either: the plain `Agent` tool's `model` parameter
> is schema-locked to the enum `sonnet | opus | haiku | fable`, so a
> non-Anthropic id is rejected before dispatch. Passing `model: sonnet` there is
> identical to passing nothing — the frontmatter already says `sonnet`.
> (That enum is a property of the HARNESS, not of this repo — nothing in the
> tree pins it and no validator can. Measured 2026-08-15 against the hosted tool
> schema; re-check it after a Claude Code upgrade, because this claim drifts on
> their release, not on our edits.)
>
> Two routes actually apply the configured tier:
> 1. **`render`** (below) — writes the binding into the project-layer agent
>    files. Requires a session restart.
> 2. **The `dispatch` workflow** — no render, no restart. Two steps, because the
>    workflow sandbox has no filesystem and cannot read `tiers.env` itself:
>
>    ```
>    bash "${CLAUDE_PLUGIN_ROOT}"/scripts/ops-render.sh --model mechanic
>    # → deepseek:deepseek-v4-flash
>    ```
>
>    then pass that id to the workflow:
>
>    ```
>    Workflow({ name: "dispatch", args: {
>      seat: "mechanic", model: "deepseek:deepseek-v4-flash", prompt: "<the task>" } })
>    ```
>
>    `seat` picks the agent (`author`, `mechanic`, `scout`, `verifier`, `crawler`,
>    `brainstorm`; the `op-` prefix is optional), and `model` is applied to the
>    call — which the plain `Agent` tool cannot do. The id gets the same charset
>    guard a `tiers.env` binding gets — no more and no less, so this is neither a
>    way around `check_routable` nor a second opinion about your model choice.
>
>    `tier` is the second route in (#158). Pass a tier NAME — `JUDGMENT`,
>    `IMPLEMENT`, `MECHANICAL`, `RECON`, case-insensitive — and the id comes out
>    of the `tiers` map you forwarded, so a seat can be dispatched on its own
>    tier without resolving the id by hand first:
>
>    ```
>    Workflow({ name: "dispatch", args: {
>      seat: "mechanic", tier: "IMPLEMENT", prompt: "<the task>",
>      tiers: { IMPLEMENT: "deepseek:deepseek-v4-flash" } } })
>    ```
>
>    `model` beats `tier` when both are given, and says so in the log. An
>    unknown tier name is REFUSED, never defaulted.
>
>    Omitting BOTH is legal and dispatches with **no model override at all**:
>    the seat runs on its own configured default — the `model:` frontmatter in
>    `agents/op-<seat>.md`, a project-layer agent written by `render` above, or
>    `$CLAUDE_CODE_SUBAGENT_MODEL`. The log says so and names both flags. It
>    used to fall back to the JUDGMENT tier instead, which dispatched the
>    IMPLEMENT-bound `mechanic` seat one tier up and logged that it had —
>    honest, not correct (#158). A workflow cannot read `tiers.env`, so the one
>    honest answer to "no binding named" is to leave the decision where it
>    already lives.
>
> **Render still beats this for repeated work.** `dispatch` is per-call and the
> id is resolved by hand each time; `render` writes the binding into the agent
> files once and every later plain dispatch picks it up. Use `dispatch` when you
> want one seat on its configured model now, or cannot restart the session.

4. **`render`** — render `.claude/agents/op-*.md` from the templates + the
   resolved tier config:

   ```
   bash "${CLAUDE_PLUGIN_ROOT}"/scripts/ops-render.sh
   ```

5. **`revert`** — remove the project-layer agents (fall back to plugin-root):

   ```
   bash "${CLAUDE_PLUGIN_ROOT}"/scripts/ops-render.sh --revert
   ```

6. **`check`** — render to a temp dir + liveness-probe each model id; write
   nothing. Use before `render` to catch a typo'd or dead id:

   ```
   bash "${CLAUDE_PLUGIN_ROOT}"/scripts/ops-render.sh --check
   ```

**`render` and `revert` require a session restart to take effect** — agent
files are read at session start, not reloaded mid-session. The scripts say so in
their output; relay that line. If `$CLAUDE_CODE_SUBAGENT_MODEL` is set it
OVERRIDES the rendered binding at dispatch (spec M7) — the renderer warns; relay
that too and tell the operator to unset it.

**Ownership:** rendered files carry a `rendered-by: cc-operator ops-render`
marker line; `render` and `revert` delete ONLY marked files. A hand-authored
`.claude/agents/op-*.md` is never deleted — and if it sits at a seat's own
target name, `render` refuses (non-zero exit) rather than overwrite. Relay the
"kept (not renderer-owned)" line when the script prints it.

Any other `$ARGUMENTS` — print the `argument-hint` and stop.

The four tiers: `JUDGMENT` (opus-class review/verdict), `IMPLEMENT`
(sonnet-class authoring), `MECHANICAL` (cheap lenses, crawls, generation),
`RECON` (haiku-class search). Rationale: `docs/TAGS.md` (`spec-wf`,
`spec-D2`) — the original orchestration-design spec files were never
committed and exist in no checkout (audit F111).
