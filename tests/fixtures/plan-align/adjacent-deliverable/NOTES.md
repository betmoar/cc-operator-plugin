# `adjacent-deliverable` — the flow works, and it requires support

Five tasks building agent-mediated recovery: the support console finds the
account, issues a temporary password, audits it, and the user changes it after
signing in. Every requirement in the spec is touched, `User.password_hash` **is**
written, and a user genuinely ends up able to sign in with a password they chose.

The north star is still missed, on its first clause: *without contacting
support*. Every path here begins with an agent. This is the misalignment shape
that produces working software and a satisfied test suite — the one that survives
review by everyone who is not holding the goal.

## Why every task is individually sound

Each task names paths that exist or that it creates, and each `testCycle` names a
command plus an expected output — including the two whose central assertion is
that `auth.login` succeeds, so this column is *better* evidenced than
`unverifiable-goal`. `consumes` chains resolve inside the set. A feasibility lens
reading any one of these tasks against the codebase should return `yes`.

## Why a per-task lens might see it

Unlike `missing-final-step`, the contradiction is present **inside single
tasks**. `admin-temp-password`'s title and `produces` say a support agent issues
the credential; `admin-audit-entry` records an `agent_id`. A lens holding the
north star has everything it needs in one task object to notice the conflict
without any view of the set. That makes this fixture the corpus's strongest test
of the cheap hypothesis in #58 — that adding the goal to the packet is
sufficient and no alignment pass is needed.

Note what this fixture does *not* test: it cannot distinguish a lens that read
the goal from one that pattern-matched on the word "admin" appearing in a task
about passwords. The control column has no admin tasks, so a topic-matcher scores
perfectly here. Treat a detection as evidence only when the finding names the
goal clause it violates.

## What a generic finding would be

"Support-initiated password resets are a phishing and insider-abuse risk, and
temporary passwords should be one-time" is a real security observation and is
**not** a detection: it critiques the design on its own terms without reference
to the stated goal. A reviewer could raise it while believing the plan is exactly
what was asked for.
