# frag-traversal — parsed field becomes a path component

**Defect:** `vuln.sh` line 30 — `"$LEDGER/verdicts.d/$owner.frag"`, where
`$owner` was parsed out of a file the script does not control.

**Why the input is untrusted.** A sentinel body is an ordinary file. A merge, a
checkout, a patch, or a second session can supply one. The real instance of this
in this repo shipped in 0.3.0 and was closed in 0.4.0; it was found by
hand-audit, not by review, because the panel did not exist yet.

**Impact.** Write outside `.operator/` at the privilege of whoever runs the
gate — which, for the SessionStart and Stop hooks, is every session start. An
absolute owner (`session_id: /etc/whatever`) is the same hole with a shorter
path.

## What each existing lens would say, and why it is not a detection

| lens | its question | verdict on this file |
| --- | --- | --- |
| `spec` | what did the task text ask for that is missing / present but unasked | nothing missing — a fragment writer that writes fragments |
| `testability` | the observable acceptance criterion per requirement | one exists and passes: `probe.sh` FUNCTIONAL: ok |
| `feasibility` | do the load-bearing claims hold against the code | the comments claim it writes a fragment named for the owner; it does |
| `quality` | craft and project conventions | reads well, guards its inputs, checks every write |
| `correctness` | logic errors, unhandled cases, **missing validation** | the nearest miss. Validation is *present* — an empty owner is refused, a missing sentinel is refused, the write status is checked. A reader asking "is anything unvalidated" finds validation everywhere they look |

The adversarial seat re-runs the stated done-criteria. Those are satisfied.

**A detection must say:** that `$owner` reaches a path expression without a
bare-name/separator check, i.e. it must name the *dataflow* from the parsed
field to the filename — not "consider validating input", which is equally true
of `fixed.sh` and therefore measures nothing.

## Measured — this prediction did not hold

The table above is what I expected the panel to say. It was then run (`../MEASUREMENT.md`, 2026-08-15) and **both judgment-tier lenses detected this defect at the mechanism level**. The prediction was wrong for feasibility and quality; it held for the cheap tier. The table is kept as written rather than rewritten to match the result — a hypothesis edited after its own experiment is not a hypothesis.
