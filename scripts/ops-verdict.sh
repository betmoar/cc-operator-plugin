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

# --- The source-state stamp (U10, issue #22) --------------------------------
# Every verdict row carries the source state it was produced from, appended
# inside the evidence cell as `@<sha>` / `@<sha>+dirty` / `@<sha>+unknown` /
# `@no-commit` / `@no-vcs`.
#
# Why it exists: a PASS used to survive unstaged, staged, committed and
# untracked mutation of the very source it verified, with the Stop hook silent
# through all four — because the row named no tree at all. Measured, issue #22.
#
# Why INSIDE the cell and not a fifth column: the 4-cell header is a published
# schema. Every existing ledger, every grep consumer, and validate_plugin's
# VERDICTS_HEADER pin are written against it, and CLAUDE.md's coupling table
# says plainly that changing it breaks grep-compatibility with every ledger
# already in the field. A token inside the cell binds the row at none of that
# cost.
#
# What it proves, stated so nobody claims more: the stamp is written by the same
# process that writes the row. It is PROVENANCE — "this row was written from
# that tree" — and never attestation — "that tree passes". The staleness reader
# (#22 step 2), independent execution (#23) and external reproduction (#25) are
# each still open.
#
# It never refuses. A verdict is real evidence and the charter's rule is that
# the gate never refuses real evidence, so every failure degrades to an explicit
# marker. Explicit, not silent: an UNSTAMPED row means "written by a version
# older than this stamp", and an audit that cannot separate that from "git was
# missing" cannot begin.
source_stamp() {
  local sha porc rc
  # Two separate questions — git absent, and git present but this is not a repo.
  # Both answer no-vcs; splitting them would only add a marker nobody can act on.
  command -v git >/dev/null 2>&1 || { printf 'no-vcs'; return 0; }
  git rev-parse --git-dir >/dev/null 2>&1 || { printf 'no-vcs'; return 0; }
  sha="$(git rev-parse --verify --short=12 HEAD 2>/dev/null || true)"
  # Unborn HEAD — a repo with no commits. There is a tree; there is no name for
  # it. Recorded as such rather than refused.
  [ -n "$sha" ] || { printf 'no-commit'; return 0; }
  # The sha becomes ledger content, and this file treats every external string
  # as untrusted (the 2026-07-10 traversal came back through exactly that door).
  # Non-hex means git answered something we do not understand: degrade, never
  # embed it.
  case "$sha" in
    *[!0-9a-f]*) printf 'no-vcs'; return 0 ;;
  esac
  # Dirty = any change to the SOURCE. `.operator/` is excluded because the
  # gate's own bookkeeping is not the tree under test: it is untracked in any
  # project that has not committed its ledger — nearly all of them — so counting
  # it would pin every row everywhere to +dirty, and a marker that can never be
  # off is the vacuous-guard class (#21) shipped as a feature. This is the same
  # boundary `ops-claims.sh --expect-clean` already draws.
  #
  # Scope is the whole repository, not the project subdirectory: a change
  # anywhere in it can change what a command prints, and a stamp that
  # under-reports dirt is worse than no stamp.
  #
  # `local porc; porc=…` on two lines, deliberately: `local porc="$(…)"` returns
  # the exit status of `local`, which is always 0, so the rc branch below would
  # be dead code.
  porc="$(git status --porcelain -- ':(exclude).operator' 2>/dev/null)" && rc=0 || rc=$?
  # An infra failure must not read as CLEAN — that is the strong claim here, and
  # fail-toward-the-strong-claim is the polarity the PLAYBOOK forbids.
  [ "$rc" -eq 0 ] || { printf '%s+unknown' "$sha"; return 0; }
  [ -z "$porc" ] || { printf '%s+dirty' "$sha"; return 0; }
  printf '%s' "$sha"
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
    # `__` separates owner from task in the sentinel NAME — same reasoning and
    # same PR #77 review finding as ops-adopt.sh's copy; a `sessA__evilB`
    # owner made every reader's first-`__` split parse owner `sessA`, letting
    # a session that adopted nothing close the real adopter's task.
    *__*) die "$1 must not contain '__' (it separates owner from task in the sentinel name)" ;;
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
# The absolute ceiling — the only budget that bounds the loop for EVERY cause
# rather than for the causes we anticipated (#68). Both budgets above count
# ITERATIONS and both `continue` past their own limit when the escape path
# itself fails, so neither is a bound. Measured: 54 leaked processes, the oldest
# ~17 days, each burning ~1 core and writing 2.7 MB of warnings into /dev/null,
# because `mkdir` was failing with ENOENT (the ledger directory removed under an
# in-flight run) and every reclaim branch opened with another `mkdir` in the
# same vanished parent. A ceiling that always exits turns any such state into
# LOCK_MAX_SPINS × 0.1s, whatever the cause — including causes not yet met.
# Precisely: it bounds THIS loop. A run that degrades to the fallback pays
# FALLBACK_SPINS on top, so the true worst case is their sum (125s at defaults).
# The fallback loop is separately bounded — its budget check precedes every
# branch and its reclaim `continue` does not rewind the counter — so it is not
# a second #68, but the sum is the honest number.
LOCK_MAX_SPINS=${LOCK_MAX_SPINS:-1200}   # × 0.1s = 120s hard ceiling, always exits

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
# The ceiling is validated like the others, and must exceed BOTH iteration
# budgets — a ceiling below them would fire during ordinary contention and turn
# a working wait into a refusal, which is how a safety limit gets removed.
_lock_check_budget LOCK_MAX_SPINS "$LOCK_MAX_SPINS" "$LOCK_MAX_SPINS"
# An explicit `if`, not `A && B || C`: with the short-circuit form, C also runs
# when A is true and B is false, which is a real branch here — and shellcheck
# refuses it (SC2015), so the build catches the shape before the logic bites.
if [ "$LOCK_MAX_SPINS" -le "$LOCK_SPINS" ] || [ "$LOCK_MAX_SPINS" -le "$LOCK_LIVE_SPINS" ]; then
  _lock_budget_die "LOCK_MAX_SPINS (must exceed LOCK_SPINS and LOCK_LIVE_SPINS)" "$LOCK_MAX_SPINS"
fi

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
  # `2>/dev/null` on the read does NOT silence a failed INPUT redirection: the
  # shell reports `<file` failing before the command's own redirections apply,
  # so a holder file removed between the `[ -f ]` above and this line printed a
  # raw bash error at the operator — the "raw bash error as operator guidance"
  # class. It is a real race, not a hypothetical: measured at ~1 line per 3 runs
  # of 40 concurrent writers, on this code and on its 0.4.0 predecessor alike.
  # Redirecting the whole compound silences the redirection failure too; the
  # empty LOCK_HOLDER_REC that results is already the documented
  # "cannot judge this holder" input, which the caller handles.
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
      echo "ops-verdict: warning — fallback lock $FALLBACK_DIR held by another degraded writer for >$((FALLBACK_SPINS / 10))s; proceeding without it" >&2
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

# Reached ONLY through the trap strings installed by the two acquire paths. The
# linter cannot follow a trap, so every line below reads as dead code (SC2317);
# `lock_release` escapes the same fate only because it also has direct callers.
# (A comment whose FIRST word is the linter's name is parsed as a directive —
#  hence the wording above. SC1072/SC1073, hit while writing this.)
# shellcheck disable=SC2317
fallback_release() {
  [ "${FALLBACK_HELD:-0}" = "1" ] || return 0
  FALLBACK_HELD=0
  # Same displacement guard as lock_release: if the fallback no longer names us
  # a later giver-up reclaimed it, and removing it would delete THAT holder's dir.
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
    # THE CEILING, first thing in the body and counted on a variable nothing
    # else resets. `i` is deliberately rewound by the deferral backoff below
    # (`i=$((LOCK_SPINS - RECLAIM_WAIT))`), so `i` can never bound the loop —
    # that rewind is exactly how a repeating failure spins forever (#68).
    # `total` only ever increases, so this exit is reachable from every state.
    total=$((total+1))
    if [ "$total" -ge "$LOCK_MAX_SPINS" ]; then
      # Refuse rather than proceed unlocked. The two "proceed unlocked" exits
      # elsewhere are reached from a JUDGED state — we know who holds it and
      # why. Here we know nothing except that acquiring has been impossible for
      # two minutes, and the likeliest cause is that the ledger directory is
      # gone underneath us, in which case writing a row is meaningless anyway.
      echo "ops-verdict: could not acquire $LOCKDIR after $((LOCK_MAX_SPINS / 10))s — refusing to spin further." >&2
      if [ ! -d "${LOCKDIR%/*}" ]; then
        # Name the cause when it is knowable: this is the #68 shape exactly,
        # and the generic message above sent a maintainer hunting a contention
        # problem that does not exist.
        echo "ops-verdict: ${LOCKDIR%/*} does not exist — the ledger directory was removed while this run was in flight." >&2
      fi
      exit 2
    fi
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
# The name-guard reject set still applies, now at construction rather than at
# every reader: an owner that our CLIs could never have written cannot appear in
# a filename they create. A name with no `__` is unowned, which fails CLOSED
# (blocks everyone) — the safe direction, unchanged.
# Ownership is in the sentinel's NAME: pending/<owner>__<task>, or pending/<task>
# when unowned. No file is opened, so the byte-bounded read, the LC_ALL=C byte
# counting, the NUL pre-scan and the symlink-degrade that guarded the old body
# parser all go with it — 51 lines here, 84 in the Stop hook, 49 in the
# statusline, for one field the writer already had in hand.
#
# What those guards defended against is gone rather than re-implemented: a
# planted file cannot smuggle an owner, because nothing reads its contents. What
# remains is a string split, and `__` is refused in both halves at construction.
sentinel_path() { # sentinel_path <task-id> → path of its sentinel, or empty
  local _t="$1" _f
  shopt -s nullglob
  for _f in "$OPDIR/pending/$_t" "$OPDIR/pending"/*__"$_t"; do
    # -e OR -L: `-e` is FALSE for a dangling symlink, so a planted broken link
    # went unseen and a second sentinel was created beside it for the same task.
    # A planted entry must be found and refused, not stepped around.
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
  # The F1 reject set, moved with the attack surface rather than deleted with the
  # body parser. Our CLIs can never write these shapes (check_bare_name refuses
  # them at construction), so a name carrying one was PLANTED — and the
  # grant-suffix arm in particular would let a planted sentinel pose as the owner
  # of a G3 grant and get another session's exemption deleted by
  # recompute_arm_marker. Degrade to unowned, which blocks everyone: fails
  # CLOSED, the safe direction.
  #
  # The literals live ONLY in the case below, never in this prose: the vacuity
  # test mutates raw text, so a comment repeating a pinned literal absorbs the
  # mutation and the pin stops proving anything.
  case "$_o" in
    "" | */* | .* | *"|"* | *[[:space:]]* | *.exempt) printf '\n'; return 0 ;;
  esac
  printf '%s\n' "$_o"
}

sentinel_owner() { # sentinel_owner <task-id> → owner ("" if unowned/absent)
  local _p; _p="$(sentinel_path "$1")"
  [ -n "$_p" ] || { printf '\n'; return 0; }
  sentinel_owner_of_name "${_p##*/}"
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
  # F2/F65 verdicts.d/: a symlink fragment is never a fragment our CLIs wrote.
  # `-f` FOLLOWS a planted or merge-corrupted symlink here and would append every
  # row for this owner THROUGH the link into an arbitrary target, exit 0, silent
  # — the same laundering class fixed at the five pending/ sites, unguarded in
  # the evidence-fragment directory. Refuse BEFORE the write, mirroring the
  # pending/ refuse-before-write pattern (ownership_gate's regular-file check).
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
  # Collect candidate rows first, then diff against the ledger in ONE pass.
  # The obvious `grep -Fxq` per fragment row is O(rows × ledger) and shells out
  # per row — measured ~7s for a 3000-row ledger, which would exceed any sane
  # lock budget and push concurrent writers onto the unlocked path, the lock's
  # guarantee evaporating exactly when it matters. Associative arrays would be
  # the other fix, but macOS /bin/bash is 3.2 and has none.
  CAND="$(mktemp "${TMPDIR:-/tmp}/opsrec.XXXXXX")"
  MISSINGF="$(mktemp "${TMPDIR:-/tmp}/opsmis.XXXXXX")"
  # `trap` REPLACES a handler for the same signal, it does not stack. This runs
  # AFTER lock_acquire, which may have degraded to fallback_acquire and installed
  # `lock_release; fallback_release` — so naming only lock_release here silently
  # dropped fallback_release for the rest of the process, leaking
  # $LOCKDIR.fallback on every reconcile-under-contention. Measured: a live
  # holder + LOCK_LIVE_SPINS=3 left .operator/.lock.fallback on disk after exit.
  # The two acquire paths carry this same warning; this site is the one that
  # ignored it. The reconcile block also named no INT/TERM of its own. That was
  # survivable but not safe: on a signal the acquire path's OWN handler ran the
  # releases, then this EXIT trap ran and removed the tempfiles — correct only
  # by inheritance, and silently wrong for any invocation that reaches here
  # without one (a future caller, or an acquire path that stops trapping).
  # Naming all three here makes the block self-sufficient.
  trap 'lock_release; fallback_release; rm -f "$CAND" "$MISSINGF"' EXIT
  trap 'lock_release; fallback_release; rm -f "$CAND" "$MISSINGF"; exit 130' INT
  trap 'lock_release; fallback_release; rm -f "$CAND" "$MISSINGF"; exit 143' TERM
  if [ -d "$FRAGDIR" ]; then
    for frag in "$FRAGDIR"/*.md; do
      [ -f "$frag" ] || continue
      # F2: `-f` follows a symlink — a planted/merge-corrupted fragment must
      # not be read as evidence. A symlink is never a fragment our CLIs wrote.
      if [ -L "$frag" ]; then
        echo "ops-verdict: refusing fragment ${frag##*/} — it is a symlink, not a fragment our CLIs wrote; skipping (remove it to reconcile the real fragment)" >&2
        continue
      fi
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
      # The bound is generous (1MiB) because a long evidence cell (>512B) splits
      # a row across chunks and each split chunk fails row_is_conformant — the
      # issue-#9 long-row blindness class, silently dropping honest rows from the
      # ledger on every reconcile. Same bound as retro_gate's prior-row scan.
      while IFS= read -r -n 1048576 row || [ -n "$row" ]; do
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
    # A ledger that became unreadable mid-reconcile (concurrent access, dropped
    # perms) makes grep exit 2; the old `|| true` masked that as a false
    # '0 restored' — silent data loss reported as success. Abort instead.
    # exit 1 is the benign "nothing missing" case and stays green. F13.
    # The pipeline writes to MISSINGF (not a command substitution) so grep's
    # exit is readable from PIPESTATUS — an assignment resets it. The guard is
    # the grep EXIT code (works on every uid, unlike a mode-bit test), so an
    # unreadable ledger aborts regardless of who runs reconcile.
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
#
# The unknown-option arm is `--*`, NOT `-*`, and the difference is load-bearing
# in both directions (issue #64):
#
#   without it — a typo'd `--ownr WRONG` fell through to the positional bucket,
#     was discarded past $4, and the HARD ownership refusal silently degraded to
#     the missing-owner WARNING, letting one session close another's task at
#     rc 0. Worse, measured: `<id> <crit> --ownr=X PASS` wrote the typo'd flag
#     into the ledger AS THE EVIDENCE CELL.
#   with `-*` instead — a single-dash evidence cell is legitimate and common
#     (`-v output: 3 passed` records correctly today, measured against 0.8.0);
#     a blind dash reject refuses real usage, which is how a guard gets removed.
#
# So: double-dash is a flag namespace WE own and can adjudicate; single-dash is
# left to the positional slots, where the surplus check below catches the rest.
# `--` ends option parsing for the case a cell genuinely opens with `--`.
# `--defer` is a positional by design — the defer path tests `${2:-}`, i.e. it
# is legal only in slot 2, and passing it through here keeps that the one rule.
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

# A surplus positional is the other half of the same slip: `--ownr WRONG` split
# into two extra positionals, and everything past $4 was silently dropped.
#
# The ceiling is PER FORM, because the two forms have different arities and a
# single `-le 4` bounds only the wider one. The defer form is three
# (`<id> --defer "<reason>"` — `--defer` is itself a positional, passed through
# by the parse loop above), so a `-le 4` ceiling left it exactly one free slot:
# `ops-verdict.sh <id> --defer "reason" STRAY --owner <sid>` deferred the task
# at rc 0 with STRAY silently discarded (measured). A realistic shape — a
# forgotten `--owner` flag leaves the bare session id sitting there — and it is
# the very class this check was added to close, surviving in the other form.
if [ "${2:-}" = "--defer" ]; then
  [ $# -le 3 ] || die "unexpected extra argument '$4' — the defer form takes exactly <id> --defer \"<reason>\" (a mistyped flag lands here as a positional)"
else
  [ $# -le 4 ] || die "unexpected extra argument '$5' — the verdict form takes exactly <id> <criterion> <evidence> <PASS|FAIL> (a mistyped flag lands here as a positional)"
fi

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
  SPATH="$(sentinel_path "$ID")"
  [ -n "$SPATH" ] || SPATH="$OPDIR/pending/$ID"
  [ ! -L "$SPATH" ] || die "sentinel at $SPATH is a symlink — not a sentinel our CLIs wrote; refusing (remove it and open the task with ops-task.sh)"
  # …and neither is a directory or a device. Refuse BEFORE the row is written,
  # not at `rm` time: the old order appended the row, then failed to clear, so
  # the CLI exited non-zero with the ledger already mutated. Same regular-file
  # contract as ops-task.sh's opener and every sentinel reader.
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
    if [ "$(sentinel_owner_of_name "${f##*/}")" = "$sid" ]; then still=0; break; fi
  done
  shopt -u nullglob
  if [ "$still" -eq 0 ]; then
    # Explicit `if`, not `A && B || C` (SC2015): the chained form runs the
    # `|| true` even when the truncate itself failed, conflating the two.
    if mkdir -p "$OPDIR/.armed" 2>/dev/null; then
      : > "$OPDIR/.armed/$sid" 2>/dev/null || true
    fi
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
  #
  # A REGULAR file, non-symlink: the same contract ops-task.sh:234, the Stop
  # hook and the statusline all apply. `-e` accepted a directory or a device as
  # an armed sentinel, and the consequence was not a cosmetic mismatch: the
  # retro-gate returned "armed", SUPPRESSING the GATE-EXCEPTION, the row was
  # appended anyway, and the later `rm -f` then failed on the directory — so the
  # CLI exited non-zero having already written an unaudited row (measured
  # 2026-08-12; Copilot review of PR #12). Anything non-regular at this path was
  # never written by our CLIs, so it must not silence the audit line.
  if [ -n "${SPATH:-}" ] && [ -f "$SPATH" ] && [ ! -L "$SPATH" ]; then
    return 0
  fi

  # Sentinel absent. We need a session to tag the GATE-EXCEPTION.
  local tag_owner="${OWNER:-$SOWNER}"
  if [ -z "$tag_owner" ]; then
    die "never-armed verdict requires --owner <session-id> — the GATE-EXCEPTION must carry a [sid:] tag, and there is no sentinel to supply one"
  fi

  # Check for prior rows in the session fragment. The fragment is append-only
  # so the newest row is at the tail, but for a binary "does any row exist?"
  # check, forward scan is equivalent and cross-platform. Bounded by
  # FRAG_MAX_BYTES — the PLAYBOOK "touching the lock" step-3 hazard.
  #
  # The id-prefix `| <id> |` is always at a LINE START. So we test EVERY line
  # start, never skipping a chunk: a long evidence cell (>512B) splits a row
  # across read chunks, and the chunk that STARTS the row is the one carrying
  # the prefix — skipping it (the issue-#9 long-row blindness class) misfiles a
  # genuine duplicate as never-armed and writes a spurious GATE-EXCEPTION.
  # A continuation chunk (mid-cell) never begins with `| <id> |`, so matching
  # every line start is both necessary and safe. The per-line bound is generous:
  # rows are ~80B honest, but an evidence cell can run to several KB, and the
  # file is already size-capped above, so a corrupted newline-less line yields a
  # few bounded non-matching chunks, not an unbounded slurp.
  local frag="$FRAGDIR/${tag_owner}.md" fragsz=0 found=1 line n=0
  # F2: `-f` follows a symlink; a symlink fragment must not count as a prior
  # row (it would either dodge the duplicate/GATE-EXCEPTION branch or leak the
  # target's contents). A symlink is never a fragment our CLIs wrote.
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
    # #14 (U2), CLOSED in 0.8.4 by reordering the two appends — read the write
    # block at the bottom of this file for the reasoning. Kept here because THIS
    # branch is where the old failure surfaced, and a reader who lands on it
    # needs to know why it is no longer one.
    #
    # It was: the fragment row and the GATE-EXCEPTION are two appends, so a crash
    # between them left a row whose audit line never landed, and this branch read
    # that row as an amendment — the bypass record lost. The exception now goes
    # FIRST, so the crash-interrupted state is an exception with no row, which a
    # retry completes rather than misreads.
    #
    # What did NOT change, and must not: the guard that downgrades to `duplicate`
    # only when a GATE-EXCEPTION for <id> exists. It was implemented and REVERTED,
    # because a legitimately ARMED first verdict also leaves a row with no
    # exception, so it reclassified every ordinary armed-then-amended verdict as
    # never-armed and wrote a spurious exception (case G1.7 caught it). "Prior row
    # without exception" is still ambiguous between the two; the reorder works by
    # removing the ambiguous state, not by reading it.
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
  # G1 applies to BOTH closing paths. --defer retires a task exactly as a verdict
  # does, so deferring an id that was never opened is an unarmed close and earns
  # the same GATE-EXCEPTION. Without this a session could retire arbitrary ids it
  # never armed and leave no trace, while the identical act through the PASS/FAIL
  # path is recorded — an asymmetry a bypass would find (PR review 2026-08-07).
  retro_gate
  # NOT reordered like the verdict path was for #14, and the asymmetry is
  # deliberate. U2's loss needs a reader that misclassifies the surviving half:
  # there, a row with no exception is read as an amendment by retro_gate's
  # prior-row scan. That scan reads the session FRAGMENT, and --defer writes no
  # fragment row at all — so a crash between these two appends leaves a
  # DEFERRED-VERDICT with no exception, the retry classifies never-armed again
  # (unchanged, since nothing it reads has moved), and the exception lands.
  # The audit line is recoverable here; reordering would only trade that for a
  # duplicate exception. Re-check this if --defer ever starts writing a fragment.
  printf '%s | %s | DEFERRED-VERDICT | %s | deferred via ops-verdict.sh --defer\n' \
    "$(date +%F)" "$ID" "$REASON" >> "$DECISIONS"
  if [ "$RETRO_STATE" = "never-armed" ]; then
    printf '%s | %s | GATE-EXCEPTION | [sid:%s] defer of %s recorded without an open sentinel — the arm gate was not used | never-armed via ops-verdict.sh --defer\n' \
      "$(date +%F)" "$ID" "${OWNER:-$SOWNER}" "$ID" >> "$DECISIONS"
  fi
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

# Resolved BEFORE the lock. `git status` is unbounded work on a large repo, and
# a holder that outruns LOCK_LIVE_SPINS does not lose its lock — its waiters
# give up and proceed UNLOCKED. Nothing waits on the stamp, so nothing is gained
# by paying for it inside the critical section (PLAYBOOK, "touching the lock",
# step 3).
SOURCE_STAMP="$(source_stamp)"

lock_acquire
ownership_gate            # inside the lock: adoption cannot slip in behind it
retro_gate                # three-state arm check (G1) — also inside the lock
ROW="$(printf '| %s | %s | %s @%s | %s |' "$ID" "$CRITERION" "$EVIDENCE" "$SOURCE_STAMP" "$VERDICT")"
# Write order in this block, and every part of it is load-bearing:
#   1. GATE-EXCEPTION (if never-armed)  — #14, reasoned through below
#   2. fragment                          — repairable by --reconcile
#   3. ledger row                        — the un-repairable one, so it goes last
#   4. sentinel clear                    — last of all, so a failure anywhere
#      above leaves the task OPEN and the gate holds
#
# G1 / #14 (U2): the GATE-EXCEPTION is written BEFORE the row, and the order is
# the whole fix. The pair is two appends, not one atomic act, so the ordering
# decides what a crash between them leaves behind:
#
#   row first (until 0.8.4): a row with no exception. The retry reads a prior row
#     for an id with no sentinel and classifies it `duplicate` — so a genuine
#     bypass KEEPS its PASS row and LOSES its exception. That is precisely the
#     outcome G1 exists to prevent, reached through a crash window instead of a
#     swallowed error.
#   exception first (now): an exception with no row. The retry re-runs and
#     appends the row; the exception is at worst duplicated, which is a
#     legible audit trail rather than a missing one. An orphan exception says
#     "an unarmed close was attempted here" — true, and the conservative
#     direction to be wrong in.
#
# The guard the issue records as built-and-reverted is still the wrong fix and
# stays out: "prior row without an exception" cannot distinguish crash-interrupted
# from ordinary-armed-then-amended (an armed first verdict also leaves a row with
# no exception), so it reclassified every amendment as never-armed and wrote a
# spurious exception — case G1.7 caught it. Reordering needs no such distinction,
# because it removes the state that was ambiguous rather than trying to read it.
#
# Both appends are already under the SAME lock, so no concurrent writer can
# interleave between them; the window this closes is a crash, not a race.
if [ "$RETRO_STATE" = "never-armed" ]; then
  printf '%s | %s | GATE-EXCEPTION | [sid:%s] verdict %s recorded without an open sentinel — the arm gate was not used | never-armed via ops-verdict.sh\n' \
    "$(date +%F)" "$ID" "${OWNER:-$SOWNER}" "$ID" >> "$DECISIONS"
fi
# Fragment BEFORE the ledger. Under `set -e` a failed write aborts the script, so
# the order decides what a partial failure leaves: a fragment without a ledger row
# is repaired by --reconcile and a duplicate fragment row is deduped there, but a
# ledger row without its fragment is silently un-repairable, and a retry after the
# abort would double the ledger row.
append_fragment "$FRAG_OWNER" "$ROW"
printf '%s\n' "$ROW" >> "$VERDICTS"
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
