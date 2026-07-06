# Operator Plugin — Build Ledger

Append-only. Row schema (byte-compatible with the harness gates):

| Gate | Criterion | Evidence (command output line) | PASS/FAIL |
|---|---|---|---|

Deviations from the plan: one greppable line each below, format
`<date> | <task> | DEVIATION | <what> | <why>`.

## Gates

| Gate | Criterion | Evidence (command output line) | PASS/FAIL |
|---|---|---|---|
| B0/T0 | `claude plugin validate ./operator --strict` exits 0 | `✔ Validation passed` / `exit=0` | PASS |
| B0/T0 | marketplace manifest validates | `Validating marketplace manifest: …/.claude-plugin/marketplace.json` → `✔ Validation passed` / `exit=0` | PASS |

## Deviations

2026-07-06 | install | DEVIATION | Kickoff started on `main`; created branch `build/operator-v0.1` before any work | Plan install-step-1 mandates a dedicated branch "never main"; the human skipped it — recoverable, corrected before T0
2026-07-06 | install | DEVIATION | Plan file was saved at `docs/plan/` (singular); renamed to `docs/plans/` via `git mv` | Plan install-step-3 and the target file tree both specify `docs/plans/`; the kickoff message also references `docs/plans/BUILD-LEDGER.md` — aligned to the plan's own spelling
2026-07-06 | T0 | DEVIATION | `marketplace.json` placed at `.claude-plugin/marketplace.json`, not repo root as the plan's tree shows | Installed CLI (`claude plugin validate .`) requires `.claude-plugin/marketplace.json`; root placement fails validation with "No manifest found". Sibling `ccp-market` uses the same `.claude-plugin/` location. Layout drift; the nested-plugin requirement (`source: "./operator"`) is preserved and validates
