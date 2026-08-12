# Changelog

All notable changes to **cc-operator** are recorded here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/).

The version in [`.claude-plugin/plugin.json`](.claude-plugin/plugin.json) is the
single source of truth; bump it in the same commit as the changelog entry.

## [Unreleased]

## [0.7.1] - 2026-08-12

### Added — `--expect-clean` reports the ignored state it cannot check

- **`ops-claims.sh --expect-clean` now emits a second evidence line** naming how
  many gitignored entries the tracked-tree check did not cover, and the command
  to list them. Porcelain describes the **tracked** tree by design, so the whole
  gitignored family — bytecode and build caches, `node_modules`, `.venv`, an
  editable install, a gitignored `.env`, a warmed fixture DB — is invisible to
  it. That invisibility is the mechanism of [#23], not a bug in the check.
  - **Report, never fail.** 34 of this repo's ignored entries are legitimate
    (`.archive/`, `.serena/`, `docs/audits/`, the pilot seeds); failing on them
    would make the check unusable and it would be turned off, which is the
    vacuous-guard class ([#21]) arriving by a different door. What the line buys
    is **scope**: a verdict citing `--expect-clean` now carries what "clean" did
    not cover.
  - **`--ignored=matching`, not the `traditional` default**, measured before
    choosing: traditional expands every file below an ignored directory — 204
    lines here versus 34. One summary line rather than one per entry, for the
    same reason. A line nobody reads is the same failure as no line.
  - A failed git read degrades to the count `unknown`, never to silence and
    never to 0: "git could not tell me" and "there is nothing" are different
    answers and only one is safe to read as clean.
  - **That degradation shipped unreachable and was caught by this release's own
    review panel.** The first draft ran the whole pipeline in one substitution
    and post-hoc tested the captured string for non-digits — but `grep -c` on
    empty input PRINTS `0` and exits 1, so a git that died at 128 was
    indistinguishable from a clean tree. Measured on two independent failures
    (`GIT_INDEX_FILE` pointing at a non-directory; a truncated `.git/index`),
    both reporting `report: 0` with rc 0 — fail-toward-the-strong-claim, the
    polarity `docs/PLAYBOOK.md` forbids and the comment above claimed to avoid.
    Git's exit status is now captured before any counting; git must be the last
    command whose status is read, because a pipeline hands back grep's.
    - Fixing it exposed a second one: this file runs under `set -e`, so a bare
      assignment carrying git's 128 killed the script outright (RC=128, the
      report line never printed). Now the `&& rc=0 || rc=$?` form
      `ops-verdict.sh:source_stamp` already uses.

### Added — the [#23] contamination class gets an in-tree fixture

- **Five cases prove the class the issue only described.** [#23] had read
  "Status: MEASURED" since it was filed, but the measurement lived in the issue
  text; `grep -rln` over `tests/` found nothing. The same commit now
  demonstrably verifies PASS in the builder's tree and FAIL in a clean checkout
  of that commit, with `git status --porcelain` empty throughout — because the
  contaminant is gitignored, which is exactly why the tracked-tree check cannot
  see it. The fifth case asserts the new scope line is what an operator would
  have to notice: green tree, ignored count 1.
- **The issue's own recipe does not reproduce, and the correction is measured.**
  It says equal source byte-length suffices because CPython validates a `.pyc`
  by source mtime + size. Size is the *second* field: writing the defect moves
  the mtime, CPython invalidates, recompiles, and **both sides FAIL**. The
  fixture reads the source mtime back out of the `.pyc` header (PEP 552:
  little-endian uint32 at offset 8) and applies it with `os.utime`, so the two
  agree by construction rather than by timing.
  - Not a detail: with the stamp removed the in-tree run passes **4 of 12**
    iterations — the builder run and the edit land on the same clock second
    often enough to look fixed and rarely enough to be worthless. A
    `stat`-and-restore fixture is green on a fast host and red on a slow one for
    reasons having nothing to do with the property under test.
  - Consequence for re-running discrimination on this case, recorded in the case
    itself: deleting the mtime stamp does **not** reliably flip it. The
    mutations that do are removing the builder warm-up (506/1) and un-ignoring
    `__pycache__` (505/2).
- **This does not close [#23].** The fixture proves the class and gives the
  eventual worktree isolation something to prove itself against; it isolates
  nothing. The three scoping decisions the issue names remain open.

### Fixed — `tiers.env` could not name a cc-proxy provider model ([#35])

- **`check_routable` learned the `<provider>:<model>` lens.** It knew three
  shapes — `glm-*`, `vendor/model`, `claude-*` — and cc-proxy's canonical
  spelling since 0.6.0 is a fourth. The colon was already legal by charset; the
  shape case had never learned about it, so `JUDGMENT=qwen:deepseek-v4-pro` died
  at resolve time with a message naming three spellings and omitting the one
  cc-proxy publishes. Only a workflow's `opts.model` reached those models,
  because that path does not pass this guard.
- **An allowlist, not `*:*`, and the difference is the guard.** Measured against
  cc-proxy's own `parseModelSelector`:

  ```
  qwen:deepseek-v4-pro   providerId=qwen   -> upstream: deepseek-v4-pro
  bogus:some-model       providerId=null   -> upstream: bogus:some-model
  ```

  An unknown lens is **not** stripped — it reaches the default backend as a
  literal model id, the silent mis-route this function exists to prevent. A
  generic colon rule would have admitted exactly that. `LENS_NAMESPACES` mirrors
  `PROVIDER_IDS` in cc-proxy's `src/providers.js`. The split is at the **first**
  colon, matching cc-proxy's `indexOf`, so `qwen:a:b` sends tail `a:b` and this
  agrees rather than second-guessing it.
- **And the allowlist shipped bypassable with a slash, caught by this release's
  own review panel.** The first draft tested the bare shapes before the lens, so
  `*/*` returned 0 and the allowlist was never consulted: `bogus:vendor/model`
  passed while `bogus:model` was correctly refused. cc-proxy answers
  `providerId=null` for it and sends the literal string upstream — the hole this
  entry had just described closing. The lens is now tested **first**, matching
  cc-proxy, whose `parseModelSelector` runs at step 0 of `resolve()`: an id
  carrying a colon is a lens no matter what follows it. Two negative controls
  keep the fix honest — `openrouter:qwen/x` (a known lens with a slashed model
  half) stays routable, and bare `openai/gpt-5` is unaffected.
- **Second defect, found while fixing the first: the parity check could not see
  the allowlist.** `LENS_NAMESPACES` is a file-scope assignment *outside*
  `check_routable`'s braces, so `check_resolver_renderer_parity`'s body
  comparison would rate two copies carrying **different** allowlists as equal —
  the F30 shape this repo keeps re-hitting. Now pinned by value with its own
  equality check, plus the in-body `$LENS_NAMESPACES` lookup in the fragment
  list, plus two pytest cases. Mutation-verified.
- **Discrimination is two-sided, because an allowlist can fail in both
  directions.** Removing the lens branch (the pre-fix behaviour) gives 510/4
  with the ACCEPT cases red; widening the allowlist to any namespace gives
  511/3 with the REFUSE cases red. No single mutation leaves all nine cases
  green — which is what makes the allowlist load-bearing rather than
  decorative. A `*:*` implementation would have survived the second.

### Fixed — the suites contaminated the tree they test

- **No more `__pycache__` from a test run.** A run left one in `scripts/` and
  one in `tests/`, both gitignored, so `git status` reported a clean tree that
  was not one. A suite that generates the [#23] class while shipping its fixture
  is arguing against itself. Measured per command, before → after:

  ```
  unittest discover                   2 -> 2
  pytest (bare or tests/)             2 -> 1
  bash tests/test-scripts.sh          2 -> 0
  python3 scripts/validate_plugin.py  0 -> 0
  ```

  Three sites, because no single one covers every shape: both workflows set
  `PYTHONDONTWRITEBYTECODE` at **job** level (not per step, so a later step that
  adds a python call inherits it), `tests/conftest.py` sets
  `sys.dont_write_bytecode`, and the bash suite exports it for its ~43 python3
  calls.
  - **Two residues, stated rather than papered over.** `conftest.py`'s own
    `.pyc` is written before the line that disables bytecode runs — nothing
    inside the process can prevent its own compilation. And
    `unittest discover` reads no config file at all; CI covers the build, a
    hand-run needs the prefix. The validator writes none and always did: it is
    run as a script, never imported.
  - **One self-inflicted defect fixed in the same change:** exporting the
    variable from the suite header broke the [#23] fixture, whose entire
    mechanism is a written `.pyc` (505/2, both write-path halves red). Three
    sites now unset it, kept symmetrical so the next edit cannot re-introduce
    the asymmetry.
- **`pytest tests/` stopped halting on 4 collection errors.** `pyproject.toml`
  pinned `testpaths` at exactly the two real modules, but **`testpaths` applies
  only when no path argument is given** — the documented invocation overrode the
  guard and walked `tests/pilot-seeds*/`. `norecursedirs` is the half that
  survives an explicit path. Both are kept: `testpaths` states what the suite
  **is**, `norecursedirs` states what is never a test even when someone points
  pytest at it.

### Changed

- **`CHANGELOG.md`: the `[Unreleased]` section was folded into `[0.7.0]`.** Five
  subsections described work that shipped in `be74205` — the commit v0.7.0 tags
  — and were never retitled before tagging, so `release_gate` (whose heading
  regex correctly does not match `[Unreleased]`) extracted only the `[0.7.0]`
  section. The published release body was 268 lines where the folded section
  generates 405. No published artifact was wrong — the squash commit message
  already described the work — only the changelog's attribution.
- **`CLAUDE.md` gains a `LENS_NAMESPACES` coupling row**: both copies, why it is
  an allowlist, and that both validator fixtures must track the guard's shape.

### Caught by the gates rather than by the author

Recorded because it is what the guardrails are for, and a green build says
nothing about how it got there:

- `check_portability` rejected a `date -r … || date -d …` fallback in the [#23]
  fixture — precisely the GNU-only shape it guards. Replaced with `os.utime` in
  the `python3` call the case already required.
- Adding `LENS_NAMESPACES` to the parity check's **in-body** fragment list made
  it fire on every tree (11 pytest failures, good-tree fixtures included — an
  earlier draft of this line and `679e9af`'s commit message both said 12, which
  no mutation reproduces; the review panel's comment lens caught it): that
  loop searches the function body, which by construction cannot contain a
  file-scope assignment.
- A reference-style `[#35]` in `CLAUDE.md` tripped `check_issue_refs` — the
  guard shipped in 0.7.0 — because that file writes bare `#N` by convention.
- **The review panel REFUTED this release before it shipped**, and both grounds
  were real. The adversarial seat reproduced the unreachable `unknown`
  degradation on its first attempt; the feasibility lens found the slash bypass
  in a guard added by this same release. Its second ground was procedural and
  also correct: the F-A1 tree check failed because the version bump and this
  changelog sat uncommitted while the panel ran.
  - The slash bypass scored **57**, below two findings about pre-existing path
    guards, and it was the one that reopened a hole this PR had just closed —
    an argument for reading a panel's findings rather than sorting them.
  - What the panel does **not** establish, unchanged from [#23]: every seat ran
    in the builder's own tree. A CONFIRMED from it would have been verification
    by a different reader of the same tree, not by a clean checkout.
- **A second review round found five more, two of them introduced by the first
  round's own fixes.** Recorded in that shape deliberately: a fix written under
  review pressure is not safer than the code it replaces, and this release has
  now demonstrated that twice.
  - **The ignored-state count was stuck at 1.** `-z` output captured through
    command substitution loses its NUL separators — every record joins onto one
    line and `grep -c '^!!'` answers 1 for any non-zero count. Measured: a
    3-entry tree reported 1, this repo's 34 reported 0. The two tests could not
    see it because their fixtures held exactly 0 and exactly 1 entry — a
    constant that reads as a count. Now captured to a file; a third case uses
    3 entries.
  - **The lens ordering broke OpenRouter's variant suffixes.** `vendor/model:free`
    and `:nitro` are legal ids that cc-proxy routes through `rankRoutes`; testing
    the lens first made the guard refuse them, with a message calling
    `deepseek/deepseek-r1:` a provider namespace. Measured against `origin/main`:
    pre-PR rc 0, post-fix rc 2. A slash *before* the colon now means a variant,
    not a lens — and the bypass stays closed, because there the slash is after.
  - **The `LENS_NAMESPACES` parity pin was vacuous.** Editing **both** copies to
    `"bogus"` passed the entire validator: the tuples still matched. `CLAUDE.md`
    claimed the value was pinned; it was pinned only to itself. Now pinned to a
    canonical literal, mutation-verified.
  - **The four workflows' `ROUTABLE` regex never learned the lens.** An operator
    binding `MECHANICAL=qwen:deepseek-v4-pro` in `tiers.env` — legal since this
    release — got a hard throw the moment that map reached a workflow.
    `check_workflows` could not catch it: all four copies drifted uniformly, the
    F30 shape. `docs/PLAYBOOK.md` names this coupling.
  - **The bytecode hygiene had no test at all.** Reverting `conftest.py` to a
    no-op left 2 `__pycache__` dirs with pytest still green; dropping
    `norecursedirs` reproduced the 4 collection errors while both suites passed.
    Two cases added — and the first draft of the `conftest` case did not
    discriminate either, because it inherited the suite-wide
    `PYTHONDONTWRITEBYTECODE` that hides exactly what it was testing.
- **A number in this changelog was wrong and is corrected above.** The comment
  lens re-derived every measured figure in the diff; one did not reproduce (the
  "12 pytest failures", actually 11). Every other number held, including the
  204-vs-34 line counts, the 4-of-12 mtime flakiness, the 505/2 and 506/1
  mutation counts, and the PEP 552 header layout.

### Gates

bash 526/0 from a neutral cwd (507/0 on ubuntu:24.04 as uid 1000, measured at
the [#23] commit — eleven cases postdate it) · validator 0 · pytest 178/0 ·
node 73/0 + 75/0 · shellcheck 0.11 rc 0 and pinned 0.10 rc 0.

Round-2 revert-discrimination, each mutation restoring one defect the review
found: NUL-losing capture → 525/1; variant carve-out removed → 524/2;
`conftest.py` neutered → 525/1; `norecursedirs` dropped → 525/1. Control 526/0.

[#21]: https://github.com/betmoar/cc-operator-plugin/issues/21
[#35]: https://github.com/betmoar/cc-operator-plugin/issues/35

## [0.7.0] - 2026-08-07

### Added — the arm-gate layer (opt-in): every write accountable to an open task

Three parts, each gating a different moment. The gate is **opt-in**
(`.operator/armgate.on`, absent by default) and fails OPEN on every
infrastructure failure — a PreToolUse hook that fails closed makes a project
unwritable. `Bash` is deliberately ungated (classifying shell writes is
unwinnable, and gating Bash deadlocks the repair path). The threat model is
forgetting, not evasion.

- **G1 — the retro-gate (default-on).** `ops-verdict.sh` distinguishes three
  states: armed (sentinel present), never-armed (no sentinel, no prior row),
  duplicate/amending. A never-armed verdict is recorded AND writes a
  `GATE-EXCEPTION` to DECISIONS.md — a gated kind that blocks Stop until
  presented. Never refuses real evidence. A never-armed verdict with no
  `--owner` is refused (the exception must carry a `[sid:]` tag). The prior-row
  scan is bounded by `FRAG_MAX_BYTES`.
- **G2 — the arm gate (opt-in).** New `ops-armgate-hook.sh` on PreToolUse
  (`Write|Edit|MultiEdit|NotebookEdit`): blocks a session holding no open task
  from mutating a file, stderr naming the arm command and the exemption path.
  The `.armed/<sid>` marker is a derived cache, created by `ops-task.sh` /
  `ops-adopt.sh` and recomputed by `ops-verdict.sh` (remove → rescan → restore,
  under the lock — the order that survives a task opening mid-recompute).
- **G3 — the audited exemption.** `ops-task.sh --exempt "<reason>" --owner <sid>`
  delegates the GATE-EXCEPTION write to `ops-verdict.sh --exempt-mark` (the
  opener takes no lock), and creates `.armed/<sid>.exempt` — a granted marker
  the recompute never touches.

### Added — backlog integration (CLI-independent cherry-picks)

- **B7** — `backlog/` joins the PROTECTED set (whole directory). An implementer
  that can edit `backlog/tasks/*.md` can edit the acceptance criteria it is
  judged against — the F48 vacuous-guard class relocated to the plan layer.
  Two-site F30 pin (ops-claims.sh + validator).
- **B10.1** — `ops-backlog.sh --census`: tracked-file / code-file / code-LOC
  counts (one-pass LOC, sub-1s on a 12K-file repo). A reporting CLI, not a gate
  CLI — joins the install set, not CHARTER_REQUIRED_CLIS/GATE_CLIS. Code files
  are selected by `git ls-files -- <pathspec>`, **not** by `grep -zE` ([#29]):
  BSD/macOS `grep -z` does not anchor `$` at the NUL, so a tracked filename
  containing a newline — legal in git — matched on an inner line. Measured
  before the fix on BSD grep 2.6.0: `code-files: 2 / code-loc: 5` against a
  ground truth of `1 / 2`, because a `.md` whose first line ended in `.py` was
  counted as code. GNU grep answers correctly, so a Linux run could not have
  caught it; case B10.4 pins it and must run on macOS to mean anything.

### Added — assurance-model audit pass (F67–F69)

The first audit whose handoff ships in-tree: `docs/audit-2026-08-09-handoff.md`
(every prior audit writeup was maintainer-local and never committed — which is
itself finding F68).

- **F67 (P2)** — `ops-init.sh` now warns, naming the exact rule, when a parent
  `.gitignore` excludes `.operator/` and thereby silently defeats the v2
  allowlist (git never descends into an excluded directory, so the nested
  negations re-admit nothing; measured on issue #25). Warn-never-fail: the
  exclusion can be deliberate, as in this repo's own dogfooding. Five bash
  cases, proven discriminating against the reverted script.
- **F68 (P3)** — CLAUDE.md's audit-trail pointers referenced `AUDIT_LOG.md` and
  `docs/audit-2026-07-31-handoff.md`, which exist in no commit; reworded to the
  maintainer-local rule, resolvable trail now points at the shipped handoff.
- **F69 (P3)** — `docs/HANDOUT.md` had drifted from the authorities on three
  load-bearing points: the IMPLEMENT default model, the read-only-seats claim
  (it is a tool-policy, not a sandbox — PLAYBOOK's own words), and a dispatch
  packet missing TEXT, SHA and the `CHANGED:` line that `ops-claims.sh`
  verifies. Corrected; `validate_plugin.check_handout_packet` now pins the
  packet spine whenever the handout exists, with a pytest mutation test.
- PLAYBOOK "adding a reader" gains item 5: a stamp reader takes the **last**
  `@`-token of the evidence cell and treats an unstamped row as pre-stamp
  history — provenance, never attestation (#22).

### Added — verdict rows name the source state that produced them (U10, #22)

Audit finding, reproduced before fixing: a PASS survived **unstaged, staged,
committed and untracked** mutation of the source it had just verified — the
criterion exiting 1 while the row still read PASS, the Stop hook silent through
all four (positive control: it exits 2 with an owned sentinel open). The row
named no tree at all, and `ops-verdict.sh` contained no `git` call.

- `ops-verdict.sh` now resolves a **source-state stamp** and appends it inside
  the evidence cell: `@<sha>`, `@<sha>+dirty` when anything outside `.operator/`
  is uncommitted, `@<sha>+unknown` when `git status` itself fails (an infra
  failure must not read as *clean* — that is the strong claim here),
  `@no-commit` on an unborn HEAD, `@no-vcs` outside git. Explicit in every
  branch: an **unstamped** row means "written before this existed", and an audit
  that cannot separate that from "git was missing" cannot start.
- **Inside the cell, not a fifth column.** `VERDICTS_HEADER`, every ledger in
  the field, and every grep written against the 4-cell schema keep working.
- **`.operator/` is excluded from the dirty test.** It is untracked in any
  project that has not committed its ledger — nearly all of them — so counting
  it would pin every row everywhere to `+dirty`, which is the vacuous-guard
  class (#21) shipped as a feature. Same boundary `ops-claims.sh
  --expect-clean` already draws.
- **Resolved before `lock_acquire`.** `git status` is unbounded work on a large
  repo and nothing waits on the stamp; a holder that outruns `LOCK_LIVE_SPINS`
  leaves its waiters proceeding unlocked.
- It **never refuses**: every failure path degrades to a marker, because a
  verdict is real evidence and the gate does not refuse real evidence.
- Scope, stated so nobody claims more: this is **provenance** ("this row was
  written from that tree"), not attestation ("that tree passes") — the stamp is
  written by the same process that writes the row. The staleness reader (#22
  step 2), execution isolation (#23) and external reproduction (#25) stay open.
  `--defer` is deliberately unstamped: nothing was verified.
- Pinned by `validate_plugin.check_source_stamp` (markers, exclusion, row
  format, application, ordering) and 10 `S1` cases. Both guards shipped
  **fail-open in their first draft** — each searched for the verdict-path marker
  in text it had already stripped of comments, so a mutation moving the stamp
  inside the lock passed a green build. Found by mutation, fixed in both, and
  recorded in `docs/LANDMINES.md`.

### Added — issue references are validated, not trusted

- **`validate_plugin.check_issue_refs`** — every `[#N]` in tracked markdown must
  have a matching link definition (and every definition a use, and no number
  defined twice), and every issue URL must resolve under `plugin.json`'s
  `repository` at the number its label claims. The class it pins is the
  **inverted ref**: `[#28]` pointing at `/issues/29` renders as "#28", navigates
  to 29, and survives review by construction, because the eye reads the label
  and the click follows the URL.
  - **Provenance, stated honestly: that class has never occurred here.** An
    earlier draft of this entry claimed two 0.7.0 commits shipped inverted refs.
    Measured against the history, that is wrong — `6b9fb89` wrote
    `[#28]: …/issues/28`, label and URL agreeing, and `ff57517` never touched
    this file. Their real defect was an *invented* issue number later assigned
    to a different issue, which this check cannot detect and never will. The
    check is preventive, not corrective; the justification is that modes 2 and 3
    are mechanical and mode 1 is invisible to review, not that it would have
    caught a past bug.
  - **Not checked, deliberately: that the issue exists, is open, or is about
    what the sentence says.** That needs `gh issue view` — network, token, rate
    limit — in a validator whose other subprocess is a local `bash -n`. A build
    that fails because GitHub is slow teaches maintainers to skip the build.
  - **Bare `#N` is out of scope, by measurement.** Tracked docs write
    `Backlog #2`, `task #1`, `F48 #5`; requiring those to be linked would force
    wrong links or an exception list. A test pins the scope decision so a later
    "tighten it up" edit fails instead of quietly breaking prose.
  - Code spans and fenced blocks are stripped before parsing: prose that
    *quotes* a reference to document it is not a reference. This entry is the
    proof — without stripping, its own backticked example counted as a use.
  - A file git tracks but cannot be read is **reported**, not skipped. Sparse
    checkouts list index entries whose files are absent from the working tree;
    swallowing that made the gate cover less than it claimed (measured: a
    foreign-repo link in a sparse-excluded file produced zero problems).
  - Scope is `git ls-files '*.md'`, falling back to a dot-skipping glob so a
    non-checkout cannot make the check vacuous. That fallback is a superset only
    while no tracked `.md` lives under a dot-directory — true today, not
    guaranteed.

### Fixed — review-pass findings, each reproduced before fixing

Six defects found by the PR-review agents and `/code-review max` on PR #12. Each
was measured first, and three of them corrected something this changelog or a
code comment had asserted.

- **A non-writable `.armed` wedged the project on every uid** ([#27]). The
  unusable-marker guard tested `-d` and `-x`, never `-w` — the permission the
  marker writes actually need. Mode 555 passed both halves, so the guard stayed
  silent while a new session was denied, `ops-task.sh` reported success writing
  no marker, its sentinel landed anyway (blocking Stop too), and all three
  advertised repairs wrote into that same unwritable directory. Measured end to
  end off-root: the unrepairable project this hook's polarity exists to prevent.
- **The census miscounted a filename containing a newline** ([#29]). See B10.1
  above; the claim that `grep -z` was safe here is retracted with it.
- **An owner ending in `.exempt` forged or destroyed a G3 grant** ([#30]).
  `.armed/` holds two marker kinds in one flat namespace and the suffix was
  unguarded, so `--owner foo.exempt` on any ordinary task granted session `foo` a
  full exemption with **zero** GATE-EXCEPTION rows, and a session named
  `foo.exempt` closing a task **deleted** foo's real exemption while the ledger
  row still asserted it held. Rejected at all three writers; deliberately not in
  the hook's reject set, which fails open.
- **The handoff file was untracked** ([#28]) — a regression from v1, which
  tracked it. `!handoff-*.md` re-admitted.
- **`armgate.on` was untracked** ([#31]), so a team could not commit its own
  opt-in and every clone got the gate silently off.
- **The SessionStart gitignore migration was silent** ([#32]). It replaces a
  file the user may have edited and leaves a `.v1.bak` that the new allowlist
  itself hides; the notice now rides `additionalContext` and names both.
- **The PreToolUse arm gate had no timeout** ([#33]). Measured: a hung `jq` left
  it blocked past 6s against a ~44ms normal path, on the one hook that gates
  every edit. Bounded at 5s, pinned in both directions.

### Fixed

- **Retro-gate long-row blindness (G1.7)** — the prior-row scan skipped any
  read-chunk that filled its 512-byte bound, so a long evidence cell split a row
  and the chunk carrying `| <id> |` was skipped — a genuine duplicate was
  misfiled never-armed, writing a spurious GATE-EXCEPTION. Now matches every line
  start (the prefix is always there; a mid-cell continuation never begins with
  `| <id> |`). Found by the G3 review.
- **SessionStart tempdir wipe unreachable (U5)** — the tempdir-root cleanup sat
  behind the `.operator/` gate, so it was unreachable for exactly the projects
  that use the tempdir path (no `.operator/`), and that root grew forever. Hoisted
  above the gate. Found by the G3 review.
- **The compressor materialized `.operator/` in projects that never opted in** —
  each ephemera root now writes its own `.gitignore` holding `*`; when
  `.operator/` is absent the roots move to `$TMPDIR/cc-operator/<sha256(cwd)
  [:16]>/` instead of creating one.
- **`templates/OPERATOR.md` reflowed to 95 columns** — 149→136 lines, 8188 bytes,
  word stream and citation tags verified identical. Binding cap is now bytes.

### Fixed — four write-path defects found by the PR #12 review

Each reproduced before it was fixed, and each pinned by a test that fails when
the fix is reverted.

- **The gitignore migration destroyed rules it could not back up.** Both writers
  advertise `.operator/.gitignore.v1.bak` as the recovery path, and both did
  `cp … 2>/dev/null` followed by an **unconditional** overwrite. With
  `.operator/` unwritable but `.gitignore` still writable, the user's rules were
  gone, no backup existed, and the SessionStart context reported that both had
  succeeded — issue #32's own failure, one layer down. `ops-init.sh` had it too,
  reachable by a different trigger (a `.v1.bak` that is already a directory:
  `cp` lands the file *inside* it, so the advertised path is not the backup).
  The write is now reachable only through a successful backup, the notice flag
  is set only after the replacement, and the refusal is reported — silence is
  what let this ship. `check_gitignore_parity` pins both halves in both writers.
- **`ops-verdict.sh` accepted a non-regular entry as an armed sentinel.**
  `retro_gate` tested `-e`, so a directory at `pending/<id>` read as "armed":
  the `GATE-EXCEPTION` was **suppressed**, the row was appended anyway, and the
  later `rm -f` failed on the directory — a non-zero exit with the ledger
  already mutated and no audit line. Every other sentinel reader already
  required a non-symlink regular file; this was the one outlier. Now refused in
  `resolve_owner`, before any write.
- **The compressor's out-of-tree spill was world-readable.** `os.tmpdir()` is
  `/tmp` on Linux — where CI runs — and the key is `sha256(cwd)[0:16]`, no
  secret in it. Under default modes any local user could read **pre-scrub** tool
  output, and because `mkdirSync` follows symlinks, one who pre-created the
  shared root as a symlink captured every later spill (demonstrated). The shared
  segment now carries the uid, every level is created 0700 and `lstat`-verified
  to be a directory this uid owns, and spill files are 0600. An untrustworthy
  root yields **no spill and no cite** rather than a write. `ops-sessionstart-hook.sh`
  derives the same path and still sweeps the legacy uid-less root.
- **`ops-backlog.sh --census` miscounted a tracked file whose name begins with
  `-`.** `xargs -0 cat` read it as options and aborted the entire batch:
  `code-loc: 0` against a ground truth of 3. The `PARTIAL` flag fired, so the
  number was honest — and useless. `cat --` terminates option parsing.

### Fixed — the gate CLIs a project runs could be arbitrarily far behind ([#34])

Found by executing `docs/REPLAY-CHARTER.md` live rather than reading it — the
first finding the replay protocol has produced.

- **`.operator/bin/` refreshed only on a version-string change.** Every
  intra-version fix to a gate CLI therefore never reached an existing project.
  Measured in this repo mid-session: `.operator/bin/ops-verdict.sh` was
  byte-identical to a commit **two behind HEAD** (`sha256 e20ee4ab…`), missing
  the non-regular-sentinel guard, with all five `bin/` mtimes 24h old across
  three commits and `.version` already reading `0.7.0`. Since the charter points
  the model at `.operator/bin/…`, that stale copy **is** the gate the session
  runs — the plugin's own tests pass against code the project does not execute.
  The refresh now also fires when a shipped CLI is newer than its installed
  copy, keeping the all-or-nothing re-stamp (CR3/H2) and adding a negative
  control that a current `bin/` is not rewritten.
- **Recorded asymmetry**: hooks resolve through `${CLAUDE_PLUGIN_ROOT}/scripts/…`
  and are current immediately, so hooks and `bin/` can sit at different commits
  in one session. Proven live: `.operator/.compress-state/.gitignore` was
  written mode `0600` — a property only the current `writeSelfIgnore` produces —
  while `bin/` was two commits back. This is what made the earlier "stale bin"
  confusion during the #22 verification so hard to see.
- **`check_install_set_parity` went vacuous while fixing this.** Refactoring one
  writer's loop to a variable made the check unable to parse that side; it
  returned `None`, the `if a and b` guard swallowed it, and the check passed
  while pinning nothing. It now accepts either spelling, requires the loop to
  iterate the declared variable, and **reports** an unlocatable set instead of
  skipping.

### Fixed — two validator guards that named one invariant and pinned another

Both surfaced by the same review, both the F30 shape *inside* the checks written
to prevent it, and both measured green before the fix.

- **`check_source_stamp` did not verify the stamp reaches the row.** It tested
  `"SOURCE_STAMP" in code`, which the assignment line satisfies on its own — so
  replacing the row's `printf` argument with a literal left every verdict row
  unstamped with the build green. It now reads the row's own argument list, and
  a missing row site is reported rather than skipped.
- **`check_gitignore_parity` claimed both writers must "emit it AND grep for
  it", and only checked emit.** The heredoc body contains the marker, so
  deleting the migration `grep` in either writer passed — and every existing v1
  project silently stopped being detected. Detection is now asserted separately,
  per writer.

### Fixed — release notes dropped every issue link they used

- `release_gate.extract_section` cut the section body at `^\[`, which *is* the
  link-definition block — so a CHANGELOG section using reference-style `[#N]`
  published as literal `[#N]` text with no link. Measured on the v0.7.0 body
  before the fix: **9 dead references**. The section now carries the definitions
  it actually uses, and only those (a test pins that other versions' refs do not
  leak in).
- The same fix had a hole in its own shape: a `[#N]` with no definition
  *anywhere* left the body untouched and `gate()` reported no problem, so the
  dead-link bug shipped again on a different input. `extract_section_checked`
  now returns those references and the gate refuses to publish. `check_issue_refs`
  catches this on every PR, but `release_gate.py` is the independent second gate
  — a CHANGELOG edited on a release branch after the last green PR reaches
  `gh release create` without the validator ever having seen it.

### Changed

- **`.operator/.gitignore` is an allowlist** — v2 ignores `*` and re-admits only
  evidence; future ephemera are covered by construction. Existing projects
  migrated (not appended) by both `ops-init.sh` and SessionStart;
  `check_gitignore_parity` pins the two writers equal.
- **CLAUDE.md coupling table** gains two G2 rows (the `.armed/` marker convention
  across three writers + the hook; the matcher keeping `Bash` out).

### Verified — first release measured on Linux, and the arm gate proved live

- **G2 blocks a real `Edit` in a live session**, not merely at the hook's exit
  code. Four controls on the same tool and file: gate off → allowed; gate on and
  unarmed → **denied**, with the hook's stderr reaching the model verbatim
  (all four lines, including the three repair commands); armed via `ops-task.sh`
  → allowed; marker removed → denied again. Each deny confirmed by reading the
  file back, so the write genuinely never lands. `ops-adopt.sh` then restored the
  marker exactly as the deny message advertises.
- **Linux parity.** Full suite **447/0 on ubuntu:24.04** (bash 5.2.21, GNU grep
  3.11, `sh` = dash) as a normal uid, identical to macOS 24.6 (bash 3.2.57 and
  5.3.15, BSD grep 2.6.0). Prior releases were measured on macOS only. (Parity
  was first established at 442; review findings then added G2.12, G2.13 and
  B10.4, and both platforms were re-measured at each step. This number has now
  gone stale twice inside one PR, which is its own small argument for citing a
  count only where a command can be re-run against it.)
  - ~~`grep -z` is genuine null-data on both~~ — **retracted, and it was a real
    bug.** The "discriminating case" behind that claim did not discriminate:
    both semantics gave the same answer for the input I used, so it proved
    nothing. A genuinely discriminating input shows BSD/macOS `grep -z` does
    **not** anchor `$` at the NUL — see the census fix below.
  - `statusline.sh`'s `stat` dual-path took the GNU branch (`-c` OK, `-f` fails)
    — the fallback's first run on the platform it was written for.
  - The gate holds under `env -i` (no PATH, HOME, TMPDIR) and still fails **open**
    when no JSON parser is reachable.
- **The hooks are self-contained.** Zero `CLAUDE_PLUGIN_ROOT` references in the
  code of `ops-armgate-hook.sh`, `ops-stop-hook.sh`, `ops-sessionstart-hook.sh`
  and `statusline.sh` (every match is comment prose), and nothing is sourced.
  Driven by absolute path from `cd /` against a project that never installed the
  plugin, all four answered correctly and the ledger row landed in that foreign
  project; the walk-up stops at a `.git` boundary rather than adopting an
  unrelated ancestor.

### Decided — quiet-introduction policy (§10 of backlog-charter.md)

The CLI-dependent B-items (B2/B3/B4/B5/B8/B9) and B11's register-audit are
**deliberately unbuilt** — do not build loud detection for a problem the field
has not demonstrated. U1 (B11 reads the p1–p5 field, not an invented tag), U2
(no backlog.md dependency — covered in-house, dissolving B5's premise), U3 (the
unknowns scan is end-user-triggered by release posture, size is informational).

### Known limitations (stated, not hidden)

- **G2 is opt-in**, so the hole is closable, not closed (G4). `Bash` is ungated
  by design — classifying shell writes is unwinnable, and gating Bash deadlocks
  the repair path.
- **The arm gate's unusable-`.armed` guard has one inert half under uid 0**
  ([#19], resolved as documented-and-tested rather than patched). `[ ! -d ]` is
  the half that works on every uid; `[ ! -x ]` is best-effort and cannot fire for
  root, whose `[ -x ]` on a `chmod 000` directory returns TRUE. That is tolerable
  for a reason that had to be measured rather than assumed: root is not blocked
  by mode bits either. `ls`, `cd` and `touch` all succeed, and — decisively — the
  marker lookup stays **accurate** through the unreadable directory (present
  reads TRUE, absent reads FALSE), so root never reaches a wrong verdict and the
  three repairs the deny message prints stay alive. No capability probe fixes the
  inert half, because under root nothing fails. Now pinned by cases (G2.12): the
  dangling-symlink mode must DENY (a broken link is absence, not an infra fault),
  and under uid 0 an armed session is allowed through a `chmod 000` `.armed` with
  the lookup asserted accurate — the tripwire for the property the tolerance
  rests on. Both mutation-verified.
- **B10's threshold is unmeasured** (one repo); U3 makes the trigger a user
  declaration rather than that number.
- **The adversarial verifier shares the builder's working tree** ([#23]), so a
  `CONFIRMED` can be produced by builder state rather than by the code.
  Measured: a `__pycache__` the builder left makes a broken commit verify
  CONFIRMED in-tree and REFUTED in a clean checkout of that same commit, with
  `git status --porcelain` reporting clean throughout — the residue is
  *gitignored*, which is exactly why the usual cleanliness check cannot see it.
  `op-verifier` promises fresh **context**, never a fresh **tree**, and nothing
  in this release claims isolation. **Until it is closed, do not describe a
  verdict as independently verified** — it is verified by a different reader of
  the same tree.
- **The review panel has no security lens** ([#24]). `workflows/review.js`
  dispatches five lenses unconditionally — spec, testability, feasibility,
  quality, correctness. A security seat is deliberately not added yet: without a
  fixture carrying a known vulnerability it would be a lens that has never found
  anything, which is the vacuous-guard class this project keeps catching.
  **Until then, a panel PASS says nothing about security.**
- **A crash between a verdict row and its `GATE-EXCEPTION` loses the audit
  line** ([#14]). The two are separate appends; the retry classifies the orphan
  as `duplicate`, so a genuine gate bypass keeps its PASS row and loses its
  exception. Recorded as residual rather than patched because the obvious guard
  was built and reverted: an *armed* first verdict also leaves a row with no
  exception, so downgrading on that basis wrote spurious exceptions for every
  ordinary amended verdict (case G1.7 caught it). Nothing in the fragment
  distinguishes crash-interrupted from ordinary-amended; closing it needs a
  format change, which earns its own bar.

[#14]: https://github.com/betmoar/cc-operator-plugin/issues/14
[#19]: https://github.com/betmoar/cc-operator-plugin/issues/19
[#23]: https://github.com/betmoar/cc-operator-plugin/issues/23
[#24]: https://github.com/betmoar/cc-operator-plugin/issues/24
[#27]: https://github.com/betmoar/cc-operator-plugin/issues/27
[#28]: https://github.com/betmoar/cc-operator-plugin/issues/28
[#29]: https://github.com/betmoar/cc-operator-plugin/issues/29
[#30]: https://github.com/betmoar/cc-operator-plugin/issues/30
[#31]: https://github.com/betmoar/cc-operator-plugin/issues/31
[#32]: https://github.com/betmoar/cc-operator-plugin/issues/32
[#33]: https://github.com/betmoar/cc-operator-plugin/issues/33
[#34]: https://github.com/betmoar/cc-operator-plugin/issues/34

## [0.6.1] - 2026-08-05

### Fixed — deviation gate was blind on ledgers with long rows (#9)

The Stop-hook deviation gate aborted its scan at the first ledger row over 512
bytes, hard-coded the unpresented count to `1`, and returned. Two compounding
consequences, both now fixed:

- **Phantom block.** Any ledger with a row over 512 bytes blocked Stop even with
  no unpresented decision — and any `HANDOFF-MARK` past the first long row was
  unreachable, so `--mark-handoff` could never clear the block (an unkillable
  false positive). Multi-KB rows are the *expected* shape of an honest ledger
  (the charter asks for measurements/baselines in the row's what-cell), so a
  project's ledger silently disabled its own gate.
- **Blindness.** Because the count was a hard-coded `1` rather than an
  accumulation, a genuine unpresented `DEVIATION` after the abort point was
  invisible — the failure presented as a false positive, masking a dark gate.

Fix: `scan_deviations` (`ops-stop-hook.sh`) and its statusline mirror
(`statusline.sh`) now **accumulate** cap-filling chunks into one logical line
before classifying, rather than failing closed per chunk. This also *eliminates*
the F45 kind-forgery vector instead of merely detecting it: a continuation is
appended, never classified as an independent row, so it cannot forge a kind. The
aggregate `DECISIONS_MAX_BYTES` cap remains the pathological-input bound.

A row is now discriminated by a leading ISO date (`YYYY-MM-DD | …`), not merely
by the presence of ` | `. Header prose containing the kind enum previously parsed
as a forged row and blocked every freshly-scaffolded ledger.

### Changed — DECISIONS schema distinguishes gated from record kinds (#9)

The `DECISIONS-header.md` kind enum advertised `DECISION` and `DEFERRED-VERDICT`
alongside the gated kinds, but the gate counts only
`DEVIATION | ESCALATION | GATE-EXCEPTION`. A `DECISION` row never blocked Stop,
despite the schema presenting it as first-class. The header now splits the kinds
into **gated** (block Stop until presented), **record** (logged, never block),
and the **HANDOFF-MARK** marker. `validate_plugin.check_decisions_schema` pins
both the token set and the gated/record split, and requires both readers to count
exactly the gated literal.

## [0.6.0] - 2026-08-04

### Added — worker-boundary enforcement (stage 3 of 3)

- The F-A1 tree check is wired into the dispatch procedure (PLAYBOOK): after any
  read-only/workflow dispatch returns, run `ops-claims.sh --expect-clean`; drift
  is a FAIL-shaped finding. No seat is trusted (op-author is write-capable).
- The review workflow's adversarial verifier gains a tree-check refutation target
  — it confirms the working tree holds no changes beyond the reviewed artifact
  (the verifier is an agent, so it can touch disk; a worker touching files
  outside the artifact is a REFUTED basis).
- PLAYBOOK rules F-A6 (a fix after a green gate re-runs the gate) and F-A13 (a
  worker-authored commit uses the worker's own report sentence).
- Also: the stage-1 REFUTED review's parse bugs fixed — `ops-claims.sh` now uses
  porcelain `-z`/diff `-z` NUL-delimited parsing, `set -f` glob matching (a
  deleted gate CLI no longer evades C3), validated `--since`, and
  `--untracked-files=all`. 10 adversarial bash cases added.

### Added — worker-boundary enforcement (stage 2 of 3)

- The deviation gate: an operator-taken decision can no longer reach session end
  unpresented. The Stop hook now blocks iff a DEVIATION owned by this session —
  or by nobody — appears after the last mine/unowned HANDOFF-MARK in
  `DECISIONS.md` (file position, not timestamp). Foreign deviations report, never
  block. A whole-file scan, fail-CLOSED on a 2MiB cap; absent/corrupt polarity is
  deliberately split (absent → open, NUL/over-long → block).
- `ops-verdict.sh --mark-handoff --owner <sid>` writes the clearing mark under
  the existing ledger lock; `--owner` is required (an empty sid would clear every
  session). `commands/handoff.md` gains the verdict-CLI grant.
- The statusline gains a dim `dev[N]` mirror of the deviation partition.
- `check_decisions_schema` pins the DECISIONS-header kind enum (incl HANDOFF-MARK)
  and requires both readers to reference it (F30). 22 bash cases (gate + mirror)
  + 2 pytest mutation tests, revert-discrimination proven.

### Added — worker-boundary enforcement (stage 1 of 3; spec `docs/spec/2026-08-03-worker-boundary-enforcement-design.md`)

The worker seam's guarantees move from prompt-deep to code-deep, porting SSSF's
enforcement layer (gap analysis F-A1/A2/A3) without its runtime.

- `ops-claims.sh` — a fourth gate CLI: verifies a dispatch report's `CHANGED:`
  line against the actual diff (C1 unclaimed-change, C2 phantom-claim) and
  enforces "the builder cannot edit its own grader" (C3 gate-trespass over a
  protected set, `--gate-task` to authorize). `--expect-clean` asserts a
  read-only/workflow dispatch left no tree changes beyond `.operator/`.
- `validate_plugin.check_claims` pins the protected-set literal AND its
  application (F30: copy parity alone is insufficient).
- The dispatch packet's REPORT carries `CHANGED:`; the charter's FORBIDDEN
  default makes gate files off-limits to implementers unless the task IS the
  gate. PLAYBOOK gains the worker-boundary procedure (F-A1/A6/A13).
- Installed into `.operator/bin/` by `ops-init.sh`; joins `CHARTER_REQUIRED_CLIS`
  and the compressor's `GATE_CLIS` carve-out.

## [0.5.1] - 2026-08-04

### Fixed

- **A load-bearing measurement was wrong by ~15x, in five files.** The F64
  chunk-cap fix was justified by "4.0s on a 64MB `tiers.env`", a figure taken
  from the original report and copied verbatim into `ops-tiers.sh`,
  `ops-render.sh`, `validate_plugin.py`, both test files, and this changelog
  without anyone re-running it. Re-measured on bash 3.2.57: **66-70s uncapped
  vs 0.11s capped**, corroborated by two independent verifier runs (61s, 62s).
  The fix was right; the number defending it was not. Corrected everywhere,
  each site now naming the bash version and date it was measured on.
- **Symlink sentinels are now rejected at every read site, not just the
  opener (F66).** F65's `-L` guard covered only `ops-task.sh`'s create path; a
  symlink planted in `.operator/pending/` was still adopted by `ops-adopt.sh`
  (laundering it into a real sentinel), closable into VERDICTS.md by
  `ops-verdict.sh`, and read as a foreign task by the Stop hook and
  statusline. Parsers now degrade a symlink to unowned (blocks — fail closed);
  the mutating CLIs refuse it outright.
- The tiers.env probe cap is now 200 chunks (100KB), the parse loop's own
  legal maximum — the 20KB cap introduced with F64 rejected comment-heavy
  configs (up to 200 lines × 511 chars) that resolved fine before it.
- Corrected a false comment in `ops-task.sh` (echoed in the F65 commit
  message): `mv` over a destination symlink replaces the link itself, never
  its target — the real exposure was read-side laundering, not a data
  overwrite.
- The validator's probe-cap check now parses the cap value (was a substring
  test that `-le 400000` satisfied) and matches any probe variable name (a
  rename evaded it); the bash regression fixture grew to 16MB so the
  wall-clock assertion actually fails when the cap is removed (2MB completed
  under budget even uncapped).

## [0.5.0] - 2026-08-03

The orchestration layer: tier-routed workflows as the operator's dispatch
primitives, an input-axis token compressor, and the guard/audit hardening
rounds F07–F65 (a full-PR adversarial panel in the final stretch surfaced
three live exploits that closed the door on late-NUL and multibyte smuggling,
plus the unbounded-probe stall).

### Added

- **Four workflows** (`workflows/*.js`) as orchestration primitives — review
  panel (narrow lenses → adversarial verifier, REFUTED is a hard stop),
  brainstorm (divergent directions + blindspot scan + references), plan
  (TDD decomposition with parallel vetting), and crawl (sharded corpus
  digest). All args-normalized, tier-guarded, and covered by an execution
  test suite (`tests/test_workflows.mjs`).
- **Layered tier system**: `ops-tiers.sh` resolves tier→model bindings from
  user/project `tiers.env` (charset + cc-proxy-routability guarded);
  `ops-render.sh` renders project-layer agents so plain Agent dispatch can
  run on configured models; `/cc-operator:tiers` wraps both.
- **Input-axis token compressor** (`scripts/ops-compress.mjs` + PostToolUse
  hook): allowlist-only scrub/dedup/elide of re-billed tool output, with
  verbatim pre-scrub spill files and an evidence-gate carve-out
  (ledger/CLI output is never compressed). Design rationale lives in the
  maintainer's local `docs/spec/` (gitignored — not shipped in a clone).
- **Workflow progress on the statusline**: `wf done/started` from the run
  journal, with unbalanced-journal liveness so long dispatches don't flap
  the segment (F58).
- **Discovery discipline** folded into the charter (interview, blindspot
  pass, plan vetting, adversarial pre-done) and the cc-agents specialists
  absorbed as rendered seats.
- **Validator checks** for the new surface: workflows, commands, compressor
  guards, resolver↔renderer parity, render templates, reader byte-bounds, and
  (F64) NUL-probe chunk-cap parity across every sentinel/config reader.
- **Plain-English handout** (`docs/HANDOUT.md`): an end-user matrix of the
  four tiers, seven agents, four workflows, and three commands, with an
  ELI5 walkthrough of solo vs orchestrated mode and the evidence gate.

### Fixed

- **Gate hardening F42–F57**: sentinel owner smuggling via NUL/over-long
  lines, and the over-long tiers.env line smuggling class.
- **Full-PR adversarial panel F59–F65** — three live exploits repro'd with
  commands, all closed and mutation-verified:
  - **F59** — late-NUL owner smuggling: a single 512-byte NUL probe left every
    NUL past byte 512 undetected, so padding + NUL + `session_id: EVIL`
    claimed ownership and flipped a sentinel from blocking to waved-through.
    All four parsers now loop the probe whole-file, bounded at 40 chunks.
  - **F60** — `check_workflows` guard-application checks read a comment-stripped
    view, so a trailing `//` could neuter the `BAD_CHARSET`/`ROUTABLE` call.
  - **F61** — dangling `docs/spec/` refs in the changelog (fresh-clone honesty).
  - **F62** — a multibyte comment bypassed the 512 line-cap on bash 3.2
    (`read -n` counts bytes, `${#}` counts chars); parse loops now run `LC_ALL=C`.
  - **F63** — `check_compressor` pinned `ELIDABLE` disjoint from
    `NEVER_COMPRESS` and stripped trailing `//` comments (the vacuous-guard
    class, with per-tool set literals and block-comment stripping).
  - **F64** — the NUL probe in `ops-tiers.sh`/`ops-render.sh` looped whole-file
    with no chunk cap, stalling the resolver ~66s on a 64MB newline-less
    `tiers.env`; now bounded (66s → 0.11s), enforced by `check_reader_bounds`.
    (The 4.0s figure this entry originally carried was wrong by ~15x —
    re-measured 2026-08-04 on bash 3.2.57; see the 0.5.1 entry.)
  - **F65** — `ops-task.sh`'s O_EXCL guard used `[ -f ]`, which follows
    symlinks: a symlink→regular read as "already open", and downstream `mv`
    would overwrite the target outside `pending/`; now guarded by `[ ! -L ]`.
- **Dead-agent honesty F31/F32/F49**: a dead lens, terminal, or blindspots
  agent surfaces as an error carrying the surviving work — never laundered
  into an empty-but-clean result.
- **Review workflow F33–F41**: array targets, starved lenses, malformed
  verdict handling, doneMeans validation, honest cost accounting bound to
  the LENSES table.
- **Statusline F12/F26/F28/F44/F58**: corrupt bar on done=0, stat-flavor
  probe (GNU/BSD), renderer exit status, transcript-mtime liveness, and the
  mid-run liveness flap.

### Changed

- CLAUDE.md slimmed: landmine narratives moved to `docs/LANDMINES.md`,
  playbook procedures to `docs/PLAYBOOK.md`; charter byte-bounded with
  per-section citation floors.
- 0.3.0's removed dev artifacts stay removed; spec headers now carry honest
  implementation status.

## [0.4.0] - 2026-07-27

Concurrent sessions in one working tree no longer trap each other. Field report
and design rationale live in the maintainer's local `docs/spec/` (gitignored —
not shipped in a clone).

### Changed
- **BREAKING (behavioral)** — Task sentinels now carry an owner
  (`session_id` / `cwd` / `opened_at`); previously they were empty files. The
  Stop hook blocks only on sentinels owned by **that** session and reports
  other sessions' as informational. Previously any session's open task blocked
  every session in the tree, and the only escapes — closing the row or
  `--defer`ring it — both wrote evidence the session had not captured and
  silently disarmed the other session's completion gate.
  A sentinel with **no** owner still blocks every session, so pre-0.4 sentinels
  and any `ops-task.sh` call without `--owner` keep gating exactly as before.
- `ops-task.sh` and `ops-verdict.sh` accept `--owner <session-id>`.
  `ops-verdict.sh` **refuses** (exit 2, no row, sentinel intact) when `--owner`
  contradicts the sentinel's owner; a missing `--owner` warns and proceeds, so
  a session whose id rotated can still close its own work.
- `ops-verdict.sh` appends under a `mkdir`-based lock (`flock(1)` is absent on
  macOS), making the file header's atomicity claim true rather than a property
  of `printf`'s buffer size. Reclaiming a lock requires the kernel confirming
  its holder is gone (see the lock entry under Fixed); a lock whose holder
  cannot be judged falls back to a bounded wait, because a stale lock must
  never cost a real verdict.
- Re-opening an already-open task is still a no-op, now explicitly **including
  its ownership** — re-open can never be a silent takeover.

### Added
- `scripts/ops-sessionstart-hook.sh` + a `SessionStart` hook registration — the
  only channel by which the agent can learn its own session id
  (`CLAUDE_SESSION_ID` is not set in the Bash tool environment). Silent outside
  operator projects and when no JSON parser is present.
- `scripts/ops-adopt.sh` (installed to `.operator/bin/`) — re-stamps named
  sentinels to a new session id. A session id rotates on `/clear`, so without
  this a session's own tasks would degrade to "foreign" and stop gating it. The
  charter's RECOVERY PROTOCOL gains adoption as step 6 of 7, just before
  resuming the first incomplete task. Explicit ids only: there
  is deliberately no bulk adopt.
- Per-session row fragments at `.operator/verdicts.d/<owner>.md`, plus
  `ops-verdict.sh --reconcile`, which restores to `VERDICTS.md` any row present
  in a fragment but missing from it (idempotent). Two branches append to two
  different files and merge cleanly; a mangled `VERDICTS.md` merge can be
  resolved any way at all and then repaired. It repairs, never regenerates —
  hand-written BAR blocks survive.
- `ops-init.sh` writes `.operator/.gitattributes` marking the ledgers
  `merge=union`, and creates `verdicts.d/`. Scoped to `.operator/` so the host
  repo's root `.gitattributes` is never touched.
- Test cases 8–11 and 21 in `tests/test-scripts.sh` covering the spec's five
  acceptance criteria: the ownership partition, pre-0.4 migration safety, the
  writer's ownership refusal and adoption, 2×50 concurrent appends with a
  full-schema assertion, genuine lock mutual-exclusion, and reconcile.
- Validator: the SessionStart hook must be registered via
  `${CLAUDE_PLUGIN_ROOT}`, and every CLI in the `.operator/bin` install set must
  be named in the charter by its project-relative path.
- **A statusline segment** — `scripts/statusline.sh` plus
  `.claude-plugin/statusline.json`, discovered automatically by
  [cc-status](https://github.com/betmoar/cc-status-plugin) and usable
  standalone as a `statusLine` command. Renders `op[2]` when this session owns
  2 open tasks (red — the stop is blocked) and `op[1+2*]` when 1 is yours and 2
  are other sessions' (dim — informational). Silent outside operator projects
  and when nothing is open.

  It runs the Stop hook's own mine/foreign partition rather than counting
  `.operator/pending/`, because since 0.4.0 those are different questions: a
  raw count claims you are stuck when every open task belongs to someone else,
  and — the direction that actually costs a session — shows nothing while an
  unowned sentinel silently gates you. Same untrusted-body rules as every other
  reader (`docs/PLAYBOOK.md`): bounded in bytes, sanitized at the parser, and a
  degenerate body degrades to unowned = counted as blocking.
- Validator: `check_statusline` (the manifest must name the plugin and point at
  a renderer that resolves — cc-status skips an unresolvable one *silently*, so
  the segment would simply never appear), and the segment is registered in
  `check_reader_bounds` as the fourth sentinel reader. It renders on a ~300ms
  timer, making a lost byte bound a permanently wedged bar rather than one slow
  turn-end: measured 6.20s *per parse* on a 64 MB newline-less sentinel vs
  0.014s bounded.
- Test case 22 in `tests/test-scripts.sh` (18 assertions) — including that one
  directory of three sentinels renders differently for each of three viewers,
  which is the assertion a file count cannot pass. Verified discriminating by
  mutation: degrading the segment to a naive count fails 8 assertions, dropping
  the byte bound fails the timing bound alone, and dropping the owner sanitizer
  fails the traversal case.

### Fixed (found in review of this branch, before release)
- **`validate_plugin`'s test suite had silently fallen three checks behind the
  build.** `ValidatorTest.problems()` hand-listed the checks to run, and
  `check_reader_bounds`, `check_guard_parity` and `check_lock_parity` were
  never added — so `test_good_tree_is_clean`, the assertion a reader trusts
  most, did not exercise the three guardrails the 2026-07-27 audit added.
  Both `main()` and the tests now iterate one `vp.CHECKS` registry, and the
  good-tree fixture was given script bodies that actually satisfy those
  contracts (bare `echo ok` stubs failed all three once they ran at all).
  Found while wiring the statusline check in.
- **The lock inferred a crash from elapsed time, and could steal a LIVE
  writer's lock.** The first draft presumed any holder past the budget dead,
  which cannot distinguish a slow writer from a dead one — the root of audit
  F03, where a long `--reconcile` had its lock reclaimed while it was still
  inside the critical section (F03 capped fragment size, bounding the trigger
  but not the inference). Reproduced both directions before fixing: a live
  writer holding the lock 30s was told it was "a crashed writer", and a waiter
  behind an already-dead holder burned 34s. Holders now stamp
  `host uid pid` into `.operator/.lock/holder` and waiters ask the kernel via
  `kill -0` — dead reclaims immediately, **alive is never reclaimed** (past 60s
  the waiter proceeds unlocked, the milder failure), and anything unjudgeable
  falls back to the timed budget. That last branch is reached constantly, not a
  compatibility path: `mkdir` and the stamp are not one atomic step, so a lock
  is briefly held-but-unstamped, and `kill -0` across uids fails with EPERM
  indistinguishably from "dead" — judging either would reclaim a live lock.
- **The two lock implementations were kept in sync by a comment.**
  `ops-verdict.sh` and `ops-adopt.sh` contend on the same lock, and "keep them
  identical" was prose. `validate_plugin.check_lock_parity` now compares the
  `# >>> LOCK BLOCK` region byte for byte and fails the build on drift — the
  same reasoning as `check_reader_bounds`, which exists because a byte bound
  reached one reader of four.
- **A dot-prefixed task-id silently defeated the gate.** `.hidden` passed the
  bare-name guard, but the Stop hook enumerates `pending/` with a plain glob,
  which does not match dotfiles — so the sentinel existed and the gate could
  never see it. All three CLIs now refuse a leading dot; the rule subsumes the
  existing `.`/`..` traversal guard. Case 12 asserts the glob premise itself,
  so the reason the rule exists cannot rot.
- **`--reconcile` bypassed the single writer's cell hygiene.** It copied
  fragment lines into `VERDICTS.md` verbatim, so a merge-corrupted or
  hand-edited fragment could inject a non-conformant row into the ledger every
  consumer greps. It now enforces the same 4-cell `PASS|FAIL` schema, skips
  what fails it, and reports the count.
- A repeated `--owner` silently took the last value. All three CLIs now refuse
  it: a duplicated flag means the caller is confused about ownership, which is
  the one thing this mechanism must not guess at.
- **The 2026-07-10 path traversal, reopened through the sentinel body.**
  `--owner` was validated, but the owner *parsed out of a sentinel* was not —
  and it becomes a fragment filename. A sentinel reading
  `session_id: ../../PWNED`, closed without `--owner` (the warn-and-proceed
  path kept for `/clear`'d sessions), appended a real ledger row outside
  `.operator/`. Reproduced before fixing. Sentinel bodies are untrusted input:
  they are ordinary files a merge, checkout, or patch can supply. Both
  `sentinel_owner` parsers now sanitize at the parser rather than at each call
  site, and an unusable owner degrades to unowned — which fails closed.
- **A CRLF sentinel was a fail-open in the central invariant.** A trailing `\r`
  (a checkout can introduce one) made a session's own id compare unequal, so
  its own task was classified foreign and the stop was waved through. Both
  parsers now strip trailing `\r`/whitespace.
- **The Stop hook could stall every session's turn-end.** It read whole
  sentinel files; a 2 MB one cost ~10s on every Stop event in the tree, and a
  directory in `pending/` emitted a raw bash read error *as operator guidance*.
  The parse is now capped at 20 lines (the owner is line 1 by construction) and
  the enumeration requires a regular file.
- **`ops-adopt.sh` wrote its temp file inside `pending/`**, which the Stop hook
  globs — so a crashed adopt left a phantom pending task that blocked the
  session and could be closed into the ledger as a garbage row. It also had a
  TOCTOU: if the owner closed the task mid-adopt, `mv` resurrected a sentinel
  for a task that already had a verdict. Temp moved out of `pending/`, and the
  sentinel is re-checked immediately before `mv`.
- **A stale lock was permanent and never reclaimed.** The trap does not cover
  `SIGKILL`, and the timeout branch only *ignored* the lock, so after one hard
  kill every later write paid the full timeout, warned, and was not mutually
  exclusive anyway. The lock is now reclaimed on timeout. The budget also rose
  to 30s because a legitimate large `--reconcile` could outlast the old 5s and
  push real writers onto the unlocked path — the guarantee evaporating exactly
  when it mattered. `--reconcile` itself went from O(rows × ledger) with a
  `grep` per row to a single pass: measured 7s → 0s at 3000 rows.
- The `INT`/`TERM` handler released the lock but let bash *resume* the critical
  section; it now exits. The verdict path writes the fragment before the ledger
  row, so a partial failure leaves a repairable state rather than an
  un-repairable ledger row plus a duplicate on retry.
- **The `--reconcile` schema check was a glob, and globs do not count.**
  `'| '*' | '*' | '*' | PASS |'` reads as a 4-cell pattern but each `*` also
  matches ` | `, so `| a | b | c | injected | PASS |` passed it and was appended
  to `VERDICTS.md` — the corrupt-fragment hole the check was added to close, one
  level down. Cells are now counted by splitting on the delimiter.
- **The reclaim claim could not expire, which turned a stall into a deadlock.**
  A process killed between creating `.lock.reclaim` and removing it made every
  later writer defer to it forever — strictly worse than the stale lock the
  claim was introduced to fix, which at least proceeded after one budget.
  Measured: still running after 45s. Deferral is now bounded (a live reclaimer
  needs milliseconds, so it gets short waits, not whole budgets); after that the
  claim is treated as dead and cleared. Worst case degrades to two reclaimers
  racing — the milder, pre-existing failure — never a hang. Recovery measured at
  ~51s. `ops-adopt.sh` shares the implementation and the fix.
- **The Stop hook's sentinel parse was bounded in lines but not bytes.** A
  single newline-less line is one "line", and `read -r` consumes all of it
  before any counter runs — 256 MB measured at 8.5s, on *every* session's Stop
  event. Now capped per line with `read -r -n 512`; same file, 0.16s.
- **Stale-lock reclamation was not itself exclusive.** With several waiters,
  each timed out independently: one removed the stale dir and recreated it, then
  the next removed *that fresh* lock and entered too — two writers in the
  critical section, neither over budget. Reclamation now requires winning an
  atomic `.lock.reclaim` claim; everyone else keeps waiting for the winner's
  lock. Applies to `ops-adopt.sh`, which shares the implementation.
- **Two TOCTOU races in the ownership mechanism itself** (found by Codex
  review). `ops-task.sh` created the sentinel with test-then-truncate, so two
  sessions opening the same id both passed the check and both wrote — the later
  silently replacing the earlier's ownership, breaking the documented
  no-takeover guarantee. Measured at 155/200 trials; now 0/200: creation uses
  `set -C` (`O_EXCL`), so the kernel picks exactly one winner and the loser
  reports the task as already open. Separately, `ops-verdict.sh` validated
  ownership *before* acquiring the lock, so an `ops-adopt.sh` landing in between
  let the former owner record a verdict and delete the new owner's sentinel.
  Ownership is now validated inside the lock, and `ops-adopt.sh` takes the same
  lock — "validate ownership, then act on it" is indivisible across both tools.
- `ops-adopt.sh` used `"${IDS[@]}"` on a possibly-empty array, which is an
  unbound-variable error on macOS's bash 3.2 under `set -u`. Uses the same
  `${IDS+"${IDS[@]}"}` guard as `ops-verdict.sh`.
- **A whitespace `--owner` silently disarmed the gate.** The Stop hook compares
  the stamped owner byte-for-byte against the payload's session id, so
  `--owner " SESS-A"` could never match any real session: the task was
  classified foreign forever, and foreign tasks never block. Reproduced (hook
  exited 0 with the task still open). Whitespace is now refused for **owners**
  at all three CLIs and treated as unowned by both parsers, so a hand-written
  sentinel that never passed through a CLI still fails closed.
  The whitespace rule applies to owners **only**. An interim version of this
  fix applied it to task ids too, which wedged any pre-0.4 task whose id
  contained a space (0.3.0 accepted `release candidate`): the hook still
  blocked on the sentinel while every closing path — verdict, defer, adopt —
  refused the id, so the session could never stop at all. That is precisely
  the trap this release exists to remove. Task ids keep only the filename and
  ledger-cell guards.
- **A payload that failed to parse failed open in total silence.** `json_get`
  swallows parser errors, so a corrupt payload made every field read empty and
  was indistinguishable from "no cwd, not an operator project". It now warns —
  the same courtesy the no-parser branch already extended — while still
  exiting 0. An empty payload stays silent, since that is not corruption.

### Documentation corrections
- "The RECOVERY PROTOCOL ends with adoption" was wrong in `ops-adopt.sh` and
  this changelog: adoption is step 6 of 7, before resuming the first incomplete
  task. The charter itself was always right.
- The README's "atomic against concurrent sessions" repeated the unqualified
  claim the script header now qualifies; both name the reclaim window. The
  spec's §4.3 assertion that locking "makes the header comment's atomicity
  claim true" is corrected in place rather than left standing.
- `CLAUDE.md`'s coupling table referenced test cases by ordinal, which shift
  whenever a case is inserted. It now references them by title, with the grep
  that lists them.

### Fixed (departing-architect audit, before release)

Full ledger in `docs/audit-2026-07-27-findings.md`; verdict and residual risk
in `docs/audit-2026-07-27-handoff.md`; procedure in the new `docs/PLAYBOOK.md`.

- **The gate failed OPEN from any subdirectory of the project.** `ops-task.sh`
  refuses to open a task anywhere but the directory holding `.operator/`, while
  the Stop hook resolved `"$cwd/.operator"` by exact match with no upward walk —
  so a Stop payload whose `cwd` was one directory deeper found nothing, took the
  no-op guard, and allowed the session to end with tasks still open. The whole
  gate, silently off. Reproduced (`cwd=<root>` → block; `cwd=<root>/src` →
  allow). Pre-existing since before 0.4.0. The hook now walks up to the nearest
  `.operator/`, bounded at a `.git` boundary and at the filesystem root, with
  `cd -P` resolving symlinks.
  Root cause worth naming: **nothing in this system defined "the project"** —
  three components each answered locally and disagreed. `ops-init.sh` now warns
  when it is scaffolding somewhere that is not the repository root, because a
  second ledger below the root would shadow the real one for everything beneath.
- **A slow `--reconcile` had its lock reclaimed by a concurrent writer.** The
  fragment read happens inside the critical section, and an unbounded read of a
  256 MB fragment took 32.56s against the 30s crash-presumption budget — so a
  second writer presumed the holder had crashed, took the lock, and both entered
  the critical section against the ledger of record. Live repro captured. Fixed
  by bounding the trigger: `--reconcile` now refuses a fragment larger than
  `FRAG_MAX_BYTES` (8 MiB ≈ 100k rows) instead of reading it. 31.85s → **0.18s**;
  a 500-row fragment reconciles normally.
- **The per-line byte bound had been applied to one of four readers.** The 0.4.0
  hardening reached the Stop hook only. Measured on one 256 MB line: hook 0.17s
  vs `ops-verdict.sh` 13.51s, `ops-adopt.sh` 16.77s, `--reconcile` 32.56s. All
  readers now use `read -r -n 512`; `ops-adopt.sh` also gained the 20-line cap it
  never had.
- `ops-adopt.sh` copied `cwd:`/`opened_at:` forward verbatim, so a CRLF sentinel
  (an ordinary `core.autocrlf` checkout artifact) put a bare CR into the Stop
  hook's foreign-task report, where a terminal carriage-returns mid-line and eats
  the operator's guidance. Gating was unaffected. Now stripped.
- `ops-init.sh` scaffolded the ledger in any directory, including one that is not
  a repository, reporting success either way — writing the evidence of record
  somewhere nobody would merge or review. Now warns (never hard-fails; a non-git
  project is unusual but legitimate) and writes `.operator/.gitignore` so lock
  ephemera (`.lock/`, `.lock.reclaim/`, `.adopt.*`) can never be committed.

### Added (audit guardrails)
- `validate_plugin.py` gains `check_reader_bounds` and `check_guard_parity` —
  the two cross-file couplings that were prose in `CLAUDE.md` and were violated
  anyway. A missed byte bound, or a name guard applied to only one of the three
  CLIs, now fails the build instead of a review. Both verified to fire on each
  regression and to pass the clean tree. (The first version of the reader check
  matched `read -r` inside comments and failed correct code — a checker that
  flags its own documentation teaches people to ignore the build; fixed and
  locked by a test.)
- `tests/test-scripts.sh` cases 17–20, each written before its fix and confirmed
  failing against the unfixed code (10 failures → 0).
- `docs/PLAYBOOK.md` — decision procedures for adding a guard, adding a reader,
  and touching the lock, each derived from a bug that actually happened here,
  plus an explicit "what a green suite does NOT prove" table.

### Known limitations
- **A slow holder still loses mutual exclusion — but is no longer presumed
  dead.** Time-based crash inference was the lock's root weakness and was
  removed before release (see the `kill -0` entry under Fixed): a live holder
  is never reclaimed. What remains is milder and deliberate — past
  `LOCK_LIVE_SPINS` (60s) a waiter proceeds *unlocked* rather than stealing a
  running writer's lock. Blocking indefinitely would trade a rare correctness
  gap for a hang.
- Reclaim exclusivity has no timing-based test, and this was **measured, not
  skipped**: six approaches against a deliberately naive copy all read 0/N
  (P ≈ 1e-5). It is instead guaranteed structurally — a held lock is stamped,
  a stamped directory is non-empty, and `rmdir` refuses those — which the suite
  asserts deterministically and which mutation-testing confirms discriminates.
- `mkdir`/`O_EXCL` atomicity is assumed by both the lock and sentinel creation.
  Untested on network filesystems.
- bash 3.2 compatibility is load-bearing on macOS and validated only by local
  dev; CI runs a modern bash.
- `DECISIONS.md` gets the lock and `merge=union` but no fragments. It is a log,
  not the evidence of record; the fragment machinery exists to make verdict rows
  unloseable.
- `ops-adopt.sh` will adopt a task owned by another *live* session, not only an
  orphan of your own. Adopt-then-close therefore reaches the outcome that
  `ops-verdict.sh`'s `--owner` refusal blocks directly. Requiring explicit ids
  (no bulk adopt) makes this deliberate and auditable rather than accidental,
  but it is not prevented — a session cannot distinguish "my task from before
  the /clear" from "someone else's active task" without a liveness signal the
  plugin does not have.

## [0.3.0] - 2026-07-10

### Changed
- **BREAKING** — The charter and the Stop-hook block message now name the
  verdict CLI at `.operator/bin/ops-verdict.sh`, and `ops-init.sh` installs
  the gate CLIs (`ops-verdict.sh`, new `ops-task.sh`) into `.operator/bin/`,
  refreshing them on every run. Previously both named `scripts/ops-verdict.sh`
  — a path that resolves only inside this repo, so in any target project the
  operator was blocked from stopping and pointed at a nonexistent command.
  Re-run `/cc-operator:start` in existing projects to install the CLIs; for
  un-migrated projects the hook falls back to the plugin's absolute path.
- **BREAKING** — Agents re-tiered to model aliases with per-tier `effort`
  pins: `claude-opus-4-8` → `opus` (author/reviewer, effort medium),
  `claude-sonnet-4-6` → `sonnet` (mechanic, effort low). Pinned IDs hard-error
  when a version is retired; aliases track the recommended version.
- `op-reviewer` hardened with `disallowedTools: Write, Edit, NotebookEdit`.

### Added
- `agents/op-scout.md` — haiku recon tier (read-only search/lookup), so
  reconnaissance stops burning operator context or opus dispatches.
- `agents/op-verifier.md` — fresh-context adversarial verifier (opus):
  re-runs DONE MEANS itself, returns CONFIRMED/REFUTED, never fixes.
- `scripts/ops-task.sh` — one-command auditable sentinel opener; the charter's
  EVIDENCE GATE names it.
- Validator checks: the charter must reference the project-resolvable
  `.operator/bin/ops-verdict.sh` path; agent `model:` must be a tier alias
  (`opus`/`sonnet`/`haiku`); `ops-task.sh` joins the `bash -n` set.
- Shellcheck step in both CI workflows (scripts + bash test suite are clean).

### Fixed
- `ops-verdict.sh` path traversal: a task-id containing `/` (e.g.
  `../../victim`) reached `clear_sentinel`'s `rm -f` and deleted files outside
  `.operator/`. Task-ids are now refused unless they are bare names.
- Ledger cell hygiene at the single writer: `|` or newlines in the task-id,
  criterion, evidence, or defer reason silently broke the one-line 4-cell row
  schema (and allowed fake-row injection into DECISIONS.md). All are now
  refused with exit 2 — refuse, never sanitize. The verdict argument is
  locked to exactly `PASS` or `FAIL` (previously any non-empty string was
  recorded). `tests/test-scripts.sh` case 7 locks all of this.
- Stop-hook fallback message no longer emits a `cd` error and a garbage
  `/ops-verdict.sh` path when the hook is invoked without a directory prefix.
- `/cc-operator:start` step 2 now instructs Read+Write for materializing the
  charter — `cp` was never in the command's allowed tools.

### Removed
- Dev provenance from the shipped tree — `docs/plans/` (build plan, ledger,
  pilot runbook/findings, handoff), `inputs/` (the prior project's evidence
  bundle), and `tests/pilot/` (scoring scripts CI never ran). `plugin install`
  clones the repo, so the tree is now exactly what ships. History remains in
  git (tree ≤ v0.2.0); the design spec stays at `docs/spec/`.

## [0.2.0] - 2026-07-08

### Changed
- **BREAKING** — Flattened the plugin to the repo root (`source: "./"`) and
  renamed it `operator` → `cc-operator` to match the cc-unknowns shipping
  standard. The command namespace moved with it: `/operator:start` and
  `/operator:handoff` are now `/cc-operator:start` and `/cc-operator:handoff`.
  Anyone who installed 0.1.0 must remove the old marketplace/plugin entry and
  reinstall under the new name; the old command names no longer resolve.

### Added
- `scripts/validate_plugin.py`: contract linter beyond schema — manifest/
  marketplace name+source sync, version-is-newest-CHANGELOG-heading, the
  charter build gates (≤150 lines, fixed section order, citation tags),
  the VERDICTS ledger header byte-schema, agent frontmatter + NEEDS_CONTEXT +
  no build-specific naming, the Stop-hook wiring, and `bash -n` on the scripts.
- `scripts/release_gate.py`: tag == plugin.json version == newest CHANGELOG
  heading, run by the release workflow and locally before tagging.
- `tests/test_validate_plugin.py`, `tests/test_release_gate.py`: stdlib
  unittest coverage — each validator check fires on a broken fixture.
- `.github/workflows/validate.yml` (validator + tests on push/PR) and
  `.github/workflows/release.yml` (tag-gated GitHub release).
- `README.md`, `CONTRIBUTING.md`, `CLAUDE.md` (maintainer handoff), `LICENSE`.

## [0.1.0] - 2026-07-06

### Added
- Initial cc-operator plugin (spec Phase 0 + mechanical Phase 2).
- Charter template `templates/OPERATOR.md` — two-mode (solo + orchestrated)
  operating charter, ≤150 lines, every rule line citation-tagged.
- Evidence-gate scripts: `ops-init.sh` (idempotent ledger scaffold),
  `ops-verdict.sh` (single writer to VERDICTS.md; append + sentinel-clear;
  `--defer` path), `ops-stop-hook.sh` (Stop-hook completion gate: exit 2 on a
  pending verdict, fail-open on missing jq/python3).
- `hooks/hooks.json` Stop-hook wiring via `${CLAUDE_PLUGIN_ROOT}`.
- Commands `/operator:start` (+`--inline`) and `/operator:handoff`.
- Agents `op-author`, `op-mechanic`, `op-reviewer` (tier-pinned trio).
- Router skill `chief-operator`.
- Ledger header templates byte-identical to the proven harness schemas.
- `tests/test-scripts.sh` — plain-bash TDD suite (23 cases) for the scripts
  and the Stop hook, including the jq-absent python3 fallback.

Live-session proof (2026-07-07): the Stop hook fires with exit-2 block +
release, and SubagentStop does not trip the main Stop hook.
