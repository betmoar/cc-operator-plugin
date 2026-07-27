#!/usr/bin/env bash
# ops-task.sh — open a tracked task: drop the sentinel .operator/pending/<id>.
# The Stop hook blocks session end until ops-verdict.sh clears the sentinel
# (verdict row or --defer). Idempotent: re-opening an open id is a no-op —
# including its ownership, so re-opening can never be a silent takeover.
#
# The sentinel body stamps who opened it, so the Stop hook can block only the
# OWNING session and merely report everyone else's open tasks:
#
#   session_id: <id>     omitted when unknown → unowned → blocks every session
#   cwd: <path>          forensics only (the hook enumerates by payload cwd)
#   opened_at: <ISO8601>
#
# The agent learns its session id from the SessionStart hook's injected context;
# CLAUDE_SESSION_ID is NOT set in the Bash tool environment.
#
# Usage: run from the project root (cwd):  ops-task.sh <task-id> [--owner <sid>]
set -eu

OPDIR=".operator"

die() { echo "ops-task: $1" >&2; exit 2; }

NL="$(printf '\nx')"; NL="${NL%x}"

# A bare name: it is a filename (sentinel, and downstream a fragment file), so
# a '/' would let a later rm -f reach outside .operator/ — the 2026-07-10
# traversal bug. '|' and newlines would break the one-line 4-cell ledger schema.
# A LEADING DOT is refused because the Stop hook enumerates pending/ with a
# plain glob, which does not match dotfiles: `.hidden` would be a sentinel the
# gate cannot see — an open task that silently never blocks. Keep this rule
# identical in ops-verdict.sh and ops-adopt.sh (tests/test-scripts.sh case 12
# asserts all three agree).
# Whitespace is refused for a specific reason: the Stop hook compares the
# stamped owner byte-for-byte against the payload's session id, so an owner with
# a stray space can never equal any real session — the sentinel is classified
# FOREIGN forever, and foreign sentinels never block. That is a silently
# disarmed gate, not a typo. (Found in review of 0.4.0: `--owner " SESS-A"` →
# hook exits 0 with the task still open.)
check_bare_name() { # check_bare_name <label> <value>
  case "$2" in
    */*) die "$1 must be a bare name (no '/')" ;;
    .*) die "$1 must not start with '.' — a dotfile sentinel is invisible to the Stop hook's glob" ;;
    *"|"* | *"$NL"*) die "$1 must not contain '|' or newlines" ;;
    *[[:space:]]*) die "$1 must not contain whitespace — it would never match a real session id, leaving the task permanently unblockable" ;;
  esac
}

ID=""
OWNER=""
while [ $# -gt 0 ]; do
  case "$1" in
    # Refuse a repeated --owner rather than silently taking the last: a
    # duplicated flag means the caller is confused about ownership, which is
    # the one thing this mechanism must not guess at.
    --owner)
      [ $# -ge 2 ] || die "--owner requires a session id"
      [ -z "$OWNER" ] || die "--owner given more than once"
      OWNER="$2"; shift 2 ;;
    --owner=*)
      [ -z "$OWNER" ] || die "--owner given more than once"
      OWNER="${1#--owner=}"; shift ;;
    -*) die "unknown option '$1' (usage: ops-task.sh <task-id> [--owner <sid>])" ;;
    *)
      [ -z "$ID" ] || die "unexpected extra argument '$1'"
      ID="$1"; shift ;;
  esac
done

[ -n "$ID" ] || die "missing task-id (usage: ops-task.sh <task-id> [--owner <sid>])"
check_bare_name "task-id" "$ID"
if [ -n "$OWNER" ]; then check_bare_name "owner" "$OWNER"; fi
[ -d "$OPDIR" ] || die "no $OPDIR/ in cwd — run ops-init.sh first"

mkdir -p "$OPDIR/pending"

if [ -e "$OPDIR/pending/$ID" ]; then
  echo "already open: $ID (ownership unchanged — use ops-adopt.sh to re-stamp)"
  exit 0
fi

{
  if [ -n "$OWNER" ]; then printf 'session_id: %s\n' "$OWNER"; fi
  printf 'cwd: %s\n' "$PWD"
  printf 'opened_at: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
} > "$OPDIR/pending/$ID"

if [ -n "$OWNER" ]; then
  echo "opened $ID owned by $OWNER (sentinel $OPDIR/pending/$ID — cleared only by ops-verdict.sh)"
else
  echo "opened $ID UNOWNED — blocks every session's Stop; pass --owner <sid> to scope it"
fi
