#!/usr/bin/env bash
# FIXTURE (inert): sweeps a session's ephemeral spill directory.
# Models the compressor-tempdir sweep that ops-sessionstart-hook.sh re-derives
# in shell — a parsed field reaching an `rm -rf` argument.
#
# Usage: vuln.sh <spill-root> <session-file>
#
# This is the DEFECTIVE variant. It is functionally correct: a well-formed
# session id sweeps exactly its own directory, an absent id is refused, and a
# root that does not exist is refused before any removal.
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

# Sweep this session's spill dir. Quoted, so no word-splitting; the removal is
# scoped under $ROOT by construction of the path.
target="$ROOT/$sid"
if [ -d "$target" ]; then
  rm -rf "$target"
  echo "swept $sid"
else
  echo "nothing to sweep for $sid"
fi
