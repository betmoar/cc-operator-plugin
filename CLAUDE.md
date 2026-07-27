# CLAUDE.md — maintainer handoff for cc-operator

This is the map a maintainer (human or agent) needs before editing. It records
the couplings that break silently and the landmines that have already been hit.
For the design rationale behind every decision, read `docs/spec/`. The build
ledger, plans, pilot runbook/findings, and prior-project evidence were removed
from the shipped tree in 0.3.0 — they live in the git history (tree ≤ v0.2.0)
and the maintainer's local `.archive/dev/` (untracked).

## The load-bearing map

- **`templates/OPERATOR.md` is the product.** Everything else exists to
  materialize, gate, or route to it. It is capped at 150 lines with a fixed
  section order and a citation tag on every rule line; `scripts/validate_plugin.py`
  enforces all three. When you edit it, re-run the validator — the cap is a hard
  gate, not a target.
- **The evidence gate is six scripts that must agree**: `ops-init.sh` scaffolds
  `.operator/` and installs `ops-verdict.sh` + `ops-task.sh` + `ops-adopt.sh`
  into `.operator/bin/` (refreshed on every run — the upgrade path),
  `ops-task.sh` opens a task by dropping the sentinel, `ops-verdict.sh` is the
  *single writer* to `VERDICTS.md`, `ops-adopt.sh` re-stamps sentinel ownership,
  `ops-stop-hook.sh` blocks Stop while a sentinel *this session owns* is
  pending, and `ops-sessionstart-hook.sh` injects the session id the whole
  ownership mechanism keys on. The sentinel filename `<id>` is the shared key;
  change the convention in one place and you break the gate.
- **Sentinel ownership is what makes the gate concurrency-safe** (0.4.0, spec
  `docs/spec/concurrent-sessions.md`). A sentinel stamps `session_id:`;
  `ops-stop-hook.sh` blocks on *mine + unowned* and merely reports *foreign*.
  Unowned fails **closed** — that is what keeps pre-0.4 empty sentinels gating,
  and it is deliberately the opposite default from the no-parser fail-open in
  the same file. Both are right: an unparseable payload is a plugin failure, an
  unowned sentinel is a real open task. `CLAUDE_SESSION_ID` is **not** in the
  Bash tool env — only hooks get `session_id` — so the SessionStart hook is
  load-bearing, not a convenience.
- **The charter references the gate CLIs at `.operator/bin/...`** — the copies
  `ops-init.sh` installs into the target project, because the model's shell has
  no `${CLAUDE_PLUGIN_ROOT}` and a `scripts/` path resolves only inside this
  repo (a v0.2.0 bug: target projects were blocked from stopping and pointed at
  a nonexistent command). `hooks/hooks.json` references the hook by
  `${CLAUDE_PLUGIN_ROOT}/scripts/ops-stop-hook.sh` — the hook runs *from the
  plugin root*. Different bases on purpose; do not "unify" them. Validator
  check 4 enforces the charter path.

## If you touch X, update Y

| If you change… | You must also… |
|---|---|
| the plugin name in `plugin.json` | update `marketplace.json` name, the `/cc-operator:` command refs in `OPERATOR.md` + `SKILL.md`, `README`, and `validate_plugin.PLUGIN_NAME` |
| `templates/VERDICTS-header.md`'s table header | update `validate_plugin.VERDICTS_HEADER` and know you are breaking every existing ledger's grep-compatibility |
| a charter section heading or its order | update `validate_plugin.CHARTER_SECTION_ORDER` |
| the sentinel/pending convention in any `ops-*.sh` | update the other scripts, `tests/test-scripts.sh`, and the EVIDENCE GATE prose in `OPERATOR.md` |
| the `.operator/bin` install set in `ops-init.sh` | update the charter's EVIDENCE GATE paths, the stop-hook fallback message, the *"project-installed gate CLIs"* test case, and `validate_plugin.CHARTER_REQUIRED_CLIS` + `check_scripts` |
| the sentinel body format (`session_id:` line) | update `ops-task.sh`, `ops-adopt.sh`, both parsers (`ops-verdict.sh:sentinel_owner`, `ops-stop-hook.sh:sentinel_owner` — the latter **must** stay builtin-only), and the *"sentinel ownership"*, *"migration safety"*, and *"sentinel BODY is untrusted input"* cases |
| the fragment/lock scheme in `ops-verdict.sh` | update `ops-init.sh` (`verdicts.d/`, `.gitattributes`), the README evidence-gate section, and the *"concurrent appends never interleave"* case |
| the `check_bare_name` reject set in any CLI | update the other two CLIs **and** the `case` filter in both `sentinel_owner` parsers — the hook must reject what the writers reject, or a body our CLIs could never have written reads as a valid foreign owner and the gate opens (*"name guards agree"* + *"untrusted input"* cases) |

> Test cases are referenced **by title**, not by ordinal: `grep '^echo "-- Case' tests/test-scripts.sh`.
> Numbers shift the moment a case is inserted, and a coupling table that quietly points at the
> wrong case is worse than one that points nowhere.
| `plugin.json` `version` | add the matching `## [x.y.z]` as the newest heading in `CHANGELOG.md`, same commit (the release gate fails otherwise) |
| the Stop-hook command in `hooks.json` | keep `ops-stop-hook.sh` + `${CLAUDE_PLUGIN_ROOT}` (validator check 7) |
| an agent's model/tools/NEEDS_CONTEXT | keep it project-agnostic — no `unknowns-harness`/`F1..F13` — and keep `model:` a tier alias (`opus`/`sonnet`/`haiku`), never a pinned ID (validator check 6) |

## Landmines (already hit — do not re-hit)

- **The Stop hook must use bash builtins + one JSON parser only.** It reads
  stdin with `read -r -d ''` (a line loop drops a newline-less final line — a
  real bug that once made the hook see an empty cwd and always exit 0) and
  enumerates `pending/` with a glob, not `find`. Reason: the hook fires on
  *every* session's Stop event; if it depends on a binary missing from a
  stripped PATH, it bricks the session. It must fail *open* (exit 0 + warning)
  when neither `jq` nor `python3` is present. The *"jq-absent fallback"* case
  proves this — keep it.
- **`ops-verdict.sh` refuses malformed cells; it never sanitizes.** A `|` or
  newline inside a cell breaks the one-line 4-cell row schema (the declared
  grep contract), and a task-id containing `/` once let `clear_sentinel`'s
  `rm -f` delete files *outside* `.operator/` (path traversal — a real bug,
  found and fixed 2026-07-10). Both are refused at the single writer with
  exit 2; the *"ledger cell hygiene"* case locks this. Do not "helpfully"
  escape or strip instead — a rewritten cell is no longer evidence.
- **`.operator/` and `OPERATOR.md` keep their names** even though the plugin is
  `cc-operator`. They are the ledger namespace and the charter filename, not the
  command namespace. Renaming them churns the scripts, tests, hook, and charter
  for zero functional gain.
- **The plugin lives at the repo root** (`source: "./"`), flattened from an
  earlier nested `./operator/` layout to match the cc-unknowns standard. Repo-
  relative script paths (in `tests/`) assume root; `${CLAUDE_PLUGIN_ROOT}`
  paths are layout-independent and were unaffected.
- **CI cannot run the live-session tests.** `tests/test-scripts.sh` exercises the
  hooks at fixture level (JSON on stdin). The *live* behavior — the Stop hook
  firing on a real turn-end, `SubagentStop` non-interference, and (0.4.0) that a
  real **SessionStart payload carries `cwd`** and its `additionalContext`
  actually reaches the model — was proven manually, not in CI. A green CI is
  necessary, not sufficient, for the gate; re-verify live after changing a hook.
- **The sentinel BODY is untrusted input.** It is an ordinary file: a merge, a
  checkout, or a patch can supply it, and `.operator/pending/` is not
  gitignored. The stamped owner becomes a fragment *filename*, so an
  unvalidated one reopened the 2026-07-10 traversal through a new door —
  `session_id: ../../PWNED` appended a real ledger row outside `.operator/`
  (found in review of 0.4.0, reproduced, fixed before release). Both
  `sentinel_owner` parsers sanitize **at the parser**, never at the call site,
  so every consumer is covered by construction; an unusable owner degrades to
  `""` = unowned = blocks everyone. Any new reader of that file must do the
  same. Related: strip trailing `\r` — a CRLF checkout otherwise makes a
  session's own id compare unequal and its own task get waved through as
  foreign, a fail-OPEN in the central invariant.
- **Ownership transitions must be atomic, and a sequential test cannot see it.**
  Two TOCTOUs shipped in 0.4.0's first draft: `ops-task.sh` created the sentinel
  with test-then-truncate (two openers both won — 155/200 trials), and
  `ops-verdict.sh` read the owner *before* taking the lock, so an adopt landing
  in between let the former owner delete the new owner's sentinel. Rules that
  follow: sentinel creation uses `set -C` (`O_EXCL`) so the kernel arbitrates,
  never a `[ -e ]` guard; and `ops-adopt.sh` shares `ops-verdict.sh`'s lock,
  with ownership validated *inside* it — the two tools both mutate ownership, so
  validate-then-act must be indivisible across them. The open race is caught by
  a 40-trial loop; the adopt/verdict window is microseconds and does **not**
  reproduce under test, so that assertion is a regression guard only. Treating
  it as evidence would be exactly the "test proves nothing" trap noted below.
- **An owner that can never match is worse than no owner.** The hook compares
  the stamped owner byte-for-byte against the payload's session id, so any
  value a real session id cannot equal — whitespace, a stray space inside —
  classifies the task FOREIGN forever, and foreign never blocks. That is a
  silently disarmed gate reached by a typo (`--owner " SESS-A"`, found in
  review of 0.4.0). Hence: whitespace is refused at all three CLIs *and*
  mapped to unowned in both parsers. Any new owner-shaped field needs both
  halves — refusing at the CLI alone leaves hand-written sentinels unguarded.
  **But that rule is about owners, not names in general.** `check_owner_name`
  is deliberately separate from `check_bare_name`: an interim fix applied the
  whitespace rule to task ids too, which wedged every pre-0.4 task whose id
  held a space (0.3.0 accepted them) — the hook kept blocking while verdict,
  defer, *and* adopt all refused the id, so the session could never stop. When
  tightening a guard, ask which of the two things it is guarding; a rule
  justified by "can never equal a session id" has no bearing on a task id.
- **Anything the Stop hook reads must be bounded.** It fires on *every*
  session's Stop event, so an unbounded read is the same class of hazard as a
  missing binary: a 2 MB sentinel cost ~10s per turn-end tree-wide. The parse
  stops at 20 lines (the owner is line 1 by construction) and the enumeration
  requires `-f` — a directory in `pending/` otherwise emitted a raw bash error
  *as operator guidance*.
- **Nothing but sentinels may live in `.operator/pending/`.** The hook globs
  that directory and treats every entry as a task id. `ops-adopt.sh` originally
  wrote its temp file there, so a crashed adopt left a phantom pending task
  that blocked the session and could be closed into the ledger as a garbage
  row. Temps go in `.operator/`, never `pending/`.
- **A sentinel the Stop hook cannot SEE is worse than no sentinel.** The hook
  enumerates `pending/` with a plain glob, which does not match dotfiles — so a
  `.hidden` task-id created an open task that never blocked (found in review of
  0.4.0, before release). Every name that becomes a filename is refused a
  leading dot in *all three* CLIs; the rule subsumes the older `.`/`..`
  traversal guard. The *"name guards agree"* case asserts the glob premise
  itself, not just the guard, so the reason cannot rot. If you ever switch the
  hook to `dotglob` or `find`, this rule is what you are trading away.
- **Count cells; never glob them.** `'| '*' | '*' | '*' | PASS |'` looks like a
  4-cell schema check and is not one: `*` matches ` | ` too, so a 5-cell row
  satisfied it and `--reconcile` appended it to the ledger. Any future schema
  check splits on the delimiter and counts (`row_is_conformant`). The same trap
  applies to any "shape" assertion written as a glob.
- **A lock whose reclaim path is not itself exclusive is not a lock.** The naive
  timeout — `rmdir` the stale dir, `mkdir` your own — lets waiter B delete
  waiter A's *fresh* lock and enter beside it, with neither over budget.
  Reclaiming requires winning a separate atomic `.lock.reclaim` claim first.
  `ops-verdict.sh` and `ops-adopt.sh` share this implementation; keep them
  identical.
- **`--reconcile` is a write to the ledger of record, so it validates.** It
  originally copied fragment lines verbatim, which routed around the single
  writer's cell hygiene entirely — a merge-corrupted fragment could inject a
  non-conformant row. Any future path that appends to `VERDICTS.md` must
  enforce the 4-cell schema too, or it reopens the same hole.
- **A concurrency test that only asserts the output schema proves nothing.**
  A short `printf` usually lands atomically on a local FS *without* any lock, so
  "100 well-formed rows" passes on the unlocked code too. The *"concurrent
  appends"* case therefore also takes the lock dir by hand and asserts a writer
  waits — that is the assertion that would fail if the lock were removed. Keep it.

## Provenance

- `docs/spec/chief-operator-spec.md` — the design spec (D1–D6, the seams); the
  charter's `[DOC:spec-*]` citation tags resolve to it. Read-only rationale.
- Everything else (build plan + ledger, pilot runbook and findings, the prior
  project's evidence bundle) was removed from the tree in 0.3.0: see git
  history (tree ≤ v0.2.0) or the maintainer's local `.archive/dev/`.
- The one still-open design question from the pilots: the evidence gate is
  opt-in at the mechanism level — nothing forces a sentinel to be opened.
  `ops-task.sh` (0.3.0) makes opening one-command and auditable, but does not
  close the hole. Documented limitation, not a bug.
