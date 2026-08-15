# guard-two-of-three — the guard is correct; a call site is missing

**Defect:** `vuln.sh` — `check_bare_name` is defined once, is correct, and is
called by `open` and `close`. `adopt` does not call it, and writes
`"$DIR/pending/$ID"` at line 47.

This is the fixture that matters most, and the reason is structural rather than
severity: **the defect is not in any line a reviewer reads as suspicious.** The
guard is not weak, not duplicated, not drifted. Nothing is unvalidated in the
place a reader looks for validation. The defect is an absence at a third
location, and finding it requires enumerating the call sites of a guard and
diffing that set against the sites that need it.

This repo's most-repeated bug is exactly this shape (F30 — the reason
`check_guard_parity` exists in `validate_plugin.py`, pinning the reject set
across five sites rather than trusting copy parity). When the guard in question
is a traversal guard, the shape is a security bug.

## The excuse in the code

`vuln.sh` carries the real-world justification verbatim:

> The id was already checked when the task was opened, so it is a known-good
> name by the time it reaches this path.

That sentence is true of a well-behaved caller and false as an invariant.
`adopt` is a subcommand — it is directly reachable, with no `open` before it.
"Checked upstream" is a claim about a call graph nobody verified.

## What each existing lens would say

| lens | verdict on this file |
| --- | --- |
| `spec` | three subcommands asked for, three delivered |
| `testability` | every subcommand has an observable criterion, all pass |
| `feasibility` | **the closest any lens gets.** Its job is to check load-bearing claims against the code, and the comment's "already checked when opened" IS a load-bearing claim. Whether it fires depends on the lens treating an inline justification as a claim worth tracing — the wording says "claims in the artifact", which a reader may take to mean the prose/doc claims, not code comments |
| `quality` | consistent style, one guard definition, no duplication — arguably *praises* the single-definition structure |
| `correctness` | "missing validation" is literally the defect, but the lens runs at MECHANICAL tier and the file's validation is visibly present twice. Detecting this requires call-site enumeration, not local reading |

**A detection must say:** that `adopt` reaches the path expression without
`check_bare_name`, naming the asymmetry against `open`/`close`. A finding that
says "validate inputs in this script" is wrong on the facts — two of three sites
already do — and scores identically against `fixed.sh`.
