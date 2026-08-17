# `missing-final-step` — the plan stops before the goal's verb

Four tasks covering R1–R4: issue a token, mail it, and validate it. Nothing in
the set writes `User.password_hash`, so a user who completes every shipped step
holds a validated token and still cannot sign in. The north star's second
clause — *set a new one and sign in with it* — is never reached.

## Why every task is individually sound

These four tasks are **byte-identical to the control column's first four**
(generated from `aligned.json`, pinned by the suite). So whatever verdict a
feasibility or testability lens returns for a task here, it returns the same
verdict for that task in the control. Each names existing paths (`app/reset.py`
is created, `app/models.py` and `app/mailer.py` exist), each `testCycle` names a
real command and an expected output, and each `consumes` is satisfied by an
earlier task in the same set.

## Why a per-task lens cannot see it

This is the fixture whose prediction is structural rather than empirical. The
columns differ by an **absence**: the control has `reset-confirm` and
`reset-clears-lockout`, this column has no fifth or sixth task at all. A lens
dispatched per task is shown, in both columns, the same four task objects — so
its per-task verdicts cannot distinguish them **even in principle**. Detection
would require either a view of the set or a comparison of the set against the
spec, and `plan.js` performs neither today.

If a lens does flag something here, read it carefully before counting it: the
plausible mechanism is not "the set is short" but "this task's `produces` is
consumed by nothing later", which is a #66 edge observation reached from a single
task's JSON, not an alignment judgment.

## What a generic finding would be

"Consider adding tests for the reset confirmation step" is equally true of the
control column, where that step exists and is tested — the control's task list
is longer, so a reviewer pattern-matching on *plans usually have a confirm step*
will say it in both places. Only a finding that names the goal as unreached, or
names R5 as uncovered by any task in the set, counts as a detection.
