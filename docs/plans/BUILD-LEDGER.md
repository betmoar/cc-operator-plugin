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
| B1/T3 | all script tests GREEN; jq path + python3 fallback + fail-open all proven | `bash tests/test-scripts.sh` → `== summary: 23 passed, 0 failed ==`; `runner exit=0` (Case 5 = jq-absent python3 fallback exit 2/0 + no-parser fail-open exit 0 + warning) | PASS |
| B1/T3 | scripts syntactically clean | `bash -n` ok on all 3 + runner; `shellcheck …` → `shellcheck-exit=0` (zero findings) | PASS |
| B1/T4 | hooks.json parses; plugin validate clean | `jq . operator/hooks/hooks.json` → `PARSE OK exit=0`; `claude plugin validate ./operator --strict` → `✔ Validation passed` | PASS |
| B2/T5 | charter ≤150 lines | `wc -l operator/templates/OPERATOR.md` → `132` | PASS |
| B2/T5 | every rule line carries a citation tag | `grep -oE '\[D:…\|\[DOC:…' \| wc -l` → `43` tags across 20 distinct refs; forbidden-content grep clean (only hit is BAR-block `budget (time/cost/iteration)`, spec §4, not O7 telemetry) | PASS |
| B2/T5 | section order fixed | `grep -n '^## '` → ROLE→SOLO→ORCHESTRATED→ENGAGEMENT CONTRACT→EVIDENCE GATE→HANDOFF→RECOVERY→PRECEDENCE | PASS |
| B2/T5 | 5 tags resolve to evidence/spec | CHART-def→CHARTER:165; roadmap-s1→roadmap:32; CHART-recover→CHARTER:207/218; GATES-g4→GATES:55/65; spec-D4→spec:144/125 | PASS |

## Deviations

2026-07-06 | install | DEVIATION | Kickoff started on `main`; created branch `build/operator-v0.1` before any work | Plan install-step-1 mandates a dedicated branch "never main"; the human skipped it — recoverable, corrected before T0
2026-07-06 | install | DEVIATION | Plan file was saved at `docs/plan/` (singular); renamed to `docs/plans/` via `git mv` | Plan install-step-3 and the target file tree both specify `docs/plans/`; the kickoff message also references `docs/plans/BUILD-LEDGER.md` — aligned to the plan's own spelling
2026-07-06 | T0 | DEVIATION | `marketplace.json` placed at `.claude-plugin/marketplace.json`, not repo root as the plan's tree shows | Installed CLI (`claude plugin validate .`) requires `.claude-plugin/marketplace.json`; root placement fails validation with "No manifest found". Sibling `ccp-market` uses the same `.claude-plugin/` location. Layout drift; the nested-plugin requirement (`source: "./operator"`) is preserved and validates
2026-07-06 | T1 | DEVIATION | T1 done-means command `head -3 … \| tail -1` is a buggy criterion — the template is 3 lines so it selects the `\|---\|` separator, never the header; can never match. Ran corrected `head -2 \| tail -1` (header row) instead | Same unsatisfiable-against-own-fixture pattern GATES.md documents; intent (header-to-header compare) is unmistakable. Corrected diff is byte-empty
2026-07-06 | T1 | DEVIATION | VERDICTS-header Evidence column is canonical `Evidence`, not the plan's verbatim `Evidence (command output line or reviewer verdict line)` | Spec §3/§4 mandate the row schema "verbatim, byte-identical" so grep habits transfer across both ledgers; plan line 4 precedence = spec wins, log the conflict. Evidence-cell guidance survives in the charter's definitional rule (T5). This is also what makes the T1 byte-match gate pass
2026-07-06 | T3 | DEVIATION | Stop hook enumerates `.operator/pending/*` via a bash nullglob, not the plan's literal `find .operator/pending -mindepth 1`; stdin slurped via `read -r -d ''`, not `cat` | A Stop hook fires on every session end; if `find`/`cat` are missing from a stripped PATH the hook would brick the session. Spec U2/D1.5 require fail-open. Restricting external deps to one JSON parser (jq→python3) with builtins for everything else is what makes Case-5 fail-open provable. Same sentinel semantics, safer implementation
2026-07-06 | T3 | DECISION | T2 runner had 2 masking bugs found during GREEN: `grep -c … \|\| echo 0` double-printed `0` (false-fail), and `env -i PATH=<pydir> bash` couldn't find bash itself (false-fail on case 5). Fixed runner to launch bash by absolute path + resolve python3 real binary via sys.executable | The genuine script bug (stdin line-loop dropped the newline-less final line → hook saw empty cwd → always exit 0) was hidden by exit-0-expecting cases passing anyway; fixing the runner surfaced it. Real bug fixed in ops-stop-hook.sh
2026-07-06 | T4 | DEVIATION | hooks.json command is `bash "${CLAUDE_PLUGIN_ROOT}/scripts/ops-stop-hook.sh"`, not the plan's bare `${CLAUDE_PLUGIN_ROOT}/scripts/ops-stop-hook.sh` | `${CLAUDE_PLUGIN_ROOT}` confirmed honored — 7 sibling plugins use it; cc-repete (also a Stop-hook plugin) uses the identical `bash "..."` form. Explicit `bash` invocation is exec-bit-independent and matches the proven sibling. Requirement (plugin-relative hook path) preserved
