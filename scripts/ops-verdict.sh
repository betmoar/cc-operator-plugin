#!/usr/bin/env bash
# ops-verdict.sh — the SINGLE writer to .operator/VERDICTS.md (and the defer
# path to .operator/DECISIONS.md). Append + sentinel-clear are one atomic
# script action, so append-only holds by construction.
#
# Verdict:  ops-verdict.sh <task-id> <criterion> <evidence> <PASS|FAIL>
#   Appends exactly one row and clears .operator/pending/<task-id>.
#   Refuses (exit 2, no row, sentinel intact) if any cell is empty.
#
# Defer:    ops-verdict.sh <task-id> --defer "<reason>"
#   Writes a DEFERRED-VERDICT line to DECISIONS.md and clears the sentinel.
#   The honest end-state for a legitimately blocked task.
set -eu

OPDIR=".operator"
VERDICTS="$OPDIR/VERDICTS.md"
DECISIONS="$OPDIR/DECISIONS.md"

die() { echo "ops-verdict: $1" >&2; exit 2; }

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
NL="$(printf '\nx')"; NL="${NL%x}"

ID="${1:-}"
[ -n "$ID" ] || die "missing task-id (usage: ops-verdict.sh <id> <criterion> <evidence> <PASS|FAIL> | <id> --defer \"<reason>\")"
case "$ID" in
  */* | . | ..) die "task-id must be a bare name (no '/', '.', '..') — it is also the sentinel filename" ;;
esac
check_cell "task-id" "$ID"
[ -d "$OPDIR" ] || die "no $OPDIR/ in cwd — run ops-init.sh first"

clear_sentinel() { rm -f "$OPDIR/pending/$ID"; }

# --- Defer path -------------------------------------------------------------
if [ "${2:-}" = "--defer" ]; then
  REASON="${3:-}"
  [ -n "$REASON" ] || die "--defer requires a non-empty reason"
  check_cell "defer reason" "$REASON"
  [ -f "$DECISIONS" ] || die "missing $DECISIONS — run ops-init.sh first"
  printf '%s | %s | DEFERRED-VERDICT | %s | deferred via ops-verdict.sh --defer\n' \
    "$(date +%F)" "$ID" "$REASON" >> "$DECISIONS"
  clear_sentinel
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

printf '| %s | %s | %s | %s |\n' "$ID" "$CRITERION" "$EVIDENCE" "$VERDICT" >> "$VERDICTS"
clear_sentinel
echo "recorded $ID = $VERDICT (row appended, sentinel cleared)"
exit 0
