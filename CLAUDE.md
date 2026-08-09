# CLAUDE.md — maintainer handoff for cc-operator

This is the map a maintainer (human or agent) needs before editing. It records
the couplings that break silently; the landmine narratives (the _why_ behind each
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
  _single writer_ to `VERDICTS.md`, `ops-adopt.sh` re-stamps sentinel ownership,
  `ops-stop-hook.sh` blocks Stop while a sentinel _this session owns_ is
  pending, and `ops-sessionstart-hook.sh` injects the session id the whole
  ownership mechanism keys on. The sentinel filename `<id>` is the shared key;
  change the convention in one place and you break the gate.
- **Sentinel ownership is what makes the gate concurrency-safe** (0.4.0, spec
  `docs/spec/concurrent-sessions.md`). A sentinel stamps `session_id:`;
  `ops-stop-hook.sh` blocks on _mine + unowned_ and merely reports _foreign_.
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
  `${CLAUDE_PLUGIN_ROOT}/scripts/ops-stop-hook.sh` — the hook runs _from the
  plugin root_. Different bases on purpose; do not "unify" them. Validator
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

| If you change…                                                        | You must also…                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                |
| --------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| the plugin name in `plugin.json`                                      | update `marketplace.json` name, the `/cc-operator:` command refs in `OPERATOR.md` + `SKILL.md`, `README`, and `validate_plugin.PLUGIN_NAME`                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                   |
| `templates/VERDICTS-header.md`'s table header                         | update `validate_plugin.VERDICTS_HEADER` and know you are breaking every existing ledger's grep-compatibility                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                 |
| a charter section heading or its order                                | update `validate_plugin.CHARTER_SECTION_ORDER`                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                |
| the sentinel/pending convention in any `ops-*.sh`                     | update the other scripts, `tests/test-scripts.sh`, and the EVIDENCE GATE prose in `OPERATOR.md`                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                               |
| the `.operator/bin` install set in `ops-init.sh` OR `ops-sessionstart-hook.sh` | the set is now declared in BOTH (ops-init on /cc-operator:start, sessionstart on the upgrade path); update the charter's EVIDENCE GATE paths, the stop-hook fallback message, the _"project-installed gate CLIs"_ test case, `validate_plugin.CHARTER_REQUIRED_CLIS` + `check_scripts` + `check_install_set_parity` (pins the two lists equal — CR4) + the `GATE_CLIS` literal in `ops-compress.mjs` (the I2.1 carve-out)                                                                                                                                                                                                                                                                                                                                                                  |
| the protected set in `ops-claims.sh` (`PROTECTED=`)                   | update `validate_plugin.check_claims` (it pins the literal AND its `matches_protected` application — F30: copy parity alone is insufficient) and the `_"ops-claims verifies diff-matches-claims"_` cases; `ops-claims.sh` is NOT a sentinel reader (no `check_guard_parity`/`check_reader_bounds` site — it reads git state, not `pending/`)                                                                                                                                                                                                                                                                                                                                                                                                                                                |
| the sentinel body format (`session_id:` line)                         | update `ops-task.sh`, `ops-adopt.sh`, **three** parsers (`ops-verdict.sh:sentinel_owner`, `ops-stop-hook.sh:sentinel_owner`, `statusline.sh:sentinel_owner` — the latter two **must** stay builtin-only), and the _"sentinel ownership"_, _"migration safety"_, _"sentinel BODY is untrusted input"_, and _"statusline segment reports the gate"_ cases                                                                                                                                                                                                                                                                                                                                                                                                                                       |
| the `else`-branch of the O_EXCL open in `ops-task.sh`                 | keep two invariants: only a pre-existing **regular file** is a legit already-open (exit 0; anything non-regular/unwritable is a fault, exit non-zero), and the write stays wrapped in `{ …; } 2>/dev/null`. Why: `docs/LANDMINES.md` _"non-regular entry"_ + _"raw bash error as operator guidance"_ (the _"non-regular entry"_ cases)                                                                                                                                                                                                                                                                                                                                                                                                                                                        |
| the mine/foreign partition rule in `ops-stop-hook.sh`                 | update `statusline.sh` — it renders that same partition, and a bar describing a different gate than the one that runs is worse than no bar                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                    |
| the deviation partition (`scan_deviations` in hook + statusline)      | both re-implement the same mine/unowned-vs-foreign scan over DECISIONS.md DEVIATION/HANDOFF-MARK lines — change one and the other must move with it, or the bar describes a gate that is not the one running. They use DIFFERENT scan STRATEGIES by design: the hook is whole-file fail-CLOSED (accuracy, the gate), the statusline is a reverse-tail scan fail-toward-SILENCE (latency, the 300ms render budget — CR5). The `[sid:]` tag convention (what-cell of DEVIATION rows) is read by both + written by `ops-verdict.sh --mark-handoff`; document it in `docs/PLAYBOOK.md` worker-boundary §6. Cap/polarity changes need both sites + the _"deviation-gate"_/_"dev\[N\] mirror"_ cases                                                                                                                                                                                                                                                                                                |
| `scripts/statusline.sh`'s path or name                                | update `.claude-plugin/statusline.json` — cc-status skips an unresolvable renderer **silently** (enforced by `validate_plugin.check_statusline`)                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                              |
| the source-state stamp in `ops-verdict.sh` (`source_stamp`, the row printf) | update `validate_plugin.check_source_stamp` (pins the marker set, the `.operator` dirty-exclusion, the 4-cell row format, the application of `SOURCE_STAMP`, and the resolve-before-`lock_acquire` ordering) and the _"source-state stamp"_ cases. The stamp lives INSIDE the evidence cell on purpose: a fifth column breaks `VERDICTS_HEADER`, every ledger in the field, and every grep written against the 4-cell schema. It is provenance, not attestation — do not let a caller describe it as proof the tree passes (#22; #23 and #25 are the other two thirds) |
| the fragment/lock scheme in `ops-verdict.sh`                          | update `ops-init.sh` (`verdicts.d/`, `.gitattributes`), the README evidence-gate section, the _"concurrent appends never interleave"_ case, **and** the `--mark-handoff` path (it writes DECISIONS.md under the same lock)                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                    |
| `templates/DECISIONS-header.md`'s kind enum                          | update `validate_plugin.DECISIONS_KINDS` + `check_decisions_schema` (pins the enum AND requires the hook/statusline/verdict to reference HANDOFF-MARK) and the _"deviation-gate"_ + _"dev\[N\] mirror"_ cases                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                  |
| the `check_bare_name` reject set in any CLI                           | update the other two CLIs **and** the `case` filter in both `sentinel_owner` parsers — the hook must reject what the writers reject, or a body our CLIs could never have written reads as a valid foreign owner and the gate opens (_"name guards agree"_ + _"untrusted input"_ cases)                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                        |
| the canonical tier set in `ops-tiers.sh` (`TIER_NAMES=…`)             | update every workflow's `KNOWN_TIERS` (code lines, never comments) **and `ops-render.sh`'s own `TIER_NAMES` literal** — `check_workflow_tier_namespace` + `check_resolver_renderer_parity` enforce equality, both reading `TIER_NAMES` by regex; a rename/retype must update those regexes, which now fail _loud_ (the read is a reported problem, not a silent skip). Why: F07 in `docs/audit-2026-07-31-handoff.md`                                                                                                                                                                                                                                                                                                                                                                         |
| the seat set, a `tiers.env` line kind, or the renderer's body sources | `ops-tiers.sh` and `ops-render.sh` parse the same `tiers.env` (BOTH line kinds: tier→model AND seat→tier — the resolver skips seat lines, the _"seat line … skipped by the resolver"_ case) and share `check_routable` (`check_resolver_renderer_parity` compares it whitespace- and comment-insensitively, so reflowing is free but a logic change is not). Render bodies come from plugin-root `agents/op-<seat>.md` first (single-source; a template must keep a `model:` line, and BOTH splice sources must be CR-free or the awk skips every substitution — `check_render_templates`, F29). New seat default → `seat_add` in `ops-render.sh` + the `ops-init.sh` scaffold comment. Render/revert delete only `RENDER_MARK`-stamped files (F17); seat names are charset-allowlisted (F18) |
| a workflow's `ROUTABLE`/`BAD_CHARSET`                                 | keep both pinned to their canonical literal in `check_workflows` **and** applied at a `.test(id)` call site. Parity across the four copies is not enough: they are copy-pasted, so uniform drift is the realistic failure and four identically-broken files are trivially "in parity" (F30)                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                   |
| the `.armed/<sid>` marker convention (G2.1)                           | update **all three** writers (`ops-task.sh`, `ops-adopt.sh`, `ops-verdict.sh`) and the arm hook's one-stat read (`ops-armgate-hook.sh`). The marker is a derived cache of "this session owns ≥1 pending sentinel"; stale-TRUE must stay fail-OPEN (degrades to today's ungated behaviour), stale-FALSE is the one desync to prevent (blocks a legitimately-armed session from every edit). `ops-verdict.sh`'s recompute is remove → rescan → restore, in that order (the intuitive clear → rescan → rm loses a task opened mid-recompute). Never touch `.armed/<sid>.exempt` in the recompute — G3 grants have a separate lifetime. Cases: the _"arm gate"_ cases (G2.1–G2.10) |
| the arm gate's tool matcher in `hooks.json` (G2)                      | keep `Bash` OUT of it (classifying shell writes is unwinnable, and gating Bash deadlocks the repair path — `ops-task.sh` is itself a Bash call), and update the deny message + the _"arm gate"_ cases. The gate is opt-in (`armgate.on`); polarity is the OPPOSITE of the Stop hook's — fail OPEN on every infra failure (a PreToolUse that fails closed makes the project unwritable) |

> Test cases are referenced **by title**, not by ordinal: `grep '^echo "-- Case' tests/test-scripts.sh`.
> Numbers shift the moment a case is inserted, and a coupling table that quietly points at the
> wrong case is worse than one that points nowhere.
> | `plugin.json` `version` | add the matching `## [x.y.z]` as the newest heading in `CHANGELOG.md`, same commit (the release gate fails otherwise) |
> | the Stop-hook command in `hooks.json` | keep `ops-stop-hook.sh` + `${CLAUDE_PLUGIN_ROOT}` (validator check 7) |
> | an agent's model/tools/NEEDS_CONTEXT | keep it project-agnostic — no `unknowns-harness`/`F1..F13` — and keep `model:` a tier alias (`opus`/`sonnet`/`haiku`), never a pinned ID (validator check 6) |

## Procedure

Before your first change read **`docs/PLAYBOOK.md`** — what to do when adding a
guard, adding a reader, or touching the lock, each derived from a bug that
actually happened here. Audit trails: F01–F06 summary in `AUDIT_LOG.md` Phase 2;
F07+ in `docs/audit-2026-07-31-handoff.md`.

Two couplings below are now enforced by `validate_plugin.py` (`check_reader_bounds`,
`check_guard_parity`) rather than by remembering them: a missed byte bound or a
guard applied to only one of the three CLIs fails the build.

## Landmines (already hit — do not re-hit)

The narrative register moved to **`docs/LANDMINES.md`** — the _why_ behind each
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
- `docs/INFOGRAPHICS.md` + `docs/img/` — visual explainers. **Non-normative and
  partly forward-looking**: two of the three sheets depict a "2.0" target state
  whose isolation, security-lens, attestation and hash-chain claims are open
  unknowns (#22–#25, #14), so the page carries a per-claim status table. When
  one of those lands, move its row rather than deleting it. Nothing here is read
  at runtime and the validator does not parse it.
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

## Operator

@templates/OPERATOR.md — it is this session's operating charter.
