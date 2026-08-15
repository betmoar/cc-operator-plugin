#!/usr/bin/env bash
# FIXTURE (inert): a tiny ledger CLI with three subcommands that each turn a
# task id into a filename. Models the F30 shape — a correct, tested guard
# applied at two of its three call sites.
#
# Usage: vuln.sh open   <dir> <task-id>
#        vuln.sh close  <dir> <task-id>
#        vuln.sh adopt  <dir> <task-id> <new-owner>
#
# This is the DEFECTIVE variant. Nothing here is unvalidated in the sense a
# reader means: the guard exists, it is correct, and it is applied. See NOTES.md.
set -u

# The guard. Correct, single definition, no drift possible.
check_bare_name() { # check_bare_name <value> <what>
  case "$1" in
    */*|*\\*|.*|*..*)
      echo "refusing $2 '$1' — not a bare name" >&2; return 1 ;;
  esac
  return 0
}

cmd="${1:?usage: vuln.sh <open|close|adopt> <dir> <task-id> [owner]}"
DIR="${2:?dir required}"
ID="${3:?task-id required}"

case "$cmd" in
  open)
    check_bare_name "$ID" "task id" || exit 2
    mkdir -p "$DIR/pending" || exit 1
    printf 'session_id: unowned\n' > "$DIR/pending/$ID"
    echo "opened $ID"
    ;;
  close)
    check_bare_name "$ID" "task id" || exit 2
    rm -f "$DIR/pending/$ID"
    echo "closed $ID"
    ;;
  adopt)
    # Re-stamps ownership of an existing sentinel. The id was already checked
    # when the task was opened, so it is a known-good name by the time it
    # reaches this path.
    OWNER="${4:?owner required}"
    mkdir -p "$DIR/pending" || exit 1
    printf 'session_id: %s\n' "$OWNER" > "$DIR/pending/$ID"
    echo "adopted $ID for $OWNER"
    ;;
  *)
    echo "unknown subcommand: $cmd" >&2; exit 64 ;;
esac
