# CLAUDE.md — maintainer handoff for cc-operator

This is the map a maintainer (human or agent) needs before editing. It records
the couplings that break silently and the landmines that have already been hit.
For the design rationale behind every decision, read `docs/spec/` and
`docs/plans/BUILD-LEDGER.md`; for what the pilots found, `docs/plans/*FINDINGS*`.

## The load-bearing map

- **`templates/OPERATOR.md` is the product.** Everything else exists to
  materialize, gate, or route to it. It is capped at 150 lines with a fixed
  section order and a citation tag on every rule line; `scripts/validate_plugin.py`
  enforces all three. When you edit it, re-run the validator — the cap is a hard
  gate, not a target.
- **The evidence gate is three files that must agree**: `ops-init.sh` scaffolds
  `.operator/`, `ops-verdict.sh` is the *single writer* to `VERDICTS.md`, and
  `ops-stop-hook.sh` blocks Stop while `.operator/pending/` is non-empty. The
  sentinel filename `<id>` is the shared key across all three; change the
  convention in one and you break the gate.
- **The charter references the scripts by relative path** (`scripts/ops-verdict.sh`)
  in its EVIDENCE GATE section. `hooks/hooks.json` references the hook by
  `${CLAUDE_PLUGIN_ROOT}/scripts/ops-stop-hook.sh`. These are different path
  bases on purpose: the charter is materialized *into a user's project* (where
  `scripts/` means the plugin's, via install), the hook runs *from the plugin
  root*. Do not "unify" them.

## If you touch X, update Y

| If you change… | You must also… |
|---|---|
| the plugin name in `plugin.json` | update `marketplace.json` name, the `/cc-operator:` command refs in `OPERATOR.md` + `SKILL.md`, `README`, and `validate_plugin.PLUGIN_NAME` |
| `templates/VERDICTS-header.md`'s table header | update `validate_plugin.VERDICTS_HEADER` and know you are breaking every existing ledger's grep-compatibility |
| a charter section heading or its order | update `validate_plugin.CHARTER_SECTION_ORDER` |
| the sentinel/pending convention in any `ops-*.sh` | update the other two scripts, `tests/test-scripts.sh`, and the EVIDENCE GATE prose in `OPERATOR.md` |
| `plugin.json` `version` | add the matching `## [x.y.z]` as the newest heading in `CHANGELOG.md`, same commit (the release gate fails otherwise) |
| the Stop-hook command in `hooks.json` | keep `ops-stop-hook.sh` + `${CLAUDE_PLUGIN_ROOT}` (validator check 7) |
| an agent's model/tools/NEEDS_CONTEXT | keep it project-agnostic — no `unknowns-harness`/`F1..F13` (validator check 6) |

## Landmines (already hit — do not re-hit)

- **The Stop hook must use bash builtins + one JSON parser only.** It reads
  stdin with `read -r -d ''` (a line loop drops a newline-less final line — a
  real bug that once made the hook see an empty cwd and always exit 0) and
  enumerates `pending/` with a glob, not `find`. Reason: the hook fires on
  *every* session's Stop event; if it depends on a binary missing from a
  stripped PATH, it bricks the session. It must fail *open* (exit 0 + warning)
  when neither `jq` nor `python3` is present. `tests/test-scripts.sh` case 5
  proves this — keep it.
- **`.operator/` and `OPERATOR.md` keep their names** even though the plugin is
  `cc-operator`. They are the ledger namespace and the charter filename, not the
  command namespace. Renaming them churns the scripts, tests, hook, and charter
  for zero functional gain.
- **The plugin lives at the repo root** (`source: "./"`), flattened from an
  earlier nested `./operator/` layout to match the cc-unknowns standard. Repo-
  relative script paths (in `tests/`, `pilot-setup.sh`) assume root;
  `${CLAUDE_PLUGIN_ROOT}` paths are layout-independent and were unaffected.
- **CI cannot run the live-session tests.** `tests/test-scripts.sh` exercises the
  hook at fixture level (JSON on stdin). The *live* behavior — the hook firing on
  a real turn-end, `SubagentStop` non-interference — was proven manually
  (2026-07-07, `BUILD-LEDGER.md`), not in CI. A green CI is necessary, not
  sufficient, for the gate; re-verify live after changing the hook.

## Provenance (read-only, under docs/)

- `docs/spec/chief-operator-spec.md` — the design spec (D1–D6, the seams).
- `docs/plans/operator-build-plan.md` + `BUILD-LEDGER.md` — the build and its
  gate evidence.
- `docs/plans/PHASE1-FINDINGS.md` — the pilot finding that the evidence gate is
  opt-in and the "trivial" wording invites skipping it (still an open charter
  question; see the fix branch history).
- `docs/plans/PILOT-RUNBOOK.md` + `tests/pilot/` — how to run the operator-
  behavior pilots (Phases 1/3/4), which a builder session cannot self-administer.
