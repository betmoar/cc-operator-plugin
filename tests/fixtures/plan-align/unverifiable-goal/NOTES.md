# `unverifiable-goal` — six requirements covered, the goal never exercised

Six tasks covering R1–R6. The set is complete, `confirm_reset` writes
`User.password_hash`, the token is consumed, the lockout is cleared. If every
task is implemented as written, a user probably *can* reset and sign in.

Nothing in the plan checks that. Every `testCycle` asserts an internal fact —
the stored hash equals `hash_password(new_password)`, the token row has
`used=True`, `locked_reason` is `None` — and no task's criterion ever calls
`app/auth.py:login`. The north star's *and sign in with it* is untested by
construction, so the plan can go fully green while the one thing the user cares
about is unobserved.

## The difference from the control, exactly

Tasks 1–4 are **byte-identical to the control's** (pinned by the suite). Tasks 5
and 6 keep the control's `id`, `title`, `files`, `produces`, `consumes` and
`specExcerpt` verbatim; only `testCycle` and `steps` differ. The control's
confirm task asserts `auth.login(email, new_password)` returns a token and that
the old password stops working. This column asserts field values instead.

So the columns differ in *what the plan proves*, with the work itself identical.
That isolates the question: does a lens notice that a criterion is a proxy for
the goal rather than the goal?

## Why the testability lens should miss it

The testability lens asks whether `testCycle` names an observable command and
expected output. Every task here does — `python3 -m unittest … → OK (3 tests)`
is exactly what it is looking for. `testable=yes` is the *correct* answer per
task. The defect is that the union of six correct criteria never touches the
goal, and no per-task question can reach that.

The feasibility lens is the plausible detector, and only with the goal in the
packet: `reset-confirm`'s `specExcerpt` quotes R5's *"the user can immediately
sign in with it"* while its `testCycle` stops at the stored hash. That
mismatch is visible in one task object.

## What a generic finding would be

"Add an end-to-end test" is nearly a detection and must not be scored as one
unless it names sign-in as the thing untested — "add integration tests" is
advice a reviewer gives to well-aligned plans too, and it is equally applicable
to the control column, whose per-task criteria are also unit-level apart from the
one login assertion.
