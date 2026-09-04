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

