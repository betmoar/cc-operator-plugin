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
| B0/T1 | VERDICTS header column set byte-matches GATES.md | `diff <(head -2 …/VERDICTS-header.md \| tail -1) <(grep -m1 '^\| Gate' inputs/evidence/GATES.md)` → `exit=0` (empty diff) | PASS |
| B1/T2 | RED demonstrated: tests fail because scripts absent | `bash tests/test-scripts.sh` → `MISSING: ops-init.sh / ops-verdict.sh / ops-stop-hook.sh`; `== summary: 3 passed, 20 failed ==`; `runner exit=1` (3 pass vacuously — empty-evidence refusal satisfied by absence) | PASS (RED) |

## Deviations

2026-07-06 | install | DEVIATION | Kickoff started on `main`; created branch `build/operator-v0.1` before any work | Plan install-step-1 mandates a dedicated branch "never main"; the human skipped it — recoverable, corrected before T0
2026-07-06 | install | DEVIATION | Plan file was saved at `docs/plan/` (singular); renamed to `docs/plans/` via `git mv` | Plan install-step-3 and the target file tree both specify `docs/plans/`; the kickoff message also references `docs/plans/BUILD-LEDGER.md` — aligned to the plan's own spelling
2026-07-06 | T0 | DEVIATION | `marketplace.json` placed at `.claude-plugin/marketplace.json`, not repo root as the plan's tree shows | Installed CLI (`claude plugin validate .`) requires `.claude-plugin/marketplace.json`; root placement fails validation with "No manifest found". Sibling `ccp-market` uses the same `.claude-plugin/` location. Layout drift; the nested-plugin requirement (`source: "./operator"`) is preserved and validates
2026-07-06 | T1 | DEVIATION | T1 done-means command `head -3 … \| tail -1` is a buggy criterion — the template is 3 lines so it selects the `\|---\|` separator, never the header; can never match. Ran corrected `head -2 \| tail -1` (header row) instead | Same unsatisfiable-against-own-fixture pattern GATES.md documents; intent (header-to-header compare) is unmistakable. Corrected diff is byte-empty
2026-07-06 | T1 | DEVIATION | VERDICTS-header Evidence column is canonical `Evidence`, not the plan's verbatim `Evidence (command output line or reviewer verdict line)` | Spec §3/§4 mandate the row schema "verbatim, byte-identical" so grep habits transfer across both ledgers; plan line 4 precedence = spec wins, log the conflict. Evidence-cell guidance survives in the charter's definitional rule (T5). This is also what makes the T1 byte-match gate pass
