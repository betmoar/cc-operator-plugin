# Base-gate subject + own workflow — Implementation Plan

> Execute with dev-flow: subagent per task, review after each task.
> Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** the trusted gate judges the tree a merge would produce, runs only under the
trusted event, and stops reporting weakenings the merge does not contain.
**Architecture:** `base-gate.sh` gains one new subject (`PR_TREE`, from
`git merge-tree --write-tree`) that arms 1, 2, 3 and 3b read instead of `PR_SHA`; arms 4
and 5 keep the `BASE..PR` diff. The CI job moves out of `validate.yml` into a workflow
subscribed only to `pull_request_target`, which makes the `on:` block the guard that an
`if:` string is today. `check_base_gate` follows the job.
**Tech stack:** bash (3.2-compatible, builtin-only where the existing file is), GitHub
Actions + Forgejo Actions YAML, python 3 (validator), shellcheck 0.10.0 pinned.
**Spec:** `docs/dev/2026-09-16-base-gate-subject-spec.md`
**Baseline** (measured 2026-09-16 on `d9ed4cd`, rootful Linux container):

```
validator  all contracts hold
python     375 cases (floor 375, slack 0)
shell      980 cases (floor 980, slack 0)     968 passed, 0 failed, 12 skipped
workflows  384 cases (floor 384, slack 0)
compress   161 cases (floor 161, slack 0)
shellcheck 0.10.0  rc 0
release    v0.11.12 OK
```

## Global Constraints

Copied verbatim from the spec and from `CLAUDE.md`; every task's requirements include
these.

- **Fail closed everywhere.** Every new refusal in `base-gate.sh` exits **2** (`die`),
  never 1 (violation) and never 0. No fallback to a weaker subject.
- **Name the gate that went red (#111).** Every mutation recorded in a commit message
  says which gate failed: "red in `check_base_gate`", "red in the bash suite's
  `base-gate` cases". Never bare "mutation-checked".
- **Restore byte-identical** after every mutation, and purge `__pycache__` between
  mutate and restore (PLAYBOOK step 5 — a stale pyc kept executing a mutant).
- **Raise the floor in the same commit** that adds cases: run the rung, take
  **passed+skipped**, set `FLOOR_<rung>` to exactly that, and record the measurement in
  the `tests/floors.env` header with the date and executor.
- **`_CI_FILES` is not extended.** `check_suite_floors` demands every rung in every file
  it lists; the base-gate workflow runs no rungs.
- **shellcheck 0.10.0 is the pin** (`/tmp/shellcheck-v0.10.0/shellcheck`); 0.11 does not
  fail SC2015 and this repo has already paid for that drift once.
- **No raw ESC bytes, no `sed -i` spelling assumptions** in test fixtures — `printf`
  whole files (GNU vs BSD `sed -i` differ and this suite runs on both executors).
- Version **0.11.13**; `plugin.json` and the newest `## [0.11.13]` CHANGELOG heading land
  in the same commit or the release gate fails.

---

### Task 1: the merged-tree subject in `base-gate.sh`

Implements R1 and R2.

**Files:**
- Modify: `scripts/base-gate.sh` — header CATCHES list; new block after line 128
  (`BASE_SHA=…`); banner line 130; arm 1 (lines 167, 182); arm 2 (243, 251); arm 3
  (299, 310); arm 3b (336, 341)
- Test: `tests/test-scripts.sh` — inside the existing
  `-- Case: base-gate.sh — the enforcer judged by code the PR cannot edit (#108)` block
  (starts line 4980)
- Modify: `tests/floors.env`

**Interfaces:**
- Produces: `PR_TREE` — a 40- or 64-hex tree sha, the PR-side subject for arms 1/2/3/3b.
  `_is_sha <string>` — returns 0 for 40 or 64 lowercase hex characters.
- Consumes: `BASE_SHA`, `PR_SHA` (unchanged, still the arm 4/5 subject).

- [ ] **Step 1: Write the failing tests**

Append inside the existing `base-gate` case block, before the `--- fail-closed` section.
The scratch repo (`$BGD`, `$BG_BASE`, `bg_run`) already exists in that block.

```bash
# --- the SUBJECT is the MERGE RESULT, not the PR head (#130) ----------------
# Re-measured 2026-09-16: a PR that touches nothing the gate guards went RED
# the moment the base raised a floor and added a tests/ file underneath it,
# because both sides were compared as COMMITS. Merging that branch leaves the
# raised floor and the added file in place, so the gate asserted a weakening
# the result does not contain. The subject is now `git merge-tree`'s tree.
git -C "$BGD" checkout -q -b innocent "$BG_BASE"
printf 'a docs line\n' >> "$BGD/NOTES-innocent.md"
git -C "$BGD" add -A >/dev/null 2>&1 && git -C "$BGD" commit -qm innocent
# the base moves the way every PR in this repo moves it
git -C "$BGD" checkout -q -b moved "$BG_BASE"
bg_floors 10 25
printf 'another suite file\n' > "$BGD/tests/test-two.sh"
git -C "$BGD" add -A >/dev/null 2>&1 && git -C "$BGD" commit -qm moved
BG_MOVED="$(git -C "$BGD" rev-parse moved)"
BG_OUT="$(bash "$BG" --base "$BG_MOVED" --pr innocent --repo "$BGD" 2>&1)"; BG_RC=$?
check "base-gate: a PR that is BEHIND the base passes — the merge result is the subject (#130)" \
  "$([ "$BG_RC" = 0 ] && echo 0 || echo 1)"
check "base-gate: and it says which tree it judged" \
  "$(printf '%s' "$BG_OUT" | grep -q 'merged tree' && echo 0 || echo 1)"
# CONTROL: a real weakening ON TOP of a moved base is still caught, or the
# case above would be satisfied by a gate that stopped looking.
git -C "$BGD" checkout -q -b weakens "$BG_BASE"
bg_floors 10 1
git -C "$BGD" commit -qam weakens
BG_OUT="$(bash "$BG" --base "$BG_MOVED" --pr weakens --repo "$BGD" 2>&1)"; BG_RC=$?
check "base-gate: a floor LOWERED is still refused when the base has moved (control)" \
  "$([ "$BG_RC" = 1 ] && echo 0 || echo 1)"

# --- the four merge-tree outcomes, three of them refusals (R2) --------------
# rc alone cannot classify: a real conflict and an UNREADABLE OBJECT both
# return 1, and only a tree sha on stdout line 1 separates them. A truncated
# shallow fetch takes the second shape, and this job fetches the PR head.
git -C "$BGD" checkout -q -b conflicts "$BG_BASE"
bg_floors 10 30
git -C "$BGD" commit -qam conflicts
BG_OUT="$(bash "$BG" --base "$BG_MOVED" --pr conflicts --repo "$BGD" 2>&1)"; BG_RC=$?
check "base-gate: a CONFLICTING pr is rc 2 (cannot judge), never rc 1 (weakens)" \
  "$([ "$BG_RC" = 2 ] && echo 0 || echo 1)"
check "base-gate: the conflict refusal says CONFLICT, and does not claim a weakening" \
  "$(printf '%s' "$BG_OUT" | grep -q 'conflicts with the base' \
     && ! printf '%s' "$BG_OUT" | grep -q 'BASE_GATE_FAILED' && echo 0 || echo 1)"
```

- [ ] **Step 2: Run them, verify they fail correctly**

Run: `bash tests/test-scripts.sh 2>&1 | grep -E '^ *FAIL|#130|merge-tree|conflicts with'`
Expected: the behind-the-base case FAILs with the gate reporting a lowered floor and a
`GONE:` line (today's defect), and the conflict case FAILs with rc 1 rather than 2. Not
an unrelated error such as a missing `bg_floors`.

- [ ] **Step 3: Minimal implementation**

3a. Insert after line 128 (`BASE_SHA=…`), before the banner:

```bash
# --- the SUBJECT: the tree a MERGE would produce (#130) -----------------------
# Arms 1, 2, 3 and 3b ask "does the RESULT weaken the base". Comparing the two
# sides as commits answers a different question, and answers it wrongly in the
# ordinary case: this repo raises a floor and adds a tests/ file in nearly
# every PR, so any branch that has not rebased since is reported as LOWERING
# that floor and DELETING that file. Measured 2026-09-16 against d9ed4cd: a PR
# whose only change was one line of README produced two BASE_GATE_FAILED lines
# and rc 1, while the merge result contained neither weakening.
#
# `merge-tree --write-tree` (git >= 2.38; the runner has 2.55) produces that
# tree with NO checkout and NO worktree, so the trusted-subject property is
# untouched: PR bytes are still never on disk and never executed.
#
# FOUR OUTCOMES, and rc alone does not separate them (measured 2026-09-16):
#   rc 0 + a tree sha  -> clean merge, this is the subject
#   rc 0 + no sha      -> an output shape this gate does not understand
#   rc 1 + a tree sha  -> a real CONFLICT (the stages follow the tree)
#   rc 1 + no sha      -> an object could not be READ, which is what a
#                         truncated shallow fetch looks like — the same shape
#                         that silently disarmed the marker arm in #125. It
#                         must never read as a conflict.
#   any other rc       -> --write-tree unavailable (129 on an older git)
# All four non-clean cases are rc 2 refusals: the gate says it cannot judge,
# never that the PR weakens anything. A conflicted PR cannot be merged by
# GitHub either way, so refusing to judge it costs nothing and claims nothing.
_is_sha() {  # _is_sha <string> → 0 when it is 40 or 64 lowercase hex chars
  case "${1:-}" in "" | *[!0-9a-f]*) return 1 ;; esac
  [ "${#1}" -eq 40 ] || [ "${#1}" -eq 64 ]
}
_MT_OUT="$(mktemp "${_TMPDIR_T}/basegate.mt.XXXXXX")"
git -C "$REPO" merge-tree --write-tree "$BASE_SHA" "$PR_SHA" > "$_MT_OUT" 2>/dev/null
_MT_RC=$?
PR_TREE="$(head -1 "$_MT_OUT" 2>/dev/null)"
rm -f "$_MT_OUT"
if [ "$_MT_RC" -eq 0 ] && _is_sha "$PR_TREE"; then
  :
elif [ "$_MT_RC" -eq 0 ]; then
  die "merge-tree reported success but printed no tree object — an output shape this gate does not understand; refusing rather than guessing at a subject"
elif [ "$_MT_RC" -eq 1 ] && _is_sha "$PR_TREE"; then
  die "the pr ref '${PR_REF}' CONFLICTS with the base ref '${BASE_REF}' — there is no merge result to judge, so this gate refuses rather than reporting a weakening it cannot see. Rebase or merge the base into the PR and re-run"
elif [ "$_MT_RC" -eq 1 ]; then
  die "merge-tree could not read an object for ${BASE_SHA:0:12}..${PR_SHA:0:12} — the repository is incomplete (a truncated or shallow fetch takes exactly this shape). This is NOT a conflict and must not be read as one; fetch both sides in full"
else
  die "git merge-tree --write-tree exited ${_MT_RC} — the option is unavailable on this runner (it needs git >= 2.38). Refusing: falling back to comparing the PR head is the defect this subject exists to remove"
fi
```

3b. Banner (line 130) becomes:

```bash
echo "== base-gate: trusted base ${BASE_SHA:0:12} vs pr ${PR_SHA:0:12} (merged tree ${PR_TREE:0:12}) =="
```

3c. Replace `$PR_SHA` with `$PR_TREE` at exactly these eight sites, and nowhere else:

| line | today | becomes |
|---|---|---|
| 167 | `extract_floors "$PR_SHA" "$PR_FLOORS"` | `extract_floors "$PR_TREE" "$PR_FLOORS"` |
| 182 | `git … show "${PR_SHA}:tests/floors.env"` | `"${PR_TREE}:tests/floors.env"` |
| 243 | `extract_checks "$PR_SHA" > "$PR_CHECKS"` | `extract_checks "$PR_TREE" …` |
| 251 | `git … show "${PR_SHA}:scripts/validate_plugin.py"` | `"${PR_TREE}:…"` |
| 299 | `ls-tree -r --name-only "${PR_SHA}" -- "$_f"` | `"${PR_TREE}"` |
| 310 | `ls-tree -r --name-only "${PR_SHA}" -- tests/` | `"${PR_TREE}"` |
| 336 | `ls-tree -r --name-only "${PR_SHA}" -- "$_ci"` | `"${PR_TREE}"` |
| 341 | `_ci_rungs "$PR_SHA" "$_ci"` | `_ci_rungs "$PR_TREE" "$_ci"` |

Lines 148 (change list), 390 (marker diff), 409 (final marker) keep `PR_SHA` — arms 4 and
5 ask what *this PR* did, not what the result is.

3d. Header CATCHES list gains one line above the floors bullet:

```
#   THE SUBJECT is the tree a MERGE would produce, not the PR head — so a PR
#   that is merely BEHIND the base is not reported as deleting what the base
#   added (#130). Conflict, unreadable object, and an unavailable merge-tree
#   are three distinct rc-2 refusals; none of them is a weakening.
```

- [ ] **Step 4: Run tests, verify pass + no regressions vs baseline**

Run: `bash scripts/gate-suite.sh shell` and `/tmp/shellcheck-v0.10.0/shellcheck scripts/base-gate.sh`
Expected: the six new checks pass; shellcheck rc 0; count = baseline 980 + 6 = 986
passed+skipped. Raise `FLOOR_shell` to the measured total in this commit.

Then the four named mutations, each restored byte-identical:

| mutation | expected red |
|---|---|
| `PR_TREE="$PR_SHA"` right after the classifier | the behind-the-base case, in the bash suite's `base-gate` cases |
| drop the `_MT_RC -eq 1 && _is_sha` branch | the conflict case, same block |
| `_is_sha` always returns 0 | the unreadable-object case, same block |
| revert line 167 alone to `$PR_SHA` | the behind-the-base case only — proves the site list is load-bearing per site |

- [ ] **Step 5: Commit**

```bash
git add scripts/base-gate.sh tests/test-scripts.sh tests/floors.env
git commit -m "fix(#130): the base-gate judges the merge result, not the PR head"
```

#### Task 1a (AMENDMENT, 2026-09-16 — after Task 1 shipped as `5cb8a20`)

> **SUPERSEDED IN PLACES, 2026-09-16.** Tasks 1 and 1a shipped and were reviewed; the fix
> for that review's findings is `23e0e03`. Two prescriptions below were corrected by that
> work and are left here only for the record: the `repository is incomplete` grep was
> VACUOUS (the string appears in three `die` messages, so folding rc 128 into the rc-1
> branch stayed green — `fatal error (128)` is the discriminator, and this file now says
> so), and the delta-report case's suggested `grep -q 'NOTES-innocent'` could never match,
> because a repo-root file is not an enforcer-core path. Do not re-implement from the
> uncorrected text.

Task 1's classifier is built and green, and the controller's own verification found two
branches of it wrong. Both measured against the built script, not argued:

```
PR root tree CORRUPTED -> merge-tree rc 128, no stdout
   base-gate says: "the option is unavailable on this runner (it needs git >= 2.38)"
   — it blames the git version for a corrupt repository.
PR root tree DELETED   -> merge-tree rc 0, stdout = 4b825dc642cb (git's EMPTY tree)
   base-gate says: "== … (merged tree 4b825dc642cb) ==" and accepts it as the subject.
   Every arm then reads every enforcer file as absent. It exited 2 here only because an
   unrelated downstream guard (the change-list diff) failed — passing for the wrong reason.
```

**Files:** Modify `scripts/base-gate.sh` (the classifier block only), `tests/test-scripts.sh`,
`tests/floors.env`.

- [ ] **Step 1: two failing checks**, appended to the merge-tree outcome block added by
  Task 1:

```bash
# rc 128 is the REACHABLE unreadable-object shape, and the first cut reported it as an
# unavailable git option — a corrupt repository blamed on the runner's version.
git -C "$BGD" checkout -q -b corrupttree "$BG_BASE"
printf 'x
' > "$BGD/tests/t-corrupt.sh"
git -C "$BGD" add -A >/dev/null 2>&1 && git -C "$BGD" commit -qm corrupttree
_ct="$(git -C "$BGD" rev-parse 'corrupttree^{tree}')"
printf 'garbage' > "$BGD/.git/objects/${_ct%"${_ct#??}"}/${_ct#??}"
BG_OUT="$(bash "$BG" --base "$BG_BASE" --pr corrupttree --repo "$BGD" 2>&1)"; BG_RC=$?
check "base-gate: an UNREADABLE object is rc 2 and names the repository, not the git version" \
  "$([ "$BG_RC" = 2 ] && printf '%s' "$BG_OUT" | grep -q 'fatal error (128)' \
     && ! printf '%s' "$BG_OUT" | grep -q 'git >= 2.38' && echo 0 || echo 1)"
git -C "$BGD" checkout -q "$BG_BASE" 2>/dev/null
```

The empty-tree half needs its own scratch repo because deleting a root tree leaves `$BGD`
unusable for later cases; create one, delete the PR commit's root tree, and assert:

```bash
check "base-gate: an EMPTY merged tree is refused as a subject, never judged" \
  "$([ "$BG_RC" = 2 ] && printf '%s' "$BG_OUT" | grep -q 'empty' \
     && ! printf '%s' "$BG_OUT" | grep -q 'BASE_GATE_FAILED' && echo 0 || echo 1)"
```

- [ ] **Step 2:** run; both FAIL — the first with the `git >= 2.38` wording, the second
  with the gate proceeding past an empty tree.

- [ ] **Step 3:** replace the classifier's tail branches:

```bash
if [ "$_MT_RC" -eq 0 ] && _is_sha "$PR_TREE"; then
  # A CLEAN merge whose result is EMPTY is not a clean merge — the base always
  # carries files, so an empty result means an input was incomplete. Measured
  # 2026-09-16: deleting the PR commit's root tree yields rc 0 and git's empty
  # tree, which every arm then reads as "every enforcer file is gone".
  if [ -z "$(git -C "$REPO" ls-tree "$PR_TREE" 2>/dev/null | head -1)" ]; then
    die "the merge of ${BASE_SHA:0:12} and ${PR_SHA:0:12} produced an EMPTY tree — the base carries files, so this means the repository is incomplete (a missing tree object takes exactly this shape), not that the PR deleted everything. Refusing rather than reporting every enforcer file as GONE"
  fi
elif [ "$_MT_RC" -eq 0 ]; then
  die "merge-tree reported success but printed no tree object — an output shape this gate does not understand; refusing rather than guessing at a subject"
elif [ "$_MT_RC" -eq 1 ] && _is_sha "$PR_TREE"; then
  die "the pr ref '${PR_REF}' conflicts with the base ref '${BASE_REF}' — there is no merge result to judge, so this gate refuses rather than reporting a weakening it cannot see. Rebase or merge the base into the PR and re-run"
elif [ "$_MT_RC" -eq 1 ]; then
  die "merge-tree could not read an object for ${BASE_SHA:0:12}..${PR_SHA:0:12} — this is NOT a conflict and must not be read as one; fetch both sides in full"
elif [ "$_MT_RC" -eq 128 ]; then
  die "git reported a FATAL error (128) merging ${BASE_SHA:0:12} and ${PR_SHA:0:12} — the repository is incomplete or an object is unreadable, which is what a truncated or shallow fetch leaves behind. This is NOT an old git and NOT a conflict; fetch both sides in full"
else
  die "git merge-tree --write-tree exited ${_MT_RC} — the option is unavailable on this runner (it needs git >= 2.38). Refusing: falling back to comparing the PR head is the defect this subject exists to remove"
fi
```

Also correct the FOUR OUTCOMES comment above it to the six the spec now records.

- [ ] **Step 4:** full shell rung + shellcheck; raise `FLOOR_shell`. Mutations: drop the
  rc-128 branch → the unreadable-object case red in the bash suite's `base-gate` cases;
  drop the empty-tree guard → the empty-tree case red there.

- [ ] **Step 5:** commit `fix(#130): rc 128 is a corrupt repository, and an empty merged tree is not a verdict`

---

---

### Task 2: the job moves to its own trusted-event workflow

Implements R3, R4 and R6.

**Files:**
- Create: `.github/workflows/base-gate.yml`, `.forgejo/workflows/base-gate.yml`
- Modify: `.github/workflows/validate.yml` — delete lines 6–17 (the
  `pull_request_target:` trigger and its comment) and the whole `base-gate:` job
  (lines 73–124); same shape in `.forgejo/workflows/validate.yml`
- Modify: `scripts/base-gate.sh` line 90 (`CI_FILES`)
- Test: `tests/test-scripts.sh`, `tests/floors.env`

**Interfaces:**
- Consumes: `PR_TREE` from Task 1 (arm 3b's presence half reads it).
- Produces: `CI_FILES` gains the two new workflow paths, so deleting one is a `GONE:` red.

- [ ] **Step 1: Write the failing test**

```bash
# A base-gate WORKFLOW file deleted by the PR is the gate removed, and the
# base's own copy is what runs, so it can and must catch that (R6).
mkdir -p "$BGD/.github/workflows"
printf 'name: base-gate\non:\n  pull_request_target:\n' > "$BGD/.github/workflows/base-gate.yml"
git -C "$BGD" add -A >/dev/null 2>&1 && git -C "$BGD" commit -qm "add the base-gate workflow"
BG_BASE2="$(git -C "$BGD" rev-parse HEAD)"
git -C "$BGD" checkout -q -b delgate "$BG_BASE2"
git -C "$BGD" rm -q .github/workflows/base-gate.yml && git -C "$BGD" commit -qm delgate
BG_OUT="$(bash "$BG" --base "$BG_BASE2" --pr delgate --repo "$BGD" 2>&1)"; BG_RC=$?
check "base-gate: a DELETED base-gate workflow is refused by name (R6)" \
  "$(printf '%s' "$BG_OUT" | grep -q 'GONE: .github/workflows/base-gate.yml' && echo 0 || echo 1)"
```

- [ ] **Step 2: Run it, verify it fails correctly**

Run: `bash tests/test-scripts.sh 2>&1 | grep -E 'R6|GONE: .github'`
Expected: FAIL — the gate is silent about the deletion, because `CI_FILES` does not name
the file yet. Not a fixture error.

- [ ] **Step 3: Minimal implementation**

3a. `scripts/base-gate.sh` line 90:

```bash
CI_FILES=".github/workflows/validate.yml .forgejo/workflows/validate.yml .github/workflows/base-gate.yml .forgejo/workflows/base-gate.yml"
```

The rung half of arm 3b finds no `gate-suite.sh` token in a base-gate workflow and
therefore asserts nothing about it; the presence half is what this adds.

3b. Create `.github/workflows/base-gate.yml`:

```yaml
name: base-gate

# ONLY the trusted event, and that is the whole mechanism. Under
# `pull_request` this file AND scripts/base-gate.sh would both be read from
# the PR head — the self-judging loop #108 exists to break. The job used to
# live in validate.yml behind `if: github.event_name == 'pull_request_target'`;
# a workflow that never receives the untrusted event cannot run under it at
# all, which is a structural guard rather than a string a reviewer must read.
#
# It also removes a measured duplicate: with both triggers on validate.yml,
# EVERY push produced two full runs of the ~4.5 minute suite (PR #132, head
# 0501ec7: runs 35081274929 and 35081274847, both green, both complete).
on:
  pull_request_target:

jobs:
  base-gate:
    runs-on: ubuntu-latest
    # Least privilege, and not boilerplate on this event: the token is the
    # BASE repo's, and the subject is untrusted code. The job only reads git.
    permissions:
      contents: read
    steps:
      - uses: actions/checkout@v4
        with:
          ref: ${{ github.event.pull_request.base.sha }}
          # FULL history. `git merge-tree` needs a merge base, and a depth-1
          # checkout has no ancestors to find one in (#130).
          fetch-depth: 0
      - name: Fetch the PR head (never checked out)
        run: |
          set -e
          # NOT --depth=1: a truncated fetch leaves objects merge-tree cannot
          # read, and that failure returns the same rc as a conflict.
          git fetch --no-tags origin \
            "${{ github.event.pull_request.head.sha }}"
      - name: Trusted base-ref gate (#108)
        run: |
          set -e
          # BOOTSTRAP: a pull_request_target workflow is read from the BASE
          # branch, so a base without the script exits 127, which reads as a
          # broken runner rather than "no gate here yet" (measured on Forgejo,
          # task 483). #108 has landed, so this line now means the gate was
          # DELETED from the base — reported, and the delete arm in the base's
          # own copy is what turns that red.
          if [ ! -f scripts/base-gate.sh ]; then
            echo "BASE_GATE_BOOTSTRAP: the base ref carries no scripts/base-gate.sh"
            exit 0
          fi
          bash scripts/base-gate.sh \
            --base "${{ github.event.pull_request.base.sha }}" \
            --pr  "${{ github.event.pull_request.head.sha }}"
```

3c. Create `.forgejo/workflows/base-gate.yml`: byte-identical except
`uses: https://github.com/actions/checkout@v4` (this repo's header rule — a bare name
resolves against DIFFERENT code on `data.forgejo.org`) and a note that whether this forge
fires `pull_request_target` at all is still unmeasured.

3d. Delete from both `validate.yml`: the `pull_request_target:` trigger with its comment
block, and the entire `base-gate:` job.

- [ ] **Step 4: Run tests, verify pass + no regressions vs baseline**

Run: `bash scripts/gate-suite.sh shell`, then `python3 scripts/validate_plugin.py`
Expected: the R6 check passes. **`check_base_gate` now FAILS** — it still looks for the
job in `validate.yml`. That is Task 3 and is expected here; record it in the commit
message rather than working around it.

- [ ] **Step 5: Commit**

```bash
git add .github/workflows .forgejo/workflows scripts/base-gate.sh tests/test-scripts.sh tests/floors.env
git commit -m "fix(#131): the base-gate runs from its own trusted-event workflow"
```

---

### Task 3: `check_base_gate` follows the job

Implements R5.

**Files:**
- Modify: `scripts/validate_plugin.py` — `_CI_FILES` region (line 3538) gains a sibling
  tuple; `check_base_gate` lines 3956–4134
- Test: `tests/test_validate_plugin.py` — `BaseGateTest`
- Modify: `tests/floors.env`

**Interfaces:**
- Produces: `_BASE_GATE_FILES` — the two workflow paths `check_base_gate` reads.
- Consumes: nothing from Tasks 1–2 beyond the files they created.

**ALSO IN THIS TASK, 2 of 2 (amendment, 2026-09-16 — from the Task 1/1a review).**
`check_base_gate`'s claim-4 token list (`FLOOR_`, `extract_checks`, `CORE_FILES`,
`is_core_path`, `BASE_GATE_FAILED`, `die `) contains nothing from the merge-tree
classifier, so deleting that whole block — the subject the four arms now read — would be
caught only by the bash suite. The claim's own docstring says it exists "to catch deletion
of the arm". Add `merge-tree` and `PR_TREE` to that list, and mutation-check by deleting
the classifier block: it must go red **in `check_base_gate`**, not only in the bash suite.

**ALSO IN THIS TASK, 1 of 2 (amendment, 2026-09-16).** Task 1 turned two existing `BaseGateTest`
cases red and could not fix them under its own hard constraints: their mutation harness
hardcodes the literal `extract_checks "$PR_SHA"`, which Task 1 changed to `$PR_TREE`.
Measured after `5cb8a20`: `test_a_comment_does_not_satisfy_an_arm_pin` and
`test_an_arm_deleted_from_the_script_fires` both fail, and the python rung is red from
Task 1 until this task lands. Repair them here by keying the harness on a literal that is
present in the current file, and prefer an anchor that is not a subject name — the whole
point of Task 1 is that the subject moves, so a harness pinned to it breaks again next
time. This is a mechanical correction; the plan is amended rather than re-gated.

- [ ] **Step 1: Write the failing tests**

In `BaseGateTest`, one per claim, each asserting `check_base_gate` fires:

```python
def test_base_gate_workflow_subscribing_to_pull_request_is_refused(self):
    # The structural replacement for the old `if:` string pin: a workflow
    # that also subscribes to `pull_request` runs the trusted job under the
    # untrusted event, which is the inversion measured on Forgejo (task 483).
    self.assertFires("base-gate.yml", lambda p: p.write_text(
        p.read_text().replace("on:\n  pull_request_target:\n",
                              "on:\n  pull_request:\n  pull_request_target:\n")),
        "pull_request")

def test_a_leftover_base_gate_job_in_validate_yml_is_refused(self):
    # Claim 5: the job must not ALSO remain where the untrusted event reaches
    # it. Moving a job is two edits, and only one of them is visible here.
    self.assertFires(".github/workflows/validate.yml", lambda p: p.write_text(
        p.read_text() + "\n  base-gate:\n    runs-on: ubuntu-latest\n"),
        "still carries a `base-gate:` job")
```

(The exact `assertFires` helper signature already used by `BaseGateTest` is what these
follow; read it before writing, and match it.)

- [ ] **Step 2: Run them, verify they fail correctly**

Run: `python3 -m unittest tests.test_validate_plugin.BaseGateTest -v`
Expected: both FAIL because `check_base_gate` reads `validate.yml` and finds no job at
all — a different failure from the one asserted. That mismatch is the signal that the
check has not been ported yet, not that the test is wrong.

- [ ] **Step 3: Minimal implementation**

3a. Beside `_CI_FILES` (line 3544):

```python
# The trusted-gate workflows. NOT part of _CI_FILES: check_suite_floors
# demands every rung in every file that tuple lists, and these run no rungs.
_BASE_GATE_FILES = (
    ".github/workflows/base-gate.yml",
    ".forgejo/workflows/base-gate.yml",
)
```

3b. In `check_base_gate`, replace the wiring loop's header:

```python
    for rel in _BASE_GATE_FILES:
        f = root / rel
        if not f.is_file():
            continue  # a forge this checkout does not configure
```

(the `f.name != "validate.yml"` filter goes with it)

3c. Replace the trigger claim with the two-sided structural one:

```python
        if not re.search(r"^\s*pull_request_target:", live, re.M):
            problems.append(
                f"{rel}: the workflow lacks `pull_request_target:` — without "
                f"it the workflow file and the gate script both come from the "
                f"PR head, which is the self-judging loop #108 exists to break")
        if re.search(r"^\s*pull_request:", live, re.M):
            problems.append(
                f"{rel}: the workflow ALSO subscribes to `pull_request:` — the "
                f"trusted job would then run under the untrusted event, where "
                f"this file and base-gate.sh both come from the PR head "
                f"(measured on Forgejo, task 483). Subscribing to one event is "
                f"the guard; an `if:` string is one a reviewer has to read")
```

3d. Delete the job-level `if:` claim (lines ~4146 region, the `if_m` block): the job no
longer carries one, and 3c is strictly stronger — it refuses the untrusted event at the
file level rather than inside the job.

3e. Add claim 5, after the per-file loop:

```python
    # The job must not ALSO remain in validate.yml, where `pull_request`
    # reaches it. Moving a job is two edits and a reviewer sees one diff.
    for rel in (".github/workflows/validate.yml",
                ".forgejo/workflows/validate.yml"):
        f = root / rel
        if not f.is_file():
            continue
        live = "".join(ln + "\n" for ln in f.read_text(encoding="utf-8").splitlines()
                       if not ln.strip().startswith("#"))
        if re.search(r"^  base-gate:", live, re.M):
            problems.append(
                f"{rel}: still carries a `base-gate:` job. It moved to its own "
                f"pull_request_target-only workflow (#131); a copy left here "
                f"runs the trusted gate under the untrusted event")
```

3f. Update the docstring's numbered claims to match, and the two comment blocks that
describe the `if:` guard.

- [ ] **Step 4: Run tests, verify pass + no regressions vs baseline**

Run: `bash scripts/gate-suite.sh python` and `python3 scripts/validate_plugin.py`
Expected: validator "all contracts hold"; python count = baseline 375 + new cases; raise
`FLOOR_python` in this commit.

Mutations, each restored byte-identical with `__pycache__` purged between:

| mutation | expected red |
|---|---|
| drop the `pull_request:` refusal (3c second half) | the subscribing-to-pull_request case, **in `check_base_gate`** |
| drop claim 5 (3e) | the leftover-job case, in `check_base_gate` |
| point `_BASE_GATE_FILES` at a nonexistent path | every wiring case, in `check_base_gate` — the control that the loop runs at all |

- [ ] **Step 5: Commit**

```bash
git add scripts/validate_plugin.py tests/test_validate_plugin.py tests/floors.env
git commit -m "fix(#131): check_base_gate pins the workflow's on: block, not a job guard"
```

---

### Task 4: `ops-reverify.sh` matches the header whole

Implements R7 (#128).

**Files:**
- Modify: `scripts/ops-reverify.sh:94`
- Test: `tests/test-scripts.sh` — the existing
  `-- Case: ops-reverify.sh dates rows` block
- Modify: `tests/floors.env`

**Interfaces:** none shared; this task is independent of Tasks 1–3 and could be reviewed
alone.

- [ ] **Step 1: Write the failing test**

```bash
# A task id of `Gate` with criterion `Criterion` is a ledger ops-task.sh
# permits, and the prefix filter dropped it from the sweep while counting it
# as "not a 4-cell row" — the wrong reason for the wrong row. caps.sh was
# fixed in #126; this is its sibling parser.
printf '| Gate | Criterion | ev @no-commit | FAIL |\n' >> "$RVP/.operator/VERDICTS.md"
RV_OUT="$(bash "$SCRIPTS/ops-reverify.sh" --ledger "$RVP/.operator/VERDICTS.md" 2>&1)"
check "#128 a row whose task id is Gate is DATED, not dropped by the header filter" \
  "$(printf '%s' "$RV_OUT" | grep -q '| Gate | ' && echo 0 || echo 1)"
check "#128 CONTROL: the real header line is still skipped" \
  "$(printf '%s' "$RV_OUT" | grep -q 'Criterion | Evidence | PASS/FAIL' && echo 1 || echo 0)"
```

(`$RVP` is that case block's existing scratch project; read the block and match its
variable names before writing.)

- [ ] **Step 2: Run it, verify it fails correctly**

Run: `bash tests/test-scripts.sh 2>&1 | grep '#128'`
Expected: the first check FAILs (the row is absent from the output), the control passes.

- [ ] **Step 3: Minimal implementation**

`scripts/ops-reverify.sh:94`:

```bash
    # The header is matched WHOLE, not by prefix (#128). `"| Gate | Criterion |"*`
    # discards any row whose id is `Gate` and whose criterion is `Criterion`, and
    # ops-task.sh permits that id. The full header cannot collide: its fourth cell
    # is `PASS/FAIL`, which the verdict enum below refuses. Same fix as caps.sh.
    case "$row" in
      "| Gate | Criterion | Evidence | PASS/FAIL |" | "|---"*) continue ;;
    esac
```

- [ ] **Step 4: Run tests, verify pass + no regressions vs baseline**

Run: `bash scripts/gate-suite.sh shell`, `/tmp/shellcheck-v0.10.0/shellcheck scripts/ops-reverify.sh`
Expected: both checks pass, shellcheck rc 0. Mutation: restore the prefix form → the
`#128` case goes red in the bash suite. Raise `FLOOR_shell` in this commit.

- [ ] **Step 5: Commit**

```bash
git add scripts/ops-reverify.sh tests/test-scripts.sh tests/floors.env
git commit -m "fix(#128): ops-reverify matches the ledger header whole, not by prefix"
```

---

### Task 5: release bookkeeping and the coupling row

**Files:**
- Modify: `.claude-plugin/plugin.json` (version), `CHANGELOG.md` (new
  `## [0.11.13] - 2026-09-16` as the newest heading), `CLAUDE.md` (the base-gate coupling
  row)

**Interfaces:** consumes nothing; it records what Tasks 1–4 produced.

- [ ] **Step 1: There is no failing test to write**

The gate here is `scripts/release_gate.py`, which already exists and already fails when
the version and the newest heading disagree. Verify that by running it before the edit:
`python3 scripts/release_gate.py v0.11.13` must FAIL against `plugin.json` still at
0.11.12. That is this task's red.

- [ ] **Step 2: Implementation**

2a. `plugin.json` version → `0.11.13`.

2b. `CHANGELOG.md` gains `## [0.11.13] - 2026-09-16` above `## [0.11.12]`, with one
bullet per issue: the subject change and the four refusals (#130), the workflow split and
the measured duplicate-run cost (#131), the header match (#128).

2c. `CLAUDE.md`'s base-gate coupling row gains, inside the existing row:

> The SUBJECT is the tree `git merge-tree --write-tree` produces, never the PR head — a
> PR merely BEHIND the base is not a weakening (#130, measured). Conflict, unreadable
> object and an unavailable `merge-tree` are three DISTINCT rc-2 refusals: a conflict and
> a truncated fetch return the same rc, and only a tree sha on stdout line 1 separates
> them. The job lives in `.github/workflows/base-gate.yml` / the Forgejo mirror,
> subscribed to `pull_request_target` ONLY — the `on:` block is the guard, and
> `check_base_gate` refuses a `pull_request:` subscription there as well as a leftover
> `base-gate:` job in either `validate.yml`.

- [ ] **Step 3: Verify**

Run, in order:

```
python3 scripts/release_gate.py v0.11.13
for r in validator python shell workflows compress; do bash scripts/gate-suite.sh "$r"; done
/tmp/shellcheck-v0.10.0/shellcheck scripts/*.sh scripts/lib/*.sh tests/test-scripts.sh
bash scripts/base-gate.sh --base origin/main --pr HEAD
```

Expected: release gate OK; five `GATE_OK` lines at their floors; shellcheck rc 0;
`BASE_GATE_PASSED` with the merged-tree sha in the banner and every enforcer-core touch
named in the delta report.

- [ ] **Step 4: Commit**

```bash
git add .claude-plugin/plugin.json CHANGELOG.md CLAUDE.md
git commit -m "0.11.13: the base-gate judges the merge result, and runs from its own workflow"
```

---

## Plan self-review

**Spec coverage.** R1 → Task 1 (3c's eight sites). R2 → Task 1 (3a's classifier, Step 1's
conflict cases). R3 → Task 2 (3b's `fetch-depth: 0` and the undepthed fetch). R4 → Task 2
(3b, 3c, 3d). R5 → Task 3 (3a–3f). R6 → Task 2 (3a's `CI_FILES`, Step 1's case). R7 →
Task 4. S1/S2 → Task 1 Step 1. S3 → Task 1 Step 1. S4 → observable only after merge, and
recorded as such in Task 5's verification, not asserted by a test. S5/S6 → the mutation
tables in Tasks 1, 3, 4. S7 → Task 5 Step 3. S8 → Task 4.

**Placeholder scan.** No TBD/TODO. Two tasks say "read the existing block and match its
variable names" (Task 3 Step 1 on `assertFires`, Task 4 Step 1 on `$RVP`) — that is a
lookup of an existing signature, not an undefined interface, and the alternative is
transcribing a helper the implementer will open anyway.

**Type consistency.** `PR_TREE` and `_is_sha` are defined in Task 1 and used only there;
`CI_FILES` in Task 2 is the same shell variable Task 1 leaves untouched;
`_BASE_GATE_FILES` is defined and consumed inside Task 3. No name appears in two spellings.

**Known deliberate red between tasks.** Task 2 leaves `check_base_gate` failing until
Task 3 lands. It is recorded in Task 2 Step 4 and in its commit message. Tasks 1–4 are
individually reviewable; only the branch as a whole is green.
