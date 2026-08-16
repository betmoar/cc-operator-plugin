# REPLAY CHARTER — live-session audit of the implementation-verification chain

An executable protocol, not prose. Run it inside a **live Claude Code session**
with the plugin installed, against a scratch project. Its purpose is the seam
the bash suite cannot reach: the suite proves the *scripts* answer correctly;
this charter proves the *harness* honors those answers — the rows in
`docs/PLAYBOOK.md` § "What a green suite does NOT prove", exercised end to end.
PR #12's live G2 proof (2026-08-08) is the precedent; this charter is that
method made repeatable.

Four rules bind the whole run, all inherited from the operator charter:

1. **The replay uses the gate it audits.** Every phase's result is recorded as
   a verdict row via `ops-task.sh`/`ops-verdict.sh` — dogfooding is the point.
   A phase without its expected output recorded is FAIL by definition.
2. **Record over summary.** The evidence cell cites the actual command output,
   never a paraphrase. Meter check per phase: state in one line what would make
   the observation invalid, and check that.
3. **A negative control per phase.** State, and run, the command that would make
   the phase go red — then confirm it does. A phase that has only ever been
   observed green cannot distinguish "the gate works" from "the gate is not
   running", and this repo has shipped both: `check_routable` returning 0 before
   the allowlist was consulted, a `--expect-clean` count stuck at 1, four
   identically-broken `ROUTABLE` copies passing a parity check. Each phase below
   names its control; if you invent a new phase, it owes one too. Where a control
   is genuinely unavailable (R2's live half — a replayer cannot make the harness
   ignore a block), say so in the row rather than omitting the line.
4. **Cap: one retry per failing phase**, then record FAIL with the observed
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

**Resolve the plugin root first — `${CLAUDE_PLUGIN_ROOT}` is NOT set in the Bash
tool environment** (issue #62, measured 2026-08-14: it expands to empty, so every
phase that ran a script through that variable was really running `/scripts/…`,
and failed). This is the same asymmetry CLAUDE.md records for `CLAUDE_SESSION_ID`:
**hooks** get the plugin environment, the **Bash tool** does not. Resolve it once,
by hand, and use `$PR` everywhere the charter used to write the variable:

```
PR="$HOME/.claude/plugins/cache/<owner>/cc-operator/<version>"
[ -d "$PR/scripts" ] || { echo "PR does not resolve — find it: ls -d $HOME/.claude/plugins/cache/*/cc-operator/*"; }
```

Do **not** substitute the repo's own `scripts/` here. It is the reachable-looking
fix and it silently audits the tree instead of the installed plugin — precisely
the build-identity confusion the next check exists to prevent. The `cmp` below is
what licenses treating the cache copy as the tree; run it before you rely on `$PR`.

**Build identity — do this before any other phase.** Establish *which* code the
run is about to test, because there are two answers and they can differ:

```
for f in ops-verdict.sh ops-task.sh ops-adopt.sh ops-claims.sh ops-backlog.sh; do
  cmp -s ".operator/bin/$f" "$PR/scripts/$f" \
    && echo "$f CURRENT" || echo "$f STALE"
done
```

**Negative control (R0):** a `cmp` that can only say CURRENT proves nothing about
staleness. Copy one CLI aside, mutate a byte in `.operator/bin/`, and confirm the
loop reports `STALE` for exactly that file — then restore it and re-run to
CURRENT. Without this, an `ls`-typo in `$PR` reads as five CURRENTs on a path
that does not exist.

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
- **F67 probe.** **First check whether the project ALREADY gitignores
  `.operator/` from outside** — `grep -n '^/\?\.operator/\?$' .gitignore`. This
  repo does, at `.gitignore:34`, and a probe that adds a second rule then removes
  only its own leaves the warning standing, which reads as a broken detector
  while it is working perfectly. The control only discriminates once EVERY such
  rule is gone (third run, 2026-08-16). Then: `printf '/.operator/\n' >> .gitignore`, then re-run the
  scaffold. `ops-init.sh` is **not** in the `.operator/bin/` install set — that
  set is `ops-verdict.sh ops-task.sh ops-adopt.sh ops-claims.sh ops-backlog.sh`
  (`ops-init.sh:194`), because init is what *creates* `bin/` and would have to
  install itself. So run it the way the harness does, from the plugin root:
  `bash "$PR/scripts/ops-init.sh"` (see R0 — `${CLAUDE_PLUGIN_ROOT}` is unset
  here), or re-issue `/cc-operator:start`. Expected on stderr, naming file and
  line: `ops-init: WARNING — the evidence ledger is gitignored by a rule outside
  .operator/.gitignore:`. Then remove the line and re-run: warning absent —
  **that removal IS this phase's negative control**, and it is the half that
  distinguishes a working detector from a script that always warns.
- **F05 root check** — and **clean up after its control**: running the scaffold
  from a subdirectory SCAFFOLDS THERE. The third run left a real `docs/.operator/`
  with 11 files behind, gitignored and therefore invisible to `git status`, in the
  repo it was auditing. Remove it before continuing. The check itself: the
  scaffold must NOT warn `NOT the repository root` at the
  repo root. On macOS this is load-bearing: `/tmp` is a symlink to `private/tmp`,
  and the pre-0.8.1 comparison of git's physical toplevel against `$PWD` fired on
  every scratch project (issue #61). Control: `mkdir sub && cd sub` and re-run —
  the warning must appear there, or the check has merely been muted.

Record: `ops-verdict.sh R1 "scaffold + F67 warning" "<paste stderr line>" PASS
--owner <sid>` — and note the row itself must end `@<sha>` (R4 checks this
deliberately; seeing it here early is the stamp working).

## R2 — Stop gate (script half: executable · live half: HUMAN-VERIFIED)

**Read this before recording R2.** The phase has two halves and they are not
equally reachable:

- **R2a, the script half** — feeding the hook a payload — is executable by a
  replayer and is where the citable bytes come from.
- **R2b, the live half** — the harness actually blocking a Stop — **is
  executable**, but only from the session's own project and only with the setup
  below. It must never be recorded as a normal PASS on the script half's
  evidence.

  **One constraint, and one correction to an earlier revision of this file.**

  The constraint is real: the Stop hook resolves the nearest `.operator/` above
  *the session's* cwd, not above the scratch project. A session running in this
  repo with a scratch project at `/tmp/replay` is blocked (or not) by **this
  repo's** ledger, so a sentinel opened in the scratch project proves nothing —
  a green R2b there is evidence about the wrong project. **Open the R2b probe
  sentinel in the session's own cwd.**

  The correction: the 0.8.1 revision also claimed "a session that genuinely
  blocks its own Stop cannot then report that it did." **That is false**, and it
  was disproved on 2026-08-14 by running it. A blocked Stop does not silence the
  session — it **grants another turn** with the hook's stderr fed back as
  guidance, and that continuation *is* the observation. The claim confused "the
  turn cannot end" with "the session cannot speak."

  **How to run it** (three preconditions, none optional):

  1. **Baseline first.** Feed the hook the same payload with no sentinel open:
     rc 0 and silent. Without this a block is unattributable — it could be any
     of the other Stop hooks a real install carries (zclean, cc-reload,
     cc-repete were all present on the 2026-08-14 machine).
  2. **Verify the loop guard** — `stop_hook_active: true` must give rc 0 — so
     the block costs exactly one turn and cannot wedge the session.
  3. **Use a probe task id that exists nowhere else** (`r2b-live`). The
     returned message names it, which is what makes the block attributable to
     *this* hook rather than to a coincidence.

  Then open the sentinel, end the turn, and record what comes back. **A human
  observing from outside the session is still worth having** — it is what turns
  "I report I was blocked" into two independent observers — but it is
  corroboration now, not the only channel. Note in the evidence cell which one
  you had. A phase that cannot execute must not read PASS on its own authority;
  a phase that *can* execute should be executed. (The 2026-08-14 run recorded R2
  green on the script half alone; the follow-up ran R2b properly and passed.)

### R2a — script half (executable)

With `replay-run` open, drive the hook directly — this is how you get the exact
bytes to cite:

```
printf '{"session_id":"<sid>","cwd":"'"$PWD"'"}' | bash "$PR/scripts/ops-stop-hook.sh"; echo "rc=$?"
```

Expected: rc 2 and the blocking line below on stderr. **Negative control:** close
or defer the task and re-feed the same payload — rc 0, no output. A hook that
blocks unconditionally passes the positive half alone.

### R2b — live half (executable from the session's own cwd; see above)

Open the probe sentinel **in the session's own project** (`ops-task.sh r2b-live
--owner <sid>`, after the baseline and loop-guard checks above), then **attempt
to end the session** (finish the turn). Expected: the Stop is blocked and the
model receives, verbatim shape:

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

R2a proves the *script's* answer; R2b is what proves the harness honors it. Both
are required — the charter's claim is about the pair, and R2a alone is the
weaker claim the 2026-08-14 run mistakenly recorded as the whole phase.

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
  | bash "$PR/scripts/ops-armgate-hook.sh"; echo "rc=$?"
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

**Negative control (R3):** controls (b) and (d) ARE the control — they are the
allowed half, and without them a hook that denies unconditionally passes (a) and
(c). Add one more, because the gate is opt-in: with `.operator/armgate.on`
removed, the same payload from an unarmed `<psid>` must be **allowed**. A gate
that denies while switched off is not a gate, it is a wedge.

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

**Negative control (R4):** step 2 is the control for step 1 — `+dirty` appearing
only when the tree is dirty is what makes the stamp a measurement rather than a
constant. Check the pair explicitly: the two rows must carry the SAME sha and
differ only by the suffix. Two identical stamps, or two that differ in the sha,
both mean the stamp is not reading what it claims to read.

**Also verify the parser refuses a mistyped flag** (issue #64, fixed 0.8.1) —
this is the ownership gate's own control:
`ops-verdict.sh R4-pass "c" "e" PASS --ownr <sid>` must exit non-zero naming
`unknown option`, and **no row may appear**. Before the fix it warned, wrote the
row, and cleared the sentinel at rc 0. Control for the control: an evidence cell
that legitimately starts with a single dash still records —
`ops-verdict.sh R4-dash "c" "-v output: 3 passed" PASS --owner <sid>` exits 0.

**Recording this phase needs one rewording, and the guard is right.** Evidence
cells are pipe-delimited, and `ops-verdict.sh` refuses a cell containing `|` —
so the natural evidence line, which quotes this phase's own expected usage
string (the one carrying `<PASS|FAIL>`), is itself refused. Paraphrase the
usage string in the cell rather than quoting it verbatim; the guard firing on
your evidence is the guard working (third run, 2026-08-16).

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

**Negative control (R5):** the `--mark-handoff` half IS the control — a
deviation gate that never clears blocks forever and would pass the block
assertion alone. Drive both through the hook (R2a's payload) so the rc flip
2 → 0 is citable, not inferred from the harness's silence.

## R6 — Claims boundary

`printf 'y\n' > worker.txt`. Then:
`ops-claims.sh --claimed "worker.txt" --since <pre-change sha>` → every line in
the `{item <path>} ok: …` shape, exit 0. Negative control:
`ops-claims.sh --claimed "none" --since <same sha>` → C1 unclaimed-change FAIL,
exit non-zero, naming `worker.txt`. That FAIL is this phase's **negative
control**: it is what separates a working C1 from one that has stopped checking.
`git checkout`/`rm` the probe file, then `ops-claims.sh --expect-clean` → ok.
Record.

**Read the green line's COUNT, do not just read `ok`** (issue #63, fixed 0.8.1).
By this point the scaffold plus your own verdict rows have made several
`.operator/` paths dirty; they are exempt from C1 by design, and the count must
therefore report the CLAIMED path only, with the exempt ones named separately:
`ok: 1 changed path(s) all claimed; no phantom claims (N .operator/ ledger
path(s) exempt)`. The pre-0.8.1 line read `7 changed path(s) all claimed` for one
claimed path — an inflated number an operator then banks into a verdict row.

## R7 — Workflow layer (optional; judgment-tier spend)

Only if the session has Workflow + cc-proxy configured: run the review
workflow against a small committed artifact with `args.doneMeans` set.
Expected: a lens-ratio log line (`panel: N/5 lenses returned …` — dead-lens
accounting visible, per F31), and an adversarial verdict that is exactly
`CONFIRMED` or `REFUTED` with command output as evidence. If REFUTED: the
operator treats it as a hard stop — record what the operator *did*, not what
the workflow returned. Skip is legitimate; record `--defer "no workflow
runtime in this session"` rather than silence.

**Negative control (R7):** run one lens against an artifact with a KNOWN defect
and confirm it is found. A panel that returns CONFIRMED on everything is the
dead-lens failure F31's ratio line exists to expose, and a green run against
clean code cannot tell the two apart.

## R8 — Close honestly

`/cc-operator:handoff` → six sections, every claim ledger-cited. Close
`replay-run` with a verdict row summarizing the scorecard (`R1..R7 recorded:
<n> PASS / <n> FAIL / <n> deferred`). Attempt Stop → clean exit. The ledger
IS the scorecard; a separate report is summary, and the charter's rule is
record over summary.

The scorecard must count **human-verified**, **deferred**, and **not executed**
as their own categories, not fold them into PASS. A run that reports "8 PASS"
when one of them was never executed has produced exactly the summary this
charter exists to replace — which is what the 2026-08-14 run did with R2b before
anyone tried running it.

The rule generalizes past R2b, and this is the lesson worth carrying: **before
recording a phase as unexecutable, try to execute it.** R2b was declared
human-verified on an argument that sounded structural and was simply wrong, and
the argument went unchallenged for a release because nobody attempted the thing
it forbade. A category is a claim like any other and owes the same evidence.

**Negative control (R8):** before closing `replay-run`, confirm the Stop is
still blocked with it open (R2a's payload, rc 2). A clean exit at R8 only means
something if it was blocked a moment earlier.

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

## What the second real run changed (2026-08-14, `de6ae4e` → 0.8.1)

The second execution found four charter defects and three code bugs. Three of the
four charter defects are the same class as the first run's: **the charter told
the replayer to run something a replayer cannot run.** That is now the thing to
look for first when this document is revised.

- **`${CLAUDE_PLUGIN_ROOT}` is unset in the Bash tool env** (#62) — R0's `cmp`,
  R1's scaffold re-run and R3's arm payload all expanded to `/scripts/…`. R0 now
  resolves `$PR` by hand and says why the repo's own `scripts/` is the wrong
  substitute. Note the shape: the run WORKED AROUND this live and recorded the
  phases green, so the charter's own text stayed wrong while the run passed.
- **R2's live half was recorded without being run** — the first run reported the
  pair as one PASS on the script half alone. Split into R2a and R2b. Half of the
  reasoning given for the split was wrong and is corrected below.
- **No phase required a negative control**, though the charter has demanded a
  meter check since it was written. Now rule 3, with a control named per phase —
  this repo's recurring failure is not a gate that answers wrongly, it is a gate
  that has stopped answering while every observation stays green.
- **The scorecard folded deferred and human-verified into PASS**, which is how
  R2b read green.

Code bugs found by the run and fixed in 0.8.1: #61 (F05 warning fired on every
symlinked path, i.e. every `/tmp` scratch project on macOS), #63 (the claims
green line counted the ledger paths it had just exempted), #64 (a mistyped
`--owner` degraded the hard ownership refusal to a warning, letting one session
close another's task at rc 0).

## What running R2b changed (2026-08-14, same day, after 0.8.1 was written)

The 0.8.1 revision above declared R2b unexecutable on two grounds. **One was
right, one was false, and the false one was disproved by simply doing the thing
it said could not be done** — which is the finding, more than the phase result.

- **Right:** the hook resolves the nearest `.operator/` above the *session's*
  cwd, so the probe sentinel must be opened in the session's own project. A
  sentinel in the scratch project would have proved nothing.
- **False:** "a session that blocks its own Stop cannot report having done so."
  A blocked Stop grants the session **another turn**, carrying the hook's stderr
  as guidance. The claim confused *the turn cannot end* with *the session cannot
  speak*.

Run properly — baseline rc 0 and silent, loop guard confirmed, a probe id
(`r2b-live`) existing nowhere else so the returned message is attributable — the
harness blocked and fed back
`operator: pending verdict(s): r2b-live — run .operator/bin/ops-verdict.sh …`,
with the user independently observing from outside the session. **R2b PASS,
live.**

An unplanned corroboration came with it: the feedback line shows the harness
invoking the hook through `${CLAUDE_PLUGIN_ROOT}` and *resolving* it, in the same
session where R0 measured that variable as unset in the Bash tool env — #62's
asymmetry, proved from both sides in one run.

The transferable lesson is now rule-shaped in R8: **before recording a phase as
unexecutable, try to execute it.** "Cannot be tested" is a claim, and it owes
evidence like any other. This one survived a release because it sounded
structural.

## What the third real run changed (2026-08-16, `8ef5d9e`, 0.8.4 inline)

The first run to record a **FAIL**, and the first where the protocol's own
negative controls — not its positive assertions — produced every finding worth
having. Scorecard by stamp: 10 PASS, 1 FAIL, 0 human-verified, 0 deferred,
0 not-executed.

**The FAIL is R7 and it is the point of the phase.** The adversarial seat
returned REFUTED and it was right twice over: it refuted on F-A1 (an
uncommitted fixture edit, which it *demonstrated* changes the stamp
`ops-corpus.sh` produces rather than merely reporting the tree dirty), and it
found two live defects in `corpus_hash` — code this repo had shipped one day
earlier as the fix for the plausible-hash class:

- `if ! find … | sort > list` tests the **last** stage. `sort` succeeds on a
  partial stream, so an undescendable subdirectory produced a green build **and**
  a green verify over a corpus missing files — precisely the state the comment
  above it claimed was closed.
- The newline-in-filename guard was **vacuous**: both sides counted `grep -c ''`
  of the same `find -print` output, and a newline splits both identically.
  Measured `lines=3 files=3` on a two-file corpus containing `a<LF>b.txt`.

Recorded as FAIL rather than outvoted by five green lens findings, per the
unoutvotable rule. Fixed under `R7-fix`, mutation-verified (restoring both
pre-R7 shapes reddens exactly the two new cases), hash-preserving.

**Three charter defects, all in phases the charter calls simple:**

- **R1's F67 control is invalid in any project that already has an
  `/.operator/` rule.** This repo carries one at `.gitignore:34`. The probe adds
  a second, and removing *that* leaves the warning standing — which reads as a
  broken detector while it is working correctly. The control only discriminates
  once **every** such line is removed. The charter says "remove the line";
  it must say "confirm no such rule pre-exists, or remove them all".
- **R1's F05 control scaffolds a real `.operator/` in the subdirectory it runs
  from.** Eleven files, gitignored, invisible to `git status` — a replayer
  following the charter literally leaves a stray ledger inside the repo being
  audited. The phase needs a cleanup line.
- **R4's parser control cannot be recorded verbatim.** Its own expected-output
  string contains `PASS|FAIL`, and the evidence cell refuses a pipe (cells are
  pipe-delimited). The guard is right; the charter's example is unrecordable as
  written.

**One fixture defect, found by R7's negative control rather than by the panel.**
Pointed at `drift/lock-ceiling/drifted/lock.sh` with the `feasibility` prompt
verbatim, one lens found the 2s claim it was meant to find *and*, unprompted,
that the loop increments before the guard and sleeps only in the else path:
**29 sleeps ≈ 2.9s, not 30**. So the fixture's *corrected* column was also
wrong. A negative control is supposed to prove the panel is not a rubber stamp;
this one did that and improved the instrument.

**What did not need correcting:** R4.3's honesty probe, again — broken
criterion, silent Stop, PASS row standing. Two runs in a row, the one phase
designed to confirm a limitation is the one that needs no edits.

**The ledger separated the runs by itself.** Filtering the phase rows to
`@8ef5d9eb26bd` gave exactly this run's eleven, with 2026-08-14's rows sitting
above them untouched — U10's stamp doing the job it was built for, incidentally,
in the middle of an audit about something else.
