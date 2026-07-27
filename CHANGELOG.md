# Changelog

All notable changes to **cc-operator** are recorded here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/).

The version in [`.claude-plugin/plugin.json`](.claude-plugin/plugin.json) is the
single source of truth; bump it in the same commit as the changelog entry.

## [Unreleased]

## [0.4.0] - 2026-07-27

Concurrent sessions in one working tree no longer trap each other. Field report
and design: `docs/spec/concurrent-sessions.md`.

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
  of `printf`'s buffer size. A lock held >5s is treated as stale: the writer
  proceeds with a warning, because a stale lock must never cost a real verdict.
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
- Test cases 8–11 in `tests/test-scripts.sh` covering the spec's five
  acceptance criteria: the ownership partition, pre-0.4 migration safety, the
  writer's ownership refusal and adoption, 2×50 concurrent appends with a
  full-schema assertion, genuine lock mutual-exclusion, and reconcile.
- Validator: the SessionStart hook must be registered via
  `${CLAUDE_PLUGIN_ROOT}`, and every CLI in the `.operator/bin` install set must
  be named in the charter by its project-relative path.

### Fixed (found in review of this branch, before release)
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

### Known limitations
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
