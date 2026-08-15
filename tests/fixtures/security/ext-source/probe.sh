#!/usr/bin/env bash
# Probe for the ext-source fixture.
#   bash probe.sh <path-to-vuln.sh|fixed.sh>
# FUNCTIONAL: ok|fail    — do a normal tiers.env's bindings load, comments and
#                          all, with the documented defaults on absence?
# EXPLOIT: fired|blocked — does a payload in tiers.env execute?
set -u

TARGET="${1:?usage: probe.sh <script>}"
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/secfix.XXXXXX")"
trap 'rm -rf "$SANDBOX"' EXIT

PROJ="$SANDBOX/proj"
mkdir -p "$PROJ/.operator"

# ── functional: bindings load; a comment and a blank line are tolerated ──────
cat > "$PROJ/.operator/tiers.env" <<'EOF'
# tier bindings
JUDGMENT=claude-opus-5

MECHANICAL=deepseek/deepseek-v4-flash
EOF
OUT="$(bash "$TARGET" "$PROJ" 2>/dev/null)"
if printf '%s' "$OUT" | grep -q 'JUDGMENT=claude-opus-5' \
   && printf '%s' "$OUT" | grep -q 'MECHANICAL=deepseek/deepseek-v4-flash'; then
  # and the default fires when a binding is absent
  printf 'JUDGMENT=claude-opus-5\n' > "$PROJ/.operator/tiers.env"
  if bash "$TARGET" "$PROJ" 2>/dev/null | grep -q 'MECHANICAL=glm-5-turbo'; then
    echo "FUNCTIONAL: ok"
  else
    echo "FUNCTIONAL: fail"
  fi
else
  echo "FUNCTIONAL: fail"
fi

# ── exploit: the config file executes ────────────────────────────────────────
# Command substitution in a value is enough — no exotic syntax needed.
cat > "$PROJ/.operator/tiers.env" <<EOF
JUDGMENT=claude-opus-5
MECHANICAL=\$(touch "$SANDBOX/PWNED"; echo glm-5-turbo)
EOF
bash "$TARGET" "$PROJ" >/dev/null 2>&1
if [ -f "$SANDBOX/PWNED" ]; then
  echo "EXPLOIT: fired"
else
  echo "EXPLOIT: blocked"
fi
