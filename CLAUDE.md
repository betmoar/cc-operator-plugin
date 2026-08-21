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
- **Sentinel ownership is what makes the gate concurrency-safe** (0.4.0 spec
  `docs/spec/concurrent-sessions.md`; 0.9.0 moved the stamp from body to
  filename). The sentinel filename carries the owner — `pending/<sid>__<task>`
  is owned, `pending/<task>` is unowned; `ops-stop-hook.sh` blocks on
  _mine + unowned_ and merely reports _foreign_.
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
- **The gate's partition rule lives in ONE file: `scripts/lib/partition.sh`**
  (0.10). `ops-stop-hook.sh` (the gate) and `statusline.sh` (the bar) source it
  — `sentinel_owner_of_name`, the mine/foreign pending scan, and the deviation
  scan. Change the rule in one place; a bar describing a different gate than
  the one that runs is worse than no bar. The bar's one deviation is its
  tail-window approximation of the deviation scan (CR5: the whole-file scan
  measured 0.4s at 3000 lines against a ~300ms render budget — fail toward
  silence, hook still gates exactly). The `.operator/bin/` gate CLIs do NOT
  source the lib (they install standalone); their hand-copies stay pinned by
  `check_guard_parity`. cc-status discovers the bar only through
  `.claude-plugin/statusline.json` and skips an unresolvable renderer
  **silently** (`check_statusline` exists for that).

## If you touch X, update Y

| If you change…                                                        | You must also…                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                |
| --------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| the plugin name in `plugin.json`                                      | update `marketplace.json` name, the `/cc-operator:` command refs in `OPERATOR.md` + `SKILL.md`, `README`, and `validate_plugin.PLUGIN_NAME`                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                   |
| `templates/VERDICTS-header.md`'s table header                         | update `validate_plugin.VERDICTS_HEADER` and know you are breaking every existing ledger's grep-compatibility                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                 |
| a charter section heading or its order                                | update `validate_plugin.CHARTER_SECTION_ORDER`                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                |
| the v1→v2 `.operator/.gitignore` migration in EITHER writer           | the write must stay reachable ONLY through a successful backup, in `ops-init.sh` AND `ops-sessionstart-hook.sh` — `check_gitignore_parity` pins both halves (the copy's exit status is tested; a non-regular `.v1.bak` is refused). The old shape was `cp … 2>/dev/null` then an unconditional write: a failed backup destroyed the user's rules while the notice promised they were recoverable. The hook additionally sets `_gi_migrated` only AFTER the replacement, and reports the refusal — silence is what let the destructive variant ship. Cases: the _"migration REFUSES"_ + _"ops-init refuses"_ cases |
| the `pending/<id>` type test in any CLI                               | it is a **non-symlink regular file** everywhere — `ops-task.sh`'s opener, both `ops-verdict.sh` sites, the Stop hook, the statusline. `retro_gate`'s `-e` was the one outlier and it cost the audit line: a directory read as "armed", suppressing the GATE-EXCEPTION, and the row was appended before `rm -f` failed. Refuse in `ownership_gate` (ops-verdict.sh's single choke point, called at both write sites), BEFORE any write. Cases: the _"non-regular entry"_ + _"refuses a non-regular entry BEFORE writing a row"_ cases |
| the compressor's ephemera (`ephemeralRoot` in `ops-compress.mjs`)    | spills and dedup state live ONLY under an existing `.operator/` (0.10: no tempdir fallback — no `.operator/` means no spill, no dedup, elide marked "not spilled"); files are 0600 with a per-root `*` self-gitignore, and `ops-sessionstart-hook.sh` wipes both roots every fire |
| the sentinel/pending convention in any `ops-*.sh`                     | update the other scripts, `tests/test-scripts.sh`, and the EVIDENCE GATE prose in `OPERATOR.md`                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                               |
| the `.operator/bin` install set (`scripts/ops-install-set.sh`)        | the set has ONE declaration since #76 step 3 — the manifest both writers source (`ops-init.sh` fails LOUD without it, the interactive path; `ops-sessionstart-hook.sh` fails OPEN: skips the upgrade, warns, does not re-stamp — an empty set must never record an upgrade that copied nothing). Adding a CLI: edit the manifest, then update the charter's EVIDENCE GATE paths, the stop-hook fallback message, the _"project-installed gate CLIs"_ test case, `validate_plugin.CHARTER_REQUIRED_CLIS` + `check_scripts`, and the `GATE_CLIS` literal in `ops-compress.mjs` (the I2.1 carve-out — a DIFFERENT 4-entry set: charter-referenced CLIs, no ops-backlog.sh; the manifest's header explains). `check_install_set_parity` pins the manifest readable + both writers sourcing and iterating `$_OPS_TOOLS` with no local literal (CR4)  |
| the `.operator/bin` refresh TRIGGER in `ops-sessionstart-hook.sh`     | keep BOTH clauses: a version-string change **or** `_bin_stale` (any shipped CLI newer than its installed copy). Version alone was #34 — every intra-version fix to a gate CLI stayed invisible because `plugin.json` had not moved, so a project kept running the broken predecessor of a fix while the plugin tree's own tests passed. The charter points the model at `.operator/bin/…`, so that copy IS the gate a session runs. Note the asymmetry: **hooks** resolve through `${CLAUDE_PLUGIN_ROOT}/scripts/…` and are current immediately, so hooks and `bin/` can sit at different commits at once. Keep the all-or-nothing re-stamp (CR3/H2) and the `#34` cases, including the negative control that a current `bin/` is not rewritten                                                                                                                                                                                                                                                                                                                                                                  |
| the protected set in `ops-claims.sh` (`PROTECTED=`)                   | update `validate_plugin.check_claims` (it pins the literal AND its `matches_protected` application — F30: copy parity alone is insufficient) and the `_"ops-claims verifies diff-matches-claims"_` cases; `ops-claims.sh` is NOT a sentinel reader (no `check_guard_parity`/`check_reader_bounds` site — it reads git state, not `pending/`)                                                                                                                                                                                                                                                                                                                                                                                                                                                |
| the sentinel filename ownership scheme (`<owner>__<task>`)            | update the three writers (`ops-task.sh` constructs the name, `ops-adopt.sh` and `ops-verdict.sh` rename to it) and the three readers' `sentinel_owner_of_name()` (`ops-verdict.sh` — which keeps a thin `sentinel_owner(task-id)` wrapper resolving the path first — `ops-stop-hook.sh`, `statusline.sh`; the latter two **must** stay builtin-only). The readers split on the FIRST `__`, which is why `__` is refused in both halves at every writer (`check_guard_parity` pins the arm). `ops-sessionstart-hook.sh`'s legacy migration is a SIXTH hand-copied reject-set site (bounded read, `-L` before `-f`). Cases: _"sentinel ownership"_, _"migration safety"_, _"sentinel BODY is untrusted input"_, _"statusline segment reports the gate"_, _"name guards agree"_                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                          |
| the `else`-branch of the O_EXCL open in `ops-task.sh`                 | keep two invariants: only a pre-existing **regular file** is a legit already-open (exit 0; anything non-regular/unwritable is a fault, exit non-zero), and the write stays wrapped in `{ …; } 2>/dev/null`. Why: `docs/LANDMINES.md` _"non-regular entry"_ + _"raw bash error as operator guidance"_ (the _"non-regular entry"_ cases)                                                                                                                                                                                                                                                                                                                                                                                                                                                        |
| the partition rule in `scripts/lib/partition.sh`                      | ONE implementation, sourced by both `ops-stop-hook.sh` (the gate: whole-file, fail-closed) and `statusline.sh` (the bar: tail-window approximation, fail-toward-silence — CR5's 300ms budget). Change it once. The `[sid:]` tag convention (what-cell of gated rows) is read by the lib + the bar's tail scanner and written by `ops-verdict.sh --mark-handoff`. Cap/polarity changes need the lib + the bar's inline scanner + the _"deviation-gate"_/_"dev\[N\] mirror"_ cases |
| a CLI's flag set quoted in `docs/REPLAY-CHARTER.md`            | the charter's quoted expectations are hand-maintained prose (0.10 deleted `check_replay_charter` — runbooks are validated by running them); a message change in `ops-stop-hook.sh`, `ops-armgate-hook.sh`, `ops-task.sh --exempt`, or `ops-init.sh` means updating the quoted strings by hand |
| `scripts/statusline.sh`'s path or name                                | update `.claude-plugin/statusline.json` — cc-status skips an unresolvable renderer **silently** (enforced by `validate_plugin.check_statusline`)                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                              |
| the source-state stamp in `ops-verdict.sh` (`source_stamp`, the row printf) | update `validate_plugin.check_source_stamp` (pins the marker set, the `.operator` dirty-exclusion, the 4-cell row format, the application of `SOURCE_STAMP` — read off the row's own `printf` argument list, because `"SOURCE_STAMP" in code` was satisfied by the assignment line alone and a literal in the row's place shipped unstamped rows green — and the resolve-before-`lock_acquire` ordering) and the _"source-state stamp"_ cases. Moving or renaming `ROW="$(printf …)"` breaks the locator, which reports rather than skipping. The stamp lives INSIDE the evidence cell on purpose: a fifth column breaks `VERDICTS_HEADER`, every ledger in the field, and every grep written against the 4-cell schema. It is provenance, not attestation — do not let a caller describe it as proof the tree passes (#22; #23 and #25 are the other two thirds) |
| the fragment/lock scheme in `ops-verdict.sh`                          | update `ops-init.sh` (`verdicts.d/`, `.gitattributes`), the README evidence-gate section, the _"concurrent appends never interleave"_ case, **and** the `--mark-handoff` path (it writes DECISIONS.md under the same lock)                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                    |
| `templates/DECISIONS-header.md`'s kind enum                          | update `validate_plugin.DECISIONS_KINDS` + `check_decisions_schema` (pins the enum AND requires the hook/statusline/verdict to reference HANDOFF-MARK) and the _"deviation-gate"_ + _"dev\[N\] mirror"_ cases                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                  |
| the `check_bare_name` reject set in any CLI                           | update the other two CLIs **and** the `case` filter in both `sentinel_owner_of_name` parsers **and** `ops-adopt.sh`'s inline `PREV` reject-set **and** `ops-sessionstart-hook.sh`'s migration reject-set (a sixth copy) — the readers must reject what the writers reject, or a name our CLIs could never have written reads as a valid foreign owner and the gate opens (_"name guards agree"_ + _"untrusted input"_ cases; `check_guard_parity` pins the `*.exempt` and `*__*` literals across the sites)                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                        |
| the canonical tier set in `ops-tiers.sh` (`TIER_NAMES=…`)             | update **`ops-render.sh`'s own `TIER_NAMES` literal** — `check_resolver_renderer_parity` enforces equality, reading both by regex; a rename/retype must update that regex, which fails _loud_ (the read is a reported problem, not a silent skip). Workflows no longer carry the set at all (#76 step 2 deleted `KNOWN_TIERS` — an unknown `args.tiers` key is accepted-and-logged, never thrown, preserving F07's resolver-map forwarding), and their `DEFAULT_TIERS` values must be harness aliases (`opus`/`sonnet`/`haiku`/`fable`), pinned by `check_workflow_default_tiers` — a vendor id pasted into a workflow default is the reflex fix that recreates the deleted catalogue. Why: F07 (writeup maintainer-local, never committed — see the audit-trail note in `docs/audit-2026-08-09-handoff.md`)                                                                                                                                                                                                                                                                                                                                                                         |
| the seat set, a `tiers.env` line kind, or the renderer's body sources | `ops-tiers.sh` and `ops-render.sh` parse the same `tiers.env` (BOTH line kinds: tier→model AND seat→tier — the resolver skips seat lines, the _"seat line … skipped by the resolver"_ case) and share `check_routable` (`check_resolver_renderer_parity` compares it whitespace- and comment-insensitively, so reflowing is free but a logic change is not). Render bodies come from plugin-root `agents/op-<seat>.md` first (single-source; a template must keep a `model:` line, and BOTH splice sources must be CR-free or the awk skips every substitution — `check_render_templates`, F29). New seat default → `seat_add` in `ops-render.sh` + the `ops-init.sh` scaffold comment + **`workflows/dispatch.js`'s `SEATS` table**, which is a LITERAL map on purpose: a computed `"cc-operator:op-" + seat` is invisible to `check_workflow_agent_types` (it matches the string by regex), so a typo'd or removed seat would ship green and fail at dispatch — F22's class. That checker matches the VALUE, not the `agentType:` key: the key form was blind to the one file that most needed it, since `dispatch.js` resolves its agentType from the table and passes the shorthand `agentType,` — a review measured every SEATS value retyped to a nonexistent agent shipping green. It reads a comment-STRIPPED view, because `dispatch.js`'s own prose quotes the concatenated form it argues against. Render/revert delete only `RENDER_MARK`-stamped files (F17); seat names are charset-allowlisted (F18) |
| the model-id guard (`check_routable`, workflows' `BAD_CHARSET`)       | it judges WELL-FORMEDNESS ONLY, and that is a decision, not an oversight (0.8.3). Until 0.8.2 it carried an id-shape catalogue (`glm-*`, `claude-*`, `vendor/model`) plus a provider-lens allowlist mirroring cc-proxy's `PROVIDER_IDS` — both lists of facts about ANOTHER system, pinned in `validate_plugin.py` and held in exact agreement across seven copies. The machinery worked; the list was wrong. Measured against a live cc-proxy serving 409 ids it refused 8 that route fine (`deepseek-v4-flash`, `qwen3.8-max` — bare vendor ids with neither a known prefix nor a slash), so a user binding one in `tiers.env` got a refusal citing a catalogue they never asked about. **The user picks the model, cc-proxy routes it, operator decides neither.** What remains tests the STRING (no whitespace, no quotes, non-empty), so it cannot go stale. `check_workflows` FIRES on a re-declared `const ROUTABLE` — the only presence-check in the validator, because the re-add is the reflex fix when an unguarded id reaches dispatch and every other gate stays green. Keep `BAD_CHARSET` pinned to `CANONICAL_BAD_CHARSET` **and** applied at a `.test(id)` call site in every `workflows/*.js`; it is now the only id guard, so a neutered call site has nothing behind it. Cases: the _"operator does not recognise"_ + _"only widens"_ + _"must not come back"_ cases |
| a workflow's `BAD_CHARSET`                                            | keep it pinned to its canonical literal in `check_workflows` **and** applied at a `.test(id)` call site. Parity across the copies is not enough: they are copy-pasted, so uniform drift is the realistic failure and identically-broken files are trivially "in parity" (F30)                                                                                                                                                                                                                                                                                                                                                                                                                                        |
| the `.armed/<sid>` marker convention (G2.1)                           | update **all three** writers (`ops-task.sh`, `ops-adopt.sh`, `ops-verdict.sh`) and the arm hook's one-stat read (`ops-armgate-hook.sh`). The marker is a derived cache of "this session owns ≥1 pending sentinel"; stale-TRUE must stay fail-OPEN (degrades to today's ungated behaviour), stale-FALSE is the one desync to prevent (blocks a legitimately-armed session from every edit). `ops-verdict.sh`'s recompute is remove → rescan → restore, in that order (the intuitive clear → rescan → rm loses a task opened mid-recompute). Never touch `.armed/<sid>.exempt` in the recompute — G3 grants have a separate lifetime. Cases: the _"arm gate"_ cases (G2.1–G2.10) |
| an issue reference in tracked markdown, or `plugin.json` `repository` | keep label/URL agreeing by hand (0.10 deleted `check_issue_refs` — markdown link lint, not a shipping concern). Bare `#N` stays out of scope. `release_gate.CODE_SPAN_RE` still strips code spans and must stay standalone-runnable |
| the dispatch packet in `templates/OPERATOR.md`                        | update `docs/HANDOUT.md`'s copy **and** `validate_plugin.HANDOUT_PACKET_SPINE`. The spine held only the FIRST and LAST fragments, so `REACH` (#57) went in the middle and the pin stayed green teaching a packet without it — F69's drift repeating inside the guard written against it. The checker now asserts the CHARTER carries every field too, not just that the handout matches it: parity passes perfectly when the original is what lost the field (F30). Every field added to the packet needs a tuple entry, and `test_handout_packet_pin_fires_per_field` fails if one is added without being enforced |
| `args.isolate` / the adversarial seat's prompt in `workflows/review.js` (#23) | keep the two branches EXCLUSIVE: un-isolated ships F-A1 (`git status --porcelain`), isolated ships F-A2 (`git rev-parse HEAD` vs the named sha) and F-A1 must NOT also ship. A fresh worktree is clean by construction, so porcelain there is a control that cannot fail — #21's class reached by ADDING a control. `isolate: true` stays refused (isolation with no named commit verifies whatever HEAD is), and both the prompt and the returned `isolation.bound` must keep naming the bound: same filesystem/`$HOME`/caches/PATH, so it defeats in-tree artifacts, not a poisoned global cache. The returned field is `requestedCommit`, NEVER `commit`: nothing in this file observes where the seat ran, so on a REFUTED — the very verdict an identity mismatch produces — a `commit:` key would stamp the result with a sha the run may never have been at. The observed HEAD lives in `adversarial.evidence`; `observedCommit` stays null until something actually reads it back. Cases: the _"adversarial isolation"_ cases; the stub runtime captures `opts.isolation` so a workflow that DESCRIBES an isolated run but dispatches a builder-tree one goes red |
| `ops-corpus.sh`'s neutralization and corpus map              | PENDING the step-6 decision (keep / lab / delete). The corpora it served were removed from the tree in 0.10 — the script's map lives IN the corpus, the neutralization stays ALLOWLIST-shaped, and exit codes stay distinct (2 stale, 3 unstamped) |
| the plan graph in `workflows/plan.js` (`contractSet`, `edges`, `layers`, #66) | REPORT-ONLY and must stay so; `produces`/`consumes` stay ARRAYS of exact names (reverting is SILENT — the prose fallback still works); `graph.contractsInferred` records every prose fallback and the log says ESTIMATED. Declared edges are CONSECUTIVE pairs, `dependsOn` scans all earlier tasks — the gap is the spurious-serialisation signal. Report `graphWidth` only WITH `dispatchBound`. Enforcement: the node suite (0.10 deleted `check_northstar`; the cases live in `tests/test_workflows.mjs`) |
| `northStar` in `workflows/plan.js` (#58)                              | read WITHOUT a fallback, keep the `Missed if:` requirement, keep `${northStar}` interpolated exactly once — into decompose, never a vet packet (6/6 feasibility seats raised goal findings against the control column when it went to the packets). Load-bearing guard: the node suite's captured-prompt assertion, which covers concatenation forms a count cannot see |
| the write ORDER in `ops-verdict.sh`'s verdict path (#14)              | the GATE-EXCEPTION goes BEFORE the row, the fragment before the ledger, the sentinel clear last. Order is the whole fix for U2: row-first leaves a row with no exception, which the retry reads as an amendment and the bypass keeps its PASS while losing its audit line. Do NOT re-add the reverted guard (downgrade only when an exception exists) — an ARMED first verdict also leaves a row with no exception, and G1.7 catches the spurious firing. Case: _"G1.10"_, which asserts relative position in the source, mutation-checked |
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
actually happened here. Audit trails: the F01–F66 writeups live in the
maintainer's local `.archive/dev/` and were never committed — no clone at any
commit resolves them; the first audit file that ships in-tree is
`docs/audit-2026-08-09-handoff.md` (F67+), whose provenance section restates
this rule.

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

- `docs/spec/TAGS.md` — **the in-tree resolution index for every charter
  `[DOC:spec-*]` tag** (#76 step E). The original spec files
  (`chief-operator-spec.md`, D1–D6; `concurrent-sessions.md`, the 0.4.0
  ownership design) were never committed — they quoted the prior project's
  evidence base 0.3.0 removed — and by 2026-08-21 no copy survived in the
  maintainer's local tree either, so 22 of the charter's 24 DOC tags dangled
  in EVERY checkout, documented as "expected". TAGS.md replaced that: each
  entry records what the tag anchors *as shipped* (from the code and the
  charter's usage, not recovered spec prose — where the original rationale is
  lost, the entry says so), and `check_charter` fails the build on a charter
  DOC tag with no `### spec-<key>` entry, so the index cannot fall behind.
  Orphan entries (a retired tag's survivor) are deliberately allowed: history,
  not rot. `docs/spec/backlog-charter.md` (the 0.7.0 arm-gate spec) still
  ships alongside it.
- `docs/PLAYBOOK.md` — the executable procedures (adding a guard, adding a
  reader, touching the lock), each derived from a bug that happened here.
- `docs/REPLAY-CHARTER.md` — the live-session replay protocol (R0–R8): re-proves
  the harness seam the bash suite cannot reach (live Stop block, arm-gate deny,
  SessionStart id injection, the U10 stamp end-to-end), every phase recorded as
  a verdict row through the gate it audits. Run it after plugin or harness
  upgrades and before any release claiming a live-verified gate. Expected-output
  strings in it quote the real scripts — a message change in `ops-stop-hook.sh`,
  `ops-armgate-hook.sh`, `ops-task.sh --exempt`, or `ops-init.sh`'s F67 warning
  must update the charter's quoted expectations too (no validator pin; prose).
  **First executed 2026-08-12** (`1e5308a`→`13ea694`): it produced issue #34 and
  four defects in its own text, all corrected, with a "What the first real run
  changed" section recording them. Its R0 now opens with a build-identity check
  — `cmp` every `.operator/bin/` CLI against the plugin's — because a stale
  `bin/` silently makes the later phases audit a different build than the tree,
  which is exactly what happened on the first run.
- `docs/INFOGRAPHICS.md` + `docs/img/` — visual explainers. **Non-normative and
  partly forward-looking**: two of the three sheets depict a "2.0" target state
  whose isolation, security-lens, attestation and hash-chain claims are open
  unknowns (#22–#25, #14), so the page carries a per-claim status table. When
  one of those lands, move its row rather than deleting it. Nothing here is read
  at runtime and the validator does not parse it.
- `docs/audits/audit-2026-07-27-{findings,handoff}.md` — the departing-architect
  audit (gate hardening, F01–F06). **Maintainer-local, never committed** — a
  fresh clone has no copy and no summary; what survives in-tree is the guardrail
  code itself plus the F-numbers cited in comments and CHANGELOG.
- `docs/audit-2026-07-31-handoff.md` — the token-diet / workflow-layer audit
  (F07–F66 era: mental model, decisions, residual risks). **Also
  maintainer-local, never committed**, despite prior revisions of this file
  citing it as if it shipped — `git log --all` on the path is empty. The
  in-tree survivors are the same: code, comments, CHANGELOG.
- `docs/audit-2026-08-09-handoff.md` — the assurance-model audit (F67+ and the
  U10–U13 unknowns). The first audit handoff that actually ships in-tree.
- Everything else (build plan + ledger, pilot runbook and findings, the prior
  project's evidence bundle) was removed from the tree in 0.3.0: see git
  history (tree ≤ v0.2.0) or the maintainer's local `.archive/dev/`.
- The one still-open design question from the pilots: the evidence gate is
  opt-in at the mechanism level — nothing forces a sentinel to be opened.
  `ops-task.sh` (0.3.0) makes opening one-command and auditable, but does not
  close the hole. Documented limitation, not a bug.

## Operator

@templates/OPERATOR.md — it is this session's operating charter.
