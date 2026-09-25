---
description: Run the brainstorm workflow — N divergent directions, a blindspot scan of this codebase, and a reference search, converged into ranked options and the questions only you can answer.
argument-hint: "<topic — one or more sentences>"
allowed-tools: Bash(bash "${CLAUDE_PLUGIN_ROOT}"/scripts/ops-tiers.sh:*), Workflow
---

Explore `$ARGUMENTS` with the brainstorm workflow, before a spec exists.

1. **Resolve the tier bindings** — one line of JSON, passed through verbatim:

   ```
   bash "${CLAUDE_PLUGIN_ROOT}"/scripts/ops-tiers.sh --json
   ```

2. **Dispatch:**

   ```
   Workflow({ name: "cc-operator:brainstorm", args: {
     topic: "<the full topic text from $ARGUMENTS — every word of it>",
     context: "<what this codebase already does that the design must fit>",
     directions: 4,
     tiers: <the JSON from step 1> } })
   ```

   **Pass the topic in full.** A four-thousand-character brief once evaporated
   in transit and the whole fan-out ran against a placeholder — seven agents,
   123,935 tokens, every seat answering that it could not propose a direction
   without a topic (#92). The normalizer that caused it is fixed; the habit of
   summarizing the brief into a phrase reproduces the same result honestly.

3. **Then interview, one question at a time.** The bundle comes back with
   `openQuestions` already ordered by architectural blast radius. Ask the first,
   wait, ask the next. Do not present all of them at once and do not answer them
   yourself — they are the decisions the workflow could not make.

4. **Write the answers down.** The approved direction is the input to the plan
   workflow, and today nothing carries it there but you: a design that lives
   only in this conversation does not survive a compaction (`docs/design/CYCLE.md` §2).

5. **Where the result goes.** The workflow returns data and has no filesystem or
   publishing tool, so the destination is yours to choose (#75). Ask the user
   ONCE per session, not per run: a brainstorm bundle is read once by a human
   and then acted on, so it suits an artifact or shared document when this
   session has a tool that publishes one; otherwise answer inline. The approved
   DIRECTION is different — it goes into the spec (`/cc-operator:spec`), because
   it is an input to later work and belongs in git.
