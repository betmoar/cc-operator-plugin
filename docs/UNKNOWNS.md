# UNKNOWNS — how the register works

**The register of record is GitHub issues, not this file.**

Open unknowns live at
[`label:unknown`](https://github.com/betmoar/cc-operator-plugin/issues?q=is%3Aissue+label%3Aunknown)
and [`label:residual`](https://github.com/betmoar/cc-operator-plugin/issues?q=is%3Aissue+label%3Aresidual).
This file holds the *convention* — what an entry must contain and how one is
closed — and deliberately holds **no status**.

That split is B1's rule applied to ourselves: the moment status lives in two
places, one of them is wrong and nothing says which. A markdown table of open
unknowns would drift the day after it was written, silently, which is precisely
the failure B11's register-audit was designed to detect. Using issues removes the
need for that audit rather than automating it.

## Why issues rather than a document

Two problems this repo had already written down dissolve on contact with the
issue tracker:

- **Section membership.** B11 needed to know whether an entry was open or closed,
  and freeform markdown has no such field — the audit would have had to invent a
  convention and then police it. An issue's **state** is that field, maintained by
  the interface itself.
- **The priority grammar.** The unknown "we now own a p1–p5 status field and have
  never defined it" (#16) is answered for the register by GitHub's **labels**.
  Nothing to specify, nothing to parse.

The ledger keeps its job: issues carry the *question*, `.operator/VERDICTS.md`
carries the *evidence*. Neither duplicates the other.

## Labels

| Label | Meaning |
|---|---|
| `p0` | Blocker — resolve before the next merge/release |
| `p1` | High — schedule into the current slice |
| `p2` | Medium — scheduled, not urgent |
| `p3` | Low — do when the area is touched anyway |
| `p4` | Backlog — no scheduled slice |
| `p5` | Won't-do unless evidence changes |
| `unknown` | An open unknown: what is not known, and what would close it |
| `residual` | Understood and deliberately unfixed — recorded, not tracked as a bug |
| `measured` | Answered by a number, including uncomfortable ones |

`residual` and `measured` are not lesser states. A residual is a decision with its
reasoning attached; a measurement that violates its own bound (#15) is worth more
than a bound nobody checked.

## What an entry must contain

Four fields, because an unknown without them is an anxiety, not a work item:

1. **What is unknown** — stated so it could be wrong.
2. **Why it is not already answered** — usually the interesting part; if the
   reason is "nobody looked", say that.
3. **What would close it** — a *command* and the output that would settle it.
   The charter's rule is the register's rule: a row without evidence is FAIL by
   definition [D:CHART-def]. "We considered it" closes nothing.
4. **Until then** — what must not be claimed while it is open. This is the field
   that stops an open unknown from being quietly ignored in a release note.

## Closing an entry

1. Run the command in **What would close it**; capture the output.
2. Record a verdict row citing that output:
   `.operator/bin/ops-verdict.sh <id> <criterion> <evidence> PASS|FAIL --owner <sid>`
3. Close the issue **with the verdict row quoted in the closing comment.**

Do not close on reasoning alone, and do not delete an entry that turned out to be
a non-issue — close it with the evidence that made it one. The next reader needs
to know the question was asked and how it was settled; a disappeared unknown is
indistinguishable from one nobody thought of.

## Related registers

- `docs/spec/backlog-charter.md` §8 — per-claim residuals for that spec (what a
  green suite does *not* prove). Local-only; `docs/spec/` is gitignored wholesale.
- `docs/LANDMINES.md` — already-hit failure classes, the backward-looking twin of
  this register.
- `.operator/VERDICTS.md` — the evidence ledger. An unknown closes here first and
  on GitHub second.
