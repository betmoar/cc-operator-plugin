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
check_bare_name() { # check_bare_name <label> <value>
  case "$2" in
    */*) die "$1 must be a bare name (no '/')" ;;
    .*) die "$1 must not start with '.' — a dotfile sentinel is invisible to the Stop hook's glob" ;;
    *"|"* | *"$NL"*) die "$1 must not contain '|' or newlines" ;;
  esac
}

# OWNERS additionally refuse whitespace, and TASK IDS deliberately do not.
# The Stop hook compares the stamped owner byte-for-byte against the payload's
# session id, so an owner with a stray space can never equal any real session:
# the sentinel is FOREIGN forever and foreign sentinels never block — a silently
# disarmed gate. That reasoning is about session ids and does not transfer to
# task ids. Applying it to both wedged pre-0.4 tasks whose ids contain a space
# (0.3.0 accepted them): the hook still blocked on the sentinel while every
# closing path refused the id, so the session could never stop at all — the
# exact trap this release removes. Keep the two guards separate.
check_owner_name() { # check_owner_name <value>
  check_bare_name "owner" "$1"
  case "$1" in
    *[[:space:]]*) die "owner must not contain whitespace — it could never match a real session id, leaving the task permanently unblockable" ;;
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
if [ -n "$OWNER" ]; then check_owner_name "$OWNER"; fi
[ -d "$OPDIR" ] || die "no $OPDIR/ in cwd — run ops-init.sh first"

mkdir -p "$OPDIR/pending"

# Create the sentinel ATOMICALLY. A test-then-write (`[ -e ] || > file`) is a
# TOCTOU: two sessions opening the same id both pass the check, both truncate,
# and the later write silently replaces the earlier session's ownership —
# breaking the documented no-takeover guarantee. Measured at 155/200 trials
# before this fix (found by Codex review).
#
# `set -C` makes `>` use O_EXCL: exactly one opener wins, the loser sees EEXIST
# and reports the task as already open. No lock needed — the kernel arbitrates.
set -C
# The redirection failure (EEXIST on a real sentinel, EISDIR on a directory,
# ENOENT through a dangling symlink) is reported by bash on fd 2 OUTSIDE the
# scope of any `2>/dev/null` on the compound body — the "a raw bash error as
# operator guidance" landmine (review-pilot finding #3). Redirect the whole
# test's fd 2 to silence bash's message; we emit our own precise one below.
if { { if [ -n "$OWNER" ]; then printf 'session_id: %s\n' "$OWNER"; fi
     printf 'cwd: %s\n' "$PWD"
     printf 'opened_at: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
   } > "$OPDIR/pending/$ID"
   } 2>/dev/null; then
  set +C
else
  _rc=$?; set +C
  # The redirection failed. O_EXCL makes this EEXIST when a real sentinel
  # already exists — the legit "already open" path. But the SAME redirection
  # fails for a non-regular entry (a directory, a dangling symlink) or a
  # permission/ENOSPC error, and conflating those with EEXIST is a fail-OPEN
  # in the gate: we'd print "already open, ownership unchanged" and exit 0,
  # while the Stop hook's `-f` guard refuses to count a non-regular entry as a
  # task — so the operator is told a task is tracked and the session stops
  # unblocked. Two components disagreeing about what a task is, silently off
  # (P1, found by the review-panel pilot 2026-07-29). Distinguish: only a
  # pre-existing REGULAR FILE is a legit already-open; anything else is a
  # fault we refuse rather than misreport. The `-L` test is load-bearing:
  # `-f` FOLLOWS symlinks, so a symlink→regular file reads as "already open"
  # (exit 0) without it — telling the operator a planted entry is live tracked
  # work. (NOT a data-overwrite hazard: mv/rename(2) replaces a destination
  # symlink itself, never its target — measured 2026-08-04. The real exposure
  # is read-side laundering: a reader that follows the link treats a file our
  # CLIs never wrote as a sentinel; every reader now carries this same -L
  # rejection.) A symlink is never a sentinel we wrote.
  if [ -f "$OPDIR/pending/$ID" ] && [ ! -L "$OPDIR/pending/$ID" ]; then
    echo "already open: $ID (ownership unchanged — use ops-adopt.sh to re-stamp)"
    exit 0
  else
    die "cannot create sentinel $OPDIR/pending/$ID (a non-regular entry, symlink, or unwritable path already exists there) — remove it or choose another id"
  fi
fi

if [ -n "$OWNER" ]; then
  echo "opened $ID owned by $OWNER (sentinel $OPDIR/pending/$ID — cleared only by ops-verdict.sh)"
else
  echo "opened $ID UNOWNED — blocks every session's Stop; pass --owner <sid> to scope it"
fi
