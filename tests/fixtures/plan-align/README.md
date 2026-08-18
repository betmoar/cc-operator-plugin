# Plan-alignment fixture corpus — the measurement instrument for #58's north-star question

Issue [#58] measures a gap one layer below the charter: `plan.js` decomposes a
spec into tasks and vets each one against **its own** `specExcerpt`, so every
task can be individually sound while the set collectively misses the goal — and
nothing in the chain asks that question. The issue proposes one field
(`northStar`), one refusal (a vague one), and *possibly* one alignment pass over
the plan as a whole, and it puts a hard condition before any of it:

> **Build the fixture first.** A plan whose tasks are each individually sound and
> which collectively misses a stated goal — then show the alignment stage
> rejecting it. A lens that has never been measured against a case it should fail
> is decoration that green-stamps every plan.

This directory is that fixture. It follows the discipline [#24] required of the
security corpus and [#70] of the drift corpus — build the instrument, measure the
existing seats against it, decide only after — and in both of those cases the
measurement said **do not build the seat**. That outcome is on the table here and
is a success, not a failure: if the existing vet lenses catch these fixtures once
the goal is in the packet, the field alone closes #58.

**Nothing here is wired into the plugin.** Inert files under `tests/fixtures/`;
nothing carries an execute bit and no shipped file *reads* any path here. Two do
**cite** the corpus in comments — `workflows/plan.js` and
`scripts/validate_plugin.py` both point a future maintainer at `MEASUREMENT.md`
before changing the decompose-only rule — which is a reference, not a runtime
dependency. Stated precisely because the earlier wording claimed no shipped file
referenced any path here, and that was false the moment those comments landed.

## The shape, and why it differs from the other two corpora

The security corpus's unit of defect is one file (`vuln.sh` vs `fixed.sh`). The
drift corpus's is a disagreement between two artifacts. Here the unit of defect
is **a set** — no single task is wrong. That forces two departures:

- **The control column is one canonical set, shared by all three fixtures.**
  `aligned.json` is a six-task plan that reaches the north star. Each fixture
  ships only its `misaligned.json`. A lens that flags the control is one false
  positive to explain, not three.
- **`ops-corpus.sh` is not used, and the reason is structural.** Its map emits a
  flat tree (`dest` is guarded as a bare filename against traversal), while a
  plan fixture needs a nested project the feasibility lens can read. There is
  also no derived tree here for [#69]'s staleness machinery to protect: seats read
  the fixture files themselves, so there is nothing to go stale. What replaces the
  neutralization step is described next.

## Neutralization

The drift and security corpora neutralize by copying defective variants under
plausible production names, because a seat that reads `vuln.sh` has been told the
answer. Here the seat never sees a path at all: a task reaches a lens as **inline
JSON**, exactly as `plan.js` dispatches it (`TASK:\n${JSON.stringify(task)}`), so
`misaligned.json` and `aligned.json` are filenames the *dispatcher* reads and the
lens never does. Two rules keep that true, and the suite pins both:

1. No task object contains the strings `aligned`, `misaligned`, `fixture`,
   `column` or a shape name. The `column` and `shape` keys live on the top-level
   object, which is not what gets serialized into a prompt.
2. `project/` is byte-identical for both columns — it is one directory, shared —
   so nothing a lens reads from disk indicates which column it was handed.
3. **Nothing under `project/` names the corpus or the answer — every file, not
   just the code.** The first run nearly shipped the answer: three docstrings
   said "fixture", and `project/README.md` stated the discriminating property
   outright — *"A plan that never writes that field cannot produce a user who
   signs in"*, which is `missing-final-step`'s defect written down in the tree
   the lens reads. The first fix scanned only `*.py` and exempted the README on
   the promise that a dispatch excludes it; a review pointed out that nothing
   pinned the promise, so the guard rested on it. The README is now ordinary
   project documentation and the scan walks **every file** under `project/`, which
   takes the promise off the load path entirely.

Dispatch with cwd = `project/`, so task paths (`app/reset.py`) resolve without
naming the corpus.

4. **The dispatch must bound what a seat may read, and that bound is part of the
   instrument.** The scan above covers `project/`; it cannot cover this README,
   the per-shape `NOTES.md`, or `MEASUREMENT.md`, because those exist precisely
   to state the planted defect to a maintainer — `missing-final-step/NOTES.md`
   says in prose that nothing in the set writes `password_hash`. A reviewer seat
   is granted `Read, Grep, Glob, Bash` with no path restriction, so a run
   dispatched from the repo root can grep the answer. Every seat prompt therefore
   carries an explicit read-bound naming the tree and forbidding anything outside
   it, and the run copies `project/` to a neutral path so the bound does not name
   the corpus either. `MEASUREMENT.md`'s method records this, and a test pins that
   it still does — an instrument whose neutralization lives only in the habits of
   whoever ran it last is not an instrument.

## The discriminating property

|                          | `misaligned.json`      | `aligned.json`        |
| ------------------------ | ---------------------- | --------------------- |
| every task feasible      | **yes**                | **yes**               |
| every task testable      | **yes**                | **yes**               |
| the set reaches the goal | **no**                 | **yes**               |

That top-left cell is the whole design constraint. If a task in a misaligned
column were infeasible or untestable, the per-task lenses would block it and the
corpus would be measuring what `plan.js` already catches. Two of the three
fixtures make this checkable rather than asserted: their first four tasks are
**byte-identical to the control's**, generated from `aligned.json`, so any
per-task verdict is identical across columns by construction.

`tests/test_plan_align_corpus.py` pins the property mechanically — every task in every
column has non-empty `files`, `produces`, `specExcerpt`, and a `testCycle`
naming both a command and an expected output; every `consumes` is satisfied
within its own set; the shared tasks are byte-identical; no task leaks a column
token. It carries controls in both directions, because a comparison that cannot
see a difference reports every column identical, which is the same value that
means clean.

## The three fixtures

Each has a different **prediction**, which is the point — a corpus whose every
fixture is predicted to be missed is built to justify a conclusion rather than to
test one.

| fixture | how the set misses the goal | can a per-task lens see it? |
| --- | --- | --- |
| `missing-final-step` | stops after validating a token; nothing writes `password_hash`, so no user ever signs in | **no, structurally** — the columns differ by an absence, and every task shown is identical in both |
| `adjacent-deliverable` | agent-mediated recovery that genuinely works, violating *without contacting support* | **plausibly yes** — the contradiction sits inside single tasks, needing only the goal in the packet |
| `unverifiable-goal` | covers all six requirements, but no task's criterion ever calls `login`; the goal is untested by construction | **plausibly yes** via feasibility — one task's `specExcerpt` quotes "can immediately sign in" while its `testCycle` stops at the stored hash |

Each `NOTES.md` states what a *generic* finding would be — one equally true of the
control column, and therefore a false positive if raised there. Any detection-rate
claim from this corpus must report both columns or it is not a rate.

## Reproducing

The measurement dispatches `plan.js`'s two vet prompts **verbatim** — the same
tier split (feasibility at judgment, testability at cheap with `effort: "low"`),
the same `VET` schema, one seat per lens per task — with the north star prepended
to the packet, which is the condition #58 names. Never hand one seat both columns:
a seat shown both is comparing them, not detecting misalignment in one.

```
northstar.txt  → prepended to each vet prompt
project/       → cwd for the dispatch
<shape>/misaligned.json, aligned.json → the task objects, inline
```

`MEASUREMENT.md` records the results and is the file that decides whether Stage B
ships an alignment pass or the field alone.

[#24]: https://github.com/betmoar/cc-operator-plugin/issues/24
[#58]: https://github.com/betmoar/cc-operator-plugin/issues/58
[#69]: https://github.com/betmoar/cc-operator-plugin/issues/69
[#70]: https://github.com/betmoar/cc-operator-plugin/issues/70
