# cc-operator — token-diet audit handoff (2026-07-31)

The departing-architect audit for the **workflow-orchestration + token-diet**
pass. Complements the 2026-07-27 handoff (the gate-hardening pass) — this one
covers the workflow layer, the tier system, and the token-diet axes. For the
*why* behind each decision, read the finding in `AUDIT_LOG.md` (the IDs match).

> The CLAUDE.md "Provenance" section references `docs/audit-2026-07-27-handoff.md`,
> which is **not present in the tree** (a dangling ref). This 2026-07-31 doc is
> the one that exists; the 2026-07-27 ledger lives only in `AUDIT_LOG.md`'s
> Phase 2 entries (F01–F06). Fix the CLAUDE.md ref or restore the file.

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

1. **Implement the input-axis compressor (F11).** — context: `docs/spec/input-axis-compressor.md` is the full boundary contract; port Chisle's `hooks/chisle-compress-output.js` (zero-LLM, deterministic) with cc-operator's gate-CLI carve-out. — first step: resolve the I2 open question (is the gate-CLI exclusion list alone sufficient, or does capture need a session flag?). — done-when: PostToolUse hook shipped; replay test asserts Read/Edit/Write never mutated and gate CLIs never compressed; validator check (#1-3 in the spec) green.
2. **Resolve the CLAUDE.md dangling ref** to `docs/audit-2026-07-27-handoff.md` (absent). — first step: decide restore-the-file vs fix-the-ref. — done-when: the Provenance section points at a file that exists.
3. **Statusline orchestration progress** (pre-existing Task #1). — context: show workflow phase / % complete on the bar. — first step: brainstorm the segment against `scripts/statusline.sh`'s byte bound + the gate-partition it already mirrors. — done-when: segment shipped, `check_statusline` green.
4. **cc-agents retirement** — HALTED (not superseded). Do not resume without re-scoping; its model-profile system is concurrent with, not replaced by, this plugin's tier resolver.
