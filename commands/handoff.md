---
description: Run when ending an operated engagement or session — to produce the structured operator→human handoff before you stop or hand off.
argument-hint: []
allowed-tools: Bash(git:*), Bash(bash:*), Bash(.operator/bin/ops-verdict.sh:*), Read, Write
---

Produce the six-section operator→human handoff. Source every claim from the
project's `.operator/VERDICTS.md`, `.operator/DECISIONS.md`, and `git log` —
never from memory. Write it to `.operator/handoff-<today's date>.md`. The
section shape is defined in `OPERATOR.md § HANDOFF`; produce exactly those six
sections:

1. **Verdict** — shipped / not-shipped / partial, against the BAR block in
   VERDICTS.md, as one table.
2. **Banked** — what holds regardless of the verdict, each item ledger-cited.
3. **Unverified / open** — the explicit not-accomplished list, each line naming
   what command or check would verify it.
4. **Conditional next steps** — each with an entry condition that must be
   checked before starting it.
5. **Stop conditions** — when *not* to continue.
6. **Not-doing** — explicit anti-scope.

Do not restate the charter. If a required fact is absent from the ledgers or
git log, write it under section 3 (Unverified) rather than asserting it.

**Resolve the paths before you run anything.** Do not assume your shell sits at
the project root — the Bash tool's cwd persists across calls, so a relative
`.operator/bin/...` typed from a subdirectory is file-not-found, and the field
history for that shape (#94/#95, audit F102) is the model then reporting a
PRESENT gate as absent. Use the ABSOLUTE, single-quoted CLI path that
SessionStart already printed in this session's context ("this session's id
is …"), or the one the Stop hook named when it last blocked. If neither is in
context, resolve it yourself: walk UP from your cwd to the nearest ancestor
holding `.operator/` — that is the project root the gate CLIs and the Stop hook
resolve to (they stop at a `.git` boundary and at `/`). In a git checkout
`git rev-parse --show-toplevel` usually names it, but it is not the rule: a
project need not be a git repository (the ledger stamps `@no-vcs` for those),
and `.operator/` may sit above a nested repo's toplevel. The ledgers you read
are under the same `.operator/`, so the directory you found them in is the
answer.

Presenting this handoff clears the deviation gate: after writing the six
sections, run that absolute path with
`ops-verdict.sh --mark-handoff --owner <session-id>`, invoked as
`bash '<absolute path>' --mark-handoff --owner <session-id>`. The `bash`
prefix is not decoration: this command's `allowed-tools` grants
`Bash(bash:*)`, which matches any absolute path, while the relative
`.operator/bin/…` grant beside it matches ONLY the bare relative form and
cannot be written absolute (the prefix is machine-specific). Without
`bash` in front, an absolute invocation falls outside every grant and you hit
a permission prompt this frontmatter exists to avoid. That stamps a
HANDOFF-MARK in DECISIONS.md so the Stop hook stops blocking on this session's
DEVIATION lines (any you logged with a leading `[sid:<session-id>]` tag in the
what-cell). An untagged DEVIATION is unowned and blocks every session — tag the
ones you author with your session id (from SessionStart).
