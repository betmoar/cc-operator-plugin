# cc-operator — token-diet audit handoff (2026-07-31)

The departing-architect audit for the **workflow-orchestration + token-diet**
pass. Complements the 2026-07-27 handoff (the gate-hardening pass) — this one
covers the workflow layer, the tier system, and the token-diet axes. For the
*why* behind each decision, read the finding in `AUDIT_LOG.md` (the IDs match).

> (Resolved 2026-08-01: the 07-27 files live at `docs/audits/` — gitignored,
> local-only — and CLAUDE.md's Provenance now says so. A fresh clone reads the
> F01–F06 summary from `AUDIT_LOG.md` Phase 2.)

## Mental model (the workflow layer, in 5 sentences)

The plugin is a **discipline-and-gate** layer: it refuses to let a session end
with an open task and no recorded verdict. The new **workflow layer**
(`workflows/{review,brainstorm,plan}.js`) fans cheap-tier lenses and converges
on judgment — but a workflow script is sandboxed (no fs/process/require/import),
so its *only* input channel is the `args` the operator passes. **Tier→model
resolution lives in `ops-tiers.sh`** (the resolver), which emits a JSON map the
operator forwards to a workflow as `args.tiers`. The resolver↔workflow contract
is held by validator parity checks; the concurrency contract (the ledger lock)
is held by a byte-identical lock block in two CLIs. Everything else exists to
materialize, gate, or route to `templates/OPERATOR.md`.

## Load-bearing map (ranked by blast radius)

1. **`templates/OPERATOR.md`** — the product (150-line cap, fixed order, citation tags).
2. **The 6-script evidence gate** — sentinel filename `<id>` is the shared key.
3. **Sentinel ownership partition** (mine/foreign/unowned) — 4 readers must agree on `session_id:`.
4. **`validate_plugin.py`** — the contract enforcer; `check_*` encode every coupling.
5. **`ops-verdict.sh` + `ops-adopt.sh` lock** — single-writer concurrency safety; budgets env-overridable but validated.
6. **The tier system** — `ops-tiers.sh` (resolver) ↔ workflows' `KNOWN_TIERS` (acceptance); must be the same set.

## Non-obvious decisions (and why)

- **`KNOWN_TIERS` ≠ `DEFAULT_TIERS`** (chosen over making them equal). DEFAULT_TIERS is what a workflow *dispatches* (review: 2); KNOWN_TIERS is what it *accepts* (always 4). Rejecting the rejected alternative ("align them") — aligning re-opens F07: forwarding the resolver's full map throws on a valid-but-unused tier.
- **Lock budgets env-overridable, but validated** (chosen over hardcoded). A pure test seam. The rejected alternative — a separate test-only copy of the lock — would drift from production. The seam keeps production-defaults-when-unset identical; the validation closes the non-numeric/zero hole the seam opened.
- **The input-axis compressor is spec-only this pass** (chosen over implementing it). The evidence-gate carve-out (compressor off for gate CLIs / verdict capture) must exist *before* the hook — a compressed verdict trail falsifies the gate. Spec at `docs/spec/input-axis-compressor.md`.
- **Workflows reject unknown tier keys against the *canonical namespace*, not their own DEFAULT_TIERS** (chosen over the prior `hasOwnProperty(DEFAULT_TIERS)`). The old guard caught typos but also rejected valid resolver tiers. The new guard catches typos (key not in the canonical 4) AND accepts valid-but-unused tiers.

## Landmines (looks wrong but is load-bearing / looks safe but isn't)

- **F03 was "fixed" by deleting IMPLEMENT; that fix caused F07.** The dead-looking declaration was a *consistency anchor*. The real fix (F07) is accept-and-ignore, not delete. Do not re-delete it.
- **A `KNOWN_TIERS` in a comment does not satisfy the namespace check** — the check matches code lines only. Looks present, isn't enforced.
- **The fail-open shape**: a validator check that silently passes when its input is unreadable is worse than no check (it *looks* enforced). The namespace check once did this; it now fails loud. Any new "read X and assert Y" check must fail loud on a read failure, not return None/skip.
- **`node --check` is too lenient to gate on** (measured: passes redeclared consts, unclosed parens). The structural checks are what the build enforces; a syntax error surfaces at launch.

## Couplings — "if you touch X you must also update Y"

See the table in `CLAUDE.md`. Two added this pass:
- **the canonical tier set in `ops-tiers.sh` (`TIER_NAMES`)** → every workflow's `KNOWN_TIERS` + the `_resolver_tier_names` regex (if you retype the line).
- **a lock budget var** → the positive-int + RECLAIM_WAIT<LOCK_SPINS guard in BOTH lock files (byte-identical, inside the LOCK BLOCK).

## Guardrails shipped this pass (the enforcement lives here, not in prose)

| Invariant (named) | Where | Enforcement | Artifact |
|---|---|---|---|
| workflows-accept-resolver-namespace | each workflow | `KNOWN_TIERS` includes every resolver tier | `validate_plugin.check_workflow_tier_namespace` + 5 pytest tests |
| resolver-readable-or-fail-loud | validator | `_resolver_tier_names` fails loud, never open | same check + `test_resolver_tier_names_unreadable_fails_loud` |
| lock-budgets-are-positive-ints | both lock CLIs | resolve-time guard, exit 2 on bad value | 3 bash cases (non-numeric/zero/reclaim≥spins refused) |
| reclaim-wait-below-lock-spins | both lock CLIs | resolve-time guard | same 3 cases |
| workflow-tier-regexes-byte-identical | all workflows | parity check | `validate_plugin.check_workflow_parity` (pre-existing) |

Each test **names the invariant** — read the failure, understand the contract.

## Residual risk register (known, not fixed)

| Risk | Sev | Confidence | Why not fixed | Mitigation in place |
|---|---|---|---|---|
| Input-axis compressor unimplemented (F11) | P1 (leverage gap) | high | spec-first rule; carve-out must precede code | spec written; open question flagged |
| F02 residual: args-normalizer + unknown-tier-key not parity-checked across workflows | low | high | `check_workflow_parity` covers ROUTABLE/BAD_CHARSET only; KNOWN_TIERS covered separately | a divergence surfaces as a different error message, not a silent mis-route |
| Converge-on-Opus 529 fragility | low (availability) | high | needs a live load test | documented as improvement candidate, not a bug |
| F05b posture: only the references lens has a catch | low | high | other lenses propagate (intentional) | log-on-catch applied to references; intentional elsewhere |

## Backlog (prioritized, pickup-able cold)

1. **Implement the input-axis compressor (F11).** — context: `docs/spec/input-axis-compressor.md` is the full boundary contract, REWRITTEN 2026-08-01 (round 2): the I2 open question is CLOSED (spill-and-cite mechanism; the CLI-exclusion lean was vacuous — F16), thresholds are pinned, Agent/mcp dropped from the allowlist, ledger paths excluded BY PATH. — first step: port Chisle's `hooks/chisle-compress-output.js` against the pinned spec; ship the OPERATOR.md spill-citation rule in the same commit. — done-when: PostToolUse hook shipped; the replay test asserts every case in the spec's guardrail #3; validator checks #1-2 green.
2. ~~CLAUDE.md dangling ref~~ — DONE 2026-08-01 (Provenance points at `docs/audits/`, notes it is gitignored).
3. ~~Statusline orchestration progress~~ — DONE 2026-07-31 (8c640ff, wf segment) + hardened 2026-08-01 (F12 corrupt-bar fix, F26 transcript-mtime liveness).
4. **cc-agents retirement** — repo-side (tag/strip/README/marketplace) is the human's. cc-operator-side absorption is COMPLETE as of round 2 (see the absorption ledger below); the model-profile one-command fleet flip remains a cc-agents-only feature, recorded as not-ported.
5. **Round-2 deferred decisions:** (a) the spec-plan-suggest PostToolUse auto-trigger (cc-agents) was dropped with no decision — decide dropped-by-design (charter routing supersedes) or ride it on the F11 hook registration; (b) reconcile the absorption inventory against the INSTALLED cc-agents 0.3.0 set (glm-scout discovery role, glm-review-design) — one paragraph here when decided.

---

# Round-2 addendum (2026-08-01) — post-absorption audit

Five-axis pass (context bloat / token maximization / agent consolidation /
regression / compressor-spec) over the post-f86ecda delta: the renderer
(ee93bec), the unknowns fold (4e73619), and the absorption commit (8c640ff).
Findings F12–F27 in `AUDIT_LOG.md` (linted, admissible format). 19-agent
panel + operator repros; every P0–P2 adversarially verified.

## What round 2 changed (mental-model deltas)

- **The renderer now OWNS its files explicitly.** Rendered agents end with the
  `RENDER_MARK` line; render/revert delete marked files only and refuse to
  overwrite an unmarked file at a seat's name (F17). The spec §3.4
  last-known-good file is GONE (written-never-read; ownership subsumes it).
- **Render bodies are single-sourced from plugin-root agents** (F14):
  `agents/op-<seat>.md` → `_templates/<seat>.tmpl` → `default.tmpl`. The seat
  templates for crawler/brainstorm were deleted; those seats are now shipped
  plugin-root agents (`op-crawler.md`, `op-brainstorm.md`), which also gives
  the crawl workflow a real dispatch target (F22).
- **Seat names are allowlisted** (`[A-Za-z0-9_-]`) and the seat-override filter
  is a literal awk compare (F18 — BRE injection deleted unrelated seats).
- **`ops-tiers.sh` skips seat lines** (validating the tier VALUE) so both
  tiers.env line kinds coexist in the one scaffolded file (F15).
- **Default seat tiers match the aliases** — author=JUDGMENT,
  mechanic=IMPLEMENT (F21; the down-tiered defaults violated the charter's
  routing rule on plain dispatch).
- **plan.js vet is spec-excerpt-based** (F13): decompose emits a required
  `specExcerpt` per task; the feasibility lens never sees the full spec again.
- **review.js has a fifth lens** — correctness/error-handling at MECHANICAL
  (F23: no other lens asks "is there a bug"); plan's vet enum gains `risk`.
- **The charter cap is byte-honest** (F19): 100-char non-table line bound +
  9000-byte ceiling in `check_charter` (constants `CHARTER_MAX_LINE_CHARS`,
  `CHARTER_MAX_BYTES`).

## Guardrails shipped (round 2)

| Invariant (named) | Enforcement | Proven firing |
|---|---|---|
| wf-agentType-names-shipped-agent (F22) | `check_workflow_agent_types` | op-nonexistent → FAIL, restore → green |
| charter-line+byte-bounds (F19) | `check_charter` additions | packed line → FAIL; table row exempt; ceiling test |
| renderer-deletes-only-owned (F17) | RENDER_MARK + bash cases | op-custom survives render+revert; collision rc=2 |
| seat-name-allowlist + literal-override (F18) | check_seat_name + awk | 4 metachar probes refused; override intact |
| resolver-skips-seat-lines (F15) | ops-tiers load_file branch + bash cases | scaffold example resolves; bad VALUE dies |
| rendered-implementers-keep-tools (F14) | bash cases on rendered frontmatter | Write/Edit + disallowedTools asserted |
| plan-vet-never-carries-full-spec (F13) | node test (BIG_SPEC sentinel) | sentinel in decompose only |
| statusline-one-line-wf-segment (F12) | bash case done=0 | corrupt render reproduced, then fixed |

## Absorption ledger (cc-agents → cc-operator, closing F23's class)

| cc-agents artifact | Disposition |
|---|---|
| glm-code-crawler | → `agents/op-crawler.md` (plugin-root) + `workflows/crawl.js` |
| code-crawl skill | → `workflows/crawl.js` (operator packs shards; harness caps concurrency) |
| glm-brainstorm | → `agents/op-brainstorm.md` + brainstorm workflow's diverge phase |
| glm-bulk-reader | dropped BY DESIGN (spec 07-28 §3.3: sharded crawler covers it) |
| review-panel skill | → `workflows/review.js` (thresholds byte-identical; REFUTED hard-stop kept) |
| glm-review-code | correctness/error-handling axes → review.js `correctness` lens (round 2, F23) |
| glm-review-plan | risk axis → plan.js vet `risk` kind (round 2); sequencing already covered (dependency order + produced-by checks) |
| glm-review-spec / glm-review-implementation | → review.js `spec` + `feasibility` lenses |
| coder / reasoner / simple (3-role) | → 4-tier system (spec 07-28 §3: separates strong seat from second-opinion seat) |
| glm-implementer | → op-mechanic (plain or rendered; render now keeps Write/Edit — F14) |
| /model-profile fleet flip | NOT ported — tiers.env edit + render + restart is the migration path; one-command flip stays cc-agents-only (recorded, deliberate) |
| spec-plan-suggest PostToolUse trigger | NOT ported, decision pending (backlog #5a) |

## Residual risks added in round 2

| Risk | Sev | Why not fixed | Mitigation |
|---|---|---|---|
| statusline wf schema is undocumented harness internals | low | can't pin what we don't own | fail-toward-silence + fixtures match live journal (verified against a real run) |
| crawl merge stringify bounded only by defensive caps (200/40/15 per digest) | low (P3, verifier-downgraded) | 1M-ctx JUDGMENT default makes overflow implausible | caps shipped anyway; hierarchical merge if N ever ~50+ |
| brainstorm references lens: no agentType (needs default toolset for web search), output capped nowhere | low (P3) | op-scout's toolset lacks search; a schema would strip the tools | single call, format-constrained prompt; revisit if converge bloats |
| workflow prompts + end-to-end fan-out untested live | med | needs live harness + models — a pilot, not a unit test | execution tests stub agent(); prompts reviewed twice |
