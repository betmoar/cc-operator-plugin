# AUDIT_STATE.md — principal-architect audit of cc-operator-plugin

- **Mode:** AUTONOMOUS
- **Target:** /home/user/cc-operator-plugin @ b653c25 (branch claude/principal-audit-autonomous-8e8cw1)
- **Phase cursor:** P3 IN PROGRESS — done: F120/F121/F122 (compressor, red→green 90→97), F101/F102/F116/F119/F124/F125/F117 (hooks+statusline, red-run 11 FAIL on old code, suite 743+/0), F103–F107/F109/F110 (workflows arm, 354→384, diffs re-verified), docs F108/F111–F115 + CLAUDE.md/LANDMINES/PLAYBOOK additions. PENDING: validator-pin arm (F126–F134 + F131 + F120 pin) — verify its mutations red myself when it lands, then full-suite run, commit clusters, P4 wrap. DEFERRED: F118, F123 (DECISION-02 in log).
- **Baseline (pre-change):** pytest 229 passed (+16 subtests) · bash suite 732/0 (1 root-skip) · workflows 354/0 · compress 90/0 · validate_plugin rc 0 · shellcheck absent locally
- **COMMIT gate:** DECISION-01 — branch-scoped commit/push + draft PR pre-authorized by session task instructions; nothing else outward.

## Load-bearing map (own read, CONFIRMED against source)

| Component | Role | Blast radius if broken |
|---|---|---|
| scripts/ops-verdict.sh (751L) | single writer to VERDICTS.md; lock; ownership gate; retro-gate; defer; reconcile; mark-handoff | ledger corruption or a silently-open/silently-closed gate — the product's core claim |
| scripts/ops-stop-hook.sh (329L) | Stop gate: exit 2 blocks; sources lib/partition.sh + lib/autobar.sh | gate silently off (exit 0 wrongly) or session bricked (exit 2 wrongly) |
| scripts/lib/partition.sh (228L) | THE partition rule (mine/unowned/foreign; deviation scan, asymmetric clearing #90) | hook and bar disagree; deviation gate opens or wedges |
| scripts/lib/autobar.sh (223L) | auto-arm (#85): >=2 changed paths → owned sentinel; fail-open | infinite block (arm-per-Stop) or permanent silent disarm |
| scripts/ops-task.sh / ops-adopt.sh | sentinel open (O_EXCL, name=owner__task) / ownership re-stamp under the verdict lock | unclearable or forgeable sentinels |
| scripts/ops-sessionstart-hook.sh (275L) | session-id injection (mechanism root); legacy migration; bin/ upgrade; ephemera wipes; gitignore v1→v2 | stale gate CLIs (#34), stranded owners, destroyed user gitignore (#32 class) |
| scripts/ops-init.sh + ops-install-set.sh | scaffold + THE install-set manifest | charter's .operator/bin paths dangle (v0.2.0 class) |
| scripts/validate_plugin.py (2527L) | cross-file invariant pins (parity, bounds, vacuity-hardened) | couplings drift silently; the repo's whole maintenance model |
| templates/OPERATOR.md | the product (capped charter) | everything downstream |
| workflows/*.js + agents/op-*.md | orchestration layer | wrong-model/wrong-seat dispatch, silent arg loss (#92 class) |
| scripts/ops-compress.mjs | PostToolUse output compressor + spill | evidence elided without citation path |
| scripts/statusline.sh | renders the same partition (tail-window approx) | bar describes a different gate than runs |

## Implicit contracts (depended on, never checked at the seam)
1. Hook payload `cwd`/`session_id` are absolute/harness-shaped; session ids never contain the reject-set chars (guards degrade, never verify against the harness).
2. SessionStart fires with cwd == project root (exact-match `$cwd/.operator`, ops-sessionstart-hook.sh:57) — while the Stop hook walks up. DELTA, see F-draft-1.
3. The Bash tool's cwd persists across calls (drives #94/#95 design).
4. `.operator/bin/` copies == shipped scripts between sessions (mtime probe assumes clock sanity).
5. Agent `model:` enum (sonnet|opus|haiku|fable) is a harness fact, re-checked manually per commands/tiers.md.
6. bash >= 3.2 semantics everywhere (no assoc arrays, `read -d ''` EOF behavior); LC_ALL=C discipline for byte-counting.
7. VERDICTS.md rows greppable as 4-cell pipe tables forever (header pinned).

## Intent-vs-behavior delta (P1 exit)
- ops-sessionstart-hook exact-matches .operator while the rest of the system walks up (F01/#95 class, unresolved on this hook).
- SessionStart banner prescribes RELATIVE `.operator/bin/...` commands; the Stop hook went absolute for exactly this (#94). Charter stays relative by design (committed artifact).
- statusline.sh header claims "builtins + one optional JSON parser"; body uses stat/tail/grep/date (all failure-guarded — comment drift only).
- commands/tiers.md cites docs/spec/2026-07-29-* and 2026-07-28-* which exist in NO checkout (CONFIRMED: ls docs/spec → TAGS.md, backlog-charter.md only).
- fallback_holder_read lacks the brace-wrapped redirection its twin lock_holder_read carries (both LOCK BLOCK copies; stderr-noise-only divergence).
- Planted `A__B__C` sentinel: reader yields task id `B__C` which every CLI refuses (`__` guard) — block message names an uncloseable id (adversarial-only path).

## Open DECISION log
- DECISION-01 (see AUDIT_LOG.md).

## What's left
- P2: collect + re-verify 4 subagent reports; write admissible findings; lint them; loop-until-dry pass on anything uncovered (ops-tiers/render/backlog read clean on first pass; compress/workflows/validator delegated).
- P3: remediate (branch-scoped), verify per-fix vs baseline.
- P4: guardrails + playbook + handoff + backlog artifacts.
