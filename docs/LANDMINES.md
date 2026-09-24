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
  cwd to read, so `statusline.sh`'s `PROJ` resolution falls back to `$PWD` deliberately (the bar
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

## Extracted from the coupling table (0.11.2)

These are the *why* halves of `CLAUDE.md`'s "If you touch X, update Y" rows. They
were living inside the table itself, which loads into every session; the rows now
carry the coupling and point here. Nothing below was reworded — it is the same
reasoning, moved.

- **A stale `.operator/bin/` is the gate a session actually runs.** The refresh
  trigger in `ops-sessionstart-hook.sh` keeps TWO clauses, a version-string change
  **or** `_bin_stale`. Version alone was #34: every intra-version fix to a gate CLI
  stayed invisible because `plugin.json` had not moved, so a project kept running
  the broken predecessor of a fix while the plugin tree's own tests passed. The
  charter points the model at `.operator/bin/…`, so that copy IS the gate. Note the
  asymmetry: **hooks** resolve through `${CLAUDE_PLUGIN_ROOT}/scripts/…` and are
  current immediately, so hooks and `bin/` can sit at different commits at once.
  The two halves must also agree about an ABSENT source (#82): both carried
  `[ -f … ] || continue`, so a manifest-named CLI with no shipped file was skipped,
  `_upgrade_ok` stayed 1, `.version` recorded a completed upgrade over a partial
  `bin/`, and the probe — the only retry trigger once the version stops moving —
  never reported it: `version == stamp` forever. Measured: 2 of 3 copied, stamped
  current, no warning. The comment above the trigger reasoned about an EMPTY set
  doing exactly this and guarded it; an INCOMPLETE one went unguarded. Fail-OPEN
  stays: the shipped CLIs still land, and the skip is announced. The `#82` cases
  carry both CONTROLs — a complete manifest DOES stamp and warns about nothing,
  because a fix that never stamps is the same bug inverted.

- **A pin is a hypothesis until the mutation runs red.** The `pin-auditor` agent
  audited 25 validator checks on 2026-08-25 (84 mutations, tmpdir copies) and found
  four VACUOUS pins with nothing behind them; reviewing that audit found six more of
  the same shapes. The list is therefore not exhaustive, and the method — mutate,
  watch it go red, restore byte-identically — is the point. The measured escapes:
  - **A substring test asks "is this text present", never "does it run"** —
    `"autobar.sh" in hcode` was satisfied by an `echo`, `true # bash "…/ops-stop-hook.sh"`
    satisfied both of `check_hook`'s tests while running nothing, and
    `for _cdir in ; do  # was: .compress-spill …` satisfied a raw-text test with the
    wipe loop emptied.
  - **A count is not a value**: `read -r -n \d+` counted occurrences and never read
    N, so `268435456` was "a bound".
  - **A literal is not the contents**: `new Set([…])` is mutable, and
    `ELIDABLE.add("Read")` after the declaration changed what gets elided with every
    literal pin green.
  - **A parity check cannot see uniform drift** (F30): `check_lock_parity` compared
    two copies and pinned no content, so inflating the holder read in BOTH left them
    perfectly in parity — F30 committed inside the check whose docstring teaches F30.
  - **A glob is narrower than the docstring**: `scripts/*.sh` does not match
    `scripts/lib/`, where the two libs the gate sources live; `[ -w ]` does not match
    `test -w`; `"([^"]*)"` does not match single quotes.
  - **`if (false)` / `if 0 and` / a preceding `if (false) if (…)`** put a pinned
    literal where it cannot run.
  - **An ANCHOR is not reachability**: `if (false) if (…)` was rejected while
    `if (false) { … }` walked past — the fix is brace depth against a named anchor,
    and if the anchor is renamed the check REPORTS rather than passing.
  - **A COMMENT-BEARING raw read is not code**: the lock pin searched the raw block,
    so commenting out the real `while ! mkdir` and leaving the text in a comment
    satisfied it.
  - **A METHOD LIST is not every write**: `GATE_CLIS.length = 0` and `X[0] = …` are
    not method calls.
  - **INDEX ZERO is not the collection, at either level**: `hooks[event][0]["hooks"]`
    counted the inner list while a second MATCHER GROUP registered an unreviewed hook.
    A STEP scan likewise cannot see a JOB-level `if: false`.
  - **A byte cap is only a byte cap in the C locale** — bash `read -n N` counts
    CHARACTERS outside it, so every cap in a UTF-8 locale is up to 4x looser than it
    reads (measured: 512 chars of `é` = 1024 bytes on bash 3.2.57 and 5.2.15). This
    one is enforced now: a file with byte-bounded reads and no `LC_ALL=C` fails, and
    the declaration belongs in the reading function (`local LC_ALL=C`), never globally.

- **The seat table in `workflows/dispatch.js` is a literal map on purpose.** A
  computed `"cc-operator:op-" + seat` is invisible to `check_workflow_agent_types`
  (it matches the string by regex), so a typo'd or removed seat would ship green and
  fail at dispatch — F22's class. That checker matches the VALUE, not the
  `agentType:` key: the key form was blind to the one file that most needed it, since
  `dispatch.js` resolves its agentType from the table and passes the shorthand
  `agentType,` — a review measured every SEATS value retyped to a nonexistent agent
  shipping green. It reads a comment-STRIPPED view, because `dispatch.js`'s own prose
  quotes the concatenated form it argues against.

- **A catalogue of another system's facts goes stale, and the machinery working is
  not the same as the list being right.** Until 0.8.2 the model-id guard carried an
  id-shape catalogue (`glm-*`, `claude-*`, `vendor/model`) plus a provider-lens
  allowlist mirroring cc-proxy's `PROVIDER_IDS` — both lists of facts about ANOTHER
  system, pinned in `validate_plugin.py` and held in exact agreement across seven
  copies. Measured against a live cc-proxy serving 409 ids it refused 8 that route
  fine (`deepseek-v4-flash`, `qwen3.8-max` — bare vendor ids with neither a known
  prefix nor a slash), so a user binding one in `tiers.env` got a refusal citing a
  catalogue they never asked about. What remains judges WELL-FORMEDNESS only, which
  cannot go stale.

- **The auto-arm cannot tell a dead session from a busy one, and that is why it has
  no suppression rule.** Porcelain measures the tree, not the session, so in a shared
  worktree `autobar` can arm a session for another's delta. Two rules were tried to
  prevent that and both were REMOVED. The first stood down on a foreign
  `verdicts.d/<sid>.md` fragment: append-only, never wiped, so one verdict by any
  other session ever disarmed the gate for the project's life. The second stood down
  on a foreign OPEN sentinel, on the reading that `pending/` is live state — but an
  OPEN sentinel means "working OR died", nothing reaps `pending/`, and one crash or
  `/clear` mid-task stranded a sentinel that darkened the armer permanently, in
  single-operator projects too. No third rule is possible here: splitting the two
  needs a liveness oracle the filesystem lacks (a sentinel carries no pid; a pid
  would be dead anyway since `ops-task.sh` exits at CLI return while the owning
  session runs; a session is a harness token with no OS handle; bash 3.2's
  whole-second mtime cannot separate stale from concurrent). The trade is priced:
  arming wrongly costs ONE arm on the session's own sentinel, capped by the
  `.autobar/<sid>` marker, announced on the BLOCKING channel with a co-presence
  sentence, cleared by one `--defer` (no `--owner` needed — it warns and proceeds;
  the hard refusal fires only on a MISMATCHED owner). Suppressing wrongly cost the
  gate permanently, on a channel that only printed exit-0 warnings — the suppression
  reason was computed and DISCARDED, its only reader inside the arm branch. Reopen
  only with a liveness signal the kernel can answer for a SESSION; a PostToolUse
  heartbeat is not one — a session idle at the prompt reads dead past any threshold.
  Two mechanical notes from the same work: a `|| true` on the sentinel write left the
  marker set with no sentinel, and `autobar_already_armed` then read the session as
  armed for life — a permanent silent disarm that survived repairing the obstruction.
  And an unmarked arm re-fires at the next Stop forever, because recording a verdict
  does not un-change the files: a session that cannot stop is worse than one that
  stops unaudited. `-uall` shipped missing once — porcelain's default untracked mode
  collapses a new directory to ONE record, so three files under `src/feature/` counted
  as 1 and the gate stayed silent on the exact multi-file session it exists to catch
  (the same three at the repo root armed, which is the control). One more correction
  worth keeping: `autobar.sh` was sourced after `partition.sh` because it called
  `sentinel_owner_of_name` — true only until `e839490` deleted the suppression rule.
  Four places kept citing that dead call as the reason (the coupling row, the hook's
  comment, `check_autobar`'s failure MESSAGE, and a test docstring), corrected in the
  #86 review. The order still holds, for the reason that is true.

- **Isolation buys a clean tree, not a commit.** The runtime's
  `isolation: "worktree"` takes NO commit — the worktree is created at the DEFAULT
  BRANCH, measured twice with different requested shas both landing nine commits
  earlier. So `args.isolate` buys the clean ENVIRONMENT only, and the default prompt
  must say so: the seat is told a HEAD mismatch is EXPECTED and must NOT be refuted,
  because refuting the harness costs a real REFUTED nobody can act on.
  `args.isolateCheckout: true` opts into `git checkout --detach <sha>` first, which
  buys commit identity and leaves the worktree on disk (the runtime auto-removes only
  an UNCHANGED one) — default off so no caller's behaviour moves. The two prompt
  branches are EXCLUSIVE, or the seat is told both that the sha is required and that
  missing it is fine. `atRequestedCommit` is the field that stops the overclaim:
  `mode: "worktree"` + `requestedCommit` rendered a default-branch run and a real one
  identically, and for the plugin's whole life it was always the former.

- **The two CI files cannot be identical, and no validator pins them.**
  `.github/workflows/validate.yml` and `.forgejo/workflows/validate.yml` run the same
  suites with two deliberate, measured divergences. First, `uses:` must be fully
  qualified on Forgejo (a bare `actions/checkout@v4` pulls from `data.forgejo.org`)
  and `act` cannot parse that form — so the forge file is NOT act-runnable: dry-run
  the GitHub copy, prove the forge copy by pushing to `lokaal`. Second, the forge job
  has **no docker**: `DOCKER_HOST` unset, no CLI (probed 2026-08-25; the host's
  `forgejo-runner-dind` belongs to the runner, not the job), so shellcheck comes from
  the arch-detected release tarball, not `docker run`. The runner is aarch64. Same
  shape for `release.yml`: the forge copy publishes with a plain POST (`gh` cannot
  reach a Gitea API) and CHECKS the status, because an unchecked create leaves the tag
  pushed and every suite green with no release object. `GITHUB_SERVER_URL` there is
  `http://forgejo:3000` — the short name, which LAN DNS serves exactly like the FQDN
  (measured), so the returned `html_url` needs no rewriting. Embedding python in a
  `run:` block: single-line `python3 -c` only — a heredoc terminator or a continuation
  line at column 0 closes the YAML block scalar, and since the forge files are not
  act-runnable, `yaml.safe_load` is the only pre-push check there is.

## From the 2026-08-31 principal audit (F101–F134)

- **A "lossless" tier is one stripped byte from a destroyer, and raw control
  bytes in a regex literal do not survive handling.** `scrub()`'s two ANSI
  regexes carried their ESC anchors as RAW `\x1b` bytes; the 0.10.0 debloat
  commit re-emitted the file without them, and the OSC pattern's empty
  alternation then matched from the first bare `]` to end-of-string. Every
  `]`-bearing tool output over 1KB — test logs, JSON, build output — was
  silently replaced with garbage (measured: a 3KB `[ok]…[FAIL]` log became the
  single character `k`), with no marker and no spill, because the destruction
  happened in the tier whose name promised it could not. The suite stayed green
  for a full release because no test input contained a bare `]`, and its one
  ANSI case asserted only the spill's fidelity, never the in-context text
  (audit F120, P0). Three rules fall out: control characters in source live as
  ESCAPES (`\x1b`), never as bytes; a "lossless" transformation gets a
  does-nothing-on-plain-text test (the identity property IS the contract); and
  a validator pin on the anchor (`check_compressor`) because the byte is
  enforced, not remembered — the same ruling as the C-locale byte caps.

- **A vacuity probe is cheap, and seven pins failed it in one afternoon.** The
  2026-08-25 pin-audit found ten vacuous pins and this repo wrote the METHOD
  into CLAUDE.md; the 2026-08-31 audit ran the method against 12 more pins and
  seven were mention-satisfiable, presence-only, or prefix-satisfiable (audit
  F126–F130, F132): a comment naming `partition.sh` satisfied the sourcing pin
  while the source line was an `echo`; a gutted `check_owner_name(){ :; }`
  passed guard parity; `for tool in $_OPS_TOOLS statusline.sh` passed the
  manifest-loop pin. The recurring shapes: a pin that greps RAW text is
  satisfied by comments (run pins on the comment-stripped view); a pin that
  proves a function EXISTS proves nothing about its arms (pin the arm literals
  and their die-polarity); a pin without an anchor after the load-bearing token
  accepts arbitrary suffixes (anchor through the next syntactic element). The
  fixed pins each carry the exact escape as a red python test.

- **Two hooks that define "the project" differently re-create F01 on whichever
  side kept the old definition.** The Stop hook got the walk-up in the F01 fix;
  the SessionStart hook kept the exact match for another year, so a session
  launched in a subdirectory lost the id banner (sentinels opened unowned),
  the legacy migration, the bin/ upgrade (#34's delivery channel), and the
  ephemera wipes — every one silently, while the Stop hook from the same cwd
  gated correctly (audit F101). When a resolution rule is fixed in one
  component, grep for the OTHER components that answer the same question:
  "who else decides what the project is?" was answerable by `grep -l
  '.operator" ] || exit'` the whole time.

- **The seat-identity spread order in a fan-out is a security boundary.** A
  workflow that records `{...pins, ...(agentOutput)}` lets the agent overwrite
  the pins — in debate.js a returned `model:` key re-routed the seat's later
  rounds onto an agent-chosen id (bypassing BAD_CHARSET, the only id guard
  left), a returned `letter:` emptied both rival pools so a seat "converged"
  with itself, and a returned `dead:true` removed a live seat (audit F103).
  Output spreads FIRST, pins come LAST, at every round — and the stub-runtime
  test carries exactly those three forged keys.

## From the 2026-09-02 principal audit (F135–F139)

- **A bucket that COUNTS a thing but does not NAME it opens the gate on it.**
  `scan_pending` counted an empty-id sentinel (`sid__`, `__`) as MINE — the
  bar rendered `op[N]` red — but appended `""` to `MINE_IDS`, and the Stop
  hook's block condition is `[ -n "$pending" ]`, the LIST. With only such
  names pending the hook returned 0 with no message while the bar said
  blocked (audit F135; measured on the pre-#99 code too — the F118 fix walked
  past it). Sharing `partition.sh` makes the hook and the bar read the same
  BUCKETS; it does not make them take the same DECISION unless every bucket
  feeds the decision the same way. When a reader branches on a derived string
  (a list, a joined description) rather than the count, every element that
  can be empty is a silent hole. The bucket is MALFORMED now, with the
  `rm -f` remedy, because both writer guards refuse an empty id.
- **Two readers of one name convention with two split rules disagree about
  what a file IS.** The readers split `pending/<owner>__<task>` on the FIRST
  `__`; the CLIs resolved a task id with the glob `*__<id>`, whose `*` spans a
  `__` — so a planted `A__B__C` was task `B__C` to the hook and task `C` to
  every CLI. `ops-task.sh C` said "already open" (rc 0) for a task that was
  never opened; `ops-adopt.sh --owner me C` RENAMED the malformed file into a
  well-formed `me__C` (audit F136). A glob is a parser, and when it stands
  beside a string-split parser of the same name the two must agree on every
  input they can both see — the task-half filter at all four glob sites is
  that agreement, and `check_guard_parity` pins it because one site without
  it is the drift that ships green.
- **A pin added to one of two twins is the F116 shape one layer up.** The PR
  #97 review made BOTH gitignore writers atomic; the atomic-swap pin covered
  the hook only, and reverting `ops-init.sh`'s write to the non-atomic shape
  reported "all contracts hold" (audit F137). When a review fixes a class at
  N sites, the pin count is N, not 1 — and the check for that is a mutation
  at EACH site, which is the vacuity method again.
- **Runbook expectations rot on the line you did not re-read.** The 0.11.2
  fix updated REPLAY-CHARTER's deviation-gate expectation to the absolute
  path shape and left the R2b pending-verdict expectation on the pre-#94
  relative shape (audit F139). A live replay would have reported a defect on
  a correct hook. The charter's quoted strings are hand-maintained by
  decision; the price is grepping the runbook for every message you change.
- **A substring pin on a function body is blind to control flow — execute
  the function.** `check_claims` pinned `*/)` and `[[ $p == $pat ]]` INSIDE
  `matches_protected`'s body, and its own comment named the escape it was
  written against: "gutted to `return 1`". Inserting exactly that as the
  first body line, literals intact, shipped "all contracts hold" (audit
  F140; the pin-auditor found six more "literal present, behaviour gone"
  siblings — a dead branch before the arm, a decoy loop, a value kept alive
  in a same-line comment). When the property is BEHAVIOUR, the only
  non-vacuous pin runs the code: `bash -c` the shipped function against
  probes with known answers. Same lesson for the workflow `meta`: two pins
  enumerated two spellings of "computed" (`+`, backtick) and a call
  expression walked past both (F141) — pin the STRUCTURE (only literal values
  survive string-stripping), not the spellings you have met.

## From the 2026-09-02 backlog closure (F144)

- **Six vacuities of the same shape, closed by executing instead of
  grepping.** The 0.11.6 audit's pin-auditor arm listed six "literal present,
  behaviour gone" siblings and deferred them as a validator-MESSAGE gap —
  each was still caught by another suite, so no hole was open. Closing them
  one grep at a time is the enumeration F140/F141 argue against, so each was
  replaced by a probe that runs the shipped code:
  - `check_guard_parity` runs `check_bare_name`/`check_owner_name` in a child
    bash. The escape they could not see: a dead `?*) : ;;` arm inserted BEFORE
    the real arms. `case` takes the FIRST match and `?*` matches every
    non-empty string, so all four rejections stopped happening while `.*)`,
    `*__*`, the metacharacter set and their `die`s stayed spelled out on the
    page.
  - `check_autobar` runs `autobar_count_changed` against a scratch repo. The
    escape: `-uall` moved into a TRAILING comment — `shell_code()` strips
    whole-line comments only, so the literal stayed inside the body while the
    flag never reached git. The same probe covers the `':(exclude).operator'`
    pathspec, which had no pin at all: without it the counter sees the gate's
    own sentinel writes and arms on its own bookkeeping.
  - `check_compressor` imports the module and runs scrub through `compress()`.
    The escape: an UNANCHORED regex in the live `.replace()` chain plus a
    correctly-anchored copy inside `if (false)`. Both F120 literal pins green,
    F120 itself restored.
  - `check_decisions_schema` parses the emitted ROW rather than asking whether
    some printf carries the marker. The escape: `HANDOFF-MARKX`, which no
    reader matches, while `check_owner_name`'s die message kept the correct
    literal alive elsewhere in the file.
  - `check_install_set_parity` requires the manifest loop's BODY to copy. The
    escape: `for _tool in $_OPS_TOOLS; do :; done` beside a second loop over a
    hardcoded list. Writing that pin found a second-order version of the same
    bug in the pin: a non-greedy `(.*?)\n\s*done` paired the DECOY's head with
    the REAL loop's body, because the decoy's inline `done` sits on its `do`
    line — the compliant-looking pair satisfied the new check, which reported
    "all contracts hold" on the mutation it was written to catch. `do`/`done`
    are matched like brackets now. A pin is a hypothesis until the mutation
    runs red, and that applies to the pin you just wrote.
  - `check_gitignore_parity`'s detection pin keys on the target BEING the live
    path, not on its not being `.tmp`. The escape: retarget detection to
    `"$_gi.v1.bak"` — not a temp, so it passed — which inverts the branch,
    because the backup does not exist until the migration this read triggers
    has already run.
- **A behaviour probe needs the refuses-everything control.** Rejection probes
  alone are satisfied by a guard that dies on every input, which would trade
  one vacuity for another. Every executable pin here asserts the ordinary case
  passes too, and that control is what caught the under-built fixtures: five
  good-tree stubs had to grow real behaviour (a counter that sets its output
  variables, a loop that copies, an exported `compress`, a 4-cell handoff row,
  guards carrying every arm) before the tree went green. An unrunnable probe
  is reported as a FAILURE, never skipped — the polarity the F140 lesson
  requires.

## Reviewing the F144 pins (PR review of e8e0179)

The executable pins above were themselves reviewed, and four defects came out
of the probes — three of them classes a substring pin cannot have, which is the
price of running code inside a build gate:

- **No timeout + inherited stdin wedges the build.** A guard containing a bare
  `read` blocked the probe forever: `validate_plugin.py` never returned
  (measured, killed at 20s). A gate that HANGS reports nothing at all, which is
  strictly worse than one that fails — CI shows a spinner, not a finding. Every
  probe now runs with `stdin=DEVNULL` and `timeout=30`, and a timeout is itself
  a reported finding, never a skip.
- **A missing interpreter raises instead of reporting.** `subprocess.run`
  throws `FileNotFoundError` when the binary is absent, so on a machine without
  node the compressor probe took down the whole validator with a traceback —
  every OTHER contract went unchecked because one optional interpreter was
  missing. Reported now, and reported rather than skipped: the pin proves
  nothing there and saying so is the point.
- **The probe measured the developer's machine.** The autobar probe's scratch
  repo inherited the caller's git config, so a global `core.excludesFile`
  listing `newdir/` made the counter report 0 and FAILED the build against
  correct shipped code. A false positive on a build gate trains the maintainer
  to ignore it — the same end state as a vacuous pin, reached from the other
  side. `GIT_CONFIG_GLOBAL`/`GIT_CONFIG_SYSTEM` are pinned to `/dev/null`.
- **`rc != 0` is not "refused".** The guard probe asked only for a non-zero
  exit, so renaming an arm's `die` to an undefined `refuse` exited 127 —
  `command not found` — and READ AS REFUSED, while the real CLI would die at
  every call. "All contracts hold" (measured). The probe now requires the
  harness's own die code exactly; a non-die exit means the arm or the harness
  is BROKEN, which is a different finding with a different fix. The F140 claims
  probe compared exact codes from the start; the newer pin regressed against
  its own predecessor.

The lesson under all four: **an executable pin has failure modes its own
subject does not.** Writing one means asking what happens when the probe cannot
run, runs somewhere unexpected, or runs and returns a number that means
something other than what you assumed — and the answer must be a reported
finding every time. Verified by re-running each measurement against the fix.

## `_tool_loops`: three bugs in one 12-line helper (PR review of e8e0179)

The helper written to fix a vacuity had three of its own, and they are worth
keeping because each is a different way for a *parser* to be wrong:

1. **Counting words is not lexing.** The scan matches the bare words `do` and
   `done`, and English contains both. `echo "nothing to do here"` opened a
   phantom nesting level, so the matcher needed one extra `done` and swallowed
   the NEXT loop whole — that loop's `cp` then satisfied the body check, and an
   install loop that copied nothing shipped "all contracts hold". The mirror
   image: `echo "install not done yet"` closed the loop EARLY, truncating the
   body mid-string, which is a false FAIL on correct code — and the truncated
   text still contained the word "install", so the check matched PROSE instead
   of a command. Wrong in both directions from the same root. Fix: mask
   comments and string bodies before the scan, offsets preserved (the
   `_mask_code`/`shell_code` discipline already used twice in this repo), plus
   a boundary — a loop body cannot extend past the next top-level loop head, so
   overshooting truncates (fail CLOSED) instead of extending (fail OPEN).
2. **`if _loops:` was the wrong polarity.** The head regex only matches an
   iteration variable literally named `tool`/`_tool`, so renaming it to `t`
   returned `[]` and both arms silently never ran. The F130 head pin still
   fired on the shapes measured, so no gate was open — but a check that goes
   quiet when its own shape assumption fails is exactly the silence this file
   refuses, and it said nothing about why. **No candidate is a finding**, the
   same rule the extraction sites already follow.
3. The one it got right, for contrast: a genuinely nested loop is indented
   deeper and must stay INSIDE the body, or tightening the scan trades a
   vacuity for a false positive. Both directions need a case, which is why the
   suite now carries `..._is_not_a_miss` beside every `..._fires`.

The lesson: **when a pin needs to parse, the parser is now part of the guarded
surface** — it earns its own mutations, in both directions, and "counting
brackets like bash does" is only true if you tokenize like bash does.

## Extracted from the coupling table (0.11.9)

The 0.11.8 CLAUDE.md re-accreted long why-narratives into cells the
0.11.2 extraction had already shortened once. This is the same move
again: each row below keeps the coupling and its citations in
CLAUDE.md; the full original cell — nothing reworded — lives here.

- **the v1→v2 `.operator/.gitignore` migration in EITHER writer** — the write must stay reachable ONLY through a successful backup, in `ops-init.sh` AND `ops-sessionstart-hook.sh` — `check_gitignore_parity` pins both halves (the copy's exit status is tested; a non-regular `.v1.bak` is refused). The old shape was `cp … 2>/dev/null` then an unconditional write: a failed backup destroyed the user's rules while the notice promised they were recoverable. The hook additionally sets `_gi_migrated` only AFTER the replacement, and reports the refusal — silence is what let the destructive variant ship. **THREE outcomes, three flags** (audit 2026-08-31): backup-refused, migrated, and backup-succeeded-but-write-FAILED. That third one had no flag, and `_gi_backup_failed` is scoped to the elif branches ABOVE the write, so it fell through both notices and the hook reported nothing (measured: rc 0, no gitignore line in additionalContext). The write is ATOMIC — heredoc into `.gitignore.v2.tmp`, `mv` on success — so the live file is always either the intact v1 or the complete v2, and the next session's retry can never copy a truncated file over the good `.v1.bak`. `check_gitignore_parity` pins `_gi_write_failed` AND its report: setting a flag and telling the session about it are two claims, and a pin on the assignment alone is satisfied by a flag nothing reads. The case's trigger is a non-regular entry at the TEMP path, not a read-only `.gitignore` — `mv -f` needs directory permission, not file permission, so a read-only file migrates fine (measured). `ops-init.sh` needs no flag: `set -e` kills it on the failed write, loudly. **Both writers' atomic swap is pinned separately** — the hook's `mv -f "$_gi.v2.tmp" "$_gi"` and init's `mv -f "$OPDIR/.gitignore.v2.tmp" "$OPDIR/.gitignore"` — because init's was NOT (audit F137, 2026-09-02): reverting `_gi_write` to the heredoc-onto-the-live-file shape reported "all contracts hold", and a pin added to one of two twins is the F116 shape one layer up. Cases: the _"migration REFUSES"_ + _"ops-init refuses"_ + _"the third state"_ cases

- **how a gate CLI finds `.operator/` (the PROJECT ROOT BLOCK)** — ONE block, byte-identical in `ops-task.sh`, `ops-verdict.sh` and `ops-adopt.sh`, pinned by `check_root_parity` (parity across the three AND a canonical-content pin — copy-pasted blocks drift uniformly, F30). It WALKS UP to the nearest ancestor holding `.operator/` and **`cd`s** there, mirroring `ops-stop-hook.sh`. Not an absolute `OPDIR`: the source stamp's `git status -- ':(exclude).operator'` pathspec is REPO-relative, so that variant leaves every ledger path correct and silently pins every row written from a subdirectory to `+dirty` — mutation-measured, it fails only the two stamp controls. Bounds are the design: `.git` stops the walk (a nested repo is its own project, or a CLI inside a vendored repo writes to the OUTER ledger) and `pwd -P` blocks a planted symlink. Why it exists: `OPDIR=".operator"` was cwd-relative until 0.11.3, so the CLIs worked from the project root and nowhere else — including through the absolute path #94 made the hook prescribe (#95, found by the 0.11.2 release test, not by a suite: every case cd'd to the root first). Cases: the _"WALKING UP"_ block + `RootParityTest`

- **the `.operator/bin` install set (`scripts/ops-install-set.sh`)** — the set has ONE declaration since #76 step 3 — the manifest both writers source (`ops-init.sh` fails LOUD without it, the interactive path; `ops-sessionstart-hook.sh` fails OPEN: skips the upgrade, warns, does not re-stamp — an empty set must never record an upgrade that copied nothing). Adding a CLI: edit the manifest, then update the charter's EVIDENCE GATE paths, the stop-hook fallback message, the _"project-installed gate CLIs"_ test case, `validate_plugin.CHARTER_REQUIRED_CLIS` + `check_scripts`, and the `GATE_CLIS` literal in `ops-compress.mjs` (the I2.1 carve-out — a DIFFERENT 4-entry set: charter-referenced CLIs, no ops-backlog.sh; the manifest's header explains). `check_install_set_parity` pins the manifest readable + both writers sourcing and iterating `$_OPS_TOOLS` with no local literal (CR4)

- **the `*__<id>` sentinel LOOKUP in any CLI (`sentinel_for` in `ops-task.sh`, `sentinel_path` in `ops-verdict.sh` + `ops-adopt.sh`, and `ops-task.sh`'s post-rename dup loop)** — keep the TASK-HALF filter (`_n="${_f##*/}"; [ "${_n#*__}" = "$_t" ] \|\| continue`) at all FOUR sites — `check_guard_parity` pins each literal (audit F136). The glob's `*` spans a `__`, so without it a planted `A__B__C` resolves as task `C` here while the readers (first-`__` split) call it MALFORMED: `ops-task.sh C` reported "already open" (rc 0) for a task never opened, `ops-adopt.sh` RENAMED the malformed file into a well-formed `<sid>__C`, and #99's "no CLI can address it" was false. The CLIs must read a name the way the hook does. Cases: the _"F136"_ block

- **the partition rule in `scripts/lib/partition.sh`** — ONE implementation, sourced by both `ops-stop-hook.sh` (the gate: whole-file, fail-closed) and `statusline.sh` (the bar: tail-window approximation, fail-toward-silence — CR5's 300ms budget). Change it once. The `[sid:]` tag convention (what-cell of gated rows) is read by the lib + the bar's tail scanner and written by `ops-verdict.sh --mark-handoff`. Cap/polarity changes need the lib + the bar's inline scanner + the _"deviation-gate"_/_"dev\[N\] mirror"_ cases. **Clearing is ASYMMETRIC and both halves must move together** (#90): a MINE row clears only on a mine/unowned mark, an UNOWNED row clears on ANY later mark including a foreign one. Nothing writes `[sid:]` onto a DEVIATION — the operator hand-writes those — so untagged is the NORMAL shape, and the old "foreign clears nothing" rule made every untagged decision block every future session forever (measured as a fresh sid: strike-zero 6, gtrw 2, all long presented). The reflex fix, letting a foreign mark clear MINE too, is a different bug and the _"foreign mark does not clear my deviation"_ case catches it. The bar mirrors this with `_devunowned_cleared` on its BACKWARD walk. Cases: the _"a FOREIGN mark clears UNOWNED"_ block, each mutation-checked

- **the MALFORMED bucket in `scripts/lib/partition.sh` (`scan_pending`)** — update `scripts/ops-stop-hook.sh`'s malformed message AND `statusline.sh`'s `BLOCKING` count — the bucket blocks, so a bar that omits it reads "not blocked" while Stop returns 2, which is the exact disagreement sharing this lib prevents. The bucket exists because readers split on the FIRST `__`, so `A__B__C` yields the task id `B__C`, which every writer guard REFUSES: the gate named a command that dies on its own guard (#99, F118). Degrading such a name to unowned does NOT fix it — the id is derived from the name either way — so the remedy is name-level (`rm -f` on the full path) and the message must never route these through the verdict CLI. **An EMPTY task id (`sid__`, `__`) is in the same bucket** (audit F135, 2026-09-02): the old scan COUNTED it as MINE but appended "" to `MINE_IDS`, and the hook's block condition is that LIST, not the count — so with only such names pending the hook returned 0 while the bar (which counts) rendered `op[N]` red: the exact disagreement the shared lib exists to prevent, and a silent open. Measured on the pre-#99 code too (pre-existing). Cases: the _"F135"_ block. Polarity is fail CLOSED, and it BLOCKS where the old code reported foreign. **The paths travel as a bash ARRAY (`MALFORMED_LIST`), never a delimited string** (PR #104 review): they are parsed back into `rm -f` lines, and the first cut's `"; "` join was split on the same literal, so a project at `/work/proj; x/` printed `rm -f '/work/proj'` — a destructive command aimed at the wrong file. No printable delimiter is safe in a path and bash cannot hold NUL, so an array is the only lossless carrier. Readers guard `"${MALFORMED_LIST[@]}"` behind `[ "$MALFORMED" -gt 0 ]` — bash 3.2 under `set -u` calls an empty array unbound. Cases: the _"F118 (#99)"_ block, each pin mutation-checked (7 red on the pre-#99 code, the two bar pins red on a statusline-only mutation, 4 red on the `"; "` carrier, 2 red with the bucket removed for the FOREIGN-owned shape)

- **the source-state stamp in `ops-verdict.sh` (`source_stamp`, the row printf)** — update `validate_plugin.check_source_stamp` (pins the marker set, the `.operator` dirty-exclusion, the 4-cell row format, the application of `SOURCE_STAMP` — read off the row's own `printf` argument list, because `"SOURCE_STAMP" in code` was satisfied by the assignment line alone and a literal in the row's place shipped unstamped rows green — and the resolve-before-`lock_acquire` ordering) and the _"source-state stamp"_ cases. Moving or renaming `ROW="$(printf …)"` breaks the locator, which reports rather than skipping. The stamp lives INSIDE the evidence cell on purpose: a fifth column breaks `VERDICTS_HEADER`, every ledger in the field, and every grep written against the 4-cell schema. It is provenance, not attestation — do not let a caller describe it as proof the tree passes (#22; #23 and #25 are the other two thirds)

- **a VALIDATOR CHECK itself — any pin in `scripts/validate_plugin.py`** — **run the mutation before you believe it** — a pin with no red run is a hypothesis, so every fix carries a python case with the exact escape it was written against, plus the control. The `pin-auditor` agent audited 25 checks on 2026-08-25 (84 mutations) and found four vacuous pins; reviewing that audit found six more, so the catalogue of escape shapes is not exhaustive and the METHOD is the point. One shape is enforced rather than remembered: a byte cap is only a byte cap **in the C locale**, so a file with byte-bounded reads and no `local LC_ALL=C` in the reading function fails. **When the property is BEHAVIOUR, the pin must EXECUTE the shipped code** (F140, then F144 for six more): `check_claims`, `check_guard_parity`, `check_autobar`, `check_compressor` and `check_decisions_schema` all run the real function/module against probes with known answers, because a substring test on a body is blind to control flow — a dead `?*)` arm, an early `return 1`, an `if (false)` copy, a flag in a TRAILING comment (`shell_code()` strips whole-line comments only) and a decoy loop each shipped "all contracts hold". Two rules come with that: every probe needs the **refuses-everything / accepts-the-ordinary-case control** (rejection probes alone are satisfied by a guard that dies on everything), and an **unrunnable probe is a FAILURE, never a skip**. Expect to grow the good-tree fixtures when you add one — five stubs were under-built, which is a fixture bug and not a defect, but it fails the build until fixed. **An executable pin has failure modes its subject does not**, so every probe goes through `_run_probe` (PR review of e8e0179, four measured defects): `stdin=DEVNULL` + `timeout=30` (a guard containing a bare `read` HUNG the validator forever — a gate that hangs reports nothing at all), `FileNotFoundError` reported not raised (absent node took the whole validator down by traceback), `GIT_CONFIG_GLOBAL/SYSTEM=/dev/null` in any git probe (a developer's global `core.excludesFile` FAILED the build against correct code — a false positive trains the same ignoring as a vacuous pin), and **exact exit codes, never `rc != 0`** (an arm calling an undefined command exits 127 and read as "refused"). **When a pin needs to PARSE, the parser joins the guarded surface**: `_tool_loops` shipped three bugs of its own — a bare `do`/`done` in English prose both extended a body (swallowing the next loop, whose `cp` satisfied the check) and truncated one (matching the word "install" in the truncated PROSE), and `if _loops:` went silent when its head regex stopped matching. Mask comments/strings before any word scan, bound the search, and make "no candidate" a finding. Every pin also owes a NEGATIVE control — reflowing, reordering equivalent arms and nesting must be proven free, or you have traded a vacuity for a false positive, which trains the same ignoring. **“mutation-checked” names the gate that went red (#111)** — “red somewhere” is not coverage: a shell mutation can go red in `tests/test-scripts.sh` while the validator pin written for it stays vacuous, and the python cases already assert the SPECIFIC check fires (`test_autobar_missing_z_flag_fires`), so the prose owes the same granularity when it records the run. **A locator's empty answer is not a negative answer (#114, generalised from `_tool_loops` and the probe rule)**: any regex/scan that selects what a pin reads must REPORT when it finds nothing, never return quietly, and a parity pin over two located things reports EACH missing side by name — measured here: `check_workflows`' meta locator could not read the inline-closed shape, and `check_guard_parity`'s F17 arm reported a missing `retro_gate` scan but said nothing when only `--reconcile`'s went. Procedure: `docs/PLAYBOOK.md` “writing a locator”. Why (the shapes, each with its measured escape): `docs/LANDMINES.md` _"A pin is a hypothesis until the mutation runs red"_ + _"Six vacuities of the same shape"_

- **the `check_bare_name` reject set in any CLI** — update the other two CLIs **and** the `case` filter in both `sentinel_owner_of_name` parsers **and** `ops-adopt.sh`'s inline `PREV` reject-set **and** `ops-sessionstart-hook.sh`'s migration reject-set (a sixth copy) — the readers must reject what the writers reject, or a name our CLIs could never have written reads as a valid foreign owner and the gate opens (_"name guards agree"_ + _"untrusted input"_ cases; `check_guard_parity` pins the `*__*` literal across the sites). `check_owner_name` additionally refuses shell metacharacters (`$` `` ` `` `'` `"` `\`) — #89: a quoted heredoc passed the literal `$S`, which reads as a FOREIGN session, so its HANDOFF-MARK cleared nothing and its sentinel was unclearable. Strictly worse than not running the command, because the tool reported success. **That arm belongs at all SIX sites, not the three writers** (PR #88 review): a pre-0.9 sentinel carries its owner in the BODY, so `ops-sessionstart-hook.sh`'s migration renamed `session_id: $S` to `$S__planted` and both `sentinel_owner_of_name` copies read it as a valid foreign owner — measured Stop rc 0 on a real open task, the silent disarm reached by the one path a writer guard cannot see. Writers refuse, readers degrade to unowned (fails CLOSED), the migration refuses. Cases: the _"UNEXPANDED shell variable"_ block and its reader half, each mutation-checked separately — the guards do not cover for each other

- **the canonical tier set in `ops-tiers.sh` (`TIER_NAMES=…`)** — update **`ops-render.sh`'s own `TIER_NAMES` literal** — `check_resolver_renderer_parity` enforces equality, reading both by regex; a rename/retype must update that regex, which fails _loud_. Workflows carry no tier set at all (#76 step 2 deleted `KNOWN_TIERS`; an unknown `args.tiers` key is accepted-and-logged, never thrown, preserving F07's resolver-map forwarding), and their `DEFAULT_TIERS` values must be harness aliases (`opus`/`sonnet`/`haiku`/`fable`), pinned by `check_workflow_default_tiers` — a vendor id pasted into a workflow default is the reflex fix that recreates the deleted catalogue

- **the seat set, a `tiers.env` line kind, or the renderer's body sources** — `ops-tiers.sh` and `ops-render.sh` parse the same `tiers.env` (BOTH line kinds: tier→model AND seat→tier — the resolver skips seat lines, the _"seat line … skipped by the resolver"_ case) and share `check_routable` (`check_resolver_renderer_parity` compares it whitespace- and comment-insensitively: reflowing is free, a logic change is not). Render bodies come from plugin-root `agents/op-<seat>.md` first; a template must keep a `model:` line and BOTH splice sources must be CR-free or the awk skips every substitution (`check_render_templates`, F29). New seat default → `seat_add` in `ops-render.sh` + the `ops-init.sh` scaffold comment + **`workflows/dispatch.js`'s `SEATS` table**, which is a LITERAL map on purpose (F22's class). Render/revert delete only `RENDER_MARK`-stamped files (F17); seat names are charset-allowlisted (F18). Why: `docs/LANDMINES.md` _"The seat table in `workflows/dispatch.js` is a literal map on purpose"_

- **the model-id guard (`check_routable`, workflows' `BAD_CHARSET`)** — it judges WELL-FORMEDNESS ONLY — a decision, not an oversight (0.8.3). **The user picks the model, cc-proxy routes it, operator decides neither.** What remains tests the STRING (no whitespace, no quotes, non-empty), so it cannot go stale. `check_workflows` FIRES on a re-declared `const ROUTABLE` — the validator's only presence-check, because the re-add is the reflex fix. Keep `BAD_CHARSET` pinned to `CANONICAL_BAD_CHARSET` **and** applied at a `.test(id)` call site in every `workflows/*.js`; it is the only id guard left, so a neutered call site has nothing behind it. Cases: the _"operator does not recognise"_ + _"only widens"_ + _"must not come back"_ cases. Why: `docs/LANDMINES.md` _"A catalogue of another system's facts goes stale"_

- **the dispatch packet in `templates/OPERATOR.md`** — update `docs/HANDOUT.md`'s copy **and** `validate_plugin.HANDOUT_PACKET_SPINE`. The spine held only the FIRST and LAST fragments, so `REACH` (#57) went in the middle and the pin stayed green teaching a packet without it — F69's drift repeating inside the guard written against it. The checker now asserts the CHARTER carries every field too, not just that the handout matches it: parity passes perfectly when the original is what lost the field (F30). Every field added to the packet needs a tuple entry, and `test_handout_packet_pin_fires_per_field` fails if one is added without being enforced

- **the auto-arm rule in `scripts/lib/autobar.sh` (#85)** — ONE implementation, sourced by `ops-stop-hook.sh` AFTER `partition.sh` — the order holds because `autobar_decide` runs BEFORE `scan_pending`, so an armed sentinel is read by the existing mine-pending branch in the SAME fire. Four invariants, each mutation-checked: (a) the delta is read `-z -uall` through **process substitution**, never `$(…)` (command substitution DELETES NUL bytes), with the repo check a SEPARATE call (process substitution carries no exit status); `-uall` is as load-bearing as `-z`. (b) the arm is marked BEFORE the sentinel is written, the write status is CHECKED, and a failed write rolls the marker BACK. (c) that write goes through `set -C` (`[ ! -e ]` is true for a dangling symlink). (d) the armer has NO foreign-presence suppression — that is the decision, arrived at twice; `check_autobar` fires on a RE-ADDED `autobar_foreign_activity` call (an inverted pin). Polarity is fail-OPEN throughout, deliberately the opposite of `partition.sh`'s sentinel default. `ops-sessionstart-hook.sh` wipes `.operator/.autobar/` every fire. Threshold is the charter's ENGAGEMENT CONTRACT clause (1) ONLY — a count, never the done-state clause. Cases: the _"auto-arm (#85)"_ block. Why (both removed suppression rules, why no third is possible, and the priced trade): `docs/LANDMINES.md` _"The auto-arm cannot tell a dead session from a busy one"_

- **the seat bindings or round structure in `workflows/debate.js`** — `check_workflow_agent_types` proves the agentType NAMES a shipped agent; nothing in the validator says which call site gets which seat, so a debater prompt handed to `op-author` (Write + Edit — able to edit the artifact it argues about) ships green. The per-label binding is asserted ONLY in `tests/test_workflows.mjs` (the _"debate.js runs three rounds"_ + _"dead-seat accounting"_ cases), which is why the stub runtime captures `opts.agentType`. Three invariants the cases pin, each mutation-checked: seats argue BLIND (no model id in any debater prompt — a rival's brand invites deference over argument, and a seat that can identify itself softens its own critique), a seat never receives its own position as a rival's (self-agreement registering as convergence), and `args.models` has NO fallback (a defaulted panel is one model debating itself — F37's silent-wrong shape, and adding that default is the reflex fix for the 2-5 refusal). `chose` is ALWAYS null and present-not-omitted: paying N flagships to disagree so the workflow can decide makes the other seats decoration

- **`args.isolate` / `args.isolateCheckout` in `workflows/review.js` (#74)** — the runtime's `isolation: "worktree"` takes NO commit — the worktree is created at the DEFAULT BRANCH (measured twice). So `args.isolate` buys the clean ENVIRONMENT only, and the default prompt must SAY so: a HEAD mismatch is EXPECTED and must NOT be refuted. `args.isolateCheckout: true` opts into `git checkout --detach <sha>` first (real commit identity, worktree left on disk); default off. The two prompt branches are EXCLUSIVE. `atRequestedCommit` is the field that stops the overclaim — never hardcode it true. `isolateCheckout` without `isolate` is REFUSED. Both branches keep refusing the porcelain substitution and keep F-A1 replaced. Cases: the _"#74"_ block, each mutation-checked (old prompt restored → 4 FAIL, `atRequestedCommit: true` → 1, checkout unconditional → 4, refusal dropped → 1). Why: `docs/LANDMINES.md` _"Isolation buys a clean tree, not a commit"_

- **`args.isolate` / the adversarial seat's prompt in `workflows/review.js` (#23)** — keep the two branches EXCLUSIVE: un-isolated ships F-A1 (`git status --porcelain`), isolated ships F-A2 (`git rev-parse HEAD` vs the named sha) and F-A1 must NOT also ship — a fresh worktree is clean by construction, so porcelain there is a control that cannot fail. `isolate: true` stays refused. Both the prompt and the returned `isolation.bound` must keep naming the bound: same filesystem/`$HOME`/caches/PATH — it defeats in-tree artifacts, not a poisoned global cache. The returned field is `requestedCommit`, NEVER `commit`; the observed HEAD lives in `adversarial.evidence` and `observedCommit` stays null until something reads it back. Cases: the _"adversarial isolation"_ cases (the stub runtime captures `opts.isolation`)

- **the feasibility lens's packet in `workflows/plan.js` (`earlierProduces`, #73)** — the lens is ASKED whether a consumed dependency is produced by an EARLIER task, so it must RECEIVE those tasks' `produces` — without them 14/21 seats returned `needs-info` citing `dependency-missing`, 5 against a correct control plan. Three invariants, each mutation-checked in `tests/test_workflows.mjs`: the map is keyed by task OBJECT IDENTITY (a positional lookup breaks on a repeated id), the slice is strictly EARLIER (never the task's own), and the empty case says "none — this is the first task" IN WORDS (an absent section reads as withheld information — the defect). Producers are named `id: names`. The TESTABILITY lens must NOT receive it. Assert on the SECTION, never the whole prompt — the packet also carries `JSON.stringify(task)`, whose own `produces` satisfies a bare `.includes()`

- **the Stop hook's block MESSAGE (`ops-stop-hook.sh`, the two `echo`s)** — it is composed from UNTRUSTED project data and read back by the model, so both halves are guarded (PR #88 review). Paths go through `shq` — absolute means long enough to contain a space, and `/work/my repo/…` pasted bare runs `/work/my`, so the #94 fix would have traded one uncopyable command for another. Ledger rows go through `sanitize_row` BEFORE being measured or truncated — a CR in a hand-edited row repaints the very instruction it is attached to, and a row of escapes is short on screen but long in bytes, so sanitizing after the cap would leave the cap dishonest and could truncate mid-escape. Both are builtin-only: a lost PATH must not disarm either. Cases: the _"hostile ledger and a spaced path"_ block

- **a workflow's `args` NORMALIZER (the `typeof args === "string"` block)** — all six must keep `catch { return args; }` — returning `{}` DISCARDS the operator's text silently, and brainstorm's copy did: a 4,000-char prose brief evaporated and the full fan-out ran against the placeholder (measured live: 7 agents, 123,935 tokens, 86s, every seat answering "cannot propose a direction without a topic"). Two halves, both needed (#92): the permissive catch, AND reading a bare string as the one required arg the way `review.js:117` does — with the catch alone the string still lands on the placeholder. A workflow whose required arg is absent must THROW BEFORE phase 1; the _"spends ZERO agents"_ case is what makes that a refusal rather than a better error after the same spend. **`crawl.js`'s `question` is the third such arg** and was missed on the first pass (PR #88 review): its absent-SHARDS branch returns before dispatching, which made it look covered, while an absent question with valid shards paid every crawler seat AND the merge. `A` is then legitimately a string, so every `A.foo` read needs a `typeof A === "object"` guard. The stub suite cannot see this class — a stub agent returns its canned object whether or not the prompt was a placeholder (#79) — so the cases assert the INPUT path, and the string case is try/wrapped because the mutation makes the workflow throw rather than return

- **a step or glob in `.github/workflows/validate.yml`** — mirror it in `.forgejo/workflows/validate.yml` — same suites, but the two files CANNOT be identical and no validator pins them. Keep BOTH glob terms (`scripts/*.sh` AND `scripts/lib/*.sh`) in every CI path including `scripts/ci-local.sh` — the missing second term let `lib/autobar.sh` ship unlinted through three of them (#86 review). Same for `release.yml`: the forge copy publishes with a plain POST and CHECKS the status. Why (the `uses:` divergence act cannot parse, the runner having no docker, the YAML traps in an embedded `python3 -c`): `docs/LANDMINES.md` _"The two CI files cannot be identical"_

- **a rung, its completion MARKER, or the CI step that runs it** — update `scripts/gate-suite.sh` (the rung's command AND its marker), `validate_plugin.SUITE_RUNGS`, and all four CI files — `check_suite_floors` requires a live `gate-suite.sh <rung>` in every one and REFUSES a raw invocation coming back. The marker is the half that catches a rung which exited 0 without running; the floor is the half that catches deletion. `check_release_gates_cover_validate` compares the INVOCATION, not the suite path: the 0.11.7 move behind the wrapper emptied it for one commit (raw paths gone from validate.yml → `vsuites` empty → the superset test passed against a release job running nothing), which is the shape a wrapper always threatens

- **a `_"…"_` citation in CLAUDE.md, or a case/section title one names** — they must agree — `check_coupling_case_refs` resolves every citation LINE-WISE against the CARRIER lines in `tests/` (or `docs/LANDMINES.md` when the surrounding prose names that file: classification is by CONTEXT, not by string) — since #115 a carrier is a suite `check`/`-- Case`/`# ---` line, a node assertion title (including its continuation line), or a python `def test_`/`assertFires(` line, never an arbitrary fixture string (#115's live escape: this repo's own fixture satisfied the production citations). `…` is an elision: its fragments must appear in order on one line. Markdown escapes are the author's, not the title's (`dev\[N\] mirror` cites `dev[N] mirror`). Fewer than 40 citations found is itself a FINDING — a head regex that stops matching reports green about a set it never read (`_tool_loops`' shape). **A test fixture must never contain a real case title**: `CouplingCaseRefsTest`'s first draft reused two, they satisfied the production citations from inside `tests/`, and the rename mutation ESCAPED — the escape was in the fixture, not the check

- **`stop_hook_active` is a shared field, and a shared field used as a
  private loop guard disarms the gate (#116).** The Stop hook's guard read
  `[ "$active" = "true" ] && exit 0` — "never re-block an already-active
  stop." But the harness sets that flag on the Stop after ANY hook-forced
  continuation, and cc-repete's loop blocks every Stop while it runs: an
  active loop therefore disarmed cc-operator's evidence gate for the whole
  loop window after its first turn, silently — the fail-OPEN class this file
  treats as the worst. cc-reload gets the contrast right: it stands down
  DELIBERATELY (reads `.repete/loop.local.md`, names the reason), while our
  stand-down was a side effect of sharing a field. The fix keys "my own
  block" on a per-session marker (`.operator/.stopguard/<sid>`, stamped by
  every exit 2, cleared by the allowing exit 0, wiped by SessionStart beside
  `.autobar/`): `active AND my marker` = my continuation, stand down;
  `active` alone = someone else's, run the gate and say so on stderr. The
  marker is advisory and fails safe both ways: an unwritable `.operator/`
  makes the guard read absent (gate RUNS — toward blocking, like the
  unowned-sentinel default); a stale marker costs exactly one stand-down —
  the pre-fix behaviour, never worse. The producer side now declares the
  contract (cc-repete#27, v0.2.4) and bounds it (cc-repete#29).

### Provenance narratives moved from CLAUDE.md (0.11.9)


Everything under `docs/` is read-only rationale — why the code is shaped this
way. None of it is loaded by the plugin at runtime; the validator reads only
`templates/`, `scripts/`, `hooks/`, `agents/`, and the manifests.

- `docs/TAGS.md` — **the in-tree resolution index for every charter
  `[DOC:spec-*]` tag** (#76 step E). The original spec files
  (`chief-operator-spec.md`, D1–D6; `concurrent-sessions.md`, the 0.4.0
  ownership design) were never committed — they quoted the prior project's
  evidence base 0.3.0 removed — and by 2026-08-21 no copy survived in the
  maintainer's local tree either, so 22 of the charter's 24 DOC tags dangled
  in EVERY checkout, documented as "expected". TAGS.md replaced that: each
  entry records what the tag anchors *as shipped* (from the code and the
  charter's usage, not recovered spec prose — where the original rationale is
  lost, the entry says so), and `check_charter` fails the build on a charter
  DOC tag with no `### spec-<key>` entry, so the index cannot fall behind.
  Orphan entries (a retired tag's survivor) are deliberately allowed: history,
  not rot. (Moved from `docs/spec/` in 0.11.9 when the directory emptied;
  `backlog-charter.md` removed — git history.)
- `docs/PLAYBOOK.md` — the executable procedures (adding a guard, adding a
  reader, touching the lock), each derived from a bug that happened here.
- `docs/REPLAY-CHARTER.md` — the live-session replay protocol (R0–R8): re-proves
  the harness seam the bash suite cannot reach (live Stop block,
  SessionStart id injection, the U10 stamp end-to-end), every phase recorded as
  a verdict row through the gate it audits. Run it after plugin or harness
  upgrades and before any release claiming a live-verified gate. Expected-output
  strings in it quote the real scripts — a message change in `ops-stop-hook.sh`
  or `ops-init.sh`'s F67 warning must update the charter's quoted expectations
  too (no validator pin; prose).
  **First executed 2026-08-12** (`1e5308a`→`13ea694`): it produced issue #34 and
  four defects in its own text, all corrected, with a "What the first real run
  changed" section recording them. Its R0 now opens with a build-identity check
  — `cmp` every `.operator/bin/` CLI against the plugin's — because a stale
  `bin/` silently makes the later phases audit a different build than the tree,
  which is exactly what happened on the first run.
- `docs/audits/audit-2026-07-27-{findings,handoff}.md` — the departing-architect
  audit (gate hardening, F01–F06). **Maintainer-local, never committed** — a
  fresh clone has no copy and no summary; what survives in-tree is the guardrail
  code itself plus the F-numbers cited in comments and CHANGELOG.
- `docs/audit-2026-07-31-handoff.md` — the token-diet / workflow-layer audit
  (F07–F66 era: mental model, decisions, residual risks). **Also
  maintainer-local, never committed**, despite prior revisions of this file
  citing it as if it shipped — `git log --all` on the path is empty. The
  in-tree survivors are the same: code, comments, CHANGELOG.
- `docs/audit-2026-08-09-handoff.md` — the assurance-model audit (F67+ and the
  U10–U13 unknowns). The first audit handoff that actually ships in-tree.
- Everything else (build plan + ledger, pilot runbook and findings, the prior
  project's evidence bundle) was removed from the tree in 0.3.0: see git
  history (tree ≤ v0.2.0) or the maintainer's local `.archive/dev/`.
- The one still-open design question from the pilots: the evidence gate is
  opt-in at the mechanism level — nothing forced a sentinel to be opened.
  CLOSED in #85 (`scripts/lib/autobar.sh`): the Stop hook now arms an ordinary
  owned sentinel when the working-tree delta names >=2 changed project paths,
  so the charter's ENGAGEMENT CONTRACT clause (1) is enforced in code rather
  than asked for in prose. Coverage is deliberately partial and the bounds are
  the design, not an oversight: clauses (2) multi-session and (3) user-named
  done-state stay UNCOVERED (both would mean classifying intent, which is a
  false-positive factory on a hook that BLOCKS); a non-git project arms nothing;
  a shared worktree suppresses the armer entirely; and a session can still
  satisfy it by opening one throwaway task and deferring it. It is an honesty
  rail against forgetting, not a sandbox against a hostile agent — the threat
  model is drift, which is the observed failure, not evasion, which is not.


## The cap detector's polarity is the opposite of every other gate (0.11.12, #107)

**the cap detector in `scripts/lib/caps.sh` (#107)** — the full cell, and the
reasoning the coupling row compresses.

Until this shipped, `templates/OPERATOR.md`'s Cap table declared three caps and
called a trip "a defined stop-and-report, not a judgment call" while nothing
read, counted, or reported any of them. Measured 2026-09-07:

```
$ grep -rn 'Identical-rejection\|rework\|Neighbor-regress' scripts/ hooks/
(no output)
```

That is the same shape as the evidence gate before #85 auto-armed it, and as
the sibling project's watchdog incident: a dispatcher re-validated ONE rejected
pull request 68 times in three and a half hours. Every individual tick was
correct; the pathology lived entirely in the SEQUENCE, which nothing was
looking at.

**REPORT-ONLY, and unlike `partition.sh` this is not a fail-open/fail-closed
choice — there is no blocking direction available at all.** `VERDICTS.md` is
append-only with a single writer, so a tripped key can never be un-tripped by
removing a row. A blocking cap detector over a permanent history is a permanent
block: worse than `autobar`'s infinite-block failure one layer up, because
there the operator could at least clear the sentinel and here nothing could
clear anything. A session that cannot end is the failure a user resolves by
deleting the plugin — the polarity #123 C states, for the same reason. The
charter independently points the same way: the trip is the OPERATOR's
stop-and-report, not the gate's.

Two consequences the code carries:

- The report is emitted **above every `exit`**, on the allowing path and both
  blocking paths. Attached to a blocking branch it would surface only when
  something else had already blocked — a report nobody sees, about a sequence
  that is invisible in any single round.
- The statusline does NOT read it, and this is not an omission of the
  partition.sh kind. The bar renders whether a stop will BLOCK; a report-only
  scan changes no blocking state, so there is nothing here for the bar to
  disagree with.

**A later PASS resets the key**, and that is what makes the signal usable
rather than permanent noise. Two FAILs followed by a PASS is a rework that
WORKED; reporting it forever would fire on every mature ledger from its first
repeated failure to the end of the project, and a line that is always there is
a line nobody reads. Forward pass, order matters — the asymmetry
`scan_deviations` applies to HANDOFF-MARK. The report is also built AFTER the
whole pass, never during it: a key that hit the cap and was then cleared must
not appear, and mid-pass emission cannot take that back.

**One of three caps is covered, and the file must keep saying which two are
not.** A partial detector whose limits go unstated reads as a complete one —
the honesty #85 applies to its own uncovered clauses (2) and (3). The two
uncovered ones fail for DIFFERENT reasons, and conflating them is how a
future session "just adds" the wrong one:

- **identical-rejection ×2** needs a SCHEMA decision first. The cap is "the
  same REVIEWER rejects the same target twice" and a row carries no reviewer
  identity. The 4-cell schema is published: a fifth column breaks
  `validate_plugin.VERDICTS_HEADER` and every ledger already in the field.
  Encoding the reviewer inside the evidence cell would make the detector
  depend on a convention nothing enforces — a detector that reports on prose.
- **neighbor-regressing ×2** is NOT a column problem. The cap is "a fix round
  REGRESSED a previously-passing check", and causation is the load-bearing
  word: the ledger records that criterion Y failed, never that a fix to X
  caused it. A PASS→FAIL flip is the nearest observable and is not the same
  claim — a flip happens whenever the tree moves, which is most rounds.
  Reporting a flip AS this cap would be a detector precisely correct about the
  wrong question, and `caps.sh` would then read as though two of three were
  covered.

**The pin EXECUTES the detector, and it must carry the constants.** The
regression this is written against is not deletion but a scan that keeps its
shape and stops tripping: it reports "no caps tripped", byte-identical to a
clean ledger, on every project, forever, with every other gate green.
`CAPS_REWORK_MAX=99` leaves every substring pin satisfied. So `check_caps`
extracts `scan_caps` and runs it against three synthetic ledgers (trip, reset,
same-id/different-criterion). The `CAPS_*` constants go into the probe WITH the
function because the function reads them and an unset one is not an error bash
reports — `[ 2 -ge "" ]` complains to stderr and evaluates FALSY. Measured
while writing the pin: extracting only the function returned 0 on the trip
ledger against a WORKING lib, which is a false positive on a build gate and
trains exactly the ignoring a vacuous pin does.

### The cap detector's own adversarial round (0.11.12, #107)

Four defects, all in the commit that introduced the detector, none found by a
local gate run. Worth keeping because three of them are the SAME failure with
three faces.

**A pin that names one spelling is a pin on that spelling.** The report-only
guard asked `^if \[ "\$caps_[a-z_]+` and then looked for an `exit` in the
block. Shell writes that branch at least three other ways, and two of them
shipped "all contracts hold" while inverting the polarity — live-verified to
exit 2 on a ledger with nothing else pending, which is the permanent block the
guard exists to refuse:

```
[ "$caps_scan_failed" = 0 ] && [ "$caps_tripped" -gt 0 ] && exit 2   # no `if`
if false; then :; elif [ "$caps_tripped" -gt 0 ]; then exit 2; fi    # `elif`
```

This is the base-gate floors lesson (close the SHAPE, not the instances)
arriving one file later, which is the point: it was written down and the next
pin still enumerated instances. The fix asks the shape-independent question —
is an `exit` reachable from any test of a `caps_*` variable — with the block
walked by DEPTH so a nested `if … fi` cannot close the window early.

A third face of the same error appeared inside the FIX: the rewritten
exit-matcher anchored on `^exit`, and a block's body is indented, so the `elif`
bypass survived. It was caught only by re-running the verifier's own three
escapes against the fix instead of trusting that the rewrite covered them.
**A fix to a vacuity is a hypothesis until the original escape runs red
against it.**

**An executable probe can test the wrong bytes.** Appending a second
`scan_caps() { caps_tripped=0; }` to the lib shipped green: bash resolves the
LAST definition, the probe's extractor is non-greedy and takes the FIRST. The
probe cannot catch this by construction — it faithfully executed a function
nothing runs — so the definition COUNT is the guard, checked before the probe.
This repo has `_report_if_redefined` for exactly this (#81) and the new check
did not use it; an executable pin does not make the older class go away.

**Size bounds are not work bounds.** `scan_caps` carried three bounds (rows,
bytes, keys) and its header claimed a measured worst case it never carried.
The real ceiling is their PRODUCT — rows × keys, because bash 3.2 has no
associative array and the key table is scanned linearly. Measured at exactly
the shipped bounds, 20,000 rows across 100 failing targets:

```
scan_caps alone                10.2s
the Stop hook carrying it      11.1s
the same rows on ONE key        1.9s   (the row parse alone)
after CAPS_MAX_STEPS            1.09s  (truncated=1, still reports 100)
```

Nine of those seconds were the lookup, paid on every Stop, on a ledger an
ordinary mature project reaches.

**And the worst case is not the case anyone lives in.** The budget fixed the
tail; the ordinary shape still costs. Re-measured at 25 task ids x 2 criteria
(50 keys, mostly PASS), whole scan, no truncation: 500 rows 0.12s, 1000 rows
0.4s, 3000 rows **1.2s**, 5000 rows 1.9s. So a few thousand rows is ~1-2s on
every Stop, forever. Whether that is acceptable cannot be answered here,
because the Stop hook has no stated wall-clock budget the way statusline.sh
has CR5's ~300ms — and **the number nobody can judge is the number nobody
notices growing**. Tracked as #127, which makes writing that budget down step
1, ahead of any caching.

**A control that counts the wrong thing is the failure it exists to prevent.**
The case asserting "this fixture stays under CAPS_MAX_KEYS" — written
specifically to stop the truncation trap below from recurring — split the row
on `" | "` and printed fields `$2 "|" $3`, which is (criterion, evidence), not
(id, criterion). Measured: 2 on a 3-key ledger. It undercounts exactly when
one criterion appears under several task ids, which is the ordinary shape, so
a future fixture could sail past the ceiling check while every scan truncated
— the guard reporting green about the wrong bytes. Found by Copilot on PR
#126, one round after the same class was closed at the level above. Both
directions now have their own control: two ids sharing a criterion is 2 keys,
one id with two criteria is 2 keys.

**A comment that names a unit the code does not implement is a lie the build
will not catch.** Both stderr row-printers wrote `[ "${#row}" -gt 110 ]` under
a comment calling it a "110-byte cap". Bash counts CHARACTERS outside the C
locale, and a desktop session runs UTF-8 — so the real cap was 220 bytes for
`é`, 440 for an emoji. Measured: a 100-target report with 200-char criteria
emitted 2591 bytes under `en_US.UTF-8` against 1731 under `C`. This is the
same defect `check_reader_bounds` refuses in every file reader (it requires
`LC_ALL=C` in scope wherever `read -r -n N` appears), one layer up, on the
channel that carries this hook's own instruction back to the model. The fix is
one `report_row` function owning the sanitize, the cap and `local LC_ALL=C`;
its case runs the hook under a UTF-8 locale, because a C-locale-only test
passes against the broken code, which is how it shipped.

**And the fix for that introduced a worse one, caught only by the other
executor.** Capping at byte 110 lands mid-character whenever the character
width does not divide 110 — a 3-byte `€` puts 36.67 characters in the budget —
and the emitted line is then invalid UTF-8. A reader in a UTF-8 locale does not
see a mangled tail; it stops seeing the LINE. `grep 'FAIL rounds'` returned rc
1 on a line that was right there (measured, lokaal task 515). That is strictly
worse than the loose cap it replaced: an over-long row wastes context, an
invalid row loses the whole entry for whoever reads it.

Two things about how it was found are the reusable part. It shipped GREEN on
macOS and red in the container, because the assertion itself used a plain
`grep` — **the test was blinded by the very defect it was testing for**, and
only the second executor exposed it. And the fixture was 2-byte `é`, which
divides 110 evenly and passes on its own; the case now runs all three widths,
because `110 % width` is the whole question. The cut backs off at most 3 bytes
to the last non-continuation byte, and the assertion is now the property
itself — the whole stderr decodes as UTF-8 — plus a visibility check, rather
than a grep that cannot fail honestly.

**The budget then under-billed the case it was written for.** The lookup
COMPARES element `i` and then breaks, so a hit at index `i` costs `i + 1`
comparisons — and the accounting charged `i`, billing a hit at index 0 as
FREE. Measured on a 19,000-row ledger where every row hits the first key:
**charged 0 against 18,999 real comparisons**, `caps_truncated=0`, the scan
reporting it had stayed inside a bound it never touched. With 100 keys created
first and 19,000 hits after: charged 4,950 against 23,950. Not off by one —
off by everything, on the shape a mature ledger actually has (a handful of
targets, reworked repeatedly). This is size-bounds-are-not-work-bounds one
level further down: the bound was correct and its ACCOUNTING was not, which no
test asking "does it truncate" can see.

**Two drafts of the case for it were vacuous, and the mutation is what said
so.** This is the part worth carrying: a bound has a WINDOW in which a fixture
can discriminate, and outside it the case passes either way while reading like
proof.

- Draft one used a hit-only ledger. At one charge per row the STEP bound
  (100,000) is unreachable before the LINE bound (20,000) stops the scan, so
  it truncated on the row count under both accountings.
- Draft two used 100 keys and 3,000 rows: 153,450 charged under the old
  accounting against 156,550 under the new — **both far past the 100,000
  budget**, so both truncated. Arithmetically green, evidentially empty. The
  suite reported 963 passed with the defect restored.

The fixture had to be SOLVED FOR. With `k` keys and hits spread evenly a row
costs `(k-1)/2` under the old accounting and `(k+1)/2` under the new, so the
case needs `rows*(k-1)/2 < CAPS_MAX_STEPS <= rows*(k+1)/2` with `rows` under
`CAPS_MAX_LINES`: k=10, rows=18,500 gives 83,250 against 101,750. Verified
both ways before being believed — `truncated=1` on the shipped code,
`truncated=0` on the pre-fix accounting.

**A pin is a hypothesis until the mutation runs red, and "the suite is green"
is not the same claim as "the case fired".** Both drafts passed the suite; only
running the defect back through them showed they were measuring nothing.

**And then the budget it fixed was skipped entirely on one branch.** The PASS
path charged its lookup and `continue`d, straight past the budget test at the
loop's tail. Measured on 100 keys plus 19,000 PASS rows walking the table:
**964,550 steps charged against a 100,000 budget — 9x over, `caps_truncated=0`,
10.6 seconds.** The entire DoS the budget exists to prevent, restored through
the one branch that skipped the check, while every earlier case stayed green
because they were all FAIL-heavy.

Two things generalise. **A `continue` in a loop whose tail carries a guard is
the shape to distrust** — it reads as "skip the rest of the work" and means
"skip the rest of the guards"; the branches are now one if/elif chain with a
single exit, so there is no path that charges without checking. And **the
premise that made it look safe was wrong**: a PASS is not cheaper than a FAIL.
Both do the same linear lookup; only what happens *after* it differs. The cheap
branch was cheap in the wrong dimension.

The test stub in `tests/test_validate_plugin.py` carried BOTH defects too —
`steps + i` and the PASS `continue` — which is its own lesson, since
`check_caps` EXECUTES that stub: **a fixture that reproduces the bug cannot
witness the fix.**

**A bound on the SCAN is not a bound on the REPORT.** `sanitize_row` walks its
input one byte at a time in bash, and the input is a ledger cell with no length
limit — `check_cell` refuses a pipe and a newline, nothing more. Two FAIL rows
carrying a 20 KB criterion, written through the real CLI and sitting far inside
every scan bound, made **every Stop take 5.81s**; 10 KB alone cost 1.40s in the
formatter. That work sat OUTSIDE `CAPS_MAX_STEPS` and ahead of the
pending/deviation gates, so it delayed the blocking decision itself. Slicing to
128 bytes before sanitizing makes it O(1) per row: 0.53s. The recurring shape —
a limit that governs one stage while the next stage reads the same unbounded
input — is the third variant of size-bounds-are-not-work-bounds in this one
file.

**A truncated scan must not report a count at all.** The report-building loop
carried the right invariant in its own comment — "a key that hit the cap and was
then cleared by a PASS must not appear" — and that invariant holds only when the
scan reaches EOF. Break early on any bound and the unread tail may hold exactly
those PASS rows. Measured: 60 keys failing repeatedly, then a PASS for every one
of them past the step budget, reported **tripped=60 where the true state is
zero**, recurring on every Stop because the same prefix is rescanned. The
operator is told to stop reworking sixty targets they already fixed.

The wrong word was "floor". A floor claims *at least this many*; a prefix cannot
claim even that. So a truncated scan now reports nothing and says the state is
UNKNOWN — which drops a real trip on a genuinely over-bounded ledger, and that
is the right direction for a report-only gate: a missed report costs one line of
guidance, a confidently wrong one costs trust in every line the gate prints.

**The case for that took three attempts, and the middle one flaked in CI.**
Draft one asserted the OUTPUT size — which the old code also bounded, since it
sanitized 20 KB and then cut the result to 110 bytes, so it passed on the
defect. Draft two was a wall-clock ratio and went red on GitHub's runner while
passing locally: reading the clock costs ~291ms per `python3` shellout,
dominating the ~0.5s being measured. **An instrument more expensive than its
signal is not a loose gate, it is noise with a threshold** — and this file
already said so two cases earlier, which did not stop it being written. The
shipped case asserts the property directly: how many bytes reach the
byte-walking sanitizer (20 KB in → 128 out), deterministic and clock-free, with
a control that a short row arrives whole so the bound cannot be satisfied by
mangling every row.

**STDERR IS NOT A CHANNEL ON EXIT 0, and that made the whole feature
undelivered.** The documented Stop-hook contract: stderr from a hook that exits
0 goes to the DEBUG LOG only — never the transcript, and Claude never sees it.
Plain stdout is the same for `Stop`. So the cap report — the one thing that must
be seen precisely when NOTHING blocks — was written to the one channel that
discards it. It became visible only when an unrelated gate happened to block,
which is the exact dependency its own placement comment claims to avoid: *"a
report nobody sees"*.

The reason no test caught it is the transferable part. Every case asserted
captured **stderr** (`$HERR`), because that is where the blocking messages
correctly go — so they all passed while the feature delivered nothing on the
path it exists for. **A test that asserts the message was PRODUCED is not a
test that it was DELIVERED**, and when the channel differs per exit code, the
tests must differ per exit code too. The fix emits `systemMessage` JSON on
stdout on the allowing path only; the blocking paths keep stderr, where exit 2
makes it the guidance the harness feeds back.

Both were found by an adversarial Codex review (PR #126) that read the code
rather than running the suite — worth noting, because the suite was green and
three prior review rounds had passed over both.

A measurement trap worth keeping, because it produced two wrong tables before
the right one: the first "realistic" fixture used 30 task ids x 7 criteria =
210 distinct keys, silently over the 100-key ceiling. Every scan truncated
early, so the timings described PARTIAL work while reading like full scans --
and the curve flattened in a way that looked like good news. `caps_truncated`
was in the output the whole time and I did not read it. **Print the honesty
flag beside the number, and then actually look at it.** The portable alternative was measured rather
than assumed: a string-keyed table is **20× worse** (3m28s on the same input),
because each lookup rescans a growing string. So the linear array stands and
the work is capped directly. **Before adding a bound, ask what it bounds** — a
bound on the INPUT says nothing about the work, and the gate that audits a
growing ledger is the one whose cost grows with it.

### `read` discards NUL, so a byte counter counts the wrong bytes (0.11.12, #126)

`CAPS_MAX_BYTES` was not a bound. The row loop charged its accumulator
`${#row} + 1`, and `${#row}` measures what SURVIVED the read — but bash
variables cannot hold NUL, so `read` discards every one. A megabyte chunk of
NUL arrives as the empty string and costs the budget one byte.

Measured on the shipped hook, macOS bash 3.2: an 8 MiB ledger, four times over
the 2 MiB cap, scanned to EOF in **3.6 seconds reporting `caps_truncated=0`** —
a clean, confident answer about a file the bound existed to refuse. The control
behaves: 3 MiB of ordinary rows truncates correctly, which is exactly why no
existing case saw it. Every fixture was made of text.

**The cost is the delay, not the wrong report.** The cap scan runs BEFORE the
pending and deviation gates, so a corrupt or planted ledger buys seconds of
latency on every single Stop, repeatedly, while the size bound that was
supposed to cap it reads as satisfied. A bounded NUL probe (512-byte chunks,
4096 of them, its own subshell) takes it to 0.044s and `truncated=1` — 82×.

The polarity differs from `scan_deviations`' probe on purpose, and the
difference is instructive. That one fails CLOSED: a not-ours DECISIONS.md may
hide a real unpresented decision, so it blocks. This one is report-only and
nothing here can block, so the only honest degradation is TRUNCATED — the
caller already says "the cap state is UNKNOWN, not clean" for exactly this
shape. Not `scan_failed`, which means "no ledger"; this ledger exists.

**And the pin that should have caught it was blind to its own idiom.**
`check_reader_bounds` counted `IFS= read -r -n N` and had no place for `-d ''`
sitting BETWEEN `-r` and `-n` — which is how every NUL probe in this plugin is
written. All three shipped probes were invisible to it, so each file's floor
was satisfied by its row loop alone and any probe could be deleted with the
build green. `lib/partition.sh`'s entry even said its probe "counts below". It
did not.

That is the transferable half: **a guard and the pin that protects it can share
an author, a session, and a blind spot.** The probes exist to make the row
loops' byte caps real, so a counter that cannot see the probes is the same
defect one layer up — and it stayed invisible because the number it produced
(1, 1, 3) was correct for the reads it COULD see. A floor satisfied by the
wrong subset reads identically to a floor satisfied.

## A gate that compares two commits answers a different question than the merge (0.11.13)

`base-gate.sh` compared `BASE_SHA` against `PR_SHA` as commits. The question it is
meant to ask is "does the RESULT of merging this PR weaken the base enforcer", and in
this repo those diverge in the ordinary case: nearly every PR raises a floor and adds a
`tests/` file, so any branch that has not rebased since reads as LOWERING that floor and
DELETING that file. Measured 2026-09-16 against `d9ed4cd`: a PR whose only change was
one README line produced two `BASE_GATE_FAILED` lines and rc 1, while the merge result
contained neither weakening. The subject is now `git merge-tree --write-tree`'s tree —
no checkout, no worktree, so PR bytes are still never on disk.

**`rc` alone cannot classify what came back.** The first cut had four outcomes and folded
two of them wrong. The reachable set is six, and the discriminator is rc PLUS whether
stdout line 1 is a sha PLUS whether the tree has any entries:

- rc 0 + sha + non-empty → the subject.
- rc 0 + sha + EMPTY → the PR's root tree object is absent. The base always carries
  files, so a clean merge whose result is empty cannot be a legitimate PR. Without this
  guard every arm reads every enforcer file as GONE — a confident weakening verdict with
  an infrastructure cause.
- rc 0 + no sha → an output shape this gate does not understand.
- rc 1 + sha → a real conflict. The message says the gate CANNOT JUDGE it, never that
  the PR weakens anything: GitHub refuses to merge a conflicted PR anyway, so the only
  honest claim is that no result tree exists to read.
- rc 1 + no sha → an unreadable object. No real-git construction reaches it (#133,
  measured on git 2.43 and 2.54: object deletion, corruption, shallow and partial clones
  all land on rc 0, rc 128, or the earlier `rev-parse` refusal). It is KEPT, not deleted:
  it fails closed, and a future git or promisor setup could emit it. The suite reaches it,
  and rc 129 and the catch-all, through a PATH shim that forces merge-tree's exit status —
  that pins the classifier's answer, not a claim that git emits the status.
- rc 128 → a FATAL git error: the repository is incomplete. This is the REACHABLE
  truncated-fetch shape that bit the #125 marker arm, and the first cut reported it as
  `--write-tree` being unavailable — blaming the runner's git version for a corrupt
  repository, which is the same two-causes-one-message defect the classifier exists to
  remove.

Every one is rc 2. Fail closed, as the file's header claims everywhere else.

**Arm 4 keeps the three-dot diff and that is not an oversight.** It names what *this PR*
authored, which a human reads as authorship; two dots there attributes the base's own
commits to the PR — the same false-authorship defect, one level up, in the only
human-facing half. Arm 5 went the other way, to `diff BASE_SHA PR_TREE`: a hard-fail arm
must ask what the merged tree carries, not what the PR's diff happens to show. Measured
honestly: the escape that motivated moving arm 5 does NOT reproduce — when the PR does
not touch the hunk, the base's deletion wins the merge and the marker is absent from the
tree under either form; when it does, merge-tree reports a conflict and the script
refuses before arm 5 runs. The change closes a FALSE POSITIVE (a marker the base's own
tip already carries, restated by the PR) and unifies the subject. Two cases pin the
form together — three-dot reddens one, two-dot reddens the other, only base-vs-tree
passes both; neither alone would have.

## A fixture that needs root does not run on CI's uid (0.11.13)

Two cases added with the classifier were RED on CI from the commit that introduced them
and passed locally every time. Git writes loose objects `0444`; **root bypasses that bit
and an ordinary user does not.** The corrupt-object fixture did
`printf 'garbage' > "$OBJ"`, which silently failed as uid 1000 — the object stayed
intact at 47 bytes, `merge-tree` succeeded, and the rc-128 branch never fired.

They stayed invisible for three more commits because `validate.yml` runs the `python`
rung BEFORE `shell`, and python was red for an unrelated known reason, so the job
aborted before the shell rung ever ran. **A known red on one rung hides every later
rung**; that is the part worth remembering, not the chmod.

The empty-merge-tree fixture had a second, subtler version of the same fault: it deleted
the PR commit's root tree object and relied on git ANSWERING that with rc 0 + the empty
tree. That is not contractual — it held on git 2.43.0 and failed on the runner's 2.55.0,
and the cause on 2.55 was never verified because that build was not available. The fix
does not bet on a diagnosis: the fixture now builds the empty result from ordinary
plumbing (`commit-tree $(hash-object -t tree /dev/null) -p <base>`), which is what the
guard actually claims and behaves identically under both uids. It also made the guard
genuinely load-bearing for the first time — remove it now and arm 1 emits
`BASE_GATE_FAILED: … the ratchet is deleted`, where the deletion-based fixture had only
an argument that a downstream `die` would catch it.

The structural gap — a rootful dev container cannot execute ten of these cases at all,
and the suite says `slack 0` while they are skipped — is #134, deliberately not closed
here.

## A trailing CR is not noise, it is a parser bypass (0.11.13, #136)

Three readers split a 4-cell ledger row (`grep -rn '{row#| }\|{line#| }' scripts/`), and
all three were defeated by a `\r`. `read -r` strips the `\n` delimiter and **never** a
preceding `\r`, so on a CRLF ledger every row arrives one invisible byte longer than the
literal each parser tests against. The three failures were not variants of one symptom —
each broke where that file happened to anchor:

- `lib/caps.sh` anchors on the verdict enum (`case "$verdict" in PASS | FAIL)`), so
  `FAIL\r` matched neither arm, every row was `continue`d, the key table stayed empty and
  the detector reported **`tripped=0` on a ledger that trips**. `ops-stop-hook.sh` sources
  this lib, so that is a fail-OPEN in the enforcement path. Measured on byte-identical
  content: LF `tripped=1`, CRLF `tripped=0`.
- `ops-reverify.sh` anchors on the whole-line header literal, so the header missed its
  own filter, fell into the data parser, and was **emitted as a phantom finding**
  (`undatable: 2`, with a row whose verdict cell read `PASS/FAIL`).
- `ops-verdict.sh`'s `row_is_conformant` anchors on the trailing pipe (`'| '*' |'`), so a
  CRLF fragment was refused as non-conformant and `--reconcile` **left it unrecovered** in
  the one path that exists to recover it, reached by exactly the messy merges `merge=union`
  produces. Measure the POLARITY before calling this one data loss, as two drafts of this
  paragraph did: the refusal is ANNOUNCED (`skipping non-conformant line in <frag>: <row>`
  on stderr, plus a `skipped` count in the summary), so it is the mildest of the three and
  the only one an operator could notice unaided. The other two answer wrongly in silence.

Two things make this worth a landmine rather than a footnote. First, **the repo already
knew**: six other readers strip CR, and `_dec_line` in `lib/partition.sh` carries the rule in
words — "a CRLF checkout must not change semantics". A guard held at six of nine sites
reads as covered. Second, `ops-reverify.sh`'s was a **regression we shipped**: the #128
whole-line header fix replaced a prefix glob that had absorbed the `\r` all along, so
closing a rare collision (a row whose id is literally `Gate`) opened a commoner one. The
same commit's sibling fix in `caps.sh` inherited it.

Where to strip: immediately after the `read`, before any test that could see the `\r`. In
`ops-verdict.sh` that means the reconcile LOOP, not inside `row_is_conformant` — the row
is appended to the ledger of record, and a CR carried in there re-breaks every reader
downstream. In `lib/caps.sh` it sits before the byte accounting, so `bytes` counts the
row as the parser sees it rather than as the file stores it: a CRLF ledger is charged one
byte per line less than its on-disk size, so `CAPS_MAX_BYTES` reads ~1.2% looser there
(measured on 80-byte rows: the accounted budget trips at 25,890 rows, whose true on-disk
size is 2,122,980 bytes against a 2,097,152 cap). It cannot matter, and the reason is
`CAPS_MAX_LINES=20000` — the row bound fires ~5,900 rows earlier than the byte bound on
any ledger of ordinary rows, so the byte cap is the backstop for pathologically long
rows, where one byte per line is noise. Worth stating rather than assuming: an earlier
draft of this paragraph guessed "~0.002%", which is three orders out, and a wrong number
in a landmine file is the thing this file exists to prevent.

`.operator/.gitattributes` sets `merge=union` on the ledgers and no `text`/`eol`, which
is how CRLF arrives. Adding `eol=lf` is a complement, never a substitute: gitattributes
normalize on checkout, and a file written CRLF in the worktree still reaches every reader
(#138).

## An empty listing is not an empty answer (0.11.13, #137)

`base-gate.sh` arm 3 wrote two whole-subtree listings to a file with no exit check:

```sh
git -C "$REPO" ls-tree -r --name-only "${BASE_SHA}" -- tests/ > "$_TESTS_BASE"
```

`ls-tree` exits non-zero and writes **nothing** when a subtree object is unreadable, so
the loop below read zero paths and "no tests/ file was deleted" was the answer. Measured
3/3: a PR deleting `tests/zzz.sh`, with the unrelated `tests/aaa` subtree object removed,
produced `BASE_GATE_PASSED` rc 0 — while the delta report printed `D tests/zzz.sh` one
line above it. The gate saw the violation, named it, and passed. That is the sibling
incident this file's own header cites, inside the guard written against it.

Nothing upstream caught it, and the reason is worth keeping: `merge-tree` only inflates
subtrees that **differ** between the two sides, so an unreadable subtree identical on both
returns rc 0. The change-list diff and arm 5's content diff returned rc 0 for the same
reason. Four independent review passes read this code and none found it; one executed
probe did.

Two bounds, both measured, so the fix stays small. A **single-path** `ls-tree` — the four
calls that pass `-- "$_f"` (the `CORE_FILES` presence loop) or `-- "$_ci"` (the CI-rung
presence check) — resolves without inflating siblings and is unaffected. The empty-tree
guard in the merge-tree classifier (`[ -z "$(… ls-tree "$PR_TREE" … | head -1)" ]`)
already fails closed, because an empty capture makes its `[ -z ]` true and it dies. Only
the two whole-subtree redirects, the ones passing `-- tests/`, needed the guard.

Cited by SYMBOL, not by line: the first draft of this paragraph named `:415`, `:416`,
`:452`, `:453` and `:213`, every one of them stale within two commits — they had been read
off a pre-merge copy of the file, and at HEAD all five pointed at comment or control-flow
lines instead of the calls they claimed. Nothing catches that: `check_coupling_case_refs`
resolves `_"…"_` case-title citations in CLAUDE.md, and has no opinion on a `:NNN` in
prose. A line number in a narrative file is a citation that rots on the next insertion,
so cite the code the way a grep would find it.

And the shape of the guard matters: `die` inside `$( )` exits only the **subshell**.
Measured — `x="$(false || die msg)"` printed the message, left the parent alive and
returned 0; `x="$(false)" || die msg` exited 2. These two sites are plain redirects, so
`cmd > file || die …` fires in the right shell. A `checked_git` wrapper called in test
position would not.

Fixtures for this class remove the loose object rather than `chmod`-ing it: removal needs
directory permission, not file permission, so root and non-root behave alike (#134's
lesson, applied). A packed object cannot be removed, so the fixture asserts its own
precondition and skips with a named reason instead of passing against a repo it never
broke.

## A writer guard and its reader bucket are ONE decision (0.11.14, #139)

`check_cell` in `ops-verdict.sh` refused `|` and newline and admitted `\r`, so a caller
passing one landed it INSIDE a cell in the ledger of record. Measured, and byte-identical
on `origin/main`, so it predates #136:

```
$ ops-verdict.sh T1 "$(printf 'cr\rit')" ev PASS --owner S1
recorded T1 = PASS
$ od -c .operator/VERDICTS.md | tail -2
| T1 | c r \r i t | ev @no-commit | PASS |\n
```

#136 taught three row parsers to strip a TRAILING CR. That is the right fix for a CRLF
checkout and says nothing about a CR in the middle, which reaches every consumer: the Stop
hook's `sanitize_row` renders it `?`, and `ops-reverify.sh`, which has no sanitizer, emits
the raw byte into its report. Refusing at the writer is what keeps it out.

**The arm could not stop at the cells, and could not be added to one CLI.** `check_cell`
is called by `check_bare_name`, so the arm also reaches the task-id — and that is the
half that makes it safe rather than the half that makes it dangerous. Measured on a
patched `.operator/bin/` copy, with the arm in `ops-verdict.sh` alone:

```
ops-task.sh    (unpatched) opens ta\rsk   -> sentinel S1__ta\rsk, rc 0
ops-verdict.sh (patched)   close          -> "task-id contains a CR", sentinel intact
ops-verdict.sh (patched)   --defer        -> same refusal, sentinel intact
Stop hook                                  -> rc 2, blocking, forever
```

An opener admitting what the closer refuses does not produce a stricter gate; it produces
an unclosable task. So all three writers (`ops-task.sh`, `ops-verdict.sh`, `ops-adopt.sh`)
carry the arm, and `check_guard_parity`'s executing probe table carries the `a\rb` tuple
that proves each one still dies on it.

**And the sentinel already on disk is the reader's problem.** A name our CLIs can no
longer address is F118/F135's class exactly, so a CR in the TASK half joins the MALFORMED
bucket in `scan_pending` with the same `rm -f` remedy. Keyed on `$id`, not `$name`: the
bucket keyed on the whole name turned 28 cases red, because a CR in the OWNER half is a
different thing — `sentinel_owner_of_name` already degrades it to unowned (its
`*[[:space:]]*` arm matches a CR; verified in bash 3.2 and 5), which fails CLOSED as MINE
while the task half stays addressable and closable. Bucketing that would destroy a task
the operator could have closed honestly.

**The message is part of the fix, and nothing saw it.** With the bucket arm in place and
the Stop hook's message reverted to its pre-#139 wording — naming only `__` and empty ids
— the whole suite shipped GREEN. A CR is invisible in a terminal, so a message listing
causes that do not include it sends the operator hunting for a separator that is not
there. The enumeration is now pinned by its own case. This is the same
message-drifts-from-code shape #99 exists to prevent, one file over: there the
disagreement was between the bar and the gate, here between the gate and its own remedy.

Mutations, each red in the case written for it, run in an isolated clone (parallel
mutate/restore cycles corrupt each other): `check_cell` arm removed 6 red; `ops-task.sh`
arm removed 1; MALFORMED arm removed 4; bucket keyed on `$name` 28; message reverted 1;
the arm widened to `*)` 108 (the refuse-everything control). In `check_guard_parity`, the
`a\rb` tuple goes red on each of the three CLIs and green when restored — and before that
tuple existed, deleting the shipped arm reported `all contracts hold`.

## `eol=lf` closes git as a producer, not CRLF as a class (0.11.14, #138)

`.operator/.gitattributes` set `merge=union` on the ledgers and no `text`/`eol` attribute,
so a clone with `core.autocrlf=true` — what every Windows clone gets — checked the ledgers
out CRLF. Measured on a scratch repo, same fixture both ways:

```
without the rule:  | a | b | c | PASS |\r\n
with text eol=lf:  | a | b | c | PASS |\n
```

And the limit, measured in the same repo immediately after: a ledger written CRLF by an
EDITOR in the worktree stays CRLF, because gitattributes normalize on checkout and commit,
not on third-party writes. So this is an ADDITION to #136's reader guards and never a
replacement — which is why the suite carries the LIMIT as its own case, beside the EFFECT
one. A rule present in the file proves nothing about what git does with it (`eol=lf`
without `text` is inert, a typo'd path matches nothing), so the EFFECT case commits a
ledger under `core.autocrlf=true`, checks it back out, and reads the bytes.

Written per-file rather than as a `*` rule: `.operator/` also holds `bin/` and `pending/`
sentinels, and declaring those `text` invites git to rewrite bytes in files whose whole
point is byte-fidelity.

## Six CR guards left unpinned on purpose — a priced omission (#138, closed into this file)

The CR strip `${x%$'\r'}` sits at six sites that parse something OTHER than a 4-cell
ledger row, and no validator pin covers them. That is a decision, recorded here so it
never reads as coverage:

```
scripts/ops-adopt.sh     LOCK_HOLDER_REC, FALLBACK_REC   (lock holder record)
scripts/ops-verdict.sh   LOCK_HOLDER_REC, FALLBACK_REC   (same two)
scripts/lib/partition.sh line="${1%$'\r'}"              (a DECISIONS line)
scripts/statusline.sh    line="${_lines[i]%$'\r'}"      (same, the bar's copy)
scripts/ops-render.sh    awk { sub(/\r$/, "") }          (template front matter, F29)
```

Cite them by symbol, never by line — the numbers moved twice while #138 was open.

Why no pin, each reason checked when #138 was filed and still true at its close:

1. **No measured defect at any of the six.** They carry the guard; a pin would be green on
   arrival and prove only that a correct thing is still correct.
2. **A different family.** #136's three defects (caps.sh failing OPEN, `--reconcile`
   dropping a row, ops-reverify phantoming one) all lived in 4-cell row parsers, and those
   are pinned by `check_cr_strip_parity`. None of these six parses a row.
3. **An honest pin is unbuildable.** Four are bare inline expressions with no enclosing
   function for a probe to execute, one is awk. Per F140/F144 a behavioural pin EXECUTES the
   shipped code; a literal scan over inline expressions in two languages is the substring
   shape that has shipped "all contracts hold" against a dead arm five times.
4. **No shared helper can reach four of them.** They live in the install set, copied
   standalone into `.operator/bin/` — a `lib/` CR helper is ruled out for this class.

The complement shipped instead: `text eol=lf` in `.operator/.gitattributes` (#141, the
section below) stops git producing CRLF ledgers; an editor writing CRLF in the worktree
still reaches every reader, so the six guards stay load-bearing.

**Reopen when** a defect is measured at one of the six, or a function boundary appears at
one of them that an executing probe can call. Either makes a pin honest; neither exists.

## An arm held closed by another arm's pathspec (0.11.14, #140)

`base-gate.sh` arm 3b — the rung-set comparison — shipped with the same unchecked-listing
fail-open #137 fixed at arm 3, in the arm that same commit wrote:

```sh
_ci_rungs() {
  git -C "$REPO" show "${1}:${2}" 2>/dev/null \
    | grep -vE '^[[:space:]]*#' | grep -oE 'gate-suite\.sh [a-z]+' | sort -u
}
...
done < <(_ci_rungs "$BASE_SHA" "$_ci")
```

An unreadable base blob yields an empty list, the `while` is a no-op, every rung removal
passes. The base-side `ls-tree` presence probe one line up had the same hole in its
quietest form: a `continue` past the whole file, which prints nothing and makes no claim.

**Why it was not caught by reading.** The pipeline cannot be checked AS a pipeline.
`pipefail` reports the last non-zero status and `grep` exits 1 on no-match, so "the blob
is unreadable" and "this CI file legitimately runs no rungs" are the same status. Any
guard written around the pipe is either vacuous or fires on honest input. The fix stages
the blob to a file through a checked `_ci_show` and reads only THAT status.

**The interlock is the real lesson.** On the shipped gate the escape did not reproduce as
rc 0 — arm 5's `git diff` fails on the same corruption, because `.github/` sits inside its
pathspec, and it `die`s rc 2 first. So the gate was correct by accident, through a
dependency nothing declared. Widening arm 5's pathspec by one `':(exclude).github/'` — an
unrelated, entirely plausible edit — turned a dropped rung into `BASE_GATE_PASSED`, rc 0
(measured). An arm whose correctness depends on which OTHER arm happens to die first is
not a gate; it is a coincidence with good luck so far. The fix is verified against the
widened copy for exactly that reason, and that probe is now a case.

**Two guards, two different corruptions.** Deleting a file's BLOB leaves `ls-tree` at rc 0
— the tree still names the entry, only `git show` fails (rc 128). Deleting the enclosing
TREE object is what makes `ls-tree` exit 1. So the `git show` guard and the `ls-tree`
guard cannot share a fixture, which is how the second one was found: reverting its `die`
alone left the whole suite green, because every case corrupted the blob.

Both `ls-tree` presence probes then turned out to be **unreachable in this repo shape**
— the PR-side one too, which the first draft of this section did not say and a review
panel caught by deleting its `|| die` and watching the suite stay green. `PR_TREE` is the
MERGED tree and shares the base's objects, so corrupting one side corrupts both views:
a fixture deleting the PR commit's `.github/workflows` tree refuses with *"could not list
… at the base ref"*, never the PR-side message. The base-side probe is unreachable for
the nearer reason — a missing tree
object is refused earlier still, by the CHANGE-LIST `git diff base...pr` that runs before
arm 1 (not by arm 4, which makes no git call at all — the first draft of this paragraph
said arm 4, and a review pass caught it). Its case pair asserts
the POLARITY with an `HONESTY NOTE` rather than asserting a message that never appears.
The guard stays: unreachable today is not unreachable after the next arm moves, and that
is the whole failure this section is about.

**Fixtures that destroy shared state owe every later case a fresh one.** Deleting a loose
object is permanent for the repository. Three cases here were written against one scratch
repo and two of them measured the corrupted tree while claiming to measure a healthy one —
the ADD-a-rung control (which should pass and could not) and the PR-side case (which never
reached its own branch, because the run refused at the base check first). Four repos, one
per corruption. Same class as the shared-sentinel error in #139's first draft, one layer up.

## One removal is not "the CR is handled" (0.11.15, #139 items 1 and 3)

#136 taught the three 4-cell row parsers to strip a trailing CR, and that closed the
case it named: a plain CRLF ledger, which is what `core.autocrlf` produces on every
Windows clone. It did not close CR handling as a class. `${row%$'\r'}` removes at most
ONE CR, so `\r\r\n` kept one and every comparison below it missed. Measured on
byte-identical content at the 0.11.14 tree:

```
LF       tripped=1
CRLF     tripped=1      <- what #136 bought
\r\r\n   tripped=0      <- unchanged, scan_failed=0, truncated=0
```

That last line is the whole reason this is a landmine rather than a footnote. A
`tripped=0` with both error flags clear is **byte-identical to a clean ledger**, in a
detector whose entire job is not to miss a sequence. The fix was strictly narrower than
the bug it replaced, which is the shape that reads as "handled" in every later review.

**Both remedies the issue proposed were wrong, and measuring said so.** The issue offered
"strip in a loop, or `${row%%$'\r'*}`":

| candidate | 1 MiB all-CR line | correctness |
|---|---|---|
| unbounded `while ${row%$'\r'}` | **>300s**, killed | correct |
| `${row%%$'\r'*}` | 0.006s | **truncates the row** at a mid-cell CR |
| bounded loop, max 16 | 0.30s | correct on all six probes |

The unbounded loop is O(n²) on a pathological line, and the row loop's own
`read -r -n 1048576` permits exactly such a line — inside a hook that runs on every Stop.
The greedy form is fast and silently discards cells. Only the TRAILING run is a
terminator artifact; a mid-cell CR is data, which is why `CAPS_MAX_CR` is a bound and not
a convenience, and why a row still ending in CR after 16 removals sets `caps_truncated`
rather than being guessed at.

**The byte cap was loose, and is also unreachable.** The strip ran before
`bytes=$((bytes + ${#row} + 1))`, so a CRLF line was charged one byte less than it
occupies — the ~1.2% the issue measured. `+ _cr` makes the identity exact. But the
probe written to assert it through behaviour could not discriminate, and the reason is
worth keeping: the **NUL probe above the loop refuses any file over 4096 × 512 bytes,
which is exactly `CAPS_MAX_BYTES`**, and accounted bytes can never exceed on-disk bytes.
Bisected: 2,097,152 B passes the probe, 2,097,664 B is refused. So the row loop's byte
cap is a second line of defence behind a tighter one, and the looseness was never
reachable through it. The case says so instead of asserting a discrimination that does
not exist.

The first draft of that case recomputed the accounting inside the test and asserted its
own arithmetic — green against a `caps.sh` with the addend deleted. A test that
reimplements the rule it is testing tests the reimplementation. The surviving pin is a
literal token grep, which is weaker and honest about being weaker.

## A citation with a number in it has no guard (0.11.15, #139 item 4)

Five `file.sh:NNN` citations in this file's own #137 section were stale within two
commits — read off a pre-merge copy, and at HEAD all five pointed at comment or
control-flow lines while the validator reported "all contracts hold".
`check_coupling_case_refs` resolves `_"…"_` case titles and has no opinion on a line
number.

The issue proposed a CONVENTION (cite by symbol). A convention followed in one file and
stated nowhere is what this repo elsewhere calls a hypothesis, so `check_line_citations`
is the mechanical half: past EOF or onto a blank line is refused. It **cannot** see a
citation that still resolves and no longer says what the prose claims, and the message
says so rather than implying the number is verified.

It found a live defect on arrival, no mutation needed: `docs/REPLAY-CHARTER.md` cited a
line in `ops-init.sh` that was blank, attached to a claim ("the install set lives here")
that had been false since #76 moved the set to `scripts/ops-install-set.sh`. Two rots in
one citation — the address and the assertion — which is the argument for symbols in one
example.

One more thing the fix itself demonstrated: the first repair kept the rotted citation
inside the sentence explaining that it had rotted, and the check matched it again. A
check that scans prose cannot tell a citation from prose ABOUT a citation — the same
shape as the commit that closed #139 by quoting a closing keyword. Paraphrase it.

## A comment that names the wrong gate is worse than no comment (0.11.15, PR #144 review)

The 0.11.15 fix hand-copies a bounded CR strip into three parsers, because two of them
may not source a lib. The comment on one copy said `check_guard_parity` pinned them
equal. It did not, and nothing did: that check compares `check_bare_name` and
`check_owner_name` across the three CLIs and contains no reference to a CR, a counter, or
a bound. Measured — reverting `ops-reverify.sh`'s whole loop to a single
`${row%$'\r'}` left `validate_plugin: all contracts hold`.

The bash suite caught it. So the code was safe and the SENTENCE was not, which is the
harder failure: a maintainer who reads "the validator pins this" runs the validator,
sees green, and ships the drift. That is #111's rule — *name the gate that went red* —
applied to prose instead of to a verdict row. The remedy was not to soften the comment
but to make it true: `check_cr_strip_parity` now holds all three sites to `CAPS_MAX_CR`
and refuses a loop that removes without counting, because equality alone is satisfied by
three identically-gutted copies (F30).

## One bad row can silence a detector, and the message must say which bound fired (0.11.15, PR #144 review)

`scan_caps` breaks on a row still carrying a CR after the bound, and a break abandons the
rest of the ledger. Measured: two genuine FAIL rounds plus one 20-CR row reports
`tripped=0`, where the same ledger without that row reports 1. The polarity is right —
a truncated scan read a prefix, and a prefix cannot claim even a floor — but the
consequence is that ONE planted row anywhere suppresses a real trip everywhere.

What made that dangerous was the message, not the break. The Stop hook's truncation
notice enumerated four SIZE bounds, so a session stopped by a corrupt row told the
operator their ledger was too big. They then go looking for length in a file whose real
problem is one line. A message describing a different bound than the one that fired is
the #99 defect one file over, and this repo has now hit that shape three times: the
statusline/hook disagreement, #139's MALFORMED wording, and here.

`caps_truncated_reason` lets a bound name itself. The size bounds leave it empty on
purpose and the caller enumerates them — an always-set reason would describe the CR case
on a ledger that is merely long, which is the same defect pointing the other way.

**The three copies answer differently past the bound, and that is deliberate.** `caps.sh`
stops the scan: it is a detector, and a partial count is worse than none.
`ops-reverify.sh` skips the row and says so: it REPORTS rows, so stopping would hide every
later one — and without an arm it rebuilt the exact defect the strip exists to remove
(measured at 17 CRs: `| 3 | T-y | FAIL | ^M | no-commit | … |`, a broken cell in the
operator's own report). `ops-verdict.sh --reconcile` needs no arm at all, because the
residual CR lands in the verdict cell and `row_is_conformant`'s enum already refuses it,
named on stderr with a skipped count. Three answers, one rule: never let a corrupt row
pass as a clean one, and never let the refusal be silent.

## A check scoped to one directory reports green about the rest (0.11.15, PR #144 review)

`check_line_citations` shipped globbing `docs/**/*.md`. A reviewer found a live rot it
could not see: `CHANGELOG.md` cited `statusline.sh:84` for the `$PWD` fallback, which at
HEAD is a `stat -c %Y` probe — the fallback moved to the `PROJ` resolution. The check was
correct about every file it read and silent about the one where the defect was.

Two smaller ones from the same review, both in the branch written to refuse: `:0` was
accepted, because `lines[0 - 1]` is Python's LAST line and that line is usually non-blank;
and the message for an out-of-range citation said "has only N lines", which is nonsense
for `:0`. A guard whose refusal path has its own bug refuses nothing, and reads as
coverage.

## The first check written by something that could not read the code (0.11.16, #112)

Everything gating this repo was written by the agent that writes the code, and readable
by it. #112 called that what it is: given enough attempts a builder optimises against
checks it can read, and that is not a claim about hostility, it is what iteration is.

The holdout lives in `ci-admin/cc-operator-holdout` on `lokaal`, and the property that
matters is that **a session working here never clones it**. The sibling project this
argument came from keeps its holdout inside the repo, protected by a prompt-level denial
to the builder plus a guard auto-rejecting any PR that touches it — two mechanisms to
simulate a property that a separate repo simply has. Structural beats enforced: there is
no instruction to forget and no guard to bypass.

**The derivation is the expensive half, and the tempting shortcut destroys the point.**
`holdout.sh` was written by a `claude -p` process in an empty directory with every file
tool denied — no Read, no Bash, no Grep. Not "an agent told not to look at `scripts/`":
an agent that had no way to look at anything, whose entire context was
`templates/OPERATOR.md` plus a black-box interface block naming how to invoke the
installer, the CLIs and the two hooks. When two of its checks failed, the repair was
dispatched BACK to a denied-context process with the measured system output as evidence.
Hand-editing those two checks here would have taken ten minutes and produced a mirror —
the artifact would still be called a holdout and would no longer be one.

**What it found on the first run that all 1101 in-repo shell cases missed.** The charter
prescribed `ops-claims.sh --claimed "<paths>"`. The shipped CLI has required a mandatory
`--since <sha>` since CR2 and exits 2 without it, so an operator following the charter
verbatim got a usage error. Every in-repo test passed throughout — they were written
against the CLI, so every one of them passed `--since`, and nothing in the repo compared
the charter's prescription to the CLI's contract. That is precisely the defect class an
in-scope check cannot see: both sides were individually correct and nobody read them
against each other.

**And the first fix for it was itself the F30 shape.** The charter was one of THREE
places prescribing that invocation: `README.md`'s CLI cheat-sheet carried the same
broken form, and `docs/PLAYBOOK.md`'s dispatch procedure had `[--since <dispatch-sha>]`
in square brackets — marked OPTIONAL for a flag the CLI refuses to run without. Fixing
the charter alone left two copies saying the thing the holdout had just proved wrong.
The holdout cannot catch that: it tests the SYSTEM, and every one of those copies is
prose. Grep the invocation, not the file you happened to be reading.

**And the fix for THAT was still one instance, not the class (0.11.17, #149).** Three
copies corrected by hand leaves nothing that would catch the fourth. `check_prose_invocations`
is the mechanism: it extracts every `ops-*.sh --flag` prescription from tracked prose and
asserts the CLI would accept it — an unknown flag, or a mandatory flag omitted, or (the
PLAYBOOK shape) a mandatory flag wrapped in `[…]`, which a presence test reads as
prescribed while the brackets tell the reader it is optional. All three of the drifted
copies were reverted and each drove it red at its own file and line, restored
byte-identical.

Two things about how it is built are the reusable lesson. **The flag sets are read off
each CLI's own parser**, never catalogued in the validator — a table here would be a
second copy of the contract, correct when written, drifting the moment the parser
changes, with nothing comparing the two. That is the defect this check exists to catch,
reintroduced one layer up. **And a flag is mandatory PER FORM**: `--owner` is required by
`ops-verdict.sh --mark-handoff` and optional in its verdict form; `--expect-clean` is a
complete form of `ops-claims.sh` needing no `--since`. The CLI already declares its forms
in its own `usage:` alternation, so that is what is read.

The order mattered more than the mutations. **Four defects in the check were found by
RUNNING it on the correct tree before mutating anything**, each of which would have
condemned a correct line: a line-anchored scan missed `ops-render.sh`'s two-arms-per-line
`;;` packing (`--revert` read as unknown); mandatory flags treated globally rather than
per form; `break` after the first `usage:` string read `--mark-handoff`'s requirements
onto the verdict form, condemning five correct lines including the charter's own; and a
line-only scan for the deliberate-negative-control marker condemned REPLAY-CHARTER.md's
`--ownr` probe, whose teaching sentence sits in the paragraph ABOVE it. Ten mutations
afterwards all went red. A pin that had only ever run against its own mutation would have
shipped all four — the mutation proves the check catches the defect, not that it leaves
correct work alone, and only one of those two is what a maintainer feels.

What it CANNOT see is the same limitation `check_line_citations` carries: a prescription
that still parses and no longer means what the prose claims. That needs a human.

**And then a five-reviewer panel found six more, four of them in the check itself.** Worth
recording because of WHERE they were: not in the hard part (reading a shell parser) but in
the suppression logic and the scan boundaries — the places a guard is least examined
because they are what makes it quiet.

Three were the check performing its own defect class:

- **It condemned correct prose.** `re.finditer` yields non-overlapping matches, so the
  citation regex's greedy tail swallowed the NEXT invocation whole. `Run ops-verdict.sh and
  ops-claims.sh --since <sha> --claimed "<paths>"` — entirely correct — reported
  ops-verdict.sh for `--claimed --since`, flags it never took, while ops-claims.sh was
  never examined at all because the scan position had already passed it. One regex, a false
  positive on one CLI and a false negative on the next. Bounding the tail at the next CLI
  name fixed both and immediately exposed a second: a span of BARE FILENAMES (the install
  set) has each entry reading as the next one's argument, so the flagless arm fired twice
  on a list. An argument that is itself a CLI name means the span is an enumeration.
- **The negative-control exemption suppressed its neighbours.** Keyed on the paragraph, it
  exempted every invocation in that paragraph. Reproduced on the real tree: a genuinely
  broken `ops-claims.sh --claimed "x"` appended to REPLAY-CHARTER.md's `--ownr` teaching
  paragraph was reported by nothing. The general rule: **an exemption must attach to the
  thing it excuses, not to its neighbourhood.** The paragraph supplies the marker; the line
  must supply the subject.
- **A helper committed the very defect it was written to remove, one level down.**
  `delta_is`'s `${2:-0}` substituted 0 for an EMPTY count, so `0 - 0 -eq 0` passed on a file
  that EXISTS — strictly worse than the absent-file case, because nothing looks wrong. #148
  guarded the FILE and left the VALUES unguarded.

The fourth is the one to remember when writing any scanning check. **The root globs were
unpinned, and the floor could not have caught them.** Narrowing `_roots` to `["*.md",
"docs/**/*.md"]` — the plausible "the `*.md` glob already covers everything" edit — stops
reading `templates/OPERATOR.md`, the file #149's defect shipped in, and every case plus the
real tree stayed green. The `_MIN` floor counts INVOCATIONS, not which files produced them,
and the reduced set still cleared 15. A count is not a selection. Assert which files are
read, the way `check_coupling_case_refs` asserts its own: a checker that is perfectly
correct about the wrong bytes reads exactly like a working one.

**Three derivation rounds, and the cap stopped the fourth.** Round 1: 27 passed, 4
failed. Round 2: 31/2. Round 3, after another prompt tweak: 21/10 — it regressed checks
round 2 passed and shipped a comparator printing `expected == got` as FAIL. That is the
same-target-rework cap at 2, logged in DECISIONS.md, and the escalation was to a
different mechanism (a repair dispatch carrying measured evidence) rather than a third
guess at the prompt. Round 4 from that repair: 33/0.

**And 33/0 was itself a false green, found by reviewing the suite rather than running
it.** A coverage review observed that `ops-adopt.sh` appeared in the holdout only as a
string the SessionStart guidance must MENTION — never as a CLI the suite INVOKES.
Measured rather than argued: `ops-adopt.sh` replaced by a body of `exit 0`, and the
suite reported 33 passed, 0 failed. The entire re-claim mechanism RECOVERY PROTOCOL
step 6 depends on could be deleted and the holdout would have certified the release.
A fifth repair dispatch (denied-context, carrying the mutation as evidence and the
explicit bar that a no-op must not pass) took it to 41 checks; the same mutation now
drives 6 red. The review also flagged two checks as possibly vacuous — mutations proved
both real: `--defer` writing its row without clearing the sentinel drives
`defer_clears_sentinel` red alone, and an auto-bar that blocks and prints "autobar"
while arming no sentinel drives `autobar_blocks_two_file_change` red alone. Two of
three suspicions wrong, one right, and only mutation could tell them apart.

The floor moved with it: `HOLDOUT_MIN_CHECKS` 30 → 41, because a floor below the true
count is slack a deletion hides in — `tests/floors.env`'s lesson, one repo over.

**Then the holdout was caught committing the defect it exists to refuse.** A
silent-failure audit found three checks reporting `ok` having measured nothing, all the
same arithmetic: `$(( $(wc -c < absent) ))` is `0`, so a before/after byte comparison
was `0 == 0`; `sed -n "1,p"` on a missing file twice, compared, is equal, so the guard
on the ledger's append-only-ness compared nothing to nothing; and `grep -c` yields `0`
for "correctly absent" and "file not there" alike. Measured with `ops-init.sh` mutated
to create no ledger: 27 passed / 14 failed, **and all three were among the passes** —
fourteen other checks caught the condition while these three reported success about it.
After a fourth denied-context repair, the same mutation gives 24 / 17, each naming its
precondition. The shape to carry away: **a check whose PASS condition is `0`, or an
empty string, or an equality between two reads of the same absent file, cannot tell
success from never-having-measured.** It is `cmd > log; echo $?` again, in a test
harness costume, and writing the harness that refuses it does not immunise you.

**None of this needs the forge.** Property 1 is "outside the builder's read scope";
`lokaal` is one way to buy it and a second GitHub repo is another, for free — the
holdout repo's `PORTING.md` prices the alternatives (orphan branch and local directory
both weaker, and it says how). `run-holdout.sh` contains no Forgejo: verified against a
plain GitHub URL, `HOLDOUT_VERIFIED sha=7057dcf7f2f6 checks=41`. The two Forgejo facts
that shaped it (a queued job has no task row, `conclusion` is always `null`) explain why
it gates on a marker, but "never gate on job status" is equally right on GitHub Actions,
where a skipped job and a successful one are both green at the API.

**The two failures that survived to round 2 were over-assertions, not defects**, and
both are worth recognising because they are what an independent writer gets wrong. It
required the SessionStart banner to enumerate every open task, which the charter never
promises (the banner names the adopt CLI and the new id; enumerating is the operator's
job). And it grepped for the literal word "warn" where the charter says the CLI "warns"
— the system says `opened X UNOWNED — blocks every session's Stop; pass --owner <sid>`,
which keeps the promise in full without the word. A check measuring vocabulary instead
of behaviour fails a correct system, and a holdout that cries wolf gets ignored, which
is the only way this mechanism dies.

**Absence fails closed, and on this forge that is not optional.** A queued Forgejo job
has no row in `actions/tasks` at all, and `conclusion` is always `null` on Forgejo 16 —
so "the holdout did not run" and "the holdout found nothing" are the same silence unless
something insists on a positive marker. `run-holdout.sh` demands
`HOLDOUT_PASSED sha=<the sha it was asked to test>` and a check-count floor, separating
six failures by exit code: absent suite 4, ran-but-reported-nothing 4, wrong sha 5,
shrunken suite 6, bad sha 2, no sha named 2. Each measured with a crafted stub. The
floor is `tests/floors.env`'s lesson one repo over: a suite that silently stopped
emitting checks exits 0 with everything it still runs green.

**Proof it can go red.** Seven mutations against the gate CLIs, each restored
byte-identical: the Stop gate's `exit 2` → `exit 0` (4 red), the `+dirty` branch deleted
(2 red), `ops-claims.sh` examining only the first changed path (1 red), the ledger row's
verdict word hardcoded to `PASS` (1 red), `--defer` writing its row without clearing the
sentinel (1 red), an auto-bar that blocks without arming (1 red), `ops-adopt.sh`
replaced by `exit 0` (6 red — 0 red before the review), and an installer that creates no
ledger (17 red — 14 before the vacuity fix). The third is the `LIMIT 1` shape the
exact-values rule exists for — a suite asserting "some violation is reported" passes it;
one asserting the named file passes it too, as long as that file is first. The first
attempt at that mutation was a syntax error, which drove the suite red for the wrong
reason and proved nothing; a mutation that makes the target unparseable is not a
mutation test.

**The asymmetry to keep in mind when reading the shipped suite.** `holdout.sh` is
derived from the CORRECTED charter, so it no longer re-finds the `--since` defect — it
asserts the fixed contract and passes. The suite that found it is kept as
`derivation/derived-round2.sh` in the holdout repo. A holdout that has been run once
against a fixed system tells you nothing about what it caught; the derivation record is
the evidence, not the current green.

## A refusal test that passes when there is nothing to refuse (0.11.17, #148)

Thirteen assertions in the shell suite proved a writer had appended nothing by comparing
two reads of the same file. With that file ABSENT both reads are the empty string and
`[ "" = "" ]` is true, so each certified a refusal about a ledger that was never there.
Nothing was mis-reporting — with a working `ops-init.sh` the file always exists — but
their passing value was indistinguishable from never-having-measured. They were carried
by the rest of the suite, not by their own logic.

Measured rather than argued, in isolated `git archive` trees, pre-fix and post-fix:
`ops-init.sh` mutated to skip the `VERDICTS.md` copy (still exit 0) took the suite to
991/110 with NINE of the thirteen among the PASSES, and to 997/119 after the fix with
all nine red. A second mutation (no `DECISIONS.md`) gives 1085/16 with three more, and
1097/19 after. The thirteenth passes under that mutation both before and after, and does
so HONESTLY — an earlier case's `>> "$DECISIONS"` creates the file before it reads it,
which is worth knowing before calling it a survivor. 9 + 3 + 1 = 13.

The two sibling sites that already used integer `-eq` failed closed for free, and bash
said exactly why: `[: : integer expression expected`. That is the whole difference —
`[ "" -eq "" ]` errors where `[ "" = "" ]` succeeds.

**The count itself was wrong in four files until a reviewer re-derived it**, and the
shape of that error is the point: "eleven" was the tally from the first substitution
batch, three more sites were converted afterwards, and nothing re-counted. A number
written beside the code is a second copy of the code, and it drifts exactly like any
other copy — the F30 rule, applied to prose. Re-derive a count from the thing it
describes, or do not write it.

The fix is four helpers that assert the precondition and then compare with `-eq`, and
the absent case is a FAILED check that NAMES the missing file on stderr. Naming it is
not decoration: a refusal that says nothing reads as an ordinary red and gets
re-diagnosed from scratch.

**The controls matter as much as the refusals.** Each helper is driven through BOTH
states — refuse the absent file, ACCEPT the present unchanged one. A helper that refused
everything would pass a suite of refusal-only controls while failing every real call
site, and the suite total is what would tell you, ten minutes later.

The general shape, which is worth recognising anywhere: **a check whose PASS condition
is `0`, an empty string, or an equality between two reads of the same absent file cannot
tell success from never-having-measured.** It is `cmd > log; echo $?` in test-harness
costume. `gate-suite.sh`'s marker-plus-floor design exists to refuse it one level up;
this is the same rule applied inside a case.
## The tier nothing dispatched, and the fallback that hid it (#158)

`grep -rn IMPLEMENT workflows/` returned **nothing**. IMPLEMENT is one of the four
canonical tiers — declared in `ops-tiers.sh`'s `TIER_NAMES`, given a baked default,
documented in the README and in `commands/tiers.md` — and it is the tier
`ops-render.sh` binds the implementer to (`seat_add mechanic IMPLEMENT default`). The
one seat on the tier was the one seat no workflow could reach on it.

What made that invisible for so long is the shape of the workaround. Two routes existed
and each looked like an answer. `ops-render.sh` writes the binding into project-layer
agent files — correct, but global and only after a session restart, which mid-engagement
is the event the RECOVERY PROTOCOL exists to survive. And `dispatch.js` resolved
`model || JUDGMENT` with only JUDGMENT in its `DEFAULT_TIERS`, so a `mechanic` dispatched
without an explicit `args.model` ran on the judgment default and **said so in the log**.
That log line is why it read as a design: a fallback that announces itself feels honest.
It was honest and wrong — a silent tier PROMOTION in the one direction that costs money,
the class #153 measures, reached by a different door.

The fix is not a better default. A workflow cannot read `tiers.env` (no filesystem in the
sandbox), so every default it could pick is a guess about a binding it cannot see. The
honest move is to DECLINE TO CHOOSE: omit `model` from the `agent()` options entirely and
let the layers that already own the decision answer — the seat's frontmatter, a rendered
project-layer agent, `$CLAUDE_CODE_SUBAGENT_MODEL`. Renderer and dispatcher stop
competing: render sets the standing default, dispatch overrides per call, and an absent
override no longer overwrites that default with a third answer.

The premise that rung was reasoned from is now MEASURED (2026-09-21). What existed was
the CONVERSE — `opts.model` overrides the agent file's frontmatter (2026-07-29) — and the
complement was carried in the code as an admitted assumption rather than assumed away.
A two-seat probe settled it: same `agentType` (a project-layer agent pinning
`model: opus`), one dispatch with no `model` key and one with `model: "haiku"`; the
runtime recorded no model key for the first and served it `claude-opus-5`, and recorded
`"model":"haiku"` for the second and served it `claude-haiku-4-5-20251001`. Writing the
assumption down as an assumption is what made it cheap to close — the alternative,
phrasing it as a fact, is the class this file exists for.

Making four tiers nameable had a second-order cost that is easy to miss: the eager
`for (const [name, id] of Object.entries(TIERS))` validation loop was sound only while
JUDGMENT was the sole dispatchable tier, because then every key was reachable on every
call. With four tiers nameable and at most one reached per call, the same loop resurrects
what PR #78 removed — a malformed value on a tier THIS CALL never touches failing the
run, which makes "forward the resolver's whole map" unsafe the moment any single
`tiers.env` binding is malformed. Validation moved to the id that actually reaches
`agent()`. The guard did not weaken; its subject narrowed.

## Serialization is a property of the script, or it is nothing (#158)

The charter says one implementer at a time, read-only workers in parallel on disjoint
inputs [D:CHART-r6]. Until `workflows/implement.js` that was prose the operator had to
obey while dispatching implementers by hand.

The tempting test is a concurrency counter in the stub runtime. It is vacuous: the node
suite's `parallel()` runs its thunks sequentially, so a workflow that fanned implementers
out in parallel would score max-concurrency 1 and pass. The assertion that actually holds
is a source scan — the file contains no `parallel(` call at all — paired with a CONTROL
that runs the same scan against `brainstorm.js` and finds one. Without the control the
scan passes on a broken regex, which is the same vacuity one level up.

The packet took the mirror treatment. `implement.js` carries the charter's dispatch
packet as `PACKET_FIELDS`, which is the FOURTH hand-copy of that contract, and the first
one in code. `check_implement_packet` pins it in both directions (a field missing from
the list, and a field in the list the charter never defined) — but the pin that matters
most is the application one: a field can be REQUIRED by the refusal and then dropped on
the way to the prompt, which is worse than never requiring it, because the refusal
implies the field was used. That is why the check demands `PACKET_FIELDS.map(` at a real
call site and not merely two mentions of the name.

## A stage that is stored is a second place for status to be wrong (#157)

Seven stages, one command, and every transition between them was the operator remembering
to make it. The obvious fix — a small `engagement.json` the hooks keep current — is the one
this repo cannot take: `docs/UNKNOWNS.md` already reasoned that the moment status lives in
two places one of them is wrong and nothing says which, and that is the argument that put
the unknowns register in GitHub issues rather than in a markdown table. A stage file would
have re-made the same mistake one directory down, with a worse failure mode: the ledger and
the stage file disagreeing about whether an engagement is finished.

So `stage_derive` opens no file. It is a function of what `scan_pending` and
`scan_deviations` already computed, which buys three things at once — no new reader to give
a byte cap and a NUL probe, no second copy of the partition rule to drift from the gate, and
no possibility of the stage disagreeing with the hook that gated on the same numbers.

The part worth keeping in mind is the UNKNOWN input. The Stop hook has run every scan;
SessionStart runs only the pending one, because scanning DECISIONS.md there would mean a
second reader in the hook whose whole contract is "never cost the id banner". Rather than
have SessionStart guess, it passes `-` and the derivation narrows its own claim: it never
reports HANDOFF, and the CLEAR it does report says out loud that the deviation gate was not
scanned here. A stage that answered identically with and without that scan would be
asserting a fact its caller never checked — the same class as a pin that reports green
about a file it never read.

The wiring's first cut carried a `&& \` continuation followed by a comment line. `bash -n`
accepts it, the hook still ran, and no reviewer would spot it. What caught it was the
end-to-end case — run the hook, read the banner — rather than any assertion about the lib.
Unit cases over a pure function prove the function; only the integration case proves the
wiring, and the wiring is where the shapes bash silently tolerates live.

## base-gate: the operational detail (0.12.0 extraction from CLAUDE.md)

Moved out of CLAUDE.md's `base-gate.sh` coupling row when 0.12.0's rows pushed that file
past its 38000-char cap. The row keeps the couplings and the citations; this keeps the
mechanics.

- **Arm 3b** holds each CI file's `gate-suite.sh <rung>` set from the base (`CI_FILES`).
  Its git calls are CHECKED via `_ci_show`: at the base a failure is `die`, at the PR it
  is `fail`.
- **The subject is the merge result.** `merge-tree --write-tree` has EIGHT outcomes. The
  SEVEN rc-2 refusals are keyed on rc, whether stdout is a sha, and whether the tree has
  ENTRIES. Arm 4 alone keeps THREE dots (#130).
- **The job** lives in its OWN `base-gate.yml` per forge. Its checkout is PINNED to the
  base sha with `fetch-depth: 0`, and the head is only FETCHED. `check_base_gate` reads
  `_BASE_GATE_FILES`.
- **Fixture traps.** A ROOT-only fixture does not run on CI's uid (#134). A fixture that
  DELETES a git object owes every later case a fresh repo (#140).
- **Floors and registry arms (#125, moved from CLAUDE.md in #159).** Floors compare the
  LAST assignment and refuse any floors.env line that is not blank, a comment, or exactly
  `FLOOR_<name>=<digits>` — SOURCED, fail-OPEN. The registry arm refuses a second
  column-0 `CHECKS =`.
- **Arm independence (#140).** An arm must never depend on WHICH OTHER ARM dies first.

## Extracted from CLAUDE.md (#159)

CLAUDE.md sat at 37,985 of its 38,000-char cap after #158 (#159): the next coupling
row could not be added without an extraction first. CLAUDE.md is a maintainer file —
it does nothing in the installed plugin — so the cap buys headroom in every dev
session's context, not in the product. Same move as 0.11.2 and 0.11.9: each row below
keeps its coupling, its pins and its citations in CLAUDE.md; the full original cell —
nothing reworded — lives here, so the measured WHY is one grep away.

- **the `pending/<id>` type test in any CLI** — it is a **non-symlink regular file** everywhere — `ops-task.sh`'s opener, both `ops-verdict.sh` sites, the Stop hook, the statusline. `retro_gate`'s `-e` was the one outlier and it cost the audit line: a directory read as "armed", suppressing the GATE-EXCEPTION, and the row was appended before `rm -f` failed. Refuse in `ownership_gate` (ops-verdict.sh's single choke point, called at both write sites), BEFORE any write. Cases: _"non-regular entry"_ + _"refuses a non-regular entry BEFORE writing a row"_
- **the scrub tier in `ops-compress.mjs` (`scrub()`'s regex literals)** — keep the `\x1b` anchors IN BOTH regexes, written as the escape `\x1b`, never as raw ESC bytes — the 0.10.0 debloat stripped the raw bytes and the "lossless" tier silently truncated every `]`-bearing output (a 3KB test log → one char), shipped green by a suite with no `]` in any input (audit F120, P0). `check_compressor` pins both anchors; cases: the _"F120 scrub is lossless"_ block in `tests/test_compress.mjs`
- **the project-resolution walk in EITHER hook** — `ops-stop-hook.sh` AND `ops-sessionstart-hook.sh` resolve the project by the SAME bounded walk-up (`.git` stops it, `/` stops it, `cd -P`) — SessionStart exact-matched `$cwd/.operator` until audit F101: a subdir session silently lost the id banner, the legacy migration, the bin/ upgrade and the ephemera wipes while the Stop hook from the same cwd blocked. Session guidance (the banner) prescribes ABSOLUTE single-quoted CLI paths (audit F102 — the #94 shape); `templates/OPERATOR.md` stays relative on purpose (committed, machine-portable). Cases: the _"SessionStart resolves the project by WALKING UP"_ + _"banner prescribes ABSOLUTE"_ blocks
- **the protected set in `ops-claims.sh` (`PROTECTED=`)** — update `validate_plugin.check_claims` (it pins the literal AND its `matches_protected` application — F30: copy parity alone is insufficient — AND since F140 it EXECUTES the shipped matcher in a child bash, one probe per protected token plus two unprotected paths: the body pins were substring tests, and `return 1` as the first body line shipped green) and the `_"ops-claims verifies diff-matches-claims"_` cases. NOT a sentinel reader (no `check_guard_parity`/`check_reader_bounds` site — it reads git state, not `pending/`)
- **the MALFORMED bucket in `scripts/lib/partition.sh` (`scan_pending`)** — update `scripts/ops-stop-hook.sh`'s malformed message AND `statusline.sh`'s `BLOCKING` count — the bucket blocks, so a bar that omits it reads "not blocked" while Stop returns 2, which is the exact disagreement sharing this lib prevents. Cases: _"F118 (#99)"_ + _"F135"_ + _"#139"_, each red in the bash suite (7 on pre-#99 code, 2 bar pins, 4 on the `"; "` carrier, 2 with the bucket removed). #139 adds a CR arm keyed on the TASK half only; its MESSAGE is pinned too. Detail: LANDMINES (0.11.9, 0.11.14).
- **the source-state stamp in `ops-verdict.sh` (`source_stamp`, the row printf)** — update `validate_plugin.check_source_stamp` (pins the marker set, the `.operator` dirty-exclusion, the 4-cell row format, the application of `SOURCE_STAMP` — read off the row's own `printf` argument list, since `"SOURCE_STAMP" in code` was satisfied by the assignment line alone and a literal in the row's place shipped unstamped rows green — and the resolve-before-`lock_acquire` ordering) and the _"source-state stamp"_ cases. Detail: docs/LANDMINES.md (0.11.9).
- **the 4-cell row `printf`, the PASS/FAIL enum, or a stamp form (`@<sha>`, `+dirty`, `no-vcs`, `no-commit`) in `ops-verdict.sh`** — update **BOTH** parsers — `ops-reverify.sh`'s (#103) **and `scripts/lib/caps.sh`'s** (#107), which SKIPS any row it cannot split into four cells: right for a hand-edit, WRONG for a schema change — a 5-cell row is silently uncounted and the detector goes off with every gate green (measured: `tripped=0` on two real rework rounds). A new VERDICT WORD is the mirror: `caps.sh` reset only on `PASS`, so a `MOOT` row (#91) would have read as a rework — and `row_is_conformant` would have made `--reconcile` drop it. #91 landed MOOT in all three copies at once and `check_verdict_words` now holds them to one set. Cases: _"ops-reverify.sh dates rows"_ + _"the cap detector (#107)"_
- **the trailing-CR strip in ANY of the three 4-cell row parsers** — strip the whole trailing RUN, bounded (`CAPS_MAX_CR`, 16) — hand-copied in `lib/caps.sh` + `ops-reverify.sh` + `ops-verdict.sh`'s reconcile loop; the latter two source no lib. `check_cr_strip_parity` holds all three to the bound AND refuses a loop that removes without counting (F30) AND requires the loop UNCONDITIONALLY (#154: the `_cr not in code` skip excused a copy rewritten without the counter); `check_guard_parity` does NOT cover this. PAST the bound each answers differently ON PURPOSE (LANDMINES 0.11.15). Cases: the _"#139 item 1"_ block + `CrStripParityTest`. Detail: LANDMINES (0.11.15).
- **`args.isolate` / the adversarial seat's prompt in `workflows/review.js` (#23)** — keep the two branches EXCLUSIVE: un-isolated ships F-A1 (`git status --porcelain`), isolated ships F-A2 (`git rev-parse HEAD` vs the named sha) and F-A1 must NOT also ship — a fresh worktree is clean by construction, so porcelain there is a control that cannot fail. Cases: the _"adversarial isolation"_ cases (the stub runtime captures `opts.isolation`). Detail: LANDMINES (0.11.9).
- **the feasibility lens's packet in `workflows/plan.js` (`earlierProduces`, #73)** — the lens is ASKED whether a consumed dependency is produced by an EARLIER task, so it must RECEIVE those tasks' `produces` — without them 14/21 seats returned `needs-info` citing `dependency-missing`, 5 against a correct control plan. Detail: docs/LANDMINES.md (0.11.9).
- **a workflow's `args` NORMALIZER (the `typeof args === "string"` block)** — all six must keep `catch { return args; }` — returning `{}` DISCARDS the operator's text silently, and brainstorm's copy did: a 4,000-char brief evaporated and the full fan-out ran against the placeholder (measured live: 7 agents, 123,935 tokens, 86s, every seat answering "cannot propose a direction without a topic"). Cases: _"spends ZERO agents"_. Detail: docs/LANDMINES.md (0.11.9).
- **`northStar` in `workflows/plan.js` (#58)** — read WITHOUT a fallback, keep the `Missed if:` requirement, keep `${northStar}` interpolated exactly once — into decompose, never a vet packet (6/6 feasibility seats raised goal findings against the control column when it went to the packets). Load-bearing guard: the node suite's captured-prompt assertion, which covers concatenation forms a count cannot see
- **the write ORDER in `ops-verdict.sh`'s verdict path (#14)** — the GATE-EXCEPTION goes BEFORE the row, the fragment before the ledger, the sentinel clear last. Order is the whole fix for U2: row-first leaves a row with no exception, which the retry reads as an amendment and the bypass keeps its PASS while losing its audit line. Do NOT re-add the reverted guard (downgrade only when an exception exists) — an ARMED first verdict also leaves a row with no exception, and G1.7 catches the spurious firing. Case: _"G1.10"_, which asserts relative position in the source — red in that bash case, mutation-checked
- **`commands/start.md`'s steps or its `allowed-tools`** — the case asserts the tools GRANT the steps the prose prescribes (`Bash(bash:*)` for step 1, `Write` for step 2) and that `ops-init.sh` is reached through `${CLAUDE_PLUGIN_ROOT}` — a bare `scripts/` path resolves only inside this repo (the v0.2.0 bug). Both grep-guards are pinned to the tokens they actually append; the `--inline` pattern matches the heading's backticks as `.` because shellcheck reads a backtick inside single quotes as command substitution (SC2016, CI-red 0.10)
- **a dead-agent guard in `brainstorm.js` / `crawl.js` (`== null` returns)** — removing one makes the workflow THROW on the next property read rather than return, and an uncaught throw kills the node suite before its summary — the regression is caught either way, but the case that caught it becomes invisible. The dead-agent cases wrap `run()` in try/catch and convert the throw into their own failure. Keep that wrapping when adding one
- **a suite's case count (adding or deleting cases)** — raise the matching `FLOOR_*` in `tests/floors.env` in the SAME commit. It is a FLOOR (`>=`) over **passed+skipped** (#109 — executor-invariant, so it sits at the true total and the root/macOS spread is not slack); adding cases never goes red, only deletion does. Nothing raises it automatically: with no auto-merge here there is no moment that could honestly do it. The shell suite's summary carries a third group (`N skipped`) — `gate-suite.sh`'s marker regex accepts it optionally, and every skip is a per-CASE `skip()`, never a block-level echo (#109)
- **the enforcer core in `scripts/base-gate.sh` (`CORE_FILES` / `CORE_GLOBS`), or the base-gate CI job (#108)** — ONE declaration read by the arms — `is_core_path` plus the direct `for _f in $CORE_FILES` presence loop; never a second hardcoded copy. Arm 3 asks the TREE (`ls-tree` at the MERGED TREE), never the diff's status letter. Floors compare the LAST assignment and refuse any floors.env line that is not blank, a comment, or exactly `FLOOR_<name>=<digits>` — SOURCED (#125, fail-OPEN). The registry arm refuses a second column-0 `CHECKS =`. Arm 3b's git calls are CHECKED via `_ci_show`. The SUBJECT is `merge-tree --write-tree`'s tree, not the PR head (#130). An arm must never depend on WHICH OTHER ARM dies first (#140). The job runs on `pull_request_target` ONLY — the `on:` block IS the guard (#131). `check_base_gate` pins the arms comment-stripped. Arm 3b, the eight merge outcomes, the job's checkout, and the fixture traps (#134, #140): `docs/LANDMINES.md` _"base-gate: the operational detail"_. It does NOT catch a check REWRITTEN in place — #112's holdout. Cases: the _"base-gate.sh — the enforcer judged by code the PR cannot edit (#108)"_ block (each arm red in the bash suite) + `BaseGateTest`. Detail: docs/LANDMINES.md (0.11.13, 0.11.14).

### Prose cut from the map and the provenance list (#159)

- **Preamble — history already restated under ## Provenance**: design rationale behind every decision, read `docs/TAGS.md` (the in-tree spec index; the spec dir emptied in 0.11.9 — rationale now lives in `docs/` and git history). The build ledger, plans, pilot runbook/findings and prior-project evidence left the tree in 0.3.0 — see git history (tree ≤ v0.2.0) or the maintainer's local `.archive/dev/` (untracked).
- **Map: sentinel ownership — provenance (0.4.0 spec `concurrent-sessions.md`, never committed; 0.9.0 moved the stamp from body to filename)**: - **Sentinel ownership is what makes the gate concurrency-safe** (0.4.0 spec `concurrent-sessions.md`, never committed — invariants indexed in `docs/TAGS.md`; 0.9.0 moved the stamp from body to filename). The sentinel filename carries the owner
- **Map: sentinel ownership — the sibling-hook measurement**: load-bearing, not a convenience. Sibling SessionStart hooks (cc-reload's rehydrate) write `additionalContext` in the same event; the harness concatenates both and the id banner survives (live-confirmed 2026-09-04, #117 item 2) — both hooks stay append-only.
- **Map: charter CLI paths — what the v0.2.0 bug did**: repo (a v0.2.0 bug: target projects were blocked from stopping and pointed at a nonexistent command). `hooks/hooks.json`
- **Map: partition rule — introduced in 0.10**: - **The gate's partition rule lives in ONE file: `scripts/lib/partition.sh`** (0.10).
- **Map: partition rule — the CR5 measurement (whole-file scan 0.4s at 3000 lines)**: The bar's one deviation is its tail-window approximation of the deviation scan (CR5: the whole-file scan measured 0.4s at 3000 lines against a ~300ms render budget — fail toward silence, hook still gates exactly).
- **Provenance: audit handoffs — the uncommitted F01–F06 files**: - **Audit handoffs are maintainer-local and never committed**, except `docs/audit-2026-08-09-handoff.md` (F67+). The 2026-07-31 and `docs/audits/audit-2026-07-27-*` files are cited by earlier revisions as shipped but have an empty `git log --all` (F01–F06): they survive only as code, comments and CHANGELOG entries. Everything else (build ledger, plans, pilot runbook/findings, prior-project evidence) left the tree in 0.3.0 — git history (tree ≤ v0.2.0) or the maintainer's local `.archive/dev/`.

## The cap scan's cost: a quadratic split and a cache that cannot lie (#145, #127)

**#145 — `${x#* | }` is quadratic on bash 3.2.** Every 4-cell row parser split cells with a
chain of `${body%% | *}` / `${r1#* | }` expansions. On bash 3.2 (macOS's `/bin/bash`), the
`#* | ` form costs time quadratic in the length of the cell it walks past. Measured
2026-09-23: a 200 KB criterion cell took 8.0s in `${r1%% | *}` alone. A 2 MB single-row
ledger did not return in 120s. Meanwhile every bound read as satisfied: one line, one step,
and under the NUL probe's 2 MiB. bash 5.x does not show it, so Linux CI never would. The
split is now ONE `[[ =~ ]]` against `^\| ([^|]*) \| ([^|]*) \| ([^|]*) \| ([^|]*)( \|)?$`
(0.05s on the same 2 MB row). It sits in a local variable, never inline, because bash 3.1
changed how a quoted inline pattern is read. `[^|]*` is exactly the writer's cell, since
`check_cell` refuses `|`. So one behaviour moved on purpose: a hand-edited row with a bare `|`
inside a cell is now skipped, which is the side `row_is_conformant` already drew. The same
chain lived in `ops-reverify.sh` (5.0s on a 100 KB cell) and in `row_is_conformant` (5.0s,
paid while `--reconcile` holds the ledger lock). Both were rewritten, and the old and new
conformance checks agree on 20 edge-case rows.

**#127 step 1 — the budget, with its executor.** The target is ≤50ms for a cache hit on
macOS bash 3.2 (the slow executor; Linux bash 5.2 is 4-5x faster). A miss is one full scan
(~0.63s at 3000 rows), paid once per ledger change rather than per Stop. Measured: three
Stops on a 3000-row project took 3.37s before and 1.96s after the scan changes alone. Ten
cache hits on the same ledger take 0.07s in total.

**#127 — a PASS removes its key.** A reset key used to stay in the table at count 0. It then
cost every later row a comparison and held one of `CAPS_MAX_KEYS` forever, so 5000 ordinary
rows truncated. A key at 0 behaves exactly like an absent one, so removal changes the cost
and not the answer. An independent Python model and a 400-trial differential fuzz against
the pre-change lib agree.

**#127 — the cache is keyed on CONTENT, and that is the whole design.**
- **Why not mtime+size (the issue's proposal).** A FAIL→PASS flip keeps the size, and
  bash 3.2's `-nt` compares whole seconds, so that key serves a stale `tripped=1` for the
  edit that cleared it. The suite pins exactly that edit.
- **What goes into the key.** `cksum` of the ledger's first `CAPS_MAX_BYTES+1` bytes, plus
  `cksum` of the lib itself (a changed detector cannot be answered by the old one), plus
  the path.
- **When the key is taken.** BEFORE the scan: a mid-scan append then costs one extra miss
  instead of pairing new bytes with an old answer.
- **When it is not cached at all.** A ledger over `CAPS_MAX_BYTES` gets no cache entry: the
  hash would cover only a prefix, and the tail can still change the truncation reason.
- **Every failure is a MISS, never an answer.** That covers: no `cksum`/`head` (`pipefail`,
  or the empty stream hashes to a constant key), a symlinked cache dir, an entry whose rows
  block disagrees with its declared length, and an unwritable parent. Each falls through to
  `scan_caps`, whose answer is today's. A 250-step randomized sequence of appends, flips,
  CRLF, NUL, truncations and duplicates found the cached answer identical to a fresh scan at
  every step.
- **Where it lives.** `.operator/.capscache/`, ignored by the v3 allowlist and wiped by
  SessionStart beside `.autobar/` and `.stopguard/`.
