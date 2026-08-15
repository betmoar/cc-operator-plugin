#!/usr/bin/env bash
# FIXTURE (inert): the CORRECTED variant of frag-traversal/vuln.sh.
# Identical CLI and identical behaviour on every well-formed owner id; the only
# difference is the reject set applied to the parsed field before it becomes a
# path component.
#
# Usage: fixed.sh <ledger-dir> <sentinel-file> <row-text>
set -u

LEDGER="$1"
SENTINEL="$2"
ROW="$3"

[ -f "$SENTINEL" ] || { echo "no such sentinel: $SENTINEL" >&2; exit 1; }

owner=""
while IFS= read -r line; do
  case "$line" in
    "session_id: "*) owner="${line#session_id: }" ;;
  esac
done < "$SENTINEL"

[ -n "$owner" ] || { echo "sentinel names no owner" >&2; exit 1; }

# THE FIX. A value that will be concatenated into a path must be a bare name:
# no separator, no dot-relative segment, no leading dot (which hides the result
# from a glob). Mirrors the bare-name reject set the shipped CLIs apply.
case "$owner" in
  */*|*\\*|.*|*..*)
    echo "refusing owner '$owner' — not a bare name" >&2; exit 2 ;;
esac

mkdir -p "$LEDGER/verdicts.d" || { echo "cannot create fragment dir" >&2; exit 1; }
printf '%s\n' "$ROW" >> "$LEDGER/verdicts.d/$owner.frag" || {
  echo "fragment write failed" >&2; exit 1; }

echo "wrote fragment for $owner"
