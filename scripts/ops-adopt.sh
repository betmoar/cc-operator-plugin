#!/usr/bin/env bash
# ops-adopt.sh — re-stamp the ownership of open task sentinels.
#
# Why this exists: a session id rotates on /clear. Without adoption, a session's
# OWN open tasks would look foreign to its Stop hook after a clear and silently
# stop gating it — the gate would weaken at exactly the moment the operator's
# context was wiped. The RECOVERY PROTOCOL therefore ends with adoption.
#
# Explicit ids only. There is deliberately no "adopt everything": a bulk sweep
# in a shared tree is a takeover of another session's tasks by another name.
#
# Usage: run from the project root (cwd):
#   ops-adopt.sh --owner <session-id> <task-id> [<task-id> ...]
set -eu

OPDIR=".operator"

die() { echo "ops-adopt: $1" >&2; exit 2; }

NL="$(printf '\nx')"; NL="${NL%x}"

# Keep identical to ops-task.sh / ops-verdict.sh — see the note there on why a
# leading dot is refused (invisible to the Stop hook's glob).
check_bare_name() { # check_bare_name <label> <value>
  case "$2" in
    */*) die "$1 must be a bare name (no '/')" ;;
    .*) die "$1 must not start with '.' — a dotfile sentinel is invisible to the Stop hook's glob" ;;
    *"|"* | *"$NL"*) die "$1 must not contain '|' or newlines" ;;
  esac
}

OWNER=""
IDS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --owner)
      [ $# -ge 2 ] || die "--owner requires a session id"
      [ -z "$OWNER" ] || die "--owner given more than once"
      OWNER="$2"; shift 2 ;;
    --owner=*)
      [ -z "$OWNER" ] || die "--owner given more than once"
      OWNER="${1#--owner=}"; shift ;;
    -*) die "unknown option '$1' (usage: ops-adopt.sh --owner <sid> <task-id>...)" ;;
    *) IDS+=("$1"); shift ;;
  esac
done

[ -n "$OWNER" ] || die "missing --owner (usage: ops-adopt.sh --owner <sid> <task-id>...)"
check_bare_name "owner" "$OWNER"
[ "${#IDS[@]}" -gt 0 ] || die "name at least one task-id — there is no bulk adopt"
[ -d "$OPDIR" ] || die "no $OPDIR/ in cwd — run ops-init.sh first"

for ID in "${IDS[@]}"; do
  check_bare_name "task-id" "$ID"
  F="$OPDIR/pending/$ID"
  [ -f "$F" ] || die "no open task '$ID' (no sentinel at $F)"
done

for ID in "${IDS[@]}"; do
  F="$OPDIR/pending/$ID"
  PREV=""
  OPENED=""
  CWDLINE=""
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      "session_id: "*) PREV="${line#session_id: }" ;;
      "opened_at: "*)  OPENED="$line" ;;
      "cwd: "*)        CWDLINE="$line" ;;
    esac
  done < "$F"

  # Rewrite via a temp file + mv so a crash mid-write cannot leave a sentinel
  # that parses as unowned (which would silently widen the block to everyone).
  TMP="$F.adopt.$$"
  {
    printf 'session_id: %s\n' "$OWNER"
    if [ -n "$CWDLINE" ]; then printf '%s\n' "$CWDLINE"; else printf 'cwd: %s\n' "$PWD"; fi
    if [ -n "$OPENED" ]; then printf '%s\n' "$OPENED"; fi
    printf 'adopted_at: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  } > "$TMP"
  mv "$TMP" "$F"

  echo "adopted $ID: ${PREV:-<unowned>} -> $OWNER"
done
