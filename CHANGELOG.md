# Changelog

All notable changes to **cc-operator** are recorded here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/).

The version in [`.claude-plugin/plugin.json`](.claude-plugin/plugin.json) is the
single source of truth; bump it in the same commit as the changelog entry.

## [Unreleased]

## [0.9.0] - 2026-08-18

A release whose headline is that a **measurement changed what got built**. #58
asked for a north-star field, a refusal, and possibly an alignment pass over the
plan as a whole. The fixture it demanded got built first, the shipped vet lenses
were measured against it across 42 seats, and the result narrowed the work: the
field ships and the alignment lens does not, because putting the goal in the
per-task packets drew goal-reachability findings from **6 of 6** seats against
the control column — the plan that reaches its goal. That is the third time this
project has declined to build a seat on evidence (#24, #70), and the first time
the evidence redirected a feature rather than cancelling one.

Underneath that, the release's own precondition: a gate that is green on the
machine that runs it most. Four assertions were wrong: three statusline cases passing
for reasons unrelated to what they name, and one control that could not pass on
macOS at all while CI stayed green.

The measurement also produced [#73] — a defect in `plan.js` larger in blast
radius than the north star, found by accident and not yet fixed — and #66's
graph work now computes the answer that issue needs.

### Added

- **`tests/fixtures/plan-align/` — the measurement instrument for #58's
  north-star question, built before the field it would justify.** #58 makes its
  own gate explicit: a plan whose tasks are each individually sound and which
  collectively misses a stated goal, measured against the shipped vet lenses
  before any alignment pass is written. Same discipline #24 required of the
  security corpus and #70 of the drift corpus, and in both of those the
  measurement said *do not build the seat*.

  One canonical control column (`aligned.json`, six tasks that reach the goal)
  shared by three misaligned columns, each with a **different prediction** —
  `missing-final-step` (predicted MISS: the columns differ by an absence, so both
  hand a per-task lens the same four task objects and its verdicts cannot
  differ), `adjacent-deliverable` (predicted CATCH: agent-mediated recovery that
  genuinely works and violates *without contacting support*, a contradiction
  visible inside one task), `unverifiable-goal` (predicted CATCH via feasibility
  only: covers all six requirements, but no criterion ever calls `login`, so the
  goal is untested by construction). A corpus whose every fixture is predicted to
  be missed is built to justify a conclusion rather than test one.

  Neutralization differs from the other two corpora because it can: a task
  reaches a seat as inline JSON exactly as `plan.js` serializes it, so
  `misaligned.json` is a filename the dispatcher reads and the lens never does.
  `ops-corpus.sh` is deliberately not used — its map emits a flat tree (`dest` is
  a bare filename by traversal guard) while a plan fixture needs a nested project
  the feasibility lens can read, and with no derived tree there is nothing for
  #69's staleness stamp to protect.

  `tests/test_plan_align_corpus.py` pins the 2×2's load-bearing cell — every task
  in **both** columns individually feasible and testable — because a misaligned
  column containing an infeasible task would measure what `plan.js` already
  blocks and score the existing gate firing as a detection. Two columns' shared
  prefixes are byte-identical to the control by construction and pinned as such.
  Five mutations checked against the corpus and all caught: a `testCycle`
  losing its expected output, a `consumes` naming an unknown dependency, a shared
  prefix diverging, a task leaking its column name to a seat, an empty
  `produces`. Two of the five carry in-file controls that run the real check
  (the byte-identical prefix, and the column-leak scan); the other three were
  verified by mutation at the time and the suite does not re-check them. Stated
  that precisely because an earlier draft of this line said three, and because
  two of the "controls" in that file turned out to assert hardcoded literals
  against themselves — they never invoked the scan they claimed to control, so
  emptying its vocabulary left them green. Both now run the code path.

  `MEASUREMENT.md` carries the method, the scoring rule, and the predictions,
  **fixed before the run** — whether a finding counts as a detection is the
  judgment a measurement's author is worst placed to make afterwards. It shipped
  with the results section empty and marked as such; the entry below filled it.

- **`plan.js` returns a graph: real/unverified edges, concurrency layers, and the
  Amdahl ceiling ([#66]).** No new phase and no extra agent call — it is
  arithmetic over `produces`/`consumes`, which the decomposition already carries.
  A seat would be paying judgment-tier tokens to do string matching.

  The **declared** edges are consecutive pairs, because the decomposer is told to
  return tasks in dependency order and that is what it asserted; `dependsOn`
  separately scans every earlier task. The gap between the two is the point: an
  edge marked `unverified` means the plan serialised B after A while B names
  nothing A produces — spurious serialisation, which is what actually caps
  wall-clock. Measured on this repo's own corpus, the **control** plan reports
  3/5 declared edges real — and a later review caught the natural reading of that
  ("two of its orderings buy nothing") being false: both unverified edges are
  between tasks that genuinely depend on task 0, just not adjacently. An
  unverified edge now carries `dependsInsteadOn`, naming the producer it does
  depend on, because "not adjacent" and "spurious" are different findings and the
  operator acts differently on each.

  `p = 1 - L/N` over unit-cost tasks, so the ceiling is `N/L` and a pure chain
  reports `p=0, 1.0x`. Every part ships its negative control, because a
  p-estimator that always answers "wide" launders a guess as a measurement. The
  worked numbers are computed rather than asserted, which caught an error in the
  first assertion: p=0.75 at 16 workers is **3.37x**, not 16x — the serial tail is
  the cap, which is the whole reason the issue wanted the number.

  `graphWidth` is reported only alongside `dispatchBound`: `[D:CHART-r6]`
  serialises implementer tasks, so the layers describe what the **graph** permits,
  never what the operator may dispatch. Reporting width without that bound would
  read as a licence for the unsafe fan-out the charter already forbids — the
  opposite error from the worthless one this section exists to expose.

  Everything here is **report-only**; a test pins that neither an unverified edge
  nor a dangling `consumes` can reach `blocked` or `needsInfo`.

- **`northStar` is a required, falsifiable input to `plan.js` (#58) — and it goes
  to decompose only.** `args.spec` is now guarded the same way, and a review caught
  that this entry originally claimed every other input already was — while
  `spec` two lines above `northStar` kept exactly the placeholder-fallback shape
  the claim condemned. Both refuse before a single dispatch is paid for. Absent, non-string, whitespace-only, too
  short, or carrying no `Missed if:` clause are each refused with their own
  message and their own case — a goal with no miss condition cannot fail, so it
  cannot align anything, and a vague one is worse than none because it launders
  drift as alignment.

  **It is not passed to the per-task vet lenses, and that is the measured
  decision rather than an omission.** Stage A put it there and counted the
  result: 6/6 feasibility seats raised goal-reachability findings against the
  control column — the plan that reaches its goal. `check_northstar` therefore
  pins the interpolation count at exactly one, because passing the goal to the
  lenses too is the obvious-looking improvement a later maintainer makes unless
  they know it was tried. Five mutations checked: both fallback forms, a
  softened throw, a dropped miss-clause rule, and the goal reaching a second
  prompt.

  The charter's BAR block now carries the north star, which is what gives the
  Discovery discipline's five goal-relative rules a referent — #58's headline
  complaint. `templates/OPERATOR.md` is at 145/150 lines, 8949/9000 bytes.

### Changed

- **Sentinel ownership moved into the filename, deleting three parsers ([#76]).**
  `pending/<session-id>__<task-id>` when owned, `pending/<task-id>` when not.
  The body carried three fields and exactly one was load-bearing — `cwd` was
  "forensics only" by its own comment and nothing read `opened_at` — yet
  recovering that one field cost **184 lines of hand-written parser** across
  three files, each a byte-bounded reader of what the code itself called
  untrusted input.

  A filename needs no parser and no read. Gone with the body: the 512-byte read
  caps, the `LC_ALL=C` byte counting, the NUL pre-scan, and the symlink-degrade
  in each of the three readers — all of which existed to make an untrusted file
  safe to parse. `ops-stop-hook.sh` −81 lines, `ops-adopt.sh` −41,
  `statusline.sh` −35. Adoption is now `mv`: atomic by the filesystem, with no
  temp file outside `pending/` and nothing to clean up after a crash.

  **What did not move is what the change is judged on.** Three properties were
  re-established rather than assumed, and two of them I broke first:

  - *No-takeover under concurrency.* `O_EXCL` only arbitrates openers of the
    same path, and the owner is now part of the path — so two sessions opening
    one task each created their own name and both won. The concurrency loop
    caught it immediately. Fixed by claiming the **unowned** name first, which
    both racers contend for and the kernel decides, then renaming to carry the
    owner. A crash between the two steps leaves an unowned sentinel: fail-closed.
  - *F15 display sanitisation.* The hostile owner used to arrive in a body and
    was sanitised before being echoed; it now arrives in a **name**, and a
    planted `evil<ESC>]0;pwned<BEL>__t1` printed its OSC sequence straight to the
    operator's terminal until the same reject set was applied to the name.
  - *F1 grant protection.* A planted `<something>.exempt__<task>` would pose as
    the owner of a G3 grant. The reject set moved onto the name reader in all
    three files; a planted one degrades to unowned, which blocks everyone.

  Unowned still fails closed, `check_bare_name` gains one rule (`__` is refused
  in both halves, at construction) and loses four agreeing copies, and the
  SessionStart hook renames legacy body-stamped sentinels — refusing any whose
  stamp our writers could not have produced, and leaving genuinely unowned ones
  alone.

  `check_guard_parity` and `check_reader_bounds` did exactly what they were built
  for: they **reported** that their locator had nothing left to find rather than
  passing silently, which is how the deletion stayed honest. Their pins now point
  at the name reader, and three reader-bound counts drop — correct only because a
  reader was deleted rather than unbounded, a distinction the number cannot make
  and which is therefore written down beside it.

  Verified on both platforms: 719/0 bash locally and on ubuntu as non-root,
  253 unittest, 211/0 + 98/0 node, validator exit 0, and the CI-pinned linter
  (v0.10.0) clean — it caught an `ls | grep` in the new test that v0.11.0 let
  pass.


- **`produces`/`consumes` are arrays of exact names, not prose ([#66]).** This is
  the fix that ends a defect class rather than patching its next instance. While
  those fields were sentences, every rule for extracting names from them had both
  a false-positive and a false-negative class, and four review rounds each closed
  one and opened another: `The` matched as a contract name; dropping bare
  capitals lost `Mailer`; a stopword list lost `HTTPClient`; a non-string coerced
  to `"[object Object]"` and joined every task to every other. There is no
  correct way to parse a dependency graph out of model-written English, so the
  schema stopped asking anyone to.

  The schema always said "exact names". Saying it in the **type** removes the
  parsing step instead of improving it, which is the difference between a number
  measured and a number estimated.

  The prose path still exists, because a decomposer can ignore a schema — but it
  is now **recorded, not silent**. `graph.contractsInferred` names every task and
  field that arrived as prose, the log line says `ESTIMATED` when it is
  non-empty, and a test pins that a mixed plan flags exactly the guessed half.
  Keeping the fallback and hiding it would have preserved the property this
  change exists to remove.

  `check_northstar` pins both fields as `array` and the presence of
  `contractsInferred`; all three mutations are caught. Reverting either type is
  otherwise silent, since the fallback keeps working and every suite keeps
  passing.

  The `tests/fixtures/plan-align/` corpus stays prose deliberately. Stage A
  measured the **vet lenses**, which never read these fields, so the seat
  measurement is untouched — and `MEASUREMENT.md` records a content hash of the
  tree its numbers describe. Rewriting the fixtures would invalidate that hash to
  improve nothing that was measured, and the corpus now doubles as the only
  realistic exercise of the fallback.


- **Round 3: resolution was per-task where it had to be per-token ([#66]).** One
  root cause under three findings, including a **regression I introduced**. The
  `if (dependsOn[j].length) continue;` guard added to silence a false
  `outOfOrder` was per-task, so a task consuming one backward-resolved name *and*
  one forward-only name was never reported — it landed in the same layer as a
  producer it depends on, with p and the ceiling stating concurrency the
  dependency forbids. `danglingConsumes` had the identical shape: one resolved
  name hid every unresolved one in the same task. And the pair scan re-spread
  `consumes` per ordered pair — 780 allocations on a 40-task plan for work an
  index does once.

  All three are now one forward-pass token index. Fixing the shape rather than
  the three symptoms is what made the third disappear for free.

- **`danglingConsumes` is now `consumesNoTaskProduces`, because the old name
  claimed more than the data supports.** With per-token resolution the corpus
  went from 0 hits to 7 — and every one is a pre-existing project symbol
  (`hash_password`, `save_user`, `verify_password`, `locked_reason`). Correct
  plans consume existing code; that is the normal case, not a defect. This
  workflow never reads the codebase, so "no task here produces it" is the entire
  claim it can make. [#73] was told this field answers the feasibility lens's
  question "exact and free" — overstated in the direction that matters, since the
  lens has `Read`/`Grep` and can tell a missing producer from an existing
  function.

- **A north star that was only a miss clause passed every gate.** `"Missed if:
  any path still needs a support agent."` is 48 characters, clears the floor,
  matches the clause, and names no goal — while the throw beside it promises "one
  sentence naming what must be true, THEN a `Missed if:` clause". Nothing checked
  the "then".

- **The token rule's false-NEGATIVE class, which overstates the ceiling.**
  Dropping bare capitals to kill `"The"` also killed `Mailer`, `User`, and
  `POST /api/reset-password` — single-word type names and routes, two of the
  three shapes `produces` documents. A plan whose contracts are type names
  reported every edge unverified and every consume unresolved, computing p as if
  fully parallel. For a number that is #66's whole deliverable, overstating is
  the worse direction; the false positive merely understated. Now bounded by a
  small closed stopword list, pinned in both directions.

- **Two return shapes from one workflow.** The empty-decomposition early return
  omitted `northStar`, `tasks`, `vetting` and `graph`, so a caller reading
  `result.graph.layers` — or `result.northStar`, which the charter now tells the
  operator to check spec coverage against — got a `TypeError` instead of an empty
  graph.

- **The statusline silence fixture was hermetic only by luck.** `statusline.sh`
  walks *up* from `$PWD` for `.operator/`, stopping at a `.git` boundary or `/`.
  With `TMPDIR` inside a scaffolded project — `TMPDIR=$GITHUB_WORKSPACE/tmp`, a
  common CI pattern — all three "renders nothing" cases go red. Reproduced
  directly, then bounded with a `.git` marker and a control.

- **The corpus's own documentation is the answer key, and only the dispatch
  read-bound keeps a seat out of it.** `missing-final-step/NOTES.md` states in
  prose that nothing in the set writes `password_hash`; the leak scan covers
  `project/` and cannot cover docs whose job is to say that. `MEASUREMENT.md` now
  records the per-seat read-bound verbatim and a test pins that it still does —
  an instrument whose neutralization lives in the habits of whoever ran it last
  is not an instrument.

  Also fixed: `dependsInsteadOn` filtered by id string while `dependsOn` is
  index-keyed, so a duplicate id erased the real producer and restored the exact
  false "buys nothing" reading the field was added to prevent; `check_northstar`
  false-positived on the behaviour-identical `const { northStar } = A;` and now
  discloses that it has no ordering awareness at all (moving the throws below the
  dispatch keeps it green — only the agent-call counts catch that); `sed_brace`
  missed `--expression=`, `-e"…"` and indented closing braces; and the registry
  comment above `CHECKS` had been orphaned onto an unrelated function.


- **A whole-branch review found the graph's token rule fabricating dependencies
  ([#66]).** `contractNames` accepted any token carrying an uppercase letter, so
  every capitalised word an English sentence opens with — `The`, `Nothing`,
  `None` — counted as a contract name. Measured: four fully independent tasks
  whose `produces`/`consumes` read *"The w() helper"* / *"The project layout
  only"* came back as a strict four-layer chain, **p=0 instead of 0.75**,
  ceiling 1.0x instead of 4x, every edge stamped `real` on the evidence token
  `"The"`. It also silenced `danglingConsumes`, since a genuinely unresolved
  dependency matched the bogus shared token.

  The follow-up review then caught the fix's own comment overclaiming in turn: it
  said the new rule "restores the one-directional property", and it does not. Two
  independent tasks whose prose shares `reset_token` still produce a `real` edge.
  The rule removes the large spurious class and leaves a small one; the comment
  now says that, because the claim was wrong twice.

  Worse than the wrong number: the comment beside it claimed the heuristic's
  failure mode was *"one-directional — a missed match downgrades an edge to
  unverified"*. A spurious match is the other direction, and it is the one that
  makes the report wrong rather than merely incomplete. A token now qualifies on
  an underscore, a digit, an internal capital, a following `(`, a `/`, or a
  leading capital that is not a sentence-opener. The internal-capital-only form
  shipped first and a later round measured the false NEGATIVE it created —
  `Mailer`, `User`, `POST /api/reset-password`, all documented `produces` shapes,
  matched nothing, so every edge read `unverified` and the ceiling was
  OVERSTATED, the worse direction for a number that is the whole deliverable.
  Pinned in both directions now, with a negative control each way.

  The corpus numbers are unchanged by the fix, and that is the explanation for
  how it survived — every `produces` in `tests/fixtures/plan-align/` is
  `snake_case` or `camelCase`, so the corpus never exercised prose at all.

  This entry originally added that the re-run "surfaced one new true signal:
  `adjacent-deliverable` reports `outOfOrder 1`". It was not a true signal, and
  it no longer fires: that flag came from `outOfOrder` not consulting
  `dependsOn`, so a later task reusing a produced name was reported while the
  real dependency had already resolved. The guard added a round later removed it,
  correctly, and all four columns now report `outOfOrder []`. Confirmed by two
  independent derivations and a bisect. Recorded rather than deleted because a
  changelog quietly dropping a number it once published is the same failure as
  publishing the wrong one.

- **`check_northstar`'s docstring claimed to close a hole it shares.** It argued
  that counting `${northStar}` interpolations beats scanning the vet literals
  because a variable could evade the latter — but `+ "…" + northStar` appended to
  a vet prompt keeps the count at 1 and the check green, and `+`-concatenated
  template literals are how both vet prompts are actually built. Verified by
  mutation: the concatenated form is caught by the node assertion over the
  captured prompts and **not** by the validator. The docstring and the `CLAUDE.md`
  coupling row now say which guard is load-bearing; a checker whose docstring
  overclaims is worse than none, because the next maintainer stops looking.

- **Two test-hygiene defects.** `_scan_for_leaks` called `read_text(encoding=
  "utf-8")` on every file it walked, so a stray `.pyc` — which anyone importing
  the fixture package creates — killed the leak test with a `UnicodeDecodeError`
  instead of returning a verdict: an exemption granted by crash, in the scan
  whose whole claim is that nothing is exempt. And `SLBARE`/`SLFB` were never
  removed, leaking two directories per run into `$TMPDIR`, one carrying a
  scaffolded `.operator/` with a pending sentinel — one run's litter becoming the
  next run's ambient state, which is what those very cases were rewritten to
  escape.


- **#58 Stage A ran: 42 seats, and the answer is narrower than either option the
  issue proposed.** The measurement is in
  `tests/fixtures/plan-align/MEASUREMENT.md` with predictions left exactly as
  they were fixed beforehand. Two held, one did not.

  **Putting the goal in the packet does not let per-task lenses discriminate.**
  The control column — a plan that reaches the goal — drew goal-reachability
  concerns from **6 of 6** feasibility seats, including *"a locked-out account
  completes every shipped step and still cannot sign in — the north-star miss
  condition verbatim"* against a task whose sibling two entries later clears
  exactly that lockout. The seat cannot see the sibling. Goal-talk at 100% on the
  good plan is noise, not detection.

  What did discriminate was narrower: naming the *clause* a plan violates
  (`adjacent-deliverable`, 4/5 vs control 0/6), and naming a criterion as a
  *proxy* for the goal (`unverifiable-goal`, caught by the cheap testability seat
  predicted to be blind to it, against a clean control counterpart). Both are
  visible inside a single task. `missing-final-step` — the one shape that truly
  needs a view of the set — was missed exactly as predicted, and no per-task lens
  can catch it.

  So: **ship the field, do not ship a per-task alignment lens.** For the absence
  shape the cheapest instrument is not a lens at all but a spec-coverage check
  asking which requirements no task claims — arithmetic over `specExcerpt`,
  belonging with #66's edge work.

- **The run found a defect in `plan.js` that #58 did not ask about.** 14 of 21
  feasibility seats returned `needs-info` citing `dependency-missing`, in every
  column including the control. The shipped prompt asks *"Is the dependency it
  consumes actually produced by an earlier task?"* while handing the seat exactly
  one task and never its siblings — it cannot answer, and `plan.js` buckets
  `needs-info` into `needsInfo`. On the CONTROL column — a well-formed plan — that
  was five of six tasks landing in the bucket the operator is told to clear before
  dispatch.
  Filed separately; it is larger in blast radius than the north star.

- **The corpus shipped two leaks and a defect, all found by running it.** Three
  of the fixture project's docstrings said "fixture", and `project/README.md`
  stated the discriminating property outright — *"A plan that never writes that
  field cannot produce a user who signs in"* — which is `missing-final-step`'s
  answer, written down in the tree a lens reads. The pins checked the task JSON
  and never the codebase beside it. Now pinned by a scan over EVERY file under
  `project/` — a first fix scanned only `*.py` and excused the README on the
  promise that a dispatch excludes it, which a review pointed out was pinned by
  nothing; the README is now ordinary project documentation instead. Separately a seat caught
  `admin-temp-password` asserting a 12-character result from
  `secrets.token_urlsafe`, which returns 16 for that argument — a true positive
  against the fixture, the same shape #70's control column produced. Fixed after
  the run; `MEASUREMENT.md` records the pre-fix corpus hash, because comparing
  later numbers to that table without it is the error #69 exists to prevent.

### Fixed

- **A control assertion that could not pass, and a CI runner that could not see
  it.** `tests/test-scripts.sh`'s holder-read control extracted
  `lock_holder_read` with `sed -n "/^f() {$/,/^}$/p"` inside `"$( … )"`. Under
  bash 3.2 — still `/bin/bash` on every macOS — the nested quoting does not
  survive the parse, `{$/,/^}` brace-expands, sed gets a split script (`invalid
  command code $`), the function is never defined, and the assertion fails every
  run. ubuntu's bash 5 parses it correctly, so CI was green on `main` for the
  whole time the local suite was red — measured **708 passed / 1 failed** on
  darwin at `d9eef21` against five consecutive green CI runs.

  It was the *control*: the assertion whose only job is to prove the guard beside
  it was exercised. #21's class with the polarity inverted, and the inverted form
  hides better, because a red local run reads as flakiness while a green CI run
  reads as truth.

  The probe now reports the record on its own stdout, so the control attests to
  **the same run** whose stderr the first assertion reads — previously the two
  re-extracted the function separately and could exercise different code.
  `check_platform_idioms` bans the shape statically, which is the only way this
  ban reaches CI at all: a bash-5 runner cannot reproduce the bug it is meant to
  catch. Mutation-checked in both directions, with controls that a single-quoted
  script and a brace-free double-quoted script both stay accepted.

- **Three statusline assertions were measuring the maintainer's desk.** They
  claimed *"degenerate stdin renders nothing"* while running with cwd = this
  repository. An unparseable payload leaves no cwd to read, so
  `statusline.sh:84` falls back to `$PWD` — an explicit
  `${CLAUDE_PROJECT_DIR:-$PWD}` default, so intended, though the file gives no
  rationale for it (`:49-50` documents the preference *order*, payload first,
  which is a different claim); the repo had simply never had
  `.operator/` scaffolded in it, so the fallback found no ledger and all three
  passed for a reason unrelated to what they name.

  Found by dogfooding: opening one real task in the plugin's own tree turned all
  three red at once, with the renderer behaving exactly as designed. The gate
  could not be run in its own repo without tripping its own suite. They now run
  from a temp dir with no `.operator/` at or above it, plus **a positive control**
  pinning the fallback from a cwd that does have a pending sentinel — without it,
  deleting the `$PWD` fallback outright would leave all three green.

  The suite's assertion count is now invariant to ambient state (711/0 with and
  without a sentinel in the repo root); at `d9eef21` it varied, 709 vs 710.

- **`ops-corpus.sh`'s containment guard failed OPEN wherever git was absent**
  (`a402ff8`). `repo_toplevel()` returned git's answer *or nothing*, so
  without git the caller's `if [ -n "$toplevel" ]` containment check silently
  **vanished** — measured in a bare ubuntu container, the derived corpus was
  written straight into the repo worktree (5 files, no refusal). It now fails
  CLOSED: the toplevel falls back to the plugin root resolved via
  `script_dir/..`, and the containment check always runs. The same
  CI-platform verification pass (`scripts/ci-local.sh`, pinned shellcheck
  0.10.0 = CI's) caught two portability defects with it: `import.meta.dirname`
  requires node ≥ 20.11 while ubuntu ships 18.19 — both `.mjs` suites crashed
  on every run (now `fileURLToPath`, no version floor) — and four test cases
  leaned on chmod behavior root ignores (now announced skips, the existing
  holder idiom).

- **Eight environment edge cases, two suite defects under them** (`471179f`).
  The suite now runs clean as non-root ubuntu (CI's actual configuration),
  on a path containing a space, with no git at all (`@no-vcs` source stamp),
  under `LC_ALL=C` ANSI_X3.4-1968, on node 18/20/22/24, and python 3.9–3.11;
  the Stop hook's python3 fallback and the compressor's world-writable-`/tmp`
  hardening were attacked directly and held. Found by running it: two cases
  **errored** on a missing git instead of skipping (a suite that dies on a raw
  traceback reports nothing), and `test_compress` lstat'ed a path a hostile
  root placement leaves nonexistent — same class, same fix.

[#66]: https://github.com/betmoar/cc-operator-plugin/issues/66
[#73]: https://github.com/betmoar/cc-operator-plugin/issues/73
[#76]: https://github.com/betmoar/cc-operator-plugin/issues/76

---

Older releases (0.1.0 – 0.8.4) live in [docs/CHANGELOG-archive.md](docs/CHANGELOG-archive.md).
