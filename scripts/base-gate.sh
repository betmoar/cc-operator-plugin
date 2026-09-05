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
#     - a floor LOWERED (a case-deletion PR must lower a floor to pass its
#       own branch run; this is the moment the deletion becomes visible)
#     - a check REMOVED from the validator's CHECKS registry
#     - an enforcer file DELETED (validator, wrapper, this script) or the
#       tests/ tree shrunk wholesale
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
CORE_GLOBS="tests/"

is_core_path() {  # is_core_path <path> → 0 when the path is enforcer core
  local p="$1" f g
  for f in $CORE_FILES; do [ "$p" = "$f" ] && return 0; done
  for g in $CORE_GLOBS; do [ "${p#"$g"}" != "$p" ] && return 0; done
  return 1
}
is_core_file() {  # is_core_file <path> → 0 when deleting it removes the gate
  local p="$1" f
  for f in $CORE_FILES; do [ "$p" = "$f" ] && return 0; done
  return 1
}

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
BASE_SHA="$(git -C "$REPO" rev-parse --quiet --verify "${BASE_REF}^{commit}")"

echo "== base-gate: trusted base ${BASE_SHA:0:12} vs pr ${PR_SHA:0:12} =="

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
# Changed = diff base..pr. This includes files the PR DELETED (state D) — a
# deleted enforcer file is the loudest possible delta and must be reported.
CHANGED_TMP="$(mktemp "${_TMPDIR_T}/basegate.changed.XXXXXX")"
DIFFSTAT_TMP="$(mktemp "${_TMPDIR_T}/basegate.diffstat.XXXXXX")"
trap 'rm -f "$CHANGED_TMP" "$DIFFSTAT_TMP"' EXIT
if ! git -C "$REPO" diff --name-status "${BASE_SHA}" "${PR_SHA}" -- > "$DIFFSTAT_TMP" 2>/dev/null; then
  die "git diff base..pr failed — refusing (a diff failure must not read as 'no changes')"
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
BASE_FLOORS="$(mktemp "${_TMPDIR_T}/basegate.bf.XXXXXX")"
PR_FLOORS="$(mktemp "${_TMPDIR_T}/basegate.pf.XXXXXX")"
extract_floors "$BASE_SHA" "$BASE_FLOORS"
extract_floors "$PR_SHA" "$PR_FLOORS"
# a missing PR floors.env is a deleted ratchet — RED, named
if [ ! -s "$PR_FLOORS" ] && [ -s "$BASE_FLOORS" ]; then
  fail "tests/floors.env is gone or empty at the PR ref — the ratchet is deleted"
elif ! diff -q "$BASE_FLOORS" "$PR_FLOORS" >/dev/null; then
  # some floor line changed: any DECREASE or REMOVAL is red
  while IFS='=' read -r k v; do
    [ -n "$k" ] || continue
    PRV="$(grep -E "^${k}=" "$PR_FLOORS" | grep -oE '[0-9]+$')"
    if [ -z "$PRV" ]; then
      fail "FLOOR: ${k} removed at the PR ref (base ${v})"
    elif [ "$PRV" -lt "$v" ]; then
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
  git -C "$REPO" show "${1}:scripts/validate_plugin.py" 2>/dev/null \
    | awk '/^CHECKS = \($/,/^\)$/' | grep -oE 'check_[A-Za-z0-9_]+' | grep -v '^check_$'
}
BASE_CHECKS="$(mktemp "${_TMPDIR_T}/basegate.bc.XXXXXX")"
PR_CHECKS="$(mktemp "${_TMPDIR_T}/basegate.pc.XXXXXX")"
extract_checks "$BASE_SHA" > "$BASE_CHECKS"
extract_checks "$PR_SHA" > "$PR_CHECKS"
if [ ! -s "$PR_CHECKS" ]; then
  fail "the CHECKS registry is gone or empty at the PR ref — a validator that runs nothing reports nothing"
else
  while IFS= read -r c; do
    [ -n "$c" ] || continue
    if ! grep -qxF "$c" "$PR_CHECKS"; then
      fail "CHECKS: ${c} removed from the registry — every check dropped is a contract unenforced"
    fi
  done < "$BASE_CHECKS"
fi
rm -f "$BASE_CHECKS" "$PR_CHECKS"

# --- arm 3: an enforcer-core file may not be DELETED or EMPTIED ---------------
# Two deletions are hard RED on their own, before any scan: the wrapper every
# CI rung goes through, and the validator itself. Deleting either is not
# "restructuring" — it is the gate removed, and a diff that consists only of
# minus-lines has no ADD lines for any content scan to fire on.
CORE_TOUCHED="$(mktemp "${_TMPDIR_T}/basegate.core.XXXXXX")"
: > "$CORE_TOUCHED"
while IFS='|' read -r st path; do
  [ -n "$path" ] || continue
  is_core_path "$path" || continue
  # M/A/D/R/C all count: a deleted enforcer file is the loudest delta.
  printf '%s %s\n' "$st" "$path" >> "$CORE_TOUCHED"
  # A deleted CORE_FILE is the gate removed. A deleted tests/ path is caught
  # by the count below (and floors.env additionally by arm 1) — not here,
  # because a legitimate test rename shows as D+A and must not be a red.
  if [ "$st" = "D" ] && is_core_file "$path"; then
    fail "DELETE: ${path} deleted — the gate itself removed"
  fi
done < "$CHANGED_TMP"

# A DELETED tests/ tree cannot be caught path-by-path (the paths no longer
# exist on the PR side), so it is caught by count: the suite files may not
# vanish wholesale.
N_TESTS_BASE="$(git -C "$REPO" ls-tree -r --name-only "${BASE_SHA}" -- tests/ | grep -c '\.')"
N_TESTS_PR="$(git -C "$REPO" ls-tree -r --name-only "${PR_SHA}" -- tests/ | grep -c '\.')"
if [ "$N_TESTS_PR" -lt "$N_TESTS_BASE" ]; then
  fail "DELETE: tests/ shrank (${N_TESTS_BASE} -> ${N_TESTS_PR} files) — the suites are the enforcer"
fi

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
if git -C "$REPO" diff "${BASE_SHA}" "${PR_SHA}" 2>/dev/null \
     | grep -qE '^\+.*BASE_GATE_(FAILED|PASSED)'; then
  fail "the PR diff ADDS a BASE_GATE_* marker line — markers exist only in this gate's output, never in a tree; this is a forged result"
fi

if [ "$FAILS" -gt 0 ]; then
  echo "base-gate: ${FAILS} violation(s) — the PR weakens the base enforcer (#108)" >&2
  exit 1
fi
echo "BASE_GATE_PASSED: trusted-base ${BASE_SHA:0:12} vs pr ${PR_SHA:0:12} — no floors lowered, no checks removed, no enforcer files deleted"
exit 0
