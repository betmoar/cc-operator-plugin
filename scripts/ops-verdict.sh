#!/usr/bin/env bash
# ops-verdict.sh — the SINGLE writer to .operator/VERDICTS.md (and the defer
# path to .operator/DECISIONS.md). Fragment + append + sentinel-clear run under
# a mkdir-based lock, so writes are mutually exclusive against concurrent
# sessions — not merely append-only.
#
# The one gap, stated honestly: after LOCK_SPINS the holder is presumed crashed
# and the lock is reclaimed. A live writer that genuinely runs longer than that
# would be overrun. The budget is set well above the slowest real critical
# section (a full --reconcile, which is a single pass, not a grep per row).
#
# Verdict:  ops-verdict.sh <task-id> <criterion> <evidence> <PASS|FAIL> [--owner <sid>]
#   Appends exactly one row and clears .operator/pending/<task-id>.
#   Refuses (exit 2, no row, sentinel intact) if any cell is empty, if a cell
#   breaks the 4-cell schema, or if --owner contradicts the sentinel's owner.
#
# Defer:    ops-verdict.sh <task-id> --defer "<reason>" [--owner <sid>]
#   Writes a DEFERRED-VERDICT line to DECISIONS.md and clears the sentinel.
#   The honest end-state for a legitimately blocked task.
#
# Exempt:   ops-verdict.sh --exempt-mark "<reason>" --owner <sid>
#   The ledger half of the G3 arm-gate exemption; called by ops-task.sh
#   --exempt, which does not write ledgers. Appends one GATE-EXCEPTION line.
#
# Reconcile: ops-verdict.sh --reconcile
#   Appends to VERDICTS.md every row present in .operator/verdicts.d/*.md but
#   missing from it. Idempotent. This REPAIRS a merge, it does not regenerate
#   the ledger: VERDICTS.md also carries hand-written BAR blocks, which a
#   rebuild would destroy.
#
# Every row is also appended to .operator/verdicts.d/<owner>.md. Two branches
# then append to two different files and git merges them cleanly; a mangled
# VERDICTS.md merge is recoverable with --reconcile.
set -eu

OPDIR=".operator"
VERDICTS="$OPDIR/VERDICTS.md"
DECISIONS="$OPDIR/DECISIONS.md"
FRAGDIR="$OPDIR/verdicts.d"
LOCKDIR="$OPDIR/.lock"

die() { echo "ops-verdict: $1" >&2; exit 2; }

NL="$(printf '\nx')"; NL="${NL%x}"

# The ledgers are one-line pipe-tables: a '|' or newline inside a cell breaks
# the 4-cell schema every grep consumer depends on. Refuse, never sanitize —
# same policy as the empty-cell refusal below.
check_cell() { # check_cell <label> <value>
  case "$2" in
    *"|"*)
      die "$1 contains '|' — cells are pipe-delimited; rephrase without it" ;;
    *"$NL"*)
      die "$1 contains a newline — ledger rows are exactly one line" ;;
  esac
}

# A bare name: it is also a filename (sentinel + fragment file), so a '/' would
# let clear_sentinel's rm -f reach outside .operator/ (the 2026-07-10 traversal
# bug). A leading dot is refused because the Stop hook enumerates pending/ with
# a plain glob, which skips dotfiles — a `.hidden` sentinel would be an open
# task the gate cannot see. Keep identical to ops-task.sh / ops-adopt.sh.
check_bare_name() { # check_bare_name <label> <value>
  case "$2" in
    */*) die "$1 must be a bare name (no '/')" ;;
    .*) die "$1 must not start with '.' — a dotfile sentinel is invisible to the Stop hook's glob" ;;
  esac
  check_cell "$1" "$2"
}

# Owners refuse whitespace; task ids deliberately do NOT — see the note in
# ops-task.sh. Applying the owner rule to task ids wedged pre-0.4 tasks whose
# ids contain a space: the hook blocked on the sentinel while every closing
# path refused the id, so the session could never stop.
check_owner_name() { # check_owner_name <value>
  check_bare_name "owner" "$1"
  case "$1" in
    *[[:space:]]*) die "owner must not contain whitespace — it could never match a real session id, leaving the task permanently unblockable" ;;
  esac
}

# A fragment holds one ~80-byte row per verdict. 8 MiB is ~100k verdicts — far
# past any honest ledger, and past it the file is corruption, not evidence.
# Bounding it keeps --reconcile's lock hold time bounded too. (Audit F02/F03.)
FRAG_MAX_BYTES=8388608

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
_lock_budget_die() { echo "ops-verdict: $1 is not a positive integer (got '$2') — refusing; see LOCK_SPINS/LOCK_LIVE_SPINS/RECLAIM_WAIT" >&2; exit 2; }
_lock_check_budget() { _lock_is_posint "$3" || _lock_budget_die "$1" "$3"; }
_lock_check_budget LOCK_SPINS "$LOCK_SPINS" "$LOCK_SPINS"
_lock_check_budget LOCK_LIVE_SPINS "$LOCK_LIVE_SPINS" "$LOCK_LIVE_SPINS"
# RECLAIM_WAIT must be < LOCK_SPINS, else the backoff `i=$((LOCK_SPINS-RECLAIM_WAIT))`
# goes non-positive and each defer pays the full RECLAIM_WAIT (review F-C).
_lock_check_budget RECLAIM_WAIT "$RECLAIM_WAIT" "$RECLAIM_WAIT"
[ "$RECLAIM_WAIT" -lt "$LOCK_SPINS" ] || _lock_budget_die "RECLAIM_WAIT (must be < LOCK_SPINS)" "$RECLAIM_WAIT"

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
        echo "ops-verdict: warning — lock $LOCKDIR held by a LIVE process for >$((LOCK_LIVE_SPINS / 10))s; proceeding unlocked rather than stealing a running writer's lock" >&2
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
          echo "ops-verdict: warning — lock $LOCKDIR was held by process ${LOCK_HOLDER_REC##* }, which is gone; reclaiming it" >&2
        else
          echo "ops-verdict: warning — lock $LOCKDIR held >$((LOCK_SPINS / 10))s and its holder cannot be identified; assuming a crashed writer and reclaiming it" >&2
        fi
        rm -f "$LOCKDIR/holder" 2>/dev/null || true
        rmdir "$LOCKDIR" 2>/dev/null || true
        if mkdir "$LOCKDIR" 2>/dev/null; then
          rmdir "$LOCKDIR.reclaim" 2>/dev/null || true
          break                       # we now hold the lock
        fi
        rmdir "$LOCKDIR.reclaim" 2>/dev/null || true
        echo "ops-verdict: warning — could not reclaim $LOCKDIR; proceeding unlocked" >&2
        return 0
      fi
      # Someone else holds the reclaim claim. A LIVE reclaimer needs only
      # milliseconds, so grant it a SHORT wait — not another full budget, which
      # would turn a crashed claimer into minutes of stalling. After a couple of
      # short waits the claim is dead, not slow.
      defers=$((defers + 1))
      if [ "$defers" -gt "$LOCK_DEFERS_MAX" ]; then
        echo "ops-verdict: warning — reclaim claim $LOCKDIR.reclaim abandoned; clearing it" >&2
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
    echo "ops-verdict: warning — $LOCKDIR was reclaimed while this process held it; not releasing another holder's lock" >&2
    return 0
  fi
  rm -f "$LOCKDIR/holder" 2>/dev/null || true
  rmdir "$LOCKDIR" 2>/dev/null || true
}
# <<< LOCK BLOCK

# --- sentinel ownership ------------------------------------------------------
# The sentinel BODY is untrusted input: it is an ordinary file that a merge, a
# checkout, or a hand-edit can supply, and it is not written only by our CLIs.
# A stamped owner becomes a fragment FILENAME, so an unvalidated one re-opens
# the 2026-07-10 traversal through a new door (`session_id: ../../../tmp/x`
# appended a real ledger row to /tmp/x.md — found in review of this branch).
# Sanitize at the parser, not at each call site: every consumer is then covered
# by construction. A malformed owner degrades to "" = unowned, which fails
# CLOSED (blocks everyone) — the safe direction.
# `read -r -n 512`, not plain `read -r`: a line cap is not a byte cap, because one
# newline-less line is a single "line" and gets slurped whole first. Measured on a
# 256MB single-line sentinel: 13.51s here vs 0.17s in the byte-bounded Stop hook.
# The owner is a short token by construction. (Audit F02 — the first fix reached
# only the Stop hook; this reader and two others kept the unbounded form.)
sentinel_owner() { # sentinel_owner <id> → stamped session_id ("" if none/invalid)
  local f="$OPDIR/pending/$1" line owner="" n=0
  # LC_ALL=C so the byte-bounded read + ${#} count BYTES not characters (a
  # multibyte-locale pad would otherwise smuggle a foreign owner past the cap
  # guard — review finding 2026-08-04). Safe: this runs in a $(...) subshell.
  LC_ALL=C
  # A symlink is never a sentinel our CLIs wrote (F65): `-f` alone FOLLOWS it,
  # so a link planted in pending/ would read its target's session_id: as a
  # valid owner. Degrade to unowned — fails closed, like every other
  # malformed body. The mutating paths additionally refuse outright below.
  [ ! -L "$f" ] || return 0
  [ -f "$f" ] || return 0
  # NUL pre-scan, same rationale as ops-stop-hook.sh (F46): bash cannot see a
  # NUL in a variable, and `read -n` stops at one on bash 3.2, so a NUL-padded
  # chunk passes the length guard and its tail smuggles an owner. Degrade to
  # unowned rather than dying — this is a reader.
  # Whole-file NUL probe in a LC_ALL=C subshell (F55): a single-shot probe left
  # a NUL past byte 512 undetected, letting a padded sentinel smuggle a foreign
  # owner. Bytes for both -n and ${#}; EOF exits non-zero so the trailing
  # partial chunk never false-positives. Mirror of the Stop hook's parser.
  if ! (LC_ALL=C _np=0
        while IFS= read -r -d '' -n 512 _nulprobe; do
          _np=$((_np + 1)); [ "$_np" -le 40 ] || exit 1
          [ "${#_nulprobe}" -eq 512 ] || exit 1
        done < "$f") 2>/dev/null; then
    printf '%s' ""
    return 0
  fi
  while IFS= read -r -n 512 line || [ -n "$line" ]; do
    n=$((n+1)); [ "$n" -le 20 ] || break   # owner is line 1 by construction
    # Cap-filling chunk → truncated mid-line; its tail would be matched as a
    # fresh line and smuggle an owner. Mirrors ops-stop-hook.sh (F45).
    [ "${#line}" -lt 512 ] || { owner=""; break; }
    case "$line" in
      "session_id: "*) owner="${line#session_id: }"; break ;;
    esac
  done < "$f"
  # A CRLF checkout would otherwise leave a trailing \r, making a session's OWN
  # task compare unequal to its id — a fail-OPEN in the central invariant.
  owner="${owner%$'\r'}"
  owner="${owner%"${owner##*[![:space:]]}"}"
  case "$owner" in
    "" | */* | .* | *"|"* | *[[:space:]]*) return 0 ;;  # unusable → unowned → fails closed
  esac
  printf '%s' "$owner"
}

# row_is_conformant <line> — true iff the line is EXACTLY the 4-cell ledger row
# `| id | criterion | evidence | PASS-or-FAIL |`. Counts the cells by splitting
# on the '|' delimiter rather than globbing, because a glob's `*` will happily
# match a delimiter and let a 5-cell row through.
row_is_conformant() {
  local line="$1" rest field n=0 verdict=""
  case "$line" in '| '*' |') ;; *) return 1 ;; esac
  rest="${line#| }"          # strip leading  "| "
  rest="${rest% |}"          # strip trailing " |"
  # rest is now  cell1 | cell2 | cell3 | cell4  — split on " | "
  while :; do
    case "$rest" in
      *" | "*) field="${rest%%" | "*}"; rest="${rest#*" | "}" ;;
      *)       field="$rest"; rest="" ;;
    esac
    n=$((n+1))
    [ -n "$field" ] || return 1        # empty cell is not conformant
    case "$field" in *"|"*) return 1 ;; esac
    verdict="$field"
    [ -n "$rest" ] || break
    [ "$n" -le 4 ] || return 1
  done
  [ "$n" -eq 4 ] || return 1
  case "$verdict" in PASS|FAIL) ;; *) return 1 ;; esac
  return 0
}

append_fragment() { # append_fragment <owner-or-empty> <row>
  local who="${1:-unowned}"
  mkdir -p "$FRAGDIR"
  printf '%s\n' "$2" >> "$FRAGDIR/$who.md"
}

# --- Reconcile path (no task-id) --------------------------------------------
if [ "${1:-}" = "--reconcile" ]; then
  [ -f "$VERDICTS" ] || die "missing $VERDICTS — run ops-init.sh first"
  lock_acquire
  added=0
  skipped=0
  # Collect candidate rows first, then diff against the ledger in ONE pass.
  # The obvious `grep -Fxq` per fragment row is O(rows × ledger) and shells out
  # per row — measured ~7s for a 3000-row ledger, which would exceed any sane
  # lock budget and push concurrent writers onto the unlocked path, the lock's
  # guarantee evaporating exactly when it matters. Associative arrays would be
  # the other fix, but macOS /bin/bash is 3.2 and has none.
  CAND="$(mktemp "${TMPDIR:-/tmp}/opsrec.XXXXXX")"
  trap 'lock_release; rm -f "$CAND"' EXIT
  if [ -d "$FRAGDIR" ]; then
    for frag in "$FRAGDIR"/*.md; do
      [ -f "$frag" ] || continue
      # Reconcile cannot stop after N lines the way the sentinel parsers do —
      # reading every row IS its job — so a per-read byte cap does not save it:
      # a 64MB newline-less line still yields ~131k capped chunks and the loop
      # walks all of them (measured 31.85s; draining them instead, 23.99s).
      # Bash has no cheap "skip to next newline".
      #
      # So reject the FILE up front on size. A fragment is machine-written, one
      # ~80-byte row per verdict; the cap below is orders of magnitude above any
      # honest fragment, and anything past it is corruption (bad merge, stray
      # binary, truncated write) whose every line would be skipped as
      # non-conformant anyway. Refusing to open it is O(1) and loses nothing.
      #
      # This read happens INSIDE the lock (acquired above). Unbounded, a 256MB
      # fragment took 32.56s against a 30s crash-presumption budget, so a
      # concurrent writer reclaimed a LIVE reconcile's lock and both entered the
      # critical section. (Audit F02/F03.)
      fragsz="$(wc -c < "$frag" 2>/dev/null || echo 0)"
      if [ "$fragsz" -gt "$FRAG_MAX_BYTES" ]; then
        echo "ops-verdict: refusing fragment ${frag##*/} — ${fragsz} bytes exceeds ${FRAG_MAX_BYTES}; it is corrupt, not a ledger (repair or delete it)" >&2
        skipped=$((skipped+1)); continue
      fi
      while IFS= read -r -n 512 row || [ -n "$row" ]; do
        [ -n "$row" ] || continue
        # Reconcile is a WRITE to the ledger of record, so it enforces the same
        # 4-cell schema the direct path does. A fragment is an ordinary file
        # that a merge or a hand-edit can corrupt; without this, --reconcile
        # would be a hole straight through the single writer's cell hygiene.
        #
        # COUNT the cells — do not pattern-match them. A glob like
        # '| '*' | '*' | '*' | PASS |' looks like a 4-cell check but each `*`
        # happily consumes ` | ` too, so `| a | b | c | injected | PASS |`
        # matched and was admitted (found by Codex review). Splitting on the
        # delimiter is the only check that actually counts.
        if ! row_is_conformant "$row"; then
          echo "ops-verdict: skipping non-conformant line in ${frag##*/}: $row" >&2
          skipped=$((skipped+1)); continue
        fi
        printf '%s\n' "$row" >> "$CAND"
      done < "$frag"
    done
  fi
  if [ -s "$CAND" ]; then
    # -F -x -v -f: keep candidate lines NOT present verbatim in the ledger.
    # Sorted -u so a row duplicated across fragments is added once.
    MISSING="$(grep -Fxv -f "$VERDICTS" -- "$CAND" 2>/dev/null | sort -u || true)"
    if [ -n "$MISSING" ]; then
      printf '%s\n' "$MISSING" >> "$VERDICTS"
      added="$(printf '%s\n' "$MISSING" | wc -l | tr -d ' ')"
    fi
  fi
  rm -f "$CAND"
  lock_release
  if [ "$skipped" -gt 0 ]; then
    echo "reconciled: $added row(s) restored to $VERDICTS from $FRAGDIR/ ($skipped non-conformant line(s) skipped — see stderr)"
  else
    echo "reconciled: $added row(s) restored to $VERDICTS from $FRAGDIR/"
  fi
  exit 0
fi

# --- mark-handoff path (no task-id) -----------------------------------------
# Stage 2 of worker-boundary enforcement: an operator-taken decision can reach
# session end unpresented because the Stop hook only checks sentinels. A
# HANDOFF-MARK line clears (for the owning session) every DEVIATION recorded
# before it — the operator has presented them. The hook partitions on the same
# mine/unowned-vs-foreign rule it uses for sentinels; a mark is positioned in
# the file AFTER the deviations it clears (file position, not timestamp).
#
# --owner is REQUIRED and non-empty: an empty sid would write an unowned mark,
# which under the partition clears EVERY session's deviations — a privilege
# inversion. The explicit `[ -n "$MOWNER" ]` guard below rejects empty;
# check_owner_name then rejects malformed (whitespace/slash/dot) owners. The
# mark's sid tag is the load-bearing cell; the engagement cell is display-only.
#
# Written UNDER the lock, inside the same critical section --defer uses for
# DECISIONS.md writes — so a concurrent verdict/defer cannot interleave.
if [ "${1:-}" = "--mark-handoff" ]; then
  shift
  MOWNER=""
  MENG="handoff"
  while [ $# -gt 0 ]; do
    case "$1" in
      --owner)
        [ $# -ge 2 ] || die "--owner requires a session id"
        [ -z "$MOWNER" ] || die "--owner given more than once"
        MOWNER="$2"; shift 2 ;;
      --owner=*)
        [ -z "$MOWNER" ] || die "--owner given more than once"
        MOWNER="${1#--owner=}"; shift ;;
      --engagement)
        [ $# -ge 2 ] || die "--engagement requires a value"
        MENG="$2"; shift 2 ;;
      --engagement=*)
        MENG="${1#--engagement=}"; shift ;;
      *) die "unknown option '$1' (usage: ops-verdict.sh --mark-handoff --owner <sid> [--engagement <name>])" ;;
    esac
  done
  [ -n "$MOWNER" ] || die "--mark-handoff requires --owner <sid> (an empty sid would write an unowned mark clearing every session's deviations)"
  check_owner_name "$MOWNER"
  check_cell "engagement" "$MENG"
  [ -f "$DECISIONS" ] || die "missing $DECISIONS — run ops-init.sh first"
  lock_acquire
  printf '%s | %s | HANDOFF-MARK | [sid:%s] %s | handoff presented\n' \
    "$(date +%F)" "$MENG" "$MOWNER" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$DECISIONS"
  lock_release
  echo "marked handoff for session $MOWNER (DECISIONS.md HANDOFF-MARK appended)"
  exit 0
fi

# --- exempt-mark path (no task-id) ------------------------------------------
# The ledger half of the G3 arm-gate exemption. The operator-facing surface is
# `ops-task.sh --exempt "<reason>" --owner <sid>`, which validates and then
# delegates HERE, because this script is the single writer to DECISIONS.md and
# already owns the lock. ops-task.sh takes no lock by design; giving it one to
# append one rare line would copy the LOCK BLOCK to a third file.
#
# The row is a GATE-EXCEPTION — a kind the stage-2 deviation gate ALREADY blocks
# Stop on until a HANDOFF-MARK presents it. That is the whole enforcement: the
# hatch is real and one command, and it costs a presentation. No new machinery.
#
# --owner is REQUIRED and non-empty for the same reason --mark-handoff requires
# it: the [sid:] tag is what scopes the debt. An untagged GATE-EXCEPTION reads
# as unowned, which under the hook's partition blocks EVERY session — a wedge,
# and this feature exists to prevent wedges.
if [ "${1:-}" = "--exempt-mark" ]; then
  shift
  XREASON=""
  XOWNER=""
  XSEEN=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --owner)
        [ $# -ge 2 ] || die "--owner requires a session id"
        [ -z "$XOWNER" ] || die "--owner given more than once"
        XOWNER="$2"; shift 2 ;;
      --owner=*)
        [ -z "$XOWNER" ] || die "--owner given more than once"
        XOWNER="${1#--owner=}"; shift ;;
      -*) die "unknown option '$1' (usage: ops-verdict.sh --exempt-mark \"<reason>\" --owner <sid>)" ;;
      *)
        [ "$XSEEN" -eq 0 ] || die "unexpected extra argument '$1' (the reason is a single quoted string)"
        XSEEN=1; XREASON="$1"; shift ;;
    esac
  done
  [ -n "$XREASON" ] || die "--exempt-mark requires a non-empty reason (the grant is audited: the reason is what the handoff presents)"
  [ -n "$XOWNER" ] || die "--exempt-mark requires --owner <sid> (an untagged GATE-EXCEPTION reads as unowned and would block every session)"
  check_owner_name "$XOWNER"
  check_cell "exemption reason" "$XREASON"
  [ -f "$DECISIONS" ] || die "missing $DECISIONS — run ops-init.sh first"
  lock_acquire
  printf '%s | %s | GATE-EXCEPTION | [sid:%s] arm-gate exemption granted: %s | exempt via ops-task.sh --exempt\n' \
    "$(date +%F)" "arm-gate" "$XOWNER" "$XREASON" >> "$DECISIONS"
  lock_release
  echo "GATE-EXCEPTION recorded for session $XOWNER (owes a handoff presentation: ops-verdict.sh --mark-handoff --owner $XOWNER)"
  exit 0
fi

# --- Argument parse ----------------------------------------------------------
# --owner may appear anywhere; everything else keeps its positional meaning.
OWNER=""
POS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --owner)
      [ $# -ge 2 ] || die "--owner requires a session id"
      [ -z "$OWNER" ] || die "--owner given more than once"
      OWNER="$2"; shift 2 ;;
    --owner=*)
      [ -z "$OWNER" ] || die "--owner given more than once"
      OWNER="${1#--owner=}"; shift ;;
    *) POS+=("$1"); shift ;;
  esac
done
set -- ${POS+"${POS[@]}"}

ID="${1:-}"
[ -n "$ID" ] || die "missing task-id (usage: ops-verdict.sh <id> <criterion> <evidence> <PASS|FAIL> [--owner <sid>] | <id> --defer \"<reason>\" | --reconcile)"
check_bare_name "task-id" "$ID"
if [ -n "$OWNER" ]; then check_owner_name "$OWNER"; fi
[ -d "$OPDIR" ] || die "no $OPDIR/ in cwd — run ops-init.sh first"

# --- Ownership gate ----------------------------------------------------------
# Mismatch is a hard refusal: closing a row you did not perform is exactly the
# failure the evidence gate exists to prevent. A MISSING --owner only warns —
# a session whose id rotated (/clear) must still be able to close its own work
# (ops-adopt.sh is the clean path).
#
# This MUST run while holding the lock, and ops-adopt.sh takes the same lock:
# checking ownership before acquiring it is a TOCTOU — another session could
# adopt the task between the read and the write, and the former owner would then
# record a verdict and delete the new owner's sentinel (found by Codex review).
# Callers therefore lock first, then call this.
ownership_gate() {
  # A symlink planted in pending/ is not a task our CLIs opened (F65): closing
  # it would append a ledger row for work that never went through ops-task.sh's
  # O_EXCL create, and clear_sentinel's `rm -f` would delete the link. Refuse
  # outright — the parser's degrade-to-unowned is not enough here, because an
  # unowned sentinel is closable by design. Runs under the lock in BOTH the
  # defer and verdict paths, so this is the single choke point.
  [ ! -L "$OPDIR/pending/$ID" ] || die "sentinel at $OPDIR/pending/$ID is a symlink — not a sentinel our CLIs wrote; refusing (remove it and open the task with ops-task.sh)"
  SOWNER="$(sentinel_owner "$ID")"
  if [ -n "$SOWNER" ]; then
    if [ -n "$OWNER" ] && [ "$OWNER" != "$SOWNER" ]; then
      die "task '$ID' is owned by session $SOWNER, not $OWNER — refusing (run ops-adopt.sh to take ownership deliberately)"
    fi
    if [ -z "$OWNER" ]; then
      echo "ops-verdict: warning — task '$ID' is owned by session $SOWNER and no --owner was given; proceeding" >&2
    fi
  fi
  FRAG_OWNER="${OWNER:-$SOWNER}"
}

clear_sentinel() { rm -f "$OPDIR/pending/$ID"; }

# --- arm-marker recompute (G2.1) --------------------------------------------
# The PreToolUse arm gate reads .operator/.armed/<sid> — a DERIVED cache of
# "this session owns at least one pending sentinel". This is the single place
# that recomputes it, and it runs UNDER THE LOCK both paths already hold, AFTER
# clear_sentinel.
#
# THE ORDER IS LOAD-BEARING AND THE INTUITIVE ONE IS WRONG. Clear → rescan →
# conditionally-remove loses this interleaving:
#
#   verdict:  clear sentinel
#   verdict:  rescan pending/ → empty
#   task:                        creates sentinel (O_EXCL, no lock — by design)
#   task:                        creates marker
#   verdict:  rm .armed/S                       ← marker gone, sentinel present
#
# That is stale-FALSE — a legitimately-armed session blocked from every edit,
# the one desync direction the design forbids. And it is not covered by the
# stale-false mitigations: those are written for a desync that PERSISTS, not one
# the recompute itself creates ("the next verdict corrects it" is circular — the
# next verdict can lose the same race).
#
# Remove-then-rescan-then-restore is safe under every interleaving: a sentinel
# created BEFORE the rescan is seen by it and the marker is restored; one
# created AFTER brings its own marker (ops-task.sh writes it). The worst case is
# stale-TRUE for one moment, which merely degrades to today's ungated behaviour.
#
# ops-task.sh takes no lock by design, so this cannot be fixed by locking the
# opener — the recompute has to be correct against an unlocked concurrent write.
#
# The `.exempt` marker is NEVER touched here: an exempt session by definition has
# nothing in pending/, so a recompute that owned both kinds would delete a grant
# the moment any verdict ran. Two marker kinds, two lifetimes (G3).
#
# Failures are swallowed (`|| true`, `2>/dev/null`): this runs after the ledger
# row is already written, and dying here under `set -e` would abort a verdict
# that succeeded. A marker we could not write degrades to stale-false, which the
# gate's deny message (ops-adopt.sh) and the next verdict both repair.
recompute_arm_marker() { # recompute_arm_marker <session-id>
  local sid="$1" f still=1
  [ -n "$sid" ] || return 0
  rm -f "$OPDIR/.armed/$sid" 2>/dev/null || true
  shopt -s nullglob
  for f in "$OPDIR/pending"/*; do
    # -f, not -e: a directory or a symlink in pending/ is not a sentinel our
    # CLIs wrote; sentinel_owner rejects both and returns "" (unowned), which
    # is not this session either way.
    [ -f "$f" ] || continue
    if [ "$(sentinel_owner "${f##*/}")" = "$sid" ]; then still=0; break; fi
  done
  shopt -u nullglob
  if [ "$still" -eq 0 ]; then
    mkdir -p "$OPDIR/.armed" 2>/dev/null && : > "$OPDIR/.armed/$sid" 2>/dev/null || true
  fi
  return 0
}

# --- Retro-gate: three-state arm check (G1) ---------------------------------
# Runs inside the lock, after ownership_gate. Determines whether this verdict
# is armed (sentinel present), never-armed (no sentinel, no prior row), or a
# duplicate/amending row (no sentinel, prior row exists).
#
# Sets RETRO_STATE to one of: armed, never-armed, duplicate.
# A never-armed verdict with no session to tag (no --owner, no sentinel) dies
# (G1.4). The prior-row scan is a reverse-tail read of the session fragment,
# bounded by FRAG_MAX_BYTES (G1.6).
retro_gate() {
  RETRO_STATE="armed"
  # Sentinel FILE present → armed, even if its body is empty/unparseable
  # (an unowned-but-present sentinel is a real open task — fails closed).
  [ -e "$OPDIR/pending/$ID" ] && return 0

  # Sentinel absent. We need a session to tag the GATE-EXCEPTION.
  local tag_owner="${OWNER:-$SOWNER}"
  if [ -z "$tag_owner" ]; then
    die "never-armed verdict requires --owner <session-id> — the GATE-EXCEPTION must carry a [sid:] tag, and there is no sentinel to supply one"
  fi

  # Check for prior rows in the session fragment. The fragment is append-only
  # so the newest row is at the tail, but for a binary "does any row exist?"
  # check, forward scan is equivalent and cross-platform. Bounded by
  # FRAG_MAX_BYTES — the PLAYBOOK "touching the lock" step-3 hazard.
  local frag="$FRAGDIR/${tag_owner}.md" fragsz=0 found=1 line n=0
  if [ -f "$frag" ]; then
    fragsz="$(wc -c < "$frag" 2>/dev/null || echo 0)"
    if [ "$fragsz" -gt "$FRAG_MAX_BYTES" ]; then
      echo "ops-verdict: fragment ${frag##*/} exceeds FRAG_MAX_BYTES (${fragsz}); prior-row scan refused — treating as never-armed" >&2
    else
      while IFS= read -r -n 512 line || [ -n "$line" ]; do
        n=$((n+1)); [ "$n" -le 200000 ] || break  # backstop: ~100k rows at ~80 bytes
        [ "${#line}" -lt 512 ] || continue         # skip capped chunks (not a complete row)
        case "$line" in
          "| $ID |"*) found=0; break ;;
        esac
      done < "$frag"
    fi
  fi

  if [ "$found" -eq 0 ]; then
    RETRO_STATE="duplicate"
    echo "ops-verdict: warning — no sentinel for '$ID' but a prior row exists in the fragment; treating as duplicate/amending row" >&2
  else
    RETRO_STATE="never-armed"
  fi
}

# --- Defer path -------------------------------------------------------------
if [ "${2:-}" = "--defer" ]; then
  REASON="${3:-}"
  [ -n "$REASON" ] || die "--defer requires a non-empty reason"
  check_cell "defer reason" "$REASON"
  [ -f "$DECISIONS" ] || die "missing $DECISIONS — run ops-init.sh first"
  lock_acquire
  ownership_gate          # inside the lock: adoption cannot slip in behind it
  printf '%s | %s | DEFERRED-VERDICT | %s | deferred via ops-verdict.sh --defer\n' \
    "$(date +%F)" "$ID" "$REASON" >> "$DECISIONS"
  clear_sentinel
  recompute_arm_marker "$FRAG_OWNER"   # G2.1 — under the lock, after the clear
  lock_release
  echo "deferred $ID (DECISIONS.md line written, sentinel cleared)"
  exit 0
fi

# --- Verdict path -----------------------------------------------------------
CRITERION="${2:-}"
EVIDENCE="${3:-}"
VERDICT="${4:-}"

# A row without evidence is FAIL by definition — refuse to write it at all.
[ -n "$CRITERION" ] || die "empty criterion — refusing (a row without a criterion is not conformant)"
[ -n "$EVIDENCE" ]  || die "empty evidence — refusing (a row without evidence is FAIL by definition)"
check_cell "criterion" "$CRITERION"
check_cell "evidence" "$EVIDENCE"
case "$VERDICT" in
  PASS|FAIL) ;;
  *) die "verdict must be exactly PASS or FAIL (got '${VERDICT:-<empty>}')" ;;
esac
[ -f "$VERDICTS" ]  || die "missing $VERDICTS — run ops-init.sh first"

lock_acquire
ownership_gate            # inside the lock: adoption cannot slip in behind it
retro_gate                # three-state arm check (G1) — also inside the lock
ROW="$(printf '| %s | %s | %s | %s |' "$ID" "$CRITERION" "$EVIDENCE" "$VERDICT")"
# Fragment FIRST. Under `set -e` a failed write aborts the script, so the order
# decides what a partial failure leaves behind: a fragment without a ledger row
# is repaired by --reconcile and a duplicate fragment row is deduped there, but
# a ledger row without its fragment is silently un-repairable, and a retry after
# the abort would double the ledger row. Sentinel-clear stays last so a failure
# anywhere above leaves the task OPEN — the gate holds.
append_fragment "$FRAG_OWNER" "$ROW"
printf '%s\n' "$ROW" >> "$VERDICTS"
# G1: never-armed verdict → write GATE-EXCEPTION to DECISIONS.md under the same lock.
if [ "$RETRO_STATE" = "never-armed" ]; then
  printf '%s | %s | GATE-EXCEPTION | [sid:%s] verdict %s recorded without an open sentinel — the arm gate was not used | never-armed via ops-verdict.sh\n' \
    "$(date +%F)" "$ID" "${OWNER:-$SOWNER}" "$ID" >> "$DECISIONS"
fi
clear_sentinel
recompute_arm_marker "$FRAG_OWNER"     # G2.1 — under the lock, after the clear
lock_release
if [ "$RETRO_STATE" = "never-armed" ]; then
  echo "recorded $ID = $VERDICT (never-armed — GATE-EXCEPTION written to DECISIONS.md)"
elif [ "$RETRO_STATE" = "duplicate" ]; then
  echo "recorded $ID = $VERDICT (duplicate/amending row — no sentinel, prior row exists)"
else
  echo "recorded $ID = $VERDICT (row appended, sentinel cleared)"
fi
exit 0
