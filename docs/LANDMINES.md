# Landmines (already hit — do not re-hit)

Extracted from `CLAUDE.md` so the 22 KB maintainer handoff stops loading into
every session. This file is the narrative register — *why* each already-hit
failure class is shaped the way it is. `CLAUDE.md` keeps the load-bearing map
and the coupling table (the always-on summary); the stories live here, read on
demand. The couplings that must not rot are enforced by `validate_plugin.py`
(`check_reader_bounds`, `check_guard_parity`, `check_lock_parity`), not by
being re-read every session.


- **Nothing in this system defines "the project" — each component decides
  locally, and they have disagreed.** `ops-task.sh` refuses to open a task
  outside the directory holding `.operator/`; `ops-stop-hook.sh` used to resolve
  `"$cwd/.operator"` by exact match, so a payload `cwd` one directory deeper
  found nothing and **allowed the stop with tasks still open** — the whole gate,
  silently off (audit F01, P0, pre-existing since before 0.4.0). The hook now
  walks up to the nearest `.operator/`, bounded at a `.git` boundary and at `/`.
  Any new component must use that same definition; `ops-init.sh` warns when it
  is scaffolding somewhere that is not the repo root, because a second ledger
  below the root would shadow the real one for everything beneath it.

- **A non-regular entry in `pending/` is not a task, and the opener must not
  claim it is.** `ops-task.sh`'s O_EXCL open failed on a directory or dangling
  symlink, and the `else`-branch conflated *every* redirection failure with
  EEXIST — printing "already open, ownership unchanged" and exiting 0 — while
  the Stop hook's `-f` guard refuses to count a non-regular entry as a task. So
  the operator was told a task was tracked and the session stopped **unblocked**:
  two components disagreeing about what a task is, the whole gate silently off.
  This is the same shape as F01 (the `.git`-boundary walk) — a disagreement
  between the opener and the hook, failing OPEN. Found by the review-panel
  pilot (2026-07-29), not by the 192-case suite or the audit: the suite tested
  the *hook's* handling of a directory but never the *opener's*. The fix: only a
  pre-existing **regular file** is a legit already-open; anything else is a
  fault that exits non-zero. The write is wrapped in `{ …; } 2>/dev/null` so
  bash's own EISDIR / dangling-symlink message does not leak as guidance (the
  *"raw bash error as operator guidance"* landmine, already fixed in the hook
  via `-f`).

- **A symlink guard applied at one site is a guard applied at none of the ones
  that matter (F65→F66).** The F65 `-L` rejection first landed only in
  `ops-task.sh`'s opener — the write path — while every *read* site kept plain
  `-f`, which FOLLOWS symlinks. A link planted in `pending/` was therefore
  adopted by `ops-adopt.sh` (whose temp-file rewrite then *laundered* it into
  a genuine regular-file sentinel), closable into VERDICTS.md by
  `ops-verdict.sh`, and read by the Stop hook and statusline as its target's
  owner — a foreign id waved the stop through (code-review of f4cae1a,
  2026-08-04; all reproduced live). Same PLAYBOOK rule as owner guards: apply
  at every reader, or the input class that is not ours walks in through the
  door you did not guard. Two corollaries from the same review: (a) the
  original F65 comment claimed `mv` over a destination symlink overwrites the
  link's *target* — measured false; `rename(2)` replaces the link itself, so
  the exposure was always the laundering, never a data overwrite; (b) both
  regression guards shipped with F64/F65 were bypassable — the validator's cap
  check was a substring test (`le 40` matched `-le 400000`) keyed to the
  literal variable name `_nulprobe`, and the bash test's 2MB fixture completed
  under its own 5s budget with the cap reverted. A guard that passes against
  the broken code guards nothing — prove discrimination by reverting
  (PLAYBOOK, "Verifying a fix"). Now enforced by `check_guard_parity`'s
  five-site `-L` check; the parsers degrade a symlink to unowned (blocks,
  fail closed), the mutating CLIs refuse loudly.

- **The Stop hook must use bash builtins + one JSON parser only.** It reads
  stdin with `read -r -d ''` (a line loop drops a newline-less final line — a
  real bug that once made the hook see an empty cwd and always exit 0) and
  enumerates `pending/` with a glob, not `find`. Reason: the hook fires on
  *every* session's Stop event; if it depends on a binary missing from a
  stripped PATH, it bricks the session. It must fail *open* (exit 0 + warning)
  when neither `jq` nor `python3` is present. The *"jq-absent fallback"* case
  proves this — keep it.
- **`ops-verdict.sh` refuses malformed cells; it never sanitizes.** A `|` or
  newline inside a cell breaks the one-line 4-cell row schema (the declared
  grep contract), and a task-id containing `/` once let `clear_sentinel`'s
  `rm -f` delete files *outside* `.operator/` (path traversal — a real bug,
  found and fixed 2026-07-10). Both are refused at the single writer with
  exit 2; the *"ledger cell hygiene"* case locks this. Do not "helpfully"
  escape or strip instead — a rewritten cell is no longer evidence.
- **`.operator/` and `OPERATOR.md` keep their names** even though the plugin is
  `cc-operator`. They are the ledger namespace and the charter filename, not the
  command namespace. Renaming them churns the scripts, tests, hook, and charter
  for zero functional gain.
- **The plugin lives at the repo root** (`source: "./"`), flattened from an
  earlier nested `./operator/` layout to match the cc-unknowns standard. Repo-
  relative script paths (in `tests/`) assume root; `${CLAUDE_PLUGIN_ROOT}`
  paths are layout-independent and were unaffected.
- **CI cannot run the live-session tests.** `tests/test-scripts.sh` exercises the
  hooks at fixture level (JSON on stdin). The *live* behavior — the Stop hook
  firing on a real turn-end, `SubagentStop` non-interference, and (0.4.0) that a
  real **SessionStart payload carries `cwd`** and its `additionalContext`
  actually reaches the model — was proven manually, not in CI. A green CI is
  necessary, not sufficient, for the gate; re-verify live after changing a hook.
- **The sentinel BODY is untrusted input.** It is an ordinary file: a merge, a
  checkout, or a patch can supply it, and `.operator/pending/` is not
  gitignored. The stamped owner becomes a fragment *filename*, so an
  unvalidated one reopened the 2026-07-10 traversal through a new door —
  `session_id: ../../PWNED` appended a real ledger row outside `.operator/`
  (found in review of 0.4.0, reproduced, fixed before release). Both
  `sentinel_owner` parsers sanitize **at the parser**, never at the call site,
  so every consumer is covered by construction; an unusable owner degrades to
  `""` = unowned = blocks everyone. Any new reader of that file must do the
  same. Related: strip trailing `\r` — a CRLF checkout otherwise makes a
  session's own id compare unequal and its own task get waved through as
  foreign, a fail-OPEN in the central invariant.
- **Ownership transitions must be atomic, and a sequential test cannot see it.**
  Two TOCTOUs shipped in 0.4.0's first draft: `ops-task.sh` created the sentinel
  with test-then-truncate (two openers both won — 155/200 trials), and
  `ops-verdict.sh` read the owner *before* taking the lock, so an adopt landing
  in between let the former owner delete the new owner's sentinel. Rules that
  follow: sentinel creation uses `set -C` (`O_EXCL`) so the kernel arbitrates,
  never a `[ -e ]` guard; and `ops-adopt.sh` shares `ops-verdict.sh`'s lock,
  with ownership validated *inside* it — the two tools both mutate ownership, so
  validate-then-act must be indivisible across them. The open race is caught by
  a 40-trial loop; the adopt/verdict window is microseconds and does **not**
  reproduce under test, so that assertion is a regression guard only. Treating
  it as evidence would be exactly the "test proves nothing" trap noted below.
- **An owner that can never match is worse than no owner.** The hook compares
  the stamped owner byte-for-byte against the payload's session id, so any
  value a real session id cannot equal — whitespace, a stray space inside —
  classifies the task FOREIGN forever, and foreign never blocks. That is a
  silently disarmed gate reached by a typo (`--owner " SESS-A"`, found in
  review of 0.4.0). Hence: whitespace is refused at all three CLIs *and*
  mapped to unowned in both parsers. Any new owner-shaped field needs both
  halves — refusing at the CLI alone leaves hand-written sentinels unguarded.
  **But that rule is about owners, not names in general.** `check_owner_name`
  is deliberately separate from `check_bare_name`: an interim fix applied the
  whitespace rule to task ids too, which wedged every pre-0.4 task whose id
  held a space (0.3.0 accepted them) — the hook kept blocking while verdict,
  defer, *and* adopt all refused the id, so the session could never stop. When
  tightening a guard, ask which of the two things it is guarding; a rule
  justified by "can never equal a session id" has no bearing on a task id.
- **Anything the Stop hook reads must be bounded.** It fires on *every*
  session's Stop event, so an unbounded read is the same class of hazard as a
  missing binary: a 2 MB sentinel cost ~10s per turn-end tree-wide. The parse
  stops at 20 lines (the owner is line 1 by construction) and the enumeration
  requires `-f` — a directory in `pending/` otherwise emitted a raw bash error
  *as operator guidance*. **`statusline.sh` is the same rule at 1000× the
  frequency**: it renders on Claude Code's ~300ms timer, so the 64 MB
  newline-less sentinel that costs the hook one slow turn-end costs the bar
  6.20s *per render* — permanently wedged, not slow (measured; bounded is
  0.014s). It is registered in `check_reader_bounds` like the other three.
  Its two `read -r` calls over the python3 pipe carry `-n 4096` they do not
  strictly need, so the guard needs no carve-out for "that one reads a pipe" —
  a guard with an exception is one the next maintainer argues with.
- **Nothing but sentinels may live in `.operator/pending/`.** The hook globs
  that directory and treats every entry as a task id. `ops-adopt.sh` originally
  wrote its temp file there, so a crashed adopt left a phantom pending task
  that blocked the session and could be closed into the ledger as a garbage
  row. Temps go in `.operator/`, never `pending/`.
- **A sentinel the Stop hook cannot SEE is worse than no sentinel.** The hook
  enumerates `pending/` with a plain glob, which does not match dotfiles — so a
  `.hidden` task-id created an open task that never blocked (found in review of
  0.4.0, before release). Every name that becomes a filename is refused a
  leading dot in *all three* CLIs; the rule subsumes the older `.`/`..`
  traversal guard. The *"name guards agree"* case asserts the glob premise
  itself, not just the guard, so the reason cannot rot. If you ever switch the
  hook to `dotglob` or `find`, this rule is what you are trading away.
- **A guard that searches text it has already stripped fails OPEN, silently.**
  `check_source_stamp` asserts the U10 stamp is resolved *before* `lock_acquire`.
  It stripped comment lines first (right — the header prose names every marker,
  so a gutted resolver would otherwise satisfy the scan), then located the
  verdict path by splitting on `# --- Verdict path ---`, which is itself a
  comment it had just removed. The split found nothing, the not-found branch
  skipped the assertion, and a mutation moving the stamp inside the lock passed
  a green build. Two rules came out of it, and the second is the one that
  generalizes: **find the region in the raw text, strip inside it** — order the
  two operations so the second never eats the first's landmark; and **not-found
  is a reported problem, never a skip**, or the guard's own blind spot is
  indistinguishable from a clean result. The bash twin (`S1.10`) had the same
  hole from the other direction — it matched the prose that *mentions*
  `source_stamp` rather than the assignment — and the same mutation caught both.
- **Count cells; never glob them.** `'| '*' | '*' | '*' | PASS |'` looks like a
  4-cell schema check and is not one: `*` matches ` | ` too, so a 5-cell row
  satisfied it and `--reconcile` appended it to the ledger. Any future schema
  check splits on the delimiter and counts (`row_is_conformant`). The same trap
  applies to any "shape" assertion written as a glob.
- **An unexpirable claim is a deadlock with extra steps.** The `.lock.reclaim`
  marker below was first written with no expiry, so a process killed while
  holding it wedged every later writer *forever* — worse than the stale lock it
  fixed, which at least proceeded after a budget. Every wait in this codebase
  must be bounded and must degrade to a *milder* failure, never a hang: deferral
  to a claim is capped, then the claim is presumed dead. Ask of any new wait:
  what happens if the thing I am waiting for never returns?
- **`read -r` is bounded by lines, not bytes — and `read -N` is not a fix.** A
  newline-less 256 MB file is one "line" and gets slurped whole before any line
  counter runs (8.5s on *every* Stop event). Use `read -r -n N`, which stops at
  N chars *or* the newline. Do not "simplify" to `read -N` (capital): it ignores
  newlines, returned an empty chunk here, and made every sentinel parse as
  unowned — every session blocking on every task, with the whole suite still
  green because nothing asserted the partition through the real parser on a
  normal sentinel. The *"parser regression guard"* assertions exist for that.
- **A lock whose reclaim path is not itself exclusive is not a lock.** The naive
  timeout — `rmdir` the stale dir, `mkdir` your own — lets waiter B delete
  waiter A's *fresh* lock and enter beside it, with neither over budget.
  Reclaiming requires winning a separate atomic `.lock.reclaim` claim first.
  `ops-verdict.sh` and `ops-adopt.sh` share this implementation; parity is now
  enforced by `validate_plugin.check_lock_parity` over the `# >>> LOCK BLOCK`
  markers, because "keep them identical" as prose is exactly the kind of
  coupling that rots (it is the same lesson as `check_reader_bounds`).
- **Never infer a crash from elapsed time when you can ask the kernel.** The
  first draft of the lock presumed any holder over budget dead, which cannot
  distinguish a slow writer from a dead one — a `--reconcile` that ran long had
  its lock reclaimed
  *while still inside the critical section* (audit F03; reproduced directly:
  a live 30s holder got "assuming a crashed writer and reclaiming it"). F03
  bounded the trigger; this removed the inference. The holder stamps
  `host uid pid` into `.lock/holder` and waiters run `kill -0`: dead → reclaim
  at once (the draft made them wait out the full 30s — measured 34s), **alive →
  never reclaim**, unjudgeable → fall back to the old timed path. The third
  branch is load-bearing: `kill -0` on another user's process fails with EPERM,
  which reads exactly like "dead", so judging a foreign uid would reclaim a LIVE
  lock — the fail-OPEN direction. Only our own host+uid are judgeable. The
  unjudgeable branch is hot, not a compatibility path: `mkdir` and the stamp are
  not one atomic step, so every lock is briefly held-but-unstamped (400/400
  samples) and a waiter landing there must not judge it.
- **The stamp is also what makes the lock un-stealable, and that is not
  incidental.** A stamped `.lock/` is a *non-empty* directory, and `rmdir`
  refuses those — so a reclaimer cannot remove a lock a healthy process has
  stamped without first deleting the stamp, which it only does after judging the
  holder dead. That deterministic property, not the timing, is what closes the
  two-reclaimer race; the *"a held lock is stamped, and a stamped lock cannot be
  rmdir'd"* case asserts it and fails the moment anyone drops the stamp.
  Corollary for test authors: a stamped lock survives a plain `rm -rf` of the
  tree, so teardown must remove `holder` first.
- **The two-simultaneous-reclaimers race cannot be reached by black-box
  timing — stop trying.** Backlog #2 asked for a discriminating test; six
  approaches were measured against a deliberately naive copy (cold-start racing,
  a ~1s critical section, killing a live holder while both waiters spun, and
  0.4s of fault injection in the reclaim path) and every one read **0/N**. The
  reclaim sequence is microseconds against a 0.1s spin, so P(collision) ≈ 1e-5.
  Reaching it would require shipping an injection point inside `lock_acquire` —
  trading a real hazard for a test. The structural assertion above is the
  stronger guarantee and is deterministic; that is the trade taken.
- **`--reconcile` is a write to the ledger of record, so it validates.** It
  originally copied fragment lines verbatim, which routed around the single
  writer's cell hygiene entirely — a merge-corrupted fragment could inject a
  non-conformant row. Any future path that appends to `VERDICTS.md` must
  enforce the 4-cell schema too, or it reopens the same hole.
- **A concurrency test that only asserts the output schema proves nothing.**
  A short `printf` usually lands atomically on a local FS *without* any lock, so
  "100 well-formed rows" passes on the unlocked code too. The *"concurrent
  appends"* case therefore also takes the lock dir by hand and asserts a writer
  waits — that is the assertion that would fail if the lock were removed. Keep it.
- **`git check-ignore -v` is not a test for "is this ignored".** It prints the
  last *matching* rule and exits 0 for a `!` negation too — and a negation means
  the path is explicitly **allowed**. So "non-empty `-v` output" reads as
  *ignored* when the truth is the opposite. `-q`'s exit status is the only
  honest answer. This has now cost the project twice in one release: once by
  hand, where it produced a confident "the allowlist fix failed" reading against
  a fix that had in fact worked; once by a simplifier collapsing `ops-init.sh`'s
  deliberate two calls (`-q` to test, `-v` to name the rule in the message) into
  a single `-v`, which inverted the #25 warning for every project the v2
  scaffold creates and was caught only because a case asserts a healthy project
  stays quiet. The two calls in `ops-init.sh` are load-bearing; the comment
  there says so.
- **A control assertion that cannot pass, and CI that cannot see it.** A control
  drove `sed -n "/^f() {$/,/^}$/p"` inside `"$( … )"` to extract a function and
  `eval` it. Under bash 5 that is correct. Under bash 3.2 — still `/bin/bash` on
  every macOS — the nested double quotes do not survive the parse, `{$/,/^}`
  becomes a **brace expansion**, sed receives a split script (`invalid command
  code $`), the function is never defined, and the assertion fails on every run.
  So the local suite was red on the maintainer's own machine while ubuntu's bash
  5 parsed it fine and CI reported green — the one signal anyone actually looks
  at. Note which assertion it was: the *control*, the thing whose whole job is to
  prove the guard beside it was exercised. That is #21's class with the polarity
  inverted — not a guard that cannot fail, a control that cannot pass — and the
  inverted form is harder to notice, because a red local run reads as flakiness
  while a green CI run reads as truth. Two fixes, and both were needed: the
  extraction is single-quoted (nothing in a sed address needs interpolation, and
  a single-quoted script is immune at every nesting depth), and
  `check_platform_idioms` now bans the shape statically, which is the only way
  the ban reaches CI at all — a bash-5 runner can never reproduce the bug it is
  meant to catch. Prefer a heredoc probe script over a nested `bash -c` one-liner
  when a test needs to run extracted code; the sibling assertion twenty lines
  above had done exactly that and was always green.
- **A statusline assertion that was really an assertion about the maintainer's
  desk.** Three cases claimed *"degenerate stdin renders nothing"* while running
  with cwd = **this repository**. When the payload cannot be parsed there is no
  cwd to read, so `statusline.sh:84` falls back to `$PWD` deliberately (the bar
  renders for where it stands). The repo had never had `.operator/` scaffolded in
  it, so the fallback found no ledger and the three cases passed — for a reason
  nothing to do with degenerate stdin. Opening one real task in the plugin's own
  tree turned all three red at once with the renderer behaving exactly as
  designed, which is how it was found: the gate cannot be dogfooded in its own
  repo without tripping its own suite. They now run from a temp dir with no
  `.operator/` at or above it, **and** a positive control pins the fallback from a
  cwd that does have a pending sentinel — without that control, deleting the
  `$PWD` fallback outright would leave all three green. Vacuous-guard class
  reached through ambient state rather than a missing call site: if an assertion's
  verdict depends on anything outside its fixture, it is measuring the
  environment, and the environment is not under test.
- **A measurement fixture that documents itself hands the seat the answer.** The
  plan-alignment corpus (#58) ships a small synthetic project for the feasibility
  lens to read. Being a good maintainer, its `README.md` explained the design —
  including *"A plan that never writes that field cannot produce a user who signs
  in"*, which is one fixture's defect stated outright, in the tree the lens reads.
  Three module docstrings said "fixture". The corpus's pins were thorough about
  the task JSON and silent about the codebase sitting beside it, because
  neutralization had been reasoned about only for the artifact under test. Caught
  by generating the prompts and grepping them, one step before 42 seats would have
  scored a measurement whose answer was written down in its own input. The lesson
  generalises past this corpus: **everything a seat can reach is input**, which
  includes absolute paths (the first prompt generation put `plan-align` in every
  one) and filenames (the first batch of prompt files was named
  `<column>__<lens>__<task>.txt`). The first fix was itself the lesson repeating:
  the scan walked `*.py`, exempted the README, and rested on a *promise* that a
  dispatch excludes it — a review measured that nothing pinned the promise. The
  README is now ordinary project documentation and the scan walks every file, so
  there is no separation left to remember. When a guard's correctness depends on
  a step someone must remember to take, widen the guard until it does not.
- **Reasoning about degenerate input is not the same as running it.** The #66
  graph work was argued to be cycle-proof by construction (`dependsOn` scans only
  earlier tasks) — correct, and still worth nothing until a back-reference fixture
  went through the shipped code and came out a DAG. Six degenerate shapes a
  *model* can emit — duplicate ids, a task consuming its own output, a
  back-reference, empty `produces`, punctuation-only contract text, a single task
  — all ran without throwing and without reaching `blocked`. The argument would
  have been right and unevidenced; the run costs a minute. This is the same
  register as "a compile is not proof the feature works", applied to a report
  nobody would think to fuzz because it is advisory.
