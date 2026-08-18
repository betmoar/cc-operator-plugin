# Measurement — do the shipped vet lenses catch a misaligned plan?

The question [#58] makes the gate for its own implementation: with the north star
in the packet, do `plan.js`'s two existing vet lenses detect a task set that is
individually sound and collectively misses the goal? If they do, the field alone
closes #58 and no alignment pass is built — the outcome [#24] and [#70] both
reached, and a success rather than a failure.

**Status: run 2026-08-18. 42 seats, 21 tasks x 2 lenses, both columns.**
Predictions below were fixed before the dispatch and are left exactly as written;
two held, one did not, and the run surfaced a defect in the corpus itself and a
larger defect in `plan.js` that is not what #58 asked about.

## Method

Verbatim reuse, so the thing measured is the shipped panel and not a variant
written for the occasion:

- The two prompts from `workflows/plan.js` phase 2, **unmodified**, plus the
  contents of `northstar.txt` prepended to each — that prepend is the entire
  intervention under test.
- The same tier split: feasibility at `JUDGMENT`, testability at `MECHANICAL`
  with `effort: "low"`.
- The same `VET` schema (`feasible` ∈ yes/no/needs-info, `testable` ∈ yes/no,
  `issues[]` with kind ∈ gap/contradiction/untestable/dependency-missing/risk).
- One seat per lens per task. **Never one seat two columns**: a seat shown both is
  comparing them, not detecting misalignment in one.
- cwd = `project/`, so task paths resolve without naming the corpus.
- Tasks passed as inline JSON, exactly as `plan.js` serializes them, so no
  filename reaches a seat.

Both columns are run for every fixture. A number from the misaligned column alone
is not a detection rate — `aligned.json` is the false-positive control and its
findings are part of the result, not a footnote.

### Scoring rule, fixed before the run

Fixed in advance because "was that a detection?" is exactly the judgment a
measurement's author is worst placed to make afterwards.

- **DETECTION** — a finding that names the goal as unreached, or names the
  specific requirement no task in the set covers, or names the criterion as a
  proxy for the goal. It must be traceable to the north star, not to general
  reviewing instinct.
- **NOT A DETECTION** — advice that would be equally apt on the control column.
  Each `NOTES.md` writes its fixture's version of this down in advance ("consider
  adding tests for the confirmation step", "add an end-to-end test", "temporary
  passwords are a phishing risk"). Scoring these as hits is how a lens that
  pattern-matched on topic gets credited with holding a goal.
- **FALSE POSITIVE** — any misalignment finding raised against `aligned.json`.
- A per-task lens returning `feasible: "no"` or `testable: "no"` on any task in
  any column is a **corpus defect**, not a detection: the property that every
  task is individually sound is pinned by `tests/test_plan_align_corpus.py`, so
  such a verdict means either the pin is too weak or the lens is wrong about the
  fixture. Investigate before scoring anything else.

### Predictions, recorded before the run

Stated up front so the result can contradict them. A corpus whose every fixture
is predicted to be missed was built to justify a conclusion.

| fixture | prediction | reasoning |
| --- | --- | --- |
| `missing-final-step` | **MISS** | structural, not empirical: the columns differ by an absence, so both columns hand a per-task lens the same four task objects. Its verdicts cannot differ. |
| `adjacent-deliverable` | **CATCH plausible** | the contradiction with *without contacting support* sits inside single task objects; the goal in the packet is all a lens needs. |
| `unverifiable-goal` | **CATCH plausible, feasibility only** | `reset-confirm`'s `specExcerpt` quotes "can immediately sign in with it" while its `testCycle` stops at the stored hash — a one-task mismatch. Testability should say `yes` and be right to. |

If the results match these predictions exactly, the conclusion is **partial**: the
field closes the shapes a single task can reveal, and an alignment pass earns its
cost only for the absence shape. That is a narrower and more useful answer than
either "build it" or "don't".

## Run identity

| | |
| --- | --- |
| date | 2026-08-18 |
| corpus content hash, as measured | `e5fef3fa0dae7f41` (17 files, tree at `fb30b2a`) |
| codebase tree handed to the seats | `a1dfdeb1abd6eda6` (5 files) |
| seats | 42 = 21 tasks x 2 lenses |
| feasibility model | `claude-opus-5` (JUDGMENT, as bound) |
| testability model | `claude-haiku-4-5` (**substitution** — see deviations) |

The corpus hash is recorded because a fix landed *after* this run: the corpus at
`e5fef3fa0dae7f41` is the one these numbers describe. Re-running against a later
tree and comparing to this table is exactly the error [#69] exists to prevent.

### Deviations from the shipped workflow

Four, none silent:

1. **The cheap lens ran on `claude-haiku-4-5`, not `glm-5-turbo`.** The Agent
   tool's `model` parameter is enum-locked to Anthropic aliases — the seam [#55]
   describes — so the bound MECHANICAL id is not reachable without the dispatch
   workflow. The testability arm is therefore a different model at the same
   tier. The feasibility arm, which carries the decisive result, is exact.
2. **Each feasibility seat was told the codebase root explicitly.** The shipped
   workflow inherits the operator's cwd; a hand dispatch has no cwd to inherit.
   The added line names the tree and forbids reading outside it, which also
   keeps the corpus directories out of reach.
3. **The project was copied to a neutral path.** The absolute path
   `tests/fixtures/plan-align/project` names the corpus in every prompt, and
   three of the tree's own docstrings said "fixture" while `project/README.md`
   stated the discriminating property outright — *"A plan that never writes that
   field cannot produce a user who signs in"*. That is the answer to
   `missing-final-step`, in the tree, addressed to the reader. The README is
   excluded from the seats' tree and the docstrings were rewritten as ordinary
   code documentation. Both are leaks the corpus shipped with and neither was
   caught by the pins.
4. **Prompt files were renamed to opaque ids** (`p01`…`p42`) after the first
   generation put the column name in every filename.

## Results

### Feasibility (judgment tier, 21 seats)

| column | n | `feasible` verdicts | raised goal-talk | **named the violated clause** |
| --- | --- | --- | --- | --- |
| `aligned` (CONTROL) | 6 | 1 yes, 5 needs-info | **6/6** | **0/6** |
| `missing-final-step` | 4 | 1 yes, 3 needs-info | 3/4 | **0/4** |
| `adjacent-deliverable` | 5 | 1 yes, 3 no, 1 needs-info | 5/5 | **4/5** |
| `unverifiable-goal` | 6 | 1 yes, 5 needs-info | 6/6 | **0/6** |

### Testability (cheap tier, 21 seats)

`testable: "yes"` on **21/21**, every task, every column — the predicted and
correct answer, since every `testCycle` in the corpus does name a command and an
expected output. One seat raised a goal-level issue anyway, and it is the
decisive one below.

### Scored under the rule fixed before the run

| fixture | prediction | result | scored |
| --- | --- | --- | --- |
| `missing-final-step` | MISS | goal-talk on 3/4, but the control produced the same talk on 6/6 | **MISS**, as predicted |
| `adjacent-deliverable` | CATCH plausible | 4/5 seats name *without contacting support* and say this task's deliverable violates it; control 0/6 | **DETECTED** |
| `unverifiable-goal` | CATCH plausible, feasibility only | feasibility missed it; the **cheap testability seat** caught it on `reset-confirm` | **DETECTED, by the wrong lens** |

The `unverifiable-goal` detection is worth quoting, because it is the only
finding in 42 seats that does exactly what the scoring rule asks and comes from
the seat predicted to be blind:

> testCycle verifies password_hash is stored correctly but does not verify login
> integration. […] The North Star requires a user to 'sign in with it' — add a
> test: auth.login(user, new_password) returns True after confirm_reset completes.

Its control counterpart — the same task with the goal-level assertion restored —
returned `{"feasible":"yes","testable":"yes","issues":[]}`. Clean discrimination,
one seat each way. The prediction that testability *should* answer `yes` and be
right to was correct; the prediction that it could not see the gap was wrong. It
answered `yes` to the question it was asked and raised the goal gap as a `risk`
alongside it.

### The control column is the result

**6/6 feasibility seats raised goal-reachability concerns against the plan that
reaches the goal.** Verbatim, from the control:

> a locked-out account completes every shipped step and still cannot sign in —
> the north-star miss condition verbatim

That is `aligned`'s `reset-confirm` — a task whose sibling, two entries later in
the same set, clears exactly that lockout. The seat cannot see the sibling, so it
reports the miss. Under the pre-registered rule every one of these is a false
positive, and they are what makes goal-talk useless as a signal: it appears at
100% on the good plan.

What survived that filter was narrow and specific: naming the *clause* the plan
violates (`adjacent-deliverable`, 4/5 vs control 0/6), and naming a criterion as
a *proxy* for the goal (`unverifiable-goal`, 1 seat vs a clean control). Both
discriminate. Neither is "the lens noticed the goal."

## What the run found that #58 did not ask about

**14 of 21 feasibility seats returned `needs-info`, in every column, citing
`dependency-missing`.** The cause is in the shipped prompt:

> Is the dependency it consumes actually produced by an earlier task?

The seat is handed exactly one task and never its siblings, so it cannot answer.
It correctly reports that it cannot confirm the producer — and `plan.js` buckets
`needs-info` into `needsInfo`. On a real run of a **well-formed** plan, roughly
five of six tasks would land in that bucket — that is the CONTROL column's own
rate, not the 14/21 across all columns — and the operator is told to resolve that
bucket before dispatch. A signal that fires on 5/6 tasks of a good plan is not a
signal.

This is independent of the north star, larger in blast radius, and measured here
by accident. It wants its own issue.

## The corpus defect this run found

`adjacent-deliverable/admin-temp-password` claimed a test asserting
`issue_temp_password` returns a 12-character string while its steps prescribed
`secrets.token_urlsafe`. A seat caught it:

> token_urlsafe(n) returns ~ceil(4n/3) base64url chars (token_urlsafe(12) -> 16
> chars) […] The test as written fails against the prescribed implementation.

True positive against the fixture, and the same shape [#70] hit — a corpus's
"correct" column carrying an error of its own, found by a lens and confirmed. It
contributed to that task's `feasible: "no"`, which the pre-registered rule flags
as a corpus defect rather than a detection, so the rule worked. Fixed after this
run; the hash above is the pre-fix tree.

## Conclusion

**The field alone does not close #58, and the alignment pass is not obviously
worth building either.** Both halves are measured:

- Putting the goal in the packet does *not* let per-task lenses distinguish a
  plan that reaches it from one that does not. It makes them discuss the goal
  constantly — 6/6 on the control — which is noise, not detection.
- Two shapes were nonetheless caught, and both were caught **inside a single
  task**: a task whose own description contradicts a goal clause
  (`adjacent-deliverable`), and a task whose own criterion is a proxy for the
  goal (`unverifiable-goal`). Neither needed a view of the set.
- The one shape that genuinely requires a view of the set —
  `missing-final-step`, where the columns differ by an absence — was missed
  exactly as predicted, and no per-task lens can ever catch it.

So the honest recommendation is narrower than either option in #58: **ship the
field, and do not ship a per-task alignment lens** — per-task is where the goal
already fails to discriminate. If anything is built for the absence shape, it has
to see the whole set, and the cheapest thing that does is not a lens at all: a
spec-coverage check asking which requirements no task claims. That is arithmetic
over `specExcerpt`, not judgment, and it belongs with [#66]'s edge work rather
than in a sixth seat.

## What this measurement still does not settle (revisited after the run)

The four bounds recorded before the run — the section at the end of this file,
written before any seat was dispatched — all stand. Two are now sharper:

1. **Three fixtures is not a rate**, and one of the three detections came from a
   single seat.
2. **The corpus is one small plan against four code modules.** Every seat read
   the entire codebase in three tool calls. Detection here is not attention on a
   real decomposition.
3. **`adjacent-deliverable` still cannot separate goal-reading from
   topic-matching** — the control has no admin tasks, so a lens keying on
   "admin" near "password" scores 4/5 without holding a goal. The clause-naming
   requirement makes this less likely, not impossible.
4. **Nothing here measures a vague north star**, #58's second claim.

**Found after the run, and left in place (5).** Four of
`adjacent-deliverable`'s five excerpts paraphrase `spec.md` rather than quoting
it, and `admin-audit-entry` cites *"R1 — a reset is single-use and
**attributable**"* when R1 says nothing about attribution. That matters because
the excerpt is what a vet seat sees instead of the spec, so the fixture's own
prose was doing work the spec was not — in the column that produced the strongest
detection (4/5).

The direction is checkable rather than assumed, and it runs **against** the
detection, not for it: the paraphrases strip R2's `request_reset(email)`, i.e.
the self-service framing, out of the excerpts, and the fabricated attribution
clause makes the audit task look *more* spec-grounded than it is. Both make the
off-goal nature harder to see from the excerpt alone, so a seat that flagged the
support-agent conflict had to get it from the north star. The detection stands;
what it does not support is any claim that the excerpts were faithful.

Not rewritten. The corpus hash above is what these numbers describe, and editing
the measured artifact after the fact is precisely the [#69] defect. A pin now
names the four offenders individually and fails on a fifth — and fails equally if
one is fixed without leaving the list.

And one new bound: the testability arm ran on a substituted model, so the single
`unverifiable-goal` detection is a finding about a cheap seat in general, not
about the seat this project actually dispatches.

## What this measurement will not settle (recorded BEFORE the run)

Recorded now, for the same reason [#70]'s corpus recorded its bound before its
conclusion was written:

1. **Three fixtures is not a rate.** Three shapes chosen by the author of the fix
   is an existence test, not coverage of the misalignment class.
2. **The corpus is one small plan against four code modules.** A real
   decomposition runs to dozens of tasks against a codebase no lens can hold.
   Detection here is not attention there — the same bound #70 hit.
3. **`adjacent-deliverable` cannot separate reading the goal from topic-matching.**
   The control column has no admin tasks, so a lens keying on "admin" near
   "password" scores perfectly without holding a goal at all. Only findings that
   name the violated clause distinguish the two, which is why the scoring rule
   requires it.
4. **Nothing here measures whether a *vague* north star is worse than none** —
   #58's second claim, that a one-line "make it better" launders drift as
   alignment. That needs a fourth column with a degenerate goal, and it is a
   separate question from this one.

[#24]: https://github.com/betmoar/cc-operator-plugin/issues/24
[#55]: https://github.com/betmoar/cc-operator-plugin/issues/55
[#66]: https://github.com/betmoar/cc-operator-plugin/issues/66
[#69]: https://github.com/betmoar/cc-operator-plugin/issues/69
[#58]: https://github.com/betmoar/cc-operator-plugin/issues/58
[#70]: https://github.com/betmoar/cc-operator-plugin/issues/70
