# Measurement — do the shipped vet lenses catch a misaligned plan?

The question [#58] makes the gate for its own implementation: with the north star
in the packet, do `plan.js`'s two existing vet lenses detect a task set that is
individually sound and collectively misses the goal? If they do, the field alone
closes #58 and no alignment pass is built — the outcome [#24] and [#70] both
reached, and a success rather than a failure.

**Status: instrument built, not yet run.** Nothing below the method section is
filled in. That is deliberate: this file exists in the same commit as the corpus
so the decision has one home, and a results table invented ahead of the dispatch
is the failure mode this whole corpus exists to prevent.

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

## Results

Not yet run. To be filled in with, per fixture per column: each lens's
`feasible`/`testable` verdict, every issue raised verbatim, and its score under
the rule above.

## What this measurement will not settle

Recorded now, for the same reason [#70]'s corpus recorded its bound before its
conclusion was written:

1. **Three fixtures is not a rate.** Three shapes chosen by the author of the fix
   is an existence test, not coverage of the misalignment class.
2. **The corpus is one small plan against a four-module project.** A real
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
[#58]: https://github.com/betmoar/cc-operator-plugin/issues/58
[#70]: https://github.com/betmoar/cc-operator-plugin/issues/70
