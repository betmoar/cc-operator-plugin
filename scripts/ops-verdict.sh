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

# --- lock: mkdir is atomic on every POSIX FS; flock(1) is absent on macOS -----
# A stale lock must never cost a real verdict, so we spin briefly and then
# proceed with a warning rather than failing.
# Timeout is generous because a legitimate --reconcile over a large ledger can
# hold the lock for seconds; a budget shorter than a real writer would make
# every contended write take the unlocked path against a LIVE writer, which is
# the opposite of the guarantee. On timeout we RECLAIM the lock rather than
# merely ignoring it: the trap does not cover SIGKILL, so without reclamation a
# hard-killed writer would leave every later write paying the full timeout and
# warning, forever, while still not being mutually exclusive.
# Reclaim is itself a critical section. An unconditional `rmdir` + `mkdir` is
# NOT safe with several waiters: waiter A times out, removes the stale dir and
# recreates it — then waiter B times out a moment later, removes *A's fresh*
# lock and creates its own, and both proceed. Two writers inside the critical
# section, neither having exceeded its budget (found by Codex review).
#
# The fix is to make the removal itself exclusive: claim the right to reclaim by
# atomically creating a separate marker, and only the winner of that claim may
# touch the stale lock. `mkdir` is the atomic primitive in both cases.
#
# The claim marker must ITSELF be able to expire. A first version deferred to
# the marker indefinitely, so a process killed between creating it and removing
# it wedged every later writer FOREVER — strictly worse than the stale lock it
# was introduced to fix, which at least proceeded after one budget (found by
# Codex review). So: defer to a live reclaimer for a bounded number of budgets,
# then treat the marker as abandoned and clear it. Worst case after that is two
# reclaimers racing — the milder, pre-existing failure — never a deadlock. An
# unexpirable claim is a deadlock with extra steps.
LOCK_SPINS=300        # × 0.1s = 30s before a held lock is presumed crashed
RECLAIM_WAIT=50       # × 0.1s = 5s to let a LIVE reclaimer finish (it needs ms)
LOCK_DEFERS_MAX=2     # short waits to grant before treating the claim as dead
lock_acquire() {
  local i=0 defers=0
  while ! mkdir "$LOCKDIR" 2>/dev/null; do
    i=$((i+1))
    if [ "$i" -ge "$LOCK_SPINS" ]; then
      if mkdir "$LOCKDIR.reclaim" 2>/dev/null; then
        echo "ops-verdict: warning — lock $LOCKDIR held >$((LOCK_SPINS / 10))s; assuming a crashed writer and reclaiming it" >&2
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
  trap 'lock_release' EXIT
  # A signal handler that only releases would let bash RESUME the critical
  # section with the lock already gone. Release and exit.
  trap 'lock_release; exit 130' INT
  trap 'lock_release; exit 143' TERM
}
lock_release() {
  if [ "${LOCK_HELD:-0}" = "1" ]; then rmdir "$LOCKDIR" 2>/dev/null || true; LOCK_HELD=0; fi
}

# --- sentinel ownership ------------------------------------------------------
# The sentinel BODY is untrusted input: it is an ordinary file that a merge, a
# checkout, or a hand-edit can supply, and it is not written only by our CLIs.
# A stamped owner becomes a fragment FILENAME, so an unvalidated one re-opens
# the 2026-07-10 traversal through a new door (`session_id: ../../../tmp/x`
# appended a real ledger row to /tmp/x.md — found in review of this branch).
# Sanitize at the parser, not at each call site: every consumer is then covered
# by construction. A malformed owner degrades to "" = unowned, which fails
# CLOSED (blocks everyone) — the safe direction.
sentinel_owner() { # sentinel_owner <id> → stamped session_id ("" if none/invalid)
  local f="$OPDIR/pending/$1" line owner="" n=0
  [ -f "$f" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n+1)); [ "$n" -le 20 ] || break   # owner is line 1 by construction
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
      while IFS= read -r row || [ -n "$row" ]; do
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
ROW="$(printf '| %s | %s | %s | %s |' "$ID" "$CRITERION" "$EVIDENCE" "$VERDICT")"
# Fragment FIRST. Under `set -e` a failed write aborts the script, so the order
# decides what a partial failure leaves behind: a fragment without a ledger row
# is repaired by --reconcile and a duplicate fragment row is deduped there, but
# a ledger row without its fragment is silently un-repairable, and a retry after
# the abort would double the ledger row. Sentinel-clear stays last so a failure
# anywhere above leaves the task OPEN — the gate holds.
append_fragment "$FRAG_OWNER" "$ROW"
printf '%s\n' "$ROW" >> "$VERDICTS"
clear_sentinel
lock_release
echo "recorded $ID = $VERDICT (row appended, sentinel cleared)"
exit 0
