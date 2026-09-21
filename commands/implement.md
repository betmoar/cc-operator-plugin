---
description: Run the implement workflow — one implementer seat per task, serially, on the IMPLEMENT tier, refusing an incomplete dispatch packet before spending a seat.
argument-hint: "<task id or short description>"
allowed-tools: Bash(bash:*), Workflow
---

Implement `$ARGUMENTS` through the implement workflow rather than a plain
subagent call. The difference is not ceremony: a plain `Agent` dispatch reads
the seat's frontmatter alias and cannot be routed to a configured model at all,
so the IMPLEMENT tier your `tiers.env` names never applies (#158).

1. **Build the packet.** Every field is required and the workflow refuses the
   whole run — zero agents dispatched — if any is missing:

   - `task` — what to do, in one line.
   - `text` — the full task text. Not a summary.
   - `scene` — where this sits: the files, the surrounding design, what already
     exists.
   - `inputs` — the paths the seat may read.
   - `forbidden` — what it must not touch. Gate files are off-limits unless the
     task IS the gate.
   - `done` — the criteria, as a command and its expected output where possible.
   - `reach` — the shipped entry point this is reached from, plus the grep or
     trace proving the path.

2. **Resolve the tier bindings** — one line of JSON, passed through verbatim:

   ```
   bash "${CLAUDE_PLUGIN_ROOT}"/scripts/ops-tiers.sh --json
   ```

3. **Dispatch:**

   ```
   Workflow({ name: "cc-operator:implement", args: {
     tasks: [ { id: "<task-id>", task: "…", text: "…", scene: "…",
                inputs: "…", forbidden: "…", done: "…", reach: "…" } ],
     seat: "mechanic",
     tiers: <the JSON from step 2> } })
   ```

   `seat` is `mechanic` (IMPLEMENT tier) or `author` (JUDGMENT tier, for work
   whose quality depends on taste or reasoning). Several packets in one call run
   SERIALLY, in order — that is the charter's one-implementer-at-a-time rule
   made structural, not a performance choice.

4. **Then close the loop yourself.** The workflow returns each seat's status and
   its CLAIMED `changed` paths, and stops there — it has no filesystem. You
   verify the claim and record the verdict:

   ```
   bash '<abs>/.operator/bin/ops-claims.sh' --claimed "<the changed paths>"
   bash '<abs>/.operator/bin/ops-verdict.sh' <id> <criterion> <evidence> <PASS|FAIL> --owner <session-id>
   ```

   The `bash` prefix is not decoration (#104): this command's `allowed-tools`
   grants `Bash(bash:*)`, which matches any absolute path, while a relative
   `.operator/bin/…` grant would match only the bare relative form — and a
   relative path typed from a subdirectory is file-not-found. Use the ABSOLUTE
   path SessionStart printed.

   A DONE status is the seat's claim, not evidence. Route the other three per
   the charter's four-status protocol.
