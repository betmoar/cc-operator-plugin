# tier-split-meta — modeled on #70 instance 3

**Claim (drifted/review.mjs `meta.description`):** "most at cheap tiers and
two at judgment: feasibility and quality."

**The code that falsifies it:** the `LENSES` table has `correctness` at
`"judgment"` tier too — three judgment-tier lenses (feasibility, quality,
correctness), not two, and two cheap-tier (spec, testability), not "most."
This mirrors the real instance: `correctness` moved to judgment tier (per
`docs/audit-2026-08-09-handoff.md`'s 0.8.3-era tier arm) and the
`meta.description` in `workflows/review.js` was not updated to match — found
by F40's own cost-contract test, not by a review lens.

**true/review.mjs** states "two at cheap tiers and three at judgment...
feasibility, quality, and correctness" against the identical `LENSES` array.
The table is byte-identical between the two files; only the description
string and its wrapping comment differ.

**Which lens should have caught it and why it does not:** `spec` asks what
the task text asked for — a `meta.description` field is not task text, it is
the artifact describing itself, so `spec` has no claim to check it against.
`testability` wants an observable acceptance criterion per requirement, not
a count of tiers. `feasibility`, the nearest miss, checks load-bearing
claims "in the artifact" against "the actual code" — this claim and the
code it describes are in the SAME file, the easiest version of this
problem, yet the real instance was caught by a cost-contract unit test
(F40), not by any review lens, meaning the measured panel run over this
exact shape did not report it. `quality`/`correctness` do not read
`meta.description` as a target at all — it is metadata, not logic.

**What a correct detection must name to count as detected:** the count
mismatch by name — "description says two judgment-tier lenses (feasibility,
quality); the table has three (feasibility, quality, correctness)" — not a
generic "verify the description matches the code," which is equally true of
`true/review.mjs` and would false-positive there.

**Functional-identity verification:** `LENSES` is byte-identical between
`drifted/review.mjs` and `true/review.mjs`; only the `meta.description`
string differs. Diffed directly:

```
$ diff tests/fixtures/drift/tier-split-meta/drifted/review.mjs tests/fixtures/drift/tier-split-meta/true/review.mjs
1,6c1,6
< // meta.description: "Runs five lenses, most at cheap tiers and two at
...
```
confirms only the description/comment lines change; `export const LENSES`
is untouched.

## Measured 2026-08-16

The prediction above said `feasibility` is the nearest miss — checking the
same-file claim against the code, the easiest version of this problem — yet
the real instance was caught by a unit test (F40), not any review lens, and
that `spec`/`testability`/`quality`/`correctness` do not read `meta.description`
as a target at all.

What actually happened (per `tests/fixtures/drift/MEASUREMENT.md`, drifted
column): `testability` **70**, `feasibility` **74**, `quality` **72**,
`correctness` **57**, `spec` **—**. Four lenses detected it.

The prediction was **wrong**. It predicted `feasibility` as a "nearest miss"
still likely to miss, and it detected at 74; it also predicted `testability`,
`quality`, and `correctness` would not treat `meta.description` as a target
at all, and all three detected it.

What still holds: the observation that the real instance was caught by a unit
test, not a review lens, on the actual PR remains a true historical fact —
it is evidence about that one run, not a claim the panel structurally cannot
do this. The measured claim ("do not read `meta.description` as a target") is
the part refuted; the historical claim about F40's origin is untouched by
this measurement.
