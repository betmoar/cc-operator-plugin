#!/usr/bin/env bash
# ops-task.sh — open a tracked task: drop the sentinel .operator/pending/<id>.
# The Stop hook blocks session end until ops-verdict.sh clears the sentinel.
# Ownership lives in the sentinel NAME: pending/<sid>__<task> is owned,
# pending/<task> is unowned (blocks every session, fail-closed). The body is
# forensics only — nothing parses it for a decision.
# Usage: ops-task.sh <task-id> [--owner <sid>]
set -eu

OPDIR=".operator"

die() { echo "ops-task: $1" >&2; exit 2; }

NL="$(printf '\nx')"; NL="${NL%x}"

# Bare name: '/' would let a later rm -f escape .operator/; '|'/newline break
# the 4-cell ledger; a leading dot is invisible to the Stop hook's glob; '__'
# is the owner/task separator. Keep identical in ops-verdict.sh + ops-adopt.sh.
check_bare_name() { # check_bare_name <label> <value>
  case "$2" in
    */*) die "$1 must be a bare name (no '/')" ;;
    .*) die "$1 must not start with '.' — a dotfile sentinel is invisible to the Stop hook's glob" ;;
    *"|"* | *"$NL"*) die "$1 must not contain '|' or newlines" ;;
    *__*) die "$1 must not contain '__' (it separates owner from task in the sentinel name)" ;;
  esac
}

# Owners refuse whitespace (a padded owner is permanently foreign — a
# silently disarmed gate); task ids do NOT (legacy spaced ids must close).
# Owners also refuse shell metacharacters (#89): an unexpanded `$S` from a
# quoted heredoc reads as a foreign session id, so the sentinel it names is
# permanently unclearable — the same hazard the whitespace rule exists for.
# Keep identical in ops-verdict.sh + ops-adopt.sh (check_guard_parity).
check_owner_name() { # check_owner_name <value>
  check_bare_name "owner" "$1"
  case "$1" in
    *[[:space:]]*) die "owner must not contain whitespace — it could never match a real session id, leaving the task permanently unblockable" ;;
    *'$'* | *'`'* | *"'"* | *'"'* | *\\*) die "owner contains a shell metacharacter — this looks like an UNEXPANDED variable, not a session id. A literal like \$S is read by every ledger consumer as a foreign session, so its HANDOFF-MARK clears nothing and its sentinel is unclearable" ;;
  esac
}

ID=""
OWNER=""
while [ $# -gt 0 ]; do
  case "$1" in
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

# ONE sentinel per task-id: look for the task under any owner first, or a
# second opener creates a second file instead of hitting O_EXCL.
sentinel_for() { # sentinel_for <task-id> → path, or empty
  local _t="$1" _f
  shopt -s nullglob
  for _f in "$OPDIR/pending/$_t" "$OPDIR/pending"/*__"$_t"; do
    # -e OR -L: -e is false for a dangling symlink; a planted entry must be
    # found and refused, not stepped around.
    { [ -e "$_f" ] || [ -L "$_f" ]; } && { printf '%s\n' "$_f"; break; }
  done
  shopt -u nullglob
}
EXISTING="$(sentinel_for "$ID")"
if [ -n "$EXISTING" ]; then
  if [ -f "$EXISTING" ] && [ ! -L "$EXISTING" ]; then
    echo "already open: $ID (ownership unchanged — use ops-adopt.sh to re-stamp)"
    exit 0
  fi
  die "cannot open $ID: $EXISTING is not a regular file (a non-regular entry, symlink, or unwritable path already exists there) — remove it or choose another id"
fi

# CLAIM the unowned name (O_EXCL only arbitrates the SAME path), then rename
# to the owner. A crash between leaves an unowned sentinel: fail-closed.
CLAIM="$OPDIR/pending/$ID"
SENTINEL="$OPDIR/pending/${OWNER:+${OWNER}__}$ID"

# set -C makes > use O_EXCL — a test-then-write is a TOCTOU.
set -C
# Whole test's fd 2 silenced: bash reports the redirection failure OUTSIDE a
# body-level 2>/dev/null; we emit our own message below.
if { { printf 'cwd: %s\n' "$PWD"
     printf 'opened_at: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
   } > "$CLAIM"
   } 2>/dev/null; then
  set +C
  # The claim is ours; stamp the owner into the name.
  if [ "$CLAIM" != "$SENTINEL" ]; then mv "$CLAIM" "$SENTINEL"; fi
  # POST-RENAME RE-CHECK: the mv frees the claim path, so a racer can mint a
  # second sentinel. Die, don't clean up — which is legit is not ours to decide.
  if [ -n "$OWNER" ]; then
    shopt -s nullglob
    for _dup in "$OPDIR/pending"/*__"$ID"; do
      [ "$_dup" = "$SENTINEL" ] && continue
      die "duplicate sentinel detected: $_dup exists beside $SENTINEL — two sessions raced the same task-id; resolve in .operator/pending/ by hand (keep the intended owner's sentinel)"
    done
    shopt -u nullglob
  fi
else
  _rc=$?; set +C
  # Only a REGULAR file is a legit already-open (P1): anything else conflated
  # with EEXIST reads "already open" while the Stop hook refuses to count it.
  # -L is load-bearing: -f follows symlinks.
  if [ -f "$CLAIM" ] && [ ! -L "$CLAIM" ]; then
    echo "already open: $ID (ownership unchanged — use ops-adopt.sh to re-stamp)"
    exit 0
  else
    die "cannot create sentinel $CLAIM (a non-regular entry, symlink, or unwritable path already exists there) — remove it or choose another id"
  fi
fi

if [ -n "$OWNER" ]; then
  echo "opened $ID owned by $OWNER (sentinel $SENTINEL — cleared only by ops-verdict.sh)"
else
  echo "opened $ID UNOWNED — blocks every session's Stop; pass --owner <sid> to scope it"
fi
