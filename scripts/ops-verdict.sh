#!/usr/bin/env bash
# ops-verdict.sh — the SINGLE writer to .operator/VERDICTS.md (and the defer
# path to .operator/DECISIONS.md). Append + fragment + sentinel-clear run under
# a mkdir-based lock, so the append is atomic against concurrent sessions —
# not merely append-only.
#
# Verdict:  ops-verdict.sh <task-id> <criterion> <evidence> <PASS|FAIL> [--owner <sid>]
#   Appends exactly one row and clears .operator/pending/<task-id>.
#   Refuses (exit 2, no row, sentinel intact) if any cell is empty, if a cell
#   breaks the 4-cell schema, or if --owner contradicts the sentinel's owner.
#
# Defer:    ops-verdict.sh <task-id> --defer "<reason>" [--owner <sid>]
#   Writes a DEFERRED-VERDICT line to DECISIONS.md and clears the sentinel.
#   The honest end-state for a legitimately blocked task.
#
# Reconcile: ops-verdict.sh --reconcile
#   Appends to VERDICTS.md every row present in .operator/verdicts.d/*.md but
#   missing from it. Idempotent. This REPAIRS a merge, it does not regenerate
#   the ledger: VERDICTS.md also carries hand-written BAR blocks, which a
#   rebuild would destroy.
#
# Every row is also appended to .operator/verdicts.d/<owner>.md. Two branches
# then append to two different files and git merges them cleanly; a mangled
# VERDICTS.md merge is recoverable with --reconcile.
set -eu

OPDIR=".operator"
VERDICTS="$OPDIR/VERDICTS.md"
DECISIONS="$OPDIR/DECISIONS.md"
FRAGDIR="$OPDIR/verdicts.d"
LOCKDIR="$OPDIR/.lock"

die() { echo "ops-verdict: $1" >&2; exit 2; }

NL="$(printf '\nx')"; NL="${NL%x}"

# The ledgers are one-line pipe-tables: a '|' or newline inside a cell breaks
# the 4-cell schema every grep consumer depends on. Refuse, never sanitize —
# same policy as the empty-cell refusal below.
check_cell() { # check_cell <label> <value>
  case "$2" in
    *"|"*)
      die "$1 contains '|' — cells are pipe-delimited; rephrase without it" ;;
    *"$NL"*)
      die "$1 contains a newline — ledger rows are exactly one line" ;;
  esac
}

# A bare name: it is also a filename (sentinel + fragment file), so a '/' would
# let clear_sentinel's rm -f reach outside .operator/ (the 2026-07-10 traversal
# bug). A leading dot is refused because the Stop hook enumerates pending/ with
# a plain glob, which skips dotfiles — a `.hidden` sentinel would be an open
# task the gate cannot see. Keep identical to ops-task.sh / ops-adopt.sh.
check_bare_name() { # check_bare_name <label> <value>
  case "$2" in
    */*) die "$1 must be a bare name (no '/')" ;;
    .*) die "$1 must not start with '.' — a dotfile sentinel is invisible to the Stop hook's glob" ;;
  esac
  check_cell "$1" "$2"
}

# --- lock: mkdir is atomic on every POSIX FS; flock(1) is absent on macOS -----
# A stale lock must never cost a real verdict, so we spin briefly and then
# proceed with a warning rather than failing.
lock_acquire() {
  local i=0
  while ! mkdir "$LOCKDIR" 2>/dev/null; do
    i=$((i+1))
    if [ "$i" -ge 50 ]; then
      echo "ops-verdict: warning — lock $LOCKDIR held for >5s; proceeding unlocked" >&2
      return 0
    fi
    sleep 0.1
  done
  LOCK_HELD=1
  trap 'lock_release' EXIT INT TERM
}
lock_release() {
  if [ "${LOCK_HELD:-0}" = "1" ]; then rmdir "$LOCKDIR" 2>/dev/null || true; LOCK_HELD=0; fi
}

# --- sentinel ownership ------------------------------------------------------
sentinel_owner() { # sentinel_owner <id> → stamped session_id ("" if none)
  local f="$OPDIR/pending/$1" line
  [ -f "$f" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in "session_id: "*) printf '%s' "${line#session_id: }"; return 0 ;; esac
  done < "$f"
}

append_fragment() { # append_fragment <owner-or-empty> <row>
  local who="${1:-unowned}"
  mkdir -p "$FRAGDIR"
  printf '%s\n' "$2" >> "$FRAGDIR/$who.md"
}

# --- Reconcile path (no task-id) --------------------------------------------
if [ "${1:-}" = "--reconcile" ]; then
  [ -f "$VERDICTS" ] || die "missing $VERDICTS — run ops-init.sh first"
  lock_acquire
  added=0
  skipped=0
  if [ -d "$FRAGDIR" ]; then
    for frag in "$FRAGDIR"/*.md; do
      [ -f "$frag" ] || continue
      while IFS= read -r row || [ -n "$row" ]; do
        [ -n "$row" ] || continue
        # Reconcile is a WRITE to the ledger of record, so it enforces the same
        # 4-cell schema the direct path does. A fragment is an ordinary file
        # that a merge or a hand-edit can corrupt; without this, --reconcile
        # would be a hole straight through the single writer's cell hygiene.
        case "$row" in
          '| '*' | '*' | '*' | PASS |' | '| '*' | '*' | '*' | FAIL |') ;;
          *) echo "ops-verdict: skipping non-conformant line in ${frag##*/}: $row" >&2
             skipped=$((skipped+1)); continue ;;
        esac
        if ! grep -Fxq -- "$row" "$VERDICTS"; then
          printf '%s\n' "$row" >> "$VERDICTS"
          added=$((added+1))
        fi
      done < "$frag"
    done
  fi
  lock_release
  if [ "$skipped" -gt 0 ]; then
    echo "reconciled: $added row(s) restored to $VERDICTS from $FRAGDIR/ ($skipped non-conformant line(s) skipped — see stderr)"
  else
    echo "reconciled: $added row(s) restored to $VERDICTS from $FRAGDIR/"
  fi
  exit 0
fi

# --- Argument parse ----------------------------------------------------------
# --owner may appear anywhere; everything else keeps its positional meaning.
OWNER=""
POS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --owner)
      [ $# -ge 2 ] || die "--owner requires a session id"
      [ -z "$OWNER" ] || die "--owner given more than once"
      OWNER="$2"; shift 2 ;;
    --owner=*)
      [ -z "$OWNER" ] || die "--owner given more than once"
      OWNER="${1#--owner=}"; shift ;;
    *) POS+=("$1"); shift ;;
  esac
done
set -- ${POS+"${POS[@]}"}

ID="${1:-}"
[ -n "$ID" ] || die "missing task-id (usage: ops-verdict.sh <id> <criterion> <evidence> <PASS|FAIL> [--owner <sid>] | <id> --defer \"<reason>\" | --reconcile)"
check_bare_name "task-id" "$ID"
if [ -n "$OWNER" ]; then check_bare_name "owner" "$OWNER"; fi
[ -d "$OPDIR" ] || die "no $OPDIR/ in cwd — run ops-init.sh first"

# --- Ownership gate ----------------------------------------------------------
# Mismatch is a hard refusal: closing a row you did not perform is exactly the
# failure the evidence gate exists to prevent. A MISSING --owner only warns —
# a session whose id rotated (/clear) must still be able to close its own work
# (ops-adopt.sh is the clean path).
SOWNER="$(sentinel_owner "$ID")"
if [ -n "$SOWNER" ]; then
  if [ -n "$OWNER" ] && [ "$OWNER" != "$SOWNER" ]; then
    die "task '$ID' is owned by session $SOWNER, not $OWNER — refusing (run ops-adopt.sh to take ownership deliberately)"
  fi
  if [ -z "$OWNER" ]; then
    echo "ops-verdict: warning — task '$ID' is owned by session $SOWNER and no --owner was given; proceeding" >&2
  fi
fi
FRAG_OWNER="${OWNER:-$SOWNER}"

clear_sentinel() { rm -f "$OPDIR/pending/$ID"; }

# --- Defer path -------------------------------------------------------------
if [ "${2:-}" = "--defer" ]; then
  REASON="${3:-}"
  [ -n "$REASON" ] || die "--defer requires a non-empty reason"
  check_cell "defer reason" "$REASON"
  [ -f "$DECISIONS" ] || die "missing $DECISIONS — run ops-init.sh first"
  lock_acquire
  printf '%s | %s | DEFERRED-VERDICT | %s | deferred via ops-verdict.sh --defer\n' \
    "$(date +%F)" "$ID" "$REASON" >> "$DECISIONS"
  clear_sentinel
  lock_release
  echo "deferred $ID (DECISIONS.md line written, sentinel cleared)"
  exit 0
fi

# --- Verdict path -----------------------------------------------------------
CRITERION="${2:-}"
EVIDENCE="${3:-}"
VERDICT="${4:-}"

# A row without evidence is FAIL by definition — refuse to write it at all.
[ -n "$CRITERION" ] || die "empty criterion — refusing (a row without a criterion is not conformant)"
[ -n "$EVIDENCE" ]  || die "empty evidence — refusing (a row without evidence is FAIL by definition)"
check_cell "criterion" "$CRITERION"
check_cell "evidence" "$EVIDENCE"
case "$VERDICT" in
  PASS|FAIL) ;;
  *) die "verdict must be exactly PASS or FAIL (got '${VERDICT:-<empty>}')" ;;
esac
[ -f "$VERDICTS" ]  || die "missing $VERDICTS — run ops-init.sh first"

ROW="$(printf '| %s | %s | %s | %s |' "$ID" "$CRITERION" "$EVIDENCE" "$VERDICT")"
lock_acquire
printf '%s\n' "$ROW" >> "$VERDICTS"
append_fragment "$FRAG_OWNER" "$ROW"
clear_sentinel
lock_release
echo "recorded $ID = $VERDICT (row appended, sentinel cleared)"
exit 0
