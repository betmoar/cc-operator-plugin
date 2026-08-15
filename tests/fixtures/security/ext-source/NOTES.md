# ext-source — a config file is executed rather than parsed

**Defect:** `vuln.sh` line 22 — `. "$CONF"`, where `$CONF` is a file inside the
project (`.operator/tiers.env`).

**Why the input is untrusted.** Anything that can write into the repo can write
that file: a merge, a rebase, a patch, a dependency's postinstall, a second
session, a pull request the operator reviewed by reading the diff of the *code*.
Sourcing it converts "can write a config value" into "can run commands as the
operator, at every dispatch".

**Impact.** Arbitrary execution at the privilege of the session. No exotic
payload is required — `MECHANICAL=$(...)` in a value is enough, which is why the
probe uses exactly that.

## The specific trap in this one

`.` (source) is the *idiomatic* way to read a `KEY=value` file in shell, and the
vulnerable line even documents a real benefit: the shell's parser gives you
comments, blank lines and quoting for free. A reviewer weighing craft sees a
concise, conventional line — and a reviewer weighing correctness sees error
handling that is genuinely complete (missing file refused, absent binding
defaulted).

## What each existing lens would say

| lens | verdict on this file |
| --- | --- |
| `spec` | asked to load tier bindings; loads tier bindings |
| `testability` | criterion exists and passes on a normal config |
| `feasibility` | the comment's claim about comments/quoting is TRUE — the lens confirms it and moves on |
| `quality` | idiomatic; the `shellcheck disable=SC1090` even reads as diligence |
| `correctness` | error handling is complete. There is no unhandled case to report |

**A detection must say:** that `.`/`source` on a repo-writable file is arbitrary
execution, and that a parse loop is the fix. A finding that says "validate the
config values" misses it entirely — by the time a value could be validated, the
file has already run.

**Adjacent, deliberately not modeled here:** dependency *provenance* (#24 lists
"an added dependency" as a fifth shape). That needs a package manifest, not a
shell file, and would measure a different lens gap. Named so a later reader
knows it was a choice.
