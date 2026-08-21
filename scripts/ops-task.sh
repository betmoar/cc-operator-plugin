#!/usr/bin/env bash
# ops-task.sh — open a tracked task: drop the sentinel .operator/pending/<id>.
# The Stop hook blocks session end until ops-verdict.sh clears the sentinel.
# Ownership lives in the sentinel NAME: pending/<sid>__<task> is owned,
# pending/<task> is unowned (blocks every session, fail-closed). The body is
# forensics only — nothing parses it for a decision.
# Usage: ops-task.sh <task-id> [--owner <sid>]
#        ops-task.sh --exempt "<reason>" --owner <sid>   (audited arm-gate escape)
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
check_owner_name() { # check_owner_name <value>
  check_bare_name "owner" "$1"
  case "$1" in
    *[[:space:]]*) die "owner must not contain whitespace — it could never match a real session id, leaving the task permanently unblockable" ;;
    # .armed/ is one flat namespace for <sid> (derived) and <sid>.exempt (G3
    # grant) — an owner ending .exempt could forge or destroy a grant (#30).
    *.exempt) die "owner must not end in '.exempt' — that suffix is reserved for G3 exemption markers in .armed/, and an owner carrying it would forge or destroy one" ;;
  esac
}

ID=""
OWNER=""
EXEMPT=""       # the reason text
EXEMPT_SEEN=0   # distinguishes a MISSING reason from "no --exempt" (G3.2)
while [ $# -gt 0 ]; do
  case "$1" in
    # --exempt is mutually exclusive with a task id: it IS the no-open-task path.
    --exempt)
      [ "$EXEMPT_SEEN" -eq 0 ] || die "--exempt given more than once"
      EXEMPT_SEEN=1
      [ $# -ge 2 ] || die "--exempt requires a non-empty reason"
      # A reason starting with '-' is a forgotten reason — refuse at the mistake.
      case "$2" in
        -*) die "--exempt requires a reason, got the flag '$2' — quote the reason: --exempt \"<reason>\" --owner <sid>" ;;
      esac
      EXEMPT="$2"; shift 2 ;;
    --exempt=*)
      [ "$EXEMPT_SEEN" -eq 0 ] || die "--exempt given more than once"
      EXEMPT_SEEN=1
      EXEMPT="${1#--exempt=}"; shift ;;
    # A duplicated --owner means the caller is confused about ownership — refuse.
    --owner)
      [ $# -ge 2 ] || die "--owner requires a session id"
      [ -z "$OWNER" ] || die "--owner given more than once"
      OWNER="$2"; shift 2 ;;
    --owner=*)
      [ -z "$OWNER" ] || die "--owner given more than once"
      OWNER="${1#--owner=}"; shift ;;
    -*) die "unknown option '$1' (usage: ops-task.sh <task-id> [--owner <sid>] | ops-task.sh --exempt \"<reason>\" --owner <sid>)" ;;
    *)
      [ -z "$ID" ] || die "unexpected extra argument '$1'"
      ID="$1"; shift ;;
  esac
done

# --- the exemption grant (G3): no lock here — the ledger append is
# delegated to ops-verdict.sh, the single writer (G3.6 pins zero acquires).
if [ "$EXEMPT_SEEN" -eq 1 ]; then
  [ -z "$ID" ] || die "--exempt takes no task-id (got '$ID') — an exemption is the no-open-task path; open a task instead if you have one"
  [ -n "$EXEMPT" ] || die "--exempt requires a non-empty reason (the grant is audited: the reason is what the handoff presents)"
  [ -n "$OWNER" ] || die "--exempt requires --owner <sid> — the GATE-EXCEPTION must carry a [sid:] tag and the marker is keyed by session"
  check_owner_name "$OWNER"
  [ -d "$OPDIR" ] || die "no $OPDIR/ in cwd — run ops-init.sh first"

  # The single writer is our sibling; $OPDIR/bin covers a bare PATH call.
  case "${BASH_SOURCE[0]}" in
    */*) _tdir="${BASH_SOURCE[0]%/*}" ;;
    *)   _tdir="$OPDIR/bin" ;;
  esac
  VERDICT_CLI="$_tdir/ops-verdict.sh"
  [ -f "$VERDICT_CLI" ] || VERDICT_CLI="$OPDIR/bin/ops-verdict.sh"
  [ -f "$VERDICT_CLI" ] || die "cannot find ops-verdict.sh next to this script or in $OPDIR/bin — the exemption's ledger write is delegated to it (run ops-init.sh)"

  # LEDGER FIRST: a marker without its row is an unaudited bypass.
  bash "$VERDICT_CLI" --exempt-mark "$EXEMPT" --owner "$OWNER" >/dev/null \
    || die "delegated ledger write failed — no exemption granted (nothing was marked)"

  # .exempt has its own lifetime (the recompute never touches it). Failures
  # DIE: the row is written, and a swallowed failure lies about being exempt.
  { mkdir -p "$OPDIR/.armed" && : > "$OPDIR/.armed/$OWNER.exempt"; } 2>/dev/null \
    || die "GATE-EXCEPTION was recorded but $OPDIR/.armed/$OWNER.exempt could not be created — the session is NOT exempt; fix the permissions and re-run"
  echo "exemption granted for session $OWNER (GATE-EXCEPTION written to $OPDIR/DECISIONS.md — Stop is now blocked until you present it: ops-verdict.sh --mark-handoff --owner $OWNER)"
  exit 0
fi

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

# --- arm marker (G2.1): sentinel first (stale-true degrades safely). Only
# with --owner. No lock. Failures swallowed — an unwritable .operator/ must
# not break task-opening itself.
arm_marker() { # arm_marker <session-id>
  mkdir -p "$OPDIR/.armed" 2>/dev/null && : > "$OPDIR/.armed/$1"
}

if [ -n "$OWNER" ]; then
  arm_marker "$OWNER" || true
  echo "opened $ID owned by $OWNER (sentinel $SENTINEL — cleared only by ops-verdict.sh)"
else
  echo "opened $ID UNOWNED — blocks every session's Stop; pass --owner <sid> to scope it"
fi
