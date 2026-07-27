# Design note — cc-operator: concurrent sessions share one sentinel namespace

**Status:** **implemented in 0.4.0** (§4.1–4.4; see the deltas noted inline).
**Written against:** cc-operator 0.3.0 — line numbers below are that source.
**Origin:** observed in the field 2026-07-25, two Claude Code sessions in one working tree of
`layerprocgen-babylon`. Every claim below was verified against the installed 0.3.0 source in the
session that hit it; line numbers are that source.

---

## 1. What happened

Session A (spec/design work, idle) and session B (executing an 8-task implementation plan under
ORCHESTRATED mode) ran concurrently in the **same directory on the same branch**. Session B opened
a tracked task — `.operator/pending/axis3-phase1`. Session A then tried to end.

Session A's Stop hook blocked, twice, naming session B's task:

```
operator: pending verdict(s): axis3-phase1 — run .operator/bin/ops-verdict.sh <id> …, or --defer
```

Session A could not clear it without violating the charter, so it could not end at all.

## 2. Root cause

The pending namespace is project-global and unowned.

- `ops-task.sh:26` creates the sentinel as an **empty file**: `: > "$OPDIR/pending/$ID"`.
  Nothing is written into it — no owner, no timestamp, no cwd.
- `ops-stop-hook.sh:77-84` enumerates the directory and blocks on **anything** present:
  ```sh
  for f in "$opdir/pending"/*; do id="${f##*/}"; pending="…$id"; done
  [ -n "$pending" ] && exit 2
  ```
- `grep -rn session_id scripts/` across `ops-task.sh`, `ops-verdict.sh`, `ops-stop-hook.sh`,
  `ops-init.sh` → **zero hits.** cc-operator has no session concept at all.

The hook is otherwise careful about context: it deliberately reads `cwd` **from the Stop payload,
never its own cwd** (documented at `ops-stop-hook.sh:14-16`). Session identity is simply the axis
that was never modelled — reasonably, since the design predates concurrent sessions.

### Why this is worse than a nuisance

The only ways out of the block both damage the ledger:

1. **Close the row** — writes a PASS/FAIL for work this session did not perform and cannot attest
   to. That is precisely the failure `EVIDENCE GATE` and CLAUDE.md H8 ("writing evidence you did
   not capture") exist to prevent. The charter's own rules forbid the only available escape.
2. **`--defer`** — writes a DEFERRED-VERDICT line to DECISIONS.md contradicting a task that is
   actively progressing, *and* clears the sentinel as a side effect (`ops-verdict.sh:42`).

Both silently **disarm the other session's completion gate mid-run.** The Stop hook is cc-operator's
strongest guarantee — a session cannot quit with open criteria — and one bystander session closing a
row it doesn't own removes that guarantee without any signal to the session that was relying on it.

Field evidence that B was live, not stale: sentinel mtime advanced 22:12:03 → 22:24:20 (re-opened
per task), `axis3-phase1` rows in VERDICTS.md went 3 → 6, and three commits landed in the interval.

## 3. Secondary defect found while investigating: unsynchronized ledger appends

`ops-verdict.sh` appends with a bare `>>` and no lock:

- `:73` — `printf '| %s | %s | %s | %s |\n' … >> "$VERDICTS"`
- `:51` — the `--defer` line `>> "$DECISIONS"`

The header comment claims "append + sentinel-clear are one atomic script action, so append-only
holds by construction". Append-only holds; **atomicity does not.** Two sessions closing rows
concurrently can interleave output mid-line. A single `printf` of a short line usually lands
atomically on a local FS, but that is a property of the buffer size, not a guarantee — and it is
exactly the kind of assumption that fails under a slow FS or a longer evidence cell.

Compounding it: `.operator/VERDICTS.md` and `DECISIONS.md` are **tracked files** (`git ls-files
.operator` → both). Two sessions on two branches therefore produce divergent append-only ledgers —
the worst possible merge-conflict shape, resolved by hand at merge time. Worktrees do **not** solve
this; they make it more likely.

## 4. Proposal

### 4.1 Stamp ownership into the sentinel (primary fix)

The sentinel is empty today, so its contents are free real estate. Write owner metadata:

```
session_id: <id>
cwd: <path>
opened_at: <ISO8601>
adopted_at: <ISO8601>    # only on sentinels re-stamped by ops-adopt.sh
```

`ops-stop-hook.sh` already parses the payload for `cwd` and `stop_hook_active`; add `session_id`
alongside (cc-reload proves it is present in Claude Code hook payloads —
`precompact-hook.sh:19`). Then block only on sentinels whose `session_id` matches, **or that carry
no owner at all**.

Unowned sentinels keep blocking, so:
- pre-0.4 sentinels written by an older `ops-task.sh` still gate correctly (backward compatible);
- a sentinel whose owner cannot be determined fails **closed**, matching the plugin's evidence-first
  posture. (Note this is the opposite default from the parser-missing case at `:34`, which fails
  *open* so a broken hook cannot brick a session. Both are right: an unparseable payload is a
  plugin failure, an unowned sentinel is a real open task.)

Non-owned pending tasks should still be **reported** — as information, not a block:

```
operator: 1 pending verdict owned by another session (axis3-phase1, opened 22:24) — not blocking.
```

That preserves the visibility that made the collision diagnosable in the first place.

### 4.2 The constraint that shapes the CLI change

**`CLAUDE_SESSION_ID` is not set in the Bash tool environment** — probed directly in the affected
session: `CLAUDE_PROJECT_DIR`, `CLAUDE_SESSION_ID`, `CLAUDE_PLUGIN_ROOT` all report `unset`. Only
*hooks* receive `session_id`, via the stdin payload. `ops-task.sh` is agent-invoked CLI, so **it
cannot self-identify.** Three workable options:

| option | mechanism | cost |
|---|---|---|
| **A. SessionStart injects the id** | a SessionStart hook emits the id via `additionalContext`; the agent passes `ops-task.sh <id> --owner <session-id>` | one new hook; cc-reload already emits `additionalContext`, so the pattern is in-house |
| **B. cwd as identity** | stamp `cwd` only; one session per worktree by convention | zero new plumbing, but identical to today when two sessions share a tree — which is the reported case |
| **C. Hook-written owner file** | SessionStart writes `.operator/.session` with the id; `ops-task.sh` reads it | breaks with two sessions in one tree (single slot, last writer wins) — same bug, moved |

**Recommendation: A**, with B's `cwd` stamped as a secondary discriminator so a worktree split alone
already helps. C is a trap — it reintroduces the singleton-slot problem this note is about.

> **Implemented (0.4.0): A. One correction to B's role.** `cwd` cannot discriminate: the hook only
> ever enumerates `$cwd/.operator/pending/` using the cwd from its *own* payload, so a stamped cwd
> always equals the payload cwd and the comparison is a tautology. It is stamped anyway — as
> forensics, which is exactly how the field collision was diagnosed — but `session_id` is the only
> real key. Shipped as `scripts/ops-sessionstart-hook.sh` + a `--owner` flag on `ops-task.sh`,
> `ops-verdict.sh`, and the new `ops-adopt.sh`.

### 4.3 Lock the ledger writes

Wrap the append in `flock` where available, degrading gracefully:

```sh
if command -v flock >/dev/null 2>&1; then
  flock "$VERDICTS" -c 'printf … >> "$VERDICTS"'
else
  printf … >> "$VERDICTS"     # current behaviour
fi
```

macOS ships no `flock(1)` by default, so the fallback matters; `mkdir`-based locking is the portable
alternative if you want it unconditional. Cheap either way, and it makes the header comment's
atomicity claim true.

> **Implemented (0.4.0): the unconditional `mkdir` variant.** `command -v flock` exits 1 on the
> maintainer's macOS, so the `flock` branch would be dead code on half the target platforms and the
> two platforms would take different code paths — the worse outcome.
>
> **Correction to this section's last sentence:** it does *not* make the atomicity claim
> unconditionally true, and the shipped headers say so. A lock cannot distinguish a crashed holder
> from a slow one, so there is a timeout: past it the holder is presumed crashed and the lock is
> **reclaimed** (an earlier draft merely ignored it, which left a hard-killed writer's lock
> poisoning every later write forever while providing no exclusion anyway). A writer that genuinely
> ran longer than the budget would be overrun. The budget is set well above the slowest real
> critical section — which required making `--reconcile` a single pass rather than a `grep` per
> row; at one `grep` per row a 3000-row ledger took ~7s and would itself have tripped the timeout,
> pushing concurrent writers onto the unlocked path exactly when contention was highest.

### 4.4 Ledger divergence across branches — open design question

Not solved by 4.1–4.3, and the one that needs your judgment: two branches, two appended ledgers,
manual merge. Options are per-session ledger fragments merged at close (`.operator/verdicts.d/<id>.md`
concatenated on demand), an explicit single-owner lock (one session may write, others queue), or
accepting hand-merges as the documented cost of concurrency. Worth deciding before recommending
worktrees to users, because worktrees make concurrent sessions *easier* and therefore this *more
frequent*.

> **Implemented (0.4.0): fragments, as a repair path rather than the ledger of record.**
> `VERDICTS.md` stays the single grep-compatible file every consumer depends on; each row is *also*
> mirrored to `.operator/verdicts.d/<owner>.md`. Fragments merge cleanly across branches, and
> `ops-verdict.sh --reconcile` appends back any row missing from `VERDICTS.md` — so a bad merge is
> recoverable from any resolution. `.operator/.gitattributes` marks all three append-only paths —
> `VERDICTS.md`, `DECISIONS.md`, and `verdicts.d/*.md` — `merge=union` to
> avoid most conflicts up front.
>
> `--reconcile` **repairs, never regenerates.** `VERDICTS.md` also carries hand-appended BAR blocks
> (charter § ENGAGEMENT CONTRACT); a rebuild-from-fragments would destroy them. Locked by a test.
> It also **validates**: a fragment is an ordinary file that a merge or a hand-edit can corrupt, so
> reconcile enforces the same 4-cell `PASS|FAIL` schema the direct writer does and skips (loudly)
> anything that fails it. Without that, `--reconcile` would be a hole straight through the single
> writer's cell hygiene — found in review before release, not in the field.
>
> `DECISIONS.md` deliberately gets the lock and `merge=union` but **no** fragments — it is a log,
> not the evidence of record.

## 5. Suggested acceptance criteria

1. Two sessions, one tree: session A opens task X; session B's Stop hook exits 0 and reports X as
   foreign. Session A's Stop hook exits 2 on X.
2. A sentinel with no owner metadata (pre-0.4 format) still blocks every session — migration safety.
3. Session A closes X; A's Stop hook then exits 0. B cannot close X through `ops-verdict.sh`:
   a foreign `--owner` is refused (exit 2, no row, sentinel intact). B *can* reach X by first
   re-stamping ownership with `ops-adopt.sh`, which is a deliberate, recorded act (`adopted_at:`
   in the sentinel) — see the note below. The criterion is about the writer, not about
   unreachability.
4. Concurrent `ops-verdict.sh` invocations produce N well-formed rows, zero interleaved lines
   (loop-drive it: two shells × 50 appends, assert `wc -l` and that every line matches the 4-cell
   schema) — **and** assert lock contention directly, because the loop-drive alone does not
   discriminate: a short `printf` usually lands atomically on a local FS, so the schema check
   passes against an unlocked build. Pre-take `.operator/.lock`, assert a writer blocks, release
   it, assert the writer proceeds.
5. `stop_hook_active` loop guard (`ops-stop-hook.sh:69`) and the no-parser fail-open (`:34`) behave
   exactly as today — neither path regresses.

> **Status of §5 (0.4.0):** all five criteria are executable in `tests/test-scripts.sh` — criteria
> 1+3 in the *ownership partition* case, criterion 2 in *migration safety*, the writer-side of
> criterion 3 in *writer ownership gate + ops-adopt*, criterion 4 in *concurrent appends*,
> criterion 5 in the *Stop hook exit codes* and *jq-absent fallback* cases, re-run unchanged.
> (Cases are named, not numbered, on purpose: ordinals shift when a case is inserted.)
>
> **Criterion 3 is enforced on the writer, not absolutely.** `ops-verdict.sh` refuses a foreign
> `--owner`; `ops-adopt.sh` is a door around that, by design. After a `/clear` a session's id has
> rotated and its own tasks look foreign, which is exactly what adoption is for, and nothing
> distinguishes "my orphan" from "someone else's live task" without a liveness signal the plugin
> does not have. Explicit ids only (no bulk adopt) makes a takeover deliberate and auditable rather
> than accidental. Criterion 3's wording above was corrected to match; an earlier draft asserted the
> absolute, which the suite then contradicted by asserting adopt-then-close works.
>
> **What a green suite does NOT prove.** Stated plainly, because a passing test that discriminates
> nothing is worse than no test:
> - *Lock exclusivity under reclaim.* No test distinguishes the shipped exclusive-reclaim protocol
>   from the naive `rmdir`+`mkdir`; reproducing the two-waiter race needs two writers timing out
>   simultaneously. Verified by code review only.
> - *Bounded parse.* The huge-sentinel case uses 32 MB, where the unfixed hook takes ~1s — under the
>   threshold. The cost is linear (256 MB measured at 8.5s unfixed vs 0.16s fixed); discriminating
>   would put a quarter-gig of writes in every CI run. Accepted, not fixed.
> - *`cwd` is not a discriminator.* §4.2's argument that the hook never compares the stamped `cwd` is
>   asserted nowhere in the suite; a regression that made the hook enumerate by its own `$PWD` would
>   silently reintroduce the worktree-collision shape.
> - *`DECISIONS.md merge=union`.* Written by `ops-init.sh`, asserted by nothing.
> - *A real SessionStart payload carries `cwd`, and `additionalContext` reaches the model.* Criterion
>   1 depends on this end-to-end — the agent must learn its own id to pass `--owner` — and it is
>   verified live, never in CI.
>
> **Known gaps not addressed by this note.** Recorded so they are not rediscovered as surprises:
> - A session whose payload `cwd` is a *subdirectory* of the project finds no `.operator/` there and
>   exits 0 with tasks still open — the gate silently does not apply. Reproduced; **pre-existing on
>   `main`**, not introduced by ownership, and deliberately out of scope here.
> - The foreign-task report names task ids but not their owners, so with three or more sessions a
>   bystander cannot tell which session to chase.
> - `--reconcile` dedups by exact line, so one task id whose evidence cell diverged across branches
>   yields two admitted rows. `merge=union` makes this reachable.
> - Owner ids are assumed unique across concurrent sessions in one tree; two sessions sharing an id
>   share a fragment file.

## 6. Companion note

The same investigation produced a matching note for cc-reload
(`cc-reload-plugin` → `docs/spec/concurrent-sessions.md`), whose digest
(`.reload/session.md`) is a singleton slot that one session silently overwrote for another. Same
root shape — per-session state in a per-project location with no owner — but the **opposite** key
is correct there: a digest must survive `/clear`, which is exactly when `session_id` changes, so
cc-reload keys on cwd/worktree while cc-operator keys on session id. A shared "make both
session-aware" change would fix one and break the other.

## 7. Scope note

This note deliberately does not touch the charter document (`OPERATOR.md`) — the charter's
single-writer rule is *correct*, it simply is not mechanically enforced across sessions. 4.3 makes
the mechanism match the stated contract; 4.1 makes the gate match the charter's intent that a
session is accountable for **its own** criteria.

> **Amended in 0.4.0.** The charter's *rules* are unchanged, as intended — but its *CLI surface*
> had to change, because a rule the operator cannot execute is not enforced: EVIDENCE GATE now
> shows `--owner` on the task/verdict commands, and RECOVERY PROTOCOL gains an adopt step (a
> session id rotates on `/clear`, which is precisely when RECOVERY runs). Still under the
> 150-line cap the validator enforces.
