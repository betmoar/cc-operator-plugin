#!/usr/bin/env bash
# Probe for the frag-traversal fixture.
#   bash probe.sh <path-to-vuln.sh|fixed.sh>
# Prints exactly two lines:
#   FUNCTIONAL: ok|fail    — does the feature still work for a normal owner id?
#   EXPLOIT: fired|blocked — does a traversal owner escape the ledger dir?
# Every path used resolves inside a mktemp sandbox that is removed on exit.
set -u

TARGET="${1:?usage: probe.sh <script>}"
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/secfix.XXXXXX")"
trap 'rm -rf "$SANDBOX"' EXIT

LEDGER="$SANDBOX/proj/.operator"
mkdir -p "$LEDGER"

# ── functional: a well-formed owner writes its own fragment, rc 0 ────────────
printf 'session_id: SESS-A\n' > "$SANDBOX/good"
if bash "$TARGET" "$LEDGER" "$SANDBOX/good" "| row | evidence | PASS |" \
     >/dev/null 2>&1 \
   && [ -f "$LEDGER/verdicts.d/SESS-A.frag" ] \
   && grep -q 'evidence' "$LEDGER/verdicts.d/SESS-A.frag"; then
  echo "FUNCTIONAL: ok"
else
  echo "FUNCTIONAL: fail"
fi

# ── exploit: the owner field escapes verdicts.d/ ─────────────────────────────
# `$LEDGER/verdicts.d/../../PWNED.frag` resolves to `$SANDBOX/proj/PWNED.frag`.
printf 'session_id: ../../PWNED\n' > "$SANDBOX/evil"
bash "$TARGET" "$LEDGER" "$SANDBOX/evil" "attacker row" >/dev/null 2>&1
if [ -f "$SANDBOX/proj/PWNED.frag" ]; then
  echo "EXPLOIT: fired"
else
  echo "EXPLOIT: blocked"
fi
