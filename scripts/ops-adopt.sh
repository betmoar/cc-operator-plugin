#!/usr/bin/env bash
# ops-adopt.sh — re-stamp the ownership of open task sentinels.
#
# Why this exists: a session id rotates on /clear. Without adoption, a session's
# OWN open tasks would look foreign to its Stop hook after a clear and silently
# stop gating it — the gate would weaken at exactly the moment the operator's
# context was wiped. Adoption is therefore RECOVERY PROTOCOL step 6 of 7, just
# before resuming the first incomplete task.
#
# Explicit ids only. There is deliberately no "adopt everything": a bulk sweep
# in a shared tree is a takeover of another session's tasks by another name.
#
# Usage: run from the project root (cwd):
#   ops-adopt.sh --owner <session-id> <task-id> [<task-id> ...]
set -eu

OPDIR=".operator"
LOCKDIR="$OPDIR/.lock"

die() { echo "ops-adopt: $1" >&2; exit 2; }

# Adoption takes the SAME lock as ops-verdict.sh, and must: ops-verdict validates
# ownership and then clears the sentinel, so an adopt landing between those two
# steps would let the former owner delete the new owner's sentinel. The lock is
# what makes "validate ownership, then act on it" indivisible across both tools.
# Same reclaim-on-timeout semantics as the writer — a stale lock must never make
# a wedged task unrecoverable, since adoption IS the recovery path.
# Reclaim is exclusive — see the long note in ops-verdict.sh. An unconditional
# rmdir+mkdir lets a second waiter delete the first waiter's FRESH lock and
# enter alongside it. Keep the two implementations identical.
LOCK_SPINS=300   # × 0.1s = 30s
lock_acquire() {
  local i=0
  while ! mkdir "$LOCKDIR" 2>/dev/null; do
    i=$((i+1))
    if [ "$i" -ge "$LOCK_SPINS" ]; then
      if mkdir "$LOCKDIR.reclaim" 2>/dev/null; then
        echo "ops-adopt: warning — lock $LOCKDIR held >$((LOCK_SPINS / 10))s; assuming a crashed holder and reclaiming it" >&2
        rmdir "$LOCKDIR" 2>/dev/null || true
        if mkdir "$LOCKDIR" 2>/dev/null; then
          rmdir "$LOCKDIR.reclaim" 2>/dev/null || true
          break
        fi
        rmdir "$LOCKDIR.reclaim" 2>/dev/null || true
        echo "ops-adopt: warning — could not reclaim $LOCKDIR; proceeding unlocked" >&2
        return 0
      fi
      i=0     # another waiter is reclaiming; wait for it, do not also reclaim
    fi
    sleep 0.1
  done
  LOCK_HELD=1
  trap 'lock_release' EXIT
  trap 'lock_release; exit 130' INT
  trap 'lock_release; exit 143' TERM
}
lock_release() {
  if [ "${LOCK_HELD:-0}" = "1" ]; then rmdir "$LOCKDIR" 2>/dev/null || true; LOCK_HELD=0; fi
}

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

# Owners refuse whitespace; task ids deliberately do NOT — see ops-task.sh.
# Adoption is a RECOVERY path: it must be able to name a legacy task id, or a
# wedged pre-0.4 sentinel has no way out at all.
check_owner_name() { # check_owner_name <value>
  check_bare_name "owner" "$1"
  case "$1" in
    *[[:space:]]*) die "owner must not contain whitespace — it could never match a real session id, leaving the task permanently unblockable" ;;
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
check_owner_name "$OWNER"
# ${IDS+"${IDS[@]}"} throughout: on macOS /bin/bash 3.2, "${EMPTY[@]}" under
# `set -u` is an unbound-variable error, not an empty list. Same idiom as
# ops-verdict.sh's POS array. Do not rely on the length check below to mask it.
[ "${#IDS[@]}" -gt 0 ] || die "name at least one task-id — there is no bulk adopt"
[ -d "$OPDIR" ] || die "no $OPDIR/ in cwd — run ops-init.sh first"

for ID in ${IDS+"${IDS[@]}"}; do
  check_bare_name "task-id" "$ID"
done

# Everything below mutates ownership, so it runs under the writer's lock:
# validate-then-rewrite must be indivisible against a concurrent ops-verdict.sh.
lock_acquire

for ID in ${IDS+"${IDS[@]}"}; do
  F="$OPDIR/pending/$ID"
  [ -f "$F" ] || die "no open task '$ID' (no sentinel at $F)"
done

for ID in ${IDS+"${IDS[@]}"}; do
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
  #
  # The temp file lives OUTSIDE pending/: the Stop hook globs that directory and
  # treats every entry as a task id, so a crashed adopt would leave a phantom
  # pending task ("T-1.adopt.4242") that blocks the session and can be closed
  # into the ledger as a garbage row. Found in review of this branch.
  TMP="$OPDIR/.adopt.$$.$ID"
  {
    printf 'session_id: %s\n' "$OWNER"
    if [ -n "$CWDLINE" ]; then printf '%s\n' "$CWDLINE"; else printf 'cwd: %s\n' "$PWD"; fi
    if [ -n "$OPENED" ]; then printf '%s\n' "$OPENED"; fi
    printf 'adopted_at: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  } > "$TMP"
  # Belt and braces: the lock already excludes a concurrent ops-verdict.sh, so
  # this can only fire if the lock was reclaimed from a crashed holder. Keep it
  # — resurrecting a sentinel for a task that already has a verdict row is the
  # exact ledger-damaging trap this branch exists to remove.
  if [ ! -f "$F" ]; then
    rm -f "$TMP"
    die "task '$ID' was closed while adopting — not resurrecting its sentinel"
  fi
  mv "$TMP" "$F"

  echo "adopted $ID: ${PREV:-<unowned>} -> $OWNER"
done

lock_release
