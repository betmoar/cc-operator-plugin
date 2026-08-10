#!/usr/bin/env bash
# ops-task.sh — open a tracked task: drop the sentinel .operator/pending/<id>.
# The Stop hook blocks session end until ops-verdict.sh clears the sentinel
# (verdict row or --defer). Idempotent: re-opening an open id is a no-op —
# including its ownership, so re-opening can never be a silent takeover.
#
# The sentinel body stamps who opened it, so the Stop hook can block only the
# OWNING session and merely report everyone else's open tasks:
#
#   session_id: <id>     omitted when unknown → unowned → blocks every session
#   cwd: <path>          forensics only (the hook enumerates by payload cwd)
#   opened_at: <ISO8601>
#
# The agent learns its session id from the SessionStart hook's injected context;
# CLAUDE_SESSION_ID is NOT set in the Bash tool environment.
#
# Usage: run from the project root (cwd):  ops-task.sh <task-id> [--owner <sid>]
#        the audited arm-gate escape hatch: ops-task.sh --exempt "<reason>" --owner <sid>
set -eu

OPDIR=".operator"

die() { echo "ops-task: $1" >&2; exit 2; }

NL="$(printf '\nx')"; NL="${NL%x}"

# A bare name: it is a filename (sentinel, and downstream a fragment file), so
# a '/' would let a later rm -f reach outside .operator/ — the 2026-07-10
# traversal bug. '|' and newlines would break the one-line 4-cell ledger schema.
# A LEADING DOT is refused because the Stop hook enumerates pending/ with a
# plain glob, which does not match dotfiles: `.hidden` would be a sentinel the
# gate cannot see — an open task that silently never blocks. Keep this rule
# identical in ops-verdict.sh and ops-adopt.sh (tests/test-scripts.sh case 12
# asserts all three agree).
check_bare_name() { # check_bare_name <label> <value>
  case "$2" in
    */*) die "$1 must be a bare name (no '/')" ;;
    .*) die "$1 must not start with '.' — a dotfile sentinel is invisible to the Stop hook's glob" ;;
    *"|"* | *"$NL"*) die "$1 must not contain '|' or newlines" ;;
  esac
}

# OWNERS additionally refuse whitespace, and TASK IDS deliberately do not.
# The Stop hook compares the stamped owner byte-for-byte against the payload's
# session id, so an owner with a stray space can never equal any real session:
# the sentinel is FOREIGN forever and foreign sentinels never block — a silently
# disarmed gate. That reasoning is about session ids and does not transfer to
# task ids. Applying it to both wedged pre-0.4 tasks whose ids contain a space
# (0.3.0 accepted them): the hook still blocked on the sentinel while every
# closing path refused the id, so the session could never stop at all — the
# exact trap this release removes. Keep the two guards separate.
check_owner_name() { # check_owner_name <value>
  check_bare_name "owner" "$1"
  case "$1" in
    *[[:space:]]*) die "owner must not contain whitespace — it could never match a real session id, leaving the task permanently unblockable" ;;
    # `.armed/` holds TWO marker kinds in ONE flat namespace: `<sid>` (derived
    # cache, the recompute may delete it) and `<sid>.exempt` (a G3 grant, the
    # recompute must never touch it). An owner ending in `.exempt` collides with
    # the second, in BOTH directions (issue #29, measured):
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

ID=""
OWNER=""
EXEMPT=""       # the reason text
EXEMPT_SEEN=0   # --exempt given at all (so a MISSING reason is distinguishable
                # from "no --exempt" — an empty reason must fail loudly, G3.2)
while [ $# -gt 0 ]; do
  case "$1" in
    # --- the arm-gate exemption (G3) -----------------------------------------
    # Mutually exclusive with opening a task id: an exemption is the "I am
    # writing WITHOUT an open task" path, so accepting both would be asking for
    # two contradictory things in one command.
    --exempt)
      [ "$EXEMPT_SEEN" -eq 0 ] || die "--exempt given more than once"
      EXEMPT_SEEN=1
      [ $# -ge 2 ] || die "--exempt requires a non-empty reason"
      # A reason starting with '-' is a FORGOTTEN reason, not a reason: without
      # this, `--exempt --owner S` swallows the flag as the reason text and the
      # failure surfaces two branches later as a nonsense "unexpected task-id
      # 'S'". Refuse where the mistake is.
      case "$2" in
        -*) die "--exempt requires a reason, got the flag '$2' — quote the reason: --exempt \"<reason>\" --owner <sid>" ;;
      esac
      EXEMPT="$2"; shift 2 ;;
    --exempt=*)
      [ "$EXEMPT_SEEN" -eq 0 ] || die "--exempt given more than once"
      EXEMPT_SEEN=1
      EXEMPT="${1#--exempt=}"; shift ;;
    # Refuse a repeated --owner rather than silently taking the last: a
    # duplicated flag means the caller is confused about ownership, which is
    # the one thing this mechanism must not guess at.
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

# --- the exemption grant (G3) ------------------------------------------------
# The arm gate (ops-armgate-hook.sh) blocks file mutations by a session with no
# open task. A blocking gate with no override is how a session WEDGES, which is
# this repo's recurring worst outcome — so the gate ships with an escape hatch
# that is audited rather than free: the grant writes a GATE-EXCEPTION line to
# DECISIONS.md, and GATE-EXCEPTION is already in the stage-2 deviation gate's
# blocking set. Bypassing the arm gate therefore OWES a handoff presentation
# (ops-verdict.sh --mark-handoff), enforced by machinery that already ships.
#
# THIS SCRIPT DOES NOT WRITE THE LEDGER. It takes no lock, on purpose — the
# O_EXCL create below is arbitrated by the kernel ("no lock needed") — and every
# DECISIONS.md append in this repo happens inside ops-verdict.sh's critical
# section, with validate_plugin.check_lock_parity pinning the LOCK BLOCK across
# the writers that have it. Giving the opener a lock would copy that block to a
# third file, and put lock code in the path that runs on every task open, for
# one rare flag. So: parse and validate here, DELEGATE the write to the single
# writer, which already holds the lock. G3.6 pins this file's occurrence count
# of the acquire call at zero, so keep the literal out of these comments too.
if [ "$EXEMPT_SEEN" -eq 1 ]; then
  [ -z "$ID" ] || die "--exempt takes no task-id (got '$ID') — an exemption is the no-open-task path; open a task instead if you have one"
  [ -n "$EXEMPT" ] || die "--exempt requires a non-empty reason (the grant is audited: the reason is what the handoff presents)"
  [ -n "$OWNER" ] || die "--exempt requires --owner <sid> — the GATE-EXCEPTION must carry a [sid:] tag and the marker is keyed by session"
  check_owner_name "$OWNER"
  [ -d "$OPDIR" ] || die "no $OPDIR/ in cwd — run ops-init.sh first"

  # Resolve the single writer as OUR SIBLING: installed we are
  # .operator/bin/ops-task.sh next to .operator/bin/ops-verdict.sh; in this repo
  # we are scripts/ops-task.sh next to scripts/ops-verdict.sh. Both hold. The
  # $OPDIR/bin fallback covers being invoked through a path with no directory
  # part (bare `ops-task.sh` off PATH).
  case "${BASH_SOURCE[0]}" in
    */*) _tdir="${BASH_SOURCE[0]%/*}" ;;
    *)   _tdir="$OPDIR/bin" ;;
  esac
  VERDICT_CLI="$_tdir/ops-verdict.sh"
  [ -f "$VERDICT_CLI" ] || VERDICT_CLI="$OPDIR/bin/ops-verdict.sh"
  [ -f "$VERDICT_CLI" ] || die "cannot find ops-verdict.sh next to this script or in $OPDIR/bin — the exemption's ledger write is delegated to it (run ops-init.sh)"

  # LEDGER FIRST, MARKER SECOND. The failure directions are not symmetric: a
  # marker without its row is an ARMED session whose bypass was never recorded —
  # the audit hole this whole feature exists to close. A row without its marker
  # is a recorded debt and a still-gated session: annoying, honest, and the
  # operator simply re-runs. Take the safe order.
  # The delegate's own stdout is suppressed (its stderr is not): two success
  # lines for one command reads as two things having happened.
  bash "$VERDICT_CLI" --exempt-mark "$EXEMPT" --owner "$OWNER" >/dev/null \
    || die "delegated ledger write failed — no exemption granted (nothing was marked)"

  # The GRANTED marker, distinct from the DERIVED .armed/<owner>: an exempt
  # session by definition has nothing in pending/, so ops-verdict.sh's
  # recompute (which derives armed-ness from pending/) would delete a plain
  # marker the moment any verdict ran. Two marker kinds, two lifetimes — the
  # recompute never touches this one.
  #
  # Session-scoped by construction: a /clear rotates the session id, so the
  # marker becomes unreachable on its own and the deviation gate has already
  # collected the presentation debt. Nothing sweeps it.
  #
  # Failures DIE here rather than degrading (the opposite of arm_marker below):
  # the row is already written, so a swallowed failure would leave the operator
  # told they are exempt while still gated, with the debt already recorded.
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

# Create the sentinel ATOMICALLY. A test-then-write (`[ -e ] || > file`) is a
# TOCTOU: two sessions opening the same id both pass the check, both truncate,
# and the later write silently replaces the earlier session's ownership —
# breaking the documented no-takeover guarantee. Measured at 155/200 trials
# before this fix (found by Codex review).
#
# `set -C` makes `>` use O_EXCL: exactly one opener wins, the loser sees EEXIST
# and reports the task as already open. No lock needed — the kernel arbitrates.
set -C
# The redirection failure (EEXIST on a real sentinel, EISDIR on a directory,
# ENOENT through a dangling symlink) is reported by bash on fd 2 OUTSIDE the
# scope of any `2>/dev/null` on the compound body — the "a raw bash error as
# operator guidance" landmine (review-pilot finding #3). Redirect the whole
# test's fd 2 to silence bash's message; we emit our own precise one below.
if { { if [ -n "$OWNER" ]; then printf 'session_id: %s\n' "$OWNER"; fi
     printf 'cwd: %s\n' "$PWD"
     printf 'opened_at: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
   } > "$OPDIR/pending/$ID"
   } 2>/dev/null; then
  set +C
else
  _rc=$?; set +C
  # The redirection failed. O_EXCL makes this EEXIST when a real sentinel
  # already exists — the legit "already open" path. But the SAME redirection
  # fails for a non-regular entry (a directory, a dangling symlink) or a
  # permission/ENOSPC error, and conflating those with EEXIST is a fail-OPEN
  # in the gate: we'd print "already open, ownership unchanged" and exit 0,
  # while the Stop hook's `-f` guard refuses to count a non-regular entry as a
  # task — so the operator is told a task is tracked and the session stops
  # unblocked. Two components disagreeing about what a task is, silently off
  # (P1, found by the review-panel pilot 2026-07-29). Distinguish: only a
  # pre-existing REGULAR FILE is a legit already-open; anything else is a
  # fault we refuse rather than misreport. The `-L` test is load-bearing:
  # `-f` FOLLOWS symlinks, so a symlink→regular file reads as "already open"
  # (exit 0) without it — telling the operator a planted entry is live tracked
  # work. (NOT a data-overwrite hazard: mv/rename(2) replaces a destination
  # symlink itself, never its target — measured 2026-08-04. The real exposure
  # is read-side laundering: a reader that follows the link treats a file our
  # CLIs never wrote as a sentinel; every reader now carries this same -L
  # rejection.) A symlink is never a sentinel we wrote.
  if [ -f "$OPDIR/pending/$ID" ] && [ ! -L "$OPDIR/pending/$ID" ]; then
    echo "already open: $ID (ownership unchanged — use ops-adopt.sh to re-stamp)"
    exit 0
  else
    die "cannot create sentinel $OPDIR/pending/$ID (a non-regular entry, symlink, or unwritable path already exists there) — remove it or choose another id"
  fi
fi

# --- arm marker (G2.1) -------------------------------------------------------
# The PreToolUse arm gate (ops-armgate-hook.sh) asks a CHEAP question — "is
# .operator/.armed/<sid> there?" — so it never needs a fourth copy of the
# sentinel-ownership parser. The expensive question is answered here, by the
# writer that already knows the answer.
#
# ORDER IS DELIBERATE: the sentinel exists by the time we get here. The reverse
# order opens a window where the marker outlives no sentinel — harmless
# (stale-true degrades to today's ungated behaviour) but the correct order is
# free, so take it.
#
# Only with --owner: an unowned task has no session to arm, and a marker keyed
# by nothing would arm nobody.
#
# NO LOCK, deliberately: this script takes none (the O_EXCL create above is
# arbitrated by the kernel), and adding one here would copy the LOCK BLOCK to a
# third file for the sake of a mkdir. A concurrent ops-verdict.sh recompute is
# safe against this by construction — it removes the marker BEFORE rescanning
# pending/, so a sentinel created before its rescan is seen, and one created
# after (like this one) brings its own marker. Failures are swallowed: a marker
# we could not write degrades to stale-false, which the gate's deny message and
# the next verdict's recompute both repair, and dying here would make an
# unwritable .operator/ break task-opening itself.
arm_marker() { # arm_marker <session-id>
  mkdir -p "$OPDIR/.armed" 2>/dev/null && : > "$OPDIR/.armed/$1"
}

if [ -n "$OWNER" ]; then
  arm_marker "$OWNER" || true
  echo "opened $ID owned by $OWNER (sentinel $OPDIR/pending/$ID — cleared only by ops-verdict.sh)"
else
  echo "opened $ID UNOWNED — blocks every session's Stop; pass --owner <sid> to scope it"
fi
