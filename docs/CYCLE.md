# CYCLE — the engagement cycle, and the spec stage that is missing from it

Read-only rationale, like everything under `docs/`. Nothing here is loaded at
runtime and nothing here is implemented yet: this file specifies the **spec
artifact**, its **approval stamp**, and the **derived-stage rule**, so the three
issues that build them argue from one document instead of three descriptions.

Scope discipline, stated once: `templates/OPERATOR.md` is at 143/150 lines and
8873/9000 bytes. Nothing proposed here goes in the charter, and if something
needs charter bytes the design is wrong — issue #75's own acceptance criterion,
kept.

## 1. The cycle as it exists today

| Stage | Mechanism | Driven by |
|---|---|---|
| diverge | `workflows/brainstorm.js` → `{ranked, sharedConstraints, openQuestions}` | operator hand-builds `args` |
| **spec** | **nothing** | — |
| plan | `workflows/plan.js`, refuses without `args.spec` **and** `args.northStar` | operator retypes both |
| implement | `workflows/dispatch.js`, or a plain `Agent` call | operator |
| review | `workflows/review.js` | operator |
| gate | `ops-task.sh` → `ops-verdict.sh` | operator, by hand |
| handoff | `/cc-operator:handoff` | the one stage with a command |

Three commands ship (`start`, `handoff`, `tiers`). Six workflows ship with no
command surface. Every transition between stages is the operator remembering to
make it — which is the one thing the RECOVERY PROTOCOL says not to rely on.

## 2. Why the spec stage is the load-bearing gap

Four measurements, not an opinion:

1. **The handoff from diverge to plan is a source comment.** The closing comment
   in `workflows/brainstorm.js` (after the `bundle` return) instructs the
   operator to "write the approved design to `docs/spec/`". That is the entire
   mechanism.
2. **`docs/spec/` does not exist.** The directory emptied in 0.11.9. Three
   tracked files still pointed at it when this document was written (`README.md`,
   `CONTRIBUTING.md`, `docs/HANDOUT.md`), a class already fixed once as **F61**
   and regressed since. Those three are corrected in the same commit as this
   file; the absence of a destination is the finding, not the links.
3. **The only artifact bridging the two stages is prose the operator retypes.**
   `args.spec` is a string assembled in the operator's context. It has no file,
   no provenance, no source-state stamp, and no ledger row — so a compaction
   between brainstorm and plan loses it entirely, and nothing notices.
4. **There are two north stars and nothing links them.** The BAR block carries
   one (charter § ENGAGEMENT CONTRACT: one sentence plus `Missed if:`).
   `workflows/plan.js` requires its own `args.northStar` with the same
   `Missed if:` requirement, read without a fallback and interpolated into the
   decompose prompt exactly once. Two sentences, two authors, one engagement.
   When they diverge, the plan is vetted against a goal the ledger never agreed
   to, and the divergence is invisible.

The evidence gate's whole premise is that a claim without a durable artifact is
not a claim. The spec is the one stage where the project does not apply that
premise to itself.

## 3. The spec artifact

### 3.1 Location

`.operator/specs/<slug>.md`, tracked in git.

Under `.operator/` because it is engagement state and the gate CLIs already
resolve that root by the bounded walk-up. Tracked because a spec is an **input
to later work**, not a read-once report — issue #75 reasons the same split for
plans, and a spec that is not diffable cannot be reviewed in the PR that
implements it.

**This is not free.** `.operator/.gitignore` is a v2 **allowlist**: `*` followed
by explicit `!` re-admissions (the ledgers, `verdicts.d/`, `tiers.env`,
`handoff-*.md`). Specs need `!specs/` and `!specs/*.md`, and the allowlist
cannot be extended in place: the migration in both writers fires only when the
version marker is **absent**, so adding a line without bumping the marker leaves
every already-initialized project silently ignoring its own specs — the stale
installed-copy class. Bumping the marker to v3 is therefore required, and the
migration's backup path is hardcoded two-state (`.gitignore.v1.bak`), so a v3
migration would write a file whose name lies about its contents. The builder
owes: a generalized backup name, both writers changed together (the parity check
pins both halves), and the migration's refusal cases extended to the third
state.

An implementation that cannot pay that cost should put specs in the project's
own `docs/` rather than weaken the allowlist — but then the spec leaves the root
every other engagement artifact lives under, and `ops-stage.sh` (§5) gains a
configurable path, which is a worse trade.

### 3.2 Schema

Fixed section order, validated by `ops-spec.sh --check`, mirroring how the
charter's own section order is pinned:

```
# SPEC — <title>

Slug: <slug>
Status: DRAFT | APPROVED @<source-stamp>
Provenance: <what produced this — brainstorm run, interview, direct authorship>

## North star
<one sentence naming what must be true when this is done>
Missed if: <the falsifying condition>

## Done criteria
| # | Criterion | Command | Expected output |
|---|---|---|---|

## In scope
## Out of scope
## Open questions
| Question | Resolution | Decided by |
|---|---|---|

## Constraints
<inherited from the brainstorm bundle's sharedConstraints, one per line>
```

Three requirements carry weight; the rest is shape:

- **North star is one sentence and carries `Missed if:`.** It is the sentence
  `plan.js` requires and the sentence the BAR block requires. One file, one
  author, both consumers.
- **At least one done criterion names a command and its expected output.** A
  criterion with no command is a criterion no one outside the session can
  reproduce — issue #25's defect, arriving one stage earlier.
- **Every open question is resolved or explicitly deferred before approval.**
  The brainstorm bundle emits `openQuestions` ordered by architectural blast
  radius precisely so the operator can interview the human one at a time; an
  approved spec with an unanswered blast-radius question is the interview
  skipped.

### 3.3 Approval, and what the stamp means

`ops-spec.sh --approve <slug>` does three things and refuses if `--check` does
not pass first:

1. Stamps `Status: APPROVED @<source-stamp>` using the **same** resolution
   `ops-verdict.sh` uses for a row — `@<sha>`, `+dirty` when anything outside
   `.operator/` was uncommitted, `@no-commit`, `@no-vcs`, `+unknown` when git
   could not answer. Same function, same degradation ladder, hand-copied the way
   the other readers are or (better) sourced from a shared lib.
2. Appends one line to `DECISIONS.md` under a new **record** kind
   `SPEC-APPROVED` — never a gated kind. Gated kinds block Stop until the
   handoff presents them; an approved spec is not a deviation to answer for.
   Putting it in the wrong constant is issue #9's defect: a kind in the wrong
   set is a kind the gate silently ignores.
3. Emits the **BAR block** into `VERDICTS.md`, built from the spec's north star,
   done criteria, budget and caps.

Point 3 is where the user-facing win is. Today the BAR block is a hand-written
ceremony the charter requires before the first implementation action, and the
auto-arm in `scripts/lib/autobar.sh` exists because operators skip it. An
approved spec already contains every field the BAR block wants; writing it twice
is the drift, not the ceremony.

Read the stamp for exactly what it is, the same caveat the ledger carries: it
says *this spec was approved against that tree*, never *that tree satisfies this
spec*.

### 3.4 Cost to the gate surface

A new CLI installed into `.operator/bin/` is not a free addition in this repo.
`ops-spec.sh` owes, at minimum:

- an entry in `scripts/ops-install-set.sh` (the one declaration both writers
  source);
- the byte-identical PROJECT ROOT BLOCK, pinned across the gate CLIs by the
  root-parity check — including its canonical-content pin, because copy-pasted
  blocks drift uniformly;
- `check_bare_name`'s reject set applied to `<slug>`, since the slug becomes a
  filename;
- a byte bound with a NUL probe if it reads any ledger, per the reader-bounds
  floor;
- the three `DECISIONS_*` validator constants plus the schema check, for the new
  kind;
- bash-suite cases and a `FLOOR_shell` raise in the same commit.

Stated up front so the work is chosen with its price visible, not discovered at
the fourth review round.

## 4. The plan gate

`/cc-operator:plan <slug>`:

1. resolves the spec, **refuses** unless `Status: APPROVED`;
2. reads the north star out of the spec and passes it as `args.northStar`;
3. passes the spec body as `args.spec`;
4. resolves `args.tiers` itself by calling the resolver, so no model id is
   pasted by hand.

Step 2 collapses the two north stars into one. Step 4 closes the call-site half
of issue #55 at the command layer: today the operator runs the renderer to print
one id, reads it off stdout, and pastes it into a `Workflow` call — a manual
step whose failure mode is silent dispatch on the wrong model.

The same shape applies to `/cc-operator:{brainstorm,review,debate,crawl}`, which
is issue #75's first half. A command per workflow is the largest
user-friendliness gain per line in this design, and it needs no new mechanism.

## 5. The derived stage — `ops-stage.sh`

The autonomy lever is not a scheduler. It is making the cycle able to say where
it is and what comes next, without anyone storing that answer.

**Derived, never stored.** `docs/UNKNOWNS.md` states the rule this repo applies
to itself: the moment status lives in two places, one of them is wrong and
nothing says which. A `.operator/engagement.json` would be that second place. So
the stage is a pure function of artifacts already on disk:

| Condition (first match wins) | Stage | Next |
|---|---|---|
| a sentinel this session owns is pending | `IMPLEMENT` | record a verdict, or `--defer` |
| no spec file exists | `DIVERGE` | run brainstorm, then `ops-spec.sh --new` |
| a spec exists, `Status: DRAFT` | `SPEC` | resolve open questions, then `--approve` |
| an approved spec, no plan artifact | `PLAN` | run the plan workflow against it |
| a plan exists, open criteria with no PASS row | `IMPLEMENT` | open a task |
| every BAR criterion has a PASS row | `HANDOFF` | `/cc-operator:handoff` |

Four constraints on the implementation:

- **Report-only.** It never exits non-zero, never blocks, never writes — the
  posture the cap detector already holds, where the validator refuses an `exit`
  in any of its branches.
- **It must not re-implement the partition.** The mine/foreign sentinel scan
  lives in `scripts/lib/partition.sh` and has exactly one implementation, shared
  by the Stop hook and the status bar. A third reader answering differently is
  worse than no third reader.
- **The status-bar consumer inherits the bar's budget**, not the hook's: the bar
  fails toward silence inside roughly a 300ms render budget, which is why it
  approximates the deviation scan with a tail window. A whole-ledger stage
  derivation is a hook-side cost, not a bar-side one.
- **Unknown is a real answer.** A project mid-migration, or one whose spec is
  unparseable, prints `STAGE unknown` and why. Guessing a stage is how a
  derived field becomes a stored one.

## 6. What this design deliberately does not do

- **No charter edit.** 127 bytes and 7 lines of headroom; a destination
  preference is the wrong altitude for the charter anyway.
- **No workflow gains a tool.** Workflow scripts get `agent`, `parallel`,
  `pipeline`, `phase` and `log`. The spec is written by the **operator**, from
  the bundle a workflow returned — the constraint issue #75 identified, applied
  here rather than fought.
- **No state file, no scheduler, no auto-advance.** The cycle proposes the next
  step; a human or the operator takes it. Auto-advance past an unanswered
  blast-radius question is the failure this whole stage exists to prevent.
- **No claim that a spec makes plans correct.** It makes the input durable,
  stamped and single-sourced. Whether the plan is good is still the vetting
  lenses' job, and issue #79 still stands: only the review workflow has ever run
  against a live model.

## 7. Build order

Each step is independently shippable and independently useful.

1. **Commands per workflow, tiers auto-resolved** (§4, issue #75 first half). No
   new mechanism, no gate surface, closes the #55 call-site footgun.
2. **`ops-spec.sh` + `/cc-operator:spec` + the plan gate** (§3, §4). The
   allowlist migration is the long pole; price it before starting.
3. **`ops-stage.sh`** (§5), then the status-bar segment once the CLI is proven.
4. **Pre-dispatch triage** (issue #152) in front of the spec→plan fan-out, so a
   thin spec is refused at roughly one agent instead of after a seven-seat run.
5. **`/cc-operator:tutorial`** (issue #75 second half), whose acceptance
   criterion is a Stop that visibly blocks and is then cleared by a verdict row.
