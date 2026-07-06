---
description: Run at the start of a session you will operate as chief operator — orchestrating an engagement, gating on evidence, or driving multi-step work to a verified done-state.
argument-hint: [--inline]
allowed-tools: Bash(bash:*), Bash(grep:*), Read, Write, Edit
---

Set this project up to be run under the operator charter. Do the steps below;
do not restate the charter's contents — it is authored in the template and
copied verbatim.

1. **Initialize the ledgers.** Run the init script (idempotent — safe to
   re-run; it never clobbers existing ledger content):

   ```
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/ops-init.sh"
   ```

   This creates `.operator/VERDICTS.md`, `.operator/DECISIONS.md`, and
   `.operator/pending/` in the project root.

2. **Materialize the charter.** Copy `${CLAUDE_PLUGIN_ROOT}/templates/OPERATOR.md`
   into the project root as `OPERATOR.md` (overwrite any prior copy — it is a
   generated artifact, not hand-edited).

3. **Point CLAUDE.md at it** (default), or **inline it** (`--inline`):

   - **Default:** if `CLAUDE.md` does not already contain the line
     `Read OPERATOR.md`, append this stanza to `CLAUDE.md` (create the file if
     absent). Grep-guard first so re-running never duplicates it:

     ```
     ## Operator
     Read OPERATOR.md — it is this session's operating charter.
     ```

   - **`--inline`** (`$ARGUMENTS` contains `--inline`): instead of the pointer,
     append the full contents of `OPERATOR.md` under a `## Operator` heading in
     `CLAUDE.md`. Grep-guard on the `## Operator` heading so a re-run does not
     append a second copy. (This is the P5 fallback path — inline is the exact
     proven-persistent configuration; the pointer is what Phase 1 A/B tests.)

4. **Print the next step.** Output one line confirming init, and: "Charter
   active. Before your first non-trivial task, append a BAR block to
   `.operator/VERDICTS.md` per OPERATOR.md § ENGAGEMENT CONTRACT."
