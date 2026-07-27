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
# A stale lock must never make a wedged task unrecoverable, since adoption IS the
# recovery path — hence the same degrade-never-hang discipline as the writer.
# >>> LOCK BLOCK — byte-identical in ops-verdict.sh and ops-adopt.sh.
# They contend on the same .operator/.lock, so a divergence here is not a style
# problem; it is two different ideas of mutual exclusion. The "no drift" case in
# tests/test-scripts.sh compares everything between these markers, with the tool
# name in warnings normalized away. Edit both, or the build fails.
#
# mkdir is atomic on every POSIX FS; flock(1) is absent on macOS.
#
# A stale lock must never cost a real verdict, so a waiter degrades rather than
# failing. But "stale" is a judgement, and how it is made is the whole design.
#
# The first draft of this lock (earlier on this branch, never released) inferred
# it from ELAPSED TIME — hold the lock longer than the budget and you were
# presumed crashed. That cannot distinguish a slow holder from a dead one, and
# the difference is not academic: a --reconcile over a large ledger genuinely ran
# past the budget, a concurrent writer reclaimed its lock, and both sat inside
# the critical section (audit F03). F03 bounded the TRIGGER by capping fragment
# size; it left the inference in place. Reproduced directly before this change:
# a live writer holding the lock 30s got told it was "a crashed writer".
#
# So the holder now IDENTIFIES itself — host, uid, pid — and waiters ask the
# kernel instead of the clock:
#
#   confirmed dead        → reclaim at once (the timed draft made every waiter
#                           behind a crashed holder sit out the budget: 34s)
#   confirmed alive       → NEVER reclaim, however long it runs. Wait a longer
#                           budget, then proceed unlocked — the milder failure.
#                           Stealing a running writer's lock is the failure this
#                           whole block exists to prevent.
#   cannot be judged      → fall back to the timed budget.
#
# The third case is load-bearing and is reached constantly — it is not a
# compatibility leftover. Two ways in:
#
#   1. `mkdir` and the stamp are NOT one atomic step. Between them the lock is
#      legitimately held and not yet stamped (observed in 400/400 samples), so
#      any waiter spinning through that window sees no record. Judging it would
#      reclaim a lock somebody just took.
#   2. `kill -0` against another user's process fails with EPERM, which reads
#      identically to "dead". Judging a foreign uid would reclaim a LIVE lock.
#
# Both are the fail-OPEN direction, so only our own host and uid are judgeable
# and everything else degrades to the timed path — bounded, and no worse than
# what this replaced.
#
# Reclaim is itself a critical section, and identified death makes that sharper
# rather than softer: two waiters now see the same dead holder in the same
# instant and race, where before they arrived 30s apart by luck. An
# unconditional `rmdir` + `mkdir` lets waiter B delete waiter A's FRESH lock and
# enter beside it — two writers inside, neither over budget (found by Codex
# review). The removal must itself be exclusive: claim the right to reclaim by
# atomically creating a separate marker; only its winner may touch the lock.
#
# The claim marker must ITSELF expire. A first version deferred to it forever,
# so a process killed between creating and removing it wedged every later writer
# — strictly worse than the stale lock it fixed, which at least proceeded after
# one budget (found by Codex review). Bounded deferral, then it is presumed
# abandoned. An unexpirable claim is a deadlock with extra steps.
LOCK_SPINS=300        # × 0.1s = 30s before an UNJUDGEABLE holder is presumed dead
LOCK_LIVE_SPINS=600   # × 0.1s = 60s to wait on a CONFIRMED-LIVE holder, then go unlocked
RECLAIM_WAIT=50       # × 0.1s = 5s to let a LIVE reclaimer finish (it needs ms)
LOCK_DEFERS_MAX=2     # short waits to grant before treating the claim as dead

LOCK_HELD=0
LOCK_MINE=""
LOCK_HOLDER_REC=""

# host + uid + pid: the three facts needed to decide whether `kill -0` can answer
# for this holder at all. Written INSIDE the lock we already hold, so it never
# races for CORRECTNESS — mkdir remains the only thing arbitrating entry. It is
# not, however, simultaneous with the mkdir: see the held-but-unstamped window
# above, which is exactly why an absent stamp must read as unjudgeable and never
# as dead.
holder_stamp() { printf '%s %s %s' "${HOSTNAME:-nohost}" "${UID:-0}" "$$"; }

# Read the holder stamp into LOCK_HOLDER_REC ("" when absent or unreadable).
# Bounded at 128 chars: this runs on every spin of every waiter, and every reader
# in this codebase is byte-bounded — a line cap is not a byte cap (see
# docs/PLAYBOOK.md, "adding a reader of a file"). Assigns to a global instead of
# printing so a contended waiter does not fork a subshell ten times a second.
lock_holder_read() {
  LOCK_HOLDER_REC=""
  [ -f "$LOCKDIR/holder" ] || return 0
  IFS= read -r -n 128 LOCK_HOLDER_REC < "$LOCKDIR/holder" 2>/dev/null || true
  LOCK_HOLDER_REC="${LOCK_HOLDER_REC%$'\r'}"
}

# 0 = alive · 1 = confirmed dead · 2 = cannot judge (caller must fall back).
holder_state() { # holder_state <record>
  local rec="$1" host uid pid
  [ -n "$rec" ] || return 2
  host="${rec%% *}"; rec="${rec#* }"
  uid="${rec%% *}"; pid="${rec##* }"
  [ "$host" = "${HOSTNAME:-nohost}" ] || return 2
  [ "$uid" = "${UID:-0}" ] || return 2
  case "$pid" in ''|*[!0-9]*) return 2 ;; esac
  kill -0 "$pid" 2>/dev/null && return 0
  return 1
}

lock_acquire() {
  local i=0 defers=0 state=2 rec0=""
  while ! mkdir "$LOCKDIR" 2>/dev/null; do
    i=$((i+1))
    lock_holder_read
    # `holder_state` reports through its EXIT STATUS, and a nonzero status from a
    # bare call trips `set -e` — the script exited 1 before doing any work. The
    # `|| state=$?` idiom is what makes a status-reporting function safe here.
    state=0; holder_state "$LOCK_HOLDER_REC" || state=$?

    if [ "$state" -eq 0 ]; then
      # Confirmed alive. Never reclaim — wait, then degrade to unlocked. This is
      # the case the timed draft got wrong (audit F03).
      if [ "$i" -ge "$LOCK_LIVE_SPINS" ]; then
        echo "ops-adopt: warning — lock $LOCKDIR held by a LIVE process for >$((LOCK_LIVE_SPINS / 10))s; proceeding unlocked rather than stealing a running writer's lock" >&2
        return 0
      fi
      sleep 0.1
      continue
    fi

    if [ "$state" -eq 1 ] || [ "$i" -ge "$LOCK_SPINS" ]; then
      if mkdir "$LOCKDIR.reclaim" 2>/dev/null; then
        # Re-verify under the claim. Between judging the holder and acting on it,
        # the lock may have been released and retaken by a healthy process;
        # reclaiming then would delete a LIVE holder's lock through the back door.
        rec0="$LOCK_HOLDER_REC"
        lock_holder_read
        if [ "$LOCK_HOLDER_REC" != "$rec0" ]; then
          rmdir "$LOCKDIR.reclaim" 2>/dev/null || true
          sleep 0.1
          continue
        fi
        if [ "$state" -eq 1 ]; then
          echo "ops-adopt: warning — lock $LOCKDIR was held by process ${LOCK_HOLDER_REC##* }, which is gone; reclaiming it" >&2
        else
          echo "ops-adopt: warning — lock $LOCKDIR held >$((LOCK_SPINS / 10))s and its holder cannot be identified; assuming a crashed writer and reclaiming it" >&2
        fi
        rm -f "$LOCKDIR/holder" 2>/dev/null || true
        rmdir "$LOCKDIR" 2>/dev/null || true
        if mkdir "$LOCKDIR" 2>/dev/null; then
          rmdir "$LOCKDIR.reclaim" 2>/dev/null || true
          break                       # we now hold the lock
        fi
        rmdir "$LOCKDIR.reclaim" 2>/dev/null || true
        echo "ops-adopt: warning — could not reclaim $LOCKDIR; proceeding unlocked" >&2
        return 0
      fi
      # Someone else holds the reclaim claim. A LIVE reclaimer needs only
      # milliseconds, so grant it a SHORT wait — not another full budget, which
      # would turn a crashed claimer into minutes of stalling. After a couple of
      # short waits the claim is dead, not slow.
      defers=$((defers + 1))
      if [ "$defers" -gt "$LOCK_DEFERS_MAX" ]; then
        echo "ops-adopt: warning — reclaim claim $LOCKDIR.reclaim abandoned; clearing it" >&2
        rmdir "$LOCKDIR.reclaim" 2>/dev/null || true
        defers=0
      fi
      i=$((LOCK_SPINS - RECLAIM_WAIT))
    fi
    sleep 0.1
  done
  LOCK_HELD=1
  LOCK_MINE="$(holder_stamp)"
  printf '%s\n' "$LOCK_MINE" > "$LOCKDIR/holder" 2>/dev/null || true
  trap 'lock_release' EXIT
  # A signal handler that only releases would let bash RESUME the critical
  # section with the lock already gone. Release and exit.
  trap 'lock_release; exit 130' INT
  trap 'lock_release; exit 143' TERM
}

lock_release() {
  [ "${LOCK_HELD:-0}" = "1" ] || return 0
  LOCK_HELD=0
  # If the lock no longer names us, someone reclaimed it while we were inside the
  # critical section. Removing it now would delete the NEW holder's lock and let
  # a third writer in — the same displacement, one step further along. Report and
  # leave it alone; the report is what the reclaim-exclusivity test observes.
  lock_holder_read
  if [ -n "$LOCK_MINE" ] && [ -n "$LOCK_HOLDER_REC" ] && [ "$LOCK_HOLDER_REC" != "$LOCK_MINE" ]; then
    echo "ops-adopt: warning — $LOCKDIR was reclaimed while this process held it; not releasing another holder's lock" >&2
    return 0
  fi
  rm -f "$LOCKDIR/holder" 2>/dev/null || true
  rmdir "$LOCKDIR" 2>/dev/null || true
}
# <<< LOCK BLOCK

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
  # `read -r -n 512` + a 20-line cap, matching every other reader: a plain
  # `read -r` is bounded by LINES, not bytes, so one newline-less line is a
  # single "line" and gets slurped whole — measured 16.77s on a 256MB sentinel.
  # (Audit F02.)
  #
  # Trailing \r is stripped from the fields we COPY FORWARD. session_id is
  # regenerated clean below, but cwd:/opened_at: were passed through verbatim,
  # and opened_at is echoed into the Stop hook's foreign-task report — where a
  # bare CR carriage-returns the terminal mid-line and eats the operator's
  # guidance. A CRLF sentinel is an ordinary checkout artifact. (Audit F04.)
  n=0
  while IFS= read -r -n 512 line || [ -n "$line" ]; do
    n=$((n+1)); [ "$n" -le 20 ] || break
    line="${line%$'\r'}"
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
