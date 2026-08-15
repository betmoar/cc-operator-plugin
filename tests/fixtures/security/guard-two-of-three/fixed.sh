#!/usr/bin/env bash
# FIXTURE (inert): the CORRECTED variant of guard-two-of-three/vuln.sh.
# Identical CLI, identical behaviour on every well-formed task id. The only
# change is that `adopt` calls the guard the other two subcommands already call.
#
# Usage: fixed.sh open   <dir> <task-id>
#        fixed.sh close  <dir> <task-id>
#        fixed.sh adopt  <dir> <task-id> <new-owner>
set -u

check_bare_name() { # check_bare_name <value> <what>
  case "$1" in
    */*|*\\*|.*|*..*)
      echo "refusing $2 '$1' — not a bare name" >&2; return 1 ;;
  esac
  return 0
}

cmd="${1:?usage: fixed.sh <open|close|adopt> <dir> <task-id> [owner]}"
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
    # THE FIX. "It was checked when it was opened" describes a well-behaved
    # caller, not an invariant: adopt is reachable directly, so the id arriving
    # here has been through no guard at all. A per-call-site check is the only
    # kind that holds.
    check_bare_name "$ID" "task id" || exit 2
    OWNER="${4:?owner required}"
    check_bare_name "$OWNER" "owner" || exit 2
    mkdir -p "$DIR/pending" || exit 1
    printf 'session_id: %s\n' "$OWNER" > "$DIR/pending/$ID"
    echo "adopted $ID for $OWNER"
    ;;
  *)
    echo "unknown subcommand: $cmd" >&2; exit 64 ;;
esac
