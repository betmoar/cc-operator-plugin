#!/usr/bin/env bash
# ops-stop-hook.sh — Stop-hook completion gate (P3/D4 layer 2).
#
# Contract (exit codes are the interface — Claude Code reads them):
#   exit 0  — allow the stop. Cases: no .operator/ reachable (no-op guard);
#             .operator/pending/ empty; stop_hook_active true WITH this hook's
#             own .stopguard marker (our continuation — the loop guard; a
#             FOREIGN continuation does NOT exit 0, #116 — EXCEPT on a project
#             that cannot carry a marker at all, which stands down as pre-#116
#             because a session that cannot end is the worse failure, #123 C);
#             no JSON parser available (fail-open — a broken hook must never
#             brick a session).
#   exit 2  — block the stop. This session OWNS a pending sentinel (or one is
#             unowned), or unpresented decisions exist; stderr names those ids
#             and the command to clear them (Claude Code feeds stderr back as
#             guidance). Every exit 2 stamps .operator/.stopguard/<sid> first
#             (#116 — see the loop guard below).
#
# Ownership: the sentinel FILENAME carries the owner — `pending/<sid>__<task>`
# is owned (ops-task.sh --owner stamps it by naming it), `pending/<task>` is
# unowned. Only sentinels owned by THIS session — or owned by nobody — block.
# Foreign ones are reported on stderr and allowed, so one session can no longer
# be trapped by another's open task, nor close a row it did not perform. An
# UNOWNED sentinel fails CLOSED (pre-0.4 sentinels are empty files, and an
# unowned sentinel is a real open task) — deliberately the opposite default
# from the no-parser fail-open below, where a broken plugin must not brick a
# session.
#
# The partition rule itself lives in scripts/lib/partition.sh, sourced below —
# the statusline renders the SAME functions, so the bar cannot describe a gate
# other than the one that runs.
#
# Reads the Stop payload as JSON on stdin ONCE. Sentinel check runs against the
# cwd carried IN the payload, never the script's own cwd. External dependencies
# are limited to one JSON parser (jq preferred, python3 fallback); stdin read,
# pending enumeration, and owner parsing use bash builtins only (no grep/sed),
# so PATH loss cannot brick it.
set -u

# --- read the whole payload from stdin (builtin; no external command) --------
# Slurp everything up to a NUL that never comes: captures the full payload
# whether or not it ends in a newline (command substitution strips trailing
# newlines, which a line-by-line `read` loop would then drop entirely).
input=""
IFS= read -r -d '' input || true

# --- pick a JSON parser once; fail open if none ------------------------------
if command -v jq >/dev/null 2>&1; then
  PARSER=jq
elif command -v python3 >/dev/null 2>&1; then
  PARSER=python3
else
  echo "operator: warning — no jq or python3 on PATH; Stop hook failing open (exit 0)" >&2
  exit 0
fi

json_get() { # json_get <field> → value on stdout ("" if absent)
  case "$PARSER" in
    jq)
      printf '%s' "$input" | jq -r --arg k "$1" '.[$k] // empty' 2>/dev/null
      ;;
    python3)
      printf '%s' "$input" | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
k = sys.argv[1]
v = d.get(k, "")
if isinstance(v, bool):
    print("true" if v else "false")
elif v is None:
    print("")
else:
    print(v)
' "$1" 2>/dev/null
      ;;
  esac
}

cwd="$(json_get cwd)"
active="$(json_get stop_hook_active)"
session="$(json_get session_id)"

# --- no-op guard: not an operator project → stay out of the way --------------
# An empty cwd has two very different causes: a payload that legitimately has
# no cwd (fine, stay out of the way) and a payload that FAILED TO PARSE
# (json_get swallows parser errors, so every field comes back empty). Both exit
# 0, but the second is a fail-open we should not perform silently. Distinguish:
# a payload with content but no parseable cwd is a corrupt payload.
if [ -z "$cwd" ]; then
  if [ -n "$input" ]; then
    echo "operator: warning — Stop payload present but unparseable (no cwd); hook failing open (exit 0)" >&2
  fi
  exit 0
fi
# Resolve the project by WALKING UP from the payload cwd to the nearest
# ancestor holding .operator/ — the way git finds its own root. Why not just
# "$cwd/.operator": ops-task.sh refuses to open a task anywhere but the
# directory holding .operator/, so an exact-match lookup one directory deeper
# finds nothing and ALLOWS the stop with tasks still open — the whole gate,
# silently off (audit F01). Bounded twice: at a .git boundary (a nested repo is
# its own project) and at the filesystem root; `cd -P` resolves symlinks.
opdir=""
walk="$(cd -P "$cwd" 2>/dev/null && pwd)" || walk=""
while [ -n "$walk" ]; do
  if [ -d "$walk/.operator" ]; then opdir="$walk/.operator"; break; fi
  [ -e "$walk/.git" ] && break
  [ "$walk" = "/" ] && break
  walk="${walk%/*}"; [ -n "$walk" ] || walk="/"
done
[ -n "$opdir" ] || exit 0

# --- loop guard: never re-block MY OWN block, never disarm for anyone else's --
# stop_hook_active is a HARNESS field every Stop hook receives, not a private
# one (#116): it is true on the Stop AFTER any hook-forced continuation — ours,
# but equally cc-repete's re-inject or any sibling's block. The old guard
# `[ "$active" = "true" ] && exit 0` could not tell those apart, so an active
# cc-repete loop (which blocks every Stop while it runs) disarmed this gate
# for the whole loop window after its first turn — a fail-OPEN silent disarm,
# the worst class in docs/LANDMINES.md.
#
# The marker closes the ambiguity: we stamp .operator/.stopguard/<sid> when WE
# block, clear it when WE allow. "Active AND my marker" = the continuation of
# my own block → stand down (the guard's original purpose: never re-block the
# stop I myself forced, or the operator cannot escape the loop). "Active and
# NO marker" = someone else's continuation → run the gate normally.
#
# STANDING DOWN SPENDS THE BLOCK (#123 A): the own-continuation branch clears
# the marker too. The first cut kept it ("at worst one stand-down"), but the
# reachable chain is exactly #116's: we block → we stand down (marker kept) →
# cc-repete blocks that same Stop → the NEXT Stop still carries
# stop_hook_active true AND our stale marker → a foreign continuation reads
# as ours and the gate is off for the rest of the loop window. One stand-down
# per block, spent when taken.
#
# READER TYPE TEST (#123 B): the marker is a NON-SYMLINK regular file on the
# read side too — `[ -f ]` follows a link, so a symlink at the marker path
# pointing at any regular file read as "ours" and disarmed the guard (the
# write side already refused links; the read side was the sixth `-L before -f`
# site the pending/<id> convention names).
#
# UNMARKABLE PROJECT (#123 C): if the marker cannot be written (a non-dir at
# .stopguard/, an unwritable .operator/), every ordinary stop blocks and every
# continuation ALSO blocks — a session that cannot end, which this file's own
# header forbids ("a broken hook must never brick a session"). Failing toward
# blocking once is defensible; failing toward blocking forever is not. The
# polarity chosen: a project that cannot carry the marker is PRE-#116 for
# loop-guard purposes — active=true stands down unconditionally there,
# trading the #116 disarm back for a session that CAN end. The block itself
# still fires on the ordinary stop (the gate is not disabled), and the write
# failure is SAID on stderr (a silent flag is the two-claims rule).
_stopguard_path() { # prints "" (not a project / no session) or the marker path.
  # CONTRACT: callers consume STDOUT and test [ -n ] — the EXIT status is
  # always 0 and carries no meaning (a prior comment implied otherwise).
  [ -n "${opdir:-}" ] || return 0
  [ -n "$session" ] || return 0
  printf '%s/.stopguard/%s' "$opdir" "$session"
}

stopguard_mark_blocked() { # record that THIS hook blocked (advisory, builtin)
  _sgp="$(_stopguard_path)"
  if [ -z "$_sgp" ]; then
    # No session id in the payload: the marker cannot be ADDRESSED at all, so
    # this block can never be spent by a later continuation. Every subsequent
    # stop_hook_active fire falls to the foreign-continuation branch, re-runs
    # the gate and blocks again (measured on this branch: rc 2, 2, 2).
    #
    # That polarity is deliberate — stopguard_can_mark deliberately does NOT
    # call this the C case, because standing down for every session-less
    # payload is the #116 disarm through the back door — but it must not be
    # SILENT. Returning 0 here (nothing to mark is not a failed write) while
    # saying nothing was the last unreported state in this mechanism: the
    # operator saw a block repeat with no account of why it could not be
    # spent. Two claims, both made.
    echo "operator: warning — this Stop payload carries no session id, so no .stopguard marker can be written and this block can never be spent. Every continuation will re-run the gate and block again until the pending work is cleared or deferred; there is no loop-guard escape for a session-less payload (#123/#124)." >&2
    return 0
  fi
  mkdir -p "${_sgp%/*}" 2>/dev/null || return 1
  # set -C (O_EXCL) so a planted symlink at the marker path is refused rather
  # than followed — the same discipline as the autobar sentinel write above.
  ( set -C; : > "$_sgp" ) 2>/dev/null
  # A pre-existing regular file is our own marker from the previous block:
  # presence is the whole state, so a refused overwrite of our own marker is
  # success, and a symlink at the path is failure (the marker would lie).
  [ -f "$_sgp" ] && [ ! -L "$_sgp" ] && return 0
  # Distinguish "cannot mark" (return 1 — the C case) from "nothing to mark"
  # (the empty path above returns 0): a failed write is REPORTED, never
  # silently treated as success.
  return 1
}

stopguard_clear() { # we allowed the stop — my block, if any, is over
  _sgp="$(_stopguard_path)"
  [ -n "$_sgp" ] || return 0
  rm -f -- "$_sgp" 2>/dev/null
}

# The reader's type test, one helper used by BOTH guard arms (#123 B).
stopguard_is_mine() { # → 0 if a regular non-symlink marker is present
  _sgp="$(_stopguard_path)"
  [ -n "$_sgp" ] || return 1
  [ -f "$_sgp" ] && [ ! -L "$_sgp" ]
}

# C's polarity, as code: a project that cannot CARRY a marker at all (the
# .stopguard path is a non-directory, or .operator/ is unwritable) is pre-#116
# for loop-guard purposes — active=true stands down, because the alternative
# is a continuation that blocks forever on a marker it can never spend.
# Distinct from B's symlink case: a LINK at the marker path is tampering
# (reads as not-mine, gate RUNS); an ABSENT marker DIRECTORY is environment.
stopguard_can_mark() { # → 0 if the marker's parent dir exists AND is writable (or creatable)
  # Empty PATH (no session id in the payload): NOT the C case. A no-session
  # payload can never have owned a marker, so there is nothing to spend and
  # nothing to escape from — the foreign-continuation branch below is the
  # honest reading (rc 2 with the notice). Treating it as "unmarkable" would
  # stand the guard down for every payload that lacks a session id, which is
  # the #116 disarm through the back door (measured: case 4d went 2 -> 0).
  _sgp="$(_stopguard_path)"
  [ -n "$_sgp" ] || return 0
  # WRITABILITY, not bare existence (PR #124 review): a read-only .stopguard/
  # dir made the polarity decision on a false premise — can_mark said
  # "markable", the later write failed, and the guard had already chosen
  # "gate runs" for this continuation on evidence that was about to be
  # contradicted.
  #
  # #21 DISCIPLINE — this `[ -w ]` is a BEST-EFFORT HALF, inert for uid 0
  # (root bypasses mode bits; the validator's permission-test allowlist is
  # raised for exactly this one with that reasoning). The uid-invariant half
  # of the guard is the TYPE test in the same branch (`-d`, holds on every
  # uid) plus the warned write failure downstream: on root, a read-only dir
  # reads markable, the marker write then fails, and the call site SAYS so on
  # stderr — the operator learns the state one event later instead of at
  # decision time. That is the documented trade, not an oversight.
  if [ -d "${_sgp%/*}" ]; then
    [ -w "${_sgp%/*}" ]
    return $?
  fi
  # A dir we just created via mkdir is writable by construction (we made it);
  # a failed mkdir already returns 1 here.
  mkdir -p "${_sgp%/*}" 2>/dev/null && return 0
  return 1
}

if [ "$active" = "true" ] && ! stopguard_can_mark; then
  # The C escape: unmarkable project, pre-#116 polarity, said on stderr.
  echo "operator: stop_hook_active is true and this project cannot carry a .stopguard marker ($opdir/.stopguard is not a directory / not creatable) — standing down as pre-#116 (#123): a session that can never end is the worse failure. The ordinary-stop gate below is unaffected." >&2
  exit 0
fi
if [ "$active" = "true" ] && ! stopguard_is_mine; then
  # Someone else's continuation. Say so on stderr (it is guidance, and the
  # silence here was the #116 report's first confusion) and RUN the gate.
  echo "operator: stop_hook_active is true but no block of ours caused it (no .stopguard marker) — another hook's continuation does not suspend the evidence gate (#116); gate runs normally." >&2
elif [ "$active" = "true" ]; then
  # MY OWN continuation (I blocked last Stop, the harness re-fired with
  # stop_hook_active true, the operator is acting on my instruction). This is
  # the guard's original purpose: never re-block the stop I myself forced, or
  # the operator cannot escape the loop. Standing down SPENDS the block
  # (#123 A): clear now, or a later foreign continuation inherits the stale
  # marker and reads as ours. The clear's status is READ and a failure SAID
  # (#124 review): a silently-failed clear leaves exactly the stale marker the
  # NEXT foreign continuation misreads as ours — the #116 disarm back, with no
  # diagnostic trail. The stand-down itself still happens.
  stopguard_clear || echo "operator: warning — could not clear the .stopguard marker ($opdir/.stopguard/$session unwritable or not removable). The stop is still allowed, but a later continuation may misread the stale marker as ours (#123/#124)." >&2
  exit 0
fi
# stop_hook_active false (the ordinary stop): fall through to the gate.


case "${BASH_SOURCE[0]}" in
  */*) _libdir="${BASH_SOURCE[0]%/*}/lib" ;;
  *)   _libdir="lib" ;;
esac
# shellcheck source=/dev/null
# shellcheck disable=SC2154  # deviations_* are assigned by the sourced lib
. "$_libdir/partition.sh"
# partition.sh first — but NOT because autobar.sh calls into it. It did until
# e839490 deleted the suppression rule; today the two libs share no symbol. The
# order that matters is below: autobar_decide runs BEFORE scan_pending, so a
# sentinel armed here is read by the existing mine-pending branch in the same
# fire. Keeping a deleted dependency as the stated reason is how a comment
# starts describing a mechanism that no longer runs.
# shellcheck source=/dev/null
# shellcheck disable=SC2154  # autobar_* are assigned by the sourced lib
. "$_libdir/autobar.sh"

# --- auto-arm (#85): the charter's clause (1), enforced ----------------------
# Runs BEFORE the pending scan on purpose: a sentinel armed here is an ORDINARY
# owned sentinel, so the existing mine-pending branch below blocks on it with
# the message it already ships. No new blocking stage, no new message class, no
# new polarity for a partition.sh reader — the seam that already works.
#
# The write is inline rather than a call to ops-task.sh: this hook resolves
# through ${CLAUDE_PLUGIN_ROOT} and the CLI lives at .operator/bin/, which an
# older scaffold may not have. A gate that silently stops arming because a
# project skipped an upgrade is the #34 class.
autobar_decide "${opdir%/.operator}" "$opdir" "$session"
# shellcheck disable=SC2154  # assigned by the sourced lib/autobar.sh
if [ "$autobar_arm" = 1 ]; then
  _ab_sentinel="$opdir/pending/${session}__${AUTOBAR_TASK}"
  # Mark FIRST, arm second. The reverse order re-arms forever if the mark fails
  # (see autobar.sh): a sentinel with no marker is re-created at the next Stop
  # the instant the operator clears it. Better to skip an arm than to wedge.
  if autobar_mark_armed "$opdir" "$session"; then
    # set -C makes > use O_EXCL, the same discipline ops-task.sh's opener uses
    # and for the same two reasons. A test-then-write is a TOCTOU, and `[ ! -e ]`
    # is TRUE for a dangling symlink — so the plain `>` followed the link and
    # created its target OUTSIDE .operator/ (measured). autobar_mark_armed
    # already refuses a symlink; this writer, three lines away, did not.
    #
    # The write's exit status is now CHECKED. It was `|| true`, which swallowed
    # the one asymmetry the branching above exists to prevent: the marker is
    # already written, so autobar_already_armed reads this session as armed for
    # the rest of its life — the gate silently never fires again, RC 0, stderr
    # empty. Measured with .operator/pending replaced by a plain file, and it
    # survived repairing the directory. A failed sentinel write must roll the
    # marker back, or the failure is permanent instead of retried next Stop.
    _ab_ok=0
    if mkdir -p "$opdir/pending" 2>/dev/null; then
      ( set -C; : > "$_ab_sentinel" ) 2>/dev/null && _ab_ok=1
      # Already-open is success, not failure: O_EXCL refuses a pre-existing
      # regular file, and that is this session's own sentinel from an earlier
      # arm — the same reading ops-task.sh's else-branch takes.
      [ "$_ab_ok" = 1 ] || { [ -f "$_ab_sentinel" ] && [ ! -L "$_ab_sentinel" ] && _ab_ok=1; }
    fi
    if [ "$_ab_ok" = 0 ]; then
      rm -f "$opdir/.autobar/$session" 2>/dev/null
      echo "operator: warning — auto-arm could not write $_ab_sentinel (a non-regular entry, a planted symlink, or an unwritable .operator/pending). The session marker was rolled back, so the next Stop retries rather than leaving this session permanently unarmed." >&2
    fi
  else
    echo "operator: warning — auto-arm skipped, could not record the session marker under $opdir/.autobar/ (arming without it would re-block after every verdict)" >&2
  fi
fi

scan_pending "$opdir" "$session"
pending="$MINE_IDS"
foreign="$FOREIGN_DESC"

# Defined BEFORE its first use: bash resolves a function at call time, so a
# call above the definition expands to the empty string and the message ships
# a blank command — no error, just useless guidance.
# Single-quote a path for pasting into a shell. Builtin-only (no printf %q,
# which is bash-4 and renders `$'…'` forms a user cannot read back).
shq() { # shq <string> → '<string>' with embedded quotes escaped
  printf "'%s'" "${1//\'/\'\\\'\'}"
}

# Render an UNTRUSTED ledger row safe for stderr. The rows are hand-editable
# project data, and this hook's stderr is fed back to the model as guidance —
# so an embedded ESC, CR or backspace could repaint the very instruction it is
# attached to (a CR alone rewrites the "run … --mark-handoff" line). Replace
# every C0 byte and DEL with `?`: the row is an INDEX into DECISIONS.md, never
# the thing acted on, so losing exotic bytes costs nothing. `tr` is not used —
# a lost PATH must not disarm the sanitizer, and this hook is builtin-only
# everywhere else for the same reason.
sanitize_row() { # sanitize_row <row> → row with control bytes replaced
  local _s="$1" _out="" _c _i=0
  while [ "$_i" -lt "${#_s}" ]; do
    _c="${_s:$_i:1}"
    case "$_c" in
      [[:cntrl:]] | $'\177') _out="${_out}?" ;;
      *) _out="${_out}${_c}" ;;
    esac
    _i=$((_i + 1))
  done
  printf '%s' "$_out"
}

verdict_cmd_for() { # → the verdict CLI path that resolves from the project cwd
  # ops-init installs it at .operator/bin/; fall back to this hook's own
  # sibling (the plugin copy) for projects scaffolded by an older ops-init.
  #
  # ABSOLUTE, not `.operator/bin/...` (#94). The Bash tool's cwd persists across
  # calls, so a session sitting in a subdirectory when the hook fires followed
  # the relative path, got "No such file or directory" from both the CLI and a
  # `find .` for the ledger, and concluded the charter was never realized here —
  # a PRESENT gate misdiagnosed as absent, the exact inversion of its purpose.
  # $opdir is already absolute: it comes from `cd -P` on the payload cwd.
  #
  # SINGLE-QUOTED, because absolute means "long enough to contain a space".
  # `/work/my repo/.operator/bin/ops-verdict.sh` pasted bare runs `/work/my`,
  # so the relative→absolute fix would have traded one uncopyable command for
  # another. An embedded `'` is closed, escaped and reopened, the one form that
  # survives any path a filesystem permits.
  if [ -f "$opdir/bin/ops-verdict.sh" ]; then
    shq "$opdir/bin/ops-verdict.sh"
    return 0
  fi
  case "${BASH_SOURCE[0]}" in
    */*) script_dir="${BASH_SOURCE[0]%/*}" ;;
    *)   script_dir="." ;;                    # invoked bare: script is in cwd
  esac
  script_dir="$(cd "$script_dir" 2>/dev/null && pwd)" || script_dir=""
  [ -n "$script_dir" ] && shq "$script_dir/ops-verdict.sh"
}

# Foreign tasks stay VISIBLE — that visibility is what made the collision
# diagnosable in the field — but they never block.
if [ -n "$foreign" ]; then
  # The remedy goes IN-BAND. A sentinel whose owner crashed, was killed, or was
  # /clear'd mid-task sits here forever and nothing reaps it; before #85's
  # suppression was dropped it also darkened the auto-armer permanently. It no
  # longer does, so this is hygiene rather than a defect — but hygiene nobody
  # is told about is hygiene nobody performs.
  echo "operator: $FOREIGN_N pending verdict(s) owned by another session ($foreign) — not blocking. If an owner session is gone (crashed, killed, /clear'd mid-task) nothing reaps its sentinel: clear it with $(verdict_cmd_for) <id> --defer \"<reason>\" — no --owner needed, it warns and proceeds." >&2
fi

# --- deviation gate: unpresented decisions block Stop (stage 2) ---------------
# Either gate can block. A session_id of "" makes every DEVIATION unowned →
# every one blocks (pre-gate lines are real unpresented decisions), mirroring
# the unowned-sentinel default. The ABSENT-ledger polarity is deliberately
# OPPOSITE the sentinel default and both are right: an unowned sentinel fails
# CLOSED (a real open task), an absent DECISIONS.md has no task to enforce
# (fail OPEN — scaffold problem, not evidence of an unpresented decision).
# ABSENT, not merely missing-from-the-scan: a present-but-UNREADABLE ledger
# fails CLOSED, because the file exists and an unpresented decision may be in
# it (#83 — the lib's header claimed unreadable took the fail-open path; it
# never did, and the code was the correct half).
scan_deviations "$opdir/DECISIONS.md" "$session"


# MALFORMED sentinels (F118 / #99) get their own sentence and their own remedy.
# These are names no writer CLI could have produced — a second `__` yields a
# task id every guard refuses — so the verdict CLI cannot address them, and the
# old code folded them into the mine/foreign lists whose message names exactly
# that CLI. The operator was told to run a command that dies on its own guard.
#
# `rm -f` is the honest remedy, not a fallback: the file is the whole problem,
# nothing in the ledger refers to it, and it is what an operator ends up doing
# once they work out that nothing else clears it. Path is shq'd for the same
# reason verdict_cmd_for's is — absolute means long enough to contain a space.
# Blocking, matching the unowned default: our CLIs cannot write this shape.
#
# One element per path, straight from the lib's ARRAY. The first cut carried
# the paths as a "; "-joined string and split it here, so a project path that
# itself contained "; " was cut at the wrong place and BOTH halves were printed
# as `rm -f` targets — a destructive command aimed at a file that was not the
# sentinel (PR #104 review, measured). Quoting after a split cannot repair a
# split that already lost the boundary; the carrier has to be lossless.
# Guarded on the count: on bash 3.2 under `set -u`, `"${arr[@]}"` on an empty
# array is "unbound variable", and macOS ships 3.2.
if [ "$MALFORMED" -gt 0 ]; then
  echo "operator: $MALFORMED pending sentinel(s) with a MALFORMED name — a second '__' or an EMPTY task id (a name ending in '__') makes the task id unaddressable, so no ops-verdict.sh invocation can clear them (a task id containing '__', or an empty one, is refused by the CLI's own guard). No writer of ours produces this shape; it was planted or hand-made. Inspect, then remove:" >&2
  for _mfone in "${MALFORMED_LIST[@]}"; do
    echo "operator:   rm -f $(shq "$_mfone")" >&2
  done
fi

if [ -n "$pending" ] || [ "$MALFORMED" -gt 0 ]; then
  verdict_cmd="$(verdict_cmd_for)"
  # The auto-armed sentinel needs its own sentence, or the operator reads
  # "pending verdict: autobar" as a task it never opened and has no way to
  # learn what tripped it. Name the count and the threshold: an unexplained
  # block is the one a user resolves by removing the hook.
  # shellcheck disable=SC2154  # assigned by the sourced lib/autobar.sh
  if [ "$autobar_arm" = 1 ]; then
    echo "operator: auto-armed '$AUTOBAR_TASK' — $autobar_reason, and the charter requires a BAR block before multi-file work (ENGAGEMENT CONTRACT clause 1). Record the evidence, or close it honestly with --defer \"<reason>\"." >&2
    # CO-PRESENCE. The armer measures the TREE and cannot attribute the delta to
    # a session, so in a shared worktree this block can land on someone who
    # changed nothing. Say so in the same breath: an unexplained accusation
    # against an honest operator is what gets the hook deleted, and the whole
    # bet of dropping suppression is that this sentence is cheaper than a
    # permanent silent disarm.
    echo "operator: the delta is measured from the working TREE and cannot be attributed to a session — if another session is working in this worktree, these paths may not be yours; close with --defer \"another session's changes\" and it costs you one command." >&2
  fi
  # Guarded: with malformed-only entries there is no addressable id to name, and
  # printing "pending verdict(s): " with an empty list is the useless guidance
  # this whole branch exists to avoid.
  [ -n "$pending" ] && echo "operator: pending verdict(s): $pending — run $verdict_cmd <id> <criterion> <evidence> <PASS|FAIL>, or --defer \"<reason>\"" >&2
  # The mark's status is READ and the failure SAID (#123 C): the gate still
  # blocks either way, but without this line the operator cannot know why the
  # next continuation will block again — and on an unmarkable project the
  # loop-guard polarity below is what keeps the session endable at all.
  stopguard_mark_blocked || echo "operator: warning — could not write the .stopguard marker (a non-directory at $opdir/.stopguard, an unwritable .operator/, or a symlink at the marker path). The gate still blocked; on the next stop_hook_active continuation this project is treated as pre-#116 and stands down, because a session that can never end is the worse failure (#123)." >&2
  exit 2
fi

# No pending sentinels — but unpresented deviations still block. Name the
# clearing command (the verdict CLI's --mark-handoff).
# shellcheck disable=SC2154  # assigned by the sourced lib/partition.sh
if [ "$deviations_scan_failed" = 0 ] && [ "$deviations_unpresented" -gt 0 ]; then
  verdict_cmd="$(verdict_cmd_for)"
  echo "operator: $deviations_unpresented unpresented decision(s) in $opdir/DECISIONS.md — present them (/cc-operator:handoff or in your reply), then run $verdict_cmd --mark-handoff --owner <session-id>" >&2
  # NAME the rows (#93/#94). The count alone was unauditable: identifying which
  # rows it meant took reading partition.sh, so the cheapest correct response
  # was to mark without reading — the habit the gate exists to prevent. The
  # scanner already parsed them; it used to discard them.
  #
  # Capped at 10 and truncated to ~110 chars: stderr is fed back to the model as
  # guidance, and a 100-row ledger dumped into it buries the instruction above.
  # The full rows are in the file, which the line above now names absolutely.
  #
  # SANITIZE BEFORE MEASURING. The rows are hand-editable project data printed
  # into the channel that carries this hook's own instruction, so a control byte
  # could repaint it. Sanitizing first also keeps the 110 cap honest: a row of
  # escapes is short on screen and long in bytes, and truncating mid-escape is
  # its own hazard.
  if [ -n "$deviations_rows" ]; then
    _dn=0
    while IFS= read -r _drow; do
      [ -n "$_drow" ] || continue
      _drow="$(sanitize_row "$_drow")"
      _dn=$((_dn + 1))
      if [ "$_dn" -gt 10 ]; then
        echo "operator:   … and $((deviations_unpresented - 10)) more — read $opdir/DECISIONS.md" >&2
        break
      fi
      if [ "${#_drow}" -gt 110 ]; then
        echo "operator:   ${_drow:0:110}…" >&2
      else
        echo "operator:   $_drow" >&2
      fi
    done <<EOF
$deviations_rows
EOF
  fi
  # The mark's status is READ and the failure SAID (#123 C): the gate still
  # blocks either way, but without this line the operator cannot know why the
  # next continuation will block again — and on an unmarkable project the
  # loop-guard polarity below is what keeps the session endable at all.
  stopguard_mark_blocked || echo "operator: warning — could not write the .stopguard marker (a non-directory at $opdir/.stopguard, an unwritable .operator/, or a symlink at the marker path). The gate still blocked; on the next stop_hook_active continuation this project is treated as pre-#116 and stands down, because a session that can never end is the worse failure (#123)." >&2
  exit 2
fi

# Allowing the stop: my own block, if there was one, is over — clear the
# marker so a FUTURE hook-forced continuation (someone else's) is not mistaken
# for ours (#116). Ordering: clear only after every blocking branch has been
# passed, so the marker always reflects "this hook last blocked". Status
# read and failures said (#124 review) — the two-claims rule, same as the
# mark sites: a silent clear-failure leaves the stale marker the NEXT
# foreign continuation misreads as ours.
stopguard_clear || echo "operator: warning — could not clear the .stopguard marker; a later stop_hook_active continuation may misread the stale marker as ours (#123/#124)." >&2
exit 0
