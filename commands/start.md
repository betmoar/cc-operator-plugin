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

   This creates `.operator/VERDICTS.md`, `.operator/DECISIONS.md`,
   `.operator/pending/`, `.operator/verdicts.d/`, and `.operator/.gitattributes`
   in the project root, and installs the gate CLIs into `.operator/bin/`.

2. **Materialize the charter.** Read
   `${CLAUDE_PLUGIN_ROOT}/templates/OPERATOR.md` and Write its content
   verbatim to `OPERATOR.md` in the project root (overwrite any prior copy —
   it is a generated artifact, not hand-edited). Use the Read and Write tools;
   `cp` is not in this command's allowed tools.

3. **Point CLAUDE.md at it** (default), or **inline it** (`--inline`):

   - **Default:** if `CLAUDE.md` does not already contain `@OPERATOR.md`, append
     this stanza to `CLAUDE.md` (create the file if absent). Grep-guard first so
     re-running never duplicates it:

     ```
     ## Operator
     @OPERATOR.md — it is this session's operating charter.
     ```

     The `@OPERATOR.md` form is a CLAUDE.md **import**: Claude Code loads the
     referenced file's content into context on every CLAUDE.md load, so the
     charter re-injects deterministically after a compaction — without relying on
     the operator choosing to re-read it. (A bare `Read OPERATOR.md` prose line
     does NOT import; it only persists if the operator elects to read the file.
     Phase-1 pilot evidence: the prose form survived compaction only via the
     operator's agency; `@import` removes that dependency.)

   - **`--inline`** (`$ARGUMENTS` contains `--inline`): instead of the pointer,
     append the full contents of `OPERATOR.md` under a `## Operator` heading in
     `CLAUDE.md`. Grep-guard on the `## Operator` heading so a re-run does not
     append a second copy. (This is the P5 fallback path — inline is the exact
     proven-persistent configuration; the `@import` pointer above is the
     lighter-weight equivalent whose persistence Phase 1 A/B compares against it.)

4. **Print the next step.** Output one line confirming init, and: "Charter
   active. Before your first non-trivial task, append a BAR block to
   `.operator/VERDICTS.md` per OPERATOR.md § ENGAGEMENT CONTRACT."
