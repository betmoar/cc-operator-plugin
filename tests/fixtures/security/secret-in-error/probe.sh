#!/usr/bin/env bash
# Probe for the secret-in-error fixture.
#   bash probe.sh <path-to-vuln.sh|fixed.sh>
# FUNCTIONAL: ok|fail    — is the failure still reported, with the model id and
#                          a usable credential reference, at the documented rc?
# EXPLOIT: fired|blocked — does the secret's VALUE appear in the output?
set -u

TARGET="${1:?usage: probe.sh <script>}"
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/secfix.XXXXXX")"
trap 'rm -rf "$SANDBOX"' EXIT

SECRET="sk-live-4f9a2c7e1b8d3a60"
printf 'OPERATOR_API_KEY=%s\n' "$SECRET" > "$SANDBOX/env"

# BOTH streams, into one file. Capturing stderr alone certified a script that
# printed the token on stdout as safe (measured) — and the fixture's own premise
# is that this output reaches VERDICTS.md and a CI log, neither of which
# distinguishes the two streams. A leak probe that watches one pipe is not a
# leak probe.
ERR="$SANDBOX/out.txt"
bash "$TARGET" "$SANDBOX/env" "claude-opus-5" >"$ERR" 2>&1
RC=$?

# ── functional: the failure is reported, debuggable, at rc 3 ────────────────
# "Debuggable" is asserted rather than assumed: the model id AND a credential
# reference must both survive, or the fix has traded the feature for silence.
if [ "$RC" = 3 ] \
   && grep -q 'dispatch FAILED' "$ERR" \
   && grep -q 'model=claude-opus-5' "$ERR" \
   && grep -q 'Authorization: Bearer' "$ERR"; then
  # a missing key must still be refused before dispatch
  printf 'SOMETHING_ELSE=x\n' > "$SANDBOX/env2"
  if ! bash "$TARGET" "$SANDBOX/env2" "claude-opus-5" >/dev/null 2>&1; then
    echo "FUNCTIONAL: ok"
  else
    echo "FUNCTIONAL: fail"
  fi
else
  echo "FUNCTIONAL: fail"
fi

# ── exploit: the secret's value leaks into the reported output ───────────────
if grep -qF "$SECRET" "$ERR"; then
  echo "EXPLOIT: fired"
else
  echo "EXPLOIT: blocked"
fi
