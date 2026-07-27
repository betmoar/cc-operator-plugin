# Playbook — changing cc-operator safely

For whoever maintains this next. `CLAUDE.md` is the map (what couples to what,
which landmines are already hit). This file is the **procedure**: what to do,
in order, when you touch a load-bearing component.

The one thing to internalize: **this plugin has exactly one job — refuse to let a
session end while it holds an open task with no recorded verdict.** Every rule
below exists because some change once broke that, silently. A gate that fails
closed is an annoyance. A gate that fails open is worthless *and looks fine*.

---

## The question to ask before any change

> If this change is wrong, does the gate stop blocking?

If yes, you are in the highest-risk category and every rule here applies. If no
(a message string, a doc, a test name), use judgement and move on.

**Fail-open is the only direction that matters.** Reviewers, tests, and CI are
all much better at catching "it broke loudly" than "it quietly stopped working".

---

## Decision procedure: adding a guard to a CLI

Recurring judgement call — three CLIs validate names, and they must agree.

1. **Decide which of the two guards it belongs to.** They are deliberately
   separate and conflating them has already caused an outage-shaped bug:
   - `check_bare_name` — the value becomes a **filename** (task ids, owners).
     Rejects `/`, a leading `.`, `|`, newlines.
   - `check_owner_name` — the value is additionally **compared to a session id**
     (owners only). Adds the whitespace rejection.
2. **Ask what the rule is actually about.** "It could never equal a real session
   id" is a statement about *owners*. Applying it to task ids wedged every
   pre-0.4 task whose id contained a space: the hook still blocked, and verdict,
   defer, *and* adopt all refused the id — no way out at all. If your
   justification names session ids, it does not belong in `check_bare_name`.
3. **Apply it in all three CLIs** (`ops-task.sh`, `ops-verdict.sh`,
   `ops-adopt.sh`) — and if the rule concerns owners, **also** in the `case`
   filter of **both** `sentinel_owner` parsers (`ops-verdict.sh`,
   `ops-stop-hook.sh`). Refusing at the CLI alone leaves hand-written and
   merged-in sentinels unguarded, which is exactly the input class that is not
   ours.
4. **Write the migration test before the guard.** Take a value that was legal
   before your change, and assert it can still be opened, closed, deferred, and
   adopted. A guard that makes an existing task unclosable is worse than the
   bug it fixes.

## Decision procedure: adding a reader of a file

Any new code that reads a sentinel, a fragment, or a ledger.

1. **Treat the content as untrusted.** These are ordinary files. `git merge`,
   `git checkout`, a hand-edit, a truncated write, and a stray binary can all
   produce them. A stamped owner becomes a *fragment filename* — that is how the
   2026-07-10 path traversal came back through a new door in 0.4.0.
2. **Sanitize at the parser, never at the call site.** Then every consumer is
   covered by construction. Degenerate input must degrade to `""` = unowned =
   **blocks everyone**. Fail closed.
3. **Bound the read in BYTES, not just lines.** `read -r` is bounded by lines,
   and one newline-less line is a single line — it gets slurped whole. Use
   `read -r -n 512` plus a line cap.
   - If your reader can stop early (it is looking for one field), the line cap
     is enough.
   - If it must read every line (like `--reconcile`), a per-read cap does **not**
     save you: a 64 MB line is ~131k capped chunks and the loop walks all of
     them (measured 31.85s). **Reject the file on size up front** — see
     `FRAG_MAX_BYTES`.
4. **Never use `read -N`** (capital). It ignores newlines, returned an empty
   chunk here, and made every sentinel parse as unowned — every session blocking
   on every task, with the whole suite still green.

## Decision procedure: touching the lock

`ops-verdict.sh` and `ops-adopt.sh` carry a byte-identical lock implementation,
delimited by `# >>> LOCK BLOCK` / `# <<< LOCK BLOCK`.

1. **Change both — the build now checks.** They contend on the same
   `.operator/.lock`; a divergence is not a style problem, it is two different
   ideas of mutual exclusion. `validate_plugin.check_lock_parity` compares the
   marked block byte for byte (normalizing only the tool name in warnings), so
   editing one file fails the build immediately rather than four minutes later
   in the bash suite. Edit the block in one file and copy it verbatim.
2. **Keep every wait bounded, and bound it to degrade to a *milder* failure.**
   An unexpirable claim is a deadlock with extra steps — the `.lock.reclaim`
   marker was first written with no expiry and wedged every later writer forever,
   worse than the stale lock it fixed.
3. **Never lengthen the critical section without re-checking the budget.**
   A holder that outruns `LOCK_LIVE_SPINS` (60s) no longer loses its lock, but
   its waiters do give up and proceed *unlocked* — the milder failure, still a
   failure. Before adding work under the lock, ask: what is the worst-case
   wall-clock? Slow `--reconcile` runs caused this twice.
4. **Crash detection asks the kernel, not the clock** (was the root weakness
   behind F03). The holder writes `host uid pid` to `.lock/holder`;
   waiters `kill -0` it. Three outcomes, and all three matter:
   - **dead** → reclaim at once (the timed draft made every waiter behind a crashed
     holder sit out the full 30s budget; measured 34s).
   - **alive** → *never* reclaim, however long it runs. Wait, then proceed
     unlocked. Stealing a running writer's lock is the bug this replaced.
   - **unjudgeable** → fall back to the timed budget unchanged. Not a leftover:
     `kill -0` across uids fails with EPERM, indistinguishable from "dead", so
     judging a foreign uid would reclaim a LIVE lock. Only our own host+uid are
     judgeable. This branch is reached constantly: `mkdir` and the stamp are not
     one atomic step, so a lock is briefly held-but-unstamped and a waiter
     spinning through that window sees no record.
5. **Do not remove the stamp to "simplify".** A stamped `.lock/` is non-empty,
   and `rmdir` refuses non-empty directories — that is what actually stops a
   second reclaimer from stepping onto a fresh lock, deterministically, where
   the timing argument only makes it unlikely. The *"a held lock is stamped, and
   a stamped lock cannot be rmdir'd"* case fails the moment the stamp goes.
   (It also means a stamped lock survives `rm -rf`: delete `holder` first in
   any teardown.)
6. **Do not try to test the two-reclaimer race by timing.** Six approaches were
   measured against a deliberately naive copy — cold-start racing, a ~1s
   critical section, killing a live holder while both waiters spun, 0.4s of
   injected delay inside the reclaim path — and all read 0/N. Microsecond
   sequence, 0.1s spin: P(collision) ≈ 1e-5. Reaching it means shipping an
   injection point inside `lock_acquire`, which trades a real hazard for a test.
   Assert the structural property in step 5 instead.

---

## Changing the Stop hook — the highest-risk file in the repo

It runs on **every session's every turn-end**. Read `CLAUDE.md`'s landmine
section first; then:

1. **Bash builtins + at most one JSON parser.** No `grep`, `sed`, `awk`, `find`.
   If it depends on a binary missing from a stripped PATH, it bricks sessions.
2. **Preserve both intentional fail-opens** — no-parser and `stop_hook_active`.
   A broken hook must never make a session unquittable.
3. **Everything else fails closed.** Unowned, unreadable, malformed, oversized:
   all block.
4. **Anything you read must be bounded.** See above.
5. **Verify the partition on a NORMAL sentinel, through the real parser.** The
   `read -N` incident broke ownership completely while all 133 assertions stayed
   green, because nothing exercised the ordinary path end-to-end.

**Run after any change:**
```sh
bash tests/test-scripts.sh          # the behavioural suite — the one that matters
shellcheck scripts/*.sh tests/test-scripts.sh
python3 scripts/validate_plugin.py  # contracts; does NOT test behaviour
```
`validate_plugin.py` passes a hook gutted to `exit 0`. Only the bash suite
catches that. Never treat a green validator as evidence the gate works.

---

## Verifying a fix — the part that is usually skipped

1. **Record the baseline before you change anything**, and report the delta
   in that shape — e.g. `144 passed/0 failed → 160 passed/0 failed` (a real
   delta from the 2026-07-27 audit; the suite has grown since, so take your own
   baseline rather than trusting any number written down here). "No
   regressions" without a recorded baseline is not a claim, it is a hope.
2. **Write the test first and watch it fail.** A guardrail that passes before
   the fix guards nothing.
3. **Then prove it discriminates**: revert the script, re-run, confirm the new
   assertions fail, restore. Do this — three tests in this suite were found to
   pass against the broken code, and are now labelled as guards rather than
   evidence.
4. **If it cannot discriminate, say so in the test itself.** There are
   `HONESTY NOTE` comments in the suite for exactly this. A test that proves
   nothing while looking authoritative is worse than no test.

## What a green suite does NOT prove

Keep this list honest; add to it when you find a new gap.

| Not proven | Why |
|---|---|
| Lock exclusivity under reclaim | Needs two writers timing out simultaneously. Code-review only. |
| Bounded parse at scale | Sized to discriminate at 64 MB; the real-world bad case is larger. |
| A live SessionStart payload carries `cwd`, and `additionalContext` reaches the model | End-to-end, needs a real session. Verified live, never in CI. |
| bash 3.2 compatibility | CI runs modern bash. The `${ARR+"${ARR[@]}"}` idiom is load-bearing on macOS and is validated only by local dev. |
| `mkdir` atomicity on network filesystems | The lock and O_EXCL sentinel creation both assume POSIX atomicity. Untested on NFS. |
