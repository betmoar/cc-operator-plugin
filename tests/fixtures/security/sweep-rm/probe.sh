#!/usr/bin/env bash
# Probe for the sweep-rm fixture.
#   bash probe.sh <path-to-vuln.sh|fixed.sh>
# FUNCTIONAL: ok|fail    — does a normal session id sweep its own dir only?
# EXPLOIT: fired|blocked — does a traversal id delete a sibling outside the root?
# All paths live inside a mktemp sandbox removed on exit.
set -u

TARGET="${1:?usage: probe.sh <script>}"
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/secfix.XXXXXX")"
trap 'rm -rf "$SANDBOX"' EXIT

ROOT="$SANDBOX/spill"
mkdir -p "$ROOT"

# ── functional: sweeps its own dir, leaves a neighbour's alone ───────────────
mkdir -p "$ROOT/SESS-A" "$ROOT/SESS-B"
printf 'x\n' > "$ROOT/SESS-A/spill.txt"
printf 'y\n' > "$ROOT/SESS-B/spill.txt"
printf 'session_id: SESS-A\n' > "$SANDBOX/good"
if bash "$TARGET" "$ROOT" "$SANDBOX/good" >/dev/null 2>&1 \
   && [ ! -d "$ROOT/SESS-A" ] && [ -d "$ROOT/SESS-B" ]; then
  echo "FUNCTIONAL: ok"
else
  echo "FUNCTIONAL: fail"
fi

# ── exploit: escape the spill root and delete an unrelated tree ──────────────
# `$ROOT/../victim` resolves to `$SANDBOX/victim`.
mkdir -p "$SANDBOX/victim"
printf 'important\n' > "$SANDBOX/victim/data.txt"
printf 'session_id: ../victim\n' > "$SANDBOX/evil"
bash "$TARGET" "$ROOT" "$SANDBOX/evil" >/dev/null 2>&1
if [ ! -d "$SANDBOX/victim" ]; then
  echo "EXPLOIT: fired"
else
  echo "EXPLOIT: blocked"
fi
