# Audit handoff — cc-operator, 2026-07-27

Departing-architect audit of `feat/session-owned-sentinels` @ `14d6ca9`.
Findings ledger: `docs/audit-2026-07-27-findings.md`. Procedure: `docs/PLAYBOOK.md`.
(The audit's own resume-state — `AUDIT_STATE.md`, `AUDIT_LOG.md` — is dev scaffolding,
gitignored per the repo's "never shipped" convention; it lives only in the working tree.)

## Verdict

The mechanism is sound and unusually well defended in its interior — the lock
protocol, the ownership partition, and the ledger write ordering all survived
deliberate abuse (disk-full, immutable filesystem, 8-way stale-lock contention,
directory-as-sentinel, SIGKILL mid-critical-section). Every partial-failure
state I could construct left the gate **blocking**, which is the correct
direction.

The defects were all at the **edges of the model**, and they share one root
cause worth naming: **nothing in this system defines "the project."** Each
component answers that question locally and they disagreed —

- `ops-task.sh` says the project is "the directory holding `.operator/`" and
  refuses to work anywhere else.
- `ops-stop-hook.sh` said it is "wherever the payload `cwd` points," exact-match.
- `ops-init.sh` said it is "wherever you happen to be standing."

F01 (P0) is that disagreement, and it failed open. F05 is the same crack. If you
add a component, the first question to answer is which definition it uses — the
playbook now says: walk up to the nearest `.operator/`, bounded at a `.git`
boundary.

The second theme: **a hardening applied to one call site is not applied.** The
byte bound landed on the Stop hook and missed three other readers (F02), one of
which then broke the lock's own budget (F03). That class of miss is now a build
failure, not a review responsibility.

## What changed

| ID | Severity | Fix | Verification |
|---|---|---|---|
| F01 | **P0** | Stop hook walks up to the nearest `.operator/`, bounded at `.git` and `/`; `cd -P` resolves symlinks | 4 subdir depths now block; unrelated dir and nested repo still no-op |
| F03 | **P1** | `--reconcile` refuses a fragment over `FRAG_MAX_BYTES` (8 MiB) rather than reading it under the lock | 31.85s → **0.18s**; 500-row fragment unaffected |
| F02 | P2 | `read -r -n 512` + 20-line cap on the `ops-verdict.sh` and `ops-adopt.sh` sentinel parsers | 256 MB line: 13.5s/16.8s → sub-second |
| F04 | P3 | `ops-adopt.sh` strips trailing `\r` from copied-forward fields | No CR reaches the operator's report line |
| F05 | P3 | `ops-init.sh` warns when cwd is not a repo / not the repo root; writes `.operator/.gitignore` for lock ephemera | Warning asserted; ephemera ignored |

**Baseline → delta (this audit):** bash `144 passed / 0 failed` →
**`160 passed / 0 failed`** (+16 assertions, cases 17–20). Python `30` →
**`35`**. shellcheck clean, `validate_plugin.py` clean, `release_gate.py
v0.4.0` OK.

> Those are the audit's own numbers, frozen at its close. Later work on the
> same branch (the lock's PID liveness, the statusline segment) moved the
> totals to bash **192** / python **44**. Do not read the figures above as the
> current suite size — read them as this audit's delta. The live total is
> whatever `bash tests/test-scripts.sh` prints today.

## Guardrails added (they fail the build, not a review)

- **`check_reader_bounds`** — every sentinel/fragment reader must use
  `read -r -n N`. Verified to fire when a bound is removed, and verified *not*
  to fire on the scripts' own comments about `read -r` (it did at first; a
  checker that flags its own documentation teaches people to ignore the build).
- **`check_guard_parity`** — all three CLIs must carry both `check_bare_name`
  and `check_owner_name` and reject a leading dot; the hook's parser must reject
  whitespace owners. Verified to fire on each removal.
- **Cases 17–20** in `tests/test-scripts.sh`, each written *before* its fix and
  confirmed failing against the unfixed code (10 failures → 0).

## Read this before your first change

`docs/PLAYBOOK.md`. It is procedure, not prose: what to do when adding a guard,
adding a reader, or touching the lock — each written from a bug that actually
happened here.

The one line to remember: **`validate_plugin.py` passes a Stop hook gutted to
`exit 0`.** Only `tests/test-scripts.sh` catches that. Never accept a green
validator as evidence the gate works.

## Residual risk

| Risk | Why it remains | What would close it |
|---|---|---|
| ~~Time-based crash inference in the lock~~ | **Closed 2026-07-27, same branch cycle.** The holder stamps `host uid pid`; waiters `kill -0`. Dead → immediate reclaim, alive → never reclaimed, unjudgeable → old timed path. | Done — case 21, `check_lock_parity`. |
| A slow holder still loses *mutual exclusion* (not its lock) | Past `LOCK_LIVE_SPINS` (60s) waiters proceed unlocked rather than stealing the lock. Milder failure, still a failure. | Blocking indefinitely trades it for a hang; not obviously better. Revisit only with a real slow-holder report. |
| The two-reclaimer race has no discriminating test | **Not deferred — measured as unreachable.** Six approaches vs. a naive copy all read 0/N; P(collision) ≈ 1e-5. | Nothing short of an injection point inside `lock_acquire`. The structural `rmdir`-refuses-non-empty assertion replaces it. |
| `mkdir`/`O_EXCL` atomicity on network filesystems | The lock and sentinel creation both assume POSIX atomicity. Untested on NFS. | Test on an NFS mount, or document the platform constraint. |
| bash 3.2 compatibility | The `${ARR+"${ARR[@]}"}` idiom is load-bearing on macOS; CI runs modern bash. | A CI matrix entry running `/bin/bash` 3.2. |
| ~~SessionStart `additionalContext` reaching the model~~ | **Closed 2026-07-27 by live check.** A `/clear` in this tree put the id banner in the rehydrated context; a start before `.operator/` existed emitted nothing, which also proves the payload `cwd` was usable (the hook gates on it). Still unverifiable in CI — re-check live after touching either hook. | Done. |
| The gate is opt-in | Nothing forces a sentinel to be opened. Documented limitation since 0.3.0. | Out of scope; a design change, not a bug. |

## Backlog, prioritized

~~1. **PID-based lock liveness**~~ — **done 2026-07-27, same branch cycle**: holder stamps
   `host uid pid`, waiters `kill -0`, both implementations changed together and
   their parity is now enforced by `validate_plugin.check_lock_parity`. The
   pre-fix behaviour was reproduced first (a live 30s holder told it was "a
   crashed writer"; a dead holder costing a waiter 34s).

~~2. **A discriminating reclaim-exclusivity test**~~ — **closed as unreachable,
   not skipped.** Six approaches measured against a deliberately naive copy all
   returned 0/N; the window is ~1e-5. Replaced by a deterministic assertion of
   the property that actually closes the race (a stamped lock dir is non-empty,
   so `rmdir` refuses it), which is mutation-tested: dropping the stamp fails it.

3. **bash 3.2 in CI** — the compatibility contract is real, load-bearing, and
   currently validated only by whoever runs the suite on a Mac.
4. **`capture_baseline.sh` does not detect this repo's suites** — it reported
   `NO SUITE` for a repo that had 160 bash assertions and 35 python tests at
   the time, so the baseline had to be taken by hand. **Not actionable from
   this repo:** that script belongs to the `principal-architect-audit` skill
   (`~/.claude/skills/principal-architect-audit/scripts/`), not to cc-operator.
   Recorded here so the next audit of this repo expects the manual step; fix it
   in the skill.
5. **`--reconcile` admits divergent-evidence duplicates** — dedup is by exact
   line, so one task id with two different evidence cells yields two rows.
   Known, documented in the spec.
6. **The foreign-report line is unbounded** — N foreign tasks produce one line
   of N entries. Cosmetic until N is large.
