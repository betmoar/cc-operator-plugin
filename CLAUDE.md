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
| the `.operator/bin` install set in `ops-init.sh` | update the charter's EVIDENCE GATE paths, the stop-hook fallback message, `tests/test-scripts.sh` case 6, and `validate_plugin.CHARTER_REQUIRED_CLIS` + `check_scripts` |
| the sentinel body format (`session_id:` line) | update `ops-task.sh`, `ops-adopt.sh`, both parsers (`ops-verdict.sh:sentinel_owner`, `ops-stop-hook.sh:sentinel_owner` — the latter **must** stay builtin-only), and `tests/test-scripts.sh` cases 8–10 |
| the fragment/lock scheme in `ops-verdict.sh` | update `ops-init.sh` (`verdicts.d/`, `.gitattributes`), the README evidence-gate section, and `tests/test-scripts.sh` case 11 |
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
  when neither `jq` nor `python3` is present. `tests/test-scripts.sh` case 5
  proves this — keep it.
- **`ops-verdict.sh` refuses malformed cells; it never sanitizes.** A `|` or
  newline inside a cell breaks the one-line 4-cell row schema (the declared
  grep contract), and a task-id containing `/` once let `clear_sentinel`'s
  `rm -f` delete files *outside* `.operator/` (path traversal — a real bug,
  found and fixed 2026-07-10). Both are refused at the single writer with
  exit 2; `tests/test-scripts.sh` case 7 locks this. Do not "helpfully"
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
- **A sentinel the Stop hook cannot SEE is worse than no sentinel.** The hook
  enumerates `pending/` with a plain glob, which does not match dotfiles — so a
  `.hidden` task-id created an open task that never blocked (found in review of
  0.4.0, before release). Every name that becomes a filename is refused a
  leading dot in *all three* CLIs; the rule subsumes the older `.`/`..`
  traversal guard. `tests/test-scripts.sh` case 12 asserts the glob premise
  itself, not just the guard, so the reason cannot rot. If you ever switch the
  hook to `dotglob` or `find`, this rule is what you are trading away.
- **`--reconcile` is a write to the ledger of record, so it validates.** It
  originally copied fragment lines verbatim, which routed around the single
  writer's cell hygiene entirely — a merge-corrupted fragment could inject a
  non-conformant row. Any future path that appends to `VERDICTS.md` must
  enforce the 4-cell schema too, or it reopens the same hole.
- **A concurrency test that only asserts the output schema proves nothing.**
  A short `printf` usually lands atomically on a local FS *without* any lock, so
  "100 well-formed rows" passes on the unlocked code too. `tests/test-scripts.sh`
  case 11 therefore also takes the lock dir by hand and asserts a writer waits —
  that is the assertion that would fail if the lock were removed. Keep it.

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
