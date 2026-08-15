#!/usr/bin/env bash
# FIXTURE (inert): the CORRECTED variant of sweep-rm/vuln.sh.
# Identical CLI and identical behaviour on every well-formed session id.
#
# Usage: fixed.sh <spill-root> <session-file>
set -u

ROOT="$1"
SESSION_FILE="$2"

[ -d "$ROOT" ] || { echo "no spill root: $ROOT" >&2; exit 1; }
[ -f "$SESSION_FILE" ] || { echo "no session file: $SESSION_FILE" >&2; exit 1; }

sid=""
while IFS= read -r line; do
  case "$line" in
    "session_id: "*) sid="${line#session_id: }" ;;
  esac
done < "$SESSION_FILE"

[ -n "$sid" ] || { echo "session file names no id" >&2; exit 1; }

# THE FIX. Before the value becomes an `rm -rf` argument it must be a bare
# name. Quoting was never the issue here — a quoted `../..` traverses exactly
# as well as an unquoted one, which is why "it is quoted, so it is scoped" is
# the wrong reading of the vulnerable line.
case "$sid" in
  */*|*\\*|.*|*..*)
    echo "refusing session id '$sid' — not a bare name" >&2; exit 2 ;;
esac

target="$ROOT/$sid"
if [ -d "$target" ]; then
  rm -rf "$target"
  echo "swept $sid"
else
  echo "nothing to sweep for $sid"
fi
