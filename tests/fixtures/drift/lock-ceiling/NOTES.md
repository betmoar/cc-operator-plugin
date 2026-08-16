# lock-ceiling — modeled on #70 instance 4

**Claim (drifted/lock.sh, line 2):** "Bounded at a 2s ceiling."

**The code that falsifies it:** `LOCK_MAX_SPINS=30` × `SPIN_SLEEP=0.1` ≈ 3
seconds, not 2. The comment states a numeric bound the constants directly
contradict — arithmetic anyone can check without running anything.

**≈, not =, and the correction is the fixture's own lesson.** The loop
increments `n` BEFORE the guard and sleeps only in the else path, so the
30th iteration returns without sleeping: **29 sleeps, 2.9s of sleep time**
(and ~3.7s of wall clock — see the third-pass note below).

`true/lock.sh` originally said "3s ceiling (30 spins of 0.1s)" and was
therefore *also* wrong — the corrected column carrying a smaller version of
the defect it exists to correct. Found on 2026-08-16 by the REPLAY-CHARTER R7
negative control (one `feasibility` lens, prompt verbatim, this file alone:
it went looking for the 2s claim and reported the off-by-one unprompted), and
its consequence named by a Copilot review of PR #72: **the false-positive
column must be actually clean, or the measurement's "zero drift
false-positives" conclusion is unsound** — a lens flagging `true/lock.sh` was
right, not spuriously firing.

A first pass left it as `≈` in the NOTES and the wrong claim in the file,
which is the same mistake one level up: recording the correction instead of
making it.

**And the second pass was still wrong.** "~2.9s" is the sum of the SLEEPS; a
comment-accuracy review timed the function against a held lock and measured
**3.68/3.67/3.69s (drifted) and 3.72/3.69/3.71s (true)** — 30 `mkdir` attempts
and the loop itself are not free, so a stated 2.9s ceiling is ~27% under. Three
versions of this comment, three precise numbers, three misses; the file now
separates sleep time from wall clock and states both. The teaching point was
never a duration — it is the counter-before-guard off-by-one — and a fixture
that keeps needing its own numbers corrected is evidence for stating the
mechanism rather than a figure.

The MEASUREMENT.md control column is re-read accordingly — see its "control
column" section.

**true/lock.sh** carries the corrected claim (bounded; 29 sleeps of 0.1s =
2.9s of SLEEP, ~3.7s of wall clock) against the identical constants and identical
`acquire_lock` body. Both variants behave identically: same retry count, same
sleep interval, same timeout message, same return codes.

**Which lens should have caught it and why it does not:** the real instance
(#70 #4) was found by the review panel itself on PR #67 — this is the one
instance of the six the panel *did* catch, which is why it makes a useful
negative-control-adjacent fixture: it shows the class is not universally
invisible, only invisible where the comment and the constant it describes
sit far enough apart (see `errno-claim`, `stdout-copies`) that no lens reads
them together. Here they are three lines apart and arithmetic, which is
squarely `correctness`'s "logic errors" question once it is told to check
numeric claims against constants, and `feasibility`'s "load-bearing claim
against the code." Both are plausible catches for this shape; the panel's
existing prompts do not explicitly instruct either to check arithmetic
comments, so detection is incidental rather than guaranteed — worth
measuring rather than assuming.

**What a correct detection must name to count as detected:** the specific
arithmetic — "the comment says 2s, the constants give 29 sleeps of 0.1s" — not a generic
"verify timing constants," which is equally applicable to `true/lock.sh` and
would be a false positive there. A detection naming "30 × 0.1 = 3s" counts as
a hit on the 2s claim but is itself imprecise, which is why this fixture
needed correcting twice.

**Functional-identity verification:** `LOCK_MAX_SPINS`, `SPIN_SLEEP`, and
`acquire_lock` are byte-identical between the two files; only the comment's
stated ceiling differs. Ran both:

```
$ bash -c 'source tests/fixtures/drift/lock-ceiling/drifted/lock.sh; d=$(mktemp -d)/l; time acquire_lock "$d"; echo rc=$?'
rc=0
$ bash -c 'source tests/fixtures/drift/lock-ceiling/true/lock.sh; d=$(mktemp -d)/l; time acquire_lock "$d"; echo rc=$?'
rc=0
```

identical behavior (immediate success on an unheld lock; both would spin
identically on a held one, since `LOCK_MAX_SPINS`/`SPIN_SLEEP` do not
differ between the files).

## Measured 2026-08-16

The prediction above said this is the one instance the panel already caught
on the real PR, that `correctness` and `feasibility` are both plausible
catches, and that detection here is "incidental rather than guaranteed" since
no prompt explicitly instructs checking arithmetic comments.

What actually happened (per `tests/fixtures/drift/MEASUREMENT.md`, drifted
column): `testability` **55**, `feasibility` **72**, `quality` **68**,
`correctness` **52**, `spec` **—**. **Four** lenses detected it — including
`quality`, which the prediction did not name as a candidate — but at this
fixture's lowest scores of the six (55/72/68/52). (An earlier draft said
"three" while quoting four scores on the same line; the arithmetic-comment
fixture had an arithmetic error in its own write-up.)

The prediction was **partly right**: it correctly named `feasibility` and
`correctness` as plausible catches, and both did detect. But "incidental
rather than guaranteed" is only partly supported — three lenses independently
caught it, which is not incidental in outcome, though the scores being the
lowest of the six does support the "not confidently anchored" half of the
claim. What it does not support: any suggestion of a miss, or of this being a
near-universal case relative to the others — it detected as reliably as the
rest, just with weaker confidence.
