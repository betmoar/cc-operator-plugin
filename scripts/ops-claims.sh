#!/usr/bin/env bash
# ops-claims.sh — verify a worker's dispatch report against the actual diff.
# The gate verifies CLAIMS mechanically: without it a worker can claim files it
# never touched, touch files it never claimed, or edit the gate that grades it
# (F48). SSSF diff_matches_claims port + grader protection.
#
# Invocation (operator, on a DONE report):
#   ops-claims.sh --claimed "<space-separated paths>" \
#       [--since <sha>] [--gate-task] [--expect-clean]
#   --claimed    the CHANGED: line ("none" = no paths claimed)
#   --since      MANDATORY with --claimed: the dispatch sha. A HEAD default
#                makes a worker that COMMITS its gate-trespass invisible (CR2).
#   --gate-task  authorizes edits to the protected set (the task IS the gate)
#   --expect-clean  (F-A1) tree empty apart from .operator/ — the read-only-
#                seat check; runs alone, no --since needed.
#
# Every check emits `{item <path>} <ok|fail>: <note>`; exit non-zero on any
# failure. NOT a sentinel reader: it reads git state, not pending/ — so no
# check_guard_parity / check_reader_bounds site and no byte-bound obligation.
set -eu

die() { echo "ops-claims: $1" >&2; exit 2; }

NL="$(printf '\nx')"; NL="${NL%x}"

# _ACTUAL_TMP: raw diff∪porcelain; _DEDUPED_TMP: deduped (CR7). The .err/.ign
# siblings are trapped because they are written on paths that die.
_ACTUAL_TMP="$(mktemp "${TMPDIR:-/tmp}/opsclaims.XXXXXX")"
_DEDUPED_TMP="$(mktemp "${TMPDIR:-/tmp}/opsclaims.XXXXXX")"
trap 'rm -f "$_ACTUAL_TMP" "$_ACTUAL_TMP.err" "$_ACTUAL_TMP.ign" "$_DEDUPED_TMP"' EXIT

# --- protected set (F-A2: the builder cannot edit its own grader) ------------
# A touched match without --gate-task is gate-trespass (C3). check_claims pins
# the literal AND its application (F30). '/' = prefix; glob chars = glob; else
# exact. set -f is CRITICAL: patterns must match the STRING, never the disk (a
# deleted gate CLI must still match). statusline.sh: a sentinel reader (F66).
# backlog/: whole dir — editable acceptance criteria are self-grading (B7/Q4).
PROTECTED="scripts/validate_plugin.py tests/ .operator/bin/ hooks/ scripts/ops-*.sh scripts/statusline.sh backlog/"

matches_protected() {  # matches_protected <path> → 0 if under the protected set
  local p="$1" pat
  set -f          # disable pathname expansion so $PROTECTED's glob tokens stay
  for pat in $PROTECTED; do   # literal PATTERNS matched against the string $p.
    case "$pat" in
      */) # a dir token (trailing /) matches by PREFIX: tests/ covers tests/t.sh
          [ "${p#"$pat"}" != "$p" ] && { set +f; return 0; } ;;
      *)  # a glob/exact token, deliberately unquoted so [[ == ]] pattern-
          # matches rather than pathname-expands.
          # shellcheck disable=SC2053
          [[ $p == $pat ]] && { set +f; return 0; } ;;
    esac
  done
  set +f
  return 1
}

# Claimed paths are LITERAL (the CHANGED: contract is paths, not patterns) —
# only a trailing-'/' dir claim matches by prefix. set -f stops a claimed path
# containing a glob char from expanding against the disk.
matches_claimed() {  # matches_claimed <path> <claimed-list> → 0 if claimed
  local p="$1" c
  set -f
  for c in $2; do
    case "$c" in
      */) case "$p" in "$c"*) set +f; return 0 ;; esac ;;
      *)  [ "$p" = "$c" ] && { set +f; return 0; } ;;
    esac
  done
  set +f        # a non-match must NOT leak noglob into the caller (CR1)
  return 1
}

# .operator/ ledger paths are expected side-effects of any dispatch — exempt
# from the unclaimed-change check, NOT from gate-trespass (.operator/bin/ is
# protected: a worker editing an installed gate CLI is grading itself).
is_ledger_path() {  # is_ledger_path <path> → 0 if under .operator/
  case "$1" in .operator/*) return 0 ;; esac
  return 1
}

# --- argument parse ----------------------------------------------------------
CLAIMED=""
SINCE=""
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
    -*) die "unknown option '$1' (usage: ops-claims.sh --since <sha> --claimed \"<paths>|none\" [--gate-task] | --expect-clean)" ;;
    *) die "unexpected positional argument '$1'" ;;
  esac
done

# Both modes need a git repo; refuse clearly rather than emit raw git errors.
git rev-parse --git-dir >/dev/null 2>&1 || die "not a git repository — ops-claims reads git state"

# --- porcelain path extraction (NUL-delimited) -------------------------------
# Every -z record is "XY path" EXCEPT a rename/copy dest (a bare path AFTER an
# R/C record) — the structural rule; an XY allowlist left codes glued to paths.
# bash 3.2 `read -d ''` returns non-zero at EOF but still populates.
porcelain_paths() {  # porcelain_paths → emits one repo-relative path per line
  local rec path _expect_dest=0
  while IFS= read -r -d '' rec || [ -n "$rec" ]; do
    [ -n "$rec" ] || continue
    if [ "$_expect_dest" = 1 ]; then
      path="$rec"; _expect_dest=0
    else
      path="${rec#???}"
      case "$rec" in
        R*|C*) _expect_dest=1 ;;
      esac
    fi
    [ -n "$path" ] && printf '%s\n' "$path"
  done
}

# --- --expect-clean (F-A1): read-only-seat tree check ------------------------
if [ "$EXPECT_CLEAN" = "1" ]; then
  # git's status checked BEFORE the verdict: a dead git must not fall
  # through to "ok: clean" (PR #36). Captured to a FILE — bash cannot hold
  # NUL in a variable.
  git status --porcelain -z --untracked-files=all >"$_ACTUAL_TMP" 2>"$_ACTUAL_TMP.err" \
    && _ec_rc=0 || _ec_rc=$?
  [ "$_ec_rc" -eq 0 ] || die "git status --porcelain failed (exit $_ec_rc): $(cat "$_ACTUAL_TMP.err") — refusing --expect-clean (a status failure must not read as a clean tree)"
  stray=""
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    is_ledger_path "$p" && continue
    stray="${stray:+$stray$NL}$p"
  done < <(porcelain_paths < "$_ACTUAL_TMP")
  if [ -n "$stray" ]; then
    printf '%s\n' "$stray" | while IFS= read -r p; do
      [ -n "$p" ] || continue
      echo "{item $p} fail: working tree not clean (read-only dispatch left a change beyond .operator/)"
    done
    exit 1
  fi
  echo "{item working-tree} ok: clean apart from .operator/ ledger paths"
  # Ignored state is invisible to porcelain and is #23's exact mechanism.
  # REPORT, NEVER FAIL (#21: a check nobody can run gets disabled) — the line
  # buys SCOPE for the verdict. Failure degrades to `unknown`, never 0. git's
  # exit captured separately (grep -c prints "0" AND exits 1 on empty input)
  # and to a FILE (command substitution drops NULs — PR #36).
  git status --porcelain --ignored=matching -z --untracked-files=all \
    >"$_ACTUAL_TMP.ign" 2>/dev/null && _ign_rc=0 || _ign_rc=$?
  if [ "$_ign_rc" -ne 0 ]; then
    _ign_n="unknown"
  else
    _ign_n="$(tr '\0' '\n' < "$_ACTUAL_TMP.ign" | grep -c '^!!' || true)"
    case "$_ign_n" in
      ''|*[!0-9]*) _ign_n="unknown" ;;
    esac
  fi
  rm -f "$_ACTUAL_TMP.ign"
  echo "{item ignored-state} report: $_ign_n gitignored entr(y|ies) NOT covered by the check above — \`git status --porcelain --ignored=matching\` lists them; ignored build state can make a broken commit verify green (#23)"
  # --expect-clean may run alone (no --claimed): a clean read-only dispatch.
  [ -n "$CLAIMED" ] || exit 0
fi

# --- diff-vs-claims (C1/C2/C3) requires --claimed AND --since ----------------
[ -n "$CLAIMED" ] || die "missing --claimed (usage: ops-claims.sh --since <sha> --claimed \"<paths>|none\" [--gate-task] | --expect-clean)"
[ -n "$SINCE" ] || die "missing --since <sha> — a HEAD default would make a committed gate-trespass invisible (CR2); the operator records the dispatch sha and passes it here"

# `none` is the "CHANGED: none" report: no paths claimed. Normalize to empty.
[ "$CLAIMED" = "none" ] && CLAIMED=""

# Claimed paths: no '|'/newline, no '..' traversal, no .operator/. NO
# leading-dot reject (#37): that is a task-id (filename) rule; a claimed path
# is a string, and six tracked files here start with a dot.
check_claimed_path() {  # check_claimed_path <path>
  local nl
  nl="$(printf '\nx')"; nl="${nl%x}"
  case "$1" in
    *"|"*) die "claimed path contains '|' — rephrase without it" ;;
    *"$nl"*) die "claimed path contains a newline" ;;
    ../*|*/../*) die "claimed path contains '..' traversal — not a claim about this repo" ;;
    .operator|.operator/*) die "claimed path is under .operator/ — the ledger is an expected side-effect of every dispatch (exempt from the unclaimed-change check), not a worker's claimed work" ;;
  esac
}
# Space-separated IS the CHANGED: contract; the git side is NUL-delimited.
set -f
for c in $CLAIMED; do check_claimed_path "$c"; done
set +f

# A typo'd --since must not degrade to "no changes". Fail loud.
if ! git rev-parse --verify "${SINCE}^{commit}" >/dev/null 2>&1; then
  die "--since '${SINCE}' is not a valid commit ref — refusing (a bad ref must not silently pass the gate)"
fi

# Actual = diff-since-SINCE ∪ porcelain (untracked+unmerged), both -z. A git
# failure must not degrade to "no changes" (H1) — PIPESTATUS, die loud.
git diff --name-only -z "$SINCE" 2>"$_ACTUAL_TMP.err" \
  | while IFS= read -r -d '' _p || [ -n "$_p" ]; do printf '%s\n' "$_p"; done \
  > "$_ACTUAL_TMP"
_diff_rc=${PIPESTATUS[0]}
if [ "$_diff_rc" -ne 0 ]; then
  die "git diff --name-only '$SINCE' failed (exit $_diff_rc): $(cat "$_ACTUAL_TMP.err") — refusing (a diff failure must not silently pass the gate)"
fi
git status --porcelain -z --untracked-files=all 2>"$_ACTUAL_TMP.err" | porcelain_paths >> "$_ACTUAL_TMP"
_status_rc=${PIPESTATUS[0]}
if [ "$_status_rc" -ne 0 ]; then
  die "git status --porcelain failed (exit $_status_rc): $(cat "$_ACTUAL_TMP.err") — refusing (a status failure must not silently pass the gate)"
fi
rm -f "$_ACTUAL_TMP.err"

# De-dup the union (first occurrence wins; bash 3.2 has no assoc arrays).
_seen=""
_de_dup() {  # _de_dup <path> — write to _DEDUPED_TMP unless already seen
  [ -n "$1" ] || return 0
  case "$NL$_seen$NL" in
    *"$NL$1$NL"*) return 0 ;;
  esac
  _seen="${_seen:+$_seen$NL}$1"
  printf '%s\n' "$1" >> "$_DEDUPED_TMP"
}
: > "$_DEDUPED_TMP"
while IFS= read -r line; do _de_dup "$line"; done < "$_ACTUAL_TMP"

fails=0

# C3 first: checked across ACTUAL so it fires even on an honestly-reported
# trespass. From the temp file, not a pipe — fails mutates in THIS shell.
if [ "$GATE_TASK" = "0" ]; then
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    if matches_protected "$p"; then
      echo "{item $p} fail: gate-trespass — touched a protected (gate) path without --gate-task"
      fails=$((fails + 1))
    fi
  done < "$_DEDUPED_TMP"
fi

# C1 unclaimed-change: a touched file not in the claimed list (ledger exempt).
while IFS= read -r p; do
  [ -n "$p" ] || continue
  is_ledger_path "$p" && continue
  if [ -z "$CLAIMED" ] || ! matches_claimed "$p" "$CLAIMED"; then
    echo "{item $p} fail: unclaimed-change — touched but not in the claimed list"
    fails=$((fails + 1))
  fi
done < "$_DEDUPED_TMP"

# C2 phantom-claim: claimed but no actual change. A dir claim (tests/) is
# satisfied by ANY path under it; an exact claim needs its exact path.
if [ -n "$CLAIMED" ]; then
  set -f
  for c in $CLAIMED; do
    found=0
    case "$c" in
      */) while IFS= read -r p; do case "$p" in "$c"*) found=1; break ;; esac; done < "$_DEDUPED_TMP" ;;
      *)  while IFS= read -r p; do [ "$p" = "$c" ] && { found=1; break; }; done < "$_DEDUPED_TMP" ;;
    esac
    if [ "$found" = 0 ]; then
      echo "{item $c} fail: phantom-claim — claimed but no actual change"
      fails=$((fails + 1))
    fi
  done
  set +f
fi

if [ "$fails" -gt 0 ]; then
  echo "ops-claims: $fails check(s) failed" >&2
  exit 1
fi

# Green: count only what C1 ADJUDICATED (#63) — the whole-file count banked
# inflated numbers into verdict rows. Exempt paths reported, not dropped.
n_actual=0
n_ledger=0
while IFS= read -r _l; do
  [ -n "$_l" ] || continue
  if is_ledger_path "$_l"; then n_ledger=$((n_ledger + 1)); else n_actual=$((n_actual + 1)); fi
done < "$_DEDUPED_TMP"
_exempt_note=""
# .operator/ spelled out to match is_ledger_path's literal.
[ "$n_ledger" -gt 0 ] && _exempt_note=" ($n_ledger .operator/ ledger path(s) exempt)"
if [ -n "$CLAIMED" ]; then
  echo "{item diff-matches-claims} ok: $n_actual changed path(s) all claimed; no phantom claims$_exempt_note"
else
  echo "{item diff-matches-claims} ok: CHANGED none and no protected-path trespass"
fi
exit 0
