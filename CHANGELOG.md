# Changelog

All notable changes to **cc-operator** are recorded here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/).

The version in [`.claude-plugin/plugin.json`](.claude-plugin/plugin.json) is the
single source of truth; bump it in the same commit as the changelog entry.

## [Unreleased]

## [0.12.12] - 2026-09-26

The JUDGMENT tier defaults to the harness alias `opus`.

### Changed

- **`JUDGMENT` defaults to `opus`, not `claude-opus-5`.** The alias always
  resolves to the latest Opus, so the default cannot go stale — the same reason
  the workflows' own `DEFAULT_TIERS` are aliases (#76 step 2). The baked default
  changed in all three copies (`ops-tiers.sh`, `ops-render.sh`, the `ops-init.sh`
  scaffold), and the debate panel's Anthropic seat followed:
  `PANEL=opus,glm-5.3,deepseek-flash`, `PANEL_FALLBACK=qwen3.8-max,persona:opus`.
- **A harness alias is harness-served.** `opus`/`sonnet`/`haiku`/`fable` count as
  available without a `/v1/models` entry (`--panel`), are skipped by the
  catalogue note (`--check`) and the liveness probe (`ops-render.sh --check`),
  and share family `claude` with `claude-*` ids in both family-rule copies
  (`ops-tiers.sh` `family`, `debate.js` `familyOf`). Without this the new default
  panel dropped its `opus` seat against any real catalogue, and
  `ops-render.sh --check` refused to render. `--suggest` names an alias
  binding as an alias ("not compared") rather than "not graded": grades key
  concrete ids, and mapping one to the other would be a catalogue that rots.
  `--check`'s catalogue note reads `CC_OPERATOR_CATALOGUE` like `--panel` does.

### Fixed

- **A BOM no longer hides a spec's Status line from the plan gate (#186).** A
  leading byte-order mark put a line-1 `Status: DRAFT` off column 0, so the
  gate read "no Status line" and ran the unapproved spec on the spec-less path.
  `plan.js` strips a leading BOM before matching. The other edge inputs are now
  pinned in the direction they already resolved: CRLF parses, lowercase
  `approved` refuses, the FIRST of two Status lines decides, a column-0 line
  inside a fence refuses, an indented line is not the stamp.

## [0.12.11] - 2026-09-25

Two instruction-vs-mechanism gaps closed in code (#177, #178).

### Changed

- **The plan gate is enforced in `workflows/plan.js` (#177).** A spec whose
  column-0 `Status:` line's first token is not `APPROVED` is refused before any
  dispatch — the exact line `ops-spec.sh --approve` stamps, previously checked
  only by `commands/plan.md` prose. A spec with no Status line proceeds as the
  pre-#155 spec-less path and the result reports `specStatus: "unstamped"`
  (an APPROVED spec reports `"approved"`), so the operator sees which path ran.
- **A missing `node` makes the PostToolUse compressor hook a no-op (#178).**
  The hook command is now `command -v node >/dev/null 2>&1 || exit 0; node …` —
  the same exit-0 fail-open as the jq/python3 hooks (silent here; those warn).
  Previously a node-less machine ran a hook exiting 127 on every matched tool
  call.

## [0.12.10] - 2026-09-25

A prompt audit of every model-facing surface.

### Changed

- **Prompt audit of every model-facing surface** (agents, skills, commands,
  the charter, workflow prompt strings) against Claude Opus 5. Seat prompts now
  name the packet fields the workflows actually send (`DONE`, not `DONE MEANS`;
  `CONSTRAINTS` only where a caller passes it). `/cc-operator:start` no longer
  offers the "non-trivial" BAR exemption the charter forbids. The charter's
  report-once rule now says when to speak between tool calls; its self-audit
  and Thought/Action/Observation rules, which nothing enforced and no session
  followed, are removed. op-author loses its self-review instruction, the
  read-only seats lose prohibitions their tool lists already enforce, and
  issue/audit ids and version history leave model-facing text, including the
  workflow `meta.whenToUse` strings (review, debate) that ride every request and
  the review/plan result strings a seat or operator reads. Target model: Claude
  Opus 5.5 (`claude-opus-5-5`).

### Added

- **`check_agent_field_labels`** (#180): an agent body (and the renderer
  template) may name a dispatch field only if it is a charter packet field or a
  label a workflow dispatching THAT agent actually emits. Red on the pre-fix
  tree (op-author, op-mechanic, default.tmpl each named `DONE MEANS`); seven
  python cases, each red case red under its own mutation.

### Verified

- **Live behaviour run** (#183), old (11abad5) vs new, on `claude-opus-5-5`
  where the seat alias resolves to it: 24 headless seat runs (op-author,
  op-mechanic, op-scout, op-brainstorm) and 12 operated sessions (6 solo, 6
  orchestrated with an op-mechanic dispatch). No regression in any arm:
  every fixture ended `PASS`, the FORBIDDEN file untouched, the vague packet
  NEEDS_CONTEXT 6/6, no raw diff or transcript ingested, 0 pending sentinels.
  The self-audit rule was the one visible behaviour change — the old charter
  wrote it in 3/3 orchestrated sessions, the new one in 0/3 — and the T/A/O
  trace appeared in 0 of 12 sessions under either charter.

## [0.12.9] - 2026-09-25

The documentation, audited against the code and restructured. The README is
rewritten for the current version, and `docs/` is grouped by audience with an
index the README links to.

### Changed

- **`docs/` is grouped by audience**: `guide/` (HANDOUT), `design/` (TAGS, CYCLE,
  DECISION-ENGINE-PROBES), `maintainer/` (PLAYBOOK, LANDMINES, REPLAY-CHARTER,
  UNKNOWNS), `history/` (CHANGELOG-archive), and `docs/README.md` indexes them.
  Every path that named a moved file was rewired: the validator, its tests,
  CLAUDE.md, code comments and cross-doc links.
- **README.md rewritten for the current version.** It now covers prerequisites (git, jq or python3, node, and
  optional cc-proxy/cc-status), what `/cc-operator:start` installs and what it
  tracks, the four Stop-hook blocking conditions, auto-arm, the loop guard, the
  cap detector, MOOT and `--defer`, the stage banner, hooks, tiers and
  `tiers.env` line kinds, all four status segments, the full layout, and CI as
  `gate-suite.sh` rungs. Every claim was checked against the code, and an
  adversarial review pass then found 16 more false claims, each reproduced and
  fixed.
- **HANDOUT.md** now has 8 agents, 7 workflows, 11 commands, the cycle, and
  the panel. **CONTRIBUTING.md** prescribes the CI rungs instead of raw suite
  commands and describes base-gate correctly. **CYCLE.md** states what is built.

### Fixed

- **HANDOUT's `tiers.env` example exited 2.** A `#` after a value is part of the
  value, and `ops-tiers.sh` refused `JUDGMENT='claude-opus-5 # …'`. Comments now go on
  their own line; the corrected example resolves with rc 0 in both
  `ops-tiers.sh --show` and `ops-render.sh --show`.
- **CLAUDE.md said a shared worktree suppresses auto-arm.** `autobar_decide` has
  no suppression (both tried rules failed open). It also named
  `docs/audit-2026-08-09-handoff.md` as committed, but that file left in 0.10.0.
- **Docs claimed behaviour the code does not have:** that `ops-verdict.sh` refuses to close a
  foreign sentinel (it does only under a different `--owner`), that auto-arm
  fires only when no task is open and once per session (it ignores open tasks,
  and re-arms after each SessionStart), that the banner can print `HANDOFF` (the
  banner passes `-` for deviations), that MOOT does not reset the rework cap,
  and that base-gate checks out the PR head (it never does).
- **Workflow comments pointed at the removed `docs/spec/`.** brainstorm.js and
  plan.js now name `/cc-operator:spec` and `docs/plans/`.

### Filed

- [#177](https://github.com/betmoar/cc-operator-plugin/issues/177): the plan gate is
  command prose, and `plan.js` accepts an unapproved spec.
- [#178](https://github.com/betmoar/cc-operator-plugin/issues/178): without node,
  the PostToolUse hook exits 127 on every matched tool call.

## [0.12.8] - 2026-09-24

A holdout can now be derived from inside the plugin, and a first-time user can watch
the gate block before reading about it.

### Added

- **`skills/holdout` + `scripts/ops-holdout.sh` (#150).** The procedure #112 learned
  over three derivation rounds and three repair dispatches, as a skill: prove the denial, derive, reproduce every disagreement before
  deciding defect vs over-assertion, dispatch repairs back (never hand-edit), cap rework
  at two, accept only after a mutation drives it red, gate on a marker. The CLI owns the
  one thing a skill cannot enforce, the denial itself: `--derive` runs `claude -p` with
  `--tools ""`, `--setting-sources ""` and `--strict-mcp-config` from an EMPTY directory,
  refusing a non-empty dir, an ancestor `CLAUDE.md` and empty context. `--canary`
  measures the property on this machine's claude, using a planted file in the cwd and a
  codeword in an ancestor `CLAUDE.md`. Measured live on haiku: PASS as shipped. Without
  `--setting-sources ""` the codeword leaks (red), and with `--tools Read` the file
  leaks (red). Also measured: `--tools ""` alone still loads the user's and the project's
  `CLAUDE.md`, so a tool-denied process is not independent without the second flag.
- **`/cc-operator:tutorial` + `scripts/ops-tutorial.sh` (#75).** A throwaway git project,
  one tracked task, and the real Stop hook fed a Stop payload: exit 2 (blocked), then a
  verdict row with evidence through the installed CLI, then exit 0. It prints
  `TUTORIAL_OK` only when it observed both, and a copy whose hook never blocks fails it
  with `TUTORIAL_FAILED`. The README gains a Getting started section pointing at it.
- **Where a workflow's result goes (#75).** `commands/{brainstorm,plan,debate,review}.md`
  each say it, because a workflow cannot publish: specs and plans are inputs to later
  work and go in git (`plan.md` now grants `Write`). A brainstorm bundle, a debate, or a
  panel report can be published as an artifact when the session has a tool for it.
  Ask once per session.

### Fixed (PR #176 review, each reproduced first)

- **`--canary` could PASS without measuring.** A `claude` that prints an error at exit 0
  ("Invalid API key", an unknown model) contains neither planted token, so it read as
  "no leak". `--derive` handed the same error back as a derivation. Both now require a
  random nonce on the answer's first line: an error message cannot contain it. Measured:
  haiku and sonnet echo it with every tool denied.
- **The tutorial could credit the wrong block.** The auto-arm (#85) also exits 2, so the
  block must now name `tutorial-demo`. A failing `ops-task.sh` or `ops-verdict.sh` was
  masked by `| sed` without `pipefail`. The tutorial now sets `pipefail`, requires the
  sentinel to exist after step 2 and the row to exist after step 4, and stops otherwise.
- **Copilot review.** A reply holding the nonce and nothing else still made `--canary`
  PASS, because the empty scan found no leak (reproduced). The answer must now have a
  non-blank body after the nonce. `--derive --canary` together is refused; before, the
  later flag silently won. `/cc-operator:tutorial` now forwards its arguments, so the
  advertised `--keep` works. The holdout skill's `description:` is quoted: YAML read the
  unquoted ` #112` as a comment and cut the description at "the procedure".
- **Copilot review, round 2.** `commands/tutorial.md` pasted `$ARGUMENTS` into a command
  run under `Bash(bash:*)`, so `--keep; <anything>` became shell. It now offers `--keep` as
  a literal and refuses any other argument. A mid-step abort (a `die`, a `set -e` exit)
  printed no marker at all; one exit trap now ends every non-OK path in `TUTORIAL_FAILED`
  with the exit code. `--derive` also refuses a directory below a `.claude/rules/`: a
  codeword in a rules file reached a tool-denied process without `--setting-sources ""`
  (measured, like `CLAUDE.local.md`).
- **Review, round 2.**
  - The canary matched a leak verbatim, so a model that lower-cased the planted token or
    split it across lines leaked it and the canary still passed (reproduced). The match
    is now on the token's random serial, case-folded, with whitespace and punctuation
    removed.
  - The ancestor walk now refuses a dangling `CLAUDE.md` symlink (`-e` is false for it).
  - The PASS line prints the model's answer. A model that refused to try also reads as
    PASS, and only the answer tells the two apart.
  - Five guards that had no test now each have one that fails when the guard is broken:
    `CLAUDE.local.md`, `.claude/CLAUDE.md`, the `$HOME` skip, and the tutorial's
    sentinel, pipefail and row checks.
  - The tutorial's exit trap skipped the marker on exit code 1, a gap meant for its own
    `TUTORIAL_FAILED` ending. A step that failed with its own `exit 1` (ops-init.sh's
    missing-install-set path) therefore ended with no marker. The trap now keys on which
    ending ran, never on the code.
  - The blank-answer check used `${out//[[:space:]]/}`, which is quadratic on bash 3.2
    (the #145 class). The code review measured 8 KB taking 33 s, and an 80 KB derivation
    never came back. The check now uses `grep`.

### Verified

- **`implement` has its first controlled live run (#79).** A fixture repo carried an
  unlabelled off-by-one (`can_afford` used `<`, `spend` gates on `>`). A held-out probe
  the seat never saw found 21 mismatches. One mechanic seat on `claude-sonnet-5`
  (confirmed from the agent log, 37,642 tokens, 23s) returned DONE. Checked outside its
  report: the probe then found 0 mismatches, the diff was one line (`<` → `<=`) with
  `spend` untouched, and its new regression test fails on the pre-fix file (1 failed,
  2 passed).

## [0.12.7] - 2026-09-24

The #172 panel's review follow-ups (#174), and #138's priced omission moved into the tree.

### Fixed

- **A misspelled panel key is refused, not swallowed (#174 item 3).** `PANEL_FALLBAK=RECON`
  read as a seat binding: `--panel` gave rc 0 on the default panel, and `ops-render.sh
  --model PANEL_FALLBAK` resolved a phantom seat. Seat names are now lowercase in both
  parsers — they name `agents/op-<seat>.md` — so an UPPERCASE non-tier, non-panel name is a
  misspelling and dies at rc 2, naming the three line kinds. A lowercase custom seat still
  binds (CONTROL case).
- **A nested `persona:persona:x` is refused (#174 item 5)** in `check_panel` and in debate.js
  `parseEntry` (models and spares). It passed both and would have sent `persona:x` to the
  router as a model id.
- **A fallback dropped for repeating a seated family says so (#174 item 1)**, with the same
  `repeats family … — skipped` note the panel side already printed.

### Changed

- **The scaffold's commented panel defaults are pinned to `ops-tiers.sh`'s baked `PANEL=` /
  `PANEL_FALLBACK=` (#174 item 4)**, read from the script rather than from a literal in the
  test — the third copy now fails when the first moves.
- The `ops-tiers.sh` panel comment cites #172's measurement, not the closed #84 (#174 item 6).
- **#138 closes into `docs/LANDMINES.md`.** The six unpinned CR sites are a decision, not a
  gap; the record now lives beside the code with the four reasons and the reopen condition.

## [0.12.6] - 2026-09-24

A debate now seats three different model families by default, and says when two of its
seats are one model.

### Added

- **A cross-vendor debate panel, declared once (#172).** `tiers.env` gains two keys:
  `PANEL=claude-opus-5,glm-5.3,deepseek-flash` and
  `PANEL_FALLBACK=qwen3.8-max,persona:claude-opus-5`. Those are the defaults, and they are
  the user's choice, not a capability ranking. `ops-tiers.sh --panel` resolves them against
  what the proxy routes and prints `{"models":[…],"spares":[…]}`.
  - An id counts as available when it is a harness-served `claude-*` id, or when it is listed
    in `/v1/models` and not marked `usable:false`.
  - Diversity is judged by model family, not by route: `qwen:glm-5.3` is GLM, so it cannot
    take a second seat beside `glm-5.3`.
  - A panel that comes up short says so on stderr.
  - With no proxy, or an unreadable `/v1/models` body, availability goes unchecked, with a note
    (fail-open). The family rule still applies, since it needs no catalogue. Before the Copilot
    review, those paths printed the declared lists raw, so `glm-5.3,qwen:glm-5.3` seated one
    family twice. With no `python3`, `--panel` exits 3 and prints no JSON. The raw lists skip
    both rules, and a shell copy of the family rule would be its third hand copy.
  - A `PANEL` of fewer than 2 or more than 5 entries, or a `PANEL_FALLBACK` of more than 5, is
    refused (rc 2) at the line that declared it. Before this they resolved at rc 0 and failed
    later in `debate.js`. A panel that resolves to fewer than 2 seats still prints its JSON, but
    exits 3 and says it cannot be dispatched (#174 item 2). The same full entry listed twice
    (`persona:x,persona:x`) seats once, with a note. `debate.js` refused the duplicate.
  - Only the list of routable ids is read, never `grade` (#121).
  - `commands/debate.md` resolves the panel instead of asking for hand-typed ids.
  - `ops-render.sh` skips the panel lines. Without that skip, every render in a project that
    declares a panel died on `seat 'PANEL' bound to unknown tier` (measured). The key set is
    pinned in parity by `check_resolver_renderer_parity`.
- **`debate.js` takes `persona:<id>` and `spares` (#172).**
  - A persona seat runs on the bare id and carries an assigned temperament in all three rounds.
  - The synthesis is told, by letter only, which seats share one model family, so their
    agreement counts as one voice. Each shared group is counted by its own size; the note once
    reused the first group's size for all of them. That covers a persona seat and the same weights over two
    routes (`glm-5.3` + `qwen:glm-5.3`, found in review). Family uses the same rule as
    `--panel`, because a caller passing ids by hand skips `--panel`. The result reports
    `distinctModels` as a count of families.
  - A colon whose left side holds a `/` ends a variant tag, not a route: `z-ai/glm-5.2:free`
    is GLM. Reading the text after the last colon made 79 of the proxy's 461 ids family `free`
    or `batch`. Two vendors read as one, and GLM beside `glm-5.3` read as independent (found
    in review, measured on the live catalogue; both copies of the rule now agree on all 461).
  - A seat that dies at opening is re-seated on the next unused spare and keeps its letter. The
    move is reported in `reseated`. `agent()` returns `null` for an unroutable id rather than
    throwing (probed), which is what makes the re-seat possible.
  - `reseated` and `distinctModels` are on every return, including a collapsed panel and a dead
    synthesis. Those are the cases where the re-seat record matters most. `distinctModels`
    counts only seats whose opening returned; it used to count a dead seat's family too.
  - The family tally is a `Map`. On a plain `{}`, an id like `constructor-1` (family
    `constructor`) hit `Object.prototype` and threw before synthesis.

### Measured

- **First controlled live debate (#79).** The panel ran on Opus, GLM-5.3 and deepseek-flash,
  with 10 agents, 0 dead and 331,598 tokens. The case carried a planted error: that
  `CAPS_MAX_BYTES` is 64 KiB. It is 2 MiB (`scripts/lib/caps.sh:133`).
  - All three seats refuted the error in their openings, independently, each citing
    `caps.sh:133`. Each also named the two 65536 literals the error was built from (the cache
    guards at `caps.sh:579` and `:608`). Checked against the code by hand.
  - The seats disagreed where the numbers were hard. One seat withdrew its own claim about
    which bound fires first. The synthesis kept a contested headroom figure open rather than
    averaging it away.

## [0.12.5] - 2026-09-23

The cheap tier stops paying more for less, and brainstorm's seats stop giving one answer
four times.

### Added

- **`ops-tiers.sh --suggest` (#153).** Reports which tier bindings are dominated, and
  changes nothing. It reads cc-proxy's `~/.claude/cc-proxy/grades.json`, or the path in
  `CC_OPERATOR_GRADES`. A binding counts as dominated when some graded model scores at least
  as high and costs no more on input or output, and is strictly better on at least one of
  the three. It does NOT pick the cheapest model above a capability floor: run over the live
  table, that `min()` puts three of the four tiers on one model, and then the judgment seat
  is no stronger than the seat it reviews. The report prints the table's `fetched_at`, so a
  stale suggestion shows how stale it is, and an ungraded id is reported as ungraded. It
  fails open: cc-proxy is optional, so an absent, oversized or unparseable table, or a
  missing `python3`, produces a note at exit 0. The table is read where cc-proxy keeps it
  and never copied into this repo; that copying is the class 0.8.3 removed. Every string
  in the table is treated as untrusted. Control bytes are replaced before printing, so a
  model key carrying terminal escapes (alternate screen, title bar) cannot repaint the
  screen. A lone UTF-16 surrogate prints as a replacement character instead of ending the
  report in a traceback. Both were reproduced in review. The PR review added three more.
  - A table entry without a numeric score or price is counted in the summary line instead of
    dropped silently. The live table has 8 such entries out of 32, so "not dominated" is now
    qualified by what was actually compared.
  - A bare binding matches its vendor-prefixed grade key (`z-ai/…`). The report names the key
    it matched, and says AMBIGUOUS when two prefixed keys carry different numbers.
  - A python failure after some rows were printed marks those rows INCOMPLETE. Before this,
    the fallback note claimed nothing had been read at all.

### Changed

- **The baked MECHANICAL default is `glm-5.3-flash` (#153).** It was `glm-5-turbo`. By
  cc-proxy's grades (fetched 2026-09-17, both entries `measured`), the old default was
  dominated on every axis: 61.69 vs 66.04 capability, $1.20 vs $0.09 input and $4.00 vs
  $0.30 output per Mtok. That is 13× the price for a lower score, and it applied to every
  project that had not overridden the tier. Changed in both copies (`ops-tiers.sh`,
  `ops-render.sh`), the `tiers.env` scaffold, and `docs/HANDOUT.md`. The default carries
  a dated comment, so the next reader knows when it was last checked.
- **brainstorm assigns each direction seat a stance (#84).** On a live run, four seats
  with one shared prompt (differing only by "Direction i of N") came back with four
  checksum schemes for a single design. The directions that questioned the premise never
  appeared. Each seat now gets one of six generative stances: smallest change, challenge
  the premise, remove the cause, move the responsibility, detect and recover, borrow. The
  order is chosen so that the 2-seat minimum still keeps the premise challenge. Converge is
  told to keep one ranked entry per direction, so it cannot flatten them back into
  `sharedConstraints`.
  Measured on the original #82 topic, with 16 seats (4 unassigned, 4 assigned, on each of
  `glm-5.3-flash` and `glm-5-turbo`, with no tools and the context inlined). A blind judge
  at judgment tier clustered them by mechanism, twice. The number of distinct mechanisms
  per 4-seat run did NOT change: 3 unassigned, against 3 or 4 assigned. The distribution
  did. One family, "validate the whole set before any write", held 4 of the 8 unassigned
  seats and 0 or 1 of the 8 assigned ones, depending on the judge run. Two mechanisms
  appeared only in the assigned arm: moving the check to build time (2 or 3 seats), and the
  in-loop smallest fix (2 seats). This setup did not reproduce #84's four-way convergence
  either: one unassigned seat derived the set from the directory, which #84 lists as a
  direction that never appeared. The judge was blind to which arm a seat came from, but
  not fully to its stance: two seats echoed their stance label ("REMOVE THE CAUSE",
  "smallest change").
  A second measurement ran the SHIPPED path: `brainstorm.js` through the Workflow runtime,
  op-author seats with tools on, `glm-5.3-flash`, on a different topic (#152's packet
  triage), unassigned (`3cfe597^`) against assigned at N=2 and N=6, one run each. All 16
  direction seats returned the schema: none rate-limited, none dead. (With `claude -p
  --json-schema`, 15 of 24 had returned prose.) The seats barely used the tools: 6 Bash
  calls across 16 seats. Two blind judge runs produced the same 5 clusters. Distinct
  mechanisms per run: N=6 3 unassigned against 4 assigned; N=2 2 against 2. The dominant
  family, "one extra cheap seat judges the packet", held 4 of 6 unassigned seats and 3 of
  6 assigned ones. A deterministic lint appeared only with stances (smallest change at
  N=2, borrow at N=6). At N=2 the premise challenge landed outside the smallest-change
  cluster. At N=6, detect-and-recover, smallest change and move-the-responsibility all
  collapsed into the dominant family, so detect bought no mechanism of its own. Borrow
  did.
  Across both topics the finding is the same: stances change WHICH directions appear and
  add at most one per run. #84's four-way convergence did not come back. The pre-#84
  script was re-run on the #82 topic, N=4, `glm-5-turbo`, through the Workflow runtime,
  twice. Two blind judges put at most 2 of 4 seats in one family in every run. With the
  two no-tools baselines above, that is 1 converged run (2026-08-22) against 4 that did
  not, so #84 is closed as not reproducible: a single run, most likely chance. The stances
  stay, on the measured grounds above, not as a fix for #84. Model diversity across
  vendors is #172.
  What the stub suite can check is the input: N distinct stances at N=2, 4 and 6. Output
  quality is still #79's gap.

A criterion that stopped being answerable gets its own verdict word, and the rework cap says
what it cannot see.

### Added

- **`MOOT`, a third verdict word (#91).** `ops-verdict.sh <id> <criterion> <reason> MOOT`
  records that a criterion can no longer be evaluated, for example a gate that needs the
  same bytes HEAD has since moved past. Before this, the choices were PASS (a lie), FAIL
  (reads as broken work), or `--defer` (closes the whole task). MOOT works per criterion,
  and the evidence cell is its mandatory reason. A blank reason is refused along with an empty
  one, and whitespace-only evidence is now refused for PASS and FAIL too. "Blank" is judged by
  bytes, so the locale does not change the answer: Unicode blanks (NBSP, zero-width space,
  BOM, and similar) count as blank. A `[:space:]` test alone accepted a lone NBSP under
  `C`/`POSIX` and refused it under UTF-8.
  Every reader learned the word in the same change: `--reconcile` restores a MOOT row,
  `lib/caps.sh` treats MOOT as a reset (it is the cap's own "stop, log, move on"), and
  `ops-reverify.sh` lists it as clear because it asserts no result to re-run.
- **`check_verdict_words`.** The verdict enum has three hand-copied sites: the writer's
  `case`, `row_is_conformant`'s regex, and `caps.sh`'s enum. The check holds them to one
  set. It reads every arm of a `case`, requires exactly one site per copy, and reports an
  enum it cannot read. The adversarial review found that reading only the first arm let
  `WAIVE) ;;` as a second arm pass green. `check_caps` gains an executed `moot`
  fixture, because parity cannot see a reset narrowed back to `= PASS`.

### Changed

- **#129: the rework cap is verdict-row-scoped by design.** This is recorded in `caps.sh`'s
  coverage note, with the measurement behind it. On this repo's ledger, `126-*` review rounds
  report tripped=0, and still do when every id is normalised to its numeric prefix, because
  those rounds closed PASS. A round that finds and fixes a defect records a pass, not a
  failure. Re-keying targets would not have fired, so the cap stays keyed exactly as recorded.

## [0.12.3] - 2026-09-23

The cap scan stops costing a second on every Stop, and a long cell stops hanging it.

### Fixed

- **A long cell no longer hangs the Stop hook (#145).** Three parsers split ledger rows with
  `${x%% | *}` / `${x#* | }` chains: `lib/caps.sh`, `ops-reverify.sh`, and
  `ops-verdict.sh`'s `row_is_conformant`. bash 3.2 runs those in time quadratic in the
  cell's length. One 200 KB cell took 8s, and a 2 MB single-row ledger did not return in
  120s while every size bound read as satisfied. Each parser is now one regex match (0.05s
  on the same 2 MB row). A hand-edited row with a bare `|` inside a cell is now skipped,
  matching what the writer and `--reconcile` already refuse.

### Changed

- **The cap scan is no longer paid on every Stop (#127).** The Stop hook calls
  `scan_caps_cached`. It is keyed on the ledger's CONTENT and the detector's own bytes, never
  mtime+size, because a same-second FAIL→PASS flip keeps both. Every cache failure is a full
  scan, so the cache changes only cost, never the answer. The budget is written down for
  macOS bash 3.2: ≤50ms for a hit. Measured: 10 hits on a 3000-row ledger take 0.07s, where
  one full scan took 1.12s before this change. A PASS now removes its key from the table:
  3000 rows scan in 0.63s, and 5000 rows no longer truncate. `check_caps` pins the hook's
  `scan_caps_cached` call and EXECUTES the cache against a same-size FAIL→PASS flip. The PR
  review found that reverting the call to plain `scan_caps` left every gate green.

## [0.12.2] - 2026-09-23

The merge-tree classifier's last unreached branches get cases.

### Fixed

- **base-gate's unreached merge-tree branches have cases (#133).** Three branches of the
  merge-tree classifier had no case: rc 1 with no tree sha, rc 129, and an unrecognised rc.
  For the first, the mutation `_is_sha` always returning 0 was recorded as unreproducible.
  Real git does not produce rc 1 with no sha from inside the gate. Measured on git 2.54:
  partial clones (blob:none and tree:0, lazy fetch on and off, promisor unreachable) answer
  rc 128 or recover. So the bash suite forces merge-tree's exit status with a PATH shim,
  plus a CONTROL case proving the shim reaches the classifier. Each of four mutations goes
  red in exactly its named case. The rc-1 branch is kept: it fails closed, and a future
  git could reach it.

## [0.12.1] - 2026-09-23

CLAUDE.md gets its headroom back, and the narrative it cut stays one grep away.

### Changed

- **CLAUDE.md has headroom again (#159).** It sat at 37,980 of its 38,000-char cap, so the
  next coupling row could not be added without an extraction first. Seventeen coupling
  rows and seven map/provenance passages lost their measured narrative, 3,086 chars in
  all (34,894 now). Every original cell moved VERBATIM to `docs/LANDMINES.md`
  § "Extracted from CLAUDE.md (#159)", matching the 0.11.2 and 0.11.9 extractions. Every
  coupling, pin name and `_"…"_` citation stays in the row: 67 citations before and after,
  none reclassified. CLAUDE.md is a maintainer file and does nothing in the installed
  plugin, so this only trims every dev session's always-on context.

## [0.12.0] - 2026-09-21

The engagement cycle gains the two stages it never had — a **spec** artifact and an
**implement** workflow — plus the command surface that reaches them and the stage
derivation that tells a session where it stands. Design rationale: `docs/CYCLE.md`.

### Added

- **The spec stage has an artifact (#155).** `scripts/ops-spec.sh` writes
  `.operator/specs/<slug>.md` (`--new`), checks it against the schema (`--check`) and
  stamps approval (`--approve`) — the stamp writes a `SPEC-APPROVED` row to DECISIONS.md
  and the BAR block to VERDICTS.md, both under the SAME `.operator/.lock` `ops-verdict.sh`
  and `ops-adopt.sh` take, in that order. Before this, "approved" was a claim in a
  transcript; a session restarting could not tell an approved spec from a draft.
  `check_lock_parity` now holds THREE writers, `check_root_parity` FOUR.
- **The implement stage runs as a workflow (#158).** `workflows/implement.js` replaces the
  bare `Agent` dispatch, which could not reach a tier: the Agent tool's `model` is
  enum-locked to `sonnet|opus|haiku|fable`, so a seat bound to an external model in
  `tiers.env` was unreachable and silently ran the default. The workflow carries the
  charter's dispatch packet (`PACKET_FIELDS`, seven fields), the four-status REPORT
  protocol, and a SERIAL loop — no `parallel(` in the file, because one implementer at a
  time is [D:CHART-r6] and prose does not hold it. `check_implement_packet` pins all four.
- **A command per workflow (#75).** `commands/{spec,brainstorm,plan,implement,review,crawl,debate}.md`.
  Each resolves the tier bindings itself with `ops-tiers.sh --json` rather than asking the
  operator to hand-paste them — the hand-paste IS #55 at the call site. Every workflow but
  `dispatch` owes one, and an absent command is refused by the suite.
- **The session is told where the engagement stands (#157).** `scripts/lib/stage.sh`
  derives one word — BLOCKED > IMPLEMENT > HANDOFF > SPEC > PLAN > CLEAR — from the
  sentinel partition, the deviation scan and the spec summary. PURE and REPORT-ONLY: it
  opens no file, so it is not a reader and carries no byte cap. An UNSCANNED deviation
  gate (`-`) is said, never assumed clean; a foreign sentinel is reported, never a stage.

### Changed

- **`dispatch.js` declines to choose a model rather than promoting a seat (#158).**
  `args.model` wins, then `args.tier`, and with NEITHER the `model` key is omitted
  entirely so the seat's own configured default stands. The previous fallback promoted
  silently.
- **The charter names the implement workflow (#159).** ORCHESTRATED MODE listed review,
  brainstorm, plan and debate while `workflows/implement.js` shipped — the operator was
  not told the stage it runs most has a workflow. One word: 144/150 lines,
  8934/9000 bytes after the rebase onto 0.11.18, caps re-run green.
- **`.operator/.gitignore` takes a third version ADDITIVELY (#156).** v1→v2 REPLACES
  (blocklist and allowlist are contradictory schemes); v2→v3 APPENDS, because v3 only adds
  `specs/` to a scheme v2 already established. A replace there would have destroyed every
  hand-added rule. Both writers (`ops-init.sh`, `ops-sessionstart-hook.sh`) carry it and
  `check_gitignore_parity` pins both halves.

### Fixed

- **The v3 append no longer FUSES with an unterminated last line.** `>>` appends at the
  byte offset the file ends at, so a `.gitignore` whose last line carried no terminating
  newline came back as `!my-hand-added.md!specs/` — measured: the user's rule destroyed,
  `!specs/` inert, and the v3 marker still landing so the migration never retries. Both
  writers terminate the file first. Five cases; the mutation removing the guard from BOTH
  writers turns all five red.
- **`check_cr_strip_parity` no longer excuses a copy with no counter.** Its
  `if "_cr" not in code: continue` guard skipped exactly what the realistic simplification
  produces. Measured on the real tree: `ops-reverify.sh`'s loop replaced by the #139
  issue's own rejected `${row%%$'\r'*}` — which truncates the row at a mid-cell CR — with
  `_cr` dropped from its `local` line left `validate_plugin: all contracts hold`. The loop
  is now required unconditionally wherever `lib/caps.sh` declares `CAPS_MAX_CR`. (The
  narrower mutation, the loop deleted but the `local … _cr=0` line kept, fired even
  before this fix.) Red in `CrStripParityTest`.
- **`check_lock_parity` compared two of three writers.** It held `ops-verdict.sh` against
  `ops-adopt.sh` only, so `ops-spec.sh`'s copy was held by the content pin alone — and
  the content pin passes anything that still looks like a lock. Measured:
  `LOCK_SPINS=100` in `ops-spec.sh` alone reported nothing. Parity now runs against one
  reference copy, so a fourth writer cannot drift unseen either. Red in
  `test_third_writer_drift_fires`.
- **The good-tree fixture was hiding the check entirely.** With `ops-spec.sh` absent from
  the fixture, `check_lock_parity` returned early (missing-file is `check_scripts`' to
  report) and all four LockParityTest mutation cases went green against a check that never
  ran — the #111 shape, inside the suite written to prevent it.
- **The open-questions check named the wrong cell (PR #154, Copilot review).**
  `grep -c '| *|'` matched an empty cell ANYWHERE in the row, so a question that
  WAS answered but named nobody was refused as an "empty Resolution cell" —
  measured, `| Can we X? | Yes |  |` printed exactly that. A true refusal under
  a false name sends the operator to fix the wrong cell. Now cell-addressed:
  the unattributed case has its own message, and a row with fewer than three
  cells fails CLOSED as unanswered rather than being guessed at. The reviewer's
  other premise — that the skeleton's `||` headers were miscounted — does not
  hold: the skeleton writes `| Question | Resolution | Decided by |` and
  `|---|---|---|`, both filtered, and a fresh skeleton reports no
  open-questions problem.
- **The dispatch no-override assertion was reading the wrong object (PR #154,
  Copilot review).** It asked `"model" in dFallCall` — the test stub's RECORD,
  which always carries a `model` property because the stub writes one — so it
  was always true and the check collapsed to `model === undefined`, while the
  `hasModelKey` the stub records for exactly this purpose went unused. Measured:
  `dispatch.js` sending `{ model: undefined }` on that rung kept the node suite
  at 430 passed, 0 failed. The assertion now reads `hasModelKey === false` and
  its control asserts `=== true`; the same mutation is red.
- **SC2329 pre-empted (#160).** shellcheck 0.11 reports "this function is never invoked"
  on `ops-verdict.sh`'s `fallback_release`, which is trap-reachable from nine sites and
  already carried `# shellcheck disable=SC2317` for the same fact. The tree is clean
  under 0.11 with no exclusions; the CI pin is not bumped here.
### Rebased onto 0.11.18

#149's `check_prose_invocations` landed on main while this branch was open, and
it read this branch's prose on arrival:

- It reported 10 correct `ops-spec.sh` prescriptions as unknown flags. The CLI
  dispatches its modes through one `--new|--check|--approve)` arm, and its usage
  is a heredoc with one form per line. The contract reader handled only
  single-flag arms and the first usage line; it now reads both shapes.
- It found three real defects. `commands/implement.md` prescribed
  `ops-claims.sh --claimed` without `--since`, the defect the holdout found in
  the charter. `workflows/implement.js` carried a copy in a string that no
  prose check reads. Two `--approve` lines omitted the mandatory `--owner`.
- Three stage checks used `$(case … in pat) …)`, which bash 3.2 cannot parse
  inside a command substitution. On macOS the suite reported them as failures,
  while the Linux CI passed. The patterns now carry the leading `(`.
- Review of the rebased branch (four lenses) found:
  - `check_guard_parity` left out `ops-spec.sh`, a fourth writer with its own
    copies of both name guards. Deleting its `*__*` arm reported all contracts
    holding. It is now in the CLI tuple, with two cases that are red on the old
    validator.
  - `--approve` duplicated its ledger lines on a retry. A failure between writes
    left Status DRAFT, and every retry re-appended the SPEC-APPROVED line and
    the BAR block (measured: 3 lines and 2 blocks for one spec). A retry now
    skips what already landed, keyed on slug + stamp.
  - The concurrent-verdict case's detector ended the BAR block at the next
    `## ` heading, so a row correctly appended after a trailing block read as
    spliced, a flaky red. It now ends at `Caps:`, with both sides pinned.
  - `stage.sh` and CYCLE.md said the Stop hook shares `stage_derive`. It does
    not; only SessionStart calls it.
- CLAUDE.md went over its 38000-char cap once both sides' rows were merged.
  The base-gate row's mechanics moved to `docs/LANDMINES.md` ("base-gate: the
  operational detail").

## [0.11.18] - 2026-09-23

The v0.11.17 tag build could not ship. Its release job wrote `release-notes.md` to the
repo root, and the validator step after it read every root `*.md` as prose: the notes
quote the old `ops-claims.sh --claimed` form the CHANGELOG records, so
`check_prose_invocations` failed the build 4 times on a file that exists only inside
that job (GitHub run 35822151503). Every PR build was green, because no PR build
writes the file. It is the first time a check shipped in a release read that
release's own notes as prose.

### Fixed

- Both release workflows write and publish the notes at
  `${RUNNER_TEMP:-/tmp}/release-notes.md`, outside the checkout.
- `check_release_notes_outside_tree` pins it in both forges: every live mention of
  `release-notes.md` in a `release.yml` must be the out-of-tree path, and the writer and
  publisher must both name it. It fires 4 times on v0.11.17's workflows. The
  publisher-left-behind case fires on its own, because moving only the writer makes a
  release step that fails after every gate has passed.

## [0.11.17] - 2026-09-19

Closes #149 and #148 — both found while reviewing the holdout's work in PR #146, and
both the same shape: v0.11.16 fixed the INSTANCE and left the CLASS unmechanized.

### Added

- **A validator check comparing prose prescriptions to the CLIs' contracts
  (#149).** v0.11.16 corrected three copies of a charter line prescribing
  `ops-claims.sh --claimed "<paths>"` for a CLI that has required a mandatory
  `--since <sha>` since CR2 and exits 2 without it. Correcting them by hand left
  nothing that would catch the fourth. `check_prose_invocations` extracts every
  `ops-*.sh --flag` prescription from tracked prose and asserts the CLI would
  accept it: an unknown flag, a mandatory flag omitted, or a mandatory flag
  wrapped in `[…]` — the `docs/PLAYBOOK.md` shape, where a presence test reads
  the flag as prescribed while the brackets tell the operator it is optional.
  Both flag sets are read off each CLI's **own parser and `usage:` forms**, never
  catalogued in the validator: a table here would be a second copy of the
  contract, drifting the moment the parser changes, with nothing comparing the
  two — the defect the check exists to catch, one layer up. Mandatory is judged
  **per form** (`--owner` is required by `--mark-handoff` and optional in the
  verdict form; `--expect-clean` is a complete form needing no `--since`).
  Verified against the real defect three ways — the charter, README and PLAYBOOK
  copies each reverted and each driving it red at its own file and line, restored
  byte-identical — plus ten mutations of the check itself, each named with the
  case it drove red (#111). **Four defects in the check were found by RUNNING it
  on the correct tree before any mutation**, each of which would have condemned a
  correct line; a pin that only ever ran against its own mutation would have
  shipped all four.

### Fixed

- **Thirteen shell-suite assertions could pass about a file that was not there
  (#148).** Each proved a writer had appended nothing by comparing two reads of
  the same file. With that file ABSENT both reads are the empty string and
  `[ "" = "" ]` is true, so each certified a refusal about a ledger that was
  never there — a passing value indistinguishable from never-having-measured.
  Measured in isolated trees, pre-fix and post-fix: `ops-init.sh` mutated to
  skip the `VERDICTS.md` copy (still exit 0) gives 991/110 with NINE of the
  thirteen among the PASSES, 997/119 after; a second mutation (no
  `DECISIONS.md`) gives 1085/16 with three more, 1097/19 after. The thirteenth
  passes under that mutation both before and after, and does so honestly —
  an earlier case's append creates the file first. A fourteenth site takes the
  same guard without belonging to the count: it byte-compares an installed CLI,
  not a ledger, and was never vacuous. Replaced with four helpers that assert the precondition and compare with
  `-eq`, which errors on an empty operand where `=` succeeds — the same property
  that made the two pre-existing `-eq` sites fail closed for free. An absent
  precondition is a FAILED check that NAMES the missing file on stderr. Each
  helper carries BOTH controls: refuse the absent file AND accept the present
  unchanged one, since a helper that refused everything would pass a
  refusal-only control set while failing every real call site.

### Review round (PR #146, five reviewers)

Six findings in this release's own work, each reproduced before it was believed and
each now carrying a mutation. Four were in `check_prose_invocations` itself, and three
of those were the check performing its own defect class:

- **It condemned correct prose.** `re.finditer` yields non-overlapping matches, so the
  citation regex's greedy tail swallowed the next invocation whole: `Run ops-verdict.sh
  and ops-claims.sh --since <sha> --claimed "<paths>"` reported ops-verdict.sh for flags
  it never took, while ops-claims.sh went unexamined. Fixing it exposed a second — a span
  of bare filenames reads as each entry arguing the next, so the flagless arm fired on a
  list.
- **The negative-control exemption suppressed its neighbours.** Keyed on the paragraph,
  it exempted every invocation in it; a genuinely broken `ops-claims.sh --claimed "x"`
  appended to REPLAY-CHARTER.md's `--ownr` paragraph was reported by nothing. The
  paragraph now supplies the marker, the line must supply the subject.
- **The root globs were unpinned** — narrowing them to `["*.md", "docs/**/*.md"]` stops
  reading `templates/OPERATOR.md`, the file the defect shipped in, with every case and
  the real tree green. The `_MIN` floor counts invocations, not which files produced
  them: a count is not a selection.
- **A flagless prescription was invisible.** The check keyed on the presence of a flag to
  decide something had been prescribed, so `ops-adopt.sh <task-id>` — which exits 2 with
  `missing --owner` — read as nothing to check.
- Also pinned, each confirmed unpinned by mutation first: the no-readable-CLIs guard, the
  `docs/dev/` exemption, a CLI with no parseable usage form, and the per-form selection
  arm (whose only coverage was the real-tree case).
- **`delta_is` committed #148's own defect one level down.** `${2:-0}` substituted 0 for
  an empty count, so `0 - 0 -eq 0` passed on a file that exists — worse than the
  absent-file case, because nothing looks wrong. #148 guarded the file and left the
  values unguarded.
- **Two counts written beside the code had drifted from it.** The #148 site count said
  eleven in four files: that was the tally from the first substitution batch, three more
  were converted afterwards, and nothing re-derived it — the measured figure is thirteen
  ledger sites plus one non-ledger site. `check_prose_invocations`'s own comment claimed
  21 flagged invocations against a measured 33. Neither was gated by anything; both are
  the F30 rule applied to prose, and both are now stated with the measurement that
  produced them.
- **Round 3: the exemption still skipped a whole line.** Its subject guard is met by ANY
  unaccepted flag, so a neighbour with a typo of its own was exempt from the
  mandatory-flag arm too — `ops-claims.sh --sinse abc --claimed "a"` under a lesson
  paragraph reported nothing, and 2 findings alone. The lesson now suppresses only the
  unknown-flag report. The flagless arm's population counts (149 / 126 / 3) did not
  reproduce (measured 159 / 138 / 12) and were dropped rather than updated: only the
  number a test holds — 0 false positives — stays beside the code.
- **The four latent gaps the review filed, fixed here** (#161 #162 #163 #164):
  - `ops-render.sh` and `ops-tiers.sh` read as ZERO usage forms — they declare them in a
    `# Usage:` comment block the one-line regex could not see — so the mandatory-flag
    arm skipped both silently. The block is now read, and a CLI with no readable form is
    REPORTED where prose depends on it instead of skipped.
  - An invocation wrapped with a trailing `\` inside a fence was judged on its first
    line only; a broken flag on the continuation was never read. Continuations are
    joined in fences (outside one, `\` is a markdown hard break).
  - A non-UTF-8 file crashed the validator with a traceback from an unrelated check.
    `check_text_encoding` runs first and names the file; `main()` turns a later decode
    error into a finding naming the check, so every other contract is still judged.
  - A lesson paragraph excused any unknown flag on any line in it. It now excuses ONE —
    the first typo it carries — and a second, different typo fires.

### Changed

- `FLOOR_shell` 1101 → 1116 and `FLOOR_python` 397 → 433, with the measurements
  in `tests/floors.env`.
- CLAUDE.md gained two coupling rows and lost its `## Procedure` section, whose
  two pointers duplicated what `## Provenance` and `## Landmines` already said.

## [0.11.16] - 2026-09-19

Closes #112 — the first check in this project written by an agent that could not read
`scripts/`, and the defect it found on its first run.

### Fixed

- **The charter prescribed an `ops-claims.sh` invocation the shipped CLI refuses
  (#112).** `templates/OPERATOR.md` § EVIDENCE GATE said
  `ops-claims.sh --claimed "<paths>"`; the CLI has required a mandatory
  `--since <sha>` since CR2 (a HEAD default hides a trespass the worker committed)
  and exits 2 without it. An operator following the charter verbatim got a usage
  error. Every in-repo test passed throughout — they were written against the CLI,
  so they all passed `--since`, and nothing compared the charter's prescription to
  the CLI's contract. Found by the holdout below, which is the first check in this
  project written by an agent that could not read `scripts/`.

### Added

- **A holdout, outside this repo (#112).** `ci-admin/cc-operator-holdout` on
  `lokaal` — 41 checks derived from `templates/OPERATOR.md` alone by an agent with
  no file tools and no shell, run against an `ops-init.sh`-produced `.operator/` as
  a black box. Independence is structural: a cc-operator session never clones that
  repo, so there is no denial to forget and no guard to bypass. Its runner demands a
  positive marker naming the sha (`HOLDOUT_PASSED sha=<sha>`) and a check-count
  floor, so an absent, silent, shrunken or wrong-sha run all fail — measured on the
  forge both ways: run 1458 `HOLDOUT_VERIFIED sha=7057dcf7f2f6 checks=41`, run 1456
  red on a nonexistent sha. Eight mutations against the gate CLIs each drove it red
  and were restored byte-identical. It is not tied to this forge: `run-holdout.sh`
  contains no Forgejo and is verified against a plain GitHub URL; the repo's
  `PORTING.md` prices the alternatives for anyone without a private forge. **That count is a point-in-time figure**: the
  holdout is a separate repo on its own history, so this line records what was
  measured at v0.11.16 and is not kept in sync. Its own README carries the live
  number; `HOLDOUT_MIN_CHECKS` there is the ratchet.

## [0.11.15] - 2026-09-18

Finishes #139 — items 1, 3 and 4, the residue 0.11.14 left open. #139 can close with
this; #138's priced omission (the six unpinned CR sites) is unchanged and stays open.

### Fixed

- **A `\r\r\n` ledger no longer fails the cap detector OPEN (#139 item 1).** `${row%$'\r'}`
  removes at most ONE CR, so a double-terminated row kept one and every comparison below
  it missed. Measured on byte-identical content at 0.11.14: LF `tripped=1`,
  CRLF `tripped=1`, `\r\r\n` `tripped=0` — with `caps_scan_failed=0` and
  `caps_truncated=0`, which reads exactly like a clean ledger. All three 4-cell row
  parsers now strip the whole TRAILING run, bounded: `scripts/lib/caps.sh`,
  `scripts/ops-reverify.sh`, and `ops-verdict.sh`'s `--reconcile` loop (the latter two
  source no lib, so the rule is hand-copied — the standalone constraint the
  `.operator/bin/` CLIs live under).
- **Both remedies the issue proposed were measured and rejected.** The unbounded
  `while ${row%$'\r'}` it suggested is O(n²): on ONE line of 1 MiB of CRs — which the row
  loop's own `read -r -n 1048576` permits — it had not finished after **300s**, inside a
  hook that runs on every Stop. `${row%%$'\r'*}` costs 0.006s and TRUNCATES the row at a
  mid-cell CR, discarding cells. The shipped form is a bounded loop (`CAPS_MAX_CR=16`,
  0.30s on the same line) that leaves a mid-cell CR alone; a row still ending in CR after
  16 removals sets `caps_truncated` rather than being guessed at.
- **`ops-reverify.sh` stops emitting a spurious empty cell.** On a double-CR ledger the
  surviving CR landed in the row's last cell: `| 3 | T1 | FAIL | | no-commit | … |`,
  measured — an extra cell in the operator's own report, plus the header swept as a
  phantom row for the reason #128 names.
- **`--reconcile` restores what it can read.** Four fragments terminated LF / `\r\n` /
  `\r\r\n` / `\r\r\r\n` restored **2 of 4** before this change (announced on stderr with
  a skipped count, never silent); now 4 of 4, with a genuine 5-cell row still refused and
  named.
- **The byte cap charges what a line occupies (#139 item 3).** The strip ran before
  `bytes=$((bytes + ${#row} + 1))`, so a CRLF line was billed one byte less than its true
  size (~1.2% loose). `+ _cr` makes `accounted == on-disk` exact. Recorded honestly: the
  row loop's byte cap is **effectively unreachable**, because the NUL probe above it
  refuses any file over 4096 × 512 bytes — exactly `CAPS_MAX_BYTES` — and accounted bytes
  can never exceed on-disk bytes (bisected: 2,097,152 B passes, 2,097,664 B is refused).
  So this is an exact bound behind a tighter one, not a defect anyone could reach.
- **A rotted line citation now fails the build (#139 item 4).** `check_line_citations`
  refuses a `file.sh:NNN` in tracked prose that is past EOF or lands on a BLANK line. It
  found a live defect on arrival, no mutation needed: `docs/REPLAY-CHARTER.md` cited a
  blank line in `ops-init.sh`, attached to a claim ("the install set lives here") false
  since #76 moved the set to `scripts/ops-install-set.sh`. It deliberately CANNOT see a
  citation that still resolves and no longer says what the prose claims — the message
  tells the author to cite the symbol instead of implying the number is verified. Three
  further citations were converted to symbols (`_dec_line`, `PROJ`, the walk-up).

### Verification

Every fix ran RED on unmodified pre-fix code taken from git, then green, with the tree
restored byte-identical. caps 0/2 trips on `\r\r\n`; reverify's phantom cell; reconcile
2/4 with both skips named. Four shell mutations, each red only on its own case
(`1086/1 failed` ×3, `1087/1` ×1), each in an isolated tree. Two validator mutations red
in `check_caps` — the single-strip revert on the `dblcr` fixture, the greedy-prefix form
on the `midcr` control. Removing `check_line_citations` from `CHECKS` is red in
`CheckRegistryTest`.

One case was rewritten mid-flight rather than believed: the first item-3 probe
recomputed the accounting inside the test and asserted its own arithmetic — green against
a `caps.sh` with the addend deleted. A test that reimplements the rule it tests, tests the
reimplementation.

Gates: shell 1101@1101, python 397@397, workflows 384@384, compress 161@161, validator
all contracts hold, shellcheck clean (one pre-existing SC2329 in `ops-verdict.sh`, present
on `main` and unknown to CI's pinned 0.10.0).

### Fixed in review (PR #144, four panels)

- **A comment claimed a guard that did not exist.** `ops-verdict.sh` said
  `check_guard_parity` pinned the three hand-copied CR strips equal. It does not — that
  check only compares `check_bare_name`/`check_owner_name` and has no notion of a CR.
  Measured: reverting `ops-reverify.sh`'s whole loop to a single strip left
  `validate_plugin: all contracts hold`. Naming the wrong gate is the #111 defect, so the
  gap is now closed rather than documented: **`check_cr_strip_parity`** holds all three
  sites to `CAPS_MAX_CR` and refuses a loop that removes without counting (F30 — equality
  alone is satisfied by three identically-gutted copies). Three mutations red in it.
- **One planted row suppressed the whole cap report, and the operator was told the wrong
  thing.** The CR-residue break abandons the rest of the ledger — measured: two genuine
  FAIL rounds plus one 20-CR row reports `tripped=0` where the same ledger without that
  row reports 1. The polarity is right for a report-only gate; the message was not. The
  hook's notice enumerated four SIZE bounds, so the operator went hunting for length.
  `caps_truncated_reason` now lets a bound name itself, and a size bound leaves it empty
  so the hook still enumerates.
- **Past the bound, `ops-reverify.sh` rebuilt the defect it exists to fix.** At 17 CRs the
  report grew a broken cell — `| 3 | T-y | FAIL | ^M | no-commit | … |`. It now skips the
  row, says why, and counts it. `--reconcile` needs no such arm and the case records why:
  the residual CR lands in the verdict cell and `row_is_conformant`'s enum already refuses
  it, named on stderr.
- **`check_line_citations` looked in one directory.** Scoped to `docs/**` it reported green
  about every file it never read; a reviewer found a live rot it could not see
  (`CHANGELOG.md` citing `statusline.sh:84` for a fallback that has moved). Scope widened to
  all tracked markdown, and that citation converted to a symbol. Also: `:0` was silently
  accepted — `lines[0 - 1]` is Python's LAST line — now refused with its own message.

### Known, unchanged by this release

`scan_caps` does not return within 120s on a 2 MB single-line ledger — measured at HEAD
**and** with this fix, so it is pre-existing and filed separately, not introduced here.

## [0.11.14] - 2026-09-18

Closes #134 and #140. Delivers **part** of #139 (item 2, the writer-side CR refusal) and
part of #138 (the `.gitattributes` complement); both issues stay open — #139's items 1, 3
and 4 are untouched, and #138's priced omission (the six unpinned CR sites) is unchanged.

### Fixed

- **A carriage return is refused at the WRITER, in all three CLIs (#139 item 2).**
  `check_cell` refused `|` and newline and admitted `\r`, so a caller passing one landed
  it inside a cell in the ledger of record — `| T1 | c r \r i t | ev @no-commit | PASS |`,
  measured, and byte-identical on `origin/main`, so it predates #136. #136 taught three
  row parsers to strip a TRAILING CR; a mid-cell one still reached every consumer, and
  `ops-reverify.sh` (no sanitizer) emits it raw into its report.
- **The arm reaches the task-id too, and that is what makes it safe.** `check_bare_name`
  calls `check_cell`, so `ops-verdict.sh` refuses a CR id — which means `ops-task.sh` had
  to refuse one as well. Measured with the arm in `ops-verdict.sh` alone: `ops-task.sh`
  opened `ta\rsk` (rc 0), and both the verdict path and `--defer` then refused to close
  it, leaving Stop blocking on a sentinel no invocation could clear. An opener admitting
  what the closer refuses is not a stricter gate, it is an unclosable task.
  `ops-adopt.sh` carries the arm for the same reason (re-stamping to such a name).
- **Every UNCLOSABLE task id is MALFORMED, not just the CR one.** The first cut of this
  bucket asked which BYTE; the review asked whether any CLI can close the sentinel, which
  is the question the bucket exists to answer. `|` and a newline are refused by
  `check_bare_name`/`check_cell` exactly as a CR is, so they were equally unclosable and
  were not bucketed — measured on `SESS-A__a|b`: `ops-verdict.sh 'a|b' …` and `--defer`
  both exit 2 with `task-id contains '|'`, while the Stop hook printed
  `pending verdict(s): a|b — run …ops-verdict.sh <id> …`, guidance for a command that
  cannot succeed on a task that can never be closed. That half predates #139; the CR work
  is what made it visible. The bucket now encodes the writers' reject set rather than a
  list of bytes, and its cases assert the PREMISE (neither path can close it) so the
  bucket stays the correct home rather than a convenient one.
- **A CR in a sentinel's TASK half is MALFORMED (the reader half of the same fix).** A
  name our CLIs can no longer address is F118/F135's class exactly, so `scan_pending`
  buckets it with the same `rm -f` remedy rather than naming an id the operator cannot
  type back. Keyed on the task half, not the whole name: a CR in the OWNER half already
  degrades to unowned via `sentinel_owner_of_name` (its `*[[:space:]]*` arm matches a CR
  — verified in bash 3.2 and 5), which fails closed as MINE with the task still
  addressable. Keying the bucket on `$name` turned 28 cases red.
- **The Stop hook's MALFORMED message now names the carriage return.** With the bucket
  arm in place and only the message reverted to its pre-#139 wording, the whole suite
  shipped green — so the enumeration has its own pin. A CR is invisible in a terminal;
  a message listing only `__` and empty ids sends the operator hunting for a separator
  that is not there.
- **`.operator/.gitattributes` pins the ledgers to `eol=lf` (#138's actionable half).**
  Measured on a scratch repo with `core.autocrlf=true`: without the rule a checked-out
  ledger is `| a | b | c | PASS |\r\n`, with it `\n`. Measured in the same repo
  immediately after: a ledger written CRLF by an EDITOR in the worktree stays CRLF,
  because gitattributes normalize on checkout/commit and not on third-party writes. So
  this closes git as a PRODUCER of CRLF ledgers and every reader guard stays
  load-bearing — the suite carries that LIMIT as its own case beside the EFFECT one.
  Per-file rather than a `*` rule: `.operator/` also holds `bin/` and `pending/`, whose
  whole point is byte-fidelity.

### Changed

- **`docs/PLAYBOOK.md` documents running the shell rung under BOTH uids (#134's
  remaining half).** The roster under the summary (which #134 already shipped) names
  what a run skipped; the playbook now gives the `su`/`sudo` invocation that covers the
  other direction, and "What a green suite does NOT prove" gains the row for it. Ten
  cases self-skip as root, the total is unchanged by design (#109), so the count alone
  cannot tell you.

### Notes

- `FLOOR_shell` 1013 → 1072. Fifty-nine cases; sixteen mutations, each red in the case
  written for it. Two of those cases exist only because a mutation found nothing: the
  #139 message revert, and #140's PR-side case, which accepted arm 5's message as
  standing in for arm 3b until it was made to name the arm — the interlock masks BOTH
  sides. `check_guard_parity` gained the `a\rb` probe tuple (red on each of the three
  CLIs; before it existed, deleting the shipped arm reported `all contracts hold`), and
  `check_base_gate`'s arm-token set gained `_ci_show` (red when the helper is deleted
  and the unchecked pipeline inlined back — the regression that looks like a
  simplification). Five of the cases came from verifying a claim rather than from a
  mutation: `.operator/.gitattributes` in this very repo returned 0 `eol=lf` lines,
  because the `[ ! -f ]` guard meant #138's rule never reached an existing project —
  their own mutations are drop the `grep -qF` guard → 1 red (idempotence), rewrite
  instead of append → 1 red (hand-edits destroyed), append the inert `eol=lf` shape with
  no `text` → 2 red. Three more came from the review panel rather than from either:
  `>>` appends at the byte offset a file ends at, so on a `.gitattributes` with no
  trailing newline the first appended rule FUSED with the last existing one —
  `VERDICTS.md merge=unionVERDICTS.md text eol=lf`, which git accepts silently and which
  destroys the original `merge=union` rule. Every fixture until then ended in a newline.
  A second review round found three more of the same kind, none of them reachable by a
  mutation of the shipped code: the presence grep was unanchored, so a COMMENTED-OUT copy
  of the rule left `git check-attr` at `unspecified` while ops-init reported success; a
  bare `>>` on an unwritable file printed bash's own `Permission denied` before the
  crafted warning, and `break` hid the remaining two paths.
  Measured macOS uid 501, isolated rung runs; not measured under root.
- TWO of #140's four guards are deliberately unasserted, and the `HONESTY NOTE` names
  both: the base-side AND the PR-side `ls-tree` presence probes. The first draft of this
  entry said "one" — the review panel deleted the PR-side `|| die` and the whole suite
  stayed green, which is the claim failing on its own terms.
  `PR_TREE` is the MERGED tree and shares the base's objects, so any corruption reachable
  from it trips the base-side check (or the change-list diff) first; measured on a fixture
  that deletes the PR commit's `.github/workflows` tree object, the run refuses with
  "could not list … at the base ref", never the PR-side message. The base-side probe is
  unassertable for the same reason: A missing TREE object is what makes `ls-tree`
  fail (deleting the BLOB leaves it at rc 0; only `git show` fails), and that
  corruption is refused EARLIER by the change-list `git diff base...pr` that runs
  BEFORE arm 1, so no fixture in this repo shape
  reaches the guard. Its pair asserts the polarity instead — the #133 situation one
  arm over, recorded rather than faked.
- **`base-gate.sh` arm 3b no longer fails open on an unreadable CI file (#140).** The
  same defect #137 fixed at arm 3, in the arm that commit wrote: `_ci_rungs` piped
  `git show` into grep with `2>/dev/null` and the loop iterated the BASE side, so an
  unreadable base blob made it a no-op and every rung removal passed. The base-side
  `ls-tree` presence probe had the same hole one line up, in its quietest form — a
  `continue` past the whole file, printing nothing and claiming nothing.
  The pipeline is not checkable as a pipeline (`grep` exits 1 on no-match, so an
  unreadable blob and a file that legitimately runs no rungs are the same status), so
  the blob is staged through a checked `_ci_show` and only that status is read.
  Polarity matches arm 3: base side `die` (rc 2 — the gate cannot see), PR side `fail`.
  Reproduced before the fix, end-to-end: rung removed + base CI blob unreadable + one
  unrelated widening of arm 5's pathspec → `BASE_GATE_PASSED`, rc 0. The escape had
  been masked by an **undeclared interlock** — arm 5's own diff dies on the same
  corruption because `.github/` sits inside its pathspec — so arm 3b's correctness
  depended on another arm's pathspec, with nothing stating it. That probe is now a
  case, and it refuses with the widened pathspec too.

## [0.11.13] - 2026-09-16

### Fixed

- **The base-gate judges the MERGE RESULT, not the PR head (#130).** `base-gate.sh`
  computes `git merge-tree --write-tree` and uses that tree as the subject for arms 1,
  2, 3 and 3b. Measured against `d9ed4cd`: a PR whose only change was one README line
  produced two `BASE_GATE_FAILED` lines and rc 1, because this repo raises a floor and
  adds a `tests/` file in nearly every PR and an unrebased branch read as lowering and
  deleting them. The merge result contained neither weakening. Arm 4 keeps the
  three-dot diff on purpose — it names what *this PR* authored, which a human reads.
- **Eight merge-tree outcomes, seven distinct refusals (#130).** `rc` alone does not
  separate them; the discriminator is rc, whether stdout line 1 is a sha, and whether
  the tree has entries. A real conflict, an unreadable object, a corrupt repository
  (rc 128), an empty merge result, an unrecognised output shape, an old git with no
  `--write-tree` (rc 129), and any other exit status are seven branches with their own
  messages. Every one is rc 2 — the gate says it cannot judge, never that the PR weakens
  anything. The first cut folded rc 128 into "your git is too old", blaming the runner's
  version for a corrupt repository.
- **Arm 5 diffs the base against the merged tree (#130).** The anti-wormhole arm no
  longer blames a PR for a marker line the base's own tip already carries. Measured:
  the shape that motivated the change — a marker at the merge base, removed later by
  the base, retained untouched by the PR — does *not* reach the merge result under any
  diff form, so three-dot's silence there was already correct; the change closes a
  false positive and unifies the subject with every other hard-fail arm.
- **The base-gate job runs from its own trusted-event workflow (#131).**
  `.github/workflows/base-gate.yml` and the Forgejo mirror subscribe to
  `pull_request_target` and nothing else, so the `on:` block *is* the guard — a
  workflow that never receives the untrusted event cannot run under it, which replaces
  an `if:` string a reviewer had to read. Both `validate.yml` files lose the job and
  the trigger. This also removes a measured duplicate: with both triggers on
  `validate.yml`, every push ran the full ~4.5 minute suite twice (runs 35081274929
  and 35081274847, both green, both complete). The checkout gains `fetch-depth: 0` and
  the head fetch drops `--depth=1`: `merge-tree` needs a merge base, and a truncated
  fetch leaves objects it cannot read.
- **`check_base_gate` follows the job (#131).** It reads a new `_BASE_GATE_FILES`
  tuple, requires `pull_request_target:` *and* refuses a `pull_request:` subscription,
  and refuses a leftover `base-gate:` job in either `validate.yml` — moving a job is
  two edits and a reviewer sees one diff. Claim 4's token list gains `merge-tree` and
  `PR_TREE`, so deleting the classifier is caught here and not only in the bash suite.
- **`ops-reverify.sh` matches the ledger header WHOLE, not by prefix (#128).** A task
  id of `Gate` with criterion `Criterion` is a ledger `ops-task.sh` permits, and the
  prefix filter dropped that row from the re-verification sweep ENTIRELY: the header
  filter sits before the cell count, so the row was not even tallied as "not a 4-cell
  row" (measured: that counter reads 0). Invisible, not miscounted. `scripts/lib/caps.sh`
  already carried the whole-line form; this is the same fix in the sibling parser.
- **Three ledger parsers stopped losing CRLF rows (#136).** `ops-reverify.sh`, `caps.sh`
  and `ops-verdict.sh --reconcile` each mis-handled a trailing `\r`, and each failed in a
  different direction. The reverify one was a regression introduced by this release's own
  #128 fix: exact header equality removed the `*` that had been absorbing the `\r`.
  `caps.sh` failed **open** — `tripped=1` on LF and `0` on byte-identical CRLF, and the
  Stop hook sources it, so a CRLF checkout silently disabled the same-target-rework cap.
  `--reconcile` **refused** the row: 1 of 2 restored, so a recoverable row stayed
  unrecovered in the one path that exists to recover it. That refusal is ANNOUNCED — the
  row is named on stderr and counted as non-conformant — which makes it the mildest of the
  three and the only one an operator could notice. One `row="${row%$'\r'}"` in each,
  before any comparison.
- **The base-gate no longer passes a `tests/` deletion it cannot see (#137).** Both
  `ls-tree` redirects in arm 3 were unchecked, and the loop iterates the base listing — so
  an empty file made it a no-op. With a nested `tests/sub` subtree object missing, every
  earlier check passes while the listing fails: measured 3/3 deterministic as rc 0 and
  `BASE_GATE_PASSED`, with `D tests/zzz.sh` printed by the delta report one line above the
  pass. A fail-open in a hard-fail arm.
- **The controls those two fixes needed, and the mutations that prove them (#136/#137).**
  A rejection probe with no accepts-the-ordinary-case half is satisfied by a guard that
  refuses everything, and a fixture that silently does nothing reports green while
  testing nothing — so seven more cases, each mutation-checked against the shape it
  guards. Two are worth naming because the fix created them. Stripping the CR makes a
  CRLF header reach `caps.sh`'s whole-line literal for the **first** time, so #126's
  collision fix became newly reachable and needed its own control (revert that literal to
  the prefix glob → red). And the reconcile strip's PLACEMENT is now pinned, not merely
  stated: moving it into `row_is_conformant` leaves the restore assertion green while the
  row carries its `\r` through into `VERDICTS.md`, where it re-breaks every reader that
  does not strip — including the two just fixed.
- **The merge-tree tally said SEVEN/SIX; the classifier has EIGHT/SEVEN.** `397d6d3`
  split rc 129 out of the catch-all — adding a branch — and updated the prose two lines
  above the table but not the table row, the file header, or the arm-5 back-reference.
  Counted at HEAD: 7 `if/elif/else`, 7 `die`, plus the accept. Corrected in all five
  places, and the superseded plan doc now says to count the arms rather than trust a
  number. No pin: the drift cost is a wrong comment, not a wrong gate, and the arms are
  the enumeration.
- **`base-gate.sh` names an unwritable `TMPDIR` instead of blaming the fetch (#135).**
  All 13 `mktemp` calls were unchecked, so a failure left the variable empty, the
  redirection failed, and the classifier read `$?` as 1 with no tree sha — the
  rc-1-no-sha branch. Measured as uid 1000 against a `0500` TMPDIR, the run emitted a
  raw bash error (`line 184: : No such file or directory`) and then told the operator
  the repository was incomplete and to fetch both sides in full. The fetch was fine.
  `rc` was already 2, so the fix is not the polarity but the cause it names. One `_mk`
  helper now carries the refusal; each call site pairs with `|| exit 2`, because
  `X="$(_mk …)"` runs in a subshell where a `die` would exit only that shell.
- **The shell suite names what it skipped (#134, reporting half).** A skip here is a
  property the executor cannot exhibit — root bypasses the write bit, so every
  `chmod` refusal case is unexhibitable as uid 0. That is unavoidable; a run reporting
  "998 cases, slack 0" while 14 properties went untested is not. The summary now
  prints a roster of the skipped titles below the marker line. The non-root CI parity
  job, #134's other option, is not done here.
- **Two rc-classifier fixtures stop depending on root (#130).** Git writes loose
  objects `0444`; root bypasses that bit and an ordinary user does not, so the
  corrupt-object fixture silently did nothing on every non-root runner and the branch
  it tests never fired. It now chmods first and asserts its own precondition. The
  empty-merged-tree fixture no longer deletes an object at all — it builds the empty
  result from ordinary plumbing, which is version-stable and makes the guard genuinely
  load-bearing. See #134 for the structural gap that let both ship green.

## [0.11.12] - 2026-09-07

- **The charter's cap table now has something behind it (#107).**
  `templates/OPERATOR.md` declares three caps and calls a trip "a defined
  stop-and-report, not a judgment call", and until now
  `grep -rn 'Identical-rejection\|rework\|Neighbor-regress' scripts/ hooks/`
  returned nothing: they were instructions to a model, which is the category
  the charter exists to escape. `scripts/lib/caps.sh` is the detector, sourced
  by the Stop hook beside `partition.sh` and `autobar.sh`. It scans
  `VERDICTS.md` for **same-target-rework ×2** — two FAIL rounds on one
  `(task-id, criterion)` — names the targets, and a later PASS on the same key
  clears it.
- **It is REPORT-ONLY, and that polarity is the design.** `VERDICTS.md` is
  append-only with a single writer, so a tripped key can never be un-tripped by
  removing a row: a blocking cap detector over a permanent history is a
  permanent block. The charter also makes the trip the operator's
  stop-and-report, not the gate's. The report is emitted above every `exit`, on
  the allowing path and both blocking paths — the session that stops clean is
  exactly the one that needs to hear it. `check_caps` pins that no `caps_*`
  branch in the hook contains an `exit`.
- **Two of the three caps stay UNCOVERED, and the file says so.**
  Identical-rejection needs a schema decision first: the cap is about a
  *reviewer*, and a row carries no reviewer identity — the 4-cell schema is
  published, and a fifth column breaks every ledger in the field.
  Neighbor-regressing is not a column problem: the cap is about *causation*,
  and a PASS→FAIL flip is the nearest observable while not being the same
  claim. A partial detector whose limits go unstated reads as a complete one,
  so `check_caps` reads both names back out of the file.
- **The pin EXECUTES the detector.** The regression this is written against is
  not deletion — it is a scan that keeps its shape and stops tripping, which
  reports "no caps tripped", byte-identical to a clean ledger, forever.
  `check_caps` extracts the shipped `scan_caps` (with its `CAPS_*` constants —
  an unset one makes `[ n -ge "" ]` evaluate falsy and the detector silently
  stops) and runs it against four synthetic ledgers: trip, reset, a
  same-id/different-criterion control, and an over-budget one.
- **An adversarial round found four defects in the above, all in the same
  commit's own gate.** Three were vacuities of one family — the pin described
  ONE SPELLING of a thing shell writes many ways, the base-gate floors lesson
  arriving a file later. A second `scan_caps()` appended to the lib shipped
  green because bash runs the LAST definition while the probe's extractor
  reads the FIRST, so the probe validated a function that never ran and the
  live hook reported nothing; the report-only pin was anchored on
  `^if [ "$caps_`, so `[ "$caps_tripped" -gt 0 ] && exit 2` and an `elif` form
  both walked past it — and both were live-verified to INVERT the polarity,
  exiting 2 on a ledger with nothing else pending. The pin now asks the
  shape-independent question (an `exit` reachable from any test of a `caps_*`
  variable, with the block walked by depth), and the lib's definition count is
  its own guard.
- **The schema coupling is named, not silently inherited.** `caps.sh` is the
  SECOND reader of `ops-verdict.sh`'s 4-cell row, and its four-cell test —
  correct for a hand-edit, since no writer of ours produces anything else — is
  *wrong* for a schema change: a 5-cell row is silently uncounted, so widening
  the row would turn the detector off with every gate green (measured:
  `tripped=0` on two real rework rounds). A new verdict word is the mirror; the
  reset tests `= PASS`, so a `MOOT` row (#91's proposal) reads as a rework
  round rather than resolving one. Neither is fixable in `caps.sh` — it cannot
  know what the writer will emit next — so the coupling row for the row
  `printf` now names BOTH parsers, and two cases pin the blindness where the
  next schema change will read it.
- **A review round found three more, two of them in the guards themselves.**
  The stderr row-printers wrote `[ "${#row}" -gt 110 ]` under a comment calling
  it a *byte* cap — but bash counts CHARACTERS outside the C locale, so on a
  UTF-8 desktop session the real cap was 220 bytes for `é` and 440 for an
  emoji (measured: a 100-target report emitted 2591 bytes under `en_US.UTF-8`
  against 1731 under `C`). That is the defect `check_reader_bounds` already
  refuses in every file reader, one layer up, on the channel carrying this
  hook's instruction back to the model; both call sites now go through one
  `report_row` owning the sanitize, the cap and `local LC_ALL=C`, and its case
  runs the hook under UTF-8, since a C-only test passes against the broken
  code. Separately, the test helper asserting "this fixture stays under
  `CAPS_MAX_KEYS`" — written to stop the truncation trap recurring — split the
  row into `(criterion, evidence)` rather than `(id, criterion)` and
  undercounted whenever one criterion spanned several ids: **a control that
  counts the wrong thing is the failure it exists to prevent.** Both directions
  now have their own control. Thanks to Copilot's review on PR #126.
- **And the byte-cap fix introduced a worse bug, caught by the second
  executor.** Cutting at byte 110 lands mid-character whenever the width does
  not divide 110 (a 3-byte `€` gives 36.67 characters), and an invalid-UTF-8
  line is not *mangled* to a UTF-8 reader — it is **invisible**: `grep`
  returned rc 1 on a line that was right there. Worse than the loose cap it
  replaced. It shipped green on macOS and red on lokaal because the assertion
  used a plain `grep` and was blinded by the defect it was testing for; the
  fixture was 2-byte `é`, which divides 110 evenly. The cut now backs off to
  the last lead byte, and the cases run all three widths asserting the
  property directly (the stderr decodes) plus visibility to a UTF-8 reader.
- **And the budget under-billed the case it was written for.** The lookup
  compares element `i` then breaks, so a hit at index `i` costs `i + 1`
  comparisons — charging `i` billed a hit at index 0 as free. Measured on a
  19,000-row ledger where every row hits the first key: **charged 0 against
  18,999 real comparisons**, with `caps_truncated=0` claiming the scan had
  stayed inside its bound. Not off by one; off by everything, on the shape a
  mature ledger actually has. Found by Copilot on PR #126.
- **The budget was then skipped entirely on the PASS path.** That branch
  charged its lookup and `continue`d past the check at the loop's tail:
  measured at **964,550 steps against a 100,000 budget — 9x over,
  `caps_truncated=0`, 10.6 seconds** — the whole DoS restored through the one
  branch that skipped the guard, while every existing case stayed green because
  they were FAIL-heavy. A PASS is not cheaper than a FAIL (same linear lookup;
  only what follows differs), so the branches are now one if/elif chain with a
  single exit. The validator's test stub carried both this and the `i + 1`
  defect — and `check_caps` *executes* that stub, so a fixture reproducing the
  bug could not witness the fix. Found by Copilot on PR #126.
- **An adversarial review then found two more, both about bounds that did not
  bind.** `sanitize_row` walks its input byte by byte, and a ledger cell has no
  length limit — two FAIL rows with a 20 KB criterion (accepted by the writer,
  well inside every scan bound) made **every Stop take 5.81s**, outside
  `CAPS_MAX_STEPS` and ahead of the blocking gates. Slicing to 128 bytes before
  sanitizing: **0.53s**. And a truncated scan reported its prefix counts as
  confirmed trips: 60 keys failed, then all 60 passed past the step budget,
  reported as **60 active caps where the truth is zero**, recurring every Stop.
  "A floor" was the wrong word — a floor claims *at least this many* and a
  prefix cannot; a truncated scan now reports nothing and says UNKNOWN. Also
  fixed: `scan_caps` clobbered any caller variable named `_caps_k`/`_caps_c`/
  `_caps_n`, and two comments claimed the 110-byte cap covered the emitted line
  rather than the row payload.
- **The report was going to a channel that does not exist on exit 0.** A Stop
  hook's stderr, when it exits 0, reaches the debug log only — not the
  transcript, not Claude. So the cap report, the one thing that must be seen
  when *nothing* blocks, was visible only when an unrelated gate happened to
  block: the exact dependency its placement was designed to avoid. Every test
  asserted captured stderr, so the feature was fully covered and never
  delivered — **a test that the message was produced is not a test that it was
  delivered.** It now emits `systemMessage` JSON on stdout on the allowing
  path; blocking paths keep stderr, where exit 2 makes it the channel the
  harness reads back. Also fixed: the ledger header was matched by *prefix*, so
  a real task named `Gate` with criterion `Criterion` — an id `ops-task.sh`
  permits — had its rows silently discarded (measured: `tripped=0` on two real
  rework rounds). `ops-reverify.sh` carries the same prefix filter and is
  tracked as #128 rather than fixed in passing.
- **What the budget does NOT buy, recorded as issue #127 rather than implied.**
  The 11.1s figure is the WORST case, and a project does not live there. At a
  realistic shape (50 distinct keys, mostly PASS), a 3,000-row ledger still
  costs **~1.2s on every Stop**, and 5,000 rows 1.9s. There is no agreed
  wall-clock budget for the Stop hook — `statusline.sh` has CR5's ~300ms, this
  hook has never had one — so "within budget" is a claim nobody can make here.
  The two cheaper designs are named with their reasons: a tail window (what the
  bar does) breaks the reset rule, since a clearing PASS can sit anywhere and a
  false report costs more than a missed one; an mtime cache is the real fix and
  has its own failure mode (a stale cache is a gate that silently stopped
  running), so it is tracked, not half-built. Token cost is separately bounded
  and is not the issue: the report is capped at 10 rows × 110 bytes, measured
  at 1,618 bytes in the 100-target worst case and zero on a clean ledger.
- **The fourth was a measured DoS in the detector itself.** The three size
  bounds do not bound the WORK: the ceiling is rows × keys, and at exactly
  those bounds a 20,000-row ledger across 100 failing targets cost **10.2s for
  the scan and 11.1s for the Stop carrying it** — every Stop, on a ledger an
  ordinary mature project reaches. `CAPS_MAX_STEPS` caps the lookup directly:
  the same input now measures **1.09s** and reports `caps_truncated`, the same
  honest degradation the other bounds use. An associative array would delete
  the term and bash 3.2 has none; a string-keyed table was measured at 3m28s
  on the same input, 20× worse.
- **And a last one: the scan kept working after its answer was thrown away.**
  Hitting `CAPS_MAX_KEYS` set `caps_truncated` and fell through, so the loop
  went on walking a full 100-key table for every remaining row — feeding a
  report the truncation rule had already abandoned (a truncated scan returns
  before building one). Measured on a 20,000-row ledger of *distinct* failing
  targets, which hits the ceiling at row 100 and is what a project with many
  one-off task ids looks like: **0.97s → 0.14s, 7×**. Waste rather than a DoS —
  the step budget did bound it — so the fix is one condition at the loop's
  existing sole exit, not a second `break` upstream. The case asserts **rows
  read**, not wall clock: the budget makes the durations converge, and this file
  has already paid once for a timing assertion that flaked on a shared runner.
  Its first draft anchored on an `xtrace` prefix that the suite does not set, so
  it measured zero rows and *passed* — caught in the same run by its own
  control, which demanded 3,000 rows and got the same zero. Found by Copilot on
  PR #126.
- **The report-only guard had one more door: `then` on its own line.**
  `check_caps` opened its window only when the caps-test line *ended* with
  `then`, so the two-line form bash treats identically — `if [ … ]`, newline,
  `then`, `exit 2` — opened no window at all and shipped green (measured:
  control clean, mutation clean). Same class as the `^if ` and `elif` escapes an
  adversarial verifier found earlier on this branch, one spelling further in,
  which is the argument for describing the *structure* instead: the window now
  counts net `if`/`fi` depth per line and never looks for `then`. Counting a
  bare `\b(if|fi)\b` went red on the shipped hook — the truncation message ends
  "…if a rework cap matters here", and prose in a guarded string is the normal
  case here (#93/#94 make these messages long on purpose) — so the tokens are
  matched in *command position*. Three cases: the multi-line form, plus two
  negative controls (a one-line `if …; fi` must not unbalance the window, and an
  English `if` in a message must not be read as a keyword). Found by Copilot on
  PR #126.
- **Two stale notes corrected in the same round.** `caps.sh`'s `CAPS_MAX_STEPS`
  comment still said the caller reports a floor, which the adversarial round had
  already replaced with *unknown* — a comment describing the design a rewrite
  replaced is the same defect as a stale pin. And `tests/floors.env` said
  `FLOOR_shell 968 -> 974` above a binding of `977`: the previous bump amended
  the earlier heading instead of appending, so the one line explaining why the
  floor sits where it does stopped resolving. Each bump now gets its own entry.
  Found by Copilot on PR #126.
- **NUL bytes walked straight through the ledger byte budget.** `read` *discards*
  NUL — a bash variable cannot hold one — so the row loop's `${#row}` measured
  what survived the read rather than what it consumed: a megabyte of NUL arrived
  as the empty string and charged the accumulator one byte. `CAPS_MAX_BYTES` was
  therefore not a bound on any input containing NUL. Measured on the shipped
  hook, macOS bash 3.2: an 8 MiB ledger — 4× over the 2 MiB cap — scanned to EOF
  in **3.6s reporting `truncated=0`**, a confident clean answer over a file the
  bound existed to refuse. The cost is the *delay*, not the report: this scan
  runs before the pending and deviation gates, so a corrupt or planted ledger
  buys seconds of latency on every Stop. A bounded NUL probe (512-byte chunks,
  2 MiB ceiling, its own subshell) now degrades to **`truncated=1` in 0.044s**,
  82×. Report-only leaves no fail-closed direction, so the state is *unknown*,
  which the caller already says — not `scan_failed`, which means "no ledger" and
  this ledger exists.
- **And the pin that should have caught it was blind to its own idiom.**
  `check_reader_bounds` counted `IFS= read -r -n N` and had no place for `-d ''`
  *between* `-r` and `-n` — which is exactly how a NUL probe is written. All
  three shipped probes (`caps.sh`, `partition.sh`, `statusline.sh`) were
  invisible to it, so each file's floor was satisfied by its row loop alone and
  any probe could be deleted with the build green. `partition.sh`'s entry even
  claimed its probe "counts below". The probes are what make the row loops' byte
  caps real, so this was the same defect one layer up. Regex widened, floors
  raised to 2/2/4, each deletion verified red. Found by Codex on PR #126.

## [0.11.11] - 2026-09-05

- **The validator no longer grades the pull request that edits it (#108).**
  Every CI rung ran `scripts/validate_plugin.py` from the PR's own checkout,
  so a branch that lowered a floor, dropped a check from `CHECKS`, or deleted
  `gate-suite.sh` supplied the code that judged it. This is the shape of the
  sibling project's worst incident: a guard that SAW both violations, NAMED
  them, and exited 0. `scripts/base-gate.sh` is the trusted half — it runs
  from the BASE ref via a `pull_request_target` job, checks out the base sha,
  and reads the PR only through `git show`/`git diff`; PR bytes are never on
  disk and never executed. The hard-red arms, as they stand after the review
  rounds below: a floor lowered, removed, or written in a shape the runtime
  and the reader disagree about; a check dropped from the registry or the
  registry rebound after it; an enforcer file gone from the PR ref (deleted,
  renamed, moved) or any `tests/` path gone; a `gate-suite.sh` rung dropped
  from a CI file; and a forged `BASE_GATE_*` marker planted in the diff. It fails
  CLOSED on an unresolvable base ref — falling back to the branch's copy is
  the original bug wearing a fallback's clothes.
- **What it deliberately does not do.** A check REWRITTEN in place (body
  neutered, registry intact) is NOT an arm: trusted code cannot separate that
  from legitimate pin evolution, which this repo does in nearly every PR, and
  a gate that red-flags both is one nobody reads. Those touches ride the
  DELTA REPORT to the human merge instead — no auto-merge exists here. #112
  (the holdout) is the structural version of that gap and is unchanged.
- **The first draft of this change shipped the gate under the WRONG EVENT,
  and only a real forge run found it.** The job was guarded with
  `if: github.event_name == 'pull_request'` — under which the workflow file
  and `base-gate.sh` itself both come from the PR head, so the gate judged
  the PR with the PR's own code, while `pull_request_target` (the trusted
  event, the entire reason the job exists) was skipped. Every local gate
  passed: `act` cannot parse the Forgejo `uses:` form and no local run has a
  PR context. Measured on lokaal, task 483 (2026-09-05), the job ran under
  the untrusted event. `check_base_gate` now pins the job's own `if:` and
  reports the string it found — both spellings read as deliberate in review.
- **A bootstrap state, from the same run.** A `pull_request_target` workflow
  is always read from the BASE branch, so until this lands on the default
  branch the base has no `base-gate.sh` and the step exits 127 — which reads
  as a broken runner, not "there is no gate here yet". Both copies now report
  `BASE_GATE_BOOTSTRAP` and pass: with no trusted enforcer at the base there
  is nothing to weaken, and failing closed would block the very PR that adds
  the gate. Self-limiting; after the merge the base always carries it.
- **Five bypasses found by a five-lens review panel.**
  All three passed the gate before the fix, all three are now red with the
  mutation recorded: (a) a floor hidden behind a DUPLICATE key — the file is
  sourced, so the last assignment is the effective one, and the draft's
  two-line operand made `[ -lt ]` print "integer expression expected" to
  stderr and evaluate FALSY, a genuine fail-open; (b) an enforcer file
  RENAMED rather than deleted (git reports `R`, never `D`, and the path CI
  invokes is gone all the same); (c) a tests/ SWAP — one file deleted, one
  junk file added — holding the count equal while coverage shrank. The root
  cause of (b) and (c) was one design error: arm 3 reasoned about the diff's
  status LETTER instead of the resulting TREE. It now asks `ls-tree` at the
  PR ref, which makes all three shapes the same question. Then (d) a
  COMMENTED-OUT registry entry — `# check_b,` leaves the token in the raw
  text while python sees one fewer callable, so a token grep reported a
  registry that had actually shrunk; the extractor strips comments first now,
  the same discipline `shell_code()` applies on the python side. And (e) the
  anti-wormhole arm piped `git diff` straight into `grep -q`, the one git
  call in the file with no failure check: `grep -q` on empty input exits 1
  whether the diff found no marker or never ran. Reproduced by removing a
  blob — the shape a truncated shallow fetch takes, which is how this job
  fetches the PR head — the full diff died 128, the arm stood down, and the
  run reported PASS while an enforcer file was modified. It now refuses.
- **The marker arm is scoped to what a human reads as evidence.** Its first
  version went red on the very PR that added its own test cases: a suite
  asserting the gate's refusal text necessarily contains the marker. `tests/`
  and this script are exempt, and the match anchors on the emitted line shape
  (`BASE_GATE_PASSED:`) rather than the bare token — naming the marker is not
  forging it. A false positive that fires on every PR touching its own tests
  is how an alarm gets ignored, so the exemption carries its own control.
- **Two vacuities found by mutation-checking this change's own tests.** The
  fail-closed case asserted `rc 2` alone, and deleting the base-ref guard
  still yields `rc 2` three arms downstream (from the `git diff` failure) —
  it now asserts the MESSAGE names the ref. And `check_base_gate`'s job-block
  locator dropped each file's last line (`"\n".join(splitlines())` loses the
  trailing newline), so a job ending a file lost its final step; the fix is
  mutation-checked red in `BaseGateTest`.
- **A test that was NONDETERMINISTIC on Linux — green or red with no code
  change.** `stat -f '%i'` is BSD/macOS; GNU `stat` reads `-f` as FILESYSTEM,
  errors on stderr, and still prints the filesystem TABLE on stdout, so the
  captured value was 237 bytes of `Blocks: … Free: N`, not empty (measured in
  the PR #125 review, rootful Linux, where all three F5 checks were GREEN on
  the old code). Two captures differ exactly when the free counters drifted
  between them: the "new inode" check passed on drift and the steady-state
  check passed only when nothing moved — red on lokaal (task 490), green in
  the review container, same bytes. The probe takes both spellings now and
  carries its own control asserting it returns a NUMBER, so a dead or
  wrong-shaped probe fails 3 cases loudly (mutation-checked: `_ino` emptied
  → 3 red in the bash suite). Found by pushing the release candidate to the
  second executor, not by any local run.

- **Three more fail-opens, found by the PR review (all `BASE_GATE_PASSED`,
  exit 0, on the shipped gate; each reproduced before it was fixed).** (f) The
  floor arm read VALUES and the file is SOURCED: `FLOOR_shell=1 # 20`
  satisfied the trailing `[0-9]+$` with the comment, and `FLOOR_shell=$((1))`
  after a kept `FLOOR_shell=20` was invisible to the `=[0-9]+` extractor —
  both enforce 1 at runtime. The arm now closes the SHAPE, not the instances:
  at the PR ref a floors.env line is blank, a comment, or exactly
  `FLOOR_<name>=<digits>`, anything else red. (g) The registry arm read the
  tuple BLOCK and python runs the LAST binding: `CHECKS = (check_x,)` after
  the full tuple shrank the registry that runs with the block intact — the
  duplicate-key bypass one file over. One binding at column 0, or red. (h)
  No arm read a CI file at all: a PR that drops `gate-suite.sh shell` from
  validate.yml and the `check_suite_floors` pin in the same commit passes its
  own run, and the base copy never looked. Arm 3b now holds each CI file's
  rung set from the base (comment-stripped, per forge; a file absent at the
  base makes no claim, absent only at the PR ref is red), and the workflow
  dirs are enforcer core for the delta report. Twelve cases, each arm mutated
  red in the bash suite; floors shell 898 → 910.
- Floors raised in the same commit: shell 862 → 881, python 340 → 353.

## [0.11.10] - 2026-09-05

- **CI was red on one test, and the cause was this file.** `test_release_gate.
  test_real_repo_gate_passes` refuses a non-empty `[Unreleased]` while
  `plugin.json` still names a released version — the round's notes sat under
  `[Unreleased]` at 0.11.9. Version bumped to 0.11.10 and the notes retitled;
  no v0.11.x tag exists (latest is v0.9.0), so nothing published was rewritten,
  and folding into `[0.11.9]` would have back-dated this round's work into a
  section that describes a different commit.
- **The last silent state in the `.stopguard` mechanism now speaks.** A Stop
  payload with NO session id cannot ADDRESS a marker, so its block can never be
  spent: every continuation falls to the foreign branch, re-runs the gate and
  blocks again (measured rc 2, 2, 2). The polarity is right and stays —
  `stopguard_can_mark` deliberately refuses to call this the C case, because
  standing down for every session-less payload is the #116 disarm through the
  back door — but `stopguard_mark_blocked` returned success and said nothing,
  so the operator saw a block repeat with no account of why. It warns now;
  case 4o pins it. Exit codes unchanged.
- **The #123B pin no longer depends on a file outside the repo.** Its symlink
  target is a regular file created in the test project, with a setup assertion
  that fails loud if that stops being true. The pin was already load-bearing on
  both platforms (`/etc/hosts` exists on Linux and macOS — it replaced a first
  cut using `/etc/hostname`, which does not exist on macOS), so this is not a
  found vacuity: it removes the external dependency whose absence would make a
  DANGLING link fail `-f` as well, passing the case for the wrong reason with
  no signal. Mutation re-run after the change: dropping `! -L` from
  `stopguard_is_mine` goes RED in the bash suite's `#123B` case (#111's naming
  rule), restored byte-identical.
- **Floors raised to the measured counts** (859 shell as passed+skipped, 340
  python). The python one was DRIFT, not new cases: 0.11.8 set 333 against a
  count that had already moved and nothing raised it since — the hand-
  maintenance lapse #109 predicts, found by re-measuring rather than by a gate,
  because a floor is a floor and slack is green.
- **PR #124 second review round (panel over the fix commits themselves).**
  Findings fixed: 4l's close ran UNCHECKED and — the real defect under it —
  invoked the CLI from the suite's cwd, so the project walk-up resolved to
  THIS repo's `.operator` and 20 stray T-9 rows accumulated in the dogfood
  ledger while `$P`'s sentinel survived (the CLI was correct; the harness
  violated the cd-first convention every other case follows). Fixed both
  invocations, purged the ledger, and made the premise a counted check.
  **The clear-warning path pinned** (final-allow site: marker present, dir
  read-only between mark and clear → rc 0 AND warned; the own-continuation
  route cannot reach it — `can_mark` stands down earlier — so the case
  documents which site it exercises). The classifier window's boundary pair
  is now DERIVED from the window constant instead of hardcoded, so a window
  change moves the test with it. The permission-allowlist comment block was
  rewritten cleanly (the edit had pasted it twice); the "guard removed"
  arm's message now names the move case. `FLOOR_shell` 859 → 862 after the
  rebase (this round's two cases on top of the measured 859).

- **PR #124 review round — two critical, four important, all fixed.** Panel:
  code / tests / silent-failures / comments (types N/A for this diff).
  **Critical:** `stopguard_clear`'s failure was never read or reported at
  either call site — a silently-failed clear leaves exactly the stale marker
  the next foreign continuation misreads as ours (the two-claims rule applied
  to the set, not the clear); both sites now warn. The header contract said
  "a FOREIGN continuation does NOT exit 0" while the #123-C arm stands down
  for foreign continuations on an unmarkable project — the header now carries
  the carve-out. **Important:** the DEVIATIONS-path mark site and
  `stopguard_can_mark`'s mkdir-success path were unexercised (cases 4l/4m);
  three root-conditional blocks were still unconverted `echo` skips,
  re-introducing exactly the #109 slack (6 skips converted — a root executor
  now reports the same 857 total); `_packet_block`'s last-match fix had the
  symmetric hole (a decoy AFTER a broken real packet read clean — the
  after-decoy test went red on the code as shipped), now EVERY-match: any
  fence carrying the packet marker must teach every field; dead `return
  None` removed. **Boundary tightened:** the classifier's window edge pinned
  at the measured crossover (gap 98 inside / 99 outside) instead of 125/19 —
  an off-by-one in the slice now flips exactly that pair. `FLOOR_shell`
  855 → 857.
- **The declined finding, taken (#124 follow-up):** `stopguard_can_mark` now
  tests WRITABILITY, not bare existence, of `.stopguard/` — a read-only dir
  previously made the loop-guard polarity decision on a false premise
  (existence said markable; the write then failed). Case 4n pins it both ways
  (read-only → pre-#116 stand-down; writable → gate runs), root-skipped per
  #109's counted-skip rule; mutation red on the existence-only revert.
  `FLOOR_shell` 857 → 858.

- **Fixed #123 — the #116 `.stopguard` marker's three gaps.** All three
  measured against `b61217b` by the review session that filed the issue, and
  reproduced locally before fixing:
  **(A)** the own-continuation stand-down kept the marker, so a later foreign
  continuation inherited it and read as ours — the stand-down now SPENDS the
  block (`stopguard_clear` before `exit 0`). **(B)** the reader used bare
  `[ -f ]`, which follows a symlink — any link at the marker path pointing at
  a regular file disarmed the guard; the reader is now `-L` before `-f`, the
  sixth site of the `pending/<id>` type-test convention. **(C)** an
  unmarkable project (a non-dir at `.stopguard/`) blocked every continuation
  forever — a session that cannot end, which the hook's own header forbids;
  the polarity is now deliberate and written in the code: such a project
  stands down as pre-#116 on `active=true` (the ordinary-stop gate is
  unaffected), the write failure is SAID on stderr, and an EMPTY session id
  is explicitly not the C case (a no-session payload never owned a marker;
  treating it as unmarkable was the #116 disarm through the back door —
  caught by case 4d going red on the first cut). Five cases (4i-4k), each
  mutation red in the bash suite (A: 2, B: 1, C: 1); `FLOOR_shell` 850 → 855.

- **Counted `skip()` in the shell suite — the floor is executor-invariant
  (#109).** `tests/test-scripts.sh` gains a `SKIP` counter and a `skip()`
  helper; every executor-conditional block now owes ONE skip per check it
  replaces (the block-level `echo "SKIP …"` hid the count from the floor
  arithmetic). The summary line carries a third group (`N skipped`);
  `gate-suite.sh`'s marker regex takes it optionally and the floor is taken
  against **passed+skipped**. `FLOOR_shell` 832 → 850 — AT the true total,
  so the permanent root/macOS spread stops being slack a deletion can hide
  in (measured both executors: 850/0/0 full-PATH; 843+7 on a git-less,
  Apple-python3 PATH — the restricted run also exposed that Apple's system
  python3 sets `pycache_prefix` and never writes `__pycache__` beside
  sources, so the #23 stale-pyc block is now gated on that with 5 counted
  skips instead of failing on the fixture). Three wrapper cases pin the new
  arithmetic; mutation red (wrapper ignoring skips fails the count case).
  F121-class note: the marker contract moved, and the rung coupling row
  follows it.

- **Convention (#111): "mutation-checked" names the gate that went red.**
  Bare "mutation-checked" records that SOMETHING fired — a shell mutation can
  go red in the bash suite while the validator pin written for it stays
  vacuous. The coupling-table rule now requires the granularity the python
  suite already asserts (`test_autobar_missing_z_flag_fires` names its
  check); the four bare sites in CLAUDE.md are retrofitted with their gates.
  PLAYBOOK's "Verifying a fix" gains step 5 (purge `__pycache__` between
  mutate and restore — a byte-identical restore kept executing the mutant
  from a stale `.pyc` whose embedded mtime still matched, measured during
  the #113 audit) and step 6 (the naming rule itself).

## [0.11.9] - 2026-09-04

- **Docs: CLAUDE.md char diet (60,237 → 33,922 chars).** The harness injects
  the project CLAUDE.md whole into every session and warns above 40.0k chars;
  the file had crept to ~60k by 0.11.8 with nothing in the repo reading that
  number. The long why-narratives that had accreted back into the coupling
  table cells (the 0.11.2 extraction, repeated) moved byte-faithful to
  `docs/LANDMINES.md` under "Extracted from the coupling table (0.11.9)";
  every row keeps the coupling, all 53 unique `_"…"_` citations, and a
  pointer. New validator pin `check_claude_md_size` (cap 38,000 chars —
  headroom under the clip, the F19 lesson: a cap without a gate is a target),
  mutation-verified red on the pre-diet file and green on the result, with
  `ClaudeMdSizeTest` (5 cases; fires/boundary/absent/real-tree/cap-under-clip).
- **Fixed #116: the Stop-hook loop guard no longer disarms on a sibling's
  continuation.** `stop_hook_active` is a harness field every Stop hook
  receives — cc-repete's loop sets it on every Stop it blocks, so the old
  `[ "$active" = "true" ] && exit 0` disarmed the evidence gate for an entire
  active loop after its first turn (fail-OPEN silent disarm, the worst
  class). The guard now distinguishes my own continuation (per-session
  marker `.operator/.stopguard/<sid>`, stamped by every blocking exit 2,
  cleared by the allowing exit 0, wiped by SessionStart beside `.autobar/`)
  from someone else's — the latter runs the gate normally and says so on
  stderr. Marker is advisory and fails safe both directions. Cases 4d-4h in
  the bash suite (foreign continuation blocks, own marker stands down,
  marker write/clear lifecycle, deviation-block stamps too); mutation run
  red (old guard restored → the foreign-continuation case fails). Coupling
  row + LANDMINES narrative added; REPLAY-CHARTER's R2 expectation updated
  to the #116 shape.
- **Household slimming (the diet's other half).** Removed maintainer-local
  audit scaffolding that had drifted into the tree: `AUDIT_LOG.md`,
  `AUDIT_STATE.md`, `docs/DEBLOAT-0.10.md`, `docs/audit-2026-08-31-principal.md`,
  `docs/audit-2026-09-02-principal.md`, and `docs/spec/backlog-charter.md` —
  all live in git history now, the same pattern as the 0.3.0 removals.
  `docs/spec/TAGS.md` moved to `docs/TAGS.md` (the dir emptied), with its
  pinned references updated: `check_charter`'s path + messages, the python
  fixture, CLAUDE.md's map + provenance, `commands/tiers.md`, LANDMINES,
  UNKNOWNS. Validator + all four suites green.

## [0.11.8] - 2026-09-04

The validator made honest about what it actually read (#110, #114, #115) —
two measured fail-open defects fixed, both in the class where a pin reports
green about a set it never read. Two more of the same class were found in
the first fixes themselves and are fixed here too (PR #118's own review).

### Added

- **`CheckRegistryTest` (#110)** — every defined `check_*` must be registered
  in `CHECKS`. A check defined and never registered was invisible to both the
  build and the good-tree test (which deliberately iterates the registry);
  today the two agree at 31/31, so this is a latent hole closed, not a live
  defect. Both mutations red, reordering proven free.
- **`docs/PLAYBOOK.md` "writing a locator" (#114)** — the empty answer is not
  a negative answer, generalised from `_tool_loops` and the probe rule: a
  locator that finds nothing reports; a parity pin over two located things
  reports each missing side by name; a fixture string is not a carrier; the
  mutation owes its anchor.

### Fixed

- **`check_coupling_case_refs` resolved citations against ANY line under
  `tests/` (#115)** — so this repo's own fixture, which reused two real case
  titles as sample data, satisfied the production citations and a rename
  mutation ESCAPED (found live while building the check). Citations now
  resolve only against CARRIER lines: suite `check`/`-- Case`/`# ---` lines,
  node assertion titles including their continuation lines, python
  `def test_`/`assertFires(` lines. Measured: renamed real case + planted
  fixture string stayed green before, fires now. The first cut's continuation
  carve-out accepted ANY quote-only line, which made a data literal inside
  `for (const cmd of […])` a carrier — the same escape reopened by the fix,
  caught in this PR's own review; a continuation carrier must now trace to
  an open `ok(`/`throws(` head, and `assertFires(` carries a synthetic pin.
  Round 2 of the review found the carve-out's window close had an unpinned
  `)` disjunct and dropped the two-string continuation the suites really
  write (`throws(fn, "title", "expect")` — 26 lines in test_workflows.mjs);
  both pinned, each mutation red.
- **`check_workflows`' meta locator could not read the inline-closed meta
  shape (#114)** — the regex required the closing `};` on its own line, the
  good-tree fixture closes inline, so every fixture-based meta-pin test was
  testing nothing and a computed meta in a one-line block passed every pin
  (A/B measured: `located=False` before, fires after). A locator that stops
  locating now reports instead of skipping. The widened regex then stopped at
  the FIRST `};` — one inside a meta string truncated the block and every
  computed tail after the cut was invisible (found in this PR's own review);
  the locator now walks the object with string-aware brace depth and ends at
  the balancing `}`, quotes skipped.
- **`check_guard_parity`'s F17 arm reported only a missing `retro_gate`
  scanner (#114)** — deleting `--reconcile`'s said nothing, and half a
  comparison is satisfied by deleting the other half. Each side reports by
  name; mutation red through the real fixture.
- **The floors integer check mis-parsed under bash 3.2 (#118)** —
  `$(case …)` with a glob-bar pattern breaks inside command substitution on
  macOS `/bin/bash` (CI's bash 5 is fine; shipped green at 0.11.7 and failed
  only on a Mac executor). Plain `case` + variable; verified pre-existing by
  minimal repro at the base commit.
- `.repete/` in `.gitignore` beside `.reload/` (#117 item 1) — `autobar`
  counts changed paths and an untracked sibling state dir feeds the arm
  decision. Widening the autobar pathspec stays a separate decision.

### Changed

- **"mutation-checked" now names the gate that went red (#111, convention
  half)** — "red somewhere" is not coverage: a shell mutation can go red in
  the bash suite while the validator pin written for it stays vacuous. The
  python cases already assert the specific check fires; CLAUDE.md's prose
  owes the same granularity.
- `FLOOR_python` 315 → 333: the eighteen cases this change adds. Executor-
  invariant (no skipIf/skipTest in the python suites), so the floor can sit
  at the observed count.

## [0.11.7] - 2026-09-03

Three unenforced claims made enforceable, after reading
[coleam00/ai-software-factory](https://github.com/coleam00/ai-software-factory)
(`51778f6`) — a sibling project whose `docs/incidents.md` reaches the same
conclusions this repo reached separately, and names three we had not.

### Added

- **`tests/floors.env` — the ratchet.** The ONE declaration of every suite's
  case floor. Until now the only floor here was PROSE, in a comment above the
  shell-suite step in `.forgejo/workflows/validate.yml`, claiming 683 cases on
  macOS and 675 in a rootful container. Measured 2026-09-03 in a rootful
  container: **820**. Stale by ~145 cases, and nothing noticed, because nothing
  read it. Deleting a hundred cases shipped green through every CI path.
- **`scripts/gate-suite.sh` — the rung runner.** Every suite now runs through
  it, in all four workflow files and `scripts/ci-local.sh`. Two claims a suite
  cannot fake: its completion MARKER must appear in the output (exit 0 is also
  what a step that ran nothing returns), and its case count must clear the
  floor. A summary reporting failures while exiting 0 is refused too.
- **`validate_plugin.check_suite_floors`** — a floor per counted rung, ONE
  declaration (no floor literal may be re-stated in the wrapper), a live
  `gate-suite.sh <rung>` step in every CI file, no raw invocation bypassing it,
  and four EXECUTED probes against the shipped wrapper including the
  accepts-the-ordinary-case control.
- **`validate_plugin.check_coupling_case_refs`** — every `_"…"_` citation in
  CLAUDE.md must resolve, line-wise and ellipsis-aware, in `tests/` or in
  `docs/LANDMINES.md` (classified by the surrounding prose, not by the string).
  53 citations, nothing read them, and CLAUDE.md's own note says a table that
  points at the wrong case is worse than one pointing nowhere. Fewer than 40
  citations found is itself a finding.
- **The issue register as a cross-repo, cross-session rule** (CLAUDE.md): every
  identified-but-unimplemented gap is filed as an issue before the session ends,
  in the repo that owns the fix, cross-linked both ways.

### Fixed

- `check_release_gates_cover_validate` compared raw suite PATHS, so moving every
  rung behind `gate-suite.sh` emptied it: `vsuites` came back empty and the
  superset test passed vacuously against a release job running nothing. It now
  compares the invocation. Caught by its own mutation, one commit after being
  introduced — a wrapper is exactly the indirection that empties a check aimed
  at what it wraps.
- Both release workflows now carry the floors and markers too, keeping the
  publishing job a superset of the PR job (#38).


## [0.11.6] - 2026-09-02

A second principal-architect audit (2026-09-02, autonomous), targeted at the
0.11.4/0.11.5 remediation itself. Five findings (F135–F139, ledger in
`AUDIT_LOG.md`), each fix landed with the test run RED against the pre-fix
code; the run-1 backlog's P1 item #103 gets its procedure and a tool.

### Fixed

- **An EMPTY task id opened the gate silently (audit F135).** Readers split
  `pending/<owner>__<task>` on the first `__`, so `sid__` and `__` yield an
  empty task id. `scan_pending` counted such names as MINE — the statusline
  rendered `op[N]` red — but appended `""` to `MINE_IDS`, and the Stop hook
  blocks on that LIST: with only such names pending it returned 0 with no
  message while the bar said blocked. Pre-existing (measured on the pre-#99
  code); F118's class. The empty id joins the MALFORMED bucket, fail closed,
  with the `rm -f` remedy; the hook's sentence names both shapes.
- **The CLIs and the Stop hook disagreed about what a malformed name IS
  (audit F136).** Every CLI resolved a task id with the glob `*__<id>`, whose
  `*` spans a `__`, so a planted `A__B__C` was task `C` to the CLIs and task
  `B__C` to the hook: `ops-task.sh C` reported "already open" (rc 0) for a
  task never opened, `ops-verdict.sh C` refused it as foreign, and
  `ops-adopt.sh --owner <me> C` RENAMED it into a well-formed `<me>__C` —
  which also made #99's "no CLI can address it" false. All four lookup sites
  (`sentinel_for`, both `sentinel_path`s, the post-rename dup loop) now
  filter on the task half of the match; `check_guard_parity` pins each
  literal (4 red subtests with any one removed).
- **`ops-init.sh`'s atomic gitignore write had no pin (audit F137).** The PR
  #97 review made both writers temp+mv; only the hook's swap was pinned, and
  reverting init's to the heredoc-onto-the-live-file shape reported "all
  contracts hold" (measured). Pinned, with the red python case.
- **`docs/REPLAY-CHARTER.md` R2b quoted the pre-#94 relative Stop message as
  the expected verbatim shape (audit F139)** — a live replay would have
  reported a defect on a correct hook. Now the absolute single-quoted shape.
- **`.claude/hooks/shellcheck-edited.sh` could not lint itself (audit
  F138):** its second line began `# shellcheck-…`, which shellcheck parses as
  a directive and rejects.
- **A pin-auditor pass over the ten validator pins added in 0.11.4/0.11.5**
  (each mutation re-run by hand): nine fire on their named escape; four
  repairs landed, each with its red python case. **F140 (P2):**
  `check_claims`' F129 pins were substring tests on `matches_protected`'s
  body, so the exact escape the pin's comment names — `return 1` as the first
  body line, literals intact — shipped "all contracts hold"; the pin now
  EXECUTES the shipped matcher in a child bash against one probe per
  protected token and two unprotected paths. **F141 (P2):** a workflow `meta`
  computed by a call expression (`name: String("crawl").trim()`) passed the
  validator and all three suites while the harness refuses it at launch — the
  `+` and template-literal pins were two spellings of "computed"; a
  structural pin now allows only literal values once strings are stripped.
  **F142 (P3):** a legal source line with a trailing comment failed the build
  as "does not SOURCE"; both source pins tolerate it. **F143 (P3):** a second
  `sentinel_owner_of_name()` appended to `lib/partition.sh` went unreported —
  the reader-arm pin's `pass` claimed another site reports it, none did.

### Added

- **`scripts/ops-reverify.sh` — the #103 procedure, as a tool.** Dates every
  `VERDICTS.md` row by its stamp's HEAD window (commit date of the sha to the
  commit date of its first descendant toward HEAD, open-ended when none) and
  lists the rows overlapping a date window — default the F120 defect's outer
  bounds, v0.10.0 (2026-08-22) to v0.11.4 (2026-08-31). Undatable rows
  (`@no-vcs`, an unknown sha, no git) are listed as such, never as clear;
  exit 1 when anything needs re-verification; it never writes. The
  re-verification steps (re-run the criterion, append a NEW row through the
  single writer, never edit the old) are in the footer and in
  `docs/PLAYBOOK.md`. A maintainer tool like `ops-backlog.sh`: not in the
  install set, not charter-referenced.
- **The six sibling vacuities the audit deferred are now executable pins
  (F144).** The pin-auditor arm listed six "the literal is present, the
  behaviour is gone" siblings and logged them as residual: each was still
  caught by another suite, so no hole was open, but the validator described a
  contract it was not testing. All six are closed — and closed by RUNNING the
  shipped code, not by adding six more greps, which is the enumeration
  F140/F141 argue against. `check_guard_parity` executes
  `check_bare_name`/`check_owner_name` per CLI (escape: a dead `?*) : ;;` arm
  before the real arms — `case` takes the first match and `?*` matches
  everything, so all four rejections stopped while every pinned literal stayed
  on the page); `check_autobar` runs `autobar_count_changed` against a scratch
  repo (escape: `-uall` moved into a TRAILING comment, which `shell_code()`
  does not strip — the same probe covers the `':(exclude).operator'` pathspec,
  which had NO pin at all, and without it the counter arms on the gate's own
  sentinel writes); `check_compressor` imports the module and runs scrub
  through `compress()` (escape: an unanchored regex live plus an anchored copy
  in `if (false)` — both F120 pins green, F120 restored);
  `check_decisions_schema` parses the emitted ROW's kind cell (escape:
  `HANDOFF-MARKX`, which no reader matches, while the correct literal survived
  in a die message); `check_install_set_parity` requires the manifest loop's
  BODY to copy (escape: a `do :; done` decoy beside a hardcoded-list loop);
  and `check_gitignore_parity`'s detection pin keys on the target BEING the
  live path (escape: retargeting to `"$_gi.v1.bak"`, which is not a `.tmp`, so
  #102's exclusion let it through — and which inverts the branch, since the
  backup does not exist until the migration this read triggers has run). Each
  carries its measured escape as a red python case beside a green control, and
  each probe asserts the ordinary input still PASSES — rejection probes alone
  are satisfied by a guard that refuses everything. An unrunnable probe is
  reported as a failure, never skipped. Writing the install-set pin reproduced
  the bug one level up: a non-greedy `do…done` regex paired the decoy's head
  with the real loop's body and reported "all contracts hold" on the mutation
  it was written to catch (`do`/`done` are bracket-matched now) — the method
  applies to the pin you are currently writing.
- **Reviewing those pins found four defects IN the probes (same release).** An
  executable pin has failure modes its subject does not, and three of these are
  classes a substring pin cannot have. (1) **No timeout, inherited stdin:** a
  guard containing a bare `read` blocked the probe forever and
  `validate_plugin.py` never returned (measured, killed at 20s) — a gate that
  HANGS reports nothing at all, which is worse than one that fails. (2)
  **`FileNotFoundError` raised instead of reported:** on a machine without node
  the compressor probe took the whole validator down with a traceback, leaving
  every other contract unchecked because one optional interpreter was missing.
  (3) **The probe measured the developer's machine:** the autobar scratch repo
  inherited the caller's git config, so a global `core.excludesFile` listing
  `newdir/` FAILED the build against correct shipped code — a false positive
  trains the same ignoring as a vacuous pin, reached from the other side. (4)
  **`rc != 0` is not "refused":** renaming an arm's `die` to an undefined
  `refuse` exits 127 (`command not found`) and READ AS REFUSED while the real
  CLI would die at every call — the new pin had the same vacuity as the pins it
  replaced, and its own predecessor (F140's claims probe) had compared exact
  codes from the start. All five probe sites now go through one `_run_probe`
  helper: `stdin=DEVNULL`, `timeout=30`, missing-interpreter and timeout both
  REPORTED, git config pinned to `/dev/null`, and exact exit codes. Each fix
  was re-measured against the case that found it, and each carries a red test.
- **And three more in `_tool_loops` itself — the helper written to fix a
  vacuity had three of its own.** When a pin needs to PARSE, the parser is part
  of the guarded surface. (a) Counting the bare words `do`/`done` is not
  lexing, and English contains both: `echo "nothing to do here"` opened a
  phantom nesting level and swallowed the next loop whole, whose `cp` then
  satisfied the body check — an install loop copying nothing shipped "all
  contracts hold" against the real `ops-init.sh`. The mirror image, `echo
  "install not done yet"`, closed the loop EARLY and truncated the body
  mid-string — a false FAIL on correct code, and the truncated text still
  contained "install", so the check matched PROSE rather than a command.
  Comments and string bodies are masked before the scan now (offsets
  preserved), and a body cannot extend past the next top-level loop head, so
  overshooting fails CLOSED. (b) `if _loops:` was the wrong polarity: the head
  regex only matches an iteration variable named `tool`/`_tool`, so renaming it
  returned `[]` and both arms silently never ran — the F130 head pin still
  fired on the measured shapes, so no gate was open, but the check said nothing
  about why it had stopped applying. No candidate loop is now a finding. Each
  carries a red case, and each direction has its negative control: reflowing,
  reordering equivalent arms, a legitimately nested loop and a reflowed `git`
  call are all proven FREE, because a pin that fires on everything is as
  useless as one that fires on nothing.
- **`docs/spec/TAGS.md`'s `spec-concurrent` entry names the parse rule.** The
  entry described the name convention; two reader populations now depend on
  it, so it states the FIRST-`__` split as THE rule, both no-valid-parse shapes
  (double separator, empty half) with their name-level `rm -f` remedy, and the
  four CLI glob sites whose task-half filter re-imposes the readers' rule on a
  glob whose `*` spans a `__`.

## [0.11.5] - 2026-09-01

Four self-contained items from the 2026-08-31 audit backlog. Every fix ships
with the pin that would have caught it, each run RED against the defect it was
written for and GREEN against the restored tree.

### Fixed

- **A malformed sentinel name got a remedy that could not run (#99, audit
  F118).** Readers split `pending/<owner>__<task>` on the FIRST `__`, so a
  planted `A__B__C` parsed as owner `A`, task `B__C` — and `B__C` is a task id
  every writer CLI refuses, because `__` is the separator. The gate named
  `ops-verdict.sh 'B__C' --defer`, which dies on the CLI's own guard: the
  operator was told to run a command that errors. `scan_pending` now buckets
  such names as MALFORMED (fail closed, matching the unowned default) and the
  Stop hook names the one remedy that works — `rm -f` on the sentinel's
  absolute, single-quoted path. The statusline counts the bucket as blocking,
  so the bar and the gate still describe the same thing.
- **The compressor's elide cut mid-codepoint (#101, audit F123).**
  `HEAD_BYTES`/`TAIL_BYTES` are size bounds with no reason to fall between
  codepoints, and `Buffer.subarray(…).toString("utf8")` over a half-sequence
  decodes to U+FFFD, so every elided multibyte output carried mojibake at both
  seams. The cut now backs off to a UTF-8 boundary, which also makes the head a
  true prefix of the input — the offset `elide` uses to find the middle.
- **`commands/handoff.md` prescribed a relative CLI path (#100, the residue of
  audit F102).** The Bash tool's cwd persists across calls, so
  `.operator/bin/ops-verdict.sh` pasted from a subdirectory is file-not-found,
  and the field history for that shape (#94/#95) is the model then reporting a
  PRESENT gate as absent. The command now routes to the absolute path
  SessionStart or the Stop hook already printed, with `git rev-parse
  --show-toplevel` as the fallback when neither is in context.

- **Review of this release (PR #104) found the malformed remedy printing the
  wrong path.** The MALFORMED paths travelled as a `"; "`-joined string and the
  Stop hook split on the same literal, so a project whose path itself contained
  `"; "` was cut there: `rm -f '/work/proj'` and `rm -f 'x/.operator/pending/…'`,
  two confident lines, neither the sentinel, one aimed at whatever sits at the
  cut (measured). The carrier is now a bash array; the two-sentinel case on a
  `"; "` path runs 4 red on the old carrier. A FOREIGN-owned malformed name —
  the "blocks where the old code reported foreign" widening the prose claimed
  but nothing pinned — now has its own case (2 red with the bucket removed).
- **`commands/handoff.md`'s grant did not cover the path it prescribed** (PR
  #104 review). The body said ABSOLUTE; `Bash(.operator/bin/ops-verdict.sh:*)`
  is a literal prefix no absolute invocation starts with, so the model hit a
  permission prompt. `Bash(bash:*)` is added and the body prescribes
  `bash '<absolute path>' --mark-handoff …`. The fallback for a session with
  no printed path names the walk-up rule and non-git (`@no-vcs`) projects
  rather than a bare `git rev-parse`. The #100 pin now matches the relative
  CLI in ANY markup — a fenced copy of the old command passed the
  backtick-anchored form.
- **The compressor's byte helpers are unit-swept** (PR #104 review): a 2-byte
  width joins the elide sweep, and `headBytes`/`tailBytes` are exported so
  every `n` in `[-2, len+2]` is checked for prefix/suffix, bound, ≤3-byte
  back-off and no U+FFFD — through `compress()` those guards were unreachable
  at default sizes. 29 red on the pre-#101 helpers.

### Changed

- **The atomic gitignore write is pinned on its own, and the CONFIRMATION pin
  is unconditional** (PR #104 review). The confirmation pin was gated on
  `".v2.tmp" in text`, so removing the temp entirely — a non-atomic
  `cat > "$_gi"`, the pre-0.11.4 F119 shape — removed the check with it. It
  still fired only because the user-facing notice mentioned the temp; with that
  one prose line reworded the validator reported "all contracts hold" over a
  non-atomic write (measured, two-place mutation). A new pin keys on the
  `mv -f "$_gi.v2.tmp" "$_gi"` swap itself; both shapes have a python case.
- **`check_gitignore_parity` tells the DETECTION grep from the CONFIRMATION
  grep (#102).** Both writers grep for the v2 marker, and since the atomic
  rewrite the hook does it twice — once on the live file to decide "is this
  still v1?", once on `$_gi.v2.tmp` to confirm the write landed. The pin
  matched either, so a mutation removing only detection — after which a v1
  blocklist is never migrated at all — shipped green. Each is now pinned by its
  target, and each is knocked out on its own in its own case.

## [0.11.4] - 2026-08-31

A principal-architect audit (2026-08-31, autonomous) — 34 findings, all logged
with evidence in `AUDIT_LOG.md`; every fix landed with a test run RED against
the pre-fix code.

### Fixed

- **The compressor's "lossless" scrub tier was destroying output (P0, audit
  F120).** The 0.10.0 debloat stripped the raw ESC bytes out of `scrub()`'s two
  ANSI regex literals; without the `\x1b` anchor the OSC pattern's empty
  alternation matched from the first bare `]` to end-of-string, so virtually
  every real `]`-bearing tool output over 1KB was silently replaced with
  garbage (measured: a 3KB `[ok]…[FAIL]` log came back as the single character
  `k`) — no marker, no spill, suite green because no test input contained a
  bare `]`. Anchors restored as escapes, identity-on-plain-text and
  real-ANSI-strip tests added, and `check_compressor` now pins both anchors.
- **SessionStart resolves the project by walking up, like the Stop hook (audit
  F101/F102).** The exact-match `$cwd/.operator` made the hook a silent no-op
  from any subdirectory — no id banner, no legacy migration, no `bin/` upgrade,
  no ephemera wipes. The banner also prescribes ABSOLUTE single-quoted CLI
  paths now (the #94 shape).
- **Seven vacuous validator pins now fire (audit F126–F130, F132–F134).**
  Mention-satisfiable sourcing pin (a comment naming `partition.sh` passed a
  gutted hook), presence-only guard-parity pins (a `check_owner_name(){ :; }`
  shipped green), a prefix-satisfiable install-set loop pin, raw-text
  kind/marker pins, a missing `-uall` pin, a template-literal meta escape, and
  comment-view compressor defaults — each repaired pin carries its exact escape
  as a red python test beside a green control.
- **Workflow hardening (audit F103–F110).** debate: agent output can no longer
  overwrite a seat's pinned letter/model/dead (spread first, pin last);
  brainstorm: zero surviving directions error-returns before the judgment-tier
  converge is paid, and results carry `directionsRequested`; crawl: shard path
  ELEMENTS must be non-empty strings; review: the adversarial seat carries the
  untrusted-data rule and OBSERVED_HEAD provenance, and a non-array `findings`
  no longer kills the paid panel; plan: vet rows carry `taskIndex` so duplicate
  ids stay distinguishable.
- **`release_gate.py` (audit F131):** the section terminator no longer
  truncates notes at a body line starting with `[`, and definitions inside
  code fences/spans no longer count as resolving a reference.
- **The gitignore migration's failed-write notice is now enforced, not just
  written.** The atomic temp+mv rewrite (above) removed the truncated-live-file
  shape and added `_gi_write_failed`, but nothing tested that the notice fires
  or pinned it against removal — and a flag nothing reports is the same silence
  the third state was found in (measured on the pre-atomic hook: a backed-up
  file with a failed write exited 0 with no gitignore line in
  `additionalContext` at all). `check_gitignore_parity` now pins the flag AND
  its report as two separate claims, and a bash case drives the real trigger (a
  non-regular entry at the temp path) with a success control. `ops-init.sh`
  needs no flag: `set -e` kills it on the failed write, loudly.
- **The F102 banner cases could not pass on macOS.** `newproj()` returned
  `mktemp -d`'s unresolved `/var/folders/...` path while every hook and CLI
  resolves through `cd -P` to `/private/var/folders/...`, so four correct
  absolute-path assertions failed against a correct banner. The helper now
  returns the resolved path, which is what the code under test always sees.
- Smaller: neutral elide marker + honest no-spill wording (F121), symlinked
  `.operator/` refused by the compressor (F122), gitignore-migration success
  probed by exit status + marker (F119), statusline byte-bounded tail window /
  guarded lib source / honest header (F124/F125/F117), brace-wrapped fallback
  holder read in both LOCK BLOCK copies (F116).

### Docs

- CLAUDE.md coupling table repaired (`DECISIONS_KINDS` never existed; the
  install-set map bullet now points at the manifest) and extended with rows
  for the scrub anchors and the hook walk-up; README gains the debate row
  ("Six workflows"); `commands/tiers.md` stops citing two spec files that
  exist in no checkout; new landmine narratives and a playbook procedure for
  renaming validator constants; the full audit ledger ships as
  `AUDIT_LOG.md` + `AUDIT_STATE.md` and `docs/audit-2026-08-31-principal.md`.

## [0.11.3] - 2026-08-28

0.11.2's own release test found the half of #94 that fix did not reach.

### Fixed

- **The gate CLIs resolve the project by walking up, not from cwd (#95).**
  `ops-task.sh`, `ops-verdict.sh` and `ops-adopt.sh` set `OPDIR=".operator"` —
  relative to the *caller's* cwd — so they worked from the project root and
  nowhere else. 0.11.2 made the Stop hook prescribe an ABSOLUTE path to
  `ops-verdict.sh`, which resolves fine from anywhere, and the pasted command
  still failed from a subdirectory:

  ```
  $ cd 'a project/apps/viewer'
  $ '…/a project/.operator/bin/ops-verdict.sh' --mark-handoff --owner FRESH
  ops-verdict: missing .operator/DECISIONS.md — run ops-init.sh first
  rc=2
  ```

  The absolute path said where the CLI *lives*, never which project it
  *serves*. The three now walk up to the nearest ancestor holding `.operator/`
  and `cd` there — the same resolution `ops-stop-hook.sh` has always used,
  bounded the same way: stop at a `.git` boundary (a nested repo is its own
  project) and at the filesystem root, `pwd -P` so a planted symlink cannot
  redirect the walk.

  `cd`, not an absolute `OPDIR`: the source stamp's
  `git status --porcelain -- ':(exclude).operator'` pathspec is **repo-relative**,
  so the reflex fix leaves every ledger path looking correct while silently
  pinning every row written from a subdirectory to `+dirty`. That variant is
  mutation-measured — it fails only the two stamp controls — and is now refused
  by `check_root_parity`, which pins the block across all three copies plus its
  canonical contents (uniform drift is what parity alone cannot see, F30).

  The not-found message says the walk happened: "no `.operator/` here or in any
  parent up to the repo boundary". The old "in cwd" sent the operator to the
  wrong diagnosis — they *are* in the project, just not at its root.

### Notes

Three script mutations (revert the block, the absolute-`OPDIR` reflex fix, drop
the `.git` boundary) and four validator-pin mutations, each red against the case
written for it, each restored. Suites: 740 bash (was 726), 354 node, 90
compress, 229 python (was 222), validator green.

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
  `statusline.sh`'s `PROJ` resolution falls back to `$PWD` — an explicit
  `${CLAUDE_PROJECT_DIR:-$PWD}` default, so intended, though the file gives no
  rationale for it (the comment above it documents the preference *order*,
  payload first, which is a different claim); the repo had simply never had
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

Older releases (0.1.0 – 0.8.4) live in [docs/history/CHANGELOG-archive.md](docs/history/CHANGELOG-archive.md).
