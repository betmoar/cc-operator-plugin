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
#   --since      MANDATORY (with --claimed). Changes are git diff + untracked
#                since this ref — the dispatch sha the operator records in the
#                packet, so the diff is anchored BEFORE the dispatch. A HEAD
#                default would make a worker that COMMITS its gate-trespass
#                invisible (git diff HEAD compares against the worker's own
#                commit) — the exact F-A2 attack (code-review CR2, 2026-08-04).
#                Not required with --expect-clean alone (that reads porcelain,
#                no diff range).
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

# Temp files for the diff∪porcelain path stream. _ACTUAL_TMP holds the raw union
# (a path in both diff and porcelain appears twice); _DEDUPED_TMP holds the
# first-occurrence-deduped stream the checks actually read. The dedup is NOT
# cosmetic: a path in both streams would otherwise be emitted twice as an
# evidence line and double-counted in the green-run path count (CR7, 2026-08-04).
# mktemp is the one external beyond git (cf. ops-verdict.sh --reconcile); cleaned
# on exit. Paths are newline-delimited; a raw space is fine because porcelain/diff
# -z already de-quoted them, and we iterate with `while IFS= read -r` (one path
# per line), never unquoted `$ACTUAL`.
_ACTUAL_TMP="$(mktemp "${TMPDIR:-/tmp}/opsclaims.XXXXXX")"
_DEDUPED_TMP="$(mktemp "${TMPDIR:-/tmp}/opsclaims.XXXXXX")"
trap 'rm -f "$_ACTUAL_TMP" "$_DEDUPED_TMP"' EXIT

# --- protected set (F-A2: the builder cannot edit its own grader) ------------
# A touched path matching any of these PATTERNS, without --gate-task, is
# gate-trespass (C3). PROTECTED is the single source; matches_protected() is its
# application site — check_claims pins BOTH the literal and the call (F30: pinned
# to a canonical literal AND applied; copy parity alone is insufficient). A
# token ending in '/' matches by PREFIX (tests/ covers tests/x); a token with a
# glob char (*?[) matches as a glob; else exact.
#
# `set -f` is CRITICAL here. An earlier version iterated `for pat in $PROTECTED`
# WITHOUT it, so `scripts/ops-*.sh` PATHNAME-EXPANDED against the filesystem:
# a deleted gate CLI (the exact F-A2 attack — `git rm scripts/ops-verdict.sh`)
# matched nothing and evaded C3, and the match was CWD-relative. With `set -f`,
# `for pat in $PROTECTED` only WORD-SPLITS (no glob expansion against disk), and
# each token is matched against the STRING $p — prefix via parameter expansion
# for dir tokens, glob via `[[ == ]]` for the rest — never the filesystem. A
# deleted file still matches its pattern (review REFUTED, 2026-08-04). This keeps
# ONE source (the literal); a hardcoded `case` would drift — the F30 trap.
#
# statusline.sh is included per the F66 amendment: it is a full sentinel reader
# bound by gate semantics (same -L/NUL/byte-bound obligations as the hook), so a
# worker weakening its parser re-opens a laundering path invisibly. No existing
# glob in this literal covered it.
#
# backlog/ (B7) — the WHOLE directory, no field-level carve-out (Q4 decided): an
# implementer that can edit backlog/tasks/*.md can edit the ACCEPTANCE CRITERIA
# it is being judged against, the F48 vacuous-guard class relocated to the plan
# layer, and materially harder to spot than a weakened validator (the diff looks
# like ordinary task bookkeeping). The tempting notes-writable escape needs a
# parser for the neighbour's frontmatter grammar, which B5 forbids; the worker
# reports notes and the operator writes them with `backlog task edit --notes`.
# Token ends in '/' so it matches by PREFIX (backlog/ covers backlog/tasks/x.md).
PROTECTED="scripts/validate_plugin.py tests/ .operator/bin/ hooks/ scripts/ops-*.sh scripts/statusline.sh backlog/"

matches_protected() {  # matches_protected <path> → 0 if under the protected set
  local p="$1" pat
  set -f          # disable pathname expansion so $PROTECTED's glob tokens stay
  for pat in $PROTECTED; do   # literal PATTERNS matched against the string $p.
    case "$pat" in
      */) # a dir token (trailing /) matches by PREFIX: tests/ covers tests/t.sh
          [ "${p#"$pat"}" != "$p" ] && { set +f; return 0; } ;;
      *)  # a glob/exact token. $pat is a glob by design (ops-*.sh → ops-verdict.sh),
          # deliberately unquoted so [[ == ]] pattern-matches rather than pathname-
          # expands. A deleted gate CLI still matches its pattern (review REFUTED).
          # shellcheck disable=SC2053
          [[ $p == $pat ]] && { set +f; return 0; } ;;
    esac
  done
  set +f
  return 1
}

# A claimed path ending in '/' matches by prefix; else exact. UNLIKE the
# protected set (which globs via [[ == ]]), claimed paths are LITERAL — the
# CHANGED: contract is space-separated paths, not patterns, so a claimed glob is
# the worker's error, never a pattern. set -f stops a claimed path that happens
# to contain a glob char from pathname-expanding against the disk.
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

# --- porcelain path extraction (NUL-delimited; robust to spaces/quotes) ------
# `git status --porcelain -z` and `git diff --name-only -z` separate records with
# a NUL, so a path containing a space, a tab, or a quote — which porcelain v1
# C-quotes and an unquoted `$VAR` then word-splits into garbage — survives intact
# (review REFUTED, 2026-08-04). Each porcelain record is "XY path" (2 status
# chars + a space + the path) OR, for a rename/copy, "XY orig\0dest": the ORIG is
# a separate NUL-delimited record, so BOTH paths are extracted as changes (a
# renamed gate CLI must not evade C3). We collect each touched path.
#
# Status-code handling: an earlier version matched a HAND-WRITTEN ALLOWLIST of XY
# codes (?? D M A R C...) and fell through anything else to the rename-dest
# branch — so AM/AD/MD/RD/T/UU/AA left the status chars glued to the path
# ("{item AM feature.txt}"), defeating C3 on a staged-then-deleted gate CLI and
# the ledger exemption on a staged ledger write. The allowlist was the bug. The
# structural rule (review REFUTED #2, 2026-08-04): git guarantees EVERY record
# starts with exactly 2 status chars + 1 space, EXCEPT a rename/copy DEST, which
# is a bare path emitted as the record immediately AFTER an R/C record. So track
# whether the previous record was a rename (col 1 = R or C); if so the current
# record is a bare dest (emit as-is), else strip the 3-char "XY " prefix. This
# handles every XY combination without enumerating them.
#
# Builtins only: `IFS= read -r -d ''` reads one NUL-delimited record. bash 3.2's
# `read -d ''` returns non-zero at EOF (no trailing NUL) but still populates the
# variable, so `|| [ -n "$rec" ]` catches the final record.
porcelain_paths() {  # porcelain_paths → emits one repo-relative path per line
  local rec path _expect_dest=0
  while IFS= read -r -d '' rec || [ -n "$rec" ]; do
    [ -n "$rec" ] || continue
    if [ "$_expect_dest" = 1 ]; then
      # The bare dest half of a rename/copy — no XY prefix. Emit as-is.
      path="$rec"; _expect_dest=0
    else
      # A normal "XY <path>" record: strip the 3-char status prefix. If column 1
      # is R or C (rename/copy), the NEXT record is the bare rename dest — flag it.
      path="${rec#???}"
      case "$rec" in
        R*|C*) _expect_dest=1 ;;
      esac
    fi
    [ -n "$path" ] && printf '%s\n' "$path"
  done
}

# --- --expect-clean (F-A1): read-only-seat tree check ------------------------
# Run after any read-only/workflow dispatch. The working tree must be empty
# apart from .operator/ ledger paths; anything else is a read-only seat that
# wrote, or a workflow that mutated the tree — a FAIL-shaped finding logged
# before any other action. Independent of --claimed (it can run alone).
if [ "$EXPECT_CLEAN" = "1" ]; then
  stray=""
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    is_ledger_path "$p" && continue
    stray="${stray:+$stray$NL}$p"
  done < <(git status --porcelain -z --untracked-files=all 2>/dev/null | porcelain_paths)
  if [ -n "$stray" ]; then
    printf '%s\n' "$stray" | while IFS= read -r p; do
      [ -n "$p" ] || continue
      echo "{item $p} fail: working tree not clean (read-only dispatch left a change beyond .operator/)"
    done
    exit 1
  fi
  echo "{item working-tree} ok: clean apart from .operator/ ledger paths"
  # --expect-clean may run alone (no --claimed): a clean read-only dispatch.
  [ -n "$CLAIMED" ] || exit 0
fi

# --- diff-vs-claims (C1/C2/C3) requires --claimed AND --since ----------------
# --since is MANDATORY (not defaulted): a HEAD default made a worker that
# COMMITS its gate-trespass invisible — `git diff HEAD` compares against the
# commit the worker just made, so every check passed on the exact F-A2 attack
# (code-review CR2, 2026-08-04). The operator must record the dispatch sha in
# the packet and pass it here, so the diff is anchored to BEFORE the dispatch,
# not after the worker's commit. --expect-clean alone (no --claimed) needs no
# --since: it reads porcelain, not a diff range.
[ -n "$CLAIMED" ] || die "missing --claimed (usage: ops-claims.sh --since <sha> --claimed \"<paths>|none\" [--gate-task] | --expect-clean)"
[ -n "$SINCE" ] || die "missing --since <sha> — a HEAD default would make a committed gate-trespass invisible (CR2); the operator records the dispatch sha and passes it here"

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
    .*|*/.*) die "claimed path has a leading/trailing dot — not a path the gate tracks (review REFUTED, 2026-08-04: the comment promised this, the code did not)" ;;
  esac
}
# CLAIMED is space-separated on the CLI (the CHANGED: line contract). Iterate
# with word-splitting: that IS the contract. A claimed path with a literal space
# is not representable in it (a documented limitation, not a bug) — and ACTUAL,
# the git-output side, is NUL-delimited so spaces there are safe.
set -f
for c in $CLAIMED; do check_claimed_path "$c"; done
set +f

# Validate --since: a typo'd or invalid ref must NOT silently degrade to "no
# changes" (which would green-light a committed gate-trespass). git diff against
# a bad ref errors on stderr; without this guard the `|| true` swallowed it and
# the gate reported a false PASS (review REFUTED, 2026-08-04). Fail loud instead.
if ! git rev-parse --verify "${SINCE}^{commit}" >/dev/null 2>&1; then
  die "--since '${SINCE}' is not a valid commit ref — refusing (a bad ref must not silently pass the gate)"
fi

# Actual changes = tracked-changed-since-SINCE  ∪  untracked+unstaged.
# `git diff --name-only -z` covers modified+staged+deleted since SINCE; porcelain
# adds untracked (?? ) and unmerged, which diff omits. Both use -z (NUL-delimited)
# so paths with spaces/quotes survive intact (review REFUTED, 2026-08-04).
#
# A git FAILURE (corrupt index, filter error, ENOSPC) must NOT silently degrade to
# "no changes" — that would false-PASS C3 on a committed gate-trespass (H1, code-
# review 2026-08-04). So capture each git exit and die loud on non-zero, instead
# of `2>/dev/null || true` swallowing it. rev-parse already validated --since is a
# ref; this catches the failures rev-parse can't.
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

# De-dup the union (first occurrence wins; bash 3.2 has no assoc arrays) into
# _DEDUPED_TMP — the stream the checks read. A path in BOTH diff and porcelain
# (e.g. modified+staged) would otherwise be emitted twice and double-counted in
# the green-run path count (CR7, 2026-08-04). _seen is global; _de_dup appends.
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

# C3 gate-trespass first (it is the most serious): a touched protected path
# without --gate-task. Checked across ACTUAL so it fires even when the worker
# honestly reported the trespass in --claimed. ACTUAL is read from the temp file
# (NOT a pipe — `fails` must mutate in THIS shell, and `for p in $ACTUAL` would
# word-split a space-containing path, review REFUTED 2026-08-04).
if [ "$GATE_TASK" = "0" ]; then
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    if matches_protected "$p"; then
      echo "{item $p} fail: gate-trespass — touched a protected (gate) path without --gate-task"
      fails=$((fails + 1))
    fi
  done < "$_DEDUPED_TMP"
fi

# C1 unclaimed-change: a touched file not in the claimed list. Ledger paths
# are exempt (verdict rows are expected side-effects of any dispatch).
while IFS= read -r p; do
  [ -n "$p" ] || continue
  is_ledger_path "$p" && continue
  if [ -z "$CLAIMED" ] || ! matches_claimed "$p" "$CLAIMED"; then
    echo "{item $p} fail: unclaimed-change — touched but not in the claimed list"
    fails=$((fails + 1))
  fi
done < "$_DEDUPED_TMP"

# C2 phantom-claim: a claimed file with no actual change. "reported done,
# touched nothing". A directory claim (tests/) is satisfied if ANY actual path
# is under it; an exact claim needs its exact path in ACTUAL. CLAIMED is
# space-split (the CLI contract); set -f stops a claimed glob expanding.
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

# Green: state what was verified (the SSSF "a green gate answers what did you
# verify" shape). The operator's PASS verdict row cites these lines.
n_actual=0
while IFS= read -r _l; do [ -n "$_l" ] && n_actual=$((n_actual + 1)); done < "$_DEDUPED_TMP"
if [ -n "$CLAIMED" ]; then
  echo "{item diff-matches-claims} ok: $n_actual changed path(s) all claimed; no phantom claims"
else
  echo "{item diff-matches-claims} ok: CHANGED none and no protected-path trespass"
fi
exit 0
