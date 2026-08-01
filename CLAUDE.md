# CLAUDE.md — maintainer handoff for cc-operator

This is the map a maintainer (human or agent) needs before editing. It records
the couplings that break silently; the landmine narratives (the *why* behind each
already-hit failure class) live in `docs/LANDMINES.md`, read on demand. For the
design rationale behind every decision, read `docs/spec/`. The build
ledger, plans, pilot runbook/findings, and prior-project evidence were removed
from the shipped tree in 0.3.0 — they live in the git history (tree ≤ v0.2.0)
and the maintainer's local `.archive/dev/` (untracked).

## The load-bearing map

- **`templates/OPERATOR.md` is the product.** Everything else exists to
  materialize, gate, or route to it. It is capped at 150 lines / 9000 bytes /
  100 chars per non-table line (the byte bounds keep the line cap honest — F19),
  with a fixed section order and citation tags (validator floor: ≥1 per section;
  the every-rule-line convention is maintained by hand). When you edit it,
  re-run the validator — the caps are a hard gate, not a target.
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
- **`scripts/statusline.sh` is a mirror of the gate, not a display of it**
  (0.4.0). It re-implements `ops-stop-hook.sh`'s mine/foreign partition —
  deliberately, because a count of `.operator/pending/` answers a different
  question than "will my stop be blocked?" and is wrong in both directions.
  That duplication is the coupling: change the partition rule or the sentinel
  body in the hook and this must move with it, or the bar confidently describes
  a gate that is not the one running. It reads `session_id` from the
  statusline stdin payload (documented schema) and is otherwise a fourth
  sentinel reader bound by the same PLAYBOOK rules — with the byte bound
  mattering most, since it renders on a ~300ms timer. cc-status discovers it
  only through `.claude-plugin/statusline.json` and skips an unresolvable
  renderer **silently**, which is why `check_statusline` exists.

## If you touch X, update Y

| If you change… | You must also… |
|---|---|
| the plugin name in `plugin.json` | update `marketplace.json` name, the `/cc-operator:` command refs in `OPERATOR.md` + `SKILL.md`, `README`, and `validate_plugin.PLUGIN_NAME` |
| `templates/VERDICTS-header.md`'s table header | update `validate_plugin.VERDICTS_HEADER` and know you are breaking every existing ledger's grep-compatibility |
| a charter section heading or its order | update `validate_plugin.CHARTER_SECTION_ORDER` |
| the sentinel/pending convention in any `ops-*.sh` | update the other scripts, `tests/test-scripts.sh`, and the EVIDENCE GATE prose in `OPERATOR.md` |
| the `.operator/bin` install set in `ops-init.sh` | update the charter's EVIDENCE GATE paths, the stop-hook fallback message, the *"project-installed gate CLIs"* test case, and `validate_plugin.CHARTER_REQUIRED_CLIS` + `check_scripts` |
| the sentinel body format (`session_id:` line) | update `ops-task.sh`, `ops-adopt.sh`, **three** parsers (`ops-verdict.sh:sentinel_owner`, `ops-stop-hook.sh:sentinel_owner`, `statusline.sh:sentinel_owner` — the latter two **must** stay builtin-only), and the *"sentinel ownership"*, *"migration safety"*, *"sentinel BODY is untrusted input"*, and *"statusline segment reports the gate"* cases |
| the `else`-branch of the O_EXCL open in `ops-task.sh` | keep two invariants: only a pre-existing **regular file** is a legit already-open (exit 0; anything non-regular/unwritable is a fault, exit non-zero), and the write stays wrapped in `{ …; } 2>/dev/null`. Why: `docs/LANDMINES.md` *"non-regular entry"* + *"raw bash error as operator guidance"* (the *"non-regular entry"* cases) |
| the mine/foreign partition rule in `ops-stop-hook.sh` | update `statusline.sh` — it renders that same partition, and a bar describing a different gate than the one that runs is worse than no bar |
| `scripts/statusline.sh`'s path or name | update `.claude-plugin/statusline.json` — cc-status skips an unresolvable renderer **silently** (enforced by `validate_plugin.check_statusline`) |
| the fragment/lock scheme in `ops-verdict.sh` | update `ops-init.sh` (`verdicts.d/`, `.gitattributes`), the README evidence-gate section, and the *"concurrent appends never interleave"* case |
| the `check_bare_name` reject set in any CLI | update the other two CLIs **and** the `case` filter in both `sentinel_owner` parsers — the hook must reject what the writers reject, or a body our CLIs could never have written reads as a valid foreign owner and the gate opens (*"name guards agree"* + *"untrusted input"* cases) |
| the canonical tier set in `ops-tiers.sh` (`TIER_NAMES=…`) | update every workflow's `KNOWN_TIERS` (code lines, never comments) **and `ops-render.sh`'s own `TIER_NAMES` literal** — `check_workflow_tier_namespace` + `check_resolver_renderer_parity` enforce equality, both reading `TIER_NAMES` by regex; a rename/retype must update those regexes, which now fail *loud* (the read is a reported problem, not a silent skip). Why: F07 in `docs/audit-2026-07-31-handoff.md` |
| the seat set, a `tiers.env` line kind, or the renderer's body sources | `ops-tiers.sh` and `ops-render.sh` parse the same `tiers.env` (BOTH line kinds: tier→model AND seat→tier — the resolver skips seat lines, the *"seat line … skipped by the resolver"* case) and share `check_routable` (`check_resolver_renderer_parity` compares it whitespace- and comment-insensitively, so reflowing is free but a logic change is not). Render bodies come from plugin-root `agents/op-<seat>.md` first (single-source; a template must keep a `model:` line, and BOTH splice sources must be CR-free or the awk skips every substitution — `check_render_templates`, F29). New seat default → `seat_add` in `ops-render.sh` + the `ops-init.sh` scaffold comment. Render/revert delete only `RENDER_MARK`-stamped files (F17); seat names are charset-allowlisted (F18) |
| a workflow's `ROUTABLE`/`BAD_CHARSET` | keep both pinned to their canonical literal in `check_workflows` **and** applied at a `.test(id)` call site. Parity across the four copies is not enough: they are copy-pasted, so uniform drift is the realistic failure and four identically-broken files are trivially "in parity" (F30) |

> Test cases are referenced **by title**, not by ordinal: `grep '^echo "-- Case' tests/test-scripts.sh`.
> Numbers shift the moment a case is inserted, and a coupling table that quietly points at the
> wrong case is worse than one that points nowhere.
| `plugin.json` `version` | add the matching `## [x.y.z]` as the newest heading in `CHANGELOG.md`, same commit (the release gate fails otherwise) |
| the Stop-hook command in `hooks.json` | keep `ops-stop-hook.sh` + `${CLAUDE_PLUGIN_ROOT}` (validator check 7) |
| an agent's model/tools/NEEDS_CONTEXT | keep it project-agnostic — no `unknowns-harness`/`F1..F13` — and keep `model:` a tier alias (`opus`/`sonnet`/`haiku`), never a pinned ID (validator check 6) |

## Procedure

Before your first change read **`docs/PLAYBOOK.md`** — what to do when adding a
guard, adding a reader, or touching the lock, each derived from a bug that
actually happened here. Audit trails: F01–F06 summary in `AUDIT_LOG.md` Phase 2;
F07+ in `docs/audit-2026-07-31-handoff.md`.

Two couplings below are now enforced by `validate_plugin.py` (`check_reader_bounds`,
`check_guard_parity`) rather than by remembering them: a missed byte bound or a
guard applied to only one of the three CLIs fails the build.

## Landmines (already hit — do not re-hit)

The narrative register moved to **`docs/LANDMINES.md`** — the *why* behind each
already-hit failure class, read on demand instead of loading into every session.
What stays here is the always-on summary: the load-bearing map above and the
coupling table, whose invariants are enforced by `validate_plugin.py`
(`check_reader_bounds`, `check_guard_parity`, `check_lock_parity`). Before
touching the Stop hook or a sentinel reader, read the landmine file first.

## Provenance

Everything under `docs/` is read-only rationale — why the code is shaped this
way. None of it is loaded by the plugin at runtime; the validator reads only
`templates/`, `scripts/`, `hooks/`, `agents/`, and the manifests.

- `docs/spec/chief-operator-spec.md` — the original design spec (D1–D6, the
  seams); most of the charter's `[DOC:spec-*]` citation tags resolve to it.
  **Local-only:** `docs/spec/` is gitignored wholesale (`docs/spec/.gitignore`
  is a bare `*`); the four files that ship were force-added. This one is not,
  because it quotes the prior project's evidence base — the same material 0.3.0
  deliberately removed from the tree. A fresh clone does not get it.
- `docs/spec/concurrent-sessions.md` — the 0.4.0 design: the field report, the
  ownership proposal, and `Implemented (0.4.0)` amendments recording where the
  shipped code diverged from the proposal. Its line numbers are 0.3.0-relative
  and say so. Also the honest register of what a green suite does **not** prove.
  **Local-only**, same as above.
- Consequence, and it is not small: of the charter's 24 `[DOC:spec-*]` tags,
  **22 point into those two untracked files** (`D2`×5, `D4`×4, `D6`×3,
  `D1.5`×3, `concurrent`×3, plus `D1.2`, `D1.6`, `D5`, `O8`). Only `spec-wf`
  and `spec-unk` resolve in a fresh clone. `check_charter` counts tags and
  requires ≥1 per section; it never resolves a tag to a file, so the build
  stays green either way. Treat a dangling `[DOC:spec-*]` in a clean checkout as expected, not as
  charter rot — and if you need the rationale, it is in the maintainer's local
  tree or the git history, not in the clone.
- `docs/PLAYBOOK.md` — the executable procedures (adding a guard, adding a
  reader, touching the lock), each derived from a bug that happened here.
- `docs/audits/audit-2026-07-27-{findings,handoff}.md` — the departing-architect
  audit (gate hardening, F01–F06). Local-only: `docs/audits/` is gitignored
  wholesale; a fresh clone gets the F01–F06 summary from `AUDIT_LOG.md` Phase 2.
- `docs/audit-2026-07-31-handoff.md` — the token-diet / workflow-layer audit:
  the workflow + tier-system mental model, the F07–F11 findings' decisions, the
  guardrails shipped this pass, the residual-risk register, and the prioritized
  backlog (incl. the input-axis compressor spec at `docs/spec/input-axis-compressor.md`).
- Everything else (build plan + ledger, pilot runbook and findings, the prior
  project's evidence bundle) was removed from the tree in 0.3.0: see git
  history (tree ≤ v0.2.0) or the maintainer's local `.archive/dev/`.
- The one still-open design question from the pilots: the evidence gate is
  opt-in at the mechanism level — nothing forces a sentinel to be opened.
  `ops-task.sh` (0.3.0) makes opening one-command and auditable, but does not
  close the hole. Documented limitation, not a bug.
