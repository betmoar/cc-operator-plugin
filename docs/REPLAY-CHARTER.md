# REPLAY CHARTER — live-session audit of the implementation-verification chain

An executable protocol, not prose. Run it inside a **live Claude Code session**
with the plugin installed, against a scratch project. Its purpose is the seam
the bash suite cannot reach: the suite proves the *scripts* answer correctly;
this charter proves the *harness* honors those answers — the rows in
`docs/PLAYBOOK.md` § "What a green suite does NOT prove", exercised end to end.
PR #12's live G2 proof (2026-08-08) is the precedent; this charter is that
method made repeatable.

Three rules bind the whole run, all inherited from the operator charter:

1. **The replay uses the gate it audits.** Every phase's result is recorded as
   a verdict row via `ops-task.sh`/`ops-verdict.sh` — dogfooding is the point.
   A phase without its expected output recorded is FAIL by definition.
2. **Record over summary.** The evidence cell cites the actual command output,
   never a paraphrase. Meter check per phase: state in one line what would make
   the observation invalid, and check that.
3. **Cap: one retry per failing phase**, then record FAIL with the observed
   output and continue. A wedged replay proves less than a completed one with
   an honest FAIL row.

**What this replay does NOT prove**, stated before the first command: it is
session-local. It cannot show clean-environment verification (#23), security
coverage (#24), or external attestation (#25). A green replay means the chain
works *for the session that ran it* — that is the claim, and the whole claim.

---

## R0 — Preconditions and identity

Scratch project, real git repo (the stamp needs one — S1 cases):

```
mkdir /tmp/replay && cd /tmp/replay && git init .
git config user.email replay@test && git config user.name replay
printf '#!/bin/sh\necho 5\n' > calc.sh && chmod +x calc.sh
printf '#!/bin/sh\n[ "$(./calc.sh)" = 5 ] && echo OK || { echo BROKEN; exit 1; }\n' > check.sh
chmod +x check.sh && git add -A && git commit -m init
```

Run `/cc-operator:start`. **Expected:** `.operator/` scaffolded and `OPERATOR.md`
materialized.

**The id does NOT arrive here, and the ordering is the point.**
`ops-sessionstart-hook.sh:95` exits silently when `.operator/` is absent, and the
banner that carries the id is written at the very end of that hook — so the
SessionStart that fired *before* the scaffold existed said nothing, and running
the slash command does not re-fire it. In a genuinely fresh project the id
therefore appears only on the **next** SessionStart (`startup|resume|clear|compact`).

So either scaffold first and start a new session before asserting identity, or —
the practical route, and the one this replay took — run it in a project that
already has `.operator/`, where the current session's own banner supplied the id.
Do not read "no id yet" in a fresh scratch project as a failure; that is the
documented gate, not a bug.

The load-bearing check stands, only its timing moves: once a session *has* been
told its id, `CLAUDE_SESSION_ID` is still NOT in the Bash tool env, so the hook
is the only supplier. If a session that should know its id does not, every
sentinel it opens is unowned and blocks every session — stop the replay there,
this is a live-harness FAIL the suite can never see. Call the id `<sid>` below;
verify it by opening the tracking task below and confirming the sentinel reports
`owned by <sid>` rather than opening unowned.

**Build identity — do this before any other phase.** Establish *which* code the
run is about to test, because there are two answers and they can differ:

```
for f in ops-verdict.sh ops-task.sh ops-adopt.sh ops-claims.sh ops-backlog.sh; do
  cmp -s ".operator/bin/$f" "${CLAUDE_PLUGIN_ROOT}/scripts/$f" \
    && echo "$f CURRENT" || echo "$f STALE"
done
```

Anything `STALE` invalidates every later phase that runs through
`.operator/bin/…` — those phases then test the installed copy, not the tree you
think you are auditing. This is not hypothetical: the 2026-08-12 run found
`ops-verdict.sh` two commits behind (issue #34, fixed in `13ea694`), so R2–R6
had validated a predecessor. Hooks are a **separate** staleness domain: they
resolve through `${CLAUDE_PLUGIN_ROOT}/scripts/…` and are current immediately,
so hooks and `bin/` can legitimately sit at different commits in one session.

If anything is stale, fire the SessionStart hook once and re-check before
continuing; if it is still stale, that is a P0 finding and the replay stops
until it is fixed. Record the resolved identity — the commit `bin/` matches — in
R0's verdict row, so every later row is readable against a known build.

Open the replay's own tracking task:
`.operator/bin/ops-task.sh replay-run --owner <sid>`

## R1 — Scaffold contracts (incl. F67)

- `ls .operator` → `VERDICTS.md DECISIONS.md pending verdicts.d bin
  .gitattributes .gitignore tiers.env` (order aside).
- `.operator/.gitignore` first non-comment line is `*` (v2 allowlist; the bare
  `*` is the load-bearing half — check_gitignore_parity's lesson).
- **F67 probe:** `printf '/.operator/\n' >> .gitignore`, then re-run the
  scaffold. `ops-init.sh` is **not** in the `.operator/bin/` install set — that
  set is `ops-verdict.sh ops-task.sh ops-adopt.sh ops-claims.sh ops-backlog.sh`
  (`ops-init.sh:194`), because init is what *creates* `bin/` and would have to
  install itself. So run it the way the harness does, from the plugin root:
  `bash "${CLAUDE_PLUGIN_ROOT}/scripts/ops-init.sh"`, or re-issue
  `/cc-operator:start`. Expected on stderr, naming file and line:
  `ops-init: WARNING — the evidence ledger is gitignored by a rule outside
  .operator/.gitignore:`. Then remove the line and re-run: warning absent.

Record: `ops-verdict.sh R1 "scaffold + F67 warning" "<paste stderr line>" PASS
--owner <sid>` — and note the row itself must end `@<sha>` (R4 checks this
deliberately; seeing it here early is the stamp working).

## R2 — Stop gate, live (the harness-interpretation seam)

With `replay-run` open, **attempt to end the session** (finish the turn).
Expected: the Stop is blocked and the model receives, verbatim shape:

```
operator: pending verdict(s): replay-run — run .operator/bin/ops-verdict.sh
<id> <criterion> <evidence> <PASS|FAIL>, or --defer "<reason>"
```

This is the one check the entire bash suite asserts only at exit-code level —
the live block is what the plugin exists to do. If cc-status renders the
statusline, its segment must show this session's pending count (a mirror of the
mine/foreign partition, not a count of `pending/`).

Foreign-sentinel half: `ops-task.sh foreign-probe --owner OTHER-SESSION`, then
attempt Stop again. Expected stderr names the task, its owner and its open time —
`operator: 1 pending verdict(s) owned by another session (foreign-probe owned by
OTHER-SESSION, opened <ISO-8601>) — not blocking.` — reported, and the blocking
line for your own task still follows it. Close it: `ops-verdict.sh foreign-probe
--defer "replay probe" --owner OTHER-SESSION`.

Both halves can also be driven directly, which is how you get the exact bytes to
cite: `printf '{"session_id":"<sid>","cwd":"'"$PWD"'"}' | bash
"${CLAUDE_PLUGIN_ROOT}/scripts/ops-stop-hook.sh"; echo "rc=$?"`. That proves the
*script's* answer; the live block above is what proves the harness honors it.
Both are required — the charter's claim is about the pair.

## R3 — Arm gate, live (G2/G3; the four controls from PR #12)

Enable: `touch .operator/armgate.on`. Then, same file and same tool each time:

**Use a PROBE SESSION ID, not `<sid>`.** The earlier revision of this table told
you to unarm your own session, which R0 has already armed by opening
`replay-run` — `.armed/<sid>` exists, so control (a) would be *allowed* and the
table's own parenthetical wandered through three contradictory workarounds
trying to escape that. There is nothing to escape: the arm gate keys on the
session id in the hook payload, so a probe id that owns no task is unarmed by
construction, and your real session keeps its tracking task throughout. Call it
`<psid>` (any string, e.g. `ARM-PROBE-SID`).

The gate is a PreToolUse hook, so drive it by feeding it a payload rather than
by making real edits — that also lets `<psid>` differ from the session you are
actually running in:

```
printf '{"session_id":"<psid>","cwd":"'"$PWD"'","tool_name":"Write",
"tool_input":{"file_path":"'"$PWD"'/probe.txt"}}' \
  | bash "${CLAUDE_PLUGIN_ROOT}/scripts/ops-armgate-hook.sh"; echo "rc=$?"
```

| Control | Setup | Expected |
|---|---|---|
| a | gate on, `<psid>` owns no task | **denied**, rc 2; stderr carries all three repair commands verbatim |
| b | `ops-task.sh arm-probe --owner <psid>` | same payload **allowed**, rc 0 |
| c | `rm .operator/.armed/<psid>` (simulate desync) | denied again, rc 2 — stale-FALSE fails closed |
| d | `ops-adopt.sh --owner <psid> arm-probe` | allowed — the deny message's own repair works |

Clean up after: `ops-verdict.sh arm-probe --defer "replay R3 control probe"
--owner <psid>` and `rm -f .operator/.armed/<psid>`.

Every deny is confirmed by **reading the file back** — `probe.txt` must not
exist after (a) and (c). rc 2 with the file present would mean the hook denied
after the write, which is a different and worse bug.

With `<psid>` doing the probing there is no ordering constraint against R2: your
own session keeps `replay-run` open the whole time. Still exercise **G3**, on a
third id so the grant is isolated: `ops-task.sh --exempt "replay R3" --owner
<esid>`, expecting `exemption granted for session <esid> (GATE-EXCEPTION written
… Stop is now blocked until you present it …)`, then confirm the same payload
now passes for `<esid>` and that a `GATE-EXCEPTION` carrying `[sid:<esid>]`
landed in DECISIONS.md. Present and clear it with `ops-verdict.sh
--mark-handoff --owner <esid>`. Disable the gate after: `rm
.operator/armgate.on`, and remove `.armed/<esid>.exempt`.

Record R2+R3 as verdict rows citing the observed stderr.

## R4 — Evidence lifecycle and the stamp (U10)

1. `./check.sh` → `OK`. `ops-verdict.sh R4-pass "./check.sh prints OK"
   "./check.sh -> OK" PASS --owner <sid>` (open `R4-pass` first). Expected: the
   ledger row ends `@<12-hex-sha> | PASS |` and the fragment row is
   byte-identical.
2. `printf 'x\n' > dirty.txt`, open+record `R4-dirty`. Expected stamp:
   `@<same-sha>+dirty`.
3. **The honesty probe** — break the criterion (`echo 6` in calc.sh), do NOT
   re-verify, attempt Stop with no task open. Expected: **Stop is silent
   (rc 0) and the R4-pass row still reads PASS.** This is #22's still-open
   half. Record it as PASS-of-the-probe (current behavior confirmed), with the
   evidence cell saying exactly that — a replayer who records this as a
   framework failure has misread the stamp's contract: provenance, never
   attestation. Restore calc.sh.

## R5 — Retro-gate (G1) and the deviation gate

`ops-verdict.sh never-armed-probe "retro" "no sentinel existed" PASS --owner
<sid>` (no ops-task first). Expected: `recorded … (never-armed —
GATE-EXCEPTION written to DECISIONS.md)`. Attempt Stop. Expected block:

```
operator: 1 unpresented decision(s) in DECISIONS.md — present them
(/cc-operator:handoff or in your reply), then run
.operator/bin/ops-verdict.sh --mark-handoff --owner <session-id>
```

Present it in your reply, then `ops-verdict.sh --mark-handoff --owner <sid>`.
Attempt Stop → clean. Record the sequence as one row.

## R6 — Claims boundary

`printf 'y\n' > worker.txt`. Then:
`ops-claims.sh --claimed "worker.txt" --since <pre-change sha>` → every line in
the `{item <path>} ok: …` shape, exit 0. Negative control:
`ops-claims.sh --claimed "none" --since <same sha>` → C1 unclaimed-change FAIL,
exit non-zero, naming `worker.txt`. `git checkout`/`rm` the probe file, then
`ops-claims.sh --expect-clean` → ok. Record.

## R7 — Workflow layer (optional; judgment-tier spend)

Only if the session has Workflow + cc-proxy configured: run the review
workflow against a small committed artifact with `args.doneMeans` set.
Expected: a lens-ratio log line (`panel: N/5 lenses returned …` — dead-lens
accounting visible, per F31), and an adversarial verdict that is exactly
`CONFIRMED` or `REFUTED` with command output as evidence. If REFUTED: the
operator treats it as a hard stop — record what the operator *did*, not what
the workflow returned. Skip is legitimate; record `--defer "no workflow
runtime in this session"` rather than silence.

## R8 — Close honestly

`/cc-operator:handoff` → six sections, every claim ledger-cited. Close
`replay-run` with a verdict row summarizing the scorecard (`R1..R7 recorded:
<n> PASS / <n> FAIL / <n> deferred`). Attempt Stop → clean exit. The ledger
IS the scorecard; a separate report is summary, and the charter's rule is
record over summary.

---

## Reading a replay

- All phases green ⇒ the chain holds **in this harness, for this session** —
  the seam rows in PLAYBOOK's not-proven table are covered for this
  environment, dated by the run's verdict rows (each stamped `@<sha>`).
- Any phase red ⇒ file it as an issue with the observed vs expected output;
  the row's stamp names the tree it happened on. R0/R2 reds are
  harness-integration failures (highest blast radius — the gate is not
  running); R3 reds distinguish hook-answer from harness-honor; R4.3 "red"
  is almost always a misreading — reread the stamp's contract first.
- Replay after: plugin upgrades, harness (Claude Code) upgrades, new OS/uid
  environments (#20 — run once as non-root and once as root and diff), and
  before any release that claims a live-verified gate.

## What the first real run changed (2026-08-12, `1e5308a` → `13ea694`)

The charter was written from the PR #12 precedent and had never been executed
end to end. Running it produced one bug and four defects in the charter itself,
which is the honest yield of a protocol's first outing — recorded here so the
next reader knows these lines are measured rather than designed.

- **The bug: #34.** `.operator/bin/` refreshed only on a version-string change,
  so intra-version fixes never reached the project. Found by R0's build-identity
  check, which did not exist then and now leads the phase.
- **`ops-init.sh` is not in the install set**, so R1's `bash
  .operator/bin/ops-init.sh` could never have run. Corrected to the plugin-root
  invocation. I worked around it live without noticing the charter was wrong —
  a replayer following it literally would have hit a missing command.
- **R0's identity check fires one session too early** in a genuinely fresh
  project: the hook exits at `:95` when `.operator/` is absent, and the slash
  command does not re-fire it.
- **R3's control (a) contradicted itself** — R0 arms your session, so it could
  not be unarmed; the table's own parenthetical argued with itself about the
  workaround. Replaced by a probe session id, which removes the constraint
  rather than dancing around it.
- **Two expected-output strings were paraphrases**, not the real bytes (the
  foreign-sentinel line carries task, owner and open time).

Not changed: R4.3's honesty probe behaved exactly as written — broken criterion,
silent Stop, PASS row standing. The one phase designed to confirm a limitation
rather than a capability is the one that needed no correction.
