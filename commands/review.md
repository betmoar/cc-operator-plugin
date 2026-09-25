---
description: Run the review workflow over an artifact — parallel narrow lenses then an adversarial verifier — with the tier bindings resolved for you.
argument-hint: "<path> [more paths] [--isolate <sha>]"
allowed-tools: Bash(bash "${CLAUDE_PLUGIN_ROOT}"/scripts/ops-tiers.sh:*), Workflow
---

Review `$ARGUMENTS` with the review workflow. Two steps; the first is what this
command exists for.

1. **Resolve the tier bindings.** One line of JSON, exactly the shape
   `args.tiers` takes:

   ```
   bash "${CLAUDE_PLUGIN_ROOT}"/scripts/ops-tiers.sh --json
   ```

   Pass it through verbatim. Do NOT retype it, and do NOT skip this step
   because the defaults "look right": the defaults are harness aliases, so
   skipping it silently runs every lens on an Anthropic model while the
   operator's `tiers.env` says otherwise (the render warning in
   `/cc-operator:tiers` describes the same footgun).

2. **Dispatch:**

   ```
   Workflow({ name: "cc-operator:review", args: {
     target: "<the path(s) from $ARGUMENTS>",
     doneMeans: "<the task text the DONE criteria came from>",
     tiers: <the JSON from step 1> } })
   ```

   `doneMeans` is not optional in practice: the spec and testability lenses ask
   about the task, and without it they review the artifact against nothing. If
   you cannot state it, say so rather than dispatching a panel that will answer
   a question you did not ask.

   For release-bound work, commit first and add `isolate: "<sha>"` — the
   adversarial seat then runs in a fresh worktree. Read what that buys in the
   workflow's own `whenToUse`: a clean TREE, not a clean machine, and the
   worktree is created at the DEFAULT BRANCH unless you also pass
   `isolateCheckout: true`.

**A REFUTED verdict is a hard stop and cannot be outvoted.** Relay the panel's
findings and the adversarial verdict as they come back; do not summarize a
REFUTED into a list of concerns.


**Where the result goes.** Findings that change code become verdict rows and
commits, not a document. A panel report the user wants to read or share can be
published as an artifact when this session has a tool for it; ask once
per session, and never let the published copy replace the ledger row.
