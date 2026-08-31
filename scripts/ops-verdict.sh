#!/usr/bin/env bash
# ops-verdict.sh — the SINGLE writer to .operator/VERDICTS.md (and the defer
# path to .operator/DECISIONS.md). Fragment + append + sentinel-clear run under
# a mkdir-based lock, so writes are mutually exclusive against concurrent
# sessions.
#
# Verdict:  ops-verdict.sh <task-id> <criterion> <evidence> <PASS|FAIL> [--owner <sid>]
#   Appends exactly one row and clears .operator/pending/<task-id>.
# Defer:    ops-verdict.sh <task-id> --defer "<reason>" [--owner <sid>]
#   Writes a DEFERRED-VERDICT line to DECISIONS.md and clears the sentinel.
# Reconcile: ops-verdict.sh --reconcile
#   Appends rows present in .operator/verdicts.d/*.md but missing from
#   VERDICTS.md. Repairs a merge; never regenerates (BAR blocks are hand-written).
#
# Every row is also appended to .operator/verdicts.d/<owner>.md so concurrent
# branches merge cleanly; a mangled VERDICTS.md is recoverable with --reconcile.
set -eu

OPDIR=".operator"
VERDICTS="$OPDIR/VERDICTS.md"
DECISIONS="$OPDIR/DECISIONS.md"
FRAGDIR="$OPDIR/verdicts.d"
LOCKDIR="$OPDIR/.lock"

die() { echo "ops-verdict: $1" >&2; exit 2; }

# >>> PROJECT ROOT BLOCK — byte-identical in ops-task.sh, ops-verdict.sh and
# ops-adopt.sh (check_root_parity + the bash suite compare the markers' span).
#
# WALK UP to the nearest ancestor holding .operator/, then cd there — the way
# git finds its own root, and the way ops-stop-hook.sh has always resolved the
# project. Without this every path below is relative to the caller's cwd, so
# the CLI worked from the project root and NOWHERE else.
#
# That is not hypothetical: the Stop hook's #94 fix made it prescribe an
# ABSOLUTE path to this CLI, which resolves fine from a subdirectory — and the
# command still failed there with "missing .operator/DECISIONS.md — run
# ops-init.sh first", because the path said where the CLI lives, never which
# project it serves. Measured on 0.11.2 from `apps/viewer/`. The Bash tool's
# cwd persists across calls, so a session is routinely somewhere else.
#
# `cd`, not an absolute OPDIR: every other relative path comes right for free —
# the sentinel glob, the fragment dir, the lock, and `git status --porcelain --
# ':(exclude).operator'` in the source stamp, whose pathspec is repo-relative
# and would silently stop excluding the ledger from a subdirectory.
#
# Bounded exactly like the hook's copy: stop at a .git boundary (a nested repo
# is its own project) and at the filesystem root. `cd -P` resolves symlinks, so
# the walk cannot be redirected by a planted link.
_ops_cd_project_root() {
  _walk="$(pwd -P 2>/dev/null)" || _walk=""
  while [ -n "$_walk" ]; do
    if [ -d "$_walk/.operator" ]; then
      # Refuse rather than operate on a project we cannot enter: a silent
      # failure here would leave every path below resolving against the
      # caller's cwd, which is the defect this block exists to remove.
      cd "$_walk" 2>/dev/null || die "found $_walk/.operator but could not cd there"
      return 0
    fi
    [ -e "$_walk/.git" ] && break
    [ "$_walk" = "/" ] && break
    _walk="${_walk%/*}"; [ -n "$_walk" ] || _walk="/"
  done
  return 1
}
# A miss is NOT fatal here: the per-command guards below already die with the
# message that names ops-init.sh, and they stay the single place that decides.
_ops_cd_project_root || :
# <<< PROJECT ROOT BLOCK

NL="$(printf '\nx')"; NL="${NL%x}"

# Ledgers are one-line pipe-tables: '|' or newline in a cell breaks the 4-cell
# schema every grep consumer depends on. Refuse, never sanitize.
check_cell() { # check_cell <label> <value>
  case "$2" in
    *"|"*)
      die "$1 contains '|' — cells are pipe-delimited; rephrase without it" ;;
    *"$NL"*)
      die "$1 contains a newline — ledger rows are exactly one line" ;;
  esac
}

# --- The source-state stamp (U10, #22) --------------------------------------
# Written INSIDE the evidence cell (a fifth column breaks the published 4-cell
# schema). PROVENANCE, never attestation. Never refuses: every failure
# degrades to an explicit marker — the gate never refuses real evidence.
source_stamp() {
  local sha porc rc
  command -v git >/dev/null 2>&1 || { printf 'no-vcs'; return 0; }
  git rev-parse --git-dir >/dev/null 2>&1 || { printf 'no-vcs'; return 0; }
  sha="$(git rev-parse --verify --short=12 HEAD 2>/dev/null || true)"
  [ -n "$sha" ] || { printf 'no-commit'; return 0; }
  # The sha becomes ledger content; non-hex means git answered something we do
  # not understand — degrade, never embed an untrusted string.
  case "$sha" in
    *[!0-9a-f]*) printf 'no-vcs'; return 0 ;;
  esac
  # .operator/ excluded: counting the gate's own bookkeeping pins every row
  # to +dirty (#21). Two-line local: `local x=$(…)` returns local's status.
  porc="$(git status --porcelain -- ':(exclude).operator' 2>/dev/null)" && rc=0 || rc=$?
  # An infra failure must not read as CLEAN (the strong claim).
  [ "$rc" -eq 0 ] || { printf '%s+unknown' "$sha"; return 0; }
  [ -z "$porc" ] || { printf '%s+dirty' "$sha"; return 0; }
  printf '%s' "$sha"
}

# Bare name: also a filename (sentinel + fragment), so '/' would let rm -f
# escape .operator/; a leading dot is invisible to the Stop hook's glob; '__'
# is the owner/task separator. Keep identical to ops-task.sh / ops-adopt.sh.
check_bare_name() { # check_bare_name <label> <value>
  case "$2" in
    */*) die "$1 must be a bare name (no '/')" ;;
    .*) die "$1 must not start with '.' — a dotfile sentinel is invisible to the Stop hook's glob" ;;
    *__*) die "$1 must not contain '__' (it separates owner from task in the sentinel name)" ;;
  esac
  check_cell "$1" "$2"
}

# Owners refuse whitespace (a padded owner never matches a real session →
# permanently unblockable); task ids deliberately do NOT — see ops-task.sh.
# Owners ALSO refuse shell metacharacters (#89): a quoted heredoc passed the
# literal two characters `$S`, which every reader classified as a FOREIGN
# session id — so the mark cleared nothing and the operator believed the
# deviations were presented because the tool said so. Strictly worse than not
# running the command, and invisible: the only symptom is the next Stop
# blocking again. No real session id contains one, so this cannot false-fire.
# Keep identical in ops-task.sh + ops-adopt.sh (check_guard_parity).
check_owner_name() { # check_owner_name <value>
  check_bare_name "owner" "$1"
  case "$1" in
    *[[:space:]]*) die "owner must not contain whitespace — it could never match a real session id, leaving the task permanently unblockable" ;;
    *'$'* | *'`'* | *"'"* | *'"'* | *\\*) die "owner contains a shell metacharacter — this looks like an UNEXPANDED variable, not a session id. A literal like \$S is read by every ledger consumer as a foreign session, so its HANDOFF-MARK clears nothing and its sentinel is unclearable" ;;
  esac
}

# ~80 bytes/row → 8 MiB is ~100k verdicts; past it the file is corruption, not
# evidence. Also bounds --reconcile's lock hold time (audit F02/F03).
FRAG_MAX_BYTES=8388608

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
_lock_budget_die() { echo "ops-verdict: $1 is not a positive integer (got '$2') — refusing; see LOCK_SPINS/LOCK_LIVE_SPINS/RECLAIM_WAIT" >&2; exit 2; }
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
  # LC_ALL=C so `read -n N` counts BYTES, not characters: bash counts
  # CHARACTERS outside the C locale, so in UTF-8 a 512-"char" read is up
  # to 2048 bytes and the cap is 4x looser than it reads (measured on
  # bash 3.2.57 and 5.2.15: 512 chars of "é" = 1024 bytes). Local, so
  # nothing leaks to the caller — the idiom scripts/lib/partition.sh uses.
  local LC_ALL=C
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
  # LC_ALL=C so `read -n N` counts BYTES, not characters: bash counts
  # CHARACTERS outside the C locale, so in UTF-8 a 512-"char" read is up
  # to 2048 bytes and the cap is 4x looser than it reads (measured on
  # bash 3.2.57 and 5.2.15: 512 chars of "é" = 1024 bytes). Local, so
  # nothing leaks to the caller — the idiom scripts/lib/partition.sh uses.
  local LC_ALL=C
  FALLBACK_REC=""
  [ -f "$FALLBACK_DIR/holder" ] || return 0
  # Brace-wrapped like lock_holder_read (audit F116): without the braces a
  # holder file removed between the -f test and the open reports a raw bash
  # error before 2>/dev/null applies — the twin was hardened, this copy not.
  { IFS= read -r -n 128 FALLBACK_REC < "$FALLBACK_DIR/holder"; } 2>/dev/null || true
  FALLBACK_REC="${FALLBACK_REC%$'\r'}"
}

# Returns 0 won-or-not — blocking forever is worse than a second writer.
fallback_acquire() {
  local i=0 fstate=2 rec0=""
  while ! mkdir "$FALLBACK_DIR" 2>/dev/null; do
    i=$((i+1))
    # ONE bound before any branch — it must cover the reclaim path too.
    if [ "$i" -ge "$FALLBACK_SPINS" ]; then
      echo "ops-verdict: warning — fallback lock $FALLBACK_DIR held by another degraded writer for >$((FALLBACK_SPINS / 10))s; proceeding without it" >&2
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
    echo "ops-verdict: warning — $FALLBACK_DIR was reclaimed while this process held it; not releasing another holder's fallback lock" >&2
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
      echo "ops-verdict: could not acquire $LOCKDIR after $((LOCK_MAX_SPINS / 10))s — refusing to spin further." >&2
      if [ ! -d "${LOCKDIR%/*}" ]; then
        # Name the cause when it is knowable (#68's exact shape).
        echo "ops-verdict: ${LOCKDIR%/*} does not exist — the ledger directory was removed while this run was in flight." >&2
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
        echo "ops-verdict: warning — lock $LOCKDIR held by a LIVE process for >$((LOCK_LIVE_SPINS / 10))s; proceeding unlocked rather than stealing a running writer's lock" >&2
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
        fallback_acquire      # same reason as the live-holder give-up above
        return 0
      fi
      # A LIVE reclaimer needs ms — short waits; then the claim is dead.
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
    echo "ops-verdict: warning — $LOCKDIR was reclaimed while this process held it; not releasing another holder's lock" >&2
    return 0
  fi
  rm -f "$LOCKDIR/holder" 2>/dev/null || true
  rmdir "$LOCKDIR" 2>/dev/null || true
}
# <<< LOCK BLOCK

# --- sentinel ownership ------------------------------------------------------
# Ownership is in the NAME: pending/<owner>__<task>; unowned fails CLOSED.
# No file is opened — a string split, `__` refused at construction.
sentinel_path() { # sentinel_path <task-id> → path of its sentinel, or empty
  local _t="$1" _f
  shopt -s nullglob
  for _f in "$OPDIR/pending/$_t" "$OPDIR/pending"/*__"$_t"; do
    # -e OR -L: -e is false for a dangling symlink; a planted entry must be
    # found and refused, not stepped around.
    { [ -e "$_f" ] || [ -L "$_f" ]; } && { printf '%s\n' "$_f"; break; }
  done
  shopt -u nullglob
}

sentinel_owner_of_name() { # <basename> → owner ("" when unowned or unwritable-by-us)
  case "$1" in
    *__*) : ;;
    *) printf '\n'; return 0 ;;
  esac
  _o="${1%%__*}"
  # The F1 reject set: our CLIs cannot write these shapes, so degrade a
  # planted name to unowned (fails CLOSED). Literals live only in the case
  # below — a comment repeating a pinned literal absorbs the vacuity mutation.
  # The metacharacter arm is #89's: a reader that accepts what check_owner_name
  # refuses reads a planted `$S__task` as a valid foreign owner (measured via
  # the SessionStart migration; Stop went rc 0 on a real open task).
  case "$_o" in
    "" | */* | .* | *"|"* | *[[:space:]]*) printf '\n'; return 0 ;;
    *'$'* | *'`'* | *"'"* | *'"'* | *\\*) printf '\n'; return 0 ;;
  esac
  printf '%s\n' "$_o"
}

sentinel_owner() { # sentinel_owner <task-id> → owner ("" if unowned/absent)
  local _p; _p="$(sentinel_path "$1")"
  [ -n "$_p" ] || { printf '\n'; return 0; }
  sentinel_owner_of_name "${_p##*/}"
}

# row_is_conformant <line> — true iff the line is EXACTLY the 4-cell ledger row
# `| id | criterion | evidence | PASS-or-FAIL |`. Counts cells by splitting on
# the delimiter — a glob's `*` happily matches ` | ` and admits a 5-cell row.
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
  # LC_ALL=C so `read -n N` counts BYTES, not characters: bash counts
  # CHARACTERS outside the C locale, so in UTF-8 a 512-"char" read is up
  # to 2048 bytes and the cap is 4x looser than it reads (measured on
  # bash 3.2.57 and 5.2.15: 512 chars of "é" = 1024 bytes). Local, so
  # nothing leaks to the caller — the idiom scripts/lib/partition.sh uses.
  local LC_ALL=C
  mkdir -p "$FRAGDIR"
  # F2/F65: -f follows a symlink and would append every row THROUGH the link
  # into an arbitrary target. Refuse BEFORE the write.
  if [ -L "$FRAGDIR/$who.md" ]; then
    die "verdicts.d/$who.md is a symlink — a fragment our CLIs never wrote; refusing to append every row through it into an arbitrary file (remove the symlink and rerun the verdict)"
  fi
  printf '%s\n' "$2" >> "$FRAGDIR/$who.md"
}

# --- Reconcile path (no task-id) --------------------------------------------
if [ "${1:-}" = "--reconcile" ]; then
  [ -f "$VERDICTS" ] || die "missing $VERDICTS — run ops-init.sh first"
  lock_acquire
  added=0
  skipped=0
  # Candidates first, ONE diff pass: per-row grep is O(rows × ledger), past
  # the lock budget on a 3000-row ledger. (No assoc arrays on bash 3.2.)
  CAND="$(mktemp "${TMPDIR:-/tmp}/opsrec.XXXXXX")"
  MISSINGF="$(mktemp "${TMPDIR:-/tmp}/opsmis.XXXXXX")"
  # trap REPLACES a handler: naming only lock_release here leaked the
  # fallback dir when lock_acquire had degraded. All three signals named.
  trap 'lock_release; fallback_release; rm -f "$CAND" "$MISSINGF"' EXIT
  trap 'lock_release; fallback_release; rm -f "$CAND" "$MISSINGF"; exit 130' INT
  trap 'lock_release; fallback_release; rm -f "$CAND" "$MISSINGF"; exit 143' TERM
  if [ -d "$FRAGDIR" ]; then
    for frag in "$FRAGDIR"/*.md; do
      [ -f "$frag" ] || continue
      # F2: -f follows a symlink — never read a planted fragment as evidence.
      if [ -L "$frag" ]; then
        echo "ops-verdict: refusing fragment ${frag##*/} — it is a symlink, not a fragment our CLIs wrote; skipping (remove it to reconcile the real fragment)" >&2
        continue
      fi
      # Reject the FILE on size, O(1): a per-read cap cannot save a path
      # whose job is reading every row (a 64MB fragment took 31.85s inside
      # the lock — F02/F03). Past the cap is corruption anyway.
      fragsz="$(wc -c < "$frag" 2>/dev/null || echo 0)"
      if [ "$fragsz" -gt "$FRAG_MAX_BYTES" ]; then
        echo "ops-verdict: refusing fragment ${frag##*/} — ${fragsz} bytes exceeds ${FRAG_MAX_BYTES}; it is corrupt, not a ledger (repair or delete it)" >&2
        skipped=$((skipped+1)); continue
      fi
      # 1MiB per read: a smaller cap split long rows across chunks and both
      # halves failed row_is_conformant — honest rows silently dropped (#9).
      while IFS= read -r -n 1048576 row || [ -n "$row" ]; do
        [ -n "$row" ] || continue
        # Reconcile WRITES the ledger, so it enforces the same 4-cell
        # schema. COUNT the cells — a glob's `*` happily consumes ` | `.
        if ! row_is_conformant "$row"; then
          echo "ops-verdict: skipping non-conformant line in ${frag##*/}: $row" >&2
          skipped=$((skipped+1)); continue
        fi
        printf '%s\n' "$row" >> "$CAND"
      done < "$frag"
    done
  fi
  if [ -s "$CAND" ]; then
    # Keep candidates NOT verbatim in the ledger, deduped. grep exit 2 must
    # abort, not read as a false '0 restored' (F13); exit 1 is benign.
    # PIPESTATUS, not an assignment, so grep's exit stays readable.
    grep -Fxv -f "$VERDICTS" -- "$CAND" 2>/dev/null | sort -u > "$MISSINGF"
    gstatus=${PIPESTATUS[0]}
    [ "$gstatus" -le 1 ] || die "grep error ($gstatus) reading $VERDICTS during reconcile — refusing to report a false '0 restored' (check ledger readability)"
    if [ -s "$MISSINGF" ]; then
      added="$(wc -l < "$MISSINGF" | tr -d ' ')"
      cat "$MISSINGF" >> "$VERDICTS"
    fi
  fi
  rm -f "$CAND" "$MISSINGF"
  lock_release
  if [ "$skipped" -gt 0 ]; then
    echo "reconciled: $added row(s) restored to $VERDICTS from $FRAGDIR/ ($skipped non-conformant line(s) skipped — see stderr)"
  else
    echo "reconciled: $added row(s) restored to $VERDICTS from $FRAGDIR/"
  fi
  exit 0
fi

# --- mark-handoff path (no task-id) -----------------------------------------
# A HANDOFF-MARK clears the owning session's DEVIATIONs positioned before it.
# --owner REQUIRED: an unowned mark would clear EVERY session's deviations.
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

# --- Argument parse ----------------------------------------------------------
# The unknown-option arm is `--*`, NOT `-*` (#64): a typo'd `--ownr` must not
# fall to a positional (it once landed in the ledger as the evidence cell),
# and a single-dash evidence cell (`-v output`) is legitimate. `--` ends
# option parsing; `--defer` stays positional (legal only in slot 2).
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
    --)
      shift
      while [ $# -gt 0 ]; do POS+=("$1"); shift; done ;;
    --defer) POS+=("$1"); shift ;;
    --*) die "unknown option '$1' (usage: ops-verdict.sh <id> <criterion> <evidence> <PASS|FAIL> [--owner <sid>] | <id> --defer \"<reason>\" | --reconcile; use -- before a cell that starts with --)" ;;
    *) POS+=("$1"); shift ;;
  esac
done
set -- ${POS+"${POS[@]}"}
# Surplus positionals are the other half of #64. The ceiling is PER FORM:
# the defer form is three, and a single -le 4 left it one free slot.
if [ "${2:-}" = "--defer" ]; then
  [ $# -le 3 ] || die "unexpected extra argument '$4' — the defer form takes exactly <id> --defer \"<reason>\" (a mistyped flag lands here as a positional)"
else
  [ $# -le 4 ] || die "unexpected extra argument '$5' — the verdict form takes exactly <id> <criterion> <evidence> <PASS|FAIL> (a mistyped flag lands here as a positional)"
fi

ID="${1:-}"
[ -n "$ID" ] || die "missing task-id (usage: ops-verdict.sh <id> <criterion> <evidence> <PASS|FAIL> [--owner <sid>] | <id> --defer \"<reason>\" | --reconcile)"
check_bare_name "task-id" "$ID"
if [ -n "$OWNER" ]; then check_owner_name "$OWNER"; fi
[ -d "$OPDIR" ] || die "no $OPDIR/ here or in any parent up to the repo boundary — run ops-init.sh first (from the project root)"

# --- Ownership gate ----------------------------------------------------------
# Mismatch is a hard refusal; a MISSING --owner only warns (a rotated session
# must still close its own work). MUST run under the lock: ownership-then-
# acquire is a TOCTOU against a concurrent adopt.
ownership_gate() {
  # A symlink is not a task our CLIs opened (F65); degrade-to-unowned is not
  # enough here (unowned is closable), so refuse. Single choke point.
  SPATH="$(sentinel_path "$ID")"
  [ -n "$SPATH" ] || SPATH="$OPDIR/pending/$ID"
  [ ! -L "$SPATH" ] || die "sentinel at $SPATH is a symlink — not a sentinel our CLIs wrote; refusing (remove it and open the task with ops-task.sh)"
  # Refuse a non-regular entry BEFORE the row is written (the old order
  # mutated the ledger, then failed to clear).
  if [ -e "$SPATH" ] && [ ! -f "$SPATH" ]; then
    die "sentinel at $SPATH is not a regular file — not a sentinel our CLIs wrote; refusing before writing any row (remove it and open the task with ops-task.sh)"
  fi
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

clear_sentinel() { [ -n "${SPATH:-}" ] && rm -f "$SPATH"; return 0; }

# --- Retro-gate (G1): RETRO_STATE = armed | never-armed | duplicate ---------
# Inside the lock, after ownership_gate. Never-armed with no session dies (G1.4).
retro_gate() {
  # LC_ALL=C so `read -n N` counts BYTES, not characters: bash counts
  # CHARACTERS outside the C locale, so in UTF-8 a 512-"char" read is up
  # to 2048 bytes and the cap is 4x looser than it reads (measured on
  # bash 3.2.57 and 5.2.15: 512 chars of "é" = 1024 bytes). Local, so
  # nothing leaks to the caller — the idiom scripts/lib/partition.sh uses.
  local LC_ALL=C
  RETRO_STATE="armed"
  # REGULAR non-symlink → armed (unowned-but-present fails closed). `-e`
  # once read a directory as armed, suppressing the GATE-EXCEPTION.
  if [ -n "${SPATH:-}" ] && [ -f "$SPATH" ] && [ ! -L "$SPATH" ]; then
    return 0
  fi

  # Sentinel absent. We need a session to tag the GATE-EXCEPTION.
  local tag_owner="${OWNER:-$SOWNER}"
  if [ -z "$tag_owner" ]; then
    die "never-armed verdict requires --owner <session-id> — the GATE-EXCEPTION must carry a [sid:] tag, and there is no sentinel to supply one"
  fi

  # Prior-row scan, bounded by FRAG_MAX_BYTES. EVERY line start is tested:
  # a split long row's leading chunk carries the prefix (#9), and a
  # continuation chunk never does — necessary and safe.
  local frag="$FRAGDIR/${tag_owner}.md" fragsz=0 found=1 line n=0
  # F2: a symlink fragment must not count as a prior row.
  if [ -f "$frag" ] && [ ! -L "$frag" ]; then
    fragsz="$(wc -c < "$frag" 2>/dev/null || echo 0)"
    if [ "$fragsz" -gt "$FRAG_MAX_BYTES" ]; then
      echo "ops-verdict: fragment ${frag##*/} exceeds FRAG_MAX_BYTES (${fragsz}); prior-row scan refused — treating as never-armed" >&2
    else
      while IFS= read -r -n 1048576 line || [ -n "$line" ]; do
        n=$((n+1)); [ "$n" -le 200000 ] || break  # backstop: ~100k rows at ~80 bytes
        case "$line" in
          "| $ID |"*) found=0; break ;;
        esac
      done < "$frag"
    fi
  fi

  if [ "$found" -eq 0 ]; then
    RETRO_STATE="duplicate"
    echo "ops-verdict: warning — no sentinel for '$ID' but a prior row exists in the fragment; treating as duplicate/amending row" >&2
    # #14 (U2): closed by the exception-before-row write order below. The
    # reverted guard (downgrade only when an exception exists) stays out —
    # an ARMED first verdict also leaves a row with no exception (G1.7).
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
  # G1 applies to BOTH closing paths, or a bypass would defer instead of PASS.
  retro_gate
  # NOT reordered like the verdict path (#14): --defer writes no fragment
  # row, so the crash-interrupted state is recoverable as-is. Re-check if
  # --defer ever writes a fragment.
  printf '%s | %s | DEFERRED-VERDICT | %s | deferred via ops-verdict.sh --defer\n' \
    "$(date +%F)" "$ID" "$REASON" >> "$DECISIONS"
  if [ "$RETRO_STATE" = "never-armed" ]; then
    printf '%s | %s | GATE-EXCEPTION | [sid:%s] defer of %s recorded without an open sentinel — no task was opened | never-armed via ops-verdict.sh --defer\n' \
      "$(date +%F)" "$ID" "${OWNER:-$SOWNER}" "$ID" >> "$DECISIONS"
  fi
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

# Resolved BEFORE the lock: git status is unbounded work; nothing waits on it.
SOURCE_STAMP="$(source_stamp)"

lock_acquire
ownership_gate            # inside the lock: adoption cannot slip in behind it
retro_gate                # three-state arm check (G1) — also inside the lock
ROW="$(printf '| %s | %s | %s @%s | %s |' "$ID" "$CRITERION" "$EVIDENCE" "$SOURCE_STAMP" "$VERDICT")"
# Write order — every part load-bearing (#14/U2): 1. GATE-EXCEPTION before
# the row (a crash after row-first left a bypass keeping its PASS and losing
# its audit line; exception-first at worst duplicates the exception);
# 2. fragment (repairable by --reconcile); 3. ledger row (un-repairable, so
# last); 4. sentinel clear (any failure above leaves the task OPEN).
if [ "$RETRO_STATE" = "never-armed" ]; then
  printf '%s | %s | GATE-EXCEPTION | [sid:%s] verdict %s recorded without an open sentinel — no task was opened | never-armed via ops-verdict.sh\n' \
    "$(date +%F)" "$ID" "${OWNER:-$SOWNER}" "$ID" >> "$DECISIONS"
fi
# Fragment BEFORE the ledger: that direction is the --reconcile-repairable one.
append_fragment "$FRAG_OWNER" "$ROW"
printf '%s\n' "$ROW" >> "$VERDICTS"
clear_sentinel
lock_release
if [ "$RETRO_STATE" = "never-armed" ]; then
  echo "recorded $ID = $VERDICT (never-armed — GATE-EXCEPTION written to DECISIONS.md)"
elif [ "$RETRO_STATE" = "duplicate" ]; then
  echo "recorded $ID = $VERDICT (duplicate/amending row — no sentinel, prior row exists)"
else
  echo "recorded $ID = $VERDICT (row appended, sentinel cleared)"
fi
exit 0
