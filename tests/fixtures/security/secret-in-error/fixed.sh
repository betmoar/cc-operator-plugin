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
  # whether it was well-formed — not its value. A fingerprint answers both:
  # the last four characters, plus the length.
  #
  # The short-token arm is not defensive padding. `${TOKEN%????}` does not match
  # a token under four characters, so the naive one-liner returned the WHOLE
  # token as the "last four" — printing the entire secret for exactly the
  # credential most likely to be a malformed paste. Found by the review panel's
  # control run over this file, and it is the failure that matters most here:
  # a redaction that silently stops redacting.
  if [ "${#TOKEN}" -ge 8 ]; then
    _tail="${TOKEN#"${TOKEN%????}"}"
    _fp="***${_tail}"
  else
    # Too short for four characters to be a safe fraction of it — say so
    # instead of showing any part.
    _fp="*** (too short to fingerprint)"
  fi
  echo "dispatch FAILED for model=$MODEL" >&2
  echo "  request context: Authorization: Bearer ${_fp} (len ${#TOKEN})" >&2
  echo "  paste this line into the verdict's evidence cell" >&2
  exit 3
fi
