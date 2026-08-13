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
LOCK_SPINS=${LOCK_SPINS:-300}        # × 0.1s = 30s before an UNJUDGEABLE holder is presumed dead
LOCK_LIVE_SPINS=${LOCK_LIVE_SPINS:-600}   # × 0.1s = 60s to wait on a CONFIRMED-LIVE holder, then go unlocked
RECLAIM_WAIT=${RECLAIM_WAIT:-50}       # × 0.1s = 5s to let a LIVE reclaimer finish (it needs ms)
LOCK_DEFERS_MAX=2     # short waits to grant before treating the claim as dead

# Validate the env-overridable budgets. ${VAR:-default} only guards EMPTY, not
# non-numeric — `[ "$i" -ge "$LOCK_SPINS" ]` with LOCK_SPINS=abc errors inside
# the `if` (status 2), set -e does not fire on a failed test, and the spin loop
# never exits → infinite hang, sentinel never clears, Stop blocks the session
# forever (review F-A). LOCK_SPINS=0 collapses the unjudgeable-holder budget to
# zero → instant reclaim of a holder that should sit out the full budget (the
# F03 displacement class; review F-B). Reject both: a positive integer, or die.
# This block is inside the LOCK BLOCK and must stay byte-identical in the sibling CLI.
_lock_is_posint() { case "$1" in ''|*[!0-9]*) return 1 ;; esac; [ "$1" -ge 1 ]; }
_lock_budget_die() { echo "ops-adopt: $1 is not a positive integer (got '$2') — refusing; see LOCK_SPINS/LOCK_LIVE_SPINS/RECLAIM_WAIT" >&2; exit 2; }
_lock_check_budget() { _lock_is_posint "$3" || _lock_budget_die "$1" "$3"; }
_lock_check_budget LOCK_SPINS "$LOCK_SPINS" "$LOCK_SPINS"
_lock_check_budget LOCK_LIVE_SPINS "$LOCK_LIVE_SPINS" "$LOCK_LIVE_SPINS"
# RECLAIM_WAIT must be < LOCK_SPINS, else the backoff `i=$((LOCK_SPINS-RECLAIM_WAIT))`
# goes non-positive and each defer pays the full RECLAIM_WAIT (review F-C).
_lock_check_budget RECLAIM_WAIT "$RECLAIM_WAIT" "$RECLAIM_WAIT"
[ "$RECLAIM_WAIT" -lt "$LOCK_SPINS" ] || _lock_budget_die "RECLAIM_WAIT (must be < LOCK_SPINS)" "$RECLAIM_WAIT"

# The two "proceed unlocked" exits below (a confirmed-LIVE holder outlasting
# LOCK_LIVE_SPINS, and a reclaim we could not win) serialized NOTHING: every
# waiter that gave up entered the critical section at once, which is the
# unarbitrated multi-writer pile-up this whole block exists to prevent — N
# givers-up, not one. They now queue on a SEPARATE mutex, $LOCKDIR.fallback,
# built from the same mkdir + stamp + kernel-judged reclaim idiom (there is no
# flock on macOS, and a one-shot claim dir would dangle on a crash).
#
# RESIDUAL, stated plainly: this reduces N to 1. ONE giver-up may still run
# beside the confirmed-live holder — that is the accepted liveness trade at the
# "confirmed alive" branch above (never block the operator forever), and the
# fallback does not remove it. 1-vs-live-holder is the floor, not zero.
#
# It must NEVER touch $LOCKDIR: a giver-up never owned the real lock, so
# LOCK_HELD stays 0 and lock_release stays a no-op for it. Setting LOCK_HELD=1
# here would make its release rm the LIVE holder's dir — the exact F03
# displacement the "confirmed alive" branch was written to forbid. Hence its own
# state, its own release, and its own budget.
FALLBACK_SPINS=${FALLBACK_SPINS:-50}   # × 0.1s = 5s to wait on a LIVE giver-up, then proceed anyway
_lock_check_budget FALLBACK_SPINS "$FALLBACK_SPINS" "$FALLBACK_SPINS"

LOCK_HELD=0
LOCK_MINE=""
LOCK_HOLDER_REC=""
FALLBACK_DIR="$LOCKDIR.fallback"
FALLBACK_HELD=0
FALLBACK_MINE=""
FALLBACK_REC=""

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

# Same 128-byte bound as lock_holder_read, for the same reason: every reader in
# this codebase is byte-bounded, and this one also runs on a spin.
fallback_holder_read() {
  FALLBACK_REC=""
  [ -f "$FALLBACK_DIR/holder" ] || return 0
  IFS= read -r -n 128 FALLBACK_REC < "$FALLBACK_DIR/holder" 2>/dev/null || true
  FALLBACK_REC="${FALLBACK_REC%$'\r'}"
}

# Queue the givers-up. Returns 0 whether or not the fallback was won: the caller
# proceeds either way — blocking the operator forever is the one outcome worse
# than a second writer, and it is why the real lock degrades in the first place.
# FALLBACK_HELD records which happened.
fallback_acquire() {
  local i=0 fstate=2 rec0=""
  while ! mkdir "$FALLBACK_DIR" 2>/dev/null; do
    i=$((i+1))
    # ONE bound, checked before any branch — it must cover the reclaim path too.
    # A dir we judge dead but cannot rmdir (permissions, a non-empty leftover)
    # would otherwise spin here without even a sleep: an unbounded wait inside
    # the code whose entire purpose is to stay bounded.
    if [ "$i" -ge "$FALLBACK_SPINS" ]; then
      echo "ops-adopt: warning — fallback lock $FALLBACK_DIR held by another degraded writer for >$((FALLBACK_SPINS / 10))s; proceeding without it" >&2
      return 0
    fi
    fallback_holder_read
    fstate=0; holder_state "$FALLBACK_REC" || fstate=$?
    if [ "$fstate" -eq 1 ]; then
      # Confirmed dead: a giver-up crashed holding the fallback. Nothing may
      # dangle here — a one-shot marker with no reclaim would wedge every later
      # giver-up, the unexpirable-claim mistake this block already made once.
      # Re-verify first, exactly as the real reclaim does under its claim: the
      # dir may have been released and retaken between the judgement and the act,
      # and a retaker is briefly held-but-UNSTAMPED, so a changed record (a new
      # stamp, or none) means back off rather than delete someone's fresh dir.
      # No separate .reclaim claim here on purpose: this path is already the
      # degraded one, its worst case is two givers-up instead of one (still
      # bounded, still better than the N this replaces), and a second claim
      # marker is the construct that wedged every writer the first time.
      # Delete the stamp before the dir — rmdir refuses a non-empty directory.
      rec0="$FALLBACK_REC"
      fallback_holder_read
      if [ "$FALLBACK_REC" != "$rec0" ]; then sleep 0.1; continue; fi
      rm -f "$FALLBACK_DIR/holder" 2>/dev/null || true
      rmdir "$FALLBACK_DIR" 2>/dev/null || true
      continue
    fi
    # Alive, or unjudgeable (held-but-unstamped window, foreign uid): wait out
    # the short budget above rather than stealing a running giver-up's dir.
    sleep 0.1
  done
  FALLBACK_HELD=1
  FALLBACK_MINE="$(holder_stamp)"
  printf '%s\n' "$FALLBACK_MINE" > "$FALLBACK_DIR/holder" 2>/dev/null || true
  # The give-up path never installed the real lock's trap (that is set only after
  # a successful acquire), so it installs its own. A crashed giver-up MUST leave
  # a reclaimable dir, not a permanent one.
  # Both releases, same as the real-acquire path: whichever trap is installed
  # last must still clean up what the other one owned.
  trap 'lock_release; fallback_release' EXIT
  trap 'lock_release; fallback_release; exit 130' INT
  trap 'lock_release; fallback_release; exit 143' TERM
  return 0
}

fallback_release() {
  [ "${FALLBACK_HELD:-0}" = "1" ] || return 0
  FALLBACK_HELD=0
  # Same displacement guard as lock_release: if the fallback no longer names us
  # a later giver-up reclaimed it, and removing it would delete THAT holder's dir.
  fallback_holder_read
  if [ -n "$FALLBACK_MINE" ] && [ -n "$FALLBACK_REC" ] && [ "$FALLBACK_REC" != "$FALLBACK_MINE" ]; then
    echo "ops-adopt: warning — $FALLBACK_DIR was reclaimed while this process held it; not releasing another holder's fallback lock" >&2
    return 0
  fi
  rm -f "$FALLBACK_DIR/holder" 2>/dev/null || true
  rmdir "$FALLBACK_DIR" 2>/dev/null || true
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
        # Unlocked with respect to the LIVE holder, but not with respect to the
        # other waiters that gave up in the same instant: queue on the fallback
        # so they enter one at a time. LOCK_HELD stays 0 — we never owned $LOCKDIR.
        fallback_acquire
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
        fallback_acquire      # same reason as the live-holder give-up above
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
  # Both releases, in both handlers: a caller that takes the fallback on one
  # acquire and the real lock on a later one would otherwise have the second
  # trap silently replace the first and leak the fallback dir for the rest of
  # the process's life. Each release is a no-op unless its own HELD flag is set.
  trap 'lock_release; fallback_release' EXIT
  # A signal handler that only releases would let bash RESUME the critical
  # section with the lock already gone. Release and exit.
  trap 'lock_release; fallback_release; exit 130' INT
  trap 'lock_release; fallback_release; exit 143' TERM
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
    # `.armed/` holds TWO marker kinds in ONE flat namespace: `<sid>` (derived
    # cache, the recompute may delete it) and `<sid>.exempt` (a G3 grant, the
    # recompute must never touch it). An owner ending in `.exempt` collides with
    # the second, in BOTH directions (issue #30, measured):
    #   grant   — `ops-task.sh <any-task> --owner foo.exempt` writes
    #             `.armed/foo.exempt`, which the hook reads as session `foo`'s
    #             G3 grant. Session foo goes from denied to allowed with ZERO
    #             GATE-EXCEPTION rows: the audited escape hatch, unaudited.
    #   destroy — a session literally named `foo.exempt` closing an ordinary
    #             task runs `recompute_arm_marker foo.exempt`, whose `rm -f`
    #             deletes foo's REAL exemption while the ledger row still
    #             asserts it holds. The gate silently re-arms against foo.
    # Rejecting the suffix at every writer is the cheap fix; separating the two
    # namespaces (`.armed/derived/` vs `.armed/granted/`) is the structural one
    # and would be a migration. Real session ids are UUIDs, so nothing legitimate
    # is refused here.
    *.exempt) die "owner must not end in '.exempt' — that suffix is reserved for G3 exemption markers in .armed/, and an owner carrying it would forge or destroy one" ;;
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
  # -L BEFORE -f: `-f` FOLLOWS a symlink, so a link planted in pending/ reads
  # as a real sentinel — and the rewrite below would then replace the link with
  # a genuine regular-file sentinel, LAUNDERING an entry that never went
  # through ops-task.sh's O_EXCL create into live tracked work. A symlink is
  # never a sentinel our CLIs wrote; refuse loudly (mirrors ops-task.sh's
  # opener guard — the same F65 rule, applied at the read site).
  [ ! -L "$F" ] || die "sentinel at $F is a symlink — not a sentinel our CLIs wrote; refusing to adopt (remove it and open the task with ops-task.sh)"
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
  # NUL pre-scan (F46): bash drops NULs so no $line test can see one, and bash
  # 3.2's `read -n` stops AT a NUL — a padded chunk passes the length guard and
  # its tail is matched as a fresh line, smuggling a prior owner. Treat the
  # whole body as unusable; the fields below stay empty and are regenerated.
  # Probe the WHOLE file in a LC_ALL=C subshell (F55): a single-shot probe left
  # a NUL past byte 512 undetected. Bytes for both -n and ${#}; EOF exits
  # non-zero so the trailing partial chunk never false-positives.
  if ! (LC_ALL=C _np=0
        while IFS= read -r -d '' -n 512 _nulprobe; do
          _np=$((_np + 1)); [ "$_np" -le 40 ] || exit 1
          [ "${#_nulprobe}" -eq 512 ] || exit 1
        done < "$F") 2>/dev/null; then
    PREV=""; OPENED=""; CWDLINE=""
  else
  n=0
  while IFS= read -r -n 512 line || [ -n "$line" ]; do
    n=$((n+1)); [ "$n" -le 20 ] || break
    # Cap-filling chunk → truncated mid-line; its tail would be matched as a
    # fresh line and smuggle a prior owner. Mirrors ops-stop-hook.sh (F45).
    [ "${#line}" -lt 512 ] || { PREV=""; break; }
    line="${line%$'\r'}"
    case "$line" in
      "session_id: "*) PREV="${line#session_id: }" ;;
      "opened_at: "*)  OPENED="$line" ;;
      "cwd: "*)        CWDLINE="$line" ;;
    esac
  done < "$F"
  fi

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

  # --- arm marker (G2.1) -----------------------------------------------------
  # AFTER the sentinel carries the new owner, under the lock this loop already
  # holds. Adoption is the documented repair for a desynced marker (the arm
  # gate's deny message names this command verbatim): re-stamping ownership and
  # re-creating the marker are the same operation from the operator's side.
  # Failure is swallowed — a marker we could not write degrades to stale-false,
  # repaired by the next verdict's recompute, and dying here would abort an
  # adoption that already succeeded.
  # Explicit `if`, not `A && B || C`: with the chained form a FAILED truncate
  # still runs the `|| true`, which reads as "success tolerated" when it is the
  # one outcome worth the (swallowed) failure being distinct. SC2015.
  if mkdir -p "$OPDIR/.armed" 2>/dev/null; then
    : > "$OPDIR/.armed/$OWNER" 2>/dev/null || true
  fi

  echo "adopted $ID: ${PREV:-<unowned>} -> $OWNER"
done

lock_release
