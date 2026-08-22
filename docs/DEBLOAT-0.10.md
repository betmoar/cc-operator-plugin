# DEBLOAT — the 0.10 plan

**Premise.** We are building software, not defending a codebase against its own
development process. Measured on this branch: 11,371 shipped lines, of which
the product a user touches — charter, gate, workflows, tiers — is ~3,000. The
other ~8,000 is armor that agents accreted: every review finding became a
permanent guard + a war-story comment + a coupling-table row + a parity check,
and nothing was ever deleted on the grounds that a design change had made the
bug impossible. The one counterexample is the 0.9.0 filename-ownership refactor
(184 parser lines deleted by making the parse unnecessary), and it is the model
for every step below: **change the design so the guard has nothing to guard,
then delete the guard.**

**Rules for executing this plan** (these bind the agent doing the work):

1. Every step names its deletion target in lines. A step that ends net-positive
   is a failed step — revert it, do not "compensate elsewhere".
2. War-story comments (dates, F-numbers, "measured…", "a review caught…") move
   to git history where they already live. Code keeps at most a one-line WHY.
   The narrative register is `docs/LANDMINES.md` and the commit log, not the
   source.
3. No new validator checks. A step that needs one to be "safe" is redesigning
   in the wrong direction.
4. Behavior changes are listed per step, explicitly. Anything not listed is
   regression.

Current per-file weight (total / comment / code):

| file | total | comment | code |
|---|---|---|---|
| validate_plugin.py | 2894 | ~40% | ~1700 |
| ops-verdict.sh | 1239 | 667 | 572 |
| ops-adopt.sh | 565 | 294 | 271 |
| ops-claims.sh | 523 | 297 | 226 |
| ops-corpus.sh | 521 | 278 | 243 |
| ops-compress.mjs | 470 | 173 | 297 |
| statusline.sh | 450 | 241 | 209 |
| ops-backlog.sh | 131 | 94 | 37 |

---

## Step 1 — ops-backlog.sh: keep the census, delete the essay (131 → ~35)

The tool is one subcommand: `--census` prints three counts. The 37 code lines
are correct and stay byte-for-byte (NUL-delimited pipeline, git-side filtering,
partial-count honesty — all real fixes). The 94 comment lines are a design
document for subcommands that were never built ("blocked on the neighbour
backlog CLI") plus per-line war stories.

- Delete the unimplemented-subcommand register (it belongs in issue #12 / the
  backlog-charter spec, which already ships in docs/spec/).
- Collapse each war story to nothing — the fix is self-evident in the code
  (`-z` flags speak for themselves) — or one line where it is not.
- Header becomes 4 lines: what it is, the one subcommand, not-a-gate-CLI.

Deletes ~95 lines. Behavior change: none.

## Step 2 — ops-compress.mjs: split the algorithm from the vault (470 → ~220)

The compressor is two things fused: a ~90-line text algorithm (scrub → elide →
salvage, plus the tool/path carve-outs) that is genuinely good, and a ~200-line
secure-tempdir vault (uid-keyed root, 0700 lstat-verified mkdir chain, symlink
defense, self-gitignoring, dedup state, session-id sanitizing) built so spills
can live in world-writable /tmp for projects that never opted in.

The vault is bloat because the REQUIREMENT is bloat: spilling verbatim tool
output for projects that never ran /cc-operator:start serves nobody — the
charter rule that makes spills meaningful ("evidence must cite the spill path")
only binds in an operated project, which by definition has `.operator/`.

- **Design change: no `.operator/` → no spill, no dedup.** Elide still happens;
  the marker says `[… N chars elided — no .operator/, not spilled …]`. The
  entire tempdir branch — TMP_ROOT_NAME, secureMkdir's chain walk,
  ephemeralRoot's null contract, the uid segment, the legacy-root sweep in
  ops-sessionstart-hook.sh — is deleted, because /tmp is never written to.
  In-project spills keep 0600 files and the self-gitignore (3 lines, cheap,
  real).
- Delete the paired tempdir-wipe block in ops-sessionstart-hook.sh (~30 lines)
  and its coupling-table row.
- Comment diet per rule 2: the containment essay (A/B/C halves, the Copilot
  demo narrative) becomes 4 lines.
- validate_plugin.check_compressor shrinks with it (the tempdir pins go).

Deletes ~250 in compress + ~30 in the hook + ~40 in the validator.
Behavior change: un-operated projects lose spill files they never knew existed.
Operated projects: none.

## Step 3 — statusline.sh: a display gets display-grade code (450 → ~150)

The bar answers one question — "will my Stop be blocked, and is a workflow
running?" — on a 300ms timer, and it currently carries the gate's full security
posture: bounded reads justified against check_reader_bounds, a reverse-tail
deviation scan with its own fail-toward-silence doctrine, stat_probe with
GNU/BSD dispatch, a live-journal mtime freshness protocol, and 241 lines of
comments defending each against reviews. A statusline that is wrong renders a
wrong glyph for 300ms; it does not open the gate. It deserves simple code and
a shared source of truth, not parallel hardening.

- **Design change: the Stop hook's partition logic moves to one sourced file**
  (`scripts/lib/partition.sh`: sentinel_owner_of_name + the mine/foreign scan +
  the deviation scan). The hook and the bar source the same functions — the
  "mirror, not display" coupling (two implementations, one contract, a
  coupling-table row, and check_guard_parity sites holding them aligned) is
  dissolved rather than maintained. Both callers run from the plugin root, so
  sourcing is safe (this is Zone A; nothing here ships to .operator/bin/).
- The bar keeps: read stdin, walk to .operator/, call the lib, render, exit 0
  on anything odd. The workflow segment keeps one mtime call with the
  GNU/BSD probe collapsed to `stat -f %m || stat -c %Y` on one line.
- Delete: the parallel deviation scanner, the duplicated owner parser, the
  per-decision comment essays. Update CLAUDE.md's two mirror rows to one line:
  "hook and bar source scripts/lib/partition.sh".
- check_guard_parity loses its statusline sites (the lib is one site now) —
  the check shrinks, per rule 3 no replacement is added.

Deletes ~300 in statusline + ~100 in the hook (its copy of the same functions)
+ ~80 in the validator. Behavior change: the bar's deviation count switches
from the reverse-tail heuristic to the hook's exact scan — the bar becomes
MORE accurate; the 300ms budget is safe (the hook's scan is a grep over a
file that is small in every real project).

## Step 4 — the comment diet on the gate CLIs (no design change)

ops-verdict/adopt/task/claims/corpus carry 1,740 comment lines, most of them
the development history of 2026-07/08. Per rule 2: every war story compresses
to one WHY line or moves to LANDMINES.md (which exists for exactly this and is
loaded on demand, not per-session). Target: comment share ≤25% per file, code
untouched, `bash -n` + full suite as the only gate needed.

Deletes ~1,200 lines of prose. Behavior change: none — and the diff is
verifiable as comment-only (`git diff -G'^[^#]'` must be empty per file).

## Step 5 — validate_plugin.py: police the product, not the process (2894 → ~1200)

After steps 2–3 shrink their checks, delete outright:

- `check_issue_refs` (189) — markdown link lint; a broken issue link has never
  opened the gate. CI prose hygiene is not a shipping concern.
- `check_replay_charter` (174) — validates that a docs file's example commands
  resolve. The replay charter is a runbook; runbooks are validated by running
  them.
- `check_northstar` (181) — 13 pins on one workflow's internals, duplicating
  what tests/test_workflows.mjs already asserts behaviorally (the node suite is
  the right home and already has the load-bearing assertions).
- `check_platform_idioms` (96) — bash-3.2 lint that shellcheck's pinned CI run
  plus the ubuntu suite already cover behaviorally.
- The measurement-corpus checks tied to decided questions (#24/#70/#58
  instruments): the corpora move out of the shipped tree to a `lab/` directory
  or the git history; their pins go with them.

What stays: manifests, charter caps + section order + tag index, hook wiring,
ledger schema, reader bounds and guard parity FOR THE GATE CLIS (Zone B keeps
hand-copies, so those two checks still earn their lines), install manifest,
workflow meta+alias pins.

Deletes ~1,700. Behavior change: none at runtime (the validator never runs in
a target project).

## Step 6 — decide the optional tier: claims, armgate, corpus (product call)

`ops-claims.sh` (523), `ops-armgate-hook.sh` (212) + the .armed/ machinery in
three CLIs, and `ops-corpus.sh` (521) are complete features with real designs —
and no evidence of field use.

**DECISION (2026-08-22, the maintainer): claims KEEP, armgate DELETE, corpus
DELETE.** Executed same day: ops-corpus.sh and ops-armgate-hook.sh removed with
their wiring (hooks.json PreToolUse entry, `.armed/` writes in task/adopt/
verdict, `--exempt`/`--exempt-mark`/recompute_arm_marker, the `.exempt` reject
arms, `armgate.on` allow-lines, check_armgate, the G2/G3 bash cases, R3 of the
replay charter). The G1 retro-gate and the deviation gate (GATE-EXCEPTION/
HANDOFF-MARK) stay — they are the core evidence gate, not the arm gate.

---

## The arithmetic

| step | deletes | file(s) |
|---|---|---|
| 1 backlog diet | ~95 | ops-backlog.sh |
| 2 compress vault | ~320 | ops-compress.mjs, sessionstart, validator |
| 3 statusline lib | ~480 | statusline.sh, ops-stop-hook.sh, validator |
| 4 comment diet | ~1200 | five gate CLIs |
| 5 validator | ~1700 | validate_plugin.py |
| **total (before step 6)** | **~3,800** | 11,371 → ~7,600 |

Step 6 at its maximum takes the tree to ~6,300 — with the tests shrinking in
proportion, since most of the deleted lines are what the meta-tests test.

Sequencing: 1 and 4 are risk-free and first. 2 and 3 are the design changes —
each is one PR with its behavior-change list restated in the description.
5 lands after 2–3 (its deletions depend on theirs). 6 is gated on a human
decision recorded in this file.
