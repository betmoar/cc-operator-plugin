# Playbook — changing cc-operator safely

For whoever maintains this next. `CLAUDE.md` is the map (what couples to what,
with the landmine narratives in `docs/LANDMINES.md`). This file is the **procedure**: what to do,
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

It runs on **every session's every turn-end**. Read `docs/LANDMINES.md` first; then:

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

## Changing a workflow (workflows/*.js) — the copy-paste invariant

The workflow sandbox forbids `import()` (measured 2026-07-30 — "import() is
not available in workflow scripts"), so the tier-resolution + args-normalization
block is **copy-pasted** across review.js, brainstorm.js, plan.js. There is no
shared module. `check_workflow_parity` is the only thing holding the copies
together — the same lesson `check_lock_parity` enforces for the bash lock block.

When you change the tier-validation logic (ROUTABLE, BAD_CHARSET, the args
normalizer, the unknown-tier-key guard):

1. **Change all three files.** `check_workflow_parity` fails the build if
   ROUTABLE or BAD_CHARSET diverge. DEFAULT_TIERS is NOT a parity invariant —
   each workflow declares only the tiers it uses, so do not "align" them.
2. **A new shared regex constant must be added to `WORKFLOW_PARITY_CONSTS`** in
   validate_plugin.py, or it can drift undetected.
3. **`args` arrives as a JSON string, not an object** (the Workflow tool
   stringifies it in transit). Every workflow normalizes with the `A` IIFE;
   review.js additionally accepts a bare-string target. If you change the
   normalizer, decide deliberately whether the bare-string branch applies.
4. **The JS ROUTABLE + BAD_CHARSET must agree with `ops-tiers.sh`'s
   `check_routable`** (charset `[A-Za-z0-9._:/@[]-]`). The shell is the
   canonical gate; the JS is its mirror. A divergence is audit F01 — silent
   mis-route on a hand-written `args.tiers` bypassing the resolver.
5. **No `node --check`** in the validator — it is too lenient (returns exit 0
   on redeclared consts, unclosed parens). A real syntax error surfaces at
   launch; the structural checks (meta-first, ROUTABLE canonical+applied) are
   what the build can enforce.

### Adding a workflow

Drop a `.js` in `workflows/`. It must: begin with `export const meta = {…}`,
declare `const ROUTABLE` and `const BAD_CHARSET` byte-identical to the others,
declare `const KNOWN_TIERS = [...]` equal to the resolver's `TIER_NAMES`, and
apply `ROUTABLE.test` + `BAD_CHARSET.test` in a tier-validation loop whose
unknown-key check is `if (!KNOWN_TIERS.includes(name))`.
`check_workflows` + `check_workflow_parity` + `check_workflow_tier_namespace`
enforce all three at build time.

### The tier-namespace coupling (audit F07, 2026-07-31)

`KNOWN_TIERS` (what a workflow *accepts* in `args.tiers`) and the resolver's
`TIER_NAMES` (what `ops-tiers.sh` *emits*) must be the same set, even though a
workflow only *uses* a subset (its `DEFAULT_TIERS`). The trap: if you add a tier
to the resolver (e.g. a fifth seat) and forget to add it to every workflow's
`KNOWN_TIERS`, forwarding the resolver's full map throws on the new key — exactly
the F07 bug. `check_workflow_tier_namespace` holds this, but it is a regex
reader, so:

- **`KNOWN_TIERS` must be a real statement, not a comment.** The check matches
  code lines only (it strips `//` lines, like `check_reader_bounds`). A
  `// const KNOWN_TIERS = …` in a comment does NOT satisfy it.
- **A rename/retype of the resolver's `TIER_NAMES=` line breaks the regex.** If
  you change it to `readonly TIER_NAMES=` or single quotes, both work (the regex
  accepts them); anything else (an array, a different var name) makes the check
  **fail loud** — update `_resolver_tier_names`'s regex, do not silence it. The
  check must never fail *open* (silently pass) — that was the review-caught
  defect in the first version of this guard.
- **`DEFAULT_TIERS` ≠ `KNOWN_TIERS`.** DEFAULT_TIERS is what the workflow
  dispatches (review: 2 tiers); KNOWN_TIERS is what it accepts (always all 4).
  Do not "fix" a workflow by making them equal — that re-opens F07.

### Dead agents: null is a DEATH, not an empty result (audit F31 + F32)

`agent()` resolves to **null** when the dispatched agent dies — schema
mismatch, timeout, rate limit. Null is NOT "found nothing"; every consumer of
an agent's return must decide which of the two it is holding, or the death
launders into the passing shape:

- **Fan-outs** (a lens, a vet, a shard): mark the death and carry it to both
  the log AND the return value. Never let a `.then()` rewrite null into a
  truthy empty object before a `.filter(Boolean)` — that was F31's worst
  variant (the filter dropped nothing; a naive ratio log printed 5/5 with a
  dead lens). Pattern: `dead: r == null` in review.js, `vettingIncomplete` in
  plan.js.
- **Terminal single calls** (the one judgment agent a workflow ends on): a
  null here must produce an explicit `{error: …}` return that CARRIES the
  surviving upstream work (shard digests, directions) so only the dead step is
  re-run — never a default that reads as clean (F32: a dead adversarial made
  `blocked:false`, the same value a CONFIRMED produces; the hard-stop gate
  failed open).
- **Gates fail CLOSED.** If the dead agent was a verifier, its absence blocks
  (review.js: `blocked: adversarial == null || …`, plus `unverified: true` so
  the operator can tell death from refutation).
- Locking tests exist for every case above ("dead terminal agents fail loud"
  in test_workflows.mjs); a new fan-out or terminal call gets the same pair
  (dead → loud; alive → unchanged) or it will regress silently — null-handling
  has no crash to catch it.

### The env-overridable lock budgets (audit F08, 2026-07-31)

`LOCK_SPINS`, `LOCK_LIVE_SPINS`, `RECLAIM_WAIT` in the LOCK BLOCK are
`${VAR:-default}` — a test seam (the slow concurrency cases run on a tiny
budget). They are validated as positive integers at resolve time in BOTH
ops-verdict.sh and ops-adopt.sh (byte-identical block). If you change the lock:

- **Any new budget var must get the same positive-int guard**, or a non-numeric
  value wedges the spin loop forever (`[ -ge ]` errors inside the `if`, `set -e`
  doesn't fire) — review F-A.
- **`RECLAIM_WAIT` must stay `< LOCK_SPINS`.** The backoff `i=$((LOCK_SPINS -
  RECLAIM_WAIT))` goes non-positive otherwise and each defer pays the full
  RECLAIM_WAIT — review F-C.
- The whole validation block is inside `# >>> LOCK BLOCK … # <<< LOCK BLOCK`,
  so `check_lock_parity` enforces it stays byte-identical in both files. A
  comment that names the sibling file by name will break parity (the normalizer
  only rewrites `ops-tool:` message prefixes) — refer to "the sibling CLI".

### The renderer's ownership + body-source rules (audit F14/F17/F18/F21/F22, 2026-08-01)

`ops-render.sh` writes into the USER'S `.claude/agents/` — treat every change
to its delete/write path as a data-loss surface:

- **Delete only what you own.** Rendered files end with the `RENDER_MARK` line;
  render/revert remove marked files only, and a seat whose target name is held
  by an UNMARKED file dies before anything is deleted (F17). Never reintroduce
  a glob-delete: `op-*` is the user's namespace too (op-reviewer is shipped but
  not a seat — hand-shadowing it is legitimate).
- **Seat names are allowlisted** (`[A-Za-z0-9_-]`), and the seat_add override
  filter compares the name FIELD literally (awk `$1 != n`). Both guards exist
  because a blocklist + BRE interpolation let `s.out` silently delete the
  `scout` record (F18). A new place a seat name flows into (pattern, filename,
  awk -v) inherits the allowlist, not a new blocklist.
- **Bodies are single-sourced from plugin-root agents.** Lookup order:
  `agents/op-<seat>.md` → `agents/_templates/<seat>.tmpl` → `default.tmpl`.
  Editing a seat's contract happens in the plugin-root agent file ONLY — a
  template that shadows a shipped seat re-opens F14 (the default.tmpl era
  stripped Write/Edit from both implementer seats).
- **Default seat tiers match the aliases** (author=JUDGMENT, mechanic=IMPLEMENT,
  scout=RECON, verifier=JUDGMENT; crawler/brainstorm=MECHANICAL by design).
  Down-tiering is a tiers.env act by the operator, never a shipped default —
  the charter's "judgment work never runs below judgment tier" applies to
  defaults too (F21).
- **A workflow agentType must name a shipped plugin-root agent** — rendered
  project-layer agents don't exist in the plugin registry
  (`check_workflow_agent_types`, F22). When you add a seat a workflow
  dispatches, ship the agent file, then reference it.
- **tiers.env has two line kinds and two readers.** `ops-tiers.sh` skips seat
  lines (after validating the tier VALUE); `ops-render.sh` consumes both. A new
  line kind must be taught to BOTH parsers in the same commit, with a test
  feeding it to each (F15 — the scaffold's own example killed the resolver).
