# #70 — the panel measured against the drift corpus

Run 2026-08-16, plugin at 0.8.4-dev. **The result contradicts the hypothesis the
fixtures were built to demonstrate, and that is recorded here rather than
smoothed over.** #24 produced the same shape of surprise and the same discipline
applies: the number decides, not the design intuition that preceded it.

## The question

#70 measured twenty claim/code drift instances across four PRs and observed that
none was caught by the five shipped lenses. It proposed three options and
prescribed none, requiring the #24 treatment first: build the fixture, measure
the current panel against it, and only then decide whether a sixth seat earns
its cost.

## Method

The five lenses were dispatched **as they ship** in `workflows/review.js` — the
`ask` strings copied verbatim, the same tier split (spec/testability at
MECHANICAL, feasibility/quality/correctness at JUDGMENT), five parallel
read-only `op-reviewer` seats, no drift lens, no adversarial seat. Tier bindings
came from this project's `tiers.env`: MECHANICAL=`deepseek-v4-flash`,
JUDGMENT=`claude-opus-5`.

Both columns were built with `scripts/ops-corpus.sh` (#69), so the trees carry a
source stamp and a stale one is an error rather than a plausible number — the
exact failure this measurement's predecessor hit:

```
$ bash scripts/ops-corpus.sh build --corpus tests/fixtures/drift --out <scratch>/drift-derived
ops-corpus: neutralization check ok — no FIXTURE|DEFECTIVE|CORRECTED marker and no
corpus-vocabulary file in <scratch>/drift-derived
ops-corpus: built <scratch>/drift-derived — 9 file(s) from tests/fixtures/drift
(stamp e9f2931a569fb51b0d24576108176354c1cd9bd4d086c1658b41d4f2f9bc7bc4)
```

The control column is the same build with the map's `drifted/` segments swapped
for `true/` (stamp `d73d3f65…`). Neutralization matters as much as it did for
#24: production filenames (`ops-lock.sh`, `panel.mjs`, `seat-dispatch.mjs`, …),
no `NOTES.md`, no `README.md`, no `drifted`/`true` in any path. A lens told which
column it is reading is not being measured on detection.

The two columns were dispatched **separately, never side by side**. A seat shown
both is comparing them, which is a much easier task than the one the panel
actually faces.

## Result — drifted column

Scores are the lens's own 0–100. **Detected** means the finding named the
specific claim and the code that falsifies it, per each fixture's `NOTES.md`
requirement — not a generic "verify the comments".

| fixture | spec | testability | feasibility | quality | correctness |
| --- | --- | --- | --- | --- | --- |
| `errno-claim` | — | — | **80** | **82** | **80** |
| `lock-ceiling` | — | **55** | **72** | **68** | **52** |
| `stdout-copies` | — | **72** | **78** | **76** | **60** |
| `tier-split-meta` | — | **70** | **74** | **72** | **57** |
| `agenttype-anchor` | — | — | **85** | **85** | **72** |
| `doc-regex-table` | — | **85** | **88** | **88** | **58** |

**6/6 detected, by at least three lenses each** — four fixtures by four lenses,
two (`errno-claim`, `agenttype-anchor`) by three. Read down the columns instead:
`feasibility` and `quality` detected **6/6** and named the mechanism in every
case; `correctness` 6/6 at lower confidence; `testability` 4/6; `spec` 0/6 (it
returned one finding, and it was about the artifact's file set — the F38 shape:
dispatched with no task text, its question has no subject).

An earlier draft of this line read "by three lenses each", which the table three
rows above contradicts. Recorded rather than quietly corrected, because this file
is the measurement a decision rests on and a reader deserves to know its summary
line was once wrong about its own data — the drift class this corpus exists to
measure, found in the corpus's own write-up by the lens dispatched to hunt it.

## Result — control column (the false-positive check)

**Zero of the six corrected claims was flagged as drift.** The control produced
findings — 33 of them — but they are about *other* properties: a prototype-chain
lookup in `seat-dispatch.mjs`, `resolve_tier` reading `tiers.env` by relative
path, `ownerOrNull` failing open on EACCES. Those are real observations about
fixture code that was written to be drift-clean, not claim-correct. One is a
genuine near-miss worth naming: `feasibility` scored 55 on "the 3s ceiling
overstates the bound — only 29 sleeps elapse before the ceiling trips". That is
arithmetic about the *corrected* claim and it is arguably right, which makes it
the most interesting single finding in the run: the lens is reading the claim
against the code closely enough to out-argue the fixture author.

Both columns' `quality` seat also independently flagged that
`warn_lock_ceiling` is byte-identical in two files with no parity pin — F30's
shape, present in both columns by construction, correctly reported in both.

## What this settles

**A sixth lens is not built, and the reason is measured rather than argued.**
Option 1 in #70 (a narrow drift lens) has no headroom to buy: `feasibility` and
`quality` already detect 6/6 with a clean control. A sixth seat would pay a
fifth of the panel's cost per review for findings the panel already returns.

Option 2 (sharpen `feasibility`) is also not taken, for a subtler reason. It ran
here **unmodified** and detected 6/6, including the three fixtures whose claim
and code live in *different files* (`stdout-copies`, `agenttype-anchor`,
`doc-regex-table`) — the shape #70's own analysis predicted it would miss. The
prompt did not need the proposed "including claims made in comments about code
in other files" clause to do it.

Option 3 (repeated-sentence detection) remains available and unexercised. It is
mechanical, catches only `stdout-copies`'s shape, and the panel already catches
that one. It would earn its place only as a *cheap pre-filter*, not as coverage.

## The honest bound — why this does not close #70

This measurement says the panel detects these six fixtures. It does **not** say
the panel would have caught the twenty real instances, and three specific gaps
separate the two claims:

1. **The corpus is nine files.** The real instances landed in PRs of dozens of
   files with hundreds of lines of unrelated diff. A lens reading nine short
   files under an explicit "check every load-bearing claim" instruction is in a
   far better position than the same lens reading a release-sized diff. Detection
   rate is not attention rate.
2. **Every file here is dense with claims.** #70 itself notes that five of its
   first six instances came from one unusually comment-dense PR, and that the
   base rate on ordinary changes is unknown. This corpus reproduces the dense
   condition, not the ordinary one.
3. **The panel that missed the real instances was not always this panel.** Four
   of the twenty were found by a general reviewer, twelve by a dedicated drift
   lens, two by Copilot — several rounds, several harnesses. Attributing all
   twenty misses to the five shipped lenses in their current form overstates what
   was measured then.

So the defensible statement is narrow: **on a dense corpus of nine files, three
of the five shipped lenses detect all six modeled drift shapes, with no
false-positive on the corrected column.** That is enough to decline building a
sixth seat now. It is not enough to declare the class covered, and #70 should
stay open on the attention question — whether these lenses find the same claims
inside a release-sized diff — which needs a different fixture: this corpus's
files scattered into a large realistic change.

## Reproducing

```
bash scripts/ops-corpus.sh build --corpus tests/fixtures/drift --out <scratch>/drifted
# control: same, with the map's `drifted/` segments replaced by `true/`
bash scripts/ops-corpus.sh verify --corpus tests/fixtures/drift --tree <scratch>/drifted
```

Then dispatch the five verbatim `ask` strings from `workflows/review.js` at the
tiers above, one seat per lens per column, never both columns to one seat.
`verify` before dispatching is the point of #69: this measurement's predecessor
produced a confident wrong answer from a tree built one step earlier.
