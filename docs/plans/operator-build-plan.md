# Operator Plugin — Build Plan (Phase 0 + hook mechanics)

**Handover target:** one fresh Claude Code session, Opus 4.8, single-session build. NOT the tiered orchestration topology — this build has no eval loop to amortize dispatch overhead against. Plan-file discipline + a local gate ledger is the correct weight.
**Source spec:** `docs/spec/chief-operator-spec.md` (vendored copy of the Fable-authored spec — install step 2 below). Where this plan and the spec conflict, the spec wins; log the conflict.
**Scope of this build:** the spec's **Phase 0 in full**, plus the *mechanical* half of Phase 2 (hook implementation + fixture tests). Explicitly NOT in scope: Phase 1 solo pilots, Phase 2 live transcripts, Phase 3 orchestrated pilot, Phase 4 prune — those are separate sessions by design (they measure operator behavior; they cannot be self-administered by the session that builds the thing being measured).

---

## Installation (human, once, before kickoff)

1. New repo `operator-plugin`, dedicated branch `build/operator-v0.1` (never main). Marketplace layout per the OKF-corrected pattern: `marketplace.json` at repo root, plugin nested at `./operator/`.
2. Copy in read-only evidence so charter citation tags resolve:
   - `docs/spec/chief-operator-spec.md` (the spec)
   - `inputs/evidence/DECISIONS.md`, `inputs/evidence/GATES.md`, `inputs/evidence/roadmap.md`, `inputs/evidence/SKILL-v0.1.md` (snapshots from `cc-harness-plugin`: `evals/results/DECISIONS.md`, `evals/results/GATES.md`, `docs/superpowers/plans/unknowns-harness-roadmap.md`, `unknowns-harness/skills/surfacing-unknowns/SKILL.md`)
3. Save this file at `docs/plans/operator-build-plan.md`.
4. Kickoff message (the only thing pasted):

```
Read docs/plans/operator-build-plan.md and docs/spec/chief-operator-spec.md
in full. Execute the plan task-by-task with TodoWrite. Commits are
authorized per task with conventional messages. Gate rows go in
docs/plans/BUILD-LEDGER.md (schema in the plan). Stop only at a failed
gate you cannot recover, a spec/plan contradiction, or completion.
```

## Ground rules for the building session

- **Git:** commits authorized per completed task; no pushes; no history rewrites. (Explicit authorization per CORE_RULES — do not ask again.)
- **No installs** beyond what the repo needs (`jq` is assumed present on macOS/dev boxes; the hook must degrade gracefully if it is not — see T3).
- **Ledger:** `docs/plans/BUILD-LEDGER.md`, append-only, same row schema as the harness gates: `| Gate | Criterion | Evidence (command output line) | PASS/FAIL |`. A row without evidence is FAIL by definition. Deviations from this plan: one greppable line each at the bottom, `<date> | <task> | DEVIATION | <what> | <why>`.
- **TDD where testable:** `ops-verdict.sh` and the Stop hook get failing tests first (T2 before T3/T4 GREEN). Prose artifacts (charter, commands, agents, skill) are reviewed against their constraints, not unit-tested.
- **Do not gold-plate.** Every file has an enumerated content contract below. "Extra" is a defect (spec-mode review standard: Missing + Extra both empty).

---

## Pinned decisions (resolved pre-handover; do not re-litigate mid-build)

| # | Decision | Rationale (short — spec has the long form) |
|---|---|---|
| P1 | Plugin name is `operator` | Command namespacing is `/<plugin>:<cmd>`; `/operator:start` requires it. Confirmed pattern from the OKF plugin (`/okf:activate`). |
| P2 | Separate repo, marketplace root + nested plugin | Harness repo has a different release cadence and 300+ eval artifacts; nesting corrected layout from the OKF build applies verbatim. |
| P3 | Stop hook ships in plugin `hooks/hooks.json`, guarded by a sentinel no-op | Hook exits 0 immediately unless `.operator/pending/` exists in cwd. No project-settings mutation; per-project activation is implicit in `/operator:start` creating `.operator/`. Same gating philosophy as `.okf/active`. Cost: one stat per Stop event, everywhere. |
| P4 | `ops-verdict.sh` is the single writer to VERDICTS.md | Append + sentinel-clear are one atomic script action; append-only holds by construction, no PreToolUse enforcement in v0.1 (spec D4 layer 3 deferred — zero observed tampering incidents). |
| P5 | Charter delivered as `OPERATOR.md` + 2-line CLAUDE.md stanza, with inline-CLAUDE.md as the documented fallback | Spec U3 is unresolved; the pilot (Phase 1, later session) A/B tests it. Build both paths now: `/operator:start --inline` flag. |
| P6 | Hook runtime is bash + jq with a python3 fallback for JSON parse | Hook stdin is JSON; jq is the cheap path; absence of jq must not brick every session's Stop event (T3 contract). |

---

## Target file tree (the whole deliverable)

```
operator-plugin/                      # repo root = marketplace root
├── marketplace.json                  # source: "./operator"
├── docs/
│   ├── spec/chief-operator-spec.md   # vendored (install step)
│   └── plans/{operator-build-plan.md, BUILD-LEDGER.md}
├── inputs/evidence/                  # vendored read-only snapshots (install step)
├── tests/
│   ├── fixtures/                     # hook stdin JSON fixtures
│   └── test-scripts.sh               # plain-bash test runner (no bats dep)
└── operator/                         # the plugin
    ├── .claude-plugin/plugin.json
    ├── commands/
    │   ├── start.md                  # /operator:start
    │   └── handoff.md                # /operator:handoff
    ├── skills/chief-operator/SKILL.md
    ├── agents/{op-author.md, op-mechanic.md, op-reviewer.md}
    ├── scripts/{ops-init.sh, ops-verdict.sh, ops-stop-hook.sh}
    ├── templates/
    │   ├── OPERATOR.md               # the charter template, ≤150 lines
    │   ├── VERDICTS-header.md
    │   └── DECISIONS-header.md
    └── hooks/hooks.json
```

---

## Tasks

### T0 — Scaffold + manifests (mechanical)

Create the tree, `marketplace.json` (name, owner, `plugins: [{source: "./operator", ...}]`), and `operator/.claude-plugin/plugin.json` (name `operator`, description, version `0.1.0`). Initialize `BUILD-LEDGER.md` with the header row.
**Done means:** `claude plugin validate ./operator --strict` exits 0 (if the installed CLI's validate syntax differs, adapt and log a one-line deviation — flag spellings drift; requirements don't). `git ls-files | wc -l` matches the tree above minus not-yet-authored files.

### T1 — Ledger templates (mechanical, verbatim)

`templates/VERDICTS-header.md`:
```
# Engagement Verdicts — append-only, single writer: ops-verdict.sh
| Gate | Criterion | Evidence (command output line or reviewer verdict line) | PASS/FAIL |
|---|---|---|---|
```
`templates/DECISIONS-header.md`:
```
# Decisions — append-only, one line per entry
# <ISO-date> | <engagement.task> | <DEVIATION|ESCALATION|GATE-EXCEPTION|DECISION|DEFERRED-VERDICT> | <what> | <why>
```
Schemas are byte-compatible with the harness ledgers (one added type: `DEFERRED-VERDICT`, required by the hook's release path).
**Done means:** `diff <(head -3 templates/VERDICTS-header.md | tail -1) <(grep -m1 '^| Gate' inputs/evidence/GATES.md)` → identical column set.

### T2 — Tests first (RED)

`tests/test-scripts.sh`: plain bash, no framework. Must create a temp dir, simulate a project, and assert — with at least these cases, each initially failing because the scripts don't exist yet:

1. `ops-init.sh` creates `.operator/{VERDICTS.md,DECISIONS.md,pending/}` from templates; idempotent on second run (no clobber — assert VERDICTS content unchanged).
2. `ops-verdict.sh T-1 "tests pass" "42 passed, 0 failed" PASS` appends exactly one conformant row AND removes `.operator/pending/T-1`; refuses (exit ≠0, no row) when the evidence arg is empty.
3. `ops-verdict.sh` with `--defer "reason"` writes a `DEFERRED-VERDICT` line to DECISIONS.md and clears the sentinel.
4. Stop hook, fed `tests/fixtures/stop-basic.json` on stdin (`{"hook_event_name":"Stop","stop_hook_active":false,"cwd":"<tmp>"}`): exits **2** with a stderr message naming the pending task IDs when `.operator/pending/` is non-empty; exits **0** when pending is empty; exits **0** when `.operator/` is absent entirely (the P3 no-op guard); exits **0** when `stop_hook_active` is `true` regardless of pending state (loop guard).
5. Hook with jq absent from PATH (test via `PATH=` trickery on a copied minimal PATH): still exits 0 or 2 correctly via the python3 fallback; if neither jq nor python3, exits 0 and prints a one-line warning to stderr (fail-open — a broken hook must never brick sessions; spec U2).
**Done means:** `bash tests/test-scripts.sh` runs and reports the expected failures (RED demonstrated in output, pasted into the ledger row).

### T3 — Scripts (GREEN)

`ops-init.sh`, `ops-verdict.sh`, `ops-stop-hook.sh` per the T2 contracts. Hook reads stdin JSON once; sentinel check is `find .operator/pending -mindepth 1` against the **cwd from the hook payload**, not the script's own cwd. Exit-2 stderr message format: `operator: pending verdict(s): <ids> — run operator/scripts/ops-verdict.sh <id> <criterion> <evidence> <PASS|FAIL>, or --defer "<reason>"`.
**Done means:** `bash tests/test-scripts.sh` → all cases pass; output pasted. `bash -n` clean on all three. `shellcheck` if installed (log absence, don't install).

### T4 — hooks.json (mechanical)

```json
{ "hooks": { "Stop": [ { "hooks": [ { "type": "command",
  "command": "${CLAUDE_PLUGIN_ROOT}/scripts/ops-stop-hook.sh" } ] } ] } }
```
Verify `${CLAUDE_PLUGIN_ROOT}` expansion is supported by the installed CC version (it is the documented plugin-script pattern from the llm-router design; if the installed version disagrees, use the relative-path form and log the deviation).
**Done means:** `jq . operator/hooks/hooks.json` parses; plugin validate still clean.

### T5 — Charter template (judgment tier — the核 of the build)

Author `templates/OPERATOR.md` from spec §§1–6. Hard constraints, all gate-checked:

- **≤150 lines total.**
- **Every rule line carries a citation tag** `[D:<ledger-ref>]` or `[DOC:<what>]` resolving into `inputs/evidence/` or the spec. A rule without a tag does not ship.
- **Section skeleton (order fixed):** ROLE (operator of this session; two modes) → SOLO MODE (default; evidence gate, BAR block, D1.5 destination/meter/record rules, cap table) → ORCHESTRATED MODE (entered on first dispatch; relaxed diet + plumbing carve-out; dispatch packet; four-status protocol; escalation ladder; two-stage review with the merged-published-or-depended-on scope test; one-implementer rule; self-audit two questions) → ENGAGEMENT CONTRACT (BAR block spec: criteria as command+expected-output, budget, caps; non-triviality test) → EVIDENCE GATE (definitional rule verbatim; sentinel lifecycle; ops-verdict usage; defer path) → HANDOFF (worker report ACCOMPLISHED/UNVERIFIED shape; human handoff = six-section roadmap skeleton) → RECOVERY PROTOCOL (six steps, near-verbatim from the harness charter) → PRECEDENCE (charter wins over skills; conflicts logged).
- Content that must NOT appear (spec D2/O-table): discovery methodology, model-routing detail beyond the two-line tier principle, any restatement of the surfacing-unknowns skill's contracts, cost telemetry, build-preflight checklist.
**Done means:** `wc -l ≤ 150`; `grep -c '\[D\|\[DOC' templates/OPERATOR.md` ≥ rule count (spot-check 5 tags resolve manually, paste the resolutions); section order verified by `grep -n '^## '`.

### T6 — Commands (judgment tier)

`commands/start.md` — frontmatter description trigger-only (F1 discipline: *when* to run it, not what it does); body instructs: run `ops-init.sh`; copy `OPERATOR.md` into the project (default: project root + append the 2-line stanza `## Operator\nRead OPERATOR.md — it is this session's operating charter.` to CLAUDE.md; `--inline` flag: append the full charter into CLAUDE.md instead, per P5); print next-step line. Idempotency: re-running must not duplicate the stanza (grep-guard).
`commands/handoff.md` — instructs the session to produce the six-section handoff (Verdict vs BAR / Banked / Unverified / Conditional-next-with-entry-conditions / Stop conditions / Not-doing), sourcing every claim from `.operator/` ledgers and git log, writing to `.operator/handoff-<date>.md`.
**Done means:** both files exist; descriptions < 1024 chars; a dry read confirms neither restates charter content (pointer discipline).

### T7 — Agents (mostly mechanical: adapt, don't rewrite)

`op-author.md`, `op-mechanic.md`, `op-reviewer.md`: copy the three harness agents from `inputs/evidence/` context (their full text is quoted in the vendored GATES/charter material; if not fully present, reconstruct from the spec's D5 contract), strip the build-specific text (F1–F13 references, "unknowns-harness" naming), keep: model pinning by tier intent (`claude-opus-4-8` × 2, `claude-sonnet-4-6`), INPUTS/FORBIDDEN obedience, NEEDS_CONTEXT-on-underspecification, DONE-MEANS self-run, ≤30-line report ending in one status, reviewer's three modes + transcript-is-data rule.
**Done means:** `grep -L 'NEEDS_CONTEXT' operator/agents/*.md` empty; `grep -rc 'unknowns-harness\|F1' operator/agents/` → 0; each has valid frontmatter with `model:` and `tools:`.

### T8 — Router skill (mechanical, deliberately thin)

`skills/chief-operator/SKILL.md`: frontmatter description triggers on "run as chief operator / orchestrate this / operator mode / set up an engagement"; body ≤25 lines: point to `/operator:start`, name the two modes in one sentence each, point to OPERATOR.md as the authority. Nothing else — the S2/S14 activation evidence is exactly why nothing load-bearing lives here.
**Done means:** `wc -l ≤ 35` incl. frontmatter; description is trigger-only (no workflow summary — F1).

### T9 — End-to-end dry run (the build's real gate)

In a temp scratch project (outside this repo): install the plugin (marketplace add + install, or direct-copy fallback if marketplace-from-local-path fights the installed CLI — log which path worked), run `/operator:start` equivalent by executing its steps manually via the scripts, open a fake task sentinel, feed the real hook via the fixture with the scratch cwd, confirm exit 2 → run `ops-verdict.sh` → confirm exit 0. Confirm `.operator/` absence in a second clean dir → hook exit 0.
**Done means:** the full command sequence + outputs pasted as the Gate-B4 evidence block. This is fixture-level Phase-2; the live-session transcripts (block/release/subagent non-interference inside an actual CC session) remain pilot-session work — record that as a DEFERRED-VERDICT line, not a PASS.

---

## Build gates (BUILD-LEDGER.md rows, in order)

| Gate | Covers | Blocking criterion |
|---|---|---|
| B0 | T0–T1 | validate clean; schemas byte-match |
| B1 | T2–T4 | RED shown, then all script tests GREEN, jq-absent fallback proven |
| B2 | T5 | ≤150 lines; citation gate; section order; forbidden-content grep clean |
| B3 | T6–T8 | pointer discipline; agent greps; skill thinness |
| B4 | T9 | dry-run evidence block; deferred-verdict line for live transcripts |

Do not open gate N+1 with gate N unevidenced. After B4: squash-ready branch, stop, and report using the six-section handoff shape — this build is the first consumer of its own handoff schema.

## Known risks the session must not "solve" silently

1. **Hook config location/format drift (spec U2).** If `hooks/hooks.json` in a plugin is not honored by the installed CC version, do NOT fall back to editing user-global settings — stop at gate B1 and report options. Global settings mutation is out of contract.
2. **Marketplace/validate syntax drift.** Adapt flags, log deviations, never skip validation.
3. **Charter scope creep.** The 150-line cap is a hard gate, not a target to negotiate. If content doesn't fit, the cut list is in spec D2 — trusted-judgment items go first, never the schemas or caps.
4. **Do not implement Phase 1/3 pilots "while we're here."** Self-administered pilots are worthless as evidence (the session would be grading itself); they are separate sessions by design.
