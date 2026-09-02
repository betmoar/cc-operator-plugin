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
