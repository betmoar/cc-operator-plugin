# Audit 2026-08-09 — the assurance-model pass (F67–F69, U10–U13)

The first audit handoff that ships in-tree. Every prior audit's writeup
(F01–F66) lived only in the maintainer's local `.archive/dev/` — `git log --all`
on those paths is empty, no clone at any commit resolves them (F68). What
survives of them in-tree is the guardrail code, the F-numbers in comments, and
CHANGELOG. This file is the rule's first exception, and the rule going forward:
**an audit's output either ships in `docs/audit-<date>-handoff.md` or it is
maintainer-local and must be cited as such.**

Audited: `eec378e` (branch `claude/assurance-gaps-audit-qkjeai` = PR #26 —
PR #12's 0.7.0 arm-gate tree + the U10 source-stamp fix). Mode: autonomous,
seeded with the session's measured findings. Verdict: **healthy** — dense,
honest guardrail culture; the real exposure is in what the framework does not
yet claim (the U11–U13 gaps below), not in what it does.

## The mental model a successor needs

Three lifecycles, three different maturity levels. Confusing them is how this
product gets overclaimed:

1. **Task lifecycle** (mature, shipping): sentinel → verdict → Stop gate, plus
   the 0.7.0 arm-gate layer (G1 retro-gate, G2 opt-in arm gate, G3 exemption).
   Guarantees accountability: work ends with a recorded verdict.
2. **Evidence lifecycle** (partial as of this branch): every verdict row now
   names the source state that produced it — the U10 stamp, `@<sha>[+dirty]`
   etc., pinned by `check_source_stamp` + the S1 cases. That is **provenance**
   ("this row was written from that tree"), never **attestation** ("that tree
   passes"). The staleness reader (#22 step 2) is unbuilt.
3. **External verification** (absent, by measurement): the verifier shares the
   builder's execution state (#23 — a gitignored `__pycache__` flipped a
   verdict), no security/supply-chain review lens exists (#24), and nothing
   outside the session can reproduce a done-criterion (#25 — BAR blocks are
   prose; CI never reads the ledger; and a parent gitignore can silently defeat
   the evidence allowlist, fixed this pass as F67's warning).

The unknowns register of record is **GitHub issues** (`label:unknown` /
`label:residual`), per `docs/UNKNOWNS.md`. This file does not duplicate their
status — it tells you they exist and how they relate.

## Findings this pass (F67–F69; numbering continues the F01–F66 history)

| ID | Sev | What | Fix shipped | Guardrail |
|---|---|---|---|---|
| F67 | P2 | A root/ancestor `.gitignore` rule excluding `.operator/` silently defeats the v2 allowlist — git never descends into an excluded dir, so the nested negations re-admit nothing; ops-init reported success while every ledger stayed untracked. Measured (issue #25 comment). | `ops-init.sh` now runs `git check-ignore` on the ledger after writing the allowlist and warns on stderr, naming the defeating rule. Warn-never-fail: the exclusion can be deliberate (this repo's own dogfooding is exactly that). Deliberately NOT in the SessionStart refresh — that hook runs every session and must stay quiet. | 5 bash cases (fires+names rule / silent healthy / silent non-git / rc=0 in all), proven discriminating by reverting the fix and watching the warning vanish. |
| F68 | P3 | CLAUDE.md's audit-trail pointers (`AUDIT_LOG.md`, `docs/audit-2026-07-31-handoff.md`) referenced files that exist in **no commit** — dead ends presented as provenance. | Three sites reworded to the maintainer-local rule; the resolvable trail now points here. | None proportionate for one link; this file existing is the fix's other half, and its opening paragraph restates the rule. |
| F69 | P3 | `docs/HANDOUT.md` drifted from the authorities on three load-bearing points: IMPLEMENT default (`glm-5.2` vs the resolver's `claude-sonnet-5`), "read-only seats can't change files" (vs PLAYBOOK: a tool-list claim, not a boundary), and a dispatch packet missing TEXT, SHA and `CHANGED:` — the line `ops-claims.sh` verifies, so handout-taught users ran the worker-boundary layer unchecked. | All three corrected; packet now carries the charter's literal. | `validate_plugin.check_handout_packet` pins the packet spine (`TASK / TEXT / SCENE`, `CHANGED: <paths>|none`) whenever the handout exists; pytest mutation test proves it fires on the measured drift. |

Declared fine, so the next reader doesn't re-spend here: `ops-backlog.sh`
(census NUL-handling and PARTIAL marker match their cases), the armgate hook
(matches its header contract including the #19 uid-0 halves), `pyproject.toml`'s
testpaths pin, `commands/*.md` + `SKILL.md` against the charter. Not re-audited
this pass: `workflows/*.js` + `ops-compress.mjs` line-level — the 141 node
tests and the prior F07–F66 pass stand for them.

## What a green suite does NOT prove (additions this pass)

- **Suites run as uid 0 prove one case less**: CR3 fails loud under root (#20),
  and the armgate's `[ ! -x ]` half is inert there (#19/#21 — the
  permission-guard class has no validator check yet, #21 is the tracker).
- **A stamped PASS is not a passing tree**: the stamp binds a row to a state;
  nothing re-runs anything (#22 step 2 unbuilt).
- **A CONFIRMED verdict is not clean-environment behavior**: the verifier
  inherits builder state (#23's fixture flips the verdict between in-tree and
  clean checkout of the same commit).

## Residual risks (known, not fixed here)

| Risk | Sev | Why not fixed | Mitigation in place |
|---|---|---|---|
| Verdict row + GATE-EXCEPTION are two appends; crash between loses the audit line | P2 (#14) | Needs an atomic-pair change to the single writer's ordering contract — its own slice | Residual documented in `retro_gate`; recorded > guessed |
| Verifier shares builder execution state | P1-for-release-claims (#23) | Scoping decision (worktree isolation per adversarial dispatch) belongs with the maintainer; harness flag exists | Measured fixture + fix path recorded on the issue |
| No security/supply-chain lens | P2 (#24) | Detection-rate experiment unrun; lens design should follow the numbers | Fixed five-lens panel + adversarial re-run still apply |
| No external reproduction of done-criteria | P3 (#25) | Prerequisites absent (machine-readable BAR, committed evidence); F67's warning closes the silent-defeat corner only | Stamp (U10) is the first prerequisite, shipped |
| `--census` 1.62s vs <1s bound on 12K files | P3 (#15) | Measured, informational — U3 made the trigger a user declaration | Number recorded on the issue |

## Backlog (prioritized, pickup-able cold)

1. **#22 step 2 — `ops-verdict.sh --audit` staleness reader.** Context: rows
   now carry `@<sha>`; a reader can say which PASS rows cite a state that is no
   longer HEAD or no longer exists. Reader rules are in PLAYBOOK §"adding a
   reader" item 5 (last `@`-token; unstamped = pre-stamp history). First step:
   walk `VERDICTS.md` rows, resolve each stamp with `git cat-file -e`.
   Done-when: a table of stale/current/unresolvable rows, tested on a repo
   where HEAD moved after a PASS.
2. **#23 — worktree-isolated adversarial seat.** First step: add
   `isolation: 'worktree'` to the adversarial dispatch in `workflows/review.js`
   behind an `args.assurance` flag; refuse when the artifact is uncommitted
   (F37 shape). Done-when: the #23 fixture REFUTES in-panel with the flag on.
3. **#24 — security-lens experiment.** First step: build the five fixtures
   named on the issue (this repo's own defect shapes); run the current panel;
   record detection. Done-when: the delta table exists and the lens/no-lens
   decision cites it.
4. **#21 — `check_no_permission_guards`.** Context: the `[ -r/-w/-x ]` class is
   vacuous under uid 0; one live instance (#19). Done-when: validator rejects a
   new permission-test guard in `scripts/*.sh` code lines outside an allowlist.
5. **#25 — machine-readable BAR.** Blocked-on: #22's stamp (done) + a decision
   on committing `.operator/` evidence per-project. First step:
   `ops-verdict.sh --bar <id> --cmd <c> --expect <pattern>` writing alongside
   the prose BAR. Done-when: a CI job can replay one criterion from a clean
   checkout.
6. **#14 — atomic verdict+exception pair.** Own slice; touches the single
   writer's ordering contract; the reverted false-positive guard (G1.7) is the
   cautionary precedent recorded in `retro_gate`.

## Verification of this pass

Baseline → delta, same environment (uid 0): bash **454/1 → 459/1** (the 1 is
#20's CR3, byte-identical, pre-existing), pytest **138 → 139 passed / 0
failed**, node **73/0 + 68/0** unchanged, `validate_plugin.py` exit 0 with two
checks added (`check_handout_packet`, plus F67's five bash cases), shellcheck
clean. Both new guardrails were proven **discriminating**, not just green: the
F67 cases fail against the reverted `ops-init.sh` (re-run shown in the audit
log), and `check_handout_packet` fires on the exact measured drift inside its
pytest test.
