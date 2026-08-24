#!/usr/bin/env bash
# ops-stop-hook.sh — Stop-hook completion gate (P3/D4 layer 2).
#
# Contract (exit codes are the interface — Claude Code reads them):
#   exit 0  — allow the stop. Cases: no .operator/ reachable (no-op guard);
#             .operator/pending/ empty; stop_hook_active true (loop guard);
#             no JSON parser available (fail-open — a broken hook must never
#             brick a session).
#   exit 2  — block the stop. This session OWNS a pending sentinel (or one is
#             unowned) and stop_hook_active is false; stderr names those ids and
#             the command to clear them (Claude Code feeds stderr back as
#             guidance).
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

# --- loop guard: never re-block an already-active stop -----------------------
[ "$active" = "true" ] && exit 0

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

# --- the partition rule, shared with the statusline ---------------------------
case "${BASH_SOURCE[0]}" in
  */*) _libdir="${BASH_SOURCE[0]%/*}/lib" ;;
  *)   _libdir="lib" ;;
esac
# shellcheck source=/dev/null
# shellcheck disable=SC2154  # deviations_* are assigned by the sourced lib
. "$_libdir/partition.sh"
# autobar.sh USES sentinel_owner_of_name, so partition.sh must be sourced first.
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
    if mkdir -p "$opdir/pending" 2>/dev/null && [ ! -e "$_ab_sentinel" ]; then
      : > "$_ab_sentinel" 2>/dev/null || true
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
verdict_cmd_for() { # → the verdict CLI path that resolves from the project cwd
  # ops-init installs it at .operator/bin/; fall back to this hook's own
  # sibling (the plugin copy) for projects scaffolded by an older ops-init.
  if [ -f "$opdir/bin/ops-verdict.sh" ]; then
    printf '.operator/bin/ops-verdict.sh'
    return 0
  fi
  case "${BASH_SOURCE[0]}" in
    */*) script_dir="${BASH_SOURCE[0]%/*}" ;;
    *)   script_dir="." ;;                    # invoked bare: script is in cwd
  esac
  script_dir="$(cd "$script_dir" 2>/dev/null && pwd)" || script_dir=""
  [ -n "$script_dir" ] && printf '%s' "$script_dir/ops-verdict.sh"
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
# the unowned-sentinel default. The absent-ledger polarity is deliberately
# OPPOSITE the sentinel default and both are right: an unowned sentinel fails
# CLOSED (a real open task), an absent DECISIONS.md has no task to enforce
# (fail OPEN — scaffold problem, not evidence of an unpresented decision).
scan_deviations "$opdir/DECISIONS.md" "$session"


if [ -n "$pending" ]; then
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
  echo "operator: pending verdict(s): $pending — run $verdict_cmd <id> <criterion> <evidence> <PASS|FAIL>, or --defer \"<reason>\"" >&2
  exit 2
fi

# No pending sentinels — but unpresented deviations still block. Name the
# clearing command (the verdict CLI's --mark-handoff).
# shellcheck disable=SC2154  # assigned by the sourced lib/partition.sh
if [ "$deviations_scan_failed" = 0 ] && [ "$deviations_unpresented" -gt 0 ]; then
  verdict_cmd="$(verdict_cmd_for)"
  echo "operator: $deviations_unpresented unpresented decision(s) in DECISIONS.md — present them (/cc-operator:handoff or in your reply), then run $verdict_cmd --mark-handoff --owner <session-id>" >&2
  exit 2
fi

exit 0
