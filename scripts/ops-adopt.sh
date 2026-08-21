#!/usr/bin/env bash
# ops-adopt.sh — re-stamp the ownership of open task sentinels.
# A session id rotates on /clear; without adoption a session's own open tasks
# would look foreign to its Stop hook and silently stop gating it. RECOVERY
# PROTOCOL step 6. Explicit ids only — a bulk sweep in a shared tree is a
# takeover by another name.
# Usage: ops-adopt.sh --owner <session-id> <task-id> [<task-id> ...]
set -eu

OPDIR=".operator"
LOCKDIR="$OPDIR/.lock"

die() { echo "ops-adopt: $1" >&2; exit 2; }

# Adoption takes the SAME lock as ops-verdict.sh, and must: verdict validates
# ownership then clears the sentinel, and an adopt landing between those steps
# would let the former owner delete the new owner's sentinel.
# >>> LOCK BLOCK — byte-identical in ops-verdict.sh and ops-adopt.sh
# (check_lock_parity + the bash suite compare the markers' span; edit both).
# mkdir is the atomic primitive (no flock on macOS). The holder stamps
# host+uid+pid and waiters ask the KERNEL, not the clock (F03): dead → reclaim
# now; alive → NEVER reclaim (wait, then proceed unlocked); unjudgeable (the
# real mkdir→stamp window, or EPERM on a foreign uid) → the timed budget.
# Reclaim is itself exclusive via a .reclaim claim that expires — an
# unexpirable claim is a deadlock with extra steps.
LOCK_SPINS=${LOCK_SPINS:-300}        # × 0.1s = 30s before an UNJUDGEABLE holder is presumed dead
LOCK_LIVE_SPINS=${LOCK_LIVE_SPINS:-600}   # × 0.1s = 60s to wait on a CONFIRMED-LIVE holder, then go unlocked
RECLAIM_WAIT=${RECLAIM_WAIT:-50}       # × 0.1s = 5s to let a LIVE reclaimer finish (it needs ms)
LOCK_DEFERS_MAX=2     # short waits to grant before treating the claim as dead
# Hard ceiling (#68): both budgets above `continue` past their own limit when
# the escape path fails, so neither bounds the loop; this always exits.
LOCK_MAX_SPINS=${LOCK_MAX_SPINS:-1200}   # × 0.1s = 120s hard ceiling, always exits

# ${VAR:-default} only guards EMPTY: non-numeric wedges the spin loop (F-A),
# zero collapses it to instant reclaim (F-B), RECLAIM_WAIT >= LOCK_SPINS makes
# the deferral backoff non-positive (F-C). Refuse all three.
_lock_is_posint() { case "$1" in ''|*[!0-9]*) return 1 ;; esac; [ "$1" -ge 1 ]; }
_lock_budget_die() { echo "ops-adopt: $1 is not a positive integer (got '$2') — refusing; see LOCK_SPINS/LOCK_LIVE_SPINS/RECLAIM_WAIT" >&2; exit 2; }
_lock_check_budget() { _lock_is_posint "$3" || _lock_budget_die "$1" "$3"; }
_lock_check_budget LOCK_SPINS "$LOCK_SPINS" "$LOCK_SPINS"
_lock_check_budget LOCK_LIVE_SPINS "$LOCK_LIVE_SPINS" "$LOCK_LIVE_SPINS"
_lock_check_budget RECLAIM_WAIT "$RECLAIM_WAIT" "$RECLAIM_WAIT"
[ "$RECLAIM_WAIT" -lt "$LOCK_SPINS" ] || _lock_budget_die "RECLAIM_WAIT (must be < LOCK_SPINS)" "$RECLAIM_WAIT"
# The ceiling must exceed both budgets or it fires under ordinary contention.
_lock_check_budget LOCK_MAX_SPINS "$LOCK_MAX_SPINS" "$LOCK_MAX_SPINS"
# Explicit `if`, not `A && B || C` (SC2015): C also runs when B fails.
if [ "$LOCK_MAX_SPINS" -le "$LOCK_SPINS" ] || [ "$LOCK_MAX_SPINS" -le "$LOCK_LIVE_SPINS" ]; then
  _lock_budget_die "LOCK_MAX_SPINS (must exceed LOCK_SPINS and LOCK_LIVE_SPINS)" "$LOCK_MAX_SPINS"
fi

# Givers-up queue on $LOCKDIR.fallback (same idiom) so "proceed unlocked"
# serializes N to 1 — one giver-up beside a live holder is the accepted floor.
# It must NEVER touch $LOCKDIR (LOCK_HELD stays 0, or its release would rm the
# LIVE holder's dir — the F03 displacement): own state, release, budget.
FALLBACK_SPINS=${FALLBACK_SPINS:-50}   # × 0.1s = 5s to wait on a LIVE giver-up, then proceed anyway
_lock_check_budget FALLBACK_SPINS "$FALLBACK_SPINS" "$FALLBACK_SPINS"

LOCK_HELD=0
LOCK_MINE=""
LOCK_HOLDER_REC=""
FALLBACK_DIR="$LOCKDIR.fallback"
FALLBACK_HELD=0
FALLBACK_MINE=""
FALLBACK_REC=""

# host + uid + pid: whether `kill -0` can answer for this holder. The
# mkdir→stamp gap is why an absent stamp reads unjudgeable, never dead.
holder_stamp() { printf '%s %s %s' "${HOSTNAME:-nohost}" "${UID:-0}" "$$"; }

# 128-char bound; assigns a global (no fork per spin). Whole compound
# redirected: a failed INPUT redirection reports before the command's own
# 2>/dev/null; an empty record is the documented "cannot judge" input.
lock_holder_read() {
  LOCK_HOLDER_REC=""
  [ -f "$LOCKDIR/holder" ] || return 0
  { IFS= read -r -n 128 LOCK_HOLDER_REC < "$LOCKDIR/holder"; } 2>/dev/null || true
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

# Same 128-byte bound as lock_holder_read; this too runs on a spin.
fallback_holder_read() {
  FALLBACK_REC=""
  [ -f "$FALLBACK_DIR/holder" ] || return 0
  IFS= read -r -n 128 FALLBACK_REC < "$FALLBACK_DIR/holder" 2>/dev/null || true
  FALLBACK_REC="${FALLBACK_REC%$'\r'}"
}

# Returns 0 won-or-not — blocking forever is worse than a second writer.
fallback_acquire() {
  local i=0 fstate=2 rec0=""
  while ! mkdir "$FALLBACK_DIR" 2>/dev/null; do
    i=$((i+1))
    # ONE bound before any branch — it must cover the reclaim path too.
    if [ "$i" -ge "$FALLBACK_SPINS" ]; then
      echo "ops-adopt: warning — fallback lock $FALLBACK_DIR held by another degraded writer for >$((FALLBACK_SPINS / 10))s; proceeding without it" >&2
      return 0
    fi
    fallback_holder_read
    fstate=0; holder_state "$FALLBACK_REC" || fstate=$?
    if [ "$fstate" -eq 1 ]; then
      # Confirmed dead. Re-verify first (a retaker is briefly unstamped);
      # stamp before dir; no second claim marker on this degraded path.
      rec0="$FALLBACK_REC"
      fallback_holder_read
      if [ "$FALLBACK_REC" != "$rec0" ]; then sleep 0.1; continue; fi
      rm -f "$FALLBACK_DIR/holder" 2>/dev/null || true
      rmdir "$FALLBACK_DIR" 2>/dev/null || true
      continue
    fi
    # Alive or unjudgeable: wait out the short budget rather than stealing.
    sleep 0.1
  done
  FALLBACK_HELD=1
  FALLBACK_MINE="$(holder_stamp)"
  printf '%s\n' "$FALLBACK_MINE" > "$FALLBACK_DIR/holder" 2>/dev/null || true
  # Own trap: a crashed giver-up must leave a reclaimable dir.
  trap 'lock_release; fallback_release' EXIT
  trap 'lock_release; fallback_release; exit 130' INT
  trap 'lock_release; fallback_release; exit 143' TERM
  return 0
}

# Reached only via the acquire paths' traps; the linter cannot follow a trap.
# shellcheck disable=SC2317
fallback_release() {
  [ "${FALLBACK_HELD:-0}" = "1" ] || return 0
  FALLBACK_HELD=0
  # Displacement guard: a reclaimed fallback is another holder's dir.
  fallback_holder_read
  if [ -n "$FALLBACK_MINE" ] && [ -n "$FALLBACK_REC" ] && [ "$FALLBACK_REC" != "$FALLBACK_MINE" ]; then
    echo "ops-adopt: warning — $FALLBACK_DIR was reclaimed while this process held it; not releasing another holder's fallback lock" >&2
    return 0
  fi
  rm -f "$FALLBACK_DIR/holder" 2>/dev/null || true
  rmdir "$FALLBACK_DIR" 2>/dev/null || true
}

lock_acquire() {
  local i=0 defers=0 state=2 rec0="" total=0
  while ! mkdir "$LOCKDIR" 2>/dev/null; do
    # The ceiling, on a variable nothing rewinds (#68).
    total=$((total+1))
    if [ "$total" -ge "$LOCK_MAX_SPINS" ]; then
      # Refuse rather than proceed unlocked: this state is unjudged.
      echo "ops-adopt: could not acquire $LOCKDIR after $((LOCK_MAX_SPINS / 10))s — refusing to spin further." >&2
      if [ ! -d "${LOCKDIR%/*}" ]; then
        # Name the cause when it is knowable (#68's exact shape).
        echo "ops-adopt: ${LOCKDIR%/*} does not exist — the ledger directory was removed while this run was in flight." >&2
      fi
      exit 2
    fi
    i=$((i+1))
    lock_holder_read
    # holder_state reports via exit status; a bare call would trip set -e.
    state=0; holder_state "$LOCK_HOLDER_REC" || state=$?

    if [ "$state" -eq 0 ]; then
      # Confirmed alive: NEVER reclaim (F03). Degrade via the fallback queue.
      if [ "$i" -ge "$LOCK_LIVE_SPINS" ]; then
        echo "ops-adopt: warning — lock $LOCKDIR held by a LIVE process for >$((LOCK_LIVE_SPINS / 10))s; proceeding unlocked rather than stealing a running writer's lock" >&2
        fallback_acquire
        return 0
      fi
      sleep 0.1
      continue
    fi

    if [ "$state" -eq 1 ] || [ "$i" -ge "$LOCK_SPINS" ]; then
      if mkdir "$LOCKDIR.reclaim" 2>/dev/null; then
        # Re-verify under the claim: never delete a retaker's LIVE lock.
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
      # A LIVE reclaimer needs ms — short waits; then the claim is dead.
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
  # Both releases in both handlers (each gated on its own HELD flag).
  trap 'lock_release; fallback_release' EXIT
  # Release AND exit — bash would otherwise resume the critical section.
  trap 'lock_release; fallback_release; exit 130' INT
  trap 'lock_release; fallback_release; exit 143' TERM
}

lock_release() {
  [ "${LOCK_HELD:-0}" = "1" ] || return 0
  LOCK_HELD=0
  # A lock reclaimed under us is the NEW holder's — report, leave it.
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

# Keep identical to ops-task.sh / ops-verdict.sh — a leading dot is invisible
# to the Stop hook's glob; '__' is the owner/task separator.
check_bare_name() { # check_bare_name <label> <value>
  case "$2" in
    */*) die "$1 must be a bare name (no '/')" ;;
    .*) die "$1 must not start with '.' — a dotfile sentinel is invisible to the Stop hook's glob" ;;
    *"|"* | *"$NL"*) die "$1 must not contain '|' or newlines" ;;
    *__*) die "$1 must not contain '__' (it separates owner from task in the sentinel name)" ;;
  esac
}

# Owners refuse whitespace; task ids do NOT (recovery must name legacy ids).
check_owner_name() { # check_owner_name <value>
  check_bare_name "owner" "$1"
  case "$1" in
    *[[:space:]]*) die "owner must not contain whitespace — it could never match a real session id, leaving the task permanently unblockable" ;;
    # .armed/ is one flat namespace for <sid> (derived) and <sid>.exempt (G3
    # grant) — an owner ending .exempt could forge or destroy a grant (#30).
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
# ${IDS+…}: bash 3.2 treats "${EMPTY[@]}" under set -u as unbound.
[ "${#IDS[@]}" -gt 0 ] || die "name at least one task-id — there is no bulk adopt"
[ -d "$OPDIR" ] || die "no $OPDIR/ in cwd — run ops-init.sh first"

for ID in ${IDS+"${IDS[@]}"}; do
  check_bare_name "task-id" "$ID"
done

# Everything below mutates ownership, so it runs under the writer's lock:
# validate-then-rewrite must be indivisible against a concurrent ops-verdict.sh.
lock_acquire

# The sentinel's NAME carries its owner, so find it by task id under any owner.
sentinel_path() { # <task-id> → path, or empty
  local _t="$1" _f
  shopt -s nullglob
  for _f in "$OPDIR/pending/$_t" "$OPDIR/pending"/*__"$_t"; do
    # -e OR -L: -e is false for a dangling symlink; a planted entry must be
    # found and refused, not stepped around.
    { [ -e "$_f" ] || [ -L "$_f" ]; } && { printf '%s\n' "$_f"; break; }
  done
  shopt -u nullglob
}

for ID in ${IDS+"${IDS[@]}"}; do
  F="$(sentinel_path "$ID")"; [ -n "$F" ] || F="$OPDIR/pending/$ID"
  # -L before -f: -f follows a symlink, and the rename below would LAUNDER a
  # planted link into a genuine sentinel (F65).
  [ ! -L "$F" ] || die "sentinel at $F is a symlink — not a sentinel our CLIs wrote; refusing to adopt (remove it and open the task with ops-task.sh)"
  [ -f "$F" ] || die "no open task '$ID' (no sentinel at $F)"
done

for ID in ${IDS+"${IDS[@]}"}; do
  F="$(sentinel_path "$ID")"; [ -n "$F" ] || F="$OPDIR/pending/$ID"
  NAME="${F##*/}"
  case "$NAME" in *__*) PREV="${NAME%%__*}" ;; *) PREV="" ;; esac
  # F15: the previous owner is an untrusted NAME — a planted filename can
  # carry terminal escapes; our writers cannot produce these shapes.
  case "${PREV:-}" in
    */* | .* | *"|"* | *[[:space:]]* | *[[:cntrl:]]* | *.exempt) PREV="<invalid>" ;;
  esac
  DEST="$OPDIR/pending/${OWNER}__$ID"

  # Adoption is a RENAME: atomic, no half-write, nothing to clean up. The
  # closed-while-adopting guard prevents resurrecting a sentinel for a task
  # that already has a verdict row.
  if [ ! -f "$F" ]; then
    die "task '$ID' was closed while adopting — not resurrecting its sentinel"
  fi
  if [ "$F" != "$DEST" ]; then
    mv "$F" "$DEST"
  fi
  F="$DEST"

  # --- arm marker (G2.1): after the rename, under the lock. Failure is
  # swallowed — dying here would abort an adoption that already succeeded.
  if mkdir -p "$OPDIR/.armed" 2>/dev/null; then
    : > "$OPDIR/.armed/$OWNER" 2>/dev/null || true
  fi

  echo "adopted $ID: ${PREV:-<unowned>} -> $OWNER"
done

lock_release
