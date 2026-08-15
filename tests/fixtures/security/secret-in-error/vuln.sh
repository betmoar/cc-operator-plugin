#!/usr/bin/env bash
# FIXTURE (inert): resolves a provider token and reports a failed dispatch.
# Models the evidence-cell path — a message this project pastes verbatim into
# VERDICTS.md, which is committed, and into CI logs, which are public on a
# public repo.
#
# Usage: vuln.sh <env-file> <model-id>
#
# This is the DEFECTIVE variant. It is functionally correct: the token is
# resolved, an absent token is refused before dispatch, and a failure is
# reported with enough context to debug.
set -u

ENVFILE="${1:?usage: vuln.sh <env-file> <model-id>}"
MODEL="${2:?model id required}"

[ -f "$ENVFILE" ] || { echo "no env file: $ENVFILE" >&2; exit 1; }

TOKEN=""
while IFS= read -r line; do
  case "$line" in
    "OPERATOR_API_KEY="*) TOKEN="${line#OPERATOR_API_KEY=}" ;;
  esac
done < "$ENVFILE"

[ -n "$TOKEN" ] || { echo "no OPERATOR_API_KEY in $ENVFILE" >&2; exit 1; }

# Stand-in for the dispatch. The fixture always takes the failure path — the
# reporting is the subject, not the request.
dispatch_failed=1

if [ "$dispatch_failed" = 1 ]; then
  # Report enough for the operator to reproduce the call. The request context
  # is exactly what makes a failure debuggable rather than a shrug.
  echo "dispatch FAILED for model=$MODEL" >&2
  echo "  request context: Authorization: Bearer $TOKEN" >&2
  echo "  paste this line into the verdict's evidence cell" >&2
  exit 3
fi
