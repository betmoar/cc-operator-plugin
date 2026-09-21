---
description: Write, check and approve the engagement's spec — the artifact that carries an approved design from brainstorm into plan, with a source stamp and a ledger row.
argument-hint: "<slug> [--approve]"
allowed-tools: Bash(bash:*), Bash(git:*), Read, Write, Edit
---

Drive the spec stage for `$ARGUMENTS`. The spec is the one artifact that
survives a compaction between divergence and planning — everything else in that
handoff is prose in your context.

**Resolve the CLI path first.** Use the ABSOLUTE, single-quoted path
SessionStart printed for the gate CLIs (`.operator/bin/ops-spec.sh` under the
project root it named). The Bash tool's cwd persists across calls, so a
relative path typed from a subdirectory is file-not-found — and the field
history for that shape is the model then reporting a PRESENT gate as absent.

1. **Scaffold**, unless the spec already exists:

   ```
   bash '<abs>/.operator/bin/ops-spec.sh' --new <slug>
   ```

2. **Fill it in — by interview, not by invention.** If a brainstorm bundle is
   in hand, its `openQuestions` are already ordered by architectural blast
   radius: ask the human the first, wait for the answer, then the next. Record
   each answer in the Open questions table with who decided it. A question you
   answered yourself is not resolved; it is a decision you made on their
   behalf, and the table has a column that says so.

   Three fields carry weight and the checker enforces all three:

   - **North star** — one sentence plus a `Missed if:` clause. **This must be
     the same sentence the BAR block and the plan workflow use.** Approving is
     what makes that true: it emits the BAR block FROM this file, so the two
     stop being two hand-written sentences that drift.
   - **Done criteria** — each a command and its expected output. A criterion
     with no command is one nobody outside this session can reproduce.
   - **Open questions** — every Resolution cell filled before approval.

3. **Check** — writes nothing, so run it as often as you like:

   ```
   bash '<abs>/.operator/bin/ops-spec.sh' --check <slug>
   ```

4. **Approve** (only when the human has answered the open questions):

   ```
   bash '<abs>/.operator/bin/ops-spec.sh' --approve <slug> --owner <session-id>
   ```

   That stamps `Status: APPROVED @<source-state>` with the same ladder the
   ledger uses (`@<sha>`, `+dirty`, `@no-commit`, `@no-vcs`), logs a
   `SPEC-APPROVED` line to DECISIONS.md, and appends the **BAR block** to
   VERDICTS.md — the ceremony the charter requires before your first
   implementation action, written from the spec instead of by hand.

   Read the stamp for what it is: it says *this spec was approved against that
   tree*, never *that tree satisfies this spec*.

Then run `/cc-operator:plan <slug>`, which refuses an unapproved spec and takes
its north star from this file.
