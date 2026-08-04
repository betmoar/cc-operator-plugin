#!/usr/bin/env bash
# ops-claims.sh — verify a worker's dispatch report against the actual diff.
#
# The evidence gate verifies CLAIMS mechanically, not by operator reading. A
# dispatch report's ACCOMPLISHED list is prose; without this check a worker can
# claim files it never touched, touch files it never claimed, or edit the gate
# that grades it (the F48 class — shipped four times by the maintainer). This
# CLI is the SSSF diff_matches_claims port (gap analysis F-A3) plus grader
# protection (F-A2): the protected-set literal below is the "builder cannot edit
# its own grader" rule, enforced instead of requested.
#
# Invocation (operator, on a DONE report):
#   ops-claims.sh --claimed "<space-separated paths>" \
#       [--since <sha>] [--gate-task] [--expect-clean]
#
#   --claimed    the CHANGED: line from the dispatch packet (paths the worker
#                reported touching). "none" means no paths were claimed.
#   --since      changes are git diff + untracked since this ref. Defaults to
#                HEAD (the operator records the dispatch sha in the packet; the
#                mechanical default is HEAD, which compares against the last
#                commit — fine for an uncommitted working-tree dispatch).
#   --gate-task  authorizes edits to the protected set (the task IS the gate).
#   --expect-clean (F-A1) asserts the working tree is empty apart from
#                .operator/ ledger paths — the read-only-seat tree check, run
#                after any read-only/workflow dispatch.
#
# Every check emits an evidence line of the SSSF shape
#   {item <path>} <ok|fail>: <note>
# so a green run answers WHAT WAS VERIFIED, and the PASS verdict row cites it.
# Exit non-zero on any failed check, naming it.
#
# Reader-discipline note (the "how many sites share this invariant?" question,
# amendment 2): this CLI does NOT read .operator/pending/ — it reads `git
# status`/`git diff`, not sentinels. It is therefore NOT a sentinel reader and
# joins neither check_guard_parity's -L site list nor check_reader_bounds. The
# only files it opens are git's own plumbing output (captured, not slurped from
# disk) and — for --expect-clean — the same porcelain stream. No byte-bound
# obligation applies because no untrusted file is read line-by-line.
set -eu

die() { echo "ops-claims: $1" >&2; exit 2; }

NL="$(printf '\nx')"; NL="${NL%x}"

# --- protected set (F-A2: the builder cannot edit its own grader) ------------
# A touched path under any of these, without --gate-task, is gate-trespass (C3).
# PROTECTED is the single source; matches_protected() is its application site —
# check_claims pins BOTH the literal and the call (F30: pinned to a canonical
# literal AND applied; copy parity alone is insufficient). A path ending in '/'
# matches by prefix (tests/ covers tests/test-scripts.sh); else exact.
#
# statusline.sh is included per the F66 amendment: it is a full sentinel reader
# bound by gate semantics (same -L/NUL/byte-bound obligations as the hook), so a
# worker weakening its parser re-opens a laundering path invisibly. No existing
# glob in this literal covered it.
PROTECTED="scripts/validate_plugin.py tests/ .operator/bin/ hooks/ scripts/ops-*.sh scripts/statusline.sh"

matches_protected() {  # matches_protected <path> → 0 if under the protected set
  local p="$1" pat
  for pat in $PROTECTED; do
    case "$pat" in
      */) case "$p" in "$pat"*) return 0 ;; esac ;;   # prefix match (dir glob)
      *)  [ "$p" = "$pat" ] && return 0 ;;            # exact match
    esac
  done
  return 1
}

# A claimed path ending in '/' matches by prefix; else exact. Same rule as the
# protected set: "CHANGED: tests/" is satisfied by a diff touching tests/x.
matches_claimed() {  # matches_claimed <path> <claimed-list> → 0 if claimed
  local p="$1" c pat
  for c in $2; do
    case "$c" in
      */) case "$p" in "$c"*) return 0 ;; esac ;;
      *)  [ "$p" = "$c" ] && return 0 ;;
    esac
  done
  return 1
}

# `.operator/` ledger paths are expected side-effects of any dispatch (verdict
# rows, fragments, sentinels) and are exempt from the unclaimed-change check.
# They are NOT exempt from gate-trespass: .operator/bin/ IS in the protected
# set (a worker editing an installed gate CLI is grading itself).
is_ledger_path() {  # is_ledger_path <path> → 0 if under .operator/
  case "$1" in .operator/*) return 0 ;; esac
  return 1
}

# --- argument parse ----------------------------------------------------------
CLAIMED=""
SINCE="HEAD"
GATE_TASK=0
EXPECT_CLEAN=0
while [ $# -gt 0 ]; do
  case "$1" in
    --claimed)
      [ $# -ge 2 ] || die "--claimed requires a path list (or 'none')"
      [ -z "$CLAIMED" ] || die "--claimed given more than once"
      CLAIMED="$2"; shift 2 ;;
    --claimed=*)
      [ -z "$CLAIMED" ] || die "--claimed given more than once"
      CLAIMED="${1#--claimed=}"; shift ;;
    --since)
      [ $# -ge 2 ] || die "--since requires a ref"
      SINCE="$2"; shift 2 ;;
    --since=*)
      SINCE="${1#--since=}"; shift ;;
    --gate-task) GATE_TASK=1; shift ;;
    --expect-clean) EXPECT_CLEAN=1; shift ;;
    -*) die "unknown option '$1' (usage: ops-claims.sh --claimed \"<paths>|none\" [--since <sha>] [--gate-task] [--expect-clean])" ;;
    *) die "unexpected positional argument '$1'" ;;
  esac
done

# Both modes need a git repo; refuse clearly rather than emit raw git errors.
git rev-parse --git-dir >/dev/null 2>&1 || die "not a git repository — ops-claims reads git state"

# --- --expect-clean (F-A1): read-only-seat tree check ------------------------
# Run after any read-only/workflow dispatch. The working tree must be empty
# apart from .operator/ ledger paths; anything else is a read-only seat that
# wrote, or a workflow that mutated the tree — a FAIL-shaped finding logged
# before any other action. Independent of --claimed (it can run alone).
if [ "$EXPECT_CLEAN" = "1" ]; then
  stray=""
  # Porcelain v1: "XY path" (or "XY "path" for special). Field 1 is the status,
  # the rest is the path. Strip the two-char status prefix to get the path.
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    p="${line#???}"            # drop "XY " (status + space)
    is_ledger_path "$p" && continue
    stray="${stray:+$stray }$p"
  done <<EOF
$(git status --porcelain 2>/dev/null || true)
EOF
  if [ -n "$stray" ]; then
    for p in $stray; do
      echo "{item $p} fail: working tree not clean (read-only dispatch left a change beyond .operator/)"
    done
    exit 1
  fi
  echo "{item working-tree} ok: clean apart from .operator/ ledger paths"
  # --expect-clean may run alone (no --claimed): a clean read-only dispatch.
  [ -n "$CLAIMED" ] || exit 0
fi

# --- diff-vs-claims (C1/C2/C3) requires --claimed ----------------------------
[ -n "$CLAIMED" ] || die "missing --claimed (usage: ops-claims.sh --claimed \"<paths>|none\" [--since <sha>] [--gate-task] [--expect-clean])"

# `none` is the "CHANGED: none" report: no paths claimed. Normalize to empty.
[ "$CLAIMED" = "none" ] && CLAIMED=""

# Claimed paths inherit the charset discipline of task ids: no '|' or newline
# (would break the space-separated list contract), no leading dot (an invisible
# ledger claim), and — critically for a PATH — no traversal ('..'). A claimed
# '/../etc/passwd' is not a claim about this repo. Reject, never sanitize.
check_claimed_path() {  # check_claimed_path <path>
  local nl
  nl="$(printf '\nx')"; nl="${nl%x}"
  case "$1" in
    *"|"*) die "claimed path contains '|' — rephrase without it" ;;
    *"$nl"*) die "claimed path contains a newline" ;;
    ../*|*/../*) die "claimed path contains '..' traversal — not a claim about this repo" ;;
  esac
}
for c in $CLAIMED; do check_claimed_path "$c"; done

# Actual changes = tracked-changed-since-SINCE  ∪  untracked.
# `git diff --name-only` covers modified+staged+deleted since SINCE; porcelain
# adds untracked (?? ) and unmerged, which diff omits. Both streams are captured
# (builtins + git only — no sed/sort/awk: the porcelain "XY " prefix is stripped
# with ${line#???}, and the union is de-duped by a first-occurrence loop because
# bash 3.2 has no associative arrays). A duplicate path would at most repeat an
# evidence line; the dedup keeps the output clean, it is not load-bearing.
_actual=""
while IFS= read -r line; do
  [ -n "$line" ] || continue
  p="${line#???}"            # drop "XY " (status + space) — porcelain only
  _actual="${_actual:+$_actual$NL}$p"
done <<EOF
$(git status --porcelain 2>/dev/null || true)
EOF
_diff="$(git diff --name-only "$SINCE" 2>/dev/null || true)"
# De-dup union (first occurrence wins).
ACTUAL=""
_seen=""
_de_dup() {  # _de_dup <path> — append to ACTUAL unless already seen
  local p="$1"
  case "$NL$_seen$NL" in
    *"$NL$p$NL"*) return 0 ;;
  esac
  _seen="${_seen:+$_seen$NL}$p"
  ACTUAL="${ACTUAL:+$ACTUAL$NL}$p"
}
while IFS= read -r line; do [ -n "$line" ] && _de_dup "$line"; done <<EOF
$_diff
$_actual
EOF

fails=0

# C3 gate-trespass first (it is the most serious): a touched protected path
# without --gate-task. Checked across ACTUAL so it fires even when the worker
# honestly reported the trespass in --claimed.
if [ "$GATE_TASK" = "0" ]; then
  for p in $ACTUAL; do
    if matches_protected "$p"; then
      echo "{item $p} fail: gate-trespass — touched a protected (gate) path without --gate-task"
      fails=$((fails + 1))
    fi
  done
fi

# C1 unclaimed-change: a touched file not in the claimed list. Ledger paths
# are exempt (verdict rows are expected side-effects of any dispatch).
for p in $ACTUAL; do
  is_ledger_path "$p" && continue
  if [ -z "$CLAIMED" ] || ! matches_claimed "$p" "$CLAIMED"; then
    echo "{item $p} fail: unclaimed-change — touched but not in the claimed list"
    fails=$((fails + 1))
  fi
done

# C2 phantom-claim: a claimed file with no actual change. "reported done,
# touched nothing". A directory claim (tests/) is satisfied if ANY actual path
# is under it; an exact claim needs its exact path in ACTUAL.
if [ -n "$CLAIMED" ]; then
  for c in $CLAIMED; do
    found=0
    case "$c" in
      */) for p in $ACTUAL; do case "$p" in "$c"*) found=1; break ;; esac; done ;;
      *)  for p in $ACTUAL; do [ "$p" = "$c" ] && { found=1; break; }; done ;;
    esac
    if [ "$found" = "0" ]; then
      echo "{item $c} fail: phantom-claim — claimed but no actual change"
      fails=$((fails + 1))
    fi
  done
fi

if [ "$fails" -gt 0 ]; then
  echo "ops-claims: $fails check(s) failed" >&2
  exit 1
fi

# Green: state what was verified (the SSSF "a green gate answers what did you
# verify" shape). The operator's PASS verdict row cites these lines.
n_actual=0
while IFS= read -r _l; do [ -n "$_l" ] && n_actual=$((n_actual + 1)); done <<EOF
$ACTUAL
EOF
if [ -n "$CLAIMED" ]; then
  echo "{item diff-matches-claims} ok: $n_actual changed path(s) all claimed; no phantom claims"
else
  echo "{item diff-matches-claims} ok: CHANGED none and no protected-path trespass"
fi
exit 0
