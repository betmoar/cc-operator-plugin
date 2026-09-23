#!/usr/bin/env bash
# base-gate.sh — the enforcer, judged by code the PR cannot edit (#108).
#
# A pull request here checks out its own head and runs the validator and the
# suites from THAT checkout — so a branch that neuters a pin, drops a check
# from the registry, or lowers a floor edits the very code that grades it.
# The sibling project's sharpest incident is this exact shape: a guard that
# SAW both violations, NAMED them, then waved itself through.
#
# This script is the trusted half. It runs from the BASE checkout (via a
# `pull_request_target` job that never checks out the PR head), reads the
# BASE copy of the enforcer, and compares the PR against it. Trusted code,
# untrusted subject. Every copy it reads is reached through `git show`, so
# PR bytes are never on disk, never sourced, never executed.
#
# What it can and cannot catch — known boundaries, on purpose:
#   CATCHES (hard red):
#     - THE SUBJECT is the tree a MERGE would produce, not the PR head — so a
#       PR that is merely BEHIND the base is not reported as deleting what
#       the base added (#130). Conflict, unreadable object, corrupt
#       repository, empty merge result, an unrecognised merge-tree output
#       shape (rc 0 with no tree sha), an old git with no --write-tree, and any
#       exit status this gate does not recognise are SEVEN distinct rc-2
#       refusals; none of them is a weakening.
#     - a floor LOWERED, REMOVED, or hidden behind a DUPLICATE key (the file
#       is sourced, so the last assignment is the effective one), or a
#       floors.env line of ANY shape other than `FLOOR_<name>=<digits>` (the
#       file is sourced, so every line is executed; a line this gate cannot
#       read is a value it cannot compare — three fail-opens, see arm 1)
#     - a check REMOVED from the validator's CHECKS registry, or the registry
#       REBOUND after the tuple (python runs the last assignment)
#     - a `gate-suite.sh <rung>` step REMOVED from a CI file, or a CI file
#       removed — the CI file is the one enforcer the PR-side validator
#       pins from the PR's own copy (check_suite_floors), so the base must
#       hold the rung set itself
#     - an enforcer file (validator, wrapper, this script) or any tests/ path
#       that exists at the base and NOT at the PR ref — deleted, renamed, or
#       moved; the arm asks the tree, so a swap that holds the count equal is
#       caught too
#     - a forged marker line planted in the PR's diff (the anti-wormhole)
#   CANNOT CATCH (needs judgment — routed to the human at merge time):
#     - a check REWRITTEN in place (body neutered, registry intact). The
#       DELTA REPORT names every enforcer-core file touched, and the human
#       merge — no auto-merge exists here — is the adjudicator. #112
#       (holdout) is the structural version of this gap: trusted code
#       judging arbitrary rewrites is a second copy of the same beliefs.
#
# Polarity: FAILS CLOSED everywhere. An unreadable base, an unresolvable ref,
# a missing registry — every one is RED. Falling back to the branch's copy is
# the original bug wearing a fallback's clothes.
#
# Usage (from the BASE checkout; the PR head is only fetched):
#   scripts/base-gate.sh [--base <ref>] [--pr <ref>] [--repo <dir>]
#     --base  the trusted ref (default: origin/main)
#     --pr    the ref under test (default: HEAD)
#     --repo  the git dir (default: the script's repo — the BASE checkout)
#
# Exit: 0 = the PR does not weaken the base enforcer; 1 = it does; 2 = usage
# or an unreadable base (which is also a refusal — nothing runs).

set -uo pipefail

# mktemp template — one declaration, used by every mktemp below.
_TMPDIR_T="${TMPDIR:-/tmp}"

die() { echo "base-gate: $1" >&2; exit 2; }
fail() { FAILS=$((FAILS + 1)); echo "BASE_GATE_FAILED: $1" >&2; }

# _mk <label> -> a temp file, or a rc-2 refusal NAMING THE REAL CAUSE (#135).
# Every mktemp here was unchecked. On failure -- a full or read-only TMPDIR, a
# restrictive runner sandbox -- the variable stayed EMPTY, the redirection that
# followed failed, and the classifier read `$?` as 1 with no tree sha: the
# rc-1-no-sha branch, whose message tells the operator to go fix a truncated
# fetch. The fetch is fine. That is the same two-causes-one-message defect the
# rc-128 branch was split out to remove, one layer down.
#
# THE SUBSHELL IS THE WHOLE TRAP. `X="$(_mk foo)"` runs _mk in a SUBSHELL, so a
# `die` in here exits THAT shell, not the script -- the parent would sail on
# with X empty, which is the very bug being fixed. The status does propagate to
# the assignment, so every call site pairs with `|| exit 2` and the message
# below has already reached stderr. Do not "simplify" that away.
_mk() {
  mktemp "${_TMPDIR_T}/basegate.${1}.XXXXXX" 2>/dev/null && return 0
  echo "base-gate: could not create a temp file under '${_TMPDIR_T}' — this gate needs a writable TMPDIR. This is NOT a repository problem and must not be read as one: no fetch, no object and no merge result is implicated" >&2
  exit 2
}

# --- args ---------------------------------------------------------------------
BASE_REF="origin/main"
PR_REF="HEAD"
REPO=""
while [ $# -gt 0 ]; do
  case "$1" in
    --base)  [ $# -ge 2 ] || die "--base requires a ref"; BASE_REF="$2"; shift 2 ;;
    --base=*)  BASE_REF="${1#--base=}"; shift ;;
    --pr)    [ $# -ge 2 ] || die "--pr requires a ref"; PR_REF="$2"; shift 2 ;;
    --pr=*)    PR_REF="${1#--pr=}"; shift ;;
    --repo)  [ $# -ge 2 ] || die "--repo requires a directory"; REPO="$2"; shift 2 ;;
    --repo=*)  REPO="${1#--repo=}"; shift ;;
    *) die "unknown argument '$1' (usage: base-gate.sh [--base <ref>] [--pr <ref>] [--repo <dir>])" ;;
  esac
done

# The enforcer core. ONE declaration, read by the arms below — a second
# hardcoded copy of this list beside it is how the two drift and the gate
# silently stops covering a file it names. Two sets, because they answer
# different questions:
#   CORE_FILES — deleting one of these IS the gate removed (hard red).
#   CORE_GLOBS — touching one is enforcer-core work the human must see.
CORE_FILES="scripts/validate_plugin.py scripts/gate-suite.sh scripts/base-gate.sh"
CORE_GLOBS="tests/ .github/workflows/ .forgejo/workflows/"
# The CI files that RUN the rungs. Listed here, not derived from a glob: the
# rung arm below asks each one by name at both refs. A forge whose file is
# absent at the BASE is not configured and makes no claim; absent at the PR
# ref while present at the base is the file deleted.
CI_FILES=".github/workflows/validate.yml .forgejo/workflows/validate.yml .github/workflows/base-gate.yml .forgejo/workflows/base-gate.yml"

is_core_path() {  # is_core_path <path> → 0 when the path is enforcer core
  local p="$1" f g
  for f in $CORE_FILES; do [ "$p" = "$f" ] && return 0; done
  for g in $CORE_GLOBS; do [ "${p#"$g"}" != "$p" ] && return 0; done
  return 1
}
# There is deliberately NO is_core_file() companion. It existed while arm 3
# keyed on the diff's status letter, and died with that design: the arm now
# asks the TREE whether each CORE_FILES entry still exists at the PR ref, so
# the set is iterated directly. Left as a comment because "add a helper back"
# is the reflex when reading `for _f in $CORE_FILES` and wondering where the
# predicate went — the answer is that a predicate over a diff STATUS was the
# bug (a rename reports R, never D, and the file is gone all the same).

FAILS=0

# --- resolve refs (fail closed: an unresolvable ref is a refusal) -------------
# In the pull_request_target job the PR is FETCHED into the base checkout —
# FETCH_HEAD is the natural ref; a maintainer's local run passes --pr <branch>.
if [ -n "$REPO" ]; then
  [ -d "$REPO/.git" ] || [ -f "$REPO/.git" ] \
    || die "--repo '$REPO' is not a git worktree — refusing"
  git -C "$REPO" rev-parse --absolute-git-dir >/dev/null 2>&1 \
    || die "could not resolve the git dir of '$REPO' — refusing"
else
  REPO="$(pwd)"
  git -C "$REPO" rev-parse --absolute-git-dir >/dev/null 2>&1 \
    || die "not a git repository (and no --repo given) — refusing"
fi

# rev-parse each side; a ref that does not exist HERE is a hard error. Note
# the PR ref is NOT checked out — `git -C` + `git show` only.
git -C "$REPO" rev-parse --verify --quiet "${BASE_REF}^{commit}" >/dev/null 2>&1 \
  || die "base ref '${BASE_REF}' does not resolve in '$REPO' — refusing to fall back to any other copy (fail closed)"
PR_SHA="$(git -C "$REPO" rev-parse --verify --quiet "${PR_REF}^{commit}" 2>/dev/null)" \
  || die "pr ref '${PR_REF}' does not resolve in '$REPO' — nothing to gate"
# CHECKED, though the verify above already passed: this is a SECOND call, so a
# ref deleted or repacked in between yields an empty BASE_SHA that every arm
# below would then compare against. Cheap to guard, silent if not (#137).
BASE_SHA="$(git -C "$REPO" rev-parse --quiet --verify "${BASE_REF}^{commit}")" \
  || die "base ref '${BASE_REF}' stopped resolving between the two rev-parse calls — refusing rather than gating against an empty sha"
[ -n "$BASE_SHA" ] \
  || die "base ref '${BASE_REF}' resolved to an EMPTY sha — refusing (every arm below would compare against nothing)"

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
# EIGHT OUTCOMES — ONE accept and SEVEN refusals — and rc alone does not
# separate them. THE COUNT HAS BEEN WRONG TWICE, both times for the same
# reason: the prose was updated to the tally that was true BEFORE the same
# commit changed the branch structure. It read six/five until the rc-0 arm was
# seen to SPLIT into accept and empty-tree-refuse (seven/six), and seven/six
# until 397d6d3 split the catch-all into rc 129 and everything-else — which is
# the eighth. Count the branches, do not trust this comment: at HEAD there are
# 7 top-level if/elif/else arms plus the nested empty-tree die inside the
# first. Nothing pins this number, which is why it survived twice (#132
# review),
# AMENDED after the first cut folded two of these wrong — R2 in
# docs/dev/2026-09-16-base-gate-subject-spec.md):
#   rc 0 + a sha + a NON-EMPTY tree -> clean merge, this is the subject
#   rc 0 + a sha + an EMPTY tree    -> the PR's root tree object is ABSENT;
#                                      the base always carries files, so a
#                                      clean merge whose result is empty
#                                      cannot be a legitimate PR
#   rc 0 + no sha                   -> an output shape this gate does not
#                                      understand
#   rc 1 + a sha                    -> a real CONFLICT (the stages follow
#                                      the tree)
#   rc 1 + no sha                   -> an object could not be READ, which is
#                                      what a truncated shallow fetch looks
#                                      like — the same shape that silently
#                                      disarmed the marker arm in #125. It
#                                      must never read as a conflict. Real
#                                      git does not reach it from here (#133);
#                                      the suite forces it with a PATH shim.
#   rc 128                          -> a FATAL git error: the repository is
#                                      incomplete or an object is unreadable
#                                      (a truncated or shallow fetch). This is
#                                      NOT an old git and NOT a conflict — the
#                                      shape that bit the #125 marker arm.
#   rc 129                          -> --write-tree unavailable (old git)
#   any OTHER rc                    -> an exit status this gate does not
#                                      recognise. NOT folded into the old-git
#                                      message: a killed process or a future
#                                      git's new code is neither (#132 review)
# Every non-clean case is a rc 2 refusal: the gate says it cannot judge,
# never that the PR weakens anything. A conflicted PR cannot be merged by
# GitHub either way, so refusing to judge it costs nothing and claims nothing.
_is_sha() {  # _is_sha <string> → 0 when it is 40 or 64 lowercase hex chars
  case "${1:-}" in "" | *[!0-9a-f]*) return 1 ;; esac
  [ "${#1}" -eq 40 ] || [ "${#1}" -eq 64 ]
}
_MT_OUT="$(_mk mt)" || exit 2
git -C "$REPO" merge-tree --write-tree "$BASE_SHA" "$PR_SHA" > "$_MT_OUT" 2>/dev/null
_MT_RC=$?
PR_TREE="$(head -1 "$_MT_OUT" 2>/dev/null)"
rm -f "$_MT_OUT"
if [ "$_MT_RC" -eq 0 ] && _is_sha "$PR_TREE"; then
  # A CLEAN merge whose result is EMPTY is not a clean merge — the base
  # always carries files, so an empty result means an input was incomplete.
  # Measured 2026-09-16: deleting the PR commit's root tree object yields
  # rc 0 and git's empty tree, which every arm then reads as "every
  # enforcer file is gone".
  if [ -z "$(git -C "$REPO" ls-tree "$PR_TREE" 2>/dev/null | head -1)" ]; then
    die "the merge of ${BASE_SHA:0:12} and ${PR_SHA:0:12} produced an empty tree — the base carries files, so this means the repository is incomplete (a missing tree object takes exactly this shape), not that the PR deleted everything. Refusing rather than reporting every enforcer file as GONE"
  fi
elif [ "$_MT_RC" -eq 0 ]; then
  die "merge-tree reported success but printed no tree object — an output shape this gate does not understand; refusing rather than guessing at a subject"
elif [ "$_MT_RC" -eq 1 ] && _is_sha "$PR_TREE"; then
  die "the pr ref '${PR_REF}' conflicts with the base ref '${BASE_REF}' — there is no merge result to judge, so this gate refuses rather than reporting a weakening it cannot see. Rebase or merge the base into the PR and re-run"
elif [ "$_MT_RC" -eq 1 ]; then
  die "merge-tree could not read an object for ${BASE_SHA:0:12}..${PR_SHA:0:12} — the repository is incomplete (a truncated or shallow fetch takes exactly this shape). This is NOT a conflict and must not be read as one; fetch both sides in full"
elif [ "$_MT_RC" -eq 128 ]; then
  die "git reported a fatal error (128) merging ${BASE_SHA:0:12} and ${PR_SHA:0:12} — the repository is incomplete or an object is unreadable, which is what a truncated or shallow fetch leaves behind. This is NOT an old git and NOT a conflict; fetch both sides in full"
elif [ "$_MT_RC" -eq 129 ]; then
  die "git merge-tree --write-tree exited 129 — the option is unavailable on this runner (it needs git >= 2.38). Refusing: falling back to comparing the PR head is the defect this subject exists to remove"
else
  # ANY OTHER STATUS IS NOT AN OLD GIT. The catch-all used to say "needs git
  # >= 2.38" for every rc it did not recognise — a killed process (130, 137),
  # a future git's new failure code, anything — which is the same
  # two-causes-one-message defect the rc-128 branch above was split out to
  # remove (PR #132 review). 129 is the documented old-option status and it
  # keeps that message; everything else says only what is known.
  die "git merge-tree --write-tree exited ${_MT_RC} — an exit status this gate does not recognise (129 is the old-git case; 1 and 128 are handled above). Refusing rather than guessing at a cause: falling back to comparing the PR head is the defect this subject exists to remove"
fi

echo "== base-gate: trusted base ${BASE_SHA:0:12} vs pr ${PR_SHA:0:12} (merged tree ${PR_TREE:0:12}) =="

# --- base copy readable (fail closed BEFORE anything compares) ----------------
# The half the sibling incident turned green: if the trusted copy cannot be
# read, the run is RED, not "skipped".
for f in scripts/validate_plugin.py tests/floors.env; do
  git -C "$REPO" show "${BASE_SHA}:${f}" >/dev/null 2>&1 \
    || die "cannot read ${f} at the base ref — the trusted copy is unreadable and the gate fails closed"
done
git -C "$REPO" show "${BASE_SHA}:scripts/validate_plugin.py" 2>/dev/null | grep -q '^CHECKS = (' \
  || die "no CHECKS registry at the base ref — the trusted copy is not a shape this gate understands (fail closed)"

# --- change list (the PR's own view of what it touched) -----------------------
# Changed = diff base...pr (THREE dots — merge-base..pr, the PR's own commits
# since it branched). This includes files the PR DELETED (state D) — a
# deleted enforcer file is the loudest possible delta and must be reported.
# TWO dots would compare the two TREES, which attributes the BASE's own work
# to the PR: this repo raises a floor and adds a tests/ file in nearly every
# PR, so a two-dot diff against an unrebased branch reports the base's raise
# as the PR LOWERING it and the base's new file as the PR DELETING it — the
# same false-authorship defect arms 1-3b were just fixed for (#130), one
# level up, in the only human-facing half, and now the ONLY signal on such a
# PR because the arms correctly stay silent. Measured 2026-09-16 on the
# `innocent`/`moved` fixture: two-dot named `M tests/floors.env` and
# `D tests/test-two.sh` (both the base's own commits); three-dot named
# neither.
CHANGED_TMP="$(_mk changed)" || exit 2
DIFFSTAT_TMP="$(_mk diffstat)" || exit 2
trap 'rm -f "$CHANGED_TMP" "$DIFFSTAT_TMP"' EXIT
if ! git -C "$REPO" diff --name-status "${BASE_SHA}...${PR_SHA}" -- > "$DIFFSTAT_TMP" 2>/dev/null; then
  die "git diff base...pr failed — refusing (a diff failure must not read as 'no changes')"
fi
# name-status: one "<status>\t<path>" per line. Strip the rename/copy dest
# (second tab field) — the DEST is the path that exists on the PR side.
awk -F'\t' '{
  if (NF >= 2) print $1 "|" $2; else print $1 "|";
}' "$DIFFSTAT_TMP" > "$CHANGED_TMP"

# --- arm 1: floors may not go DOWN --------------------------------------------
# The ratchet half. A PR that deletes cases must lower a floor for its own
# branch run to pass — that is exactly the moment this arm exists for.
extract_floors() {  # extract_floors <sha> <out-file>
  git -C "$REPO" show "${1}:tests/floors.env" 2>/dev/null \
    | grep -E '^FLOOR_[A-Za-z0-9_]+=[0-9]+' > "$2"
}
BASE_FLOORS="$(_mk bf)" || exit 2
PR_FLOORS="$(_mk pf)" || exit 2
extract_floors "$BASE_SHA" "$BASE_FLOORS"
extract_floors "$PR_TREE" "$PR_FLOORS"
# THE SHAPE IS CLOSED, NOT THE INSTANCES. gate-suite.sh SOURCES this file, so
# every line it carries is executed, and a line the value-compare below cannot
# parse is a line the runtime still obeys. Three bypasses of that compare, all
# fail-OPEN (BASE_GATE_PASSED, exit 0), measured 2026-09-05 in review:
#     FLOOR_shell=1 # 20       `[0-9]+$` read the trailing comment: 20
#     FLOOR_shell=1 ;: 20      same, through a no-op command
#     FLOOR_shell=$((1))       invisible to ^FLOOR_…=[0-9]+ after a kept
#                              FLOOR_shell=20, so the compare saw 20; sourced: 1
# So at the PR ref a floors.env line is blank, a comment, or EXACTLY
# `FLOOR_<name>=<digits>` — anything else is red, whatever it evaluates to.
# Deliberately strict: a legitimately indented or `export`ed assignment is
# refused too, and the fix is to write it in the one shape (floors.env is
# four lines of that shape under a comment header, by design).
_PR_FLOORS_RAW="$(_mk praw)" || exit 2
if git -C "$REPO" show "${PR_TREE}:tests/floors.env" > "$_PR_FLOORS_RAW" 2>/dev/null; then
  _bad_line="$(grep -vE '^[[:space:]]*(#|$)' "$_PR_FLOORS_RAW" \
               | grep -vE '^FLOOR_[A-Za-z0-9_]+=[0-9]+$' | head -1)"
  if [ -n "$_bad_line" ]; then
    fail "FLOOR: tests/floors.env in the MERGED TREE carries a line that is not blank, a comment, or exactly FLOOR_<name>=<digits> — gate-suite.sh sources every line, so a line this gate cannot read is a value it cannot compare (first offender: ${_bad_line})"
  fi
fi
rm -f "$_PR_FLOORS_RAW"
# a missing PR floors.env is a deleted ratchet — RED, named
if [ ! -s "$PR_FLOORS" ] && [ -s "$BASE_FLOORS" ]; then
  fail "tests/floors.env is gone or empty in the MERGED TREE — the ratchet is deleted"
elif ! diff -q "$BASE_FLOORS" "$PR_FLOORS" >/dev/null; then
  # some floor line changed: any DECREASE or REMOVAL is red.
  #
  # THE EFFECTIVE VALUE IS THE LAST ONE. `gate-suite.sh` reads this file with
  # `. "$FLOORS"` (its line 60), and a shell sources assignments in order —
  # so a file carrying `FLOOR_shell=862` and later `FLOOR_shell=1` enforces
  # 1. An adversarial verifier found that exact bypass on 2026-09-05: the
  # first draft's `grep | grep -oE` collected BOTH values, `[ "$PRV" -lt …]`
  # got a two-line operand, printed "integer expression expected" to stderr,
  # evaluated FALSY — and the run exited 0. A fail-OPEN, which is the one
  # direction this gate may never fail. `tail -1` now takes the value the
  # runtime would actually use, and a duplicate key is additionally reported
  # in its own right (a legitimate floors.env never restates a key, and the
  # only reason to add one is to hide the second value).
  while IFS='=' read -r k v; do
    [ -n "$k" ] || continue
    _n_decl="$(grep -cE "^${k}=" "$PR_FLOORS")"
    PRV="$(grep -E "^${k}=" "$PR_FLOORS" | tail -1 | grep -oE '[0-9]+$')"
    if [ -z "$PRV" ]; then
      fail "FLOOR: ${k} removed in the MERGED TREE (base ${v})"
      continue
    fi
    if [ "$_n_decl" -gt 1 ]; then
      fail "FLOOR: ${k} is declared ${_n_decl} times in the MERGED TREE — the LAST assignment is the one gate-suite.sh sources, so a restated key hides the value it enforces (effective: ${PRV})"
    fi
    if [ "$PRV" -lt "$v" ]; then
      fail "FLOOR: ${k} lowered ${v} -> ${PRV} — deleting cases requires lowering the floor; the trusted copy catches it here"
    fi
  done < "$BASE_FLOORS"
fi
rm -f "$BASE_FLOORS" "$PR_FLOORS"

# --- arm 2: the CHECKS registry may not SHRINK --------------------------------
# The list half. check_suite_floors already refuses a raw invocation in CI
# files, but nothing refuses a check being DROPPED from the registry — a
# validator with fewer checks reports fewer problems, and nothing counts.
extract_checks() {  # extract_checks <sha> → stdout
  # COMMENTS STRIPPED FIRST. `# check_b,` inside the tuple leaves the token
  # in the raw text while python sees one fewer callable — the registry
  # shrank and a token grep said it did not (found by review, reproduced
  # 2026-09-05). This mirrors validate_plugin.py's own `shell_code()`
  # discipline: a pin over raw text is satisfied by a comment.
  git -C "$REPO" show "${1}:scripts/validate_plugin.py" 2>/dev/null \
    | awk '/^CHECKS = \($/,/^\)$/' \
    | grep -vE '^[[:space:]]*#' \
    | grep -oE 'check_[A-Za-z0-9_]+' | grep -v '^check_$'
}
BASE_CHECKS="$(_mk bc)" || exit 2
PR_CHECKS="$(_mk pc)" || exit 2
extract_checks "$BASE_SHA" > "$BASE_CHECKS"
extract_checks "$PR_TREE" > "$PR_CHECKS"
# ONE BINDING. The extractor reads the tuple BLOCK; python runs the LAST
# assignment. A `CHECKS = (check_x,)` rebound after the full tuple leaves the
# block intact for the extractor and shrinks the registry that actually runs —
# measured fail-OPEN 2026-09-05 (the same shape as the duplicate floor key,
# one file over). Counted on the comment-stripped view at column 0, which is
# where a module-level binding lives; an indented `CHECKS =` inside a function
# would be a rewrite of the runner, and that is #112's gap, not this arm's.
_n_checks_bind="$(git -C "$REPO" show "${PR_TREE}:scripts/validate_plugin.py" 2>/dev/null \
                  | grep -vE '^[[:space:]]*#' | grep -cE '^CHECKS[[:space:]]*=')"
if [ "${_n_checks_bind:-0}" -gt 1 ]; then
  fail "CHECKS: the registry is bound ${_n_checks_bind} times in the MERGED TREE — this gate reads the tuple block, python runs the LAST binding, so a rebinding after the tuple hides the registry that actually runs"
fi
if [ ! -s "$PR_CHECKS" ]; then
  fail "the CHECKS registry is gone or empty in the MERGED TREE — a validator that runs nothing reports nothing"
else
  while IFS= read -r c; do
    [ -n "$c" ] || continue
    if ! grep -qxF "$c" "$PR_CHECKS"; then
      fail "CHECKS: ${c} removed from the registry — every check dropped is a contract unenforced"
    fi
  done < "$BASE_CHECKS"
fi
rm -f "$BASE_CHECKS" "$PR_CHECKS"

# --- arm 3: an enforcer-core file must still EXIST at the PR ref --------------
# ASK THE TREE, NOT THE DIFF. The first draft keyed this arm on the diff's
# status letter (`D` = deleted) and two attacks walked past it, both measured
# on 2026-09-05:
#
#   * `git mv scripts/gate-suite.sh scripts/gate-suite-old.sh` reports R100,
#     never D — the wrapper is gone from the tree and the arm says nothing.
#   * deleting one tests/ file while ADDING a junk one keeps the COUNT equal,
#     and a count is not a set.
#
# A status letter describes an EDIT; the question this arm asks is about the
# RESULTING TREE. So both halves now read `ls-tree` at the PR ref: a core
# file must be present there, and every tests/ path present at the base must
# still be present. A rename is then automatically red (the old path is
# absent) — which is correct: `check_suite_floors` requires
# `gate-suite.sh <rung>` at that exact path in every CI file, so moving it IS
# removing it, whatever git calls the edit.
CORE_TOUCHED="$(_mk core)" || exit 2
: > "$CORE_TOUCHED"
while IFS='|' read -r st path; do
  [ -n "$path" ] || continue
  is_core_path "$path" || continue
  # M/A/D/R/C all count for the REPORT: the human sees every core touch.
  printf '%s %s\n' "$st" "$path" >> "$CORE_TOUCHED"
done < "$CHANGED_TMP"

# The two presence tests. `ls-tree <sha> -- <path>` prints the path when it
# exists at that commit and nothing when it does not; the empty answer is the
# finding here, not a skip.
for _f in $CORE_FILES; do
  if [ -n "$(git -C "$REPO" ls-tree -r --name-only "${BASE_SHA}" -- "$_f")" ] \
     && [ -z "$(git -C "$REPO" ls-tree -r --name-only "${PR_TREE}" -- "$_f")" ]; then
    fail "GONE: ${_f} exists at the base and NOT at the pr ref — the gate itself removed (deleted, renamed, or moved: the path is what CI runs)"
  fi
done

# Every tests/ path present at the base must still be present. Set membership,
# not a count — a swap (one file deleted, one added) leaves the count equal
# and the coverage gone.
_TESTS_BASE="$(_mk tb)" || exit 2
_TESTS_PR="$(_mk tp)" || exit 2
# BOTH REDIRECTS ARE CHECKED, and the BASE side is the one that matters: the
# loop below iterates _TESTS_BASE, so an empty file makes it a NO-OP and every
# tests/ deletion passes silently — a fail-OPEN in a hard-fail arm, which is
# the one direction this gate may never fail. `ls-tree` exiting non-zero on an
# unreadable object is not "the base has no tests/"; it is the gate being
# unable to see, and that is a refusal (#137, PR #132 review).
git -C "$REPO" ls-tree -r --name-only "${BASE_SHA}" -- tests/ > "$_TESTS_BASE" \
  || die "could not list tests/ at the base ref — the trusted side is unreadable, and an empty listing here would read as 'the base has no suites' and pass every deletion (fail closed instead)"
git -C "$REPO" ls-tree -r --name-only "${PR_TREE}"  -- tests/ > "$_TESTS_PR" \
  || die "could not list tests/ in the merged tree — refusing rather than comparing against a listing that may be truncated"
while IFS= read -r _t; do
  [ -n "$_t" ] || continue
  grep -qxF "$_t" "$_TESTS_PR" \
    || fail "GONE: ${_t} exists at the base and NOT at the pr ref — the suites are the enforcer"
done < "$_TESTS_BASE"
rm -f "$_TESTS_BASE" "$_TESTS_PR"

# --- arm 3b: the CI files keep every rung they run at the base ----------------
# The one enforcer the arms above did not reach. `check_suite_floors` pins
# that every CI file runs `gate-suite.sh <rung>` for every rung — from the
# PR's OWN copy of the validator, in the PR's own run. A PR that deletes the
# shell rung from validate.yml and the pin from validate_plugin.py in one
# commit passes its own run, and until this arm the base copy never looked at
# a CI file at all (measured 2026-09-05: rung removed, BASE_GATE_PASSED). So
# the rung SET at the base must survive at the PR ref, per file: a file
# absent at the base is a forge not configured (no claim); absent at the PR
# ref while present at the base is the file deleted (red); present at both,
# every `gate-suite.sh <rung>` token the base runs must still be run.
# Comment-stripped on both sides, the shell_code() discipline.
# EVERY GIT CALL BELOW IS CHECKED, and #140 is the record of why: this arm
# shipped with the same unchecked-listing fail-open #137 fixed one arm up. It
# was written in that commit and the fix did not reach it.
#
# `git show | grep | grep | sort` CANNOT be checked as a pipeline. `pipefail`
# reports the last non-zero status, and `grep` exits 1 on no-match, so an
# unreadable blob and a CI file that legitimately runs no rungs produce the
# same 1. The blob is staged to a file first, and only THAT status is read.
#
# Polarity matches arm 3 exactly: the BASE side is the trusted half, so
# unreadable there is `die` (rc 2 — the gate cannot see, which is never the
# same as "the base runs no rungs"); the PR side is `fail` (rc 1), since a
# PR-side listing we cannot read is a subject we will not clear.
_ci_show() {  # _ci_show <sha> <file> <dest> → 0 when the blob was READ
  git -C "$REPO" show "${1}:${2}" > "$3" 2>/dev/null
}
_ci_rungs_from() {  # _ci_rungs_from <staged-blob> → the rung tokens, one per line
  grep -vE '^[[:space:]]*#' "$1" | grep -oE 'gate-suite\.sh [a-z]+' | sort -u
}
for _ci in $CI_FILES; do
  # The base-side presence probe. An unreadable listing here used to read as
  # "this forge is not configured" and `continue` past the file entirely —
  # the fail-open in its quietest form, since a skipped file makes no claim
  # and prints nothing.
  _CI_AT_BASE="$(git -C "$REPO" ls-tree -r --name-only "${BASE_SHA}" -- "$_ci")" \
    || die "could not list '${_ci}' at the base ref — the trusted side is unreadable, and an empty listing here would read as 'this forge is not configured' and skip the rung check for that file entirely (fail closed instead; #140, the #137 shape at arm 3b)"
  [ -n "$_CI_AT_BASE" ] || continue
  _CI_AT_PR="$(git -C "$REPO" ls-tree -r --name-only "${PR_TREE}" -- "$_ci")" \
    || die "could not list '${_ci}' in the merged tree — refusing rather than reading an unreadable listing as 'the PR deleted this CI file'"
  if [ -z "$_CI_AT_PR" ]; then
    fail "GONE: ${_ci} exists at the base and NOT at the pr ref — the CI file is what runs the rungs"
    continue
  fi
  _RUNGS_PR="$(_mk rungs)" || exit 2
  _RUNGS_BASE="$(_mk rungsb)" || exit 2
  _BLOB_PR="$(_mk ciblobp)" || exit 2
  _BLOB_BASE="$(_mk ciblobb)" || exit 2
  # BASE FIRST and `die`, before anything is compared: with the base list
  # empty the loop below is a no-op and every rung removal passes silently,
  # which is the one direction a hard-fail arm may never take.
  _ci_show "$BASE_SHA" "$_ci" "$_BLOB_BASE" \
    || { rm -f "$_RUNGS_PR" "$_RUNGS_BASE" "$_BLOB_PR" "$_BLOB_BASE"
         die "could not read '${_ci}' at the base ref — the trusted copy is unreadable, and an empty rung set here would read as 'this file runs no suites' and pass every rung removal (fail closed instead; #140)"; }
  if ! _ci_show "$PR_TREE" "$_ci" "$_BLOB_PR"; then
    fail "UNREADABLE: '${_ci}' in the merged tree could not be read — the rung set it runs cannot be compared, and an empty one would clear every rung the base runs"
    rm -f "$_RUNGS_PR" "$_RUNGS_BASE" "$_BLOB_PR" "$_BLOB_BASE"
    continue
  fi
  _ci_rungs_from "$_BLOB_PR"   > "$_RUNGS_PR"
  _ci_rungs_from "$_BLOB_BASE" > "$_RUNGS_BASE"
  while IFS= read -r _r; do
    [ -n "$_r" ] || continue
    grep -qxF "$_r" "$_RUNGS_PR" \
      || fail "RUNG: '${_r}' is run by ${_ci} at the base and NOT at the pr ref — a rung dropped from the CI file is a suite that never runs, and the PR-side pin (check_suite_floors) is the PR's to edit"
  done < "$_RUNGS_BASE"
  rm -f "$_RUNGS_PR" "$_RUNGS_BASE" "$_BLOB_PR" "$_BLOB_BASE"
done

# --- arm 4: the trusted delta is REPORTED, never the only red ------------------
# What remains — a check REWRITTEN in place (body neutered, registry intact,
# file present) — is exactly the shape trusted code cannot adjudicate without
# becoming #112's holdout: the base run over a diff fires only on shapes it
# already knows, and legitimate pin evolution produces the same diffs. So the
# obligation is routed to the channel that can carry it: the delta report
# names every enforcer-core file the PR touched, and the human merge (no
# auto-merge exists here) reads it. A report line is the ceiling of what a
# non-holdout can honestly do here; pretending otherwise is the vacuous-green
# failure mode this repo has shipped before.
if [ -s "$CORE_TOUCHED" ]; then
  echo "-- enforcer core touched (delta report; a human merges): --"
  while IFS= read -r line; do echo "   $line"; done < "$CORE_TOUCHED"
else
  echo "-- enforcer core untouched by this PR --"
fi

# --- arm 5: no forged marker may pre-plant a green line -----------------------
# The anti-wormhole. If the PR's diff itself ADDS a line claiming this gate
# passed, the gate has been forged — the marker exists only in BASE-GATE
# output, never in a tree. (Simple grep over the diff; the marker language
# is deliberately not a valid bash or python token.)
# THE DIFF'S OWN EXIT STATUS IS CHECKED FIRST. Piping it straight into
# `grep -q` was the one git call in this file with no failure check, and the
# two outcomes are indistinguishable: `grep -q` on empty input exits 1
# whether the diff found no marker or never ran. Reproduced 2026-09-05 by
# removing a blob object (the shape a truncated shallow fetch takes, which
# is exactly how this job fetches the PR head): `git diff` printed
# `fatal: unable to read <blob>`, the arm stood down, and the run reported
# BASE_GATE_PASSED while an enforcer-core file was modified. `die` rather
# than `fail`: unreadable is a harder failure than readable-and-violating,
# the same polarity as every other refusal here.
# SCOPE: everything EXCEPT the suites and this script. A test that asserts
# the gate's own refusal text necessarily contains the marker, and so does
# this file — scanning them makes the arm fire on every PR that touches its
# own tests, which is a false positive that trains people to ignore it.
# Measured: the first version went red on the very PR that added these
# cases. The exclusion is narrow on purpose — a marker planted anywhere a
# human reads CI output as evidence (source, docs, workflows) is still red.
# NOT three dots, unlike the change list above — this arm's subject is the
# MERGED TREE, same as arm 1 (which already reads BASE_SHA and PR_TREE
# directly, never a diff of PR_SHA). `merge-base..pr` (three-dot) answers
# "what did the PR's own commits add since it forked", which is right for
# arm 4's human-facing authorship report but is the wrong question for a
# hard-fail arm, which must ask what the tree a merge would actually produce
# carries — not what the PR's own diff happens to show.
#
# The re-review's motivating shape: a line present at the merge base,
# removed by a LATER base commit, retained unmodified by a PR that forked
# before the removal — reaches the merge result without ever being an
# addition on the PR's own side, so three-dot cannot show it as `+`.
# MEASURED against real `git merge-tree` (fixture in tests/test-scripts.sh),
# though: when the PR does not otherwise touch that hunk, the base's
# deletion wins the merge outright and the line is simply ABSENT from
# PR_TREE — so this exact shape is not a live escape under EITHER diff form,
# and three-dot's silence on it is correct, not a gap. When the PR's own
# edit instead collides with the same hunk, `git merge-tree` reports a
# CONFLICT and this script already refuses the run before arm 5 runs at all
# (see the eight merge-tree outcomes above) — so that path never reaches this
# arm either, on any diff form.
#
# The form is kept anyway, for a property that IS real and IS reachable: the
# ORIGINAL two-dot form this arm never used — `git diff "$BASE_SHA"
# "$PR_SHA"`, base tip against the raw PR head, no merge-tree involved — is
# the false-authorship shape from the paragraph above, LIVE: on the same
# fixture (base removes the line, PR never touches it), that raw comparison
# reports `+BASE_GATE_PASSED: forged` even though PR_TREE never carries it
# (measured on the same fixture: three-dot and base-vs-PR_TREE both stay
# silent; base-vs-raw-PR_SHA alone fires). Diffing the base tip against
# PR_TREE — the merge result, not the unmerged PR head — keeps that
# false-positive closed while staying literally two dots against the same
# subject every other arm reads.
_MARKER_DIFF="$(_mk marker)" || exit 2
if ! git -C "$REPO" diff "${BASE_SHA}" "${PR_TREE}" \
       -- . ':(exclude)tests/' ':(exclude)scripts/base-gate.sh' \
       > "$_MARKER_DIFF" 2>/dev/null; then
  rm -f "$_MARKER_DIFF"
  die "git diff base vs merged tree (full content) failed — refusing (a diff failure must not read as 'no forged marker')"
fi
# The EMITTED SHAPE, not the bare token: a marker line is
# `BASE_GATE_PASSED: <text>` at the start of an output line. Matching the
# token alone red-flagged this repo's own validator pin, which names the
# marker as a string it looks for — naming it is not forging it.
if grep -qE '^\+[[:space:]]*BASE_GATE_(FAILED|PASSED):' "$_MARKER_DIFF"; then
  fail "the PR diff ADDS a BASE_GATE_* marker line — markers exist only in this gate's output, never in a tree; this is a forged result"
fi
rm -f "$_MARKER_DIFF"

if [ "$FAILS" -gt 0 ]; then
  echo "base-gate: ${FAILS} violation(s) — the PR weakens the base enforcer (#108)" >&2
  exit 1
fi
echo "BASE_GATE_PASSED: trusted-base ${BASE_SHA:0:12} vs pr ${PR_SHA:0:12} — no floors lowered, no checks removed, no enforcer files deleted"
exit 0
