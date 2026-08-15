#!/usr/bin/env bash
# FIXTURE (inert): the CORRECTED variant of secret-in-error/vuln.sh.
# Identical CLI, identical exit codes, and the failure is still debuggable —
# the message keeps everything except the secret's value.
#
# Usage: fixed.sh <env-file> <model-id>
set -u

ENVFILE="${1:?usage: fixed.sh <env-file> <model-id>}"
MODEL="${2:?model id required}"

[ -f "$ENVFILE" ] || { echo "no env file: $ENVFILE" >&2; exit 1; }

TOKEN=""
while IFS= read -r line; do
  case "$line" in
    "OPERATOR_API_KEY="*) TOKEN="${line#OPERATOR_API_KEY=}" ;;
  esac
done < "$ENVFILE"

[ -n "$TOKEN" ] || { echo "no OPERATOR_API_KEY in $ENVFILE" >&2; exit 1; }

dispatch_failed=1

if [ "$dispatch_failed" = 1 ]; then
  # THE FIX. What the operator needs to debug is WHICH credential was used and
  # whether it was well-formed — not its value. A fingerprint answers both and
  # is safe to commit: last four characters plus the length.
  _tail="${TOKEN#"${TOKEN%????}"}"
  echo "dispatch FAILED for model=$MODEL" >&2
  echo "  request context: Authorization: Bearer ***${_tail} (len ${#TOKEN})" >&2
  echo "  paste this line into the verdict's evidence cell" >&2
  exit 3
fi
