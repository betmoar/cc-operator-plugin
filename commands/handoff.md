---
description: Run when ending an operated engagement or session — to produce the structured operator→human handoff before you stop or hand off.
argument-hint: []
allowed-tools: Bash(git:*), Bash(.operator/bin/ops-verdict.sh:*), Read, Write
---

Produce the six-section operator→human handoff. Source every claim from
`.operator/VERDICTS.md`, `.operator/DECISIONS.md`, and `git log` — never from
memory. Write it to `.operator/handoff-<today's date>.md`. The section shape is
defined in `OPERATOR.md § HANDOFF`; produce exactly those six sections:

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
