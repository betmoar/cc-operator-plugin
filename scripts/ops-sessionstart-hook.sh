#!/usr/bin/env bash
# ops-sessionstart-hook.sh — tell the operator its own session id.
#
# The agent cannot discover this any other way: CLAUDE_SESSION_ID is NOT set in
# the Bash tool environment (probed in the field, 2026-07-25). Only hooks receive
# session_id, via the stdin payload. Everything downstream — sentinel ownership,
# the Stop hook's mine/foreign partition, ops-adopt — depends on the agent being
# able to pass `--owner <sid>`, so this injection is the root of the mechanism.
#
# Contract: always exit 0. This hook is advisory; a failure here must never cost
# a session. Stays silent (no output at all) outside operator projects and when
# no JSON parser is available.
#
# Lives in scripts/ (not hooks/) alongside the other gate scripts; hooks.json
# references it via ${CLAUDE_PLUGIN_ROOT}/scripts/, same as the Stop hook.
set -u

input=""
IFS= read -r -d '' input || true

if command -v jq >/dev/null 2>&1; then
  PARSER=jq
elif command -v python3 >/dev/null 2>&1; then
  PARSER=python3
else
  exit 0   # silent: no parser, nothing to say
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
v = d.get(sys.argv[1], "")
print("" if v is None else v)
' "$1" 2>/dev/null
      ;;
  esac
}

session="$(json_get session_id)"
[ -n "$session" ] || exit 0

# Scope to operator projects so this never adds noise elsewhere. SessionStart
# payloads carry cwd; if a future payload omits it, fall back to the hook's own
# cwd rather than going silent — a missing banner costs the whole mechanism.
cwd="$(json_get cwd)"
[ -n "$cwd" ] || cwd="$PWD"
[ -d "$cwd/.operator" ] || exit 0

# Compressor artifact cleanup (spec I2.3 + the dedup state contract). Both are
# session-scoped ephemera, and both MUST be cleared on every SessionStart fire
# INCLUDING `compact`: compaction can prune the prior output from context, and
# "the content is already in context" is the dedup marker's entire
# justification — a stale hash after a compact collapses output the model can no
# longer see. A /clear rotates the session id, so old directories would
# otherwise accumulate forever; the whole tree goes, not just this session's.
# Best-effort by design: a cleanup failure must never cost the session its
# banner, so every branch swallows and continues.
for _cdir in "$cwd/.operator/.compress-spill" "$cwd/.operator/.compress-state"; do
  [ -d "$_cdir" ] && rm -rf "$_cdir" 2>/dev/null
done

# Ensure the compressor's ephemera are git-ignored BEFORE the compressor can
# recreate them this session. ops-init writes these lines, but a target project
# whose .operator/.gitignore predates the compressor (or was written by an older
# ops-init) lacks them — so .compress-spill/ shows up as untracked dirty state
# the moment the PostToolUse compressor fires, and stays dirty until the user
# re-runs /cc-operator:start. The upgrade-append ops-init does only fires on
# re-init; this runs every session. Idempotent append, best-effort (a write
# failure must never cost the session its banner).
_gi="$cwd/.operator/.gitignore"
if [ -f "$_gi" ] && ! grep -q '^\.compress-spill/$' "$_gi" 2>/dev/null; then
  {
    printf '# Compressor ephemera (ensured by SessionStart): session-scoped, wiped on every start.\n'
    printf '.compress-spill/\n.compress-state/\n'
  } >> "$_gi" 2>/dev/null
fi

ctx="cc-operator: this session's id is ${session}. Pass --owner ${session} when opening or closing tracked tasks — .operator/bin/ops-task.sh <id> --owner ${session}, .operator/bin/ops-verdict.sh <id> ... --owner ${session}. Sentinels you open are then yours alone: the Stop hook blocks only on your own open tasks and reports other sessions' as informational. After a /clear your id changes — run .operator/bin/ops-adopt.sh --owner ${session} <id>... to re-claim tasks you are still working."

if [ "$PARSER" = "jq" ]; then
  jq -n --arg c "$ctx" \
    '{hookSpecificOutput:{hookEventName:"SessionStart", additionalContext:$c}}'
else
  printf '%s' "$ctx" | python3 -c '
import sys, json
print(json.dumps({"hookSpecificOutput": {
    "hookEventName": "SessionStart",
    "additionalContext": sys.stdin.read(),
}}))
'
fi
exit 0
