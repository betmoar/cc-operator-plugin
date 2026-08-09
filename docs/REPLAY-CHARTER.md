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

Run `/cc-operator:start`. **Expected:** `.operator/` scaffolded, `OPERATOR.md`
materialized, and — the load-bearing check — the session context carries a
session id injected by the SessionStart hook. `CLAUDE_SESSION_ID` is NOT in the
Bash tool env; only the hook supplies it. If the operator does not know its own
id, every sentinel it opens is unowned and blocks every session — stop the
replay here, this is a live-harness FAIL the suite can never see.
Call the id `<sid>` below.

Open the replay's own tracking task:
`.operator/bin/ops-task.sh replay-run --owner <sid>`

## R1 — Scaffold contracts (incl. F67)

- `ls .operator` → `VERDICTS.md DECISIONS.md pending verdicts.d bin
  .gitattributes .gitignore tiers.env` (order aside).
- `.operator/.gitignore` first non-comment line is `*` (v2 allowlist; the bare
  `*` is the load-bearing half — check_gitignore_parity's lesson).
- **F67 probe:** `printf '/.operator/\n' >> .gitignore`, re-run
  `bash .operator/bin/ops-init.sh`. Expected on stderr, naming file and line:
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
attempt Stop again. Expected stderr: `operator: 1 pending verdict(s) owned by
another session (OTHER-SESSION) — not blocking.` — reported, not blocking.
Close it: `ops-verdict.sh foreign-probe --defer "replay probe" --owner
OTHER-SESSION`.

## R3 — Arm gate, live (G2/G3; the four controls from PR #12)

Enable: `touch .operator/armgate.on`. Then, same file and same tool each time:

| Control | Setup | Expected |
|---|---|---|
| a | gate on, no open task for a probe id (use a second file, close `replay-run`? No — use a session with only `replay-run` DEFERRED, below) | Write/Edit **denied**, exit 2; stderr carries all three repair commands verbatim |
| b | `ops-task.sh arm-probe --owner <sid>` | same edit **allowed** |
| c | `rm .operator/.armed/<sid>` (simulate desync) | denied again |
| d | `ops-adopt.sh --owner <sid> arm-probe` | allowed — the deny message's own repair works |

Every deny is confirmed by **reading the file back**: the write must genuinely
never land. Practical ordering: run R3 *before* recording R2's verdict, or use
`--exempt` — `ops-task.sh --exempt "replay R3" --owner <sid>` — and verify its
message: `exemption granted for session <sid> (GATE-EXCEPTION written … Stop is
now blocked until you present it …)`. Disable after: `rm .operator/armgate.on`.

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
