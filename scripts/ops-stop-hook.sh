#!/usr/bin/env bash
# ops-stop-hook.sh — Stop-hook completion gate (P3/D4 layer 2).
#
# Contract (exit codes are the interface — Claude Code reads them):
#   exit 0  — allow the stop. Cases: no .operator/ in cwd (no-op guard);
#             .operator/pending/ empty; stop_hook_active true (loop guard);
#             no JSON parser available (fail-open — a broken hook must never
#             brick a session).
#   exit 2  — block the stop. .operator/pending/ is non-empty and
#             stop_hook_active is false; stderr names the pending ids and the
#             command to clear them (Claude Code feeds stderr back as guidance).
#
# Reads the Stop payload as JSON on stdin ONCE. Sentinel check runs against the
# cwd carried IN the payload, never the script's own cwd. External dependencies
# are limited to one JSON parser (jq preferred, python3 fallback); stdin read
# and pending enumeration use bash builtins only, so PATH loss cannot brick it.
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

# --- loop guard: never re-block an already-active stop -----------------------
[ "$active" = "true" ] && exit 0

# --- no-op guard: not an operator project → stay out of the way --------------
[ -n "$cwd" ] || exit 0
opdir="$cwd/.operator"
[ -d "$opdir" ] || exit 0

# --- enumerate pending sentinels (builtin glob; no `find` dependency) --------
pending=""
shopt -s nullglob
for f in "$opdir/pending"/*; do
  [ -e "$f" ] || continue
  id="${f##*/}"
  pending="${pending:+$pending, }$id"
done
shopt -u nullglob

if [ -n "$pending" ]; then
  # Name a path that resolves from the project cwd: ops-init installs the
  # verdict CLI at .operator/bin/. Fall back to this hook's own sibling (the
  # plugin copy, absolute) for projects scaffolded by an older ops-init.
  verdict_cmd=".operator/bin/ops-verdict.sh"
  if [ ! -f "$opdir/bin/ops-verdict.sh" ]; then
    case "${BASH_SOURCE[0]}" in
      */*) script_dir="${BASH_SOURCE[0]%/*}" ;;
      *)   script_dir="." ;;                    # invoked bare: script is in cwd
    esac
    script_dir="$(cd "$script_dir" 2>/dev/null && pwd)" || script_dir=""
    if [ -n "$script_dir" ]; then verdict_cmd="$script_dir/ops-verdict.sh"; fi
  fi
  echo "operator: pending verdict(s): $pending — run $verdict_cmd <id> <criterion> <evidence> <PASS|FAIL>, or --defer \"<reason>\"" >&2
  exit 2
fi

exit 0
