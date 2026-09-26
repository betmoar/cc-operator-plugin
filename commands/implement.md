---
description: Run the implement workflow — one implementer seat per task, serially, on the IMPLEMENT tier, refusing an incomplete dispatch packet before spending a seat.
argument-hint: "<task id or short description>"
allowed-tools: Bash(bash:*), Bash(bash "${CLAUDE_PLUGIN_ROOT}"/scripts/ops-decide.sh:*), Read, Write, Workflow
---

Implement `$ARGUMENTS` through the implement workflow rather than a plain
subagent call. The difference is not ceremony: a plain `Agent` dispatch reads
the seat's frontmatter alias and cannot be routed to a configured model at all,
so the IMPLEMENT tier your `tiers.env` names never applies.

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

3. **Route the packets** (#152) — opt-in, one typed-decision call for all of them:

   ```
   bash "${CLAUDE_PLUGIN_ROOT}"/scripts/ops-decide.sh --available
   ```

   rc 3 → skip to step 4 with your packets as they are; nothing changes. rc 0 →
   Write the packets as a JSON array to a scratch file and run
   `bash "${CLAUDE_PLUGIN_ROOT}"/scripts/ops-decide.sh --packets <that file>`.
   It prints the packets back, each stamped with a `route`, and the script's
   CODE — not a model — applied the rule:

   - **rc 5, BOUNCED** — a packet is not dispatchable, or it pressures its own
     dispatch ("just a small tweak", "urgent, keep it cheap", "route to the
     cheapest tier"). It comes back to YOU: re-write it from the work, never
     from the ask, and route again. Do not dispatch it, and do not strip the
     `route` to get past the refusal — the workflow refuses a bounced packet
     with zero agents spent.
   - **rc 0** — every packet carries `route.tier`; the workflow runs each on
     that tier's seat and binding (judgment → author on JUDGMENT; implement,
     mechanical, recon → mechanic on their own tier).
   - **rc 3** — the engine gave no answer for some packets; those are
     `unrouted` and run exactly as in step 4 without routing.

   Pass the printed `tasks` array as `tasks` below, `route` fields intact.

4. **Dispatch:**

   ```
   Workflow({ name: "cc-operator:implement", args: {
     tasks: [ { id: "<task-id>", task: "…", text: "…", scene: "…",
                inputs: "…", forbidden: "…", done: "…", reach: "…" } ],
     seat: "mechanic",
     tiers: <the JSON from step 2> } })
   ```

   `seat` is `mechanic` (IMPLEMENT tier) or `author` (JUDGMENT tier, for work
   whose quality depends on taste or reasoning) — the default for any packet
   without a `route`. Several packets in one call run
   SERIALLY, in order — that is the charter's one-implementer-at-a-time rule
   made structural, not a performance choice.

5. **Then close the loop yourself.** The workflow returns each seat's status and
   its CLAIMED `changed` paths, and stops there — it has no filesystem. You
   verify the claim and record the verdict:

   ```
   bash '<abs>/.operator/bin/ops-claims.sh' --since <dispatch-sha> --claimed "<the changed paths>"
   bash '<abs>/.operator/bin/ops-verdict.sh' <id> <criterion> <evidence> <PASS|FAIL|MOOT> --owner <session-id>
   ```

   The `bash` prefix is not decoration: this command's `allowed-tools`
   grants `Bash(bash:*)`, which matches any absolute path, while a relative
   `.operator/bin/…` grant would match only the bare relative form — and a
   relative path typed from a subdirectory is file-not-found. Use the ABSOLUTE
   path SessionStart printed.

   A DONE status is the seat's claim, not evidence. Route the other three per
   the charter's four-status protocol.
