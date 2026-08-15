# #24 step 2 — the panel measured against the corpus

Run 2026-08-15. **The result contradicts the hypothesis the fixtures were built
to demonstrate, and that is recorded here rather than smoothed over.**

## Method

The five lenses were dispatched as they ship in `workflows/review.js` — same
prompts verbatim, same tier split (spec/testability/correctness at cheap tier,
feasibility/quality at judgment tier), five parallel read-only seats, no
security lens, no adversarial seat.

The fixtures were **neutralized first**, and that step is load-bearing. Copied
to a scratch tree outside the repo as `case1..case5`, renamed to plausible
production names (`ops-frag.sh`, `ops-sweep.sh`, `ops-ledger.sh`,
`ops-load-tiers.sh`, `ops-dispatch.sh`), with every header rewritten to drop
"FIXTURE", "This is the DEFECTIVE variant", and the `NOTES.md` pointer. No
`fixed.sh` sibling, no README, no `fixtures/security` in any path. A lens told
the file is the defective one is not being measured on detection — it is being
asked to agree. Verified by grep before dispatch: zero occurrences of
`fixture|DEFECTIVE|CORRECTED` in the neutral tree.

## Result

Scores are the lens's own, on its own 0–100 scale. **Detected** means the
finding named the specific mechanism `NOTES.md` requires — the dataflow, the
missing call site, the sink — not merely "validate inputs".

| fixture | spec | testability | feasibility | quality | correctness |
| --- | --- | --- | --- | --- | --- |
| `frag-traversal` | — | partial (60) | **88** | **92** | **78** |
| `sweep-rm` | — | **75** | **92** | **95** | **88** |
| `guard-two-of-three` | — | **85** | **90** | **90** | **82** |
| `ext-source` | extra-output (55) | **70** | **76** | **84** | 45 (dropped) |
| `secret-in-error` | **80** | — | **94** | **94** | — |

Every one of the five defects was detected by at least two lenses above the 50
threshold. `feasibility` and `quality` — the two judgment-tier seats — detected
**5/5 each**, and named the mechanism in each case.

### The specific detections, verbatim in substance

- `sweep-rm`: both judgment lenses rejected the comment's containment claim on
  the right grounds — *"quoting prevents word-splitting only"*, the exact
  distinction `NOTES.md` set as the discriminating half.
- `guard-two-of-three`: `feasibility` found the missing call site **and** went
  further than the fixture's own note — it observed that `adopt` is itself an
  opener (`mkdir -p` + `>`), so the "already checked when opened" excuse fails
  even for a well-behaved caller. `quality` independently named it as the
  project's guard-parity class.
- `secret-in-error`: `feasibility` traced the sink to the committed ledger and
  called the leak *"the documented happy path"*.
- `ext-source`: `quality` named it *"the comment sells the flaw as the
  feature"*.

## What this means for the U12 hypothesis

The issue's premise was that these classes fall systematically outside the five
lenses, with `correctness` the only near-miss and the security defect invisible
because the feature works and the tests pass. **Measured, that is false for this
corpus.** Two lenses caught everything, and the mechanism-level detail was
present, not vague.

Three honest qualifications, none of which rescue the premise:

1. **The cheap tier is where the gap lives.** `spec` detected 1/5 and
   `correctness` detected 4/5 but scored `ext-source` at 45 — below the
   threshold, i.e. dropped from the panel's output entirely, and it read the
   arbitrary-execution defect as a missing exit-status check. If the panel ran
   cheap-only, coverage would be materially worse. #24's tier question
   ("adversarial security reasoning is judgment work") is answered in the
   direction it guessed — but the answer is that the *existing* judgment lenses
   already do it, not that a new one is needed.
2. **These seats knew they were reviewing gate-like code.** The neutral headers
   describe a ledger plugin, and `quality` cited "the project's guard-parity
   rule" — a convention of *this* repo. A defect of the same class in an
   unfamiliar subsystem may not draw the same attention. Untested.
3. **Five defects, one author, one repo's shape.** The invalidator from the
   fixture README stands: a class absent from the corpus is not a class the
   panel catches.

## The false-positive control — RUN, and it changes the reading

The `fixed.sh` column was neutralized the same way (`panel-control/`, "THE FIX"
markers stripped so the corrected line does not announce itself) and dispatched
to the three lenses that had detected most: feasibility, quality, correctness.

**Not one of the five original defects was re-flagged.** No lens claimed a
traversal in `frag-traversal`'s guarded fragment write, an `rm -rf` escape in
`sweep-rm`, a missing call site in `guard-two-of-three`, arbitrary execution in
`ext-source`, or a leaked secret in `secret-in-error`. Feasibility returned "no
findings" outright for `sweep-rm` and `guard-two-of-three`.

That makes the table above a **rate**, not a count: 5/5 detected on the
defective column, 0/5 false-positived on the corrected one, for the two
judgment lenses.

### The control found three real defects in the fixes themselves

Not re-flags of the original defects — new ones, introduced by my corrections,
in code that had passed its own probe:

1. **`ext-source/fixed.sh`: a line with no `=` parsed as `key==value`.**
   `${line%%=*}` and `${line#*=}` are both the identity on such a line, so a
   stray `MECHANICAL` set `MECHANICAL=MECHANICAL` and reported that non-id as a
   resolved binding. Reproduced directly, then fixed with a `*=*` arm.
2. **`secret-in-error/fixed.sh`: the redaction stopped redacting on short
   tokens.** `${TOKEN%????}` does not match a token under four characters, so
   `_tail` became the *whole token* — the fix printed the entire secret for
   exactly the credential most likely to be a malformed paste. Fixed with a
   length floor that refuses to fingerprint rather than degrading.
3. **`guard-two-of-three`: `open` clobbers a pre-existing sentinel** with a
   plain `>`, no O_EXCL and no regular-file type test — destroying another
   session's ownership line. This one is in the fixture's *unmodified* half and
   is deliberately left in place: the fixture models one defect (the missing
   call site) and adding a second would blur what a detection is measuring. It
   is recorded here rather than fixed, and `NOTES.md` says so.

Findings 1 and 2 are the same class this project has hit repeatedly — a fix
written under review pressure needing the same scrutiny as the code it
replaces. The control run existed to validate the instrument and ended up
auditing the repairs.

**Neither of those two is pinned by `probe.sh`, and that is worth stating.**
Revert either fix and the probe still reads `FUNCTIONAL: ok` / `EXPLOIT:
blocked` — measured. The probes test the *modeled* defect (does the traversal
escape, does the secret leak), not every property of the corrected variant. The
short-token leak in particular fires only at exactly length 4: below that the
naive form prints nothing and looks safe. So a later reader should not infer
that the suite would catch a regression in these two lines. It would not.

## Step 3 — the tier arm, run 2026-08-15

Step 2 said the gap was not lens *coverage* but lens *tier*. So step 3 tested
that instead of building the security lens: the two cheap-tier lenses were
re-run at JUDGMENT tier, same corpus, same neutralized tree, same prompts
verbatim. Only the tier changed.

| fixture | `correctness` MECH → JUDG | `spec` MECH → JUDG |
| --- | --- | --- |
| `frag-traversal` | 78 → **88** | — → — |
| `sweep-rm` | 88 → **92** | — → — |
| `guard-two-of-three` | 82 → **90** | — → **82** |
| `ext-source` | **45 → 85** | 55 → 58 |
| `secret-in-error` | — → **95** | 80 → 80 |

**The 45 was the whole question, and it moved to 85.** At MECHANICAL,
`ext-source`'s arbitrary-execution defect was scored below the 50 threshold —
dropped from the panel's output entirely — and described as a missing
exit-status check on `source`. At JUDGMENT the same lens names the mechanism:
*"executes the project's `tiers.env` as shell — any `$(...)`, backtick, or plain
command in a value runs with the caller's privileges"*.

`correctness` also went 4/5 → **5/5**, picking up `secret-in-error` (95), which
it had not reported at all. `spec` went 1/5 → 3/5, and on `guard-two-of-three`
found something no lens had at either tier: that `adopt` is documented as
re-stamping an *existing* sentinel yet creates one, so it *silently doubles as a
second `open`*.

### The control, and a methodology failure worth recording

The first control run scored 62–78 on the corrected column — apparently a mass
false-positive. It was not. That control tree had been built during step 2 and
was **stale**: it predated the two fixes the step-2 control itself produced. The
judgment-tier lens was correctly reporting the *old* defects, including the
`len == 4` fingerprint leak, in code that no longer ships. Verified against the
shipped `fixed.sh` across lengths 1–9: `*** (too short to fingerprint)` through
7, `***aaaa` from 8. No bug.

Rebuilt from the current fixtures and re-run: **zero of the five modeled defects
re-flagged.** No traversal in `frag-traversal`, no `rm -rf` escape in
`sweep-rm`, no missing call site in `guard-two-of-three`, no arbitrary execution
in `ext-source`, no leaked secret in `secret-in-error`. So the 5/5 above is a
rate, not a count.

The clean control does report *other* defects in the corrected column — an
ignored `rm -rf` status, an `open` that truncates a live sentinel, silent
`continue` on a rejected config value. Those are real, they are not the modeled
defects, and they are the judgment tier finding more than it was asked for. One
of them (`open` clobbering) is the defect `guard-two-of-three/NOTES.md` records
as deliberately unfixed.

**The lesson is about the instrument, not the tier:** a control tree is an
artifact with a version, and re-running an experiment against a stale one
produces a confident wrong answer. This corpus's own README says a fixture whose
exploit does not fire is a broken instrument; the same is true of a control that
does not match the code it controls for.

Filed as #69, because nothing here catches it: the suite pins all four cells
of every fixture, and not one of those assertions is about the DERIVED trees a
measurement builds from them — which are the panel's actual input. It is #23's
class one layer up (a result produced by stale tree state rather than by the
thing under test), and arguably worse, because a verdict gets re-derived on the
next run while a measurement gets written down. **If you re-run this experiment,
rebuild both trees first.**

## Consequence for step 3

The planned step 3 was: add a conditional `security` lens plus a `supply-chain`
lens, re-run, report the delta. **On this evidence the security lens is not the
change to make** — there is no measured gap for it to close, and a lens added
against numbers that do not show a gap is decoration that green-stamps every
review. That is the vacuity class (#21) applied to a lens instead of a guard.

What the numbers *do* support is **tier**, not lens count — and the arm above
tested exactly that. Both predictions held: the control ran first, and the
cheap-tier `correctness` seat was the one dropping a real defect below
threshold.

### What was decided, and what was not

`correctness` moves to JUDGMENT tier. The evidence is a 45 → 85 on the one
finding the threshold had swallowed, 4/5 → 5/5 coverage, a mechanism-level
description where there had been a wrong diagnosis, and a clean false-positive
control. That is a measured gap with a measured fix.

`spec` stays at MECHANICAL despite going 1/5 → 3/5. Its lens question ("what
did the task text ask for that is missing") is not adversarial reasoning, its
two new findings are both restatements of what `correctness` and `quality`
already reported at judgment tier, and the panel pays for five seats per review.
Promoting a lens because its numbers rose, without asking whether the findings
are NEW, is how a panel becomes expensive without becoming better.

The 50 threshold is **not** changed. 45 was a correct observation with the wrong
severity, not a scoring-scale problem, and the tier change fixes it at the
source. Lowering the threshold would admit every 45 in every future review on
the strength of one data point.

The `security` and `supply-chain` lenses are **not** built. That remains the
step-2 conclusion and the tier arm does not disturb it: there is still no
measured gap for them to close.
