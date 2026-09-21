#!/usr/bin/env bash
# ops-spec.sh — the spec stage's artifact (#155).
#
# The cycle went brainstorm -> ??? -> plan: the only thing carrying a design
# from divergence into planning was prose the operator retyped, with no file,
# no provenance, no source stamp and no ledger row, so a compaction lost it and
# nothing noticed. This CLI is that missing artifact, and nothing more.
#
#   ops-spec.sh --new <slug>          scaffold .operator/specs/<slug>.md
#   ops-spec.sh --check <slug>        validate the skeleton; write nothing
#   ops-spec.sh --approve <slug> --owner <sid>
#                                     stamp APPROVED @<source-state>, log
#                                     SPEC-APPROVED, emit the BAR block
#
# APPROVE IS THE ONLY WRITER to a spec's Status line, for ops-verdict.sh's
# reason: one writer, one place to get the ordering right.
set -eu

OPDIR=".operator"
# The lock block below resolves this; ops-verdict.sh and ops-adopt.sh define it
# at the same point, before the block that uses it.
LOCKDIR="$OPDIR/.lock"

die() { echo "ops-spec: $1" >&2; exit 2; }

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

# The slug becomes a FILENAME, so it takes the same reject set the sentinel
# names take. Kept in step with ops-task.sh/ops-verdict.sh/ops-adopt.sh's
# check_bare_name by check_guard_parity: a name those writers refuse is a name
# no reader of ours can address, and a spec nobody can address is worse than
# no spec, because `--check` reports on the one it did find.
check_bare_name() { # check_bare_name <label> <value>
  case "$2" in
    */*) die "$1 must be a bare name (no '/')" ;;
    .*) die "$1 must not start with '.' — a dotfile spec is invisible to the specs/ glob" ;;
    *"|"* | *"$NL"*) die "$1 must not contain '|' or newlines" ;;
    *$'\r'*) die "$1 must not contain a carriage return — the ledger row it produces is a 4-cell line and a CR breaks the cell it lands in" ;;
    *__*) die "$1 must not contain '__' (it separates owner from task in the sentinel name, and a spec slug becomes a task id)" ;;
  esac
}

check_owner_name() { # check_owner_name <value>
  check_bare_name "owner" "$1"
  case "$1" in
    *[[:space:]]*) die "owner must not contain whitespace — it could never match a real session id" ;;
    *'$'* | *'`'* | *"'"* | *'"'* | *\\*) die "owner must not contain shell metacharacters" ;;
  esac
}

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

# THE LEDGER LOCK, byte-identical with ops-verdict.sh and ops-adopt.sh
# (check_lock_parity holds all three). --approve appends to VERDICTS.md AND
# DECISIONS.md, which are exactly the files ops-verdict.sh serialises: without
# this, a concurrent verdict row can land in the MIDDLE of the BAR block (six
# separate writes in one group), and a concurrent --mark-handoff can interleave
# with the SPEC-APPROVED line. A third writer to a locked file that does not
# take the lock is not a smaller risk than no lock at all — it is the case the
# lock cannot defend against.
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
_lock_budget_die() { echo "ops-spec: $1 is not a positive integer (got '$2') — refusing; see LOCK_SPINS/LOCK_LIVE_SPINS/RECLAIM_WAIT" >&2; exit 2; }
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
      echo "ops-spec: warning — fallback lock $FALLBACK_DIR held by another degraded writer for >$((FALLBACK_SPINS / 10))s; proceeding without it" >&2
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

# Reached only via the acquire paths' traps (nine sites: the fallback acquire's
# three, lock_acquire's three, and the reconcile path's three) — the linter
# cannot follow a trap. TWO codes for the one fact, because shellcheck says it
# twice: SC2317 (0.10, "command appears unreachable") and SC2329 (added in
# 0.11, "this function is never invoked"). CI pins the v0.10.0 image, so only
# the first has ever fired there; without the second the day someone bumps that
# pin `validate` goes red on this line with no code change (#160).
# shellcheck disable=SC2317,SC2329
fallback_release() {
  [ "${FALLBACK_HELD:-0}" = "1" ] || return 0
  FALLBACK_HELD=0
  # Displacement guard: a reclaimed fallback is another holder's dir.
  fallback_holder_read
  if [ -n "$FALLBACK_MINE" ] && [ -n "$FALLBACK_REC" ] && [ "$FALLBACK_REC" != "$FALLBACK_MINE" ]; then
    echo "ops-spec: warning — $FALLBACK_DIR was reclaimed while this process held it; not releasing another holder's fallback lock" >&2
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
      echo "ops-spec: could not acquire $LOCKDIR after $((LOCK_MAX_SPINS / 10))s — refusing to spin further." >&2
      if [ ! -d "${LOCKDIR%/*}" ]; then
        # Name the cause when it is knowable (#68's exact shape).
        echo "ops-spec: ${LOCKDIR%/*} does not exist — the ledger directory was removed while this run was in flight." >&2
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
        echo "ops-spec: warning — lock $LOCKDIR held by a LIVE process for >$((LOCK_LIVE_SPINS / 10))s; proceeding unlocked rather than stealing a running writer's lock" >&2
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
          echo "ops-spec: warning — lock $LOCKDIR was held by process ${LOCK_HOLDER_REC##* }, which is gone; reclaiming it" >&2
        else
          echo "ops-spec: warning — lock $LOCKDIR held >$((LOCK_SPINS / 10))s and its holder cannot be identified; assuming a crashed writer and reclaiming it" >&2
        fi
        rm -f "$LOCKDIR/holder" 2>/dev/null || true
        rmdir "$LOCKDIR" 2>/dev/null || true
        if mkdir "$LOCKDIR" 2>/dev/null; then
          rmdir "$LOCKDIR.reclaim" 2>/dev/null || true
          break                       # we now hold the lock
        fi
        rmdir "$LOCKDIR.reclaim" 2>/dev/null || true
        echo "ops-spec: warning — could not reclaim $LOCKDIR; proceeding unlocked" >&2
        fallback_acquire      # same reason as the live-holder give-up above
        return 0
      fi
      # A LIVE reclaimer needs ms — short waits; then the claim is dead.
      defers=$((defers + 1))
      if [ "$defers" -gt "$LOCK_DEFERS_MAX" ]; then
        echo "ops-spec: warning — reclaim claim $LOCKDIR.reclaim abandoned; clearing it" >&2
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
    echo "ops-spec: warning — $LOCKDIR was reclaimed while this process held it; not releasing another holder's lock" >&2
    return 0
  fi
  rm -f "$LOCKDIR/holder" 2>/dev/null || true
  rmdir "$LOCKDIR" 2>/dev/null || true
}
# <<< LOCK BLOCK

SPECDIR="$OPDIR/specs"
DECISIONS="$OPDIR/DECISIONS.md"
VERDICTS="$OPDIR/VERDICTS.md"

# The skeleton's section order, ONE declaration, read by both --new and
# --check. Two copies would drift into a scaffold its own checker refuses.
SPEC_SECTIONS="North star|Done criteria|In scope|Out of scope|Open questions|Constraints"

spec_path() { printf '%s/%s.md' "$SPECDIR" "$1"; }

# BOUNDED like every other reader here: a spec is a project file, and an
# unbounded read of one is the class this repo bounds everywhere else.
SPEC_MAX_BYTES=262144
spec_read_guard() { # spec_read_guard <path>
  [ -f "$1" ] || die "no spec at $1 — run: ops-spec.sh --new ${1##*/}"
  [ ! -L "$1" ] || die "$1 is a symlink — refusing to read a spec through one"
  _sz="$(wc -c < "$1" 2>/dev/null || echo 999999999)"
  [ "$_sz" -le "$SPEC_MAX_BYTES" ] || die "$1 is larger than $SPEC_MAX_BYTES bytes — that is not a spec, and reading it unbounded is how a reader becomes a denial of service"
}

usage() {
  cat >&2 <<'USAGE'
usage: ops-spec.sh --new <slug>
       ops-spec.sh --check <slug>
       ops-spec.sh --approve <slug> --owner <session-id>
USAGE
  exit 2
}

MODE=""; SLUG=""; OWNER=""
while [ $# -gt 0 ]; do
  case "$1" in
    --new|--check|--approve)
      [ -z "$MODE" ] || die "pick one of --new / --check / --approve"
      MODE="${1#--}"; shift
      [ $# -ge 1 ] || die "$MODE requires a slug"
      SLUG="$1"; shift ;;
    --owner) shift; [ $# -ge 1 ] || die "--owner requires a session id"; OWNER="$1"; shift ;;
    -h|--help) usage ;;
    *) die "unknown argument '$1'" ;;
  esac
done
[ -n "$MODE" ] || usage
check_bare_name "slug" "$SLUG"
[ -d "$OPDIR" ] || die "missing $OPDIR — run ops-init.sh first"

SPEC="$(spec_path "$SLUG")"

# The approve-only guards run BEFORE the checker, so a refusal that has nothing
# to do with the spec's content does not first print a verdict on its content.
# Reading "passes --check" and then "--owner is required" reads as two results
# where there is one refusal.
if [ "$MODE" = "approve" ]; then
  [ -n "$OWNER" ] || die "--approve requires --owner <session-id> (SessionStart printed yours)"
  check_owner_name "$OWNER"
  if [ -f "$SPEC" ] && grep -q '^Status: APPROVED' "$SPEC"; then
    die "$SPEC is already APPROVED — a second approval would append a second BAR block for the same spec"
  fi
fi

case "$MODE" in
new)
  mkdir -p "$SPECDIR" 2>/dev/null || die "could not create $SPECDIR"
  # O_EXCL, ops-task.sh's discipline: a test-then-write is a TOCTOU, and `>`
  # over an existing spec would destroy work the operator is mid-way through.
  if ! (set -C; : > "$SPEC") 2>/dev/null; then
    [ -f "$SPEC" ] && die "$SPEC already exists — edit it, or pick another slug"
    die "could not create $SPEC"
  fi
  cat > "$SPEC" <<SKEL
# SPEC — $SLUG

Slug: $SLUG
Status: DRAFT
Provenance: <what produced this — a brainstorm run, an interview, direct authorship>

## North star

<one sentence naming what must be true when this is done>
Missed if: <the falsifying condition>

## Done criteria

| # | Criterion | Command | Expected output |
|---|---|---|---|
| 1 | <what must hold> | <the command that shows it> | <what it prints> |

## In scope

## Out of scope

## Open questions

| Question | Resolution | Decided by |
|---|---|---|

## Constraints

SKEL
  echo "created $SPEC (DRAFT)"
  echo "next: fill it in, then ops-spec.sh --check $SLUG"
  ;;

check|approve)
  spec_read_guard "$SPEC"
  _problems=0
  _say() { echo "ops-spec: $1" >&2; _problems=$((_problems + 1)); }

  _IFS_SAVE="$IFS"; IFS='|'
  for _sec in $SPEC_SECTIONS; do
    grep -qxF "## $_sec" "$SPEC" || _say "missing section '## $_sec'"
  done
  IFS="$_IFS_SAVE"

  # The north star is the sentence BOTH the BAR block and plan.js read, and
  # the `Missed if:` clause is what plan.js refuses without. Checking it here
  # is the whole point of having one file: the two consumers stop disagreeing.
  grep -qi '^Missed if:' "$SPEC" || _say "the north star has no 'Missed if:' clause — the plan workflow reads it without a fallback and refuses without it"

  # A done criterion with no command is one nobody outside this session can
  # reproduce (#25, arriving one stage earlier). The skeleton's placeholder row
  # does not count: a spec approved with the template still in it has no
  # criteria at all.
  _rows="$(awk '/^## Done criteria/{f=1;next} /^## /{f=0} f&&/^\| *[0-9]/{print}' "$SPEC" 2>/dev/null | grep -vc '<the command that shows it>' || true)"
  [ "${_rows:-0}" -ge 1 ] || _say "no done criterion carries a real command — the skeleton's placeholder row is not a criterion"

  # An unanswered question is the interview skipped. The bundle orders them by
  # blast radius precisely so the first one is the one that reshapes the design.
  _open="$(awk '/^## Open questions/{f=1;next} /^## /{f=0} f&&/^\|/{print}' "$SPEC" 2>/dev/null \
           | grep -v '^| *Question' | grep -v '^|---' | grep -c '| *|' || true)"
  [ "${_open:-0}" -eq 0 ] || _say "$_open open question(s) have an empty Resolution cell — approving with one unanswered is the interview skipped"

  if [ "$_problems" -gt 0 ]; then
    echo "ops-spec: $SPEC is NOT ready ($_problems problem(s) above)" >&2
    exit 1
  fi
  echo "ops-spec: $SPEC passes --check"
  [ "$MODE" = "approve" ] || exit 0
  ;;
esac

[ "$MODE" = "approve" ] || exit 0

# --- approve ---------------------------------------------------------------
# (--owner and the already-approved refusal ran before the checker, above.)
# RESOLVE THE STAMP BEFORE THE LOCK, ops-verdict.sh's ordering (PLAYBOOK): git
# can be slow, and holding a lock across it widens the window every other
# writer waits in.
STAMP="$(source_stamp)"
TODAY="$(date +%F)"

lock_acquire

# ORDER, and it is ops-verdict.sh's (#14) applied here: the DECISIONS line
# BEFORE the ledger's BAR block, and the spec's own Status LAST. A crash
# between them leaves a record that the approval was attempted with the spec
# still DRAFT — which re-runs cleanly. The reverse order leaves an APPROVED
# spec no ledger knows about, and nothing would ever retry it.
printf '%s | %s | SPEC-APPROVED | spec %s approved @%s | the plan gate reads this file; see %s\n' \
  "$TODAY" "$SLUG" "$SLUG" "$STAMP" "$SPEC" >> "$DECISIONS" \
  || die "could not append to $DECISIONS"

{
  printf '\n## BAR — %s (spec %s @%s)\n\n' "$SLUG" "$SLUG" "$STAMP"
  printf 'North star: '
  awk '/^## North star/{f=1;next} /^## /{f=0} f&&NF{print; exit}' "$SPEC"
  awk '/^## North star/{f=1;next} /^## /{f=0} f&&/^[Mm]issed if:/{print; exit}' "$SPEC"
  printf '\nDone criteria (from %s):\n\n' "$SPEC"
  awk '/^## Done criteria/{f=1;next} /^## /{f=0} f&&/^\|/{print}' "$SPEC"
  printf '\nCaps: the charter table (identical-rejection x2, same-target-rework x2, neighbor-regressing x2).\n'
} >> "$VERDICTS" || die "could not append the BAR block to $VERDICTS"

# The Status line last, and rewritten through a temp + same-dir mv for the
# .gitignore writers' reason: an in-place edit that dies leaves a spec that is
# neither DRAFT nor APPROVED.
_tmp="$SPEC.tmp.$$"
if sed "s|^Status: DRAFT\$|Status: APPROVED @$STAMP|" "$SPEC" > "$_tmp" 2>/dev/null \
   && grep -q '^Status: APPROVED' "$_tmp" \
   && mv -f "$_tmp" "$SPEC" 2>/dev/null; then
  :
else
  rm -f "$_tmp" 2>/dev/null
  die "could not stamp Status: APPROVED on $SPEC — the DECISIONS line and the BAR block ARE written, so re-run --approve after fixing the file (it is idempotent only once the Status line lands)"
fi

lock_release

echo "approved $SPEC @$STAMP"
echo "  logged SPEC-APPROVED to $DECISIONS"
echo "  appended the BAR block to $VERDICTS"
echo "next: /cc-operator:plan $SLUG"
