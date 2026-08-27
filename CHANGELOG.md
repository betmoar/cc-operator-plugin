# Changelog

All notable changes to **cc-operator** are recorded here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/).

The version in [`.claude-plugin/plugin.json`](.claude-plugin/plugin.json) is the
single source of truth; bump it in the same commit as the changelog entry.

## [Unreleased]

## [0.11.2] - 2026-08-27

The deviation gate cost more than it bought, and four of the five defects were
one defect: the gate could not tell whose decision it was blocking on.

### Fixed

- **The deviation gate no longer inherits other sessions' presented decisions
  (#90).** Clearing is now asymmetric: a MINE row clears only on a mine/unowned
  mark, an UNOWNED row clears on any later mark, foreign included. Nothing
  writes the `[sid:]` tag onto a DEVIATION — the operator hand-writes those
  rows — so untagged is the NORMAL shape, not a pre-0.4 artifact, and under the
  old "foreign clears nothing" rule every untagged decision blocked every future
  session forever: the session that wrote it marked under its own sid, foreign
  to everyone after. Measured against two real ledgers as a fresh session before
  the fix: strike-zero 6 unpresented, gtrw 2 — all long presented. Both are 0
  now. What still blocks is the case the gate exists for: an untagged row with
  no later mark at all. `statusline.sh` mirrors the rule on its backward walk.
- **The block message names the rows it counted, absolutely (#93, #94).** The
  hook asked the operator to present N decisions while withholding which, so the
  cheapest correct response was to run `--mark-handoff` without reading — the
  habit the gate exists to prevent; identifying the rows meant reverse-reading
  `partition.sh`. `scan_deviations` already parsed them and threw them away. It
  now returns them, and the hook prints up to 10 (truncated at 110 chars, with a
  count of what it withheld — stderr is fed back to the model as guidance, and a
  100-row dump buries the instruction). Both prescribed paths are absolute: the
  Bash tool's cwd persists across calls, and a session sitting in a subdirectory
  followed the old relative path, got "No such file or directory" from both the
  CLI and a `find .` for the ledger, and concluded the charter was never
  realized in the repo — a present gate misdiagnosed as absent.
- **`--owner` refuses an unexpanded shell variable (#89).** A quoted heredoc
  passed the literal two characters `$S`; `check_owner_name` accepted it, and
  `[sid:$S]` took every reader's FOREIGN arm, so the mark cleared nothing while
  the tool reported success. Strictly worse than not running the command, and
  invisible until the next Stop blocked again. All three CLIs now refuse `$`,
  backtick, quote and backslash in an owner, naming the cause.
- **`brainstorm` and `plan` no longer discard a non-JSON `args` string (#92).**
  Both normalizers returned `{}` from the catch, so a prose brief evaporated and
  the run proceeded against the placeholder: measured live at 7 agents, 123,935
  tokens, 86 seconds, every seat answering "cannot propose a direction without a
  topic". The catch now returns the string, as the other four workflows always
  did, and a bare string is read as the required argument the way `review.js`
  reads its target. An absent topic/spec throws before phase 1 — a refusal that
  spends zero agents rather than a better message after the same cost.

### Fixed (second pass — PR #88 review)

Four holes the first pass left, all in the fixes above rather than beside them.

- **The #89 guard belonged on the READERS too, not just the three writers.** A
  pre-0.9 sentinel carries its owner in the BODY, so `ops-sessionstart-hook.sh`'s
  migration renamed `session_id: $S` to `$S__planted` — and both
  `sentinel_owner_of_name` copies read that as a valid FOREIGN owner. Measured:
  Stop returned rc 0 on a real open task, reporting `planted owned by $S`. The
  silent disarm the branch exists to prevent, reached by the one path a writer
  guard cannot see. The arm now sits at all six sites; writers refuse, readers
  degrade to unowned (fails CLOSED), the migration refuses. The two halves are
  mutation-checked separately — neither covers for the other.
- **The absolute path is now shell-quoted.** Absolute means long enough to
  contain a space: `/work/my repo/.operator/bin/ops-verdict.sh` pasted bare runs
  `/work/my`, so the cwd fix would have traded one uncopyable command for
  another.
- **Ledger rows are sanitized before they reach stderr.** The rows are
  hand-editable project data printed into the channel that carries this hook's
  own instruction — a CR alone repaints the `--mark-handoff` line it is attached
  to. C0 bytes and DEL become `?`, before measuring, so the 110-char cap stays
  honest and cannot truncate mid-escape.
- **`crawl`'s `question` gets the same fail-fast as `brainstorm`/`plan`.** Its
  absent-*shards* branch returns before dispatching, which is what made it look
  covered; an absent *question* with valid shards paid every crawler seat and the
  merge to answer a placeholder.

### Notes

Every fix carries its mutation: twelve were run across both passes, each red
against the case written for it, each restored byte-identical. Suites: 726 bash
(was 689), 354 node (was 340), 90 compress, 222 python, validator green,
shellcheck clean under the pinned 0.10.0.

## [0.11.1] - 2026-08-25

Three open issues, and the guard auditor's second run — four validator pins
that reported green against the exact defect they were written to catch.

### Fixed

- **#73 — the feasibility lens now receives the input its own question needs.**
  `plan.js` asks each vet seat "is the dependency it consumes actually produced
  by an earlier task?" and dispatched it with one task and no siblings. 14 of 21
  seats returned `needs-info` citing `dependency-missing`, five of them against a
  control column whose plan is correct. Each packet now carries the earlier
  tasks' `produces` as `id: names`, strictly earlier, with the empty case saying
  "none — this is the first task" in words: an absent section reads as withheld
  information and returns `needs-info` again.
- **#82 — SessionStart no longer stamps a partial upgrade as complete.** A
  manifest-named CLI with no shipped file was skipped without clearing
  `_upgrade_ok`, so `.version` recorded a finished upgrade over a partial
  `bin/`; `_bin_stale` carried the same skip, so the only retry trigger never
  fired. Measured: 2 of 3 copied, stamped current, no warning, never retried.
  Both halves now treat an absent source as a failed upgrade. Still fail-open —
  the shipped CLIs land and the skip is announced.
- **#74 — `args.isolate` never reached the commit it named.** The runtime's
  `isolation: "worktree"` takes no commit, so the worktree is created at the
  default branch; two dispatches requesting different shas both landed nine
  commits earlier. The default is now honest (clean environment, NOT commit
  identity, and the seat is told a HEAD mismatch is expected rather than
  refutable), the result carries `atRequestedCommit`, and
  `args.isolateCheckout: true` opts into a real `git checkout --detach` at the
  cost of a worktree left on disk.

### Changed

- **The guard auditor's second run: four vacuous validator pins and one blind
  spot, all closed.** 84 mutations across 25 checks. `check_reader_bounds`
  counted occurrences and never read N (a 256MB "bound" passed), never asked
  where the text was (a string literal satisfied it), and exempted
  `read -r -d $'\n'` as if it were the stdin slurp. `check_lock_parity`
  compared two copies and pinned no content, so inflating the holder read in
  BOTH left them in parity — F30 inside the check whose docstring teaches F30.
  `check_hook` accepted `true # ` in front of the command (the evidence gate off
  in three characters) and read only entry [0] of the hooks array.
  `check_compressor` missed `ELIDABLE.add("Read")` after the literal and an
  emptied wipe loop whose directory names survived in a comment.
  `check_release_gates_cover_validate` had never looked at `.forgejo/`, the job
  that publishes on this LAN, and accepted a commented-out or `if: false` step.
  `check_permission_guards` missed `test -w` and all of `scripts/lib/`.
- **The review of that audit found six more, and they are the same shapes.**
  `check_hook` read matcher group `[0]` and counted only the inner list, so a
  second matcher group registered an unreviewed hook — index-zero blindness
  inside the fix written against index-zero blindness; it also never checked the
  entry's `type`, and a non-string command raised rather than reporting. The
  lock content pin searched the RAW block, so commenting out the real
  `while ! mkdir` and leaving the text in a comment satisfied it in both copies.
  The compressor's reachability anchor caught only the one-line `if (false) if
  (…)`; a multiline `if (false) { … }` walked past, and `GATE_CLIS.length = 0`
  was not a method call. `live()` grouped steps, so a job-level `if: false`
  disabled a whole publishing job invisibly. And every byte cap was only a byte
  cap in the C locale — bash counts CHARACTERS outside it, so `ops-verdict.sh`'s
  and `ops-adopt.sh`'s reads were up to 4x looser than they read on multibyte
  input (measured: 512 chars of `é` = 1024 bytes). All six fixed, each with the
  mutation that proves it; reachability is now brace depth against a named
  anchor, which a substring cannot approximate.
- **`args.isolate` could REFUTE a correct tree.** `git rev-parse HEAD` prints a
  full lowercase sha and the guard accepts 7–40 hex, so `isolate=abc1234` was
  compared against 40 characters and failed — a false REFUTED on the one verdict
  that cannot be outvoted. The seat is now told to compare by prefix when the
  caller abbreviated, and case-insensitively.
- **`atRequestedCommit` was the caller's own flag echoed back.** A failed
  checkout, or a seat that ignored the instruction, still returned `true`: the
  workflow asserting an identity nothing observed — the overclaim `#74` fixed,
  one field over. It is now derived from the seat's `OBSERVED_HEAD:` line, with
  three distinct states (`true` / `false` / `null` for nothing observed), and
  `observedCommit` records what came back.
- **The `OBSERVED_HEAD` parse accepted a partial read as a measurement.** It
  matched 7–40 hex ANYWHERE in the evidence, so a seat writing the sha in prose
  produced a 7-char "observation" that then failed the full-sha comparison —
  reported as `atRequestedCommit: false`, a FALSE MISMATCH on a correct
  checkout. Same class as the false REFUTED above: `null` is honest, `false` is
  a claim. Now anchored to its own line and a full 40-char sha; anything else is
  "nothing observed".
- **The `#73` truncation notice counted the wrong thing and cut mid-line.** It
  reported `acc.length` — every earlier task, not the number omitted — so a list
  of 65 producers carried "119 of 119 did not fit", and the cut could leave half
  a producer name that reads as a real one. Both point the same way: the section
  exists to stop the lens inventing missing producers, and a wrong count invents
  them back. Now line-boundary truncation with a `dropped of total` count that
  the tests assert sums.
- **The `#73` dependency section is capped at 4000 chars and truncates
  visibly.** It renders every earlier task into every later packet — O(T²) in
  prompt bytes, with the comment claiming "bounded" and nothing enforcing it. A
  silent cut would teach the lens that a real producer does not exist, so the
  notice says what not to conclude from an absent name.

## [0.11.0] - 2026-08-24

The release where the evidence gate stops being optional, and where the thing
that found its bugs is the thing this release ships.

0.10.0 left a hole documented rather than closed: `ops-task.sh` opened a
sentinel and the Stop hook blocked while one was pending, but **nothing opened
one**. A session that never ran the CLI stopped clean however many files it
rewrote. The charter REQUIRES a BAR block for multi-file work, and a rule the
mechanism declines to enforce is prose.

It is closed now, and the route there is the release's other half. A debate
panel — three flagship models arguing blind over three rounds — reviewed the
commit that closed it and found a defect that would have made the gate silently
never fire again. Two more defects from Friday's audit (#81, #83) turned out to
sit on the same code this change touches, so they land here too.

### Added

- **Auto-arm: the evidence gate is no longer opt-in (#85).** At Stop, a working
  tree delta naming **>=2 changed project paths** (the charter's ENGAGEMENT
  CONTRACT clause 1, a *count*, never the done-state clause) arms an ordinary
  owned sentinel `pending/<sid>__autobar`. The existing mine-pending branch then
  blocks on it with the message it already ships: no new blocking stage, no new
  message class, no new polarity for a `partition.sh` reader.

  It measures the FILESYSTEM, not the tool stream, and that is the whole design
  decision. The property is "files changed", not "Write/Edit was called". A
  PostToolUse counter is blind to `sed -i`, heredocs, `patch`, build scripts and
  every subagent write, and its undercount is **silent** — it reports zero,
  byte-identical to a session that changed nothing. That is not a smaller hole
  than the one being closed; it is the same hole behind a counter that reports
  green.

  Bounds, stated rather than papered over: git-only (no VCS arms nothing, as the
  source stamp already degrades to `@no-vcs`); clauses (2) multi-session and (3)
  user-named done-state stay **uncovered**, because both mean classifying intent
  and that is a false-positive factory on a hook that blocks; and a session can
  still satisfy the gate by opening one throwaway task and deferring it. An
  honesty rail against forgetting, not a sandbox against a hostile agent.

- **A debate workflow and the `op-debater` seat.** N flagship models argue one
  case over three rounds — openings independently, rebuttals against each
  other's positions **unlabelled**, closings standing alone — then a neutral
  fourth pass aligns the closings into agreed / contested / falseSplit /
  decisions. `chose` is always `null` and present rather than omitted, so the
  contract reads at the call site: paying N models to disagree and then letting
  the workflow decide makes the other seats decoration.

  Three invariants, each mutation-checked. Seats argue **blind** — no model id
  reaches any debater prompt, because a rival's brand invites deference over
  argument and a seat that can identify itself softens its own critique. No seat
  receives its own position as a rival's, or self-agreement registers as
  convergence. And `args.models` has **no fallback**: a tier default would seat
  one model against itself and return a panel that could not have disagreed.

- **A gate for `SKILL.md` (#80).** The one shipped file with none. A plugin
  rename shipped green with a dead `/cc-operator:` reference in the front door;
  five cases now pin the frontmatter name, the description, every slash-command
  reference resolving to a command that exists, and the charter-is-authority
  disclaimer.

### Fixed

- **A stale artifact could disarm the auto-armer permanently.** Suppression
  first stood down on any foreign `verdicts.d/<sid>.md` fragment — append-only,
  never wiped, so **one verdict recorded by any other session, ever**, silenced
  the armer for the rest of the project's life, hardest in the mature projects
  the gate most protects. Removing that left the same shape one layer down: an
  abandoned `pending/<dead-sid>__<task>` from a crash, a kill, or a `/clear`
  mid-task, which nothing reaps. Reachable in a single-operator project, since
  `/clear` with an open task is routine.

  Foreign-presence suppression is therefore **gone entirely**, and no third rule
  is possible here. Splitting "working" from "died" needs a liveness oracle the
  filesystem does not carry: a sentinel holds `cwd:` and `opened_at:` and no
  pid, and a pid would not help — `ops-task.sh` is a subprocess that exits when
  the CLI returns, so its `$$` is dead while the owning session runs, and
  `kill -0` would read every sentinel, live ones included, as abandoned.
  `kill -0` answers for the **lock** because a holder's lifetime is bounded by
  the call that stamps it (F03); a sentinel exists to *outlive* its writer. A
  session is a harness token, not an OS handle. An mtime clock fails on bash
  3.2's whole-second granularity — measured: a fragment written 47ms after the
  epoch read as "not newer".

  The trade is priced both ways. Arming wrongly costs ONE arm on the session's
  own sentinel, capped once per session, carried on the **blocking** channel and
  cleared by one command. Suppressing wrongly cost the gate permanently, on a
  channel that only ever printed exit-0 warnings — the suppression reason was
  computed and **discarded**, its only reader inside the arm branch. Found by a
  debate panel reviewing the commit that introduced it.

- **The validator pinned the first assignment; bash resolves the last (#81).**
  One appended line disarmed a guard with the build green: `PROTECTED` in
  `ops-claims.sh` (the guard on the validator, tests, `.operator/bin/` and
  hooks), `_OPS_TOOLS` in the install manifest (installing 1 of 5 CLIs), and
  `TIER_NAMES`. All three now report a duplicate instead of pinning a dead line.
  The same class exists one level up and was measured here: `_function_body()`
  returned the FIRST definition of a re-defined shell function while bash used
  the LAST, so appending a second `autobar_count_changed` disabled the NUL read,
  the repo check and the `-z` flag with `all contracts hold`. A re-defined
  function now yields an empty body, which fails every pin.

- **`partition.sh` documented a polarity it does not have (#83).** The header
  said an *unreadable* `DECISIONS.md` failed OPEN; only *absent* and *symlink*
  do. An unreadable file takes the NUL-probe path and fails CLOSED — which is
  the correct behaviour, since the file exists and an unpresented decision may
  be in it, but the opposite of what the comment promised, in the paragraph you
  read before touching this polarity. All four states are now documented and
  pinned by a case; nothing tested `unreadable` before. `scan_deviations` also
  declares `LC_ALL` local instead of leaking C collation to its caller.

- **A CI gate that could not pass.** The #80 skill gate failed shellcheck
  0.10.0 on SC2013 in its own loop — present from the day it shipped and
  invisible locally, since no local run reaches the pinned container. Found by
  running `.github/workflows/validate.yml` with `act`. The obvious fix had a
  trap: a pipeline's `while` body is a subshell, so the flag set inside is lost
  and the gate would pass everything while the suite stayed green.

- **`verdict_cmd_for` was called twelve lines above its definition.** Bash
  resolves a function at call time, so the new Stop-hook message shipped a blank
  command — no error, just useless guidance.

### Fixed after review

A four-lens review of this release found five defects in its own new code. Each
is fixed here with the mutation that proves the fix, because four of the five
shipped with every gate green.

- **The auto-arm counted a new DIRECTORY as one path.** Porcelain's default
  untracked mode collapses `src/feature/{one,two,three}.js` to a single
  `?? src/`, so the count came back 1, below the threshold, and the gate stayed
  silent on exactly the multi-file session clause (1) exists to catch. The same
  three files at the repo root armed correctly — that contrast is the measurement.
  New work lands in new directories, so this was the common shape of the thing
  being gated, not an edge case. `-uall` now lists each file.

- **A failed sentinel write left the session permanently unarmed.** The marker
  is written first (deliberately — see #85), but the sentinel write carried
  `|| true`. Marker present, sentinel absent: `autobar_already_armed` then reads
  the session as armed for the rest of its life, so the gate never fires again —
  RC 0, empty stderr. Measured with `.operator/pending` replaced by a plain
  file, and it survived REPAIRING the directory, which is what made it permanent
  rather than transient. The write's status is now checked and a failure rolls
  the marker back, so the next Stop retries.

- **The sentinel writer followed a planted symlink.** `[ ! -e ]` is true for a
  dangling link, so `>` created its target outside `.operator/` (measured).
  `set -C` (O_EXCL) now applies, the same discipline `ops-task.sh`'s opener uses
  and for the same two reasons; a pre-existing regular file still reads as this
  session's own earlier arm, not a failure.

- **`check_no_redefinitions` was promised and never existed.** `_function_body`
  computed the diagnostic (`.fn`, `.n`) and discarded it — this repo's own
  computed-then-discarded shape. A duplicated function produced THREE confident,
  false problems ("does not pass `-z`", "does not use process substitution",
  "no rev-parse check"), every one of those properties present in the live
  definition, while the real defect went unnamed. `_report_if_redefined` now
  names it at all three call sites, matching what `_single_assignment` has done
  for variables since #81.

- **The "hook sources autobar.sh" pin matched a mention.** Replacing the source
  line with `echo 'autobar.sh disabled'` left the filename in the file, so the
  validator reported 0 problems — while at runtime `set -u` aborts the hook on
  `autobar_arm`, and exit 1 is not exit 2, so Stop is ALLOWED and the deviation
  gate never runs either. The pin now matches a source STATEMENT.

- **The stale `sentinel_owner_of_name` justification is gone.** `e839490`
  deleted the call; `grep -c` in `autobar.sh` is 0. Four places still cited it
  as a live reason — including a validator's own failure message, which told a
  maintainer a mechanism that does not exist. The sourcing order is still
  pinned, for the reason that is actually true: `autobar_decide` runs before
  `scan_pending`, so an armed sentinel is read by the existing mine-pending
  branch in the same fire.

- **`scripts/lib/` was never linted.** All three CI paths globbed
  `scripts/*.sh`, which does not match `scripts/lib/`, so `autobar.sh` shipped
  unchecked. Clean under the pinned 0.10.0 once included — but that was luck,
  not a gate.

Two test gaps closed, each proven by re-running the mutation that survived
before: the mark-before-arm ordering could be reverted with 669 bash + 189
python + the validator all green, and `debate.js`'s closing round could be
pushed below its threshold check with 276 node green (two of three
structurally-identical dead-seat branches were covered; the third was not).

### Verified

`act push -W .github/workflows/validate.yml` → Job succeeded: shellcheck 0.10.0
over `scripts/*.sh scripts/lib/*.sh tests/test-scripts.sh`, contracts hold, 193
python, 675 bash, 282 + 90 node.

Counts measured on both executors rather than inferred: **683 local**
(macOS/bash 3.2.57), **675 in-container** (ubuntu 24.04/bash 5.2.21, 8 cases
self-skip as root). A previous revision of this section claimed 662 local / 655
in-container; neither number is produced by any run, and the discrepancy is
itself the kind of unverifiable claim the EVIDENCE GATE exists to refuse.

Live, which is the part the bash suite cannot reach: **the branch's own session
was auto-armed by its own hook at Stop** — 2 changed paths, sentinel on the real
session id, `.operator/` excluded from the count, closed with a PASS row through
`ops-verdict.sh`.

## [0.10.0] - 2026-08-22

The release that stops defending the codebase against its own development
process. Measured at the start of the branch: **11,371 shipped lines**, of which
the product a user touches — charter, gate, workflows, tiers — is about 3,000.
The rest was armor, accreted one review at a time: every finding became a
permanent guard *plus* a war-story comment *plus* a coupling-table row *plus* a
parity check, and nothing was ever deleted on the grounds that a design change
had made the bug impossible.

The shipped tree is now **7,852 lines**. Nothing a user relies on was removed —
the deletions are guards whose bug became unreachable, comparators whose
duplication was collapsed, and validator checks that policed process rather than
product. The model for all of it is 0.9.0's filename-ownership refactor, which
deleted 184 parser lines by making the parse unnecessary: **change the design so
the guard has nothing to guard, then delete the guard.**

Two things arrived alongside the diet and matter more than the line count. #76's
duplication work removed three responsibilities that had required copies, so
three parity mechanisms had nothing left to compare. And the replay charter was
executed live for the fourth time, which found a stale expectation in the
charter itself and four shipped surfaces with no test that could fail.

### Changed

- **The `.operator/bin` install set has ONE declaration.** `scripts/ops-install-set.sh`
  is the manifest both writers source; the four hand-copies are gone. The polarity
  split between the writers is deliberate and both halves are verified end to end:
  `ops-init.sh` fails **loud** without the manifest (rc 1, zero installs — it is
  the interactive path, so a failure is visible), while `ops-sessionstart-hook.sh`
  fails **open** (skips the upgrade, warns, keeps the old stamp). The second is not
  laziness: an empty set must never record an upgrade that copied nothing.
  `check_install_set_parity` now pins the single-source shape instead of comparing
  two literals, with 7 mutation cases against the real writers.

- **The mine/foreign partition lives in `scripts/lib/partition.sh`.** The Stop hook
  (the gate) and `statusline.sh` (the bar) source the same implementation, because a
  bar describing a different gate than the one that runs is worse than no bar.
  `statusline.sh` 450 → 237, `ops-stop-hook.sh` 364 → 171. The bar keeps its one
  documented deviation: a tail-window approximation of the deviation scan, since the
  whole-file scan measured 0.4s at 3,000 lines against a ~300ms render budget (CR5).
  It fails toward silence; the hook still gates exactly. The `.operator/bin/` CLIs
  deliberately do NOT source the lib — they install standalone, and their hand-copies
  stay pinned by `check_guard_parity`.

- **Workflows carry no facts about the resolver.** `DEFAULT_TIERS` are harness
  aliases (`opus`/`haiku`) the harness resolves rather than vendor model ids, and
  `KNOWN_TIERS` — a five-times-copied catalogue of the resolver's own tier names —
  is deleted. An unknown `args.tiers` key is accepted and logged, never thrown, so
  F07's resolver-map forwarding survives with nothing left to synchronize.
  `check_workflow_default_tiers` pins the alias set, because the reflex fix when a
  default routes badly is pasting a vendor id back in, one file at a time.

- **The compressor's ephemera live only under an existing `.operator/`.** The
  cwd-keyed tempdir fallback is gone: no `.operator/` now means no spill, no dedup
  state, and the elide is marked "not spilled" rather than written somewhere the
  user never asked for. `ops-compress.mjs` 470 → 358.

- **`unused` tier keys can no longer fail a run.** An unknown `args.tiers` key was
  logged as "accepted, unused" and then spread into `TIERS` and value-validated, so
  a malformed value on a tier the workflow never dispatches threw anyway. All five
  workflows now filter overrides to the dispatched set. (Copilot review, PR #78.)

### Removed

- **The arm gate (G2/G3) and its exemption mechanism**, per the maintainer decision
  recorded on `docs/spec/backlog-charter.md`. G1, the retro-gate, remains and is
  still what catches a verdict recorded with no sentinel open. `ops-armgate-hook.sh`
  deleted; the sections in the backlog charter are kept as tombstones.

- **The measurement corpora and `ops-corpus.sh`** (#24 security, #70 drift, #58
  plan-align). Each had already produced its answer — twice "do not build the seat",
  once "ship the field, not the lens" — and a corpus that has answered its question
  is history, not shipping code. They live in the git history (tree ≤ 0.9.0).

- **Four validator checks: `check_issue_refs`, `check_replay_charter`,
  `check_northstar`, `check_platform_idioms`.** Markdown link lint and runbook prose
  are not shipping concerns, and a runbook is validated by running it — which this
  release did. `validate_plugin.py` 2,882 → 1,773 lines. The plan-graph rules
  `check_northstar` policed are now covered by the node suite, where they belong.

- **`docs/img/` and `docs/INFOGRAPHICS.md`** (5.5MB of rendered diagrams), and the
  pre-0.9 CHANGELOG entries, split to `docs/CHANGELOG-archive.md`.

- **1,295 comment-only lines** across the six gate CLIs and 1,414 across the two test
  suites, each proven comment-only by byte-comparing the stripped code.

### Fixed

- **The replay charter quoted an expectation the hook has not met since 0.9.0.**
  R2b said the foreign-sentinel report names "the task, its owner and its open
  time". `git log -S` places the drop at #76 step 1: ownership moved from the
  sentinel BODY to the FILENAME, so the readers stopped opening the body at all —
  which is what makes them builtin-only and what closed the `session_id: EVIL`
  smuggling class. The open time went with the read. The hook is right; the prose
  was stale, and it survived a release because nobody ran the phase.

- **`README.md` promised a compressor tempdir fallback that 0.10 removed**, and its
  repository layout omitted `scripts/lib/` and the install manifest.

### Added

- **`docs/spec/TAGS.md` — the in-tree resolution index for every charter
  `[DOC:spec-*]` tag.** 22 of the charter's 24 tags pointed into two spec files that
  were **never committed** and no longer exist anywhere, a dangle CLAUDE.md
  documented as "expected" for three releases. Each entry records what the tag
  anchors *as shipped*, and says so plainly where the original rationale is lost.
  `check_charter` now fails the build on an unindexed tag. Orphan entries — a retired
  tag's survivor — are deliberately allowed: history, not rot.

- **Direct coverage for `/cc-operator:start` and `/cc-operator:handoff`**, which had
  none: the bash suite matched only `commands/tiers.md`. The handoff cases assert the
  six sections against the CHARTER as well as the command, because the
  `HANDOUT_PACKET_SPINE` lesson is that parity passes perfectly when the original is
  what lost the field.

- **brainstorm and crawl fan-out coverage.** Both had one case (tier validation),
  leaving their fan-out shape and both dead-agent guards untested — the F31/F32 class,
  where a laundered agent death is byte-identical to "found nothing". Now 11 cases
  each: direction/shard counts, the cheap-vs-judgment tier split, the dropped-shard
  count, the dead-agent returns, and that `args.noReferences` skips the dispatch
  rather than dropping its result.

  Suites: **bash 604 → 620, node 219 → 242.** Every new case mutation-checked. One is
  worth recording: the six-section counter first read `^[1-6]\. \*\*`, which counts at
  most six and is therefore blind to a seventh — it stayed green when the mutation
  added one. A check that cannot fail is not a check.

### Verified live

The replay charter (R0–R8) was executed against this tree with the plugin
inline-loaded: **9 PASS, 1 deferred, 0 FAIL**, every phase with its own negative
control. R0's build-identity check earned itself immediately — the first `cmp` ran
against a stale plugin cache and reported 5/5 STALE, which was a wrong measurement,
not a defect: the session runs `--plugin-dir .`, so the working tree *is* the plugin
root.

R7 was run for real rather than deferred, which is what makes the review panel's
claim testable at all. A committed artifact carried one **unlabelled** off-by-one
(`can_afford` uses `<` where `spend()` gates on `>`); the giveaway comment was
stripped, because a lens that only finds a defect labelled `DEFECT` has found the
label. Verdict **REFUTED**, all five lenses finding it independently. The adversarial
seat swept the boundary exhaustively — 21 mismatches, one for every state where
`n == remaining()` — and found three defects nobody planted: a `ZeroDivisionError` at
`total=0`, an unvalidated negative total, and a check-then-act race.

### Known gaps

Recorded as issues rather than left as silence:

- **#79** — only `review` has ever run against a model. brainstorm, crawl, plan and
  dispatch are proven at the wiring level: the node suite loads each workflow with
  stub agents returning canned objects, which tests tier resolution, fan-out shape,
  refusals and dead-agent accounting, not output quality.
- **#80** — `skills/chief-operator/SKILL.md` has no gate of any kind. Its
  `/cc-operator:` command reference can be renamed to a nonexistent plugin and every
  check stays green, while CLAUDE.md's coupling table lists it as maintained.
- **#74** remains open and is now confirmed from the other direction: R7 ran
  un-isolated, F-A1 fired correctly, and `isolation` reported `mode: builder-tree`
  with `observedCommit: null` — honest about what it did not do.
- **#25** gained a datum this release: `.operator/` was deleted between sessions and,
  being gitignored, left no trace. The ledger is not merely unreadable from outside
  the session — it is not durable inside it.

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
