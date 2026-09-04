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
ps -ax -o args= | grep '[c]laude' | head        # HOW was this session launched?
PR="$HOME/.claude/plugins/cache/<owner>/cc-operator/<version>"
[ -d "$PR/scripts" ] || { echo "PR does not resolve — find it: ls -d $HOME/.claude/plugins/cache/*/cc-operator/*"; }
```

**Check the launch line first, and prefer it over the cache path** (fourth run,
2026-08-22). A session started with `claude --plugin-dir .` loads the plugin from
**that directory**, not from the cache — so `$PR` is the working tree and the cache
copy is an unrelated older install. Resolving by convention there reported 5/5
STALE, which reads exactly like the #34 class recurring and is simply a wrong pair.
The error is symmetric and that is what makes it dangerous: a mis-resolved `$PR`
yields five spurious STALEs in one direction and five spurious CURRENTs in the
other, and only the second is silent.

Do **not** substitute the repo's own `scripts/` here *on a cache-loaded session*.
It is the reachable-looking fix and it silently audits the tree instead of the
installed plugin — precisely the build-identity confusion the next check exists to
prevent. The `cmp` below is what licenses treating the cache copy as the tree; run
it before you rely on `$PR`.

The `--plugin-dir` case is not an exception to that rule, it is the rule applied:
there the tree **is** the installed plugin, which the launch line establishes as a
fact rather than an assumption. The distinction to hold onto is *why* `$PR` points
where it does — measured from how the session was started, never picked because it
was convenient.

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
  2. **Verify the loop guard (#116 shape)** — `stop_hook_active: true` with
     THIS hook's `.operator/.stopguard/<sid>` marker present (the sequence's
     own block writes it) must give rc 0 — so the block costs exactly one turn
     and cannot wedge the session. `stop_hook_active: true` with NO marker
     (another hook's continuation) must give the gate's normal verdict — rc 2
     with the sentinel open, plus the "gate runs normally" notice on stderr.
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
operator: pending verdict(s): replay-run — run '<abs>/.operator/bin/ops-verdict.sh'
<id> <criterion> <evidence> <PASS|FAIL>, or --defer "<reason>"
```

The path is ABSOLUTE and single-quoted (#94; `<abs>` is the project root) —
the relative `.operator/bin/…` this line quoted until the 2026-09-02 audit
(F139) was the pre-#94 shape, and asserting it against the shipped hook would
have reported a defect on a correct message.

This is the one check the entire bash suite asserts only at exit-code level —
the live block is what the plugin exists to do. If cc-status renders the
statusline, its segment must show this session's pending count (a mirror of the
mine/foreign partition, not a count of `pending/`).

Foreign-sentinel half: `ops-task.sh foreign-probe --owner OTHER-SESSION`, then
attempt Stop again. Expected stderr names the task and its owner —
`operator: 1 pending verdict(s) owned by another session (foreign-probe owned by
OTHER-SESSION) — not blocking.` — reported, and the blocking
line for your own task still follows it. Close it: `ops-verdict.sh foreign-probe
--defer "replay probe" --owner OTHER-SESSION`.

There is **no open-time in that line, and its absence is the design**. Until
0.8.4 the readers parsed the sentinel BODY, so `sentinel_owner` could return
`"<owner>|<opened_at>"` in one bounded pass and the report carried a timestamp.
0.9.0 (#76 step 1) moved ownership into the FILENAME — `pending/<sid>__<task>` —
and the readers stopped opening the body at all, which is what makes them
builtin-only and what closed the `session_id: EVIL` smuggling class. The open
time went with the body read. A replayer who sees no `opened <ISO-8601>` is
looking at a correct 0.9.0+ hook; this expectation was stale prose until the
fourth run (2026-08-22) executed the phase and caught it.

R2a proves the *script's* answer; R2b is what proves the harness honors it. Both
are required — the charter's claim is about the pair, and R2a alone is the
weaker claim the 2026-08-14 run mistakenly recorded as the whole phase.

## R3 — (removed in 0.10 — the arm gate was deleted; see docs/DEBLOAT-0.10.md step 6. R5's retro-gate and deviation-gate phases remain and are the gate's live-verification surface for sentinelloss closes.)

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

   **Run the probe at a 1-path delta (#122, measured 2026-09-04).** Since #85,
   "no task open" is unreachable whenever the working tree carries ≥2 changed
   project paths — autobar arms, the hook returns rc 2 with the auto-arm
   block, and the probe reads as a FAIL it is not. That is the armer working,
   not the gate broken: the probe files are dirty by design, so an honest
   replay of this phase sits exactly on the armer's threshold. Before probing,
   drop to ONE changed path (remove `dirty.txt` from step 2, keep only the
   broken `calc.sh`), and if autobar has already armed, defer its sentinel and
   re-measure — the probe's expected reading is taken on the cleaned state.
   Option (c) of #122 was considered and rejected: clearing the whole tree
   first would also clear the broken criterion the probe exists to keep.

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
that legitimately starts with a single dash still records. **Produce that cell,
do not invent it** — the fixture repo has no test suite, so the string the
earlier revisions prescribed (`-v output: 3 passed`) could not have come from
anything in it, and the phase about evidence handling was teaching a fabricated
evidence cell. A real one is one command away:

```
printf '#!/bin/sh\necho 6\n' > calc.sh
EV="$(git diff --unified=0 -- calc.sh | grep '^-echo')"   # -> "-echo 5"
ops-task.sh R4-dash --owner <sid>
ops-verdict.sh R4-dash "a dash-leading cell still records" "$EV" PASS --owner <sid>
git checkout -- calc.sh
```

Expected: rc 0 and a row whose evidence cell reads `-echo 5 @<sha>+dirty`. The
leading `-` is what the control is about, and the string is a measurement.
Whatever your scratch project makes, take the cell from a command's real output;
a replayer who types a plausible-looking one has passed the guard's test while
failing the charter's own rule 2.

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
operator: 1 unpresented decision(s) in <abs>/.operator/DECISIONS.md — present
them (/cc-operator:handoff or in your reply), then run
<abs>/.operator/bin/ops-verdict.sh --mark-handoff --owner <session-id>
operator:   2026-08-27 | never-armed-probe | GATE-EXCEPTION | [sid:…] …
```

Both paths are ABSOLUTE and the counted row is NAMED — assert both (#93/#94).
The old message prescribed `.operator/bin/…` relative to cwd, and a session
whose Bash cwd sat in a subdirectory read the present ledger as absent; the
count named no rows, so identifying them meant reading `partition.sh`.

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
clean code cannot tell the two apart. Strip any comment that labels the defect
before committing: a lens that only finds a bug marked `DEFECT` has found the
label (fourth run).

**`args.isolate` must name a commit in the SESSION's repository, and the fifth
run got this wrong.** The worktree is created by the runtime under the session's
own repo — `.claude/worktrees/<run-id>` — so a sha from the scratch project is
an object that repo has never heard of. Measured 2026-08-25: the artifact was
committed at `c68e034` in a scratch repo, `isolate` was passed that sha, and the
seat landed on `761f93c`, the plugin repo's own default branch, where
`git cat-file -t c68e034` answers `could not get object info`. Nothing refuses
this — `isolate` is validated as 7–40 hex, not as a reachable object.

The consequence is the same cwd trap R2b carries, one phase over: **an isolated
R7 verifies the SESSION's repository, not the scratch project**, so an artifact
living outside it is read from its absolute path in a worktree that has no
relation to it. Two ways to run the phase honestly, and the choice is the
replayer's:

- **Artifact inside the session's repo** — commit it there and pass that sha.
  `atRequestedCommit` still comes back `false` (the runtime creates the worktree
  at the default branch, #74), but the worktree is at least the same project.
- **Artifact in the scratch project** — then say so and omit `isolate`. An
  un-isolated run reports `mode: builder-tree`, ships F-A1, and is the honest
  shape for an artifact the worktree could never contain.

Read the returned `isolation` block rather than the flag you passed: the fifth
run's said `atRequestedCommit: false`, `observedCommit: 761f93c…` — #74's fix
answering correctly on its first live outing, which is the reason the mismatch
was visible at all rather than being rendered as a successful isolated run.

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
  running); R4.3 "red" is almost always a misreading — reread the stamp's
  contract first.
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
`ops-corpus.sh` — since deleted in 0.10 step 6 — produces rather than merely
reporting the tree dirty), and it
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

## What the fourth real run changed (2026-08-22, `1677fff` → 0.10.0, inline load)

Scorecard by stamp: **9 PASS, 1 deferred (R7 initially), 0 FAIL, 0 not-executed** —
then R7 was executed after all, as the run's own R8 rule demands, and passed. The
run's two findings both concern *this file* and the tests around it, not the gate.

**R0 caught a wrong measurement before it became a wrong conclusion.** The first
`cmp` loop reported **5/5 STALE** against
`~/.claude/plugins/cache/betmoar/cc-operator/0.9.0`. That looked like the #34 class
recurring. It was not: `ps` showed the session running as `claude --plugin-dir .`,
so the working tree *is* the plugin root and the cache copy was simply a different,
older install. Against the correct root: 5/5 CURRENT, with the negative control
discriminating (mutate a byte in `.operator/bin/` → `STALE` for exactly that file →
restore → CURRENT).

The lesson generalizes past the inline case: **`$PR` is a claim, and R0's `cmp` is
only as good as it.** A replayer who resolves the plugin root by convention rather
than by checking how the session was launched will measure the wrong pair and get a
confident, wrong answer in either direction — five spurious STALEs here, five
spurious CURRENTs if the typo had gone the other way. Add the launch check to R0's
resolution step: `ps` for the running `claude` invocation, and prefer what it says
over the cache path.

**R2b found this charter quoting an expectation the hook has not met since 0.9.0** —
the `opened <ISO-8601>` clause, corrected in the R2b section above with its cause.
It had stood through a release for the plainest possible reason: **nobody ran the
phase.** R8 already says "before recording a phase as unexecutable, try to execute
it"; this run is the evidence that the rule applies just as much to phases nobody
bothered to execute at all. A charter that is never run is prose, and prose drifts.

**R5 ran on genuine state rather than a manufactured probe.** The R0 verdict was
recorded under `replay-run-R0` while the open sentinel was `replay-run` — an
ordinary id mismatch, and the retro-gate caught it, writing a real GATE-EXCEPTION.
So the deviation gate had two unpresented decisions to block on, one accidental and
one deliberate, and cleared correctly on `--mark-handoff` (rc 2 → 0 through the
hook). An accident is a better fixture than a probe.

**R1's F05 control littered the repo it was auditing, again.** Running the scaffold
from `docs/` scaffolded there — nine entries, gitignored and therefore invisible to
`git status`. The third run recorded this same cleanup and the note was read only
*after* re-creating the mess. Kept here in stronger terms: the F05 control's cleanup
is part of the control, not a postscript to it.

**R7 was run rather than deferred, and it is the reason the panel's claim is
testable.** A committed artifact carried one **unlabelled** off-by-one —
`can_afford` uses `<` where `spend()` gates on `>`, so a request for exactly the
remaining budget is refused while `spend()` accepts it. The giveaway comment was
stripped before committing, because a lens that only finds a defect labelled
`DEFECT` has found the label, not the bug.

Verdict **REFUTED**, `blocked: true`, all five lenses finding it independently
(scores 95/95/95/85/85). The adversarial seat swept the boundary exhaustively — 21
mismatches, one for every state where `n == remaining()` — and found three defects
nobody planted: `ZeroDivisionError` at `total=0`, an unvalidated negative total, and
a check-then-act race in `spend()`. 6 agents, 0 errors, 129,700 tokens, 120s.

Two things worth carrying from it. First, the run was **un-isolated**, so F-A1
shipped and fired correctly — it reported the replayer's own in-progress edits as
stray paths, which is exactly its job on a run whose artifact lived elsewhere. The
returned `isolation` block said `mode: builder-tree`, `observedCommit: null`: honest
about what it did not do (#74). Second, R7's negative control is not optional
ceremony. A panel returning CONFIRMED on everything is indistinguishable from a
working one when it only ever sees clean code, and this is the phase that tells them
apart.

**What the run did NOT reach, recorded rather than glossed:** only `review` has been
exercised against a real model (#79), and `skills/chief-operator` has no gate of any
kind (#80). Both filed with the measurement attached.

## What the fifth real run changed (2026-08-25, `761f93c`, 0.11.1 from the cache)

Scorecard by stamp: **9 PASS, 0 FAIL, 0 human-verified-only, 0 deferred,
0 not-executed** — filtered with `@761f93c52ccb`, which separated this run's rows
from the previous four without any bookkeeping, U10's stamp doing its job again.

**R0 earned its place at the front, for the second time.** The plugin had just been
upgraded to 0.11.1 through `/plugin`, and `.operator/bin/` was still 0.11.0: two of
the five CLIs (`ops-verdict.sh`, `ops-adopt.sh`) lacked the `LC_ALL=C` byte-cap fix
that release shipped, and `.version` still read `0.11.0`. Firing the SessionStart
hook once took it to 5/5 CURRENT. This is #34's class arriving by a different road
— not an intra-version fix going unnoticed, but an upgrade landing in a session that
never re-fired the hook. **A `/plugin` upgrade mid-session does not refresh `bin/`;
the next SessionStart does.** The negative control discriminated: a byte appended to
`bin/ops-task.sh` reported STALE for exactly that file, restored to CURRENT.

**The F05 control did not litter the repo this time.** Runs three and four both left
a real `.operator/` inside `docs/`, gitignored and invisible to `git status`, and
the fourth run's note about it was read only after re-creating the mess. Running the
control in a scratch repo instead costs nothing and removes the failure mode; the
charter's F05 text now has no reason to be followed literally inside the audited
tree.

**Two defects, both found by phases judging the replay rather than the code:**

- **R4's dash-leading control prescribed a fabricated evidence cell.** The
  adversarial seat, unprompted, checked `-v output: 3 passed` against the fixture
  repo and found four files and no test suite — nothing there can produce that line.
  The charter was teaching a replayer to type a plausible-looking evidence string in
  the phase whose subject is evidence handling, against its own rule 2. Replaced
  with a cell taken from a real `git diff` (`-echo 5`), which is dash-leading for
  the same reason and is a measurement.
- **`args.isolate` accepted a sha from a different repository.** The artifact was
  committed in the scratch project; the worktree was created under the session's own
  repo at its default branch, where that object does not exist. `isolate` validates
  the string as 7–40 hex, not as a reachable commit, so nothing refused it. Written
  up in R7 with both honest ways to run the phase.

**The gate answered honestly about its own limits, which is why the second defect
was visible.** The returned block read `atRequestedCommit: false`,
`observedCommit: 761f93c…` — #74's fix on its first live outing. Before 0.11.1 the
same run would have rendered as `mode: worktree` with a `requestedCommit` and no way
to tell it apart from a real one.

**R2b arrived unplanned and passed.** The session's own Stop was blocked mid-replay
by `replay-run-R7` — the harness feeding back the hook's stderr, in the project being
audited, without the phase being set up. The blocked turn granted another turn and
the block was reported from inside the session, which is what the 2026-08-14 run
established and this one re-confirmed for free.

**What did not need correcting: R4.3's honesty probe, for the fourth run running.**
Broken criterion, silent Stop, PASS row standing. The one phase designed to confirm
a limitation rather than a capability has never once needed an edit.
