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

scan_pending "$opdir" "$session"
pending="$MINE_IDS"
foreign="$FOREIGN_DESC"

# Foreign tasks stay VISIBLE — that visibility is what made the collision
# diagnosable in the field — but they never block.
if [ -n "$foreign" ]; then
  echo "operator: $FOREIGN_N pending verdict(s) owned by another session ($foreign) — not blocking." >&2
fi

# --- deviation gate: unpresented decisions block Stop (stage 2) ---------------
# Either gate can block. A session_id of "" makes every DEVIATION unowned →
# every one blocks (pre-gate lines are real unpresented decisions), mirroring
# the unowned-sentinel default. The absent-ledger polarity is deliberately
# OPPOSITE the sentinel default and both are right: an unowned sentinel fails
# CLOSED (a real open task), an absent DECISIONS.md has no task to enforce
# (fail OPEN — scaffold problem, not evidence of an unpresented decision).
scan_deviations "$opdir/DECISIONS.md" "$session"

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

if [ -n "$pending" ]; then
  verdict_cmd="$(verdict_cmd_for)"
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
