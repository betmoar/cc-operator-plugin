# Phase 2 findings — cc-operator @ 14d6ca9

### [F01] Stop hook resolves `.operator/` only at the payload cwd, so a subdirectory cwd silently disarms the gate
- **Location:** scripts/ops-stop-hook.sh:91 (`opdir="$cwd/.operator"`), asymmetric with scripts/ops-task.sh:82
- **Severity:** P0
- **Confidence:** high
- **Claim tag:** CONFIRMED — reproduced; see Evidence
- **Failure trigger:** A session opens a task at the project root (the only place `ops-task.sh` permits), then the Stop payload arrives with `cwd` pointing at any subdirectory of the project. The hook looks for `<subdir>/.operator`, does not find it, and takes the no-op guard at :91-92.
- **Blast radius:** SILENT fail-open of the entire gate. The session ends with an open, unverdicted task and no warning on any channel. This is the precise outcome the plugin exists to prevent; every other mechanism in the repo (ownership, locks, fragments, ledger hygiene) is downstream of this one decision and is bypassed with it.
- **Evidence:** Repro with a real sentinel open at root: `cwd=<root>` -> rc=2 (blocks); `cwd=<root>/src` -> rc=0 (allows); `cwd=<root>/src/deep` -> rc=0 (allows); sentinel still present after both. Asymmetry confirmed by reading ops-task.sh:82 (`[ -d "$OPDIR" ] || die` — refuses to open outside the root) against ops-stop-hook.sh:91 (no upward walk). Pre-existing on `main`: same probe against `git show main:scripts/ops-stop-hook.sh` also returns rc=0 for the subdir case, so this is not a 0.4.0 regression.
- **Fix:** Walk up from the payload `cwd` to locate the nearest ancestor containing `.operator/`, and evaluate the gate against that directory — mirroring how git resolves its own root. Bound the walk at the filesystem root and stop at a `.git` boundary so the hook cannot escape the project. Smallest robust change; keeps the existing no-op guard for genuinely non-operator projects. NOTE: whether this fires in practice depends on whether Claude Code's Stop payload `cwd` tracks the model's shell `cd` or is pinned at session start — that is unresolvable from here and is recorded as an open question, but the fix is correct either way and costs nothing if the payload cwd never moves.
- **Guardrail:** A test that opens a task at a temp-project root, then drives the hook with a payload whose `cwd` is a subdirectory, asserting exit 2. This is the assertion that fails today and would fail again on any regression.

### [F02] The per-line byte bound was applied to one of four sentinel/fragment readers
- **Location:** scripts/ops-verdict.sh:162 and :228, scripts/ops-adopt.sh:135 (all plain `read -r`); contrast scripts/ops-stop-hook.sh:121 (`read -r -n 512`)
- **Severity:** P2
- **Confidence:** high
- **Claim tag:** CONFIRMED — measured; see Evidence
- **Failure trigger:** Any sentinel or fragment file containing one very long newline-less line — the shape a bad `merge=union` resolution, a stray binary, or a truncated write produces. `read -r` consumes the whole line before any line counter can stop it.
- **Blast radius:** Loud, not silent — the operator waits. Bounded to the single CLI invocation that touches the bad file, unlike the Stop hook (which fires tree-wide on every turn-end and is already bounded). Becomes materially worse via F03, where the delay crosses the lock budget.
- **Evidence:** One 256 MB single-line file, timed per component: `ops-stop-hook.sh` 0.17s (bounded) vs `ops-verdict.sh` 13.51s, `ops-adopt.sh` 16.77s, `ops-verdict.sh --reconcile` 32.56s. CHANGELOG.md:131-134 documents the fix as scoped to "The Stop hook's sentinel parse"; no entry claims the other readers were covered, and the code confirms they were not.
- **Fix:** Apply `read -r -n 512` to the sentinel parsers in `ops-verdict.sh:162` and `ops-adopt.sh:135` (the owner line is short by construction, same as the hook). For the fragment reader at `ops-verdict.sh:228`, cap per line as well — a conformant ledger row is far under 512 bytes, and an over-long line is non-conformant by definition and already skipped.
- **Guardrail:** A test asserting all four readers complete a huge-single-line file within a bounded wall-clock, not just the hook. Must be sized to actually discriminate (the existing 32 MB case does not — see the HONESTY NOTE at tests/test-scripts.sh:700-704).

### [F03] `--reconcile` holds the lock across an unbounded read, so a live reconcile gets its lock reclaimed by a concurrent writer
- **Location:** scripts/ops-verdict.sh:214 (`lock_acquire`) through :228 (unbounded fragment read) — the read is inside the critical section; budget at :106 (`LOCK_SPINS=300`)
- **Severity:** P1
- **Confidence:** high
- **Claim tag:** CONFIRMED — live repro; see Evidence
- **Failure trigger:** A fragment file large enough that reconcile's read exceeds the 30s lock budget, while any second `ops-verdict.sh` or `ops-adopt.sh` runs concurrently. The second process presumes the holder crashed, reclaims the lock, and enters the critical section alongside the still-running reconcile.
- **Blast radius:** Two writers in the critical section against the ledger of record — interleaved or lost rows, the exact class the lock exists to prevent. Fails with a warning on the reclaimer's stderr but the ledger damage itself is silent. The comment at ops-verdict.sh:217-221 explicitly claims this scenario was designed out ("would exceed any sane lock budget and push concurrent writers onto the unlocked path, the lock's guarantee evaporating exactly when it matters") — the single-pass rewrite fixed the O(rows x ledger) shape but left the per-line read unbounded, so the same failure returns by a different route.
- **Evidence:** 320 MB fragment; `--reconcile` started, then a normal verdict 2s later. Writer output: `ops-verdict: warning — lock .operator/.lock held >30s; assuming a crashed writer and reclaiming it`, writer rc=0, its row written while reconcile was still running. Timing measured independently at 32.56s for a 256 MB fragment vs a 30s budget.
- **Fix:** Bounding the reads (F02) removes the trigger for realistic inputs and is the smallest robust change — do that first. Additionally, make the lock holder's liveness checkable rather than inferred from elapsed time: write the holder's PID into the lock directory at acquire, and have a would-be reclaimer skip reclamation while that PID is alive (`kill -0`). Time-based crash inference is the root defect; a live-but-slow holder is indistinguishable from a dead one today.
- **Guardrail:** A test that drives a deliberately slow lock holder past the budget with a concurrent writer and asserts the writer does NOT reclaim. This is the assertion the existing suite explicitly lacks — tests/test-scripts.sh:640-644 concedes its reclaim assertions "do NOT fail against the pre-fix code."

### [F04] `ops-adopt.sh` propagates CR bytes from a CRLF sentinel into the operator-facing report
- **Location:** scripts/ops-adopt.sh:135-141 (parse loop, no `\r` strip) and :153 (`CWDLINE` written back verbatim); surfaces at scripts/ops-stop-hook.sh:163
- **Severity:** P3
- **Confidence:** high
- **Claim tag:** CONFIRMED — byte-level repro; see Evidence
- **Failure trigger:** A sentinel arrives with CRLF line endings (a checkout with `core.autocrlf`, an editor on Windows, a merge artifact) and is adopted. `session_id:` is regenerated clean, but `cwd:` and `opened_at:` are copied through with their CR intact.
- **Blast radius:** Cosmetic only, and it does NOT affect gating — verified: a CRLF sentinel adopted to SESS-B still yields rc=2 for SESS-B and rc=0 for SESS-C. The CR reaches the foreign-task report line, where a terminal will carriage-return mid-line and visually truncate the operator's guidance.
- **Evidence:** `od -c` after adopt shows `cwd: /x\r\n` and `opened_at: ...Z\r\n` surviving while `session_id: SESS-B\n` is clean. Hook stderr contains `...opened 2026-01-01T00:00:00Z\r) — not blocking.` — the CR sits inside the emitted line. Gating verified unaffected in the same run.
- **Fix:** Strip a trailing `\r` from `OPENED` and `CWDLINE` in ops-adopt.sh's parse loop, matching what both `sentinel_owner` parsers already do for the owner field.
- **Guardrail:** Extend the existing CRLF test (tests/test-scripts.sh:490-497, which covers the hook and the verdict path) to run a CRLF sentinel through `ops-adopt.sh` and assert the rewritten body contains no CR.

### [F05] `ops-init.sh` scaffolds a ledger in any directory, including one that is not a repository
- **Location:** scripts/ops-init.sh:13 (`mkdir -p "$OPDIR/pending" "$OPDIR/verdicts.d"`) — no precondition check anywhere in the script
- **Severity:** P3
- **Confidence:** high
- **Claim tag:** CONFIRMED — ran it in a bare temp dir; `.operator/` was created with no complaint
- **Failure trigger:** `/cc-operator:start` invoked from a home directory, a scratch dir, or any path that is not the intended project root — for instance when the model's cwd is not where the operator assumed.
- **Blast radius:** Loud-ish but misleading. The ledger and its `.gitattributes` land somewhere untracked, so the evidence of record is written to a location no one will merge or review, while everything appears to succeed. Related to F01: both stem from nothing in the system defining "the project root".
- **Evidence:** `mktemp -d` then `bash scripts/ops-init.sh` → prints "operator ledger ready at .operator/" and creates the full scaffold; `.operator/` present in a non-git directory. Separately, `.operator/.gitattributes` is written but no `.gitignore` is written for the ephemeral `.lock`/`.lock.reclaim` directories, which therefore appear as untracked noise inside a tracked tree.
- **Fix:** Warn (do not hard-fail — a non-git project is a legitimate if unusual target) when `git rev-parse --show-toplevel` fails or does not match `$PWD`, naming the resolved location so the operator can see where the ledger is going. Additionally write `.operator/.gitignore` covering `.lock/` and `.lock.reclaim/` so lock ephemera never reach a commit.
- **Guardrail:** A test asserting `ops-init.sh` in a non-repo directory emits a warning on stderr, and that a freshly initialised `.operator/` ignores its own lock directories.
