#!/usr/bin/env bash
# validate-on-edit.sh — run the contract validator after an edit to a file it
# actually reads, and say so only when something broke.
#
# WHY. validate_plugin.py is the guard on this repo's couplings — the ones
# CLAUDE.md's "If you touch X, update Y" table describes and that break
# SILENTLY. It runs in about a second. Waiting for CI to tell you a coupling
# snapped is paying minutes for an answer available immediately.
#
# It also failed twice in the #86 review in a way this hook makes visible
# sooner: a pin that matched a MENTION rather than an action, and a promised
# check that did not exist. Running the validator more often does not find those
# — only a mutation does — but it does surface the ordinary breakage fast, which
# is what leaves attention for the extraordinary kind.
#
# SCOPE: only files the validator reads (validator's own words: templates/,
# scripts/, hooks/, agents/, and the manifests). Editing docs/ or tests/ fires
# nothing, because a validator run that cannot be affected by the edit is noise
# with a plausible face.
#
# POLARITY: advisory, exit 0 always. Same reasoning as the shellcheck hook —
# the blocking gate in this repo is the Stop hook, and a second one on every
# edit turns a warning into a wedge.
set -u

payload=""
IFS= read -r -d '' payload || true
[ -n "$payload" ] || exit 0

if command -v jq >/dev/null 2>&1; then
  f="$(printf '%s' "$payload" | jq -r '.tool_input.file_path // empty' 2>/dev/null)"
elif command -v python3 >/dev/null 2>&1; then
  f="$(printf '%s' "$payload" | python3 -c 'import sys,json
try: d=json.load(sys.stdin)
except Exception: sys.exit(0)
print((d.get("tool_input") or {}).get("file_path") or "")' 2>/dev/null)"
else
  exit 0
fi
[ -n "$f" ] || exit 0

# Resolve the repo root from the edited file, not from cwd: a hook's cwd is not
# guaranteed to be the project, and walking up from the file is what the Stop
# hook already does for .operator/ (audit F01 — an exact-match lookup one
# directory deeper silently found nothing and allowed everything).
d="$(cd "$(dirname "$f")" 2>/dev/null && pwd)" || exit 0
root=""
while [ -n "$d" ]; do
  if [ -f "$d/scripts/validate_plugin.py" ] && [ -f "$d/.claude-plugin/plugin.json" ]; then
    root="$d"; break
  fi
  [ "$d" = "/" ] && break
  d="${d%/*}"; [ -n "$d" ] || d="/"
done
[ -n "$root" ] || exit 0

rel="${f#"$root"/}"
case "$rel" in
  templates/*|scripts/*|hooks/*|agents/*|.claude-plugin/*|commands/*) ;;
  *) exit 0 ;;
esac

command -v python3 >/dev/null 2>&1 || exit 0

# PYTHONDONTWRITEBYTECODE for the reason the workflows already set it: the
# validator writes no __pycache__ when run as a script, but the cost of being
# wrong about that is a dirty tree git status cannot show.
out="$(cd "$root" && PYTHONDONTWRITEBYTECODE=1 python3 scripts/validate_plugin.py 2>&1)" && exit 0

echo "validate_plugin FAILED after editing $rel:" >&2
printf '%s\n' "$out" >&2
exit 0
