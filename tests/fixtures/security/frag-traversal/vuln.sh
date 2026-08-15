#!/usr/bin/env bash
# FIXTURE (inert): appends a verdict fragment named after the sentinel's owner.
# Models ops-verdict.sh's fragment writer, which builds a filename out of a
# field parsed from an untrusted sentinel body.
#
# Usage: vuln.sh <ledger-dir> <sentinel-file> <row-text>
#
# This is the DEFECTIVE variant. It works correctly for every well-formed
# owner id and has no missing error handling: the sentinel is read, the field
# is extracted, an absent owner is refused, the write is checked. See NOTES.md.
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

mkdir -p "$LEDGER/verdicts.d" || { echo "cannot create fragment dir" >&2; exit 1; }
printf '%s\n' "$ROW" >> "$LEDGER/verdicts.d/$owner.frag" || {
  echo "fragment write failed" >&2; exit 1; }

echo "wrote fragment for $owner"
