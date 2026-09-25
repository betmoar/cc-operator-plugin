---
name: holdout
description: "Use when deriving, repairing or re-deriving a holdout — a check suite written from the spec by something that cannot read the code — or when a holdout check disagrees with the system, or when tempted to hand-edit one. Owns the procedure #112 learned over three derivation rounds and three repair dispatches (#150)."
---

A holdout is a check suite whose author could not read the implementation. Its
only property is that independence, and the cheapest wrong action — hand-editing
a derived check — destroys it while the artifact keeps its name and keeps
passing. This skill is the procedure; the measured history behind every rule is
`docs/maintainer/LANDMINES.md` § "The first check written by something that could not read
the code (0.11.16, #112)".

## 0. Where the holdout lives

Outside the builder's read scope — a separate repo the building session never
clones. A second GitHub repo buys that for free; an orphan branch or a local
directory is weaker (the builder can read both). **Never clone or read the
holdout from a session that builds the code it checks**: reading it puts its
assertions in context and the next check you write becomes a mirror of it.
Interact only by dispatching its run and reading its marker.

## 1. Prove the denial on this machine first

```
bash "${CLAUDE_PLUGIN_ROOT}/scripts/ops-holdout.sh" --canary
```

Exit 0 means a planted file in the cwd and a codeword in an ancestor
`CLAUDE.md` both stayed invisible to a process launched with the exact flags a
derivation uses. Exit 1 names which channel leaked — do not derive on that
machine until it passes. A subagent is never a substitute: one dispatched from
inside the repo inherits the project's `CLAUDE.md`, and "do not read scripts/"
is an instruction it cannot obey.

## 2. Derive

Write the context to a file OUTSIDE the project: the spec (for this plugin,
`templates/OPERATOR.md`) plus a **black-box interface block** — how to install,
which CLIs and hooks exist and how to invoke them, what they print. Nothing
about how they work. Then:

```
bash "${CLAUDE_PLUGIN_ROOT}/scripts/ops-holdout.sh" --derive --dir "$(mktemp -d)" < context.txt > holdout.sh
```

It refuses a non-empty `--dir`, an ancestor `CLAUDE.md`, and empty stdin. The
prompt carries three rules, each learned from a failure:

1. **Exact values, not properties.** A check that asserts "a limit applies"
   passes `LIMIT 1`; assert the number the spec fixes.
2. **Assert the promise and not one inch past it.** Where the spec says
   "warns / reports / names", assert the operator is INFORMED (the id, the task,
   the remedy appear), never that a particular word does. Where the spec fixes a
   string (a verdict word, an enum, a stamp form), assert it exactly.
3. **The black-box block is mandatory.** Without it the author invents file
   layouts and every check fails for reasons that are not defects.

## 3. When a check disagrees with the system

1. **Reproduce it by hand** against the shipped system, and write down the
   command and its output.
2. **Decide which side is wrong, in one line.** Measured on #112: one real
   defect to five over-assertions. Over-assertion (widening the promise,
   grepping for a word) is the independent writer's characteristic failure; a
   real defect is what you are there for. Do not decide before step 1.
3. **Dispatch the repair back** through `--derive`, carrying the measured
   output as evidence. **Never hand-edit a derived check** — ten minutes of
   editing converts the holdout into a mirror with no error anywhere.
4. **Cap at two rework rounds on one target** (the charter's same-target-rework
   cap). Round 3 on #112 regressed round 2's checks; the escalation was a
   different mechanism — repair-with-evidence — not a third prompt guess.

## 4. Acceptance: a green holdout proves nothing yet

Mutate the system so a promise breaks — a CLI body replaced by `exit 0`, an
installer that creates no ledger — and the holdout must go red. #112's 33/0 was
false: `ops-adopt.sh` as `exit 0` still gave 33/0. Refuse any check whose PASS
condition is `0`, an empty string, or an equality between two reads of a file
that may be absent — it cannot tell success from never having measured.

## 5. Gate on a marker, never a status

The run prints one positive marker naming the sha it checked
(`HOLDOUT_VERIFIED sha=<sha> checks=N`), and the caller asserts exactly that
string. A job status is not evidence: a skipped job and a passing one are both
green on GitHub Actions, and `conclusion` is always `null` on Forgejo 16. A
check count below the true count is slack a deletion hides in — keep the floor
at the real number.
