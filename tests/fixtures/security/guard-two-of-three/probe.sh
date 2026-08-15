#!/usr/bin/env bash
# Probe for the guard-two-of-three fixture.
#   bash probe.sh <path-to-vuln.sh|fixed.sh>
# FUNCTIONAL: ok|fail    — do all three subcommands work on a normal id, and do
#                          the two guarded ones still refuse a traversal id?
# EXPLOIT: fired|blocked — does `adopt` write outside pending/?
set -u

TARGET="${1:?usage: probe.sh <script>}"
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/secfix.XXXXXX")"
trap 'rm -rf "$SANDBOX"' EXIT

DIR="$SANDBOX/proj/.operator"
mkdir -p "$DIR"

fn_ok=1
# open → sentinel exists
bash "$TARGET" open "$DIR" T-1 >/dev/null 2>&1 || fn_ok=0
[ -f "$DIR/pending/T-1" ] || fn_ok=0
# adopt → owner re-stamped
bash "$TARGET" adopt "$DIR" T-1 SESS-A >/dev/null 2>&1 || fn_ok=0
grep -q 'session_id: SESS-A' "$DIR/pending/T-1" 2>/dev/null || fn_ok=0
# close → sentinel gone
bash "$TARGET" close "$DIR" T-1 >/dev/null 2>&1 || fn_ok=0
[ ! -f "$DIR/pending/T-1" ] || fn_ok=0
# the two guarded sites must STILL refuse a traversal id — this is what makes
# the fixture "a guard at two of three sites" rather than "no guard".
bash "$TARGET" open "$DIR" '../../ESCAPE' >/dev/null 2>&1 && fn_ok=0
bash "$TARGET" close "$DIR" '../../ESCAPE' >/dev/null 2>&1 && fn_ok=0
[ "$fn_ok" = 1 ] && echo "FUNCTIONAL: ok" || echo "FUNCTIONAL: fail"

# ── exploit: the unguarded third site ────────────────────────────────────────
# `$DIR/pending/../../ESCAPE` — DIR is `$SANDBOX/proj/.operator`, so the two
# `..` segments climb pending/ then .operator/ and the write lands in
# `$SANDBOX/proj/ESCAPE`: outside the ledger directory the CLI owns.
# (This assertion was one level too high on first writing and read "blocked"
# against a vulnerable script — the failure mode a probe must not have, and the
# reason the vuln/fixed pair is asserted in BOTH directions by the suite.)
bash "$TARGET" adopt "$DIR" '../../ESCAPE' SESS-A >/dev/null 2>&1
if [ -f "$SANDBOX/proj/ESCAPE" ]; then
  echo "EXPLOIT: fired"
else
  echo "EXPLOIT: blocked"
fi
