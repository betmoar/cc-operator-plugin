# Principal-architect audit, run 2 — 2026-09-02 (autonomous)

Audited: the 0.11.4/0.11.5 remediation itself — the delta `b653c25..0a267a4`
(PR #97, the 2026-08-31 audit's fixes; PR #104, the 0.11.5 backlog items) —
plus the two P1 issues that delta left open (#98, #103). Run 1's cursor read
DONE, so per the audit skill the target became the most valuable un-audited
surface: the remediation. Method: full direct read of every changed gate-layer
file; live reproduction of each candidate on a scratch project; mutation
probes on scratch copies for every pin claim; a pin-auditor arm over the ten
new validator pin groups. The finding ledger, in the admissible evidence
schema, is `AUDIT_LOG.md` ("Run 2", F135–F139). Every fix landed with a test
run RED against the pre-fix code; the red-run outputs are in the ledger.

## Verdict

Healthy. The remediation held under adversarial re-read: the compressor's
UTF-8 back-off, the atomic gitignore writes, the walk-up parity, the workflow
hardening and the repaired pins are all correct as shipped. What it missed is
narrow and in one family: the MALFORMED bucket (#99) fixed the double-`__`
name and walked past the EMPTY-id name beside it, and the CLIs still parsed
a sentinel name with a different rule than the hook. Both are planted-name
cases, bounded to shapes no writer produces — but one of them opened the gate
silently while the bar said blocked, which is the exact disagreement the
shared partition lib exists to prevent.

## Findings by severity (all fixed)

| ID | Sev | One line |
|----|-----|----------|
| F135 | P2 | an empty task id (`sid__`, `__`) was counted as MINE but never NAMED — hook rc 0, bar `op[N]` red; pre-existing, F118's class |
| F136 | P3 | the CLIs resolved `A__B__C` as task `C` (glob `*__C`) while the hook called it MALFORMED — "already open" for a task never opened; adopt laundered it |
| F137 | P3 | ops-init's atomic gitignore write was unpinned — the non-atomic revert shipped validator-green |
| F138 | P3 | the maintainer's shellcheck hook could not lint itself (line 2 parsed as a directive) |
| F139 | P3 | REPLAY-CHARTER R2b quoted the pre-#94 relative Stop message as the expected shape |
| F140 | P2 | check_claims' F129 pins were substring tests — `matches_protected` gutted by an early `return 1` shipped validator-green (the pin's own named escape); now EXECUTED |
| F141 | P2 | a computed workflow `meta` via a call expression passed the validator and every suite; the harness refuses it at launch — structural literal pin |
| F142 | P3 | a legal source line with a trailing comment failed the build as "does not SOURCE" — both source pins tolerate it |
| F143 | P3 | a redefined `sentinel_owner_of_name` in lib/partition.sh was reported by nobody; the `pass` beside it claimed otherwise |

F140–F143 came from the pin-auditor arm over the ten validator pin groups
added in 0.11.4/0.11.5 (nine fire on their named escape); every mutation it
reported was re-run by hand on a fresh copy before entering the ledger.

Sweep coverage, so the successor knows where NOT to spend: partition.sh,
ops-stop-hook.sh, ops-sessionstart-hook.sh (walk-up + gitignore migration),
ops-compress.mjs (headBytes/tailBytes/scrub/spill containment),
release_gate.py, all six workflows' deltas, commands/handoff.md, the 356-line
validator delta, both local dev hooks — each read in full and found correct
except as listed. `Bash(bash:*)` in commands/handoff.md is an accepted
over-grant (PR #104's reasoning stands: no narrower grant covers an absolute
path); not a finding.

## Guardrail catalog (what now locks each class in)

| Invariant | Enforcement | Artifact |
|---|---|---|
| every sentinel the hook counts is either NAMED or MALFORMED — never counted-and-silent | bash cases (hook rc 2, `rm -f` per path, bar `op[N]` agrees, control task still named) | tests/test-scripts.sh "F135" block |
| the CLIs resolve a name with the readers' first-`__` rule (task-half filter at all four glob sites) | validator pin per site + bash cases | validate_plugin.check_guard_parity (F136 block); GuardParityVacuityTest.test_dropping_the_task_half_filter_from_any_lookup_fires (4 subtests); tests/test-scripts.sh "F136" block |
| BOTH gitignore writers swap a complete temp onto the live path | validator pin per writer | validate_plugin.check_gitignore_parity (F137 pin); GitignoreParityTest.test_a_non_atomic_INIT_write_fires |
| ops-reverify's row parser follows the 4-cell schema and every stamp form | bash case with fixed-date commits | tests/test-scripts.sh "ops-reverify.sh dates rows" case (18 checks) |
| the local shellcheck hook lints itself | fix only (0.10.0 run shown in the ledger) | .claude/hooks/shellcheck-edited.sh |
| `matches_protected` MATCHES every protected token and no unprotected path — as behaviour, executed | validator runs the shipped function in a child bash | validate_plugin.check_claims (F140); ClaimsGuardTest early-return + match-everything cases |
| a workflow `meta` holds only literal values | structural pin after string-stripping | validate_plugin.check_workflows (F141); ValidatorTest call-expression / identifier / nested-literal cases |
| a legal source statement is never reported absent | both source regexes tolerate a trailing comment; the echo/fake escapes still fire | ValidatorTest.test_partition_source_line_with_a_trailing_comment_is_not_a_miss |
| a redefined reader parser in the lib is reported | `_report_if_redefined` at the reader site | GuardParityVacuityTest.test_a_redefined_reader_parser_in_the_lib_is_reported |

## Tool-level leverage

- `scripts/ops-reverify.sh` — closes issue #103's "done when": a maintainer
  runs it from a project root and gets every VERDICTS.md row placed inside or
  outside the F120 window by its stamp's HEAD interval, with undatable rows
  listed as such (never as clear), the re-verification steps in the footer,
  and exit 1 while anything remains. It never writes; the single writer stays
  `ops-verdict.sh`. Not in the install set (a maintainer tool, like
  `ops-backlog.sh`); the CLAUDE.md table couples it to the row printf.

## Residual risks (known, not fixed)

| Risk | Sev | Why not fixed | Mitigation |
|---|---|---|---|
| #98 — the live REPLAY-CHARTER re-proof has not run against 0.11.4+ | P1 | needs a live Claude Code harness; this container has none (DECISION-04). The bash suite's fixture-driven hook runs are the nearest proxy and are green, and F139 removed the one stale expectation that would have failed a correct run | run it; R0's `cmp` first |
| #103 — rows written under the F120 window are still unverified in the field | P1 (historic) | cannot be done from the plugin repo; the procedure and tool now exist | `ops-reverify.sh` per project |
| the F120 window defaults are the PLUGIN's tag dates, outer bounds only | P3 | a project's real window is when ITS plugin install moved; unknowable here | `--from/--to`; the doc says so |
| `Bash(bash:*)` grants any shell command inside /cc-operator:handoff | accepted | no narrower grant matches an absolute path | documented in the command and CLAUDE.md |
| ops-reverify's HEAD interval assumes the row was written while `<sha>` was HEAD on the CURRENT branch's ancestry | P3 | a sha reachable only from another branch reads "unknown (not an ancestor)" → AFFECTED (fails toward re-verify) | by design |
| six "literal present, behaviour gone" sibling vacuities the pin-auditor measured — S2 HANDOFF-MARK typo with the success echo rewritten as printf; S3 a dead `?*) :` arm before the intact `.*) die`; 5c' `-uall` kept only in a same-line comment; S5b a decoy `for _tool in $_OPS_TOOLS; do :; done` beside a literal-list loop; S6 the detection grep retargeted to `.v1.bak`; S7 the CSI regex's anchored copy in `if (false)` | P3 each | every one is caught by another suite (bash 2–7 red, compress 3 red) — a validator-MESSAGE gap, not an open hole; repairing all six with grep pins would be the enumeration F140/F141 argue against | the suites; the LANDMINES lesson (execute, don't grep) for whoever repairs them — the executable shape is the fix for each |

## Prioritized backlog (pickup-able cold)

1. **Run the REPLAY-CHARTER (#98) against 0.11.6** — context: doctrine
   requires it after gate changes this large; F139 fixed its stale R2b line.
   First step: `docs/REPLAY-CHARTER.md` R0 in a scratch project, `cmp` every
   `.operator/bin/` CLI first. Done-when: every phase recorded as a verdict
   row through the gate it audits.
2. **Publish 0.11.6** — context: version + heading landed here (release-gate
   rule). First step: after merge, `python3 scripts/release_gate.py v0.11.6`
   on main, then tag `v0.11.6`. Done-when: both forges' release workflows
   green.
3. **Run `ops-reverify.sh` in each operated project (#103)** — context: the
   plugin cannot do this; the tool lists the rows. First step: from the
   project root, `bash <plugin>/scripts/ops-reverify.sh`. Done-when: every
   AFFECTED/UNDATABLE row has a `re-verify(#103):` row beside it or a
   DECISION line; then close #103.
4. ~~**Fold the empty-id and task-half shapes into `docs/spec/TAGS.md`'s
   `spec-concurrent` entry**~~ DONE by the maintainer in e8e0179 (F144). — context: the entry describes the name
   convention; two reader rules now depend on it. Done-when: the entry names
   the first-`__` split as THE rule and the four glob sites as its consumers.
5. ~~**Convert the six sibling vacuities to executable pins**~~ DONE by the
   maintainer in e8e0179: all six execute the shipped code (unittest 270 → 280,
   bash 820 → 830, each escape run red first). The residual-risk row above is
   closed by that commit. — context: the
   residual-risk row above lists them with their measured mutations; each is
   "the literal is present, the behaviour is gone". First step: the F140
   shape (`bash -c` the shipped function against probes) for check_owner_name
   / check_bare_name / autobar_count_changed; a `node -e` import for the
   compressor's scrub. Done-when: each listed mutation goes RED in the
   validator with the right check named, and the shipped tree stays green.

## Provenance

- Auditing session: autonomous principal-architect audit, run 2, 2026-09-02,
  branch `claude/principal-audit-autonomous-ghqjno`.
- Working ledgers: `AUDIT_LOG.md` (append-only; Run 2 events + F135–F139
  with evidence), `AUDIT_STATE.md` (cursor; final state).
- Suite deltas, baseline → end: unittest 260 → 269 OK; bash 783 → 820 (0
  failing throughout); workflows 384 → 384; compress 161 → 161; validator,
  release gate and shellcheck 0.10.0 (CI-pinned) green on the final tree.
