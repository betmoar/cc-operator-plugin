# CLAUDE.md — maintainer handoff for cc-operator

This is the map a maintainer (human or agent) needs before editing. It records
the couplings that break silently; the landmine narratives (the _why_ behind each
already-hit failure class) live in `docs/LANDMINES.md`, read on demand. For the
design rationale behind every decision, read `docs/TAGS.md` (the in-tree
spec index; the spec dir itself emptied in 0.11.9 — rationale now lives in
`docs/` and git history). The build
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
  `.operator/` and installs the manifest's CLIs (`scripts/ops-install-set.sh` —
  the ONE declaration, five entries today) into `.operator/bin/` (refreshed on
  every run — the upgrade path),
  `ops-task.sh` opens a task by dropping the sentinel, `ops-verdict.sh` is the
  _single writer_ to `VERDICTS.md`, `ops-adopt.sh` re-stamps sentinel ownership,
  `ops-stop-hook.sh` blocks Stop while a sentinel _this session owns_ is
  pending, and `ops-sessionstart-hook.sh` injects the session id the whole
  ownership mechanism keys on. The sentinel filename `<id>` is the shared key;
  change the convention in one place and you break the gate.
- **Sentinel ownership is what makes the gate concurrency-safe** (0.4.0 spec
  `concurrent-sessions.md`, never committed — its shipped invariants are
  indexed in `docs/TAGS.md`; 0.9.0 moved the stamp from body to
  filename). The sentinel filename carries the owner — `pending/<sid>__<task>`
  is owned, `pending/<task>` is unowned; `ops-stop-hook.sh` blocks on
  _mine + unowned_ and merely reports _foreign_.
  Unowned fails **closed** — that is what keeps pre-0.4 empty sentinels gating,
  and it is deliberately the opposite default from the no-parser fail-open in
  the same file. Both are right: an unparseable payload is a plugin failure, an
  unowned sentinel is a real open task. `CLAUDE_SESSION_ID` is **not** in the
  Bash tool env — only hooks get `session_id` — so the SessionStart hook is
  load-bearing, not a convenience. Sibling SessionStart hooks (cc-reload's
  rehydrate) write `additionalContext` in the same event; the harness
  concatenates both and the id banner survives (live-confirmed 2026-09-04,
  #117 item 2) — both hooks stay append-only.
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
| the plugin name in `plugin.json` | update `marketplace.json` name, the `/cc-operator:` command refs in `OPERATOR.md` + `SKILL.md`, `README`, and `validate_plugin.PLUGIN_NAME`. **`SKILL.md` is hand-maintained** — nothing reads `skills/`, so a rename there ships green (measured 0.10; #80) |
| `templates/VERDICTS-header.md`'s table header | update `validate_plugin.VERDICTS_HEADER` and know you are breaking every existing ledger's grep-compatibility |
| a charter section heading or its order | update `validate_plugin.CHARTER_SECTION_ORDER` |
| the v1→v2 `.operator/.gitignore` migration in EITHER writer | the write must stay reachable ONLY through a successful backup, in `ops-init.sh` AND `ops-sessionstart-hook.sh` — `check_gitignore_parity` pins both halves (the copy's exit status is tested; a non-regular `.v1.bak` is refused). Cases: the _"migration REFUSES"_ + _"ops-init refuses"_ + _"the third state"_ cases. Full detail: docs/LANDMINES.md (0.11.9). |
| the `pending/<id>` type test in any CLI | it is a **non-symlink regular file** everywhere — `ops-task.sh`'s opener, both `ops-verdict.sh` sites, the Stop hook, the statusline. `retro_gate`'s `-e` was the one outlier and it cost the audit line: a directory read as "armed", suppressing the GATE-EXCEPTION, and the row was appended before `rm -f` failed. Refuse in `ownership_gate` (ops-verdict.sh's single choke point, called at both write sites), BEFORE any write. Cases: the _"non-regular entry"_ + _"refuses a non-regular entry BEFORE writing a row"_ cases |
| the compressor's ephemera (`ephemeralRoot` in `ops-compress.mjs`) | spills and dedup state live ONLY under an existing `.operator/` (0.10: no tempdir fallback — no `.operator/` means no spill, no dedup; a SYMLINKED `.operator/` reads as absent, audit F122); files are 0600 with a per-root `*` self-gitignore, and `ops-sessionstart-hook.sh` wipes both roots every fire. The elide marker is NEUTRAL — spill/no-spill status lives ONLY in the caller's appended line (audit F121) |
| the scrub tier in `ops-compress.mjs` (`scrub()`'s regex literals) | keep the `\x1b` anchors IN BOTH regexes, written as the escape `\x1b`, never as raw ESC bytes — the 0.10.0 debloat stripped the raw bytes and the "lossless" tier silently truncated every `]`-bearing output (a 3KB test log → one char), shipped green by a suite with no `]` in any input (audit F120, P0). `check_compressor` pins both anchors; cases: the _"F120 scrub is lossless"_ block in `tests/test_compress.mjs` |
| the project-resolution walk in EITHER hook | `ops-stop-hook.sh` AND `ops-sessionstart-hook.sh` resolve the project by the SAME bounded walk-up (`.git` stops it, `/` stops it, `cd -P`) — SessionStart exact-matched `$cwd/.operator` until audit F101: a subdir session silently lost the id banner, the legacy migration, the bin/ upgrade and the ephemera wipes while the Stop hook from the same cwd blocked. Session guidance (the banner) prescribes ABSOLUTE single-quoted CLI paths (audit F102 — the #94 shape); `templates/OPERATOR.md` stays relative on purpose (committed, machine-portable). Cases: the _"SessionStart resolves the project by WALKING UP"_ + _"banner prescribes ABSOLUTE"_ blocks |
| how a gate CLI finds `.operator/` (the PROJECT ROOT BLOCK) | ONE block, byte-identical in `ops-task.sh`, `ops-verdict.sh` and `ops-adopt.sh`, pinned by `check_root_parity` (parity across the three AND a canonical-content pin — copy-pasted blocks drift uniformly, F30). Cases: the _"WALKING UP"_ block + `RootParityTest`. Full detail: docs/LANDMINES.md (0.11.9). |
| the sentinel/pending convention in any `ops-*.sh` | update the other scripts, `tests/test-scripts.sh`, and the EVIDENCE GATE prose in `OPERATOR.md` |
| the `.operator/bin` install set (`scripts/ops-install-set.sh`) | the set has ONE declaration since #76 step 3 — the manifest both writers source (`ops-init.sh` fails LOUD without it, the interactive path; `ops-sessionstart-hook.sh` fails OPEN: skips the upgrade, warns, does not re-stamp — an empty set must never record an upgrade that copied nothing). Cases: _"project-installed gate CLIs"_. Full detail: docs/LANDMINES.md (0.11.9). |
| the Stop hook's loop guard / `.operator/.stopguard/` markers (#116) | keep the marker semantics: every `exit 2` in `ops-stop-hook.sh` stamps `.stopguard/<sid>` (BOTH block sites — pending and deviation), the allowing `exit 0` clears it, and `ops-sessionstart-hook.sh` wipes the dir every fire beside `.autobar/`. `stop_hook_active` alone must NEVER exit 0 again — it is a harness field any sibling's block sets (cc-repete's loop disarmed the gate whole-window, measured); only `active AND my marker` stands down. Cases: the _"gate runs normally"_ block (4d-4h). Full detail: docs/LANDMINES.md (0.11.9). |
| the `.operator/bin` refresh TRIGGER in `ops-sessionstart-hook.sh` | keep BOTH clauses: a version-string change **or** `_bin_stale` (any shipped CLI newer than its installed copy) — version alone was #34. Keep the all-or-nothing re-stamp (CR3/H2), and keep both halves agreeing about an ABSENT source (#82): whatever the copy loop skips, `_bin_stale` must call stale, the skip is announced, and `.version` is NOT stamped. Fail-OPEN. Cases: the _"#34"_ block (with its negative control) and the _"#82"_ block (with both CONTROLs). Why: `docs/LANDMINES.md` _"A stale `.operator/bin/` is the gate a session actually runs"_ |
| the protected set in `ops-claims.sh` (`PROTECTED=`) | update `validate_plugin.check_claims` (it pins the literal AND its `matches_protected` application — F30: copy parity alone is insufficient — AND since audit F140 it EXECUTES the shipped matcher in a child bash against one probe per protected token plus two unprotected paths: the body pins were substring tests, and `return 1` as the first body line shipped green) and the `_"ops-claims verifies diff-matches-claims"_` cases; `ops-claims.sh` is NOT a sentinel reader (no `check_guard_parity`/`check_reader_bounds` site — it reads git state, not `pending/`) |
| the `*__<id>` sentinel LOOKUP in any CLI (`sentinel_for` in `ops-task.sh`, `sentinel_path` in `ops-verdict.sh` + `ops-adopt.sh`, and `ops-task.sh`'s post-rename dup loop) | keep the TASK-HALF filter (`_n="${_f##*/}"; [ "${_n#*__}" = "$_t" ] \|\| continue`) at all FOUR sites — `check_guard_parity` pins each literal (audit F136). Cases: the _"F136"_ block. Full detail: docs/LANDMINES.md (0.11.9). |
| the sentinel filename ownership scheme (`<owner>__<task>`) | update the three writers (`ops-task.sh` constructs the name, `ops-adopt.sh` and `ops-verdict.sh` rename to it) and the three readers' `sentinel_owner_of_name()` (`ops-verdict.sh` — which keeps a thin `sentinel_owner(task-id)` wrapper resolving the path first — `ops-stop-hook.sh`, `statusline.sh`; the latter two **must** stay builtin-only). Readers split on the FIRST `__`, so `__` is refused in both halves at every writer (`check_guard_parity` pins the arm). `ops-sessionstart-hook.sh`'s legacy migration is a SIXTH hand-copied reject-set site (bounded read, `-L` before `-f`). Cases: _"sentinel ownership"_, _"migration safety"_, _"sentinel BODY is untrusted input"_, _"statusline segment reports the gate"_, _"name guards agree"_ |
| the `else`-branch of the O_EXCL open in `ops-task.sh` | keep two invariants: only a pre-existing **regular file** is a legit already-open (exit 0; anything non-regular/unwritable is a fault, exit non-zero), and the write stays wrapped in `{ …; } 2>/dev/null`. Why: `docs/LANDMINES.md` _"non-regular entry"_ + _"raw bash error as operator guidance"_ (the _"non-regular entry"_ cases) |
| the partition rule in `scripts/lib/partition.sh` | ONE implementation, sourced by both `ops-stop-hook.sh` (the gate: whole-file, fail-closed) and `statusline.sh` (the bar: tail-window approximation, fail-toward-silence — CR5's 300ms budget). Cases: the _"a FOREIGN mark clears UNOWNED"_ block, each mutation-checked. Cases: _"deviation-gate"_ + _"dev\[N\] mirror"_ + _"foreign mark does not clear my deviation"_. Full detail: docs/LANDMINES.md (0.11.9). |
| the MALFORMED bucket in `scripts/lib/partition.sh` (`scan_pending`) | update `scripts/ops-stop-hook.sh`'s malformed message AND `statusline.sh`'s `BLOCKING` count — the bucket blocks, so a bar that omits it reads "not blocked" while Stop returns 2, which is the exact disagreement sharing this lib prevents. Cases: the _"F118 (#99)"_ block, each pin mutation-checked (7 red on the pre-#99 code, the two bar pins red on a statusline-only mutation, 4 red on the `"; "` carrier, 2 red with the bucket removed for the FOREIGN-owned shape). Cases: _"F135"_. Full detail: docs/LANDMINES.md (0.11.9). |
| a CLI's flag set quoted in `docs/REPLAY-CHARTER.md` | the charter's quoted expectations are hand-maintained prose (0.10 deleted `check_replay_charter` — runbooks are validated by running them); a message change in `ops-stop-hook.sh` or `ops-init.sh` means updating the quoted strings by hand |
| `scripts/statusline.sh`'s path or name | update `.claude-plugin/statusline.json` — cc-status skips an unresolvable renderer **silently** (enforced by `validate_plugin.check_statusline`) |
| the source-state stamp in `ops-verdict.sh` (`source_stamp`, the row printf) | update `validate_plugin.check_source_stamp` (pins the marker set, the `.operator` dirty-exclusion, the 4-cell row format, the application of `SOURCE_STAMP` — read off the row's own `printf` argument list, because `"SOURCE_STAMP" in code` was satisfied by the assignment line alone and a literal in the row's place shipped unstamped rows green — and the resolve-before-`lock_acquire` ordering) and the _"source-state stamp"_ cases. Full detail: docs/LANDMINES.md (0.11.9). |
| the 4-cell row `printf` or a stamp form (`@<sha>`, `+dirty`, `no-vcs`, `no-commit`) in `ops-verdict.sh` | update `scripts/ops-reverify.sh`'s row parser and stamp classifier (issue #103: it dates every row by its stamp's HEAD window to find rows written under a known-bad plugin window — a maintainer tool, NOT in the install set and not charter-referenced, like `ops-backlog.sh`) and the _"ops-reverify.sh dates rows"_ case |
| the fragment/lock scheme in `ops-verdict.sh` | update `ops-init.sh` (`verdicts.d/`, `.gitattributes`), the README evidence-gate section, the _"concurrent appends never interleave"_ case, **and** the `--mark-handoff` path (it writes DECISIONS.md under the same lock) |
| `templates/DECISIONS-header.md`'s kind enum | update `validate_plugin.DECISIONS_GATED_KINDS` / `DECISIONS_RECORD_KINDS` / `DECISIONS_MARKER_KIND` — the gated/record SPLIT is part of the contract (#9: a kind in the wrong constant is a kind the gate silently ignores) — + `check_decisions_schema` (pins the enum AND requires the hook/statusline/verdict to reference HANDOFF-MARK) and the _"deviation-gate"_ + _"dev\[N\] mirror"_ cases |
| a VALIDATOR CHECK itself — any pin in `scripts/validate_plugin.py` | **run the mutation before you believe it** — a pin with no red run is a hypothesis, so every fix carries a python case with the exact escape it was written against, plus the control. Why: `docs/LANDMINES.md` _"A pin is a hypothesis until the mutation runs red"_ + _"Six vacuities of the same shape"_. Full detail: docs/LANDMINES.md (0.11.9). |
| the `check_bare_name` reject set in any CLI | update the other two CLIs **and** the `case` filter in both `sentinel_owner_of_name` parsers **and** `ops-adopt.sh`'s inline `PREV` reject-set **and** `ops-sessionstart-hook.sh`'s migration reject-set (a sixth copy) — the readers must reject what the writers reject, or a name our CLIs could never have written reads as a valid foreign owner and the gate opens (_"name guards agree"_ + _"untrusted input"_ cases; `check_guard_parity` pins the `*__*` literal across the sites). Cases: the _"UNEXPANDED shell variable"_ block and its reader half, each mutation-checked separately — the guards do not cover for each other. Full detail: docs/LANDMINES.md (0.11.9). |
| the canonical tier set in `ops-tiers.sh` (`TIER_NAMES=…`) | update **`ops-render.sh`'s own `TIER_NAMES` literal** — `check_resolver_renderer_parity` enforces equality, reading both by regex; a rename/retype must update that regex, which fails _loud_. Full detail: docs/LANDMINES.md (0.11.9). |
| the seat set, a `tiers.env` line kind, or the renderer's body sources | `ops-tiers.sh` and `ops-render.sh` parse the same `tiers.env` (BOTH line kinds: tier→model AND seat→tier — the resolver skips seat lines, the _"seat line … skipped by the resolver"_ case) and share `check_routable` (`check_resolver_renderer_parity` compares it whitespace- and comment-insensitively: reflowing is free, a logic change is not). Why: `docs/LANDMINES.md` _"The seat table in `workflows/dispatch.js` is a literal map on purpose"_. Full detail: docs/LANDMINES.md (0.11.9). |
| the model-id guard (`check_routable`, workflows' `BAD_CHARSET`) | it judges WELL-FORMEDNESS ONLY — a decision, not an oversight (0.8.3). Why: `docs/LANDMINES.md` _"A catalogue of another system's facts goes stale"_. Cases: _"operator does not recognise"_ + _"only widens"_ + _"must not come back"_. Full detail: docs/LANDMINES.md (0.11.9). |
| a workflow's `BAD_CHARSET` | keep it pinned to its canonical literal in `check_workflows` **and** applied at a `.test(id)` call site. Parity across the copies is not enough: they are copy-pasted, so uniform drift is the realistic failure and identically-broken files are trivially "in parity" (F30) |
| an issue reference in tracked markdown, or `plugin.json` `repository` | keep label/URL agreeing by hand (0.10 deleted `check_issue_refs` — markdown link lint, not a shipping concern). Bare `#N` stays out of scope. `release_gate.CODE_SPAN_RE` still strips code spans and must stay standalone-runnable |
| the dispatch packet in `templates/OPERATOR.md` | update `docs/HANDOUT.md`'s copy **and** `validate_plugin.HANDOUT_PACKET_SPINE`. Full detail: docs/LANDMINES.md (0.11.9). |
| the auto-arm rule in `scripts/lib/autobar.sh` (#85) | ONE implementation, sourced by `ops-stop-hook.sh` AFTER `partition.sh` — the order holds because `autobar_decide` runs BEFORE `scan_pending`, so an armed sentinel is read by the existing mine-pending branch in the SAME fire. Cases: the _"auto-arm (#85)"_ block. Why (both removed suppression rules, why no third is possible, and the priced trade): `docs/LANDMINES.md` _"The auto-arm cannot tell a dead session from a busy one"_. Full detail: docs/LANDMINES.md (0.11.9). |
| the seat bindings or round structure in `workflows/debate.js` | `check_workflow_agent_types` proves the agentType NAMES a shipped agent; nothing in the validator says which call site gets which seat, so a debater prompt handed to `op-author` (Write + Edit — able to edit the artifact it argues about) ships green. Cases: _"debate.js runs three rounds"_ + _"dead-seat accounting"_. Full detail: docs/LANDMINES.md (0.11.9). |
| `args.isolate` / `args.isolateCheckout` in `workflows/review.js` (#74) | the runtime's `isolation: "worktree"` takes NO commit — the worktree is created at the DEFAULT BRANCH (measured twice). Why: `docs/LANDMINES.md` _"Isolation buys a clean tree, not a commit"_. Cases: _"#74"_. Full detail: docs/LANDMINES.md (0.11.9). |
| `args.isolate` / the adversarial seat's prompt in `workflows/review.js` (#23) | keep the two branches EXCLUSIVE: un-isolated ships F-A1 (`git status --porcelain`), isolated ships F-A2 (`git rev-parse HEAD` vs the named sha) and F-A1 must NOT also ship — a fresh worktree is clean by construction, so porcelain there is a control that cannot fail. Cases: the _"adversarial isolation"_ cases (the stub runtime captures `opts.isolation`). Full detail: docs/LANDMINES.md (0.11.9). |
| the feasibility lens's packet in `workflows/plan.js` (`earlierProduces`, #73) | the lens is ASKED whether a consumed dependency is produced by an EARLIER task, so it must RECEIVE those tasks' `produces` — without them 14/21 seats returned `needs-info` citing `dependency-missing`, 5 against a correct control plan. Full detail: docs/LANDMINES.md (0.11.9). |
| the plan graph in `workflows/plan.js` (`contractSet`, `edges`, `layers`, #66) | REPORT-ONLY and must stay so; `produces`/`consumes` stay ARRAYS of exact names (reverting is SILENT — the prose fallback still works); `graph.contractsInferred` records every prose fallback and the log says ESTIMATED. Declared edges are CONSECUTIVE pairs, `dependsOn` scans all earlier tasks — the gap is the spurious-serialisation signal. Report `graphWidth` only WITH `dispatchBound`. Enforcement: the node suite (0.10 deleted `check_northstar`; the cases live in `tests/test_workflows.mjs`) |
| the Stop hook's block MESSAGE (`ops-stop-hook.sh`, the two `echo`s) | it is composed from UNTRUSTED project data and read back by the model, so both halves are guarded (PR #88 review). Cases: the _"hostile ledger and a spaced path"_ block. Full detail: docs/LANDMINES.md (0.11.9). |
| a workflow's `args` NORMALIZER (the `typeof args === "string"` block) | all six must keep `catch { return args; }` — returning `{}` DISCARDS the operator's text silently, and brainstorm's copy did: a 4,000-char prose brief evaporated and the full fan-out ran against the placeholder (measured live: 7 agents, 123,935 tokens, 86s, every seat answering "cannot propose a direction without a topic"). Cases: _"spends ZERO agents"_. Full detail: docs/LANDMINES.md (0.11.9). |
| `northStar` in `workflows/plan.js` (#58) | read WITHOUT a fallback, keep the `Missed if:` requirement, keep `${northStar}` interpolated exactly once — into decompose, never a vet packet (6/6 feasibility seats raised goal findings against the control column when it went to the packets). Load-bearing guard: the node suite's captured-prompt assertion, which covers concatenation forms a count cannot see |
| the write ORDER in `ops-verdict.sh`'s verdict path (#14) | the GATE-EXCEPTION goes BEFORE the row, the fragment before the ledger, the sentinel clear last. Order is the whole fix for U2: row-first leaves a row with no exception, which the retry reads as an amendment and the bypass keeps its PASS while losing its audit line. Do NOT re-add the reverted guard (downgrade only when an exception exists) — an ARMED first verdict also leaves a row with no exception, and G1.7 catches the spurious firing. Case: _"G1.10"_, which asserts relative position in the source, mutation-checked |

| `commands/handoff.md`'s section list or its `--mark-handoff` line | the six sections are asserted against **both** the command and `templates/OPERATOR.md § HANDOFF` — parity alone passes when the charter is what lost a section (the HANDOUT_PACKET_SPINE lesson). The counter is `^[0-9]\+\. \*\*`, deliberately not `^[1-6]`: a bounded class counts at most six and is blind to a seventh, which is how it first shipped green against that exact mutation. Cases: the _"/cc-operator:handoff carries the six-section contract"_ case  **The grant must cover the prescription** (PR #104 review): the body prescribes an ABSOLUTE path, and `Bash(.operator/bin/ops-verdict.sh:*)` is a literal prefix on the command string that no absolute invocation starts with, so the model hit a permission prompt the frontmatter exists to avoid. `Bash(bash:*)` is the grant that covers a machine-specific path (interpreter is the prefix, path is an argument — start.md's reason), so the body prescribes `bash '<absolute path>' --mark-handoff …` and the case pins both halves. The #100 pin matches `.operator/bin/ops-` in ANY markup — the backtick-anchored form passed a fenced copy of the same relative command (measured). The fallback names the WALK-UP rule and `@no-vcs`, not only `git rev-parse` |
| `commands/start.md`'s steps or its `allowed-tools` | the case asserts the tools GRANT the steps the prose prescribes (`Bash(bash:*)` for step 1, `Write` for step 2) and that `ops-init.sh` is reached through `${CLAUDE_PLUGIN_ROOT}` — a bare `scripts/` path resolves only inside this repo (the v0.2.0 bug). Both grep-guards are pinned to the tokens they actually append; the `--inline` pattern matches the heading's backticks as `.` because shellcheck reads a backtick inside single quotes as command substitution (SC2016, CI-red 0.10) |
| a dead-agent guard in `brainstorm.js` / `crawl.js` (`== null` returns) | removing one makes the workflow THROW on the next property read rather than return, and an uncaught throw kills the node suite before its summary — the regression is caught either way, but the case that caught it becomes invisible. The dead-agent cases wrap `run()` in try/catch and convert the throw into their own failure. Keep that wrapping when adding one |

> Test cases are referenced **by title**, not by ordinal: `grep '^echo "-- Case' tests/test-scripts.sh`.
> A few referenced anchors ("G1.10", "dev[N] mirror") are `check` titles or section comments INSIDE a
> case block, not Case headers — when the Case grep misses, grep the quoted string anywhere in the
> file before concluding it was deleted.
> Numbers shift the moment a case is inserted, and a coupling table that quietly points at the
> wrong case is worse than one that points nowhere.
> | `plugin.json` `version` | add the matching `## [x.y.z]` as the newest heading in `CHANGELOG.md`, same commit (the release gate fails otherwise) |
> | the Stop-hook command in `hooks.json` | keep `ops-stop-hook.sh` + `${CLAUDE_PLUGIN_ROOT}` (validator check 7) |
> | a step or glob in `.github/workflows/validate.yml` | mirror it in `.forgejo/workflows/validate.yml` — same suites, but the two files CANNOT be identical and no validator pins them. Why: `docs/LANDMINES.md` _"The two CI files cannot be identical"_. Full detail: docs/LANDMINES.md (0.11.9). |
> | a suite's case count (adding or deleting cases) | raise the matching `FLOOR_*` in `tests/floors.env` in the SAME commit. It is a FLOOR (`>=`), so adding cases never goes red — only deletion does, which is the point. Nothing raises it automatically: with no auto-merge here there is no moment that could honestly do it, and a self-raising floor climbs to the luckiest executor and then fails every ordinary run |
> | a rung, its completion MARKER, or the CI step that runs it | update `scripts/gate-suite.sh` (the rung's command AND its marker), `validate_plugin.SUITE_RUNGS`, and all four CI files — `check_suite_floors` requires a live `gate-suite.sh <rung>` in every one and REFUSES a raw invocation coming back. Full detail: docs/LANDMINES.md (0.11.9). |
> | a `_"…"_` citation in CLAUDE.md, or a case/section title one names | they must agree — `check_coupling_case_refs` resolves every citation LINE-WISE against the CARRIER lines in `tests/` (or `docs/LANDMINES.md` when the surrounding prose names that file: classification is by CONTEXT, not by string) — since #115 a carrier is a suite `check`/`-- Case`/`# ---` line, a node assertion title (including its continuation line), or a python `def test_`/`assertFires(` line, never an arbitrary fixture string (#115's live escape: this repo's own fixture satisfied the production citations). Full detail: docs/LANDMINES.md (0.11.9). |
> | an agent's model/tools/NEEDS_CONTEXT | keep it project-agnostic — no `unknowns-harness`/`F1..F13` — and keep `model:` a tier alias (`opus`/`sonnet`/`haiku`), never a pinned ID (validator check 6) |

## The issue register — cross-repo and cross-session

**GitHub issues are the only durable memory this project has.** A session ends and
its context is gone; a chat transcript is not addressable and cannot be searched by
the next session or by another repo. A finding that lives only in a PR description
or a reply is a finding that did not survive. So the register is a rule, not a habit:

- **Anything identified and not implemented in the same change gets an issue before
  the session ends** — a gap, a bug, an optimisation, a better approach, an idea, a
  limitation knowingly accepted. Especially a limitation knowingly accepted: those
  are the ones that read as decisions later and were only ever deferrals.
- **File it in the repo that owns the FIX, not the repo where it was noticed.**
  Findings about the forge tooling go to `betmoar/cc-skills-plugin` (the `forge-run`
  skill), about the CI host to `betmoar/local-ci`, about the plugin here.
- **A cross-repo finding gets an issue in EACH affected repo, and each names the
  other** as `owner/repo#N`. A one-way link rots silently — the repo that was never
  told is the one that changes.
- **Every issue carries what was MEASURED** (the command and its output, or
  `file:line`), why it matters, and what would close it. A finding without a
  measurement is a hypothesis, and the register is not a place to store hypotheses
  as if they were facts. The same rule the evidence gate applies to a verdict row.
- **A session working in a repo STARTS by reading that repo's open register**, and
  says which issues it is and is not addressing. This is what makes the projects
  talk to each other rather than each rediscovering the same thing.

The three repos in this system, and what each owns:

| repo | owns |
|---|---|
| `betmoar/cc-operator-plugin` | the charter, the evidence gate, the validator and its pins |
| `betmoar/cc-skills-plugin` | the `forge-run` skill — pushing to `lokaal`, reading what CI actually did |
| `betmoar/local-ci` | the Forgejo/act/Woodpecker stacks the runs happen on |


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
`templates/`, `scripts/`, `hooks/`, `agents/`, and the manifests. The
narrative behind each item below moved to `docs/LANDMINES.md` (0.11.9);
this is the always-on summary.

- **`docs/TAGS.md`** is the in-tree resolution index for every charter
  `[DOC:spec-*]` tag; `check_charter` fails the build on a tag with no
  `### spec-<key>` entry, so the index cannot fall behind. Orphan entries (a
  retired tag's survivor) are allowed on purpose. The spec dir emptied in
  0.11.9 (backlog-charter removed; see git history).
- **`docs/PLAYBOOK.md`** holds the executable procedures (adding a guard,
  adding a reader, touching the lock), each derived from a bug that happened
  here.
- **`docs/REPLAY-CHARTER.md`** is the live-session replay protocol (R0–R8),
  hand-maintained prose with no validator pin — a message change in
  `ops-stop-hook.sh` or `ops-init.sh` means updating its quoted expectations
  by hand.
- **Audit handoffs are maintainer-local and never committed**, with one
  exception: `docs/audit-2026-08-09-handoff.md` (F67+) is the first that
  ships in-tree. `docs/audit-2026-07-31-handoff.md`'s path has an empty
  `git log --all` despite earlier revisions of this file citing it as
  shipped; `docs/audits/audit-2026-07-27-{findings,handoff}.md` are the same
  maintainer-local shape (F01–F06). All three survive only as code, comments,
  and CHANGELOG entries.
- **Everything else** (build ledger, plans, pilot runbook/findings,
  prior-project evidence) was removed from the tree in 0.3.0: see git
  history (tree ≤ v0.2.0) or the maintainer's local `.archive/dev/`.
- **The evidence-gate opt-in gap is CLOSED in #85** (`scripts/lib/autobar.sh`):
  the Stop hook auto-arms an owned sentinel on a >=2-path delta, enforcing
  ENGAGEMENT CONTRACT clause (1) in code. Coverage is deliberately partial:
  clauses (2) multi-session and (3) user-named done-state stay UNCOVERED, a
  non-git project arms nothing, a shared worktree suppresses the armer
  entirely, and a session can still satisfy it with one throwaway task it
  defers.

## Operator

@templates/OPERATOR.md — it is this session's operating charter.
