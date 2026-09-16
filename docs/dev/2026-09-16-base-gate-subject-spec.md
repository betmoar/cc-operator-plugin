# Spec — the base-gate judges the merge result, and runs from its own workflow

**Date:** 2026-09-16 · **Tier:** L · **Issues:** #130, #131, #128 · **Target version:** 0.11.13

## Goal

`scripts/base-gate.sh` (#108) currently reports a weakening that the merge would not
contain, and its CI job lands twice on every head under two different events. Both are
wiring defects in the trusted half of the enforcer, and both bite harder the more PRs
are open at once — which the remaining roadmap (#112) will do. Fix the subject it
judges and the event it runs under, before that work starts.

## Requirements

Each is testable and carries the exact string or value it asserts.

### R1 — arms 1, 2, 3 and 3b judge the MERGE RESULT, not the PR head

`base-gate.sh` computes a merged tree from `BASE_SHA` and `PR_SHA` and uses that tree
as the PR-side subject for the four arms that ask "does the result weaken the base":

| arm | subject before | subject after |
|---|---|---|
| 1 floors | `PR_SHA` | `MERGED_TREE` |
| 2 CHECKS registry | `PR_SHA` | `MERGED_TREE` |
| 3 enforcer-file + `tests/` presence | `PR_SHA` | `MERGED_TREE` |
| 3b CI rung set | `PR_SHA` | `MERGED_TREE` |
| 4 delta report | `BASE..PR` | **unchanged** |
| 5 forged marker | `BASE..PR` | **`diff BASE_SHA PR_TREE`** (AMENDED) |

**AMENDED 2026-09-16 after the Task 1 re-review.** Arm 4 keeps the diff subject on
purpose: the delta report names what *this PR* touched, and a human reads it as
authorship. **Arm 5 does not, and the table above originally said it did.** A hard-fail
arm must ask what the tree a merge would actually produce carries. Measured: the escape
that motivated the move does NOT reproduce — when the PR never touches the hunk the
base's deletion wins the merge and the marker is absent under either form, and when it
does touch it `merge-tree` reports a conflict and the script refuses before arm 5 runs.
What the move actually buys is a closed FALSE POSITIVE (a marker the base's own tip
already carries, restated by the PR) plus one subject across every hard-fail arm. Two
cases pin the form together: three-dot reddens one, two-dot reddens the other, only
base-vs-tree passes both.

**Measured basis** (git 2.43.0 local, 2.55.0 on the GitHub runner per the #126 job log):

```
$ git merge-tree --write-tree <moved-main> <pr>
rc=0  tree=706062b2ab79...
$ git show <tree>:tests/floors.env | grep ^FLOOR_shell   ->  FLOOR_shell=985
$ git ls-tree -r --name-only <tree> -- tests/test-new.sh ->  tests/test-new.sh
```

Both accessor forms the arms use (`git show <tree>:<path>`, `ls-tree -r <tree>`) work
against a tree sha unchanged.

### R2 — six merge-tree outcomes, five distinct refusals

`rc` alone does not separate them.

**AMENDED 2026-09-16 after Task 1** — the first table was measured from a construction
that `base-gate.sh` cannot actually reach (an unresolvable sha, which `rev-parse` refuses
several lines earlier). Re-measured against the built script, two rows were wrong and one
was missing:

| situation | rc | stdout line 1 |
|---|---|---|
| clean merge | 0 | the merged tree sha |
| real conflict | 1 | the tree sha, followed by conflict stages |
| the PR's ROOT TREE object is absent | **0** | **git's EMPTY tree** (`4b825dc6…`) |
| an object is unreadable (corrupt) | **128** | nothing |
| `--write-tree` unsupported (old git) | 129 | nothing |
| unreadable/absent object | 1 | *nothing* — kept, but no construction reaches it |

So the discriminator is **rc, plus whether stdout line 1 is a sha, plus whether the tree
has any entries**:

- rc 0, a sha, and a NON-EMPTY tree → use it.
- rc 0, a sha, and an EMPTY tree → `die`. Measured: deleting the PR commit's root tree
  makes `merge-tree` return rc 0 and the empty tree, and the gate accepted it as the
  subject. Every arm then reads every enforcer file as absent, so an incomplete
  repository renders as "the ratchet is deleted" and "GONE:" for each core file — a
  confident weakening verdict with an infrastructure cause. The base always has files, so
  a clean merge whose result is empty cannot be a legitimate PR.
- rc 0 and no sha → `die`, "unexpected merge-tree output".
- rc 1 and a sha → `die`, the PR **conflicts** with the base. Message says the gate
  *cannot judge* it, never that the PR weakens anything: GitHub already refuses to merge
  a conflicted PR, so the only honest claim here is that no result tree exists to read.
- rc 1 and no sha → `die`, an object could not be read. Retained because it costs one
  branch, though neither Task 1's implementer nor the controller could construct it.
- **rc 128 → `die`, a FATAL git error: the repository is incomplete or an object is
  unreadable.** This is the reachable form of the truncated-fetch shape that bit the #125
  marker arm. Measured: corrupting the PR's root tree object produces exactly this, and
  the first implementation reported it as `--write-tree` being unavailable — blaming the
  runner's git version for a corrupt repository, which is the same two-causes-one-message
  defect this requirement exists to remove.
- rc 129 or anything else → `die`, `merge-tree --write-tree` unavailable on this runner.

Every one of these is rc 2 from `base-gate.sh` (refusal), never rc 1 (violation) and
never rc 0. Fail closed, as the file's header already claims everywhere else.

### R3 — both CI checkouts carry enough history for a merge base

`merge-tree` needs the merge base. The job today checks out the base sha and fetches the
head with `--depth=1`. After this change the checkout uses `fetch-depth: 0` and the head
fetch drops `--depth=1`.

### R4 — the base-gate job lives in its own workflow, subscribed only to the trusted event

New `.github/workflows/base-gate.yml` and `.forgejo/workflows/base-gate.yml`, each with:

```yaml
on:
  pull_request_target:
```

and no other trigger. The job loses its `if: github.event_name == 'pull_request_target'`
guard, because the file's `on:` block now *is* the guard: a workflow that does not
subscribe to `pull_request` cannot run under it. Both `validate.yml` files lose the
`base-gate` job and the `pull_request_target:` trigger.

This removes the skipped twin measured on #126:

```
run 34284576371 (pull_request_target)  base-gate  success
run 34284578552 (pull_request)         base-gate  skipped
```

### R5 — the validator pins follow the job

`check_base_gate` reads `_CI_FILES` today. It gains a `_BASE_GATE_FILES` tuple naming the
two new workflows, and its claims become:

1. the workflow declares `pull_request_target:` **and does not declare** `pull_request:` —
   the structural replacement for the old `if:` string pin;
2. the job's `uses: actions/checkout` pins a `ref:` containing `base`;
3. the job runs `bash scripts/base-gate.sh`;
4. the job carries the `BASE_GATE_BOOTSTRAP` branch;
5. **neither `validate.yml` still contains a `base-gate:` job** — a leftover would run
   under the untrusted event, which is the exact inversion #108 was built to end.

`_CI_FILES` is NOT extended: `check_suite_floors` requires every rung in every file it
lists, and the base-gate workflow runs no rungs.

### R6 — deleting a base-gate workflow is a hard red

`base-gate.sh`'s own `CI_FILES` list gains the two new paths, so a PR that deletes one is
caught by the presence half of arm 3b (`GONE: …`). The gate runs from the base, so it
still executes when a PR deletes its own workflow file.

### R7 — `ops-reverify.sh` matches the ledger header WHOLE (#128)

```sh
# before
case "$row" in "| Gate | Criterion |"* | "|---"*) continue ;; esac
# after
case "$row" in
  "| Gate | Criterion | Evidence | PASS/FAIL |" | "|---"*) continue ;;
esac
```

A task id of `Gate` with criterion `Criterion` is a ledger `ops-task.sh` permits, and the
prefix form silently drops that row from the re-verification sweep while counting it as
"not a 4-cell row". `scripts/lib/caps.sh` already carries the whole-line form; this is the
same fix in the sibling parser.

## Non-goals

- **No staleness signal.** A PR far behind the base now passes silently when the merge
  result is clean. That is correct for the question the gate asks, and GitHub already
  shows "out of date" in the UI. Not adding a second report line for it.
- **No fallback to the base-tip subject** when `merge-tree` is unavailable. The file's
  header already rules this out: falling back to a weaker subject is the original bug
  wearing a fallback's clothes. It fails closed and the runner gets fixed.
- **No change to what the gate cannot catch.** A check rewritten in place stays #112's
  holdout, riding the delta report to the human merge.
- **No branch-protection changes.** Out of my reach and out of scope; see the assumption.

## Success criteria

| # | criterion | command / expected |
|---|---|---|
| S1 | the concurrent-PR false red is gone | the #130 reproducer (innocent PR + moved main) exits 0 where it exits 1 today |
| S2 | a real weakening is still caught through a merge | lower a floor on the PR side while main moves elsewhere → `BASE_GATE_FAILED: FLOOR:` |
| S3 | the four refusals are distinct | one case per row of R2's table, each asserting its own message |
| S4 | no skipped twin | the next PR shows exactly one check run named `base-gate` |
| S5 | every arm still red under mutation | each arm neutered → red **in the bash suite's `base-gate` cases**, named per #111 |
| S6 | validator pins red under mutation | each R5 claim neutered → red **in `check_base_gate`** |
| S7 | gates green | all five rungs at floor, shellcheck 0.10.0 rc 0, release gate `v0.11.13` |
| S8 | #128 | a `Gate`/`Criterion` row is dated, and the real header is still skipped |

## Assumptions (stated rather than asked)

1. **Version 0.11.13**, patch bump, matching how 0.11.7 through 0.11.12 shipped features.
2. **#128 rides this branch** as its own commit. It is a different file and a different
   tool, but it is the same defect class as a fix already in `caps.sh`, and this repo's
   measured per-PR review cost (seven rounds on #126, per #129) makes a separate PR
   cycle cost more than the scope discipline buys.
3. **Conflict polarity is refuse-to-judge**, per R2.
4. **Forgejo's `merge-tree --write-tree` support is unmeasured.** Only `lokaal` can settle
   it, and it is a success criterion I cannot run. If that runner's git predates 2.38 the
   Forgejo base-gate will refuse (rc 2) rather than fall back, and the GitHub half carries
   the gate meanwhile — the same posture the trigger question took in #125.

## The one thing only you can check

`main` is protected, and whether `base-gate` is a **required** status check is not
readable from this session's token. R4 moves the job to a different workflow file while
keeping the check **name** identical, which is what GitHub matches required checks on — so
the expectation is that nothing breaks. But if the name were to resolve differently, the
first PR after this lands could sit waiting on a check that never reports, and unwedging
that needs admin access.

If you prefer to de-risk it: approve R1/R2/R3/R7 now and hold R4/R5/R6 for a follow-up
once you have looked at the setting. The two halves are independent — R1 does not need
the job to move.
