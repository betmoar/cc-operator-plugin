# doc-regex-table — modeled on #70 round-2 instances 11/12 (user-facing doc quoting a deleted regex)

**Claim (drifted/tiers.md, table row 3):** "check the id against cc-proxy
routability (`^glm-|/|^claude-`) — that regex is the validation."

**The code that falsifies it:** `ops-tiers.sh`'s `check_routable` contains
no such regex. Per the real PR #71 change (0.8.3, documented in
`CLAUDE.md`'s coupling table under "the model-id guard"), the id-shape
catalogue and `^glm-|/|^claude-` provider allowlist were deliberately
removed — the guard now judges well-formedness ONLY (no whitespace, no
quotes, non-empty) via `BAD_CHARSET`. The doc table row quotes the deleted
regex **verbatim** as if it still runs. This is the sharpest sub-case #70
calls out: "user-facing documentation... acted on" — a user reading this
row believes their model id will be checked against that specific pattern
and picks/debugs accordingly, when the real check is charset-only.

**true/tiers.md** states the current mechanism ("check the id is
well-formed... that is the only validation; the id shape is not judged"),
matching `ops-tiers.sh` exactly. Both `.sh` files are byte-identical; only
the doc's step-3 cell differs between `drifted/` and `true/`.

**Which lens should have caught it and why it does not:** `commands/tiers.md`
is not code under review in a typical diff that touches `ops-tiers.sh` — it
is a sibling doc file. #70's own writeup names this precisely: "instances
11-15 and 20 are claims in `commands/tiers.md`, `README.md`,
`PLAYBOOK.md`... files whose own code did not change. They are not claims
*in* the artifact; they are claims *about* the artifact, living somewhere
else." `feasibility` ran on the real PR #71 diff in round 1 and reported
none of these — its brief only reaches claims within the file(s) actually
in the diff, not doc files elsewhere in the tree quoting old behavior.
`correctness` explicitly does not judge spec fit; `quality` reviews craft,
not fact-checking against a different file's guard logic; `spec`/
`testability` have no mechanism to check documentation against
implementation at all.

**What a correct detection must name to count as detected:** the specific
stale fact — "the doc quotes `^glm-|/|^claude-` as the validation regex;
`ops-tiers.sh`'s `check_routable` has no such regex, only a `BAD_CHARSET`
well-formedness check" — not a generic "verify docs match code," which is
equally true of `true/tiers.md` and would false-positive there.

**Functional-identity verification:** `ops-tiers.sh` is byte-identical
between `drifted/` and `true/` (confirmed: only `tiers.md`'s table row 3
differs). Diffed directly:

```
$ diff tests/fixtures/drift/doc-regex-table/drifted/ops-tiers.sh tests/fixtures/drift/doc-regex-table/true/ops-tiers.sh
(no output — identical)
$ diff tests/fixtures/drift/doc-regex-table/drifted/tiers.md tests/fixtures/drift/doc-regex-table/true/tiers.md
8,9c8,9
< check the id against cc-proxy routability...
---
> check the id is well-formed...

## Measured 2026-08-16

The prediction above said `commands/tiers.md` is a sibling doc file, not code
under review in a typical diff touching `ops-tiers.sh`; that `feasibility`
ran on the real PR #71 diff and reported none of these, because its brief
only reaches claims within the file(s) actually in the diff, not doc files
elsewhere in the tree; and that `correctness`/`quality`/`spec`/`testability`
have no mechanism to check documentation against implementation at all.

What actually happened (per `tests/fixtures/drift/MEASUREMENT.md`, drifted
column): `testability` **85**, `feasibility` **88**, `quality` **88**,
`correctness` **58**, `spec` **—**. `feasibility`'s 88 and `quality`'s 88 are
each lens's highest score across all six fixtures in this run.

The prediction was **wrong**, on the same specific point as
`agenttype-anchor`: `feasibility` was predicted to miss a claim about a
different file's mechanism (here, a doc claiming a regex that lives, or no
longer lives, in `ops-tiers.sh`), and instead scored its single best result
of the run on exactly that shape.

What still holds: the historical fact that `feasibility` ran on the real PR
#71 diff and reported none of these is untouched — that is a fact about that
one prior run, not a re-testable claim here. What does not hold is the
inference drawn from it: that the lens's brief structurally "only reaches
claims within the file(s) actually in the diff." In this fixture, both
`tiers.md` and `ops-tiers.sh` were present for the seat to read, and it
evidently did read both and compared them — so the limitation was a property
of what the real PR's diff happened to include, not a structural blind spot
in the prompt.
```
