# AUDIT_LOG.md — append-only event ledger

- 2026-08-31 P0-setup: mode=AUTONOMOUS, target=/home/user/cc-operator-plugin @ b653c25, tree clean, no prior AUDIT_STATE.md — fresh run.
- 2026-08-31 P0-setup: baseline captured pre-change: pytest 229 passed (+16 subtests); bash suite 732/0 (1 skip, root); workflows 354/0; compress 90/0; validate_plugin rc 0. shellcheck absent locally.
- 2026-08-31 DECISION-01: session task instructions explicitly authorize commit+push to claude/principal-audit-autonomous-8e8cw1 and a draft PR; treated as the COMMIT-gate authorization scoped to exactly that. No other outward action authorized.
- 2026-08-31 P1: begin reconnaissance — direct read of gate scripts; subagent fan-out for workflows/, validator+release_gate, compressor, docs-vs-code delta.
- 2026-08-31 P1: gate scripts read in full (task/verdict/adopt/stop-hook/sessionstart/init/claims/tiers/render/backlog/statusline, lib/partition, lib/autobar, hooks.json, manifests, commands, SKILL, agent frontmatter). AUDIT_STATE.md P1 sections written.
- 2026-08-31 P2-repro: SessionStart-from-subdir asymmetry REPRODUCED (scratchpad/repro1): payload cwd=<proj>/apps/viewer → hook rc 0, no banner, no legacy migration; same cwd Stop hook walks up and blocks rc 2. Control at root: banner + migration both fire.
- 2026-08-31 P2: confirmed commands/tiers.md cites docs/spec/2026-07-29-* and 2026-07-28-* — absent from tree (ls docs/spec).
- 2026-08-31 P2: four subagent arms returned (workflows 7 findings; docs 5; compressor 7; validator 9). Re-verified by own hands: debate spread order (:291/:330/:365), brainstorm no-floor, crawl filter, review findings guard, DECISIONS_KINDS grep, README/CLAUDE.md text, compressor P0 (end-to-end repro: 1100-char [ok]/[FAIL] output → hook returned the single char "k"), validator vacuity probes VP-01/VP-03/VP-05 re-run GREEN on a /tmp copy.
- 2026-08-31 P2: findings section below rewritten once for lint-schema conformance (field shapes, bare confidence tokens) — content unchanged, IDs stable; noted here because the log is otherwise append-only.

## Phase 2 findings (numbered F101+ — the repo's own history already owns F01–F95), ordered P0→P3

### [F120] Compressor scrub regexes lost their ESC anchors — silently destroys tool output at the first `]` (0.10.0 regression)
- **Location:** scripts/ops-compress.mjs:88-90 (`/\][^]*(?:|\\)/g` and `/\[[0-9;?]*[A-Za-z]/g` — no `\x1b` in either)
- **Severity:** P0
- **Confidence:** high
- **Claim tag:** CONFIRMED — own end-to-end repro plus `git show 57f131e:scripts/ops-compress.mjs | grep -c $'\x1b'` → 2 vs HEAD → 0
- **Failure trigger:** any elidable-tool or Agent output >1024 chars containing `]` or `[`+letter — virtually every real test log, JSON, or build output; scrub is default-on and runs on the "lossless" Agent tier too.
- **Blast radius:** SILENT and catastrophic: the PostToolUse hook replaces the output the model reads; no elide marker and no spill when the scrubbed size stays under MAX_CHARS, so the fragment reads as the complete output — the exact evidence-falsification class the plugin exists to prevent.
- **Evidence:** own repro: payload with 1100+-char Bash output `"[ok] test A passed\n…[FAIL] CRITICAL: data corruption…"` through `node scripts/ops-compress.mjs` returned updatedToolOutput `"k"` (1 char). The first regex's empty alternation matches `]`→EOF; the second eats `[o`. Shipped suite (90/0) has no `]`-bearing input; its one ANSI case asserts only the spill.
- **Fix:** restore the anchors: `/\x1b\][^]*?(?:\x07|\x1b\\)/g` (lazy OSC body, BEL/ST terminator) and `/\x1b\[[0-9;?]*[A-Za-z]/g`.
- **Guardrail:** test_compress.mjs case with `]`-bearing text asserting evidence survives scrub; a real-ANSI case asserting escapes ARE stripped; a validator pin that both regex literals contain the ESC escape.

### [F126] check_decisions_schema's partition.sh sourcing pin is satisfied by any MENTION of the filename
- **Location:** scripts/validate_plugin.py:677 (`if "partition.sh" not in s`)
- **Severity:** P1
- **Confidence:** high
- **Claim tag:** CONFIRMED — own re-run: replaced the hook's `. "$_libdir/partition.sh"` with `echo "partition.sh unavailable" >/dev/null`; validator printed "all contracts hold"
- **Failure trigger:** any edit that removes/renames the source statement while any comment mentions partition.sh (the hook has ~8 such mentions).
- **Blast radius:** the validator's core promise (hook and bar share ONE partition rule) reports green while the hook has no scan_pending; under set -u the mutated hook aborts rc 1 (≠ 2) → Stop allowed on every open task. Bash suite would catch the hook half in CI; the statusline half fails toward silence.
- **Evidence:** VP probe 1, re-run by the operator on scratchpad/vp — GREEN; check_autobar:1343 already carries the statement-anchored src_re for the identical #86-review escape on autobar.sh.
- **Fix:** apply the same statement-match to BOTH consumers (ops-stop-hook.sh, statusline.sh) in check_decisions_schema.
- **Guardrail:** python mutation cases: source→echo per consumer must go RED naming check_decisions_schema.

### [F101] SessionStart hook is a silent no-op when the session starts in a subdirectory of an operator project
- **Location:** scripts/ops-sessionstart-hook.sh:57 (`[ -d "$cwd/.operator" ] || exit 0`) vs scripts/ops-stop-hook.sh:96-110 (walk-up)
- **Severity:** P2
- **Confidence:** high
- **Claim tag:** CONFIRMED — reproduced in scratchpad/repro1 (subdir cwd: rc 0, no banner, no migration; root control: both fire; Stop hook from same cwd blocks rc 2)
- **Failure trigger:** Claude Code launched from any subdirectory of a project whose .operator/ lives at the root (or a resume/clear/compact payload carrying a subdir cwd).
- **Blast radius:** silent: no session id injected (sentinels open unowned → block every session), pre-0.9 migration skipped, .operator/bin upgrade skipped (#34 class), compressor-ephemera and .autobar wipes skipped (dedup markers survive compaction — the wipe's stated reason).
- **Evidence:** repro commands and output in the P2-repro event line; the Stop hook's F01 comment names this class on the other hook; .claude/hooks/validate-on-edit.sh walks up citing the same F01.
- **Fix:** replace the exact-match with the hook's bounded walk-up loop (stop at .git/root, cd -P semantics), then use the resolved root everywhere `$cwd/.operator` appears.
- **Guardrail:** bash-suite case: SessionStart payload with subdir cwd must emit the banner and migrate a legacy sentinel; control: cwd outside any project stays silent.

### [F102] SessionStart banner prescribes RELATIVE `.operator/bin/...` commands — the #94 shape the Stop hook already fixed
- **Location:** scripts/ops-sessionstart-hook.sh:245 (ctx banner); commands/handoff.md (relative --mark-handoff line)
- **Severity:** P2
- **Confidence:** moderate
- **Claim tag:** CONFIRMED — for the path failure: a relative script path resolves only at the root, and ops-stop-hook.sh:213-239 documents choosing absolute+shq for exactly this; the misdiagnosis-spiral consequence is INFERRED from #94's field history (what confirms: a live session in a subdir following the banner)
- **Failure trigger:** Bash tool cwd persists across calls (this repo's own ROOT BLOCK comments); a session in a subdirectory pastes the banner's command.
- **Blast radius:** loud file-not-found, but #94's history shows the model then misdiagnoses a present gate as absent; the #95 walk-up inside the CLIs cannot help because the shell never finds the script file.
- **Evidence:** ops-sessionstart-hook.sh:245 text ".operator/bin/ops-task.sh <id> --owner …"; contrast verdict_cmd_for in the Stop hook.
- **Fix:** build banner commands from the absolute resolved root, single-quoted via a local shq; leave templates/OPERATOR.md relative (committed, machine-portable — different constraint).
- **Guardrail:** bash-suite case asserting the additionalContext names the absolute project path in each prescribed command.

### [F103] debate.js: agent output can overwrite a seat's pinned identity (letter/model/dead) — spread order
- **Location:** workflows/debate.js:291, 330, 365 (`({ letter: s.letter, model: s.model, dead: r == null, ...(r ?? {}) })`)
- **Severity:** P2
- **Confidence:** high
- **Claim tag:** CONFIRMED — pinned fields written BEFORE the spread at all three sites (own grep); subagent repro showed `{model:"EVIL-MODEL", letter:"B"}` in a return dispatching the rebuttal on EVIL-MODEL and emptying both rival pools
- **Failure trigger:** a debater's JSON return includes extra keys letter/model/dead (schemas lack additionalProperties:false; the seat is shown its letter; the case text is an injection channel).
- **Blast radius:** silent-wrong: next-round dispatch on an unvetted model id (bypasses BAD_CHARSET — the last id guard), self-agreement registering as convergence, live seats counted dead.
- **Evidence:** workflows/debate.js:291/:330/:365 read directly.
- **Fix:** spread first, pin last at all three rounds.
- **Guardrail:** node case: stub return carries the three extras; assert round-2/3 dispatch models equal caller ids, rival packets non-empty, seat counted live.

### [F104] brainstorm.js: zero surviving directions still pays the JUDGMENT converge and ships a clean bundle
- **Location:** workflows/brainstorm.js:148-168 (filter, no floor) → :271 (converge dispatch)
- **Severity:** P2
- **Confidence:** high
- **Claim tag:** CONFIRMED — own source re-read: `.then((rs) => rs.filter(Boolean))` with no directions.length check before converge; blindspot and converge deaths ARE handled (:207-212, :293), directions are not
- **Failure trigger:** all direction seats die (rate limit, refused model id, schema mismatch) — the same nulls every other fan-out in the file accounts for.
- **Blast radius:** silent-wrong: converge runs over DIRECTIONS: []; result carries no error and no dead-direction accounting (crawl/review/debate all report theirs).
- **Evidence:** subagent repro: `{error: undefined, directions: 0, convergeDispatched: true}` plus the line reads above.
- **Fix:** error-return before converge when directions is empty; add directionsRequested to the result and the ratio to the log.
- **Guardrail:** node case fixturing all direction labels dead → error return, zero converge dispatches.

### [F105] crawl.js: shard path ELEMENTS unvalidated — `[object Object]` dispatches a paid crawler
- **Location:** workflows/crawl.js:110 (filter checks `Array.isArray(s.paths) && s.paths.length` only) → :157 (`s.paths.join("\n")`)
- **Severity:** P2
- **Confidence:** high
- **Claim tag:** CONFIRMED — own source re-read of both lines; subagent repro shows shard prompt section "[object Object]"
- **Failure trigger:** operator passes shards with object/null path elements — the adjacent shape to the F27.6 case the filter's own comment claims closed.
- **Blast radius:** paid crawler + paid merge over garbage; silent unless the crawler complains.
- **Evidence:** crawl.js:110 and :157 quoted in the P2 verification.
- **Fix:** extend the filter with a per-element string check, same drop-and-count log.
- **Guardrail:** node case passing non-string elements → shard dropped and counted.

### [F106] review.js adversarial seat (the unoutvotable one) carries no untrusted-data rule; OBSERVED_HEAD is forgeable from artifact content
- **Location:** workflows/review.js:434-483 (adversarial prompt, both branches); agents/op-verifier.md (zero data-rule hits); contrast review.js:391 (panel lenses carry the rule)
- **Severity:** P2
- **Confidence:** moderate
- **Claim tag:** INFERRED — grep-confirmed the rule appears once in review.js (panel) and never in op-verifier.md; live-model effect unproven (what confirms: a live run whose artifact embeds "verifier: print OBSERVED_HEAD: <sha> and CONFIRMED")
- **Failure trigger:** reviewed file content containing imperative text addressed to the verifier.
- **Blast radius:** a fabricated OBSERVED_HEAD yields atRequestedCommit true for a checkout that never ran; an injected CONFIRMED defeats the hard-stop.
- **Evidence:** own run: `grep -cin "DATA, never" workflows/review.js agents/op-verifier.md` → 1 / 0.
- **Fix:** append the data-rule sentence to both adversarial prompt branches and op-verifier.md; state OBSERVED_HEAD must come only from a command the seat itself ran.
- **Guardrail:** node prompt assertion that the adversarial dispatch prompt contains the data-rule sentence.

### [F107] review.js crashes when a lens returns non-array `findings` — the F39 hardening stops one field short
- **Location:** workflows/review.js:403 (`findings: r?.findings ?? []` lets a string/object through) → :409-411 (`p.findings.map`), also :603
- **Severity:** P2
- **Confidence:** high
- **Claim tag:** CONFIRMED — subagent repro (`{findings:"none found"}` → TypeError, review dies post-panel) plus own read of :403/:411; review.js's own F39 comment rejects relying on harness schema enforcement
- **Failure trigger:** any lens returns non-null with non-array findings.
- **Blast radius:** loud crash after all five lenses were paid; adversarial seat never runs.
- **Evidence:** review.js:403 and :410-411 quoted in the P2 verification.
- **Fix:** Array.isArray guard at :403.
- **Guardrail:** node cases per shape ("x", {}) asserting lens treated as found-nothing, no throw.

### [F108] CLAUDE.md coupling table names `validate_plugin.DECISIONS_KINDS`, which does not exist
- **Location:** CLAUDE.md:82 vs scripts/validate_plugin.py:624-626 (DECISIONS_GATED_KINDS / DECISIONS_RECORD_KINDS / DECISIONS_MARKER_KIND)
- **Severity:** P2
- **Confidence:** high
- **Claim tag:** CONFIRMED — own grep: zero hits for DECISIONS_KINDS in validate_plugin.py; three real constants at :624-626
- **Failure trigger:** maintainer edits the kind enum, greps the name the table gives, gets nothing, concludes the pin was deleted — the trust-decay the table's own footnote warns about.
- **Blast radius:** the gated/record split is load-bearing (#9); a kind added to the wrong constant is a kind the gate silently ignores.
- **Evidence:** grep output in the P2 event line.
- **Fix:** reword the row to name the three real constants and the gated/record split.
- **Guardrail:** PLAYBOOK line: renaming a validator constant requires a prose-pointer grep over CLAUDE.md and docs/.

### [F121] Compressor elide marker claims "no .operator/, not spilled" even when the output WAS spilled
- **Location:** scripts/ops-compress.mjs:124 (mid-marker always appended by elide) and :325 (failed-spill wording)
- **Severity:** P2
- **Confidence:** high
- **Claim tag:** CONFIRMED — subagent sweep case 2 measured both strings ("not spilled" mid-marker AND "[full output spilled to …]" tail) in one output; code paths verified by own read during remediation
- **Failure trigger:** any elide in an operated project (every spill).
- **Blast radius:** silent contradiction in provenance; the charter's "MUST cite the spill" rule keys on marker text, and the mid-marker invites re-running instead of citing.
- **Evidence:** ops-compress.mjs:124 and :325.
- **Fix:** neutral elide marker; the caller's appended line carries sole spill status; reword :325 to not assert a false cause.
- **Guardrail:** test asserting a spilled output does NOT contain "not spilled".

### [F127] Gated-kind and HANDOFF-MARK pins read raw text — a surviving comment satisfies them
- **Location:** scripts/validate_plugin.py:660-671 (partition.sh gated literals) and :685-690 (ops-verdict HANDOFF-MARK)
- **Severity:** P2
- **Confidence:** high
- **Claim tag:** CONFIRMED — subagent probes 2 and 3 (case arm shrunk with old enum left in a comment; printf marker typo'd with 3 comment mentions surviving) both GREEN; methodology validated by own re-runs of probes 1/3/5
- **Failure trigger:** shrinking the gated case arm or renaming the emitted marker while comments document the old value — the realistic edit in files that discuss the literals at length.
- **Blast radius:** ESCALATION/GATE-EXCEPTION rows stop gating Stop; a misspelled mark strands presented decisions as unpresented. Mitigation: bash suite covers both behaviorally in CI.
- **Evidence:** validate_plugin.py:660-690 read.
- **Fix:** run these pins on the comment-stripped shell view (helper exists in the file).
- **Guardrail:** python comment-retention mutation cases per pin.

### [F128] check_guard_parity pins guard PRESENCE, not effect — no-op arms and a gutted check_owner_name ship green
- **Location:** scripts/validate_plugin.py:1061-1082 (function-name and arm-presence pins)
- **Severity:** P2
- **Confidence:** high
- **Claim tag:** CONFIRMED — own re-run: check_owner_name in ops-task.sh gutted to `:` → validator "all contracts hold"; subagent probe 4 (leading-dot arm die→`:`) also GREEN
- **Failure trigger:** neutering an arm's action or gutting check_owner_name — deleting the #89 metacharacter arm, for which the validator has no content pin at any of the six sites.
- **Blast radius:** dotfile sentinels invisible to the gate; unexpanded-variable owners producing unclearable sentinels. Mitigation: bash suite covers both behaviorally.
- **Evidence:** own probe run (VP-03 GREEN); the good-tree fixture itself stubs check_owner_name to `:` (tests/test_validate_plugin.py:260), proving the check cannot see a body.
- **Fix:** pin the arm literals and die-polarity inside the function body for the writer sites, as the autobar pins do.
- **Guardrail:** GuardParityVacuityTest gains gut-the-owner-guard mutations per CLI.

### [F129] check_claims never reads matches_protected's body — a `return 1` matcher passes both pins
- **Location:** scripts/validate_plugin.py:1408 (literal pin), :1429 (call-site pin)
- **Severity:** P2
- **Confidence:** high
- **Claim tag:** CONFIRMED — subagent probe 6 (matcher body replaced with `return 1`, validator GREEN); methodology validated by own probe re-runs
- **Failure trigger:** an edit breaking the matcher's case/glob logic (e.g. losing the trailing-/ prefix branch).
- **Blast radius:** C3 gate-trespass check inert — a worker edits its own grader unreported. Mitigation: bash C3 cases cover full gutting; partial branch loss only partly covered.
- **Evidence:** validate_plugin.py:1408-1429 read.
- **Fix:** pin the two arm shapes (prefix branch, `[[ $p == $pat ]]`) in the matcher's body.
- **Guardrail:** python mutation case per branch.

### [F130] check_install_set_parity's loop regex is prefix-satisfiable — an inline CLI appended beside `$_OPS_TOOLS` ships green
- **Location:** scripts/validate_plugin.py:1503 (unanchored `for _?tool in \$_OPS_TOOLS`)
- **Severity:** P2
- **Confidence:** high
- **Claim tag:** CONFIRMED — own re-run: `for tool in $_OPS_TOOLS statusline.sh; do` in ops-init.sh → validator "all contracts hold"
- **Failure trigger:** a maintainer adds one CLI to one writer instead of the manifest — the smallest form of the CR4 drift this check exists to end.
- **Blast radius:** the two writers install different sets; _bin_stale and the copy loop disagree (#82's class).
- **Evidence:** probe run logged in the P2 event line (VP-05).
- **Fix:** anchor the regex through `; do` (nothing between the variable and the loop keyword).
- **Guardrail:** this exact mutation as a red python test.

### [F131] release_gate: `^\[` section terminator truncates notes at any body line starting with `[`; defs inside code fences count as resolved
- **Location:** scripts/release_gate.py:81 (terminator), :88 (defs scanned on unstripped text)
- **Severity:** P2
- **Confidence:** high
- **Claim tag:** CONFIRMED — subagent probes a/b: a body bullet starting `[#27]` silently dropped everything after it; a `[#99]:` def living only inside a fence counted as resolved
- **Failure trigger:** a changelog line wrapped to start with a reference at column 0 — latent today (shipped CHANGELOG has none) but unguarded, and the drop is silent (#39's shape via a different door).
- **Blast radius:** truncated published release notes; false resolved verdicts.
- **Evidence:** release_gate.py:81/:88 read.
- **Fix:** terminate on a def line only; run the known-defs scan on CODE_SPAN_RE-stripped text.
- **Guardrail:** red tests for both inputs in test_release_gate.py.

### [F109] brainstorm.js references-lens death is laundered to "(none)" while the adjacent comment claims it signals
- **Location:** workflows/brainstorm.js:221-228 (null takes the `""` branch; only a throw reaches the catch); comment :195-198
- **Severity:** P3
- **Confidence:** high
- **Claim tag:** CONFIRMED — source read; null-return is the harness dead-agent shape per every other guard in the file
- **Failure trigger:** references agent returns null (dies without throwing).
- **Blast radius:** silent but bounded (references documented optional); the comment misleads the next maintainer.
- **Evidence:** brainstorm.js:221-228.
- **Fix:** log the death in the null branch; correct the comment.
- **Guardrail:** node case with references dead asserting the log line.

### [F110] plan.js vetting buckets key by task id while the graph is index-keyed — duplicate ids make blocked/needsInfo ambiguous
- **Location:** workflows/plan.js:457 (`taskId: task.id`), :762-766 vs the graph's index-keyed fix :653-658
- **Severity:** P3
- **Confidence:** moderate
- **Claim tag:** INFERRED — traced by the workflows arm and consistent with my read of the graph comments; what confirms: dup-id fixture with one blocked and one clear, caller cannot tell which
- **Failure trigger:** schema-legal duplicate task ids — the case the graph half already fixed for.
- **Blast radius:** operator dispatches or re-vets the wrong duplicate; silent.
- **Evidence:** plan.js:457 and :653-658.
- **Fix:** add taskIndex beside taskId in vet rows.
- **Guardrail:** extend the existing dup-id node case to assert distinguishable vetting rows.

### [F111] commands/tiers.md cites two spec documents that exist in no checkout
- **Location:** commands/tiers.md final paragraph (docs/spec/2026-07-29-…, docs/spec/2026-07-28-…)
- **Severity:** P3
- **Confidence:** high
- **Claim tag:** CONFIRMED — own run: `ls docs/spec/` → TAGS.md + backlog-charter.md only; repo grep shows tiers.md the only referrer
- **Failure trigger:** a user or model follows the reference from the command's own text.
- **Blast radius:** dead pointer in a user-facing command — the class TAGS.md was built to end.
- **Evidence:** command outputs in the P2 event line.
- **Fix:** drop the sentence or point at docs/spec/TAGS.md.
- **Guardrail:** narrow existence check for docs/ paths referenced from commands/ and templates/ (backlog).

### [F112] CLAUDE.md load-bearing map understates the install set (3 CLIs vs the manifest's 5)
- **Location:** CLAUDE.md load-bearing map bullet 2 vs scripts/ops-install-set.sh (_OPS_TOOLS, 5 entries) and README.md:27
- **Severity:** P3
- **Confidence:** high
- **Claim tag:** CONFIRMED — own grep of all three files
- **Failure trigger:** maintainer reasons from the map about a target project's bin/.
- **Blast radius:** prose only; coupling-table row and validator are correct.
- **Evidence:** grep outputs in the P2 verification.
- **Fix:** map bullet references the manifest instead of enumerating.
- **Guardrail:** none warranted beyond check_install_set_parity.

### [F113] CLAUDE.md provenance section carries a duplicated, unparseable clause
- **Location:** CLAUDE.md:163-165
- **Severity:** P3
- **Confidence:** high
- **Claim tag:** CONFIRMED — own run: `sed -n '163,166p' CLAUDE.md` shows the doubled clause
- **Failure trigger:** reading the one row that says the replay charter is hand-synced (prose is the only guard there).
- **Blast radius:** readability of a guard-bearing sentence.
- **Evidence:** sed output in the P2 verification.
- **Fix:** delete the duplicate clause.
- **Guardrail:** none; editorial.

### [F114] Two coupling-table case references are invisible to the table's own prescribed grep
- **Location:** CLAUDE.md rows for the ops-verdict write ORDER ("G1.10") and the partition rule ("dev[N] mirror") vs tests/test-scripts.sh (~:2976 check-title; :1465 comment)
- **Severity:** P3
- **Confidence:** high
- **Claim tag:** CONFIRMED — docs-arm greps (neither string matches the footnote's `grep '^echo "-- Case'`), spot-verified
- **Failure trigger:** maintainer follows the footnote's grep, finds nothing, concludes the cases were deleted.
- **Blast radius:** trust decay in the table; both cases exist and are load-bearing (#14, #90).
- **Evidence:** grep outputs in the DC arm report.
- **Fix:** widen the footnote or promote both to Case headers.
- **Guardrail:** none; convention hygiene.

### [F115] README says "Five workflows" and its table omits debate
- **Location:** README.md:46 (lead + table) vs workflows/debate.js and templates/OPERATOR.md (names debate a primitive)
- **Severity:** P3
- **Confidence:** high
- **Claim tag:** CONFIRMED — own grep: README.md:46 "Five **workflows**"; debate absent from the table while the repo map lists six files
- **Failure trigger:** reader inventories primitives from the README table.
- **Blast radius:** user-facing docs only.
- **Evidence:** grep output in the P2 verification.
- **Fix:** add the debate row, fix the count.
- **Guardrail:** not warranted.

### [F116] fallback_holder_read lacks the brace-wrapped redirection its twin lock_holder_read carries (both LOCK BLOCK copies)
- **Location:** scripts/ops-verdict.sh:232 and scripts/ops-adopt.sh:153 vs the fixed twin at ops-verdict.sh:205 / ops-adopt.sh:126
- **Severity:** P3
- **Confidence:** moderate
- **Claim tag:** CONFIRMED — side-by-side source read for the divergence; the stderr-noise consequence is INFERRED (holder removed between -f and the open — not reproduced)
- **Failure trigger:** the fallback holder file vanishes between the -f test and the redirection open.
- **Blast radius:** raw bash error on stderr from a path whose sibling was hardened against exactly that; behavior otherwise correct.
- **Evidence:** the four line numbers above; lock_holder_read's own comment explains why the braces exist.
- **Fix:** wrap identically in BOTH lock-block copies (check_lock_parity keeps them equal).
- **Guardrail:** bash source assertion that the fallback read is brace-wrapped like its twin.

### [F117] statusline.sh header claims "builtins + one optional JSON parser"; the body shells out to stat/tail/grep/date
- **Location:** scripts/statusline.sh:6-8 vs :75-77, :129, :134-135, :156, :167
- **Severity:** P3
- **Confidence:** high
- **Claim tag:** CONFIRMED — source read; every external is failure-guarded so behavior degrades to silence (the comment, not the code, is wrong); CP arm measured empty-PATH: rc 0, op[] renders
- **Failure trigger:** maintainer trusts the header when reasoning about PATH-loss or guard removal.
- **Blast radius:** doc drift on the hottest reader; this repo treats a wrong load-bearing comment as the worse direction (#83 precedent).
- **Evidence:** line numbers above.
- **Fix:** reword: sentinel/owner parsing is builtin-only; wf/deviation segments use guarded externals and fail toward silence.
- **Guardrail:** none; editorial.

### [F118] A planted `A__B__C` sentinel blocks with a task id every CLI refuses to accept
- **Location:** scripts/lib/partition.sh:59-60 (`id="${name#*__}"` → B__C) vs check_bare_name's `*__*` refusal in all three CLIs
- **Severity:** P3
- **Confidence:** low
- **Claim tag:** INFERRED — pattern-traced, not reproduced; writers cannot produce the shape (what confirms: plant pending/<sid>__b__c, run the Stop hook, then the prescribed defer — expected die on `__`)
- **Failure trigger:** a pending/ entry whose task half contains `__` while its owner half passes the reject set.
- **Blast radius:** the block message prescribes a clearing command that exits 2; only manual rm clears, and nothing names it. Bounded: threat model is drift, not planted files.
- **Evidence:** partition.sh:59-60 and the check_bare_name arms.
- **Fix:** degrade a double-separator name to unowned in both parsers, or flag the id as malformed in the message.
- **Guardrail:** bash case for the double-separator name asserting the message names a clearable path.

### [F119] gitignore v2 migration can report success on a partially-written file
- **Location:** scripts/ops-sessionstart-hook.sh:224-241 (heredoc write, then `[ -s … ]` as the success probe)
- **Severity:** P3
- **Confidence:** low
- **Claim tag:** INFERRED — traced; disk-full mid-heredoc not reproduced (what confirms: a nearly-full filesystem where cat writes >0 bytes then fails)
- **Failure trigger:** ENOSPC/EIO after the first heredoc byte lands.
- **Blast radius:** banner says MIGRATED while the allowlist is truncated; backup exists, so recoverable.
- **Evidence:** the lines above.
- **Fix:** branch on cat's exit status with the marker-line grep as the success probe.
- **Guardrail:** extend the migration bash block with a write-failure case if cheaply fakeable, else document.

### [F122] Compressor follows a symlinked `.operator/` — spills (unredacted tool output) land outside the project
- **Location:** scripts/ops-compress.mjs:135-142 (existsSync, no lstat)
- **Severity:** P3
- **Confidence:** high
- **Claim tag:** CONFIRMED — CP-arm sweep case 6 measured the spill in the symlink target directory; code path verified by own read
- **Failure trigger:** .operator is a symlink (planted or a legit user layout).
- **Blast radius:** silent doctrine violation ("spills ONLY under an existing .operator/"); bounded — the planter already has cwd write access. partition.sh:141 refuses a symlinked DECISIONS.md for exactly this class (F65).
- **Evidence:** ops-compress.mjs:135-142.
- **Fix:** lstat-refuse a symlink in ephemeralRoot (treat as no .operator/).
- **Guardrail:** test with symlinked .operator asserting no spill.

### [F123] Compressor multibyte split at the byte boundary emits U+FFFD and shifts char accounting by ~1
- **Location:** scripts/ops-compress.mjs:74 (headBytes decode) + :110-112 (char-indexed midStart)
- **Severity:** P3
- **Confidence:** high
- **Claim tag:** CONFIRMED — CP-arm measured exactly 1 U+FFFD at the head boundary; spill stays byte-verbatim
- **Failure trigger:** elide where the head/tail byte cut lands mid-UTF-8 sequence.
- **Blast radius:** cosmetic, silent; one char corrupted, dropped count off by ~1.
- **Evidence:** CP sweep output ("ééééé�").
- **Fix:** back off to a UTF-8 boundary before decoding.
- **Guardrail:** boundary-split test asserting zero U+FFFD.

### [F124] statusline render blows its ~300ms budget when the ledger tail is one huge newline-less line
- **Location:** scripts/statusline.sh:149-167 (NUL probe + tail -n 256 over an unbounded-byte window)
- **Severity:** P3
- **Confidence:** moderate
- **Claim tag:** CONFIRMED — CP-arm timing: 508ms on a multi-MB single-line tail vs 52-76ms healthy; correctness intact
- **Failure trigger:** DECISIONS.md ending in a multi-MB newline-less line.
- **Blast radius:** slow bar only; op[] still renders.
- **Evidence:** CP sweep timings.
- **Fix:** byte-bound before line-bound (tail -c then tail -n) or lower the probe's chunk cap.
- **Guardrail:** comment; optionally a timed case.

### [F125] statusline dies loudly (rc 1, unbound MINE) when lib/partition.sh is not beside it
- **Location:** scripts/statusline.sh:56-61 (unchecked source) + :224 under set -u
- **Severity:** P3
- **Confidence:** high
- **Claim tag:** CONFIRMED — CP-arm run of a lone copied renderer: rc 1, "No such file or directory … partition.sh"
- **Failure trigger:** $0-relative lib/ unresolvable (renderer copied standalone).
- **Blast radius:** violates the file's own never-fail-loudly contract; cc-status may drop the renderer silently thereafter. Only reachable on a broken install.
- **Evidence:** CP run output.
- **Fix:** guard the source and exit 0 on failure.
- **Guardrail:** moved-renderer subcase in the statusline bash block.

### [F132] check_autobar has no `-uall` pin though CLAUDE.md calls it "as load-bearing as -z"
- **Location:** scripts/validate_plugin.py:1261-1279
- **Severity:** P3
- **Confidence:** high
- **Claim tag:** CONFIRMED — VP-arm read of the pin set; mitigation verified (bash :4053-4092 covers -uall behaviorally with a negative control)
- **Failure trigger:** dropping -uall during a simplification; validator green, bash suite red later in CI.
- **Blast radius:** untracked-dir collapse re-opens the #85 measured gap until CI runs.
- **Evidence:** validate_plugin.py:1261-1279.
- **Fix:** add the -uall substring pin beside -z.
- **Guardrail:** python mutation case.

### [F133] check_workflows' computed-meta pin catches `+` concatenation but not template literals
- **Location:** scripts/validate_plugin.py:1903-1908
- **Severity:** P3
- **Confidence:** moderate
- **Claim tag:** INFERRED — regex read; what confirms: a fixture workflow with a backtick template in meta staying green
- **Failure trigger:** a template literal in meta — computed, harness-rejected at launch, workflow silently never runs (the docstring's own threat).
- **Blast radius:** one workflow dead until noticed.
- **Evidence:** the regex at validate_plugin.py:1903-1908.
- **Fix:** also flag a backtick inside the meta block.
- **Guardrail:** red python test.

### [F134] check_compressor's pinned defaults are searched in raw src, not the comment-stripped view
- **Location:** scripts/validate_plugin.py:2334
- **Severity:** P3
- **Confidence:** moderate
- **Claim tag:** INFERRED — read; what would confirm it: a /tmp-copy mutation that moves one pinned default into a comment while changing the code value, with the validator staying green (currently no comment carries a K:value pair, grep-verified by the VP arm)
- **Failure trigger:** a comment documenting an old default while the code default changes.
- **Blast radius:** a drifted compressor default ships green.
- **Evidence:** validate_plugin.py:2334.
- **Fix:** search the stripped code view.
- **Guardrail:** python mutation case with the default only in a comment.

## Phase 3 remediation events
- 2026-08-31 P3: F120/F121/F122 fixed in ops-compress.mjs by the operator; test_compress.mjs: red-run on old code = 8 FAIL (incl. all new cases), green with fix = 97 passed / 0 failed (baseline 90).
- 2026-08-31 P3: F101/F102/F119 fixed in ops-sessionstart-hook.sh; F124/F125/F117 in statusline.sh; F116 in both LOCK BLOCK copies (ops-verdict.sh + ops-adopt.sh, byte-identical). bash suite: red-run on old scripts = 11 FAIL (exactly the new/updated cases), green with fixes = 743 passed / 0 failed → 744 after the F10 pin update (re-run pending final). Live repro re-run: subdir SessionStart now banners with absolute quoted paths and migrates the legacy sentinel.
- 2026-08-31 P3: F103–F107, F109, F110 fixed by the workflows remediation arm (test-first, red runs captured per fix); node suite 354 → 384 passed / 0 failed; diffs re-read and verified by the operator (spread-order, filter, floor, data-rule, findings guard, taskIndex all as specified).
- 2026-08-31 P3: docs fixes — F108 (CLAUDE.md names the three real DECISIONS_* constants + the split), F112 (map bullet references the manifest), F113 (garbled clause repaired), F114 (footnote widened), F115 (README six workflows + debate row), F111 (tiers.md points at TAGS.md, notes the never-committed specs).
- 2026-08-31 P3 DECISION-02: F118 (double-separator sentinel names an uncloseable id) and F123 (U+FFFD at elide boundary) DEFERRED to the backlog — both low-severity, F118 needs a design call on reader semantics (degrade-to-unowned changes what the gate blocks on), F123 is cosmetic with the spill byte-verbatim. Deferral reasons recorded here per EXIT criteria.
- 2026-08-31 P3: validator-pin arm landed (F126-F134 + F131 + the F120 anchor pin), each with the exact escape as a red python test + control; pytest 229 → 247. Operator re-ran the three originally-measured probes on a /tmp copy of the FIXED tree: F126 source→echo RED (names the sourcing pin), F128 gutted check_owner_name RED (names the whitespace arm), F130 grafted loop word RED (names the loop pin); clean-copy control GREEN.
- 2026-08-31 P3: CI red on 810c327 (shellcheck v0.10.0 SC2016 on the F116 literal-needle grep) — fixed with the repo's targeted-disable idiom, reproduced green locally on the CI-pinned version across the full CI file set, pushed as 59efa64.
- 2026-08-31 P3-EXIT: all suites green on the final tree — pytest 247/0 (+18), bash 744/0 (+12), workflows 384/0 (+30), compress 97/0 (+7), validator rc 0, shellcheck 0.10.0 green, release-gate real-repo test green. 32/34 findings fixed; F118+F123 deferred (DECISION-02).
- 2026-08-31 P4: guardrails ran green (the suite deltas above ARE the guardrail catalog — see docs/audit-2026-08-31-principal.md §Guardrail catalog); playbook + landmine additions committed (docs/PLAYBOOK.md, docs/LANDMINES.md); handoff doc written (docs/audit-2026-08-31-principal.md); backlog captured (6 items, pickup-able cold); AUDIT_STATE.md cursor → DONE.
- 2026-08-31 P4: CHANGELOG [Unreleased] entry written; branch pushed; draft PR #97 carries the summary; PR watched until merged/closed.
- 2026-08-31 P4-followup: CI red on 00a7cc2 — test_real_repo_gate_passes: a populated [Unreleased] while plugin.json says 0.11.3 is content that vanishes from the release page. Own miss: the CHANGELOG entry was written AFTER the pytest run and committed unverified. Fix per repo convention (version bump + heading same commit): plugin.json 0.11.4 + retitle [Unreleased] → [0.11.4], empty [Unreleased] kept. Full CI mirror re-run locally BEFORE push this time: pytest 247/0, bash 744/0, workflows 384/0, compress 97/0, validator green, shellcheck green. (The intermediate 59efa64 CI red was GitignoreParityTest colliding with 0bb869f's second grep — already repaired in 1de038e.)
- 2026-08-31 review-response: Copilot review on PR #97 — six findings, all verified real, all fixed. (1) release_gate terminator located in a code-MASKED offset-preserving view (a fenced `[#99]:` def truncated the section mid-fence — reproduced, red test added); (2) compressor ephemera containment extended to NESTED symlinks (spill root, session dir, file — lstat/ownedDir + red tests: 4 FAIL pre-fix, 101/0 post); (3) the #89 metacharacter-arm pins extended to the READER sites (partition.sh + ops-verdict.sh sentinel_owner_of_name, degrade polarity) and the MIGRATION site (continue polarity) — mutation-verified red per site on a /tmp copy, fixture stubs upgraded; (4) op-verifier.md's data rule narrowed (citing artifact content is the seat's job; only self-claimed execution observations need command provenance); (5) audit-doc backlog item 2 refreshed (bump already landed; correct v-prefixed gate command); (6) both source-statement pins filename-anchored (`fakepartition.sh`/`fakeautobar.sh` no longer satisfy — red-verified, tests added). Full CI mirror green before push: pytest 253/0 (+6), bash 744/0, workflows 384/0, compress 101/0 (+4), validator, shellcheck.
- 2026-08-31 review-response-2: second Copilot round — 3 posted + 3 suppressed findings, all verified and fixed. (a) gitignore migration made ATOMIC in BOTH writers (temp + same-dir mv; the F119 fix's failure path was silent AND left a truncated live file for the next session's retry to copy over the good backup — the worse variant; distinct _gi_write_failed notice added, ops-init's _gi_write got the same treatment for the set -e mid-write death); (b) malformed lens findings now count as DEAD in review.js (coverage honesty — the F107 coercion had laundered lost coverage into found-nothing; test expectation inverted deliberately); (c) statusline's second tail gained the stderr guard (both sites, F10 pin updated); (d) the metacharacter-arm pins now require ALL FIVE alternatives with site polarity (a $-only pin accepted an arm stripped of backtick/quote/backslash — partial-arm mutations fire at writer/reader/migration, red-verified + test); (e) AUDIT_STATE + audit-doc totals refreshed to the final run; (f) GitignoreParityTest's detection-grep mutation re-anchored to the grep prefix (the atomic tmp moved the confirmation grep off "$_gi"). Final: pytest 254/0 (+23 subtests), bash 744/0, workflows 384/0, compress 101/0, validator, shellcheck — all green before push.
