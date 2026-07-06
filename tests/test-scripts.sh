#!/usr/bin/env bash
# Operator plugin — plain-bash test runner (no bats dependency).
# Covers T2 contract cases 1–5. Run from anywhere:
#   bash tests/test-scripts.sh
# Exit 0 iff every assertion passes. In RED phase (scripts absent) it fails,
# naming each missing-script failure — that failing output is the T2 evidence.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(dirname "$SCRIPT_DIR")"
SCRIPTS="$REPO/operator/scripts"
FIXTURES="$SCRIPT_DIR/fixtures"

INIT="$SCRIPTS/ops-init.sh"
VERDICT="$SCRIPTS/ops-verdict.sh"
HOOK="$SCRIPTS/ops-stop-hook.sh"

# Absolute bash so a restricted PATH (case 5) governs only the hook's INTERNAL
# command lookups (jq/python3), not the launch of bash itself.
BASH_ABS="$(command -v bash)"

PASS=0
FAIL=0
pass() { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
fail() { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }
check() { # check <desc> <0|1 condition-result>
  if [ "$2" -eq 0 ]; then pass "$1"; else fail "$1"; fi
}

# Fresh temp project; return its path.
newproj() { mktemp -d "${TMPDIR:-/tmp}/opstest.XXXXXX"; }

# Feed the hook a Stop payload built from a fixture, with cwd substituted and
# an optional restricted PATH. Captures exit code (global HRC) and stderr (HERR).
run_hook() { # run_hook <fixture> <cwd> [restricted-PATH]
  local fixture="$1" cwd="$2" rpath="${3:-}"
  local json; json="$(sed "s|<tmp>|$cwd|" "$FIXTURES/$fixture")"
  local errf; errf="$(mktemp)"
  if [ -n "$rpath" ]; then
    # Restrict only the hook's PATH (its jq/python3 lookups); bash launched by
    # absolute path so PATH loss can't stop the hook from running at all.
    printf '%s' "$json" | PATH="$rpath" "$BASH_ABS" "$HOOK" 2>"$errf"
  else
    printf '%s' "$json" | "$BASH_ABS" "$HOOK" 2>"$errf"
  fi
  HRC=$?
  HERR="$(cat "$errf")"; rm -f "$errf"
}

echo "== T2 test runner =="
echo "scripts under test: $SCRIPTS"
for s in "$INIT" "$VERDICT" "$HOOK"; do
  [ -f "$s" ] && echo "  present: ${s##*/}" || echo "  MISSING: ${s##*/} (expected to fail in RED)"
done

########################################################################
echo "-- Case 1: ops-init idempotent scaffold"
P="$(newproj)"; ( cd "$P" && bash "$INIT" >/dev/null 2>&1 )
check "init creates .operator/VERDICTS.md" "$([ -f "$P/.operator/VERDICTS.md" ] && echo 0 || echo 1)"
check "init creates .operator/DECISIONS.md" "$([ -f "$P/.operator/DECISIONS.md" ] && echo 0 || echo 1)"
check "init creates .operator/pending/ dir" "$([ -d "$P/.operator/pending" ] && echo 0 || echo 1)"
if [ -f "$P/.operator/VERDICTS.md" ]; then
  BEFORE="$(cat "$P/.operator/VERDICTS.md")"
  # mutate to prove no-clobber: a second init must NOT overwrite existing content
  printf '| T-X | seeded | seeded | PASS |\n' >> "$P/.operator/VERDICTS.md"
  SEEDED="$(cat "$P/.operator/VERDICTS.md")"
  ( cd "$P" && bash "$INIT" >/dev/null 2>&1 )
  AFTER="$(cat "$P/.operator/VERDICTS.md")"
  check "second init does not clobber VERDICTS content" "$([ "$AFTER" = "$SEEDED" ] && echo 0 || echo 1)"
else
  fail "second init does not clobber VERDICTS content (no file to test)"
fi
rm -rf "$P"

########################################################################
echo "-- Case 2: ops-verdict append + sentinel clear + empty-evidence refusal"
P="$(newproj)"; ( cd "$P" && bash "$INIT" >/dev/null 2>&1 )
mkdir -p "$P/.operator/pending"; : > "$P/.operator/pending/T-1"
( cd "$P" && bash "$VERDICT" T-1 "tests pass" "42 passed, 0 failed" PASS >/dev/null 2>&1 )
VRC=$?
ROW='| T-1 | tests pass | 42 passed, 0 failed | PASS |'
if [ -f "$P/.operator/VERDICTS.md" ]; then
  N="$(grep -Fxc "$ROW" "$P/.operator/VERDICTS.md" 2>/dev/null)"
else N=0; fi
check "verdict exits 0 on valid args" "$([ "$VRC" -eq 0 ] && echo 0 || echo 1)"
check "exactly one conformant row appended" "$([ "$N" = "1" ] && echo 0 || echo 1)"
check "sentinel pending/T-1 removed" "$([ ! -e "$P/.operator/pending/T-1" ] && echo 0 || echo 1)"
# empty evidence must be refused
: > "$P/.operator/pending/T-2"
( cd "$P" && bash "$VERDICT" T-2 "crit" "" PASS >/dev/null 2>&1 )
ERC=$?
if [ -f "$P/.operator/VERDICTS.md" ]; then
  N2="$(grep -Fc '| T-2 |' "$P/.operator/VERDICTS.md" 2>/dev/null)"
else N2=0; fi
check "empty-evidence verdict exits non-zero" "$([ "$ERC" -ne 0 ] && echo 0 || echo 1)"
check "empty-evidence appends no row" "$([ "$N2" = "0" ] && echo 0 || echo 1)"
check "empty-evidence leaves sentinel intact" "$([ -e "$P/.operator/pending/T-2" ] && echo 0 || echo 1)"
rm -rf "$P"

########################################################################
echo "-- Case 3: ops-verdict --defer writes DEFERRED-VERDICT + clears sentinel"
P="$(newproj)"; ( cd "$P" && bash "$INIT" >/dev/null 2>&1 )
mkdir -p "$P/.operator/pending"; : > "$P/.operator/pending/T-3"
( cd "$P" && bash "$VERDICT" T-3 --defer "blocked on upstream fix" >/dev/null 2>&1 )
DRC=$?
if [ -f "$P/.operator/DECISIONS.md" ]; then
  DN="$(grep -c 'DEFERRED-VERDICT' "$P/.operator/DECISIONS.md" 2>/dev/null)"
  DI="$(grep -c '| T-3 |.*DEFERRED-VERDICT' "$P/.operator/DECISIONS.md" 2>/dev/null)"
else DN=0; DI=0; fi
check "defer exits 0" "$([ "$DRC" -eq 0 ] && echo 0 || echo 1)"
check "defer writes a DEFERRED-VERDICT line" "$([ "$DN" -ge 1 ] && echo 0 || echo 1)"
check "deferred line is keyed to T-3" "$([ "$DI" -ge 1 ] && echo 0 || echo 1)"
check "defer clears sentinel pending/T-3" "$([ ! -e "$P/.operator/pending/T-3" ] && echo 0 || echo 1)"
rm -rf "$P"

########################################################################
echo "-- Case 4: Stop hook exit codes vs sentinel + loop guard"
P="$(newproj)"; ( cd "$P" && bash "$INIT" >/dev/null 2>&1 )
mkdir -p "$P/.operator/pending"   # sentinel setup independent of init success
# 4a: pending non-empty → exit 2, stderr names the id
: > "$P/.operator/pending/T-9"
run_hook stop-basic.json "$P"
check "pending non-empty → exit 2" "$([ "$HRC" -eq 2 ] && echo 0 || echo 1)"
check "exit-2 stderr names pending id T-9" "$(printf '%s' "$HERR" | grep -q 'T-9' && echo 0 || echo 1)"
# 4b: pending empty → exit 0
rm -f "$P/.operator/pending/T-9"
run_hook stop-basic.json "$P"
check "pending empty → exit 0" "$([ "$HRC" -eq 0 ] && echo 0 || echo 1)"
# 4c: .operator absent entirely → exit 0 (P3 no-op guard)
Q="$(newproj)"
run_hook stop-basic.json "$Q"
check ".operator absent → exit 0 (no-op guard)" "$([ "$HRC" -eq 0 ] && echo 0 || echo 1)"
rm -rf "$Q"
# 4d: stop_hook_active true with pending present → exit 0 (loop guard wins)
: > "$P/.operator/pending/T-9"
run_hook stop-loopguard.json "$P"
check "stop_hook_active true → exit 0 despite pending" "$([ "$HRC" -eq 0 ] && echo 0 || echo 1)"
rm -rf "$P"

########################################################################
echo "-- Case 5: jq-absent fallback (python3), then neither (fail-open)"
# Build a restricted PATH holding only python3, no jq. Resolve the REAL
# interpreter (sys.executable) — a pyenv/asdf `python3` on PATH is a shim that
# won't run standalone under a minimal PATH; its real binary will.
PYBIN="$(python3 -c 'import sys; print(sys.executable)' 2>/dev/null || true)"
BINP="$(newproj)"
if [ -n "$PYBIN" ] && [ -x "$PYBIN" ]; then ln -s "$PYBIN" "$BINP/python3"; fi
PATH_NOJQ="$BINP"           # python3 present, jq absent
PATH_NONE="$(newproj)"      # empty dir: neither jq nor python3

P="$(newproj)"; ( cd "$P" && bash "$INIT" >/dev/null 2>&1 )
mkdir -p "$P/.operator/pending"   # sentinel setup independent of init success
: > "$P/.operator/pending/T-7"
# 5a: jq absent, python3 present, pending non-empty → exit 2 via fallback
run_hook stop-basic.json "$P" "$PATH_NOJQ"
check "jq-absent+py3: pending → exit 2 via python3 fallback" "$([ "$HRC" -eq 2 ] && echo 0 || echo 1)"
# 5b: jq absent, python3 present, pending empty → exit 0
rm -f "$P/.operator/pending/T-7"
run_hook stop-basic.json "$P" "$PATH_NOJQ"
check "jq-absent+py3: empty → exit 0" "$([ "$HRC" -eq 0 ] && echo 0 || echo 1)"
# 5c: neither jq nor python3 → exit 0 + one-line stderr warning (fail-open)
: > "$P/.operator/pending/T-7"
run_hook stop-basic.json "$P" "$PATH_NONE"
check "no parser: fail-open exit 0" "$([ "$HRC" -eq 0 ] && echo 0 || echo 1)"
check "no parser: prints a stderr warning" "$(printf '%s' "$HERR" | grep -qi 'warn' && echo 0 || echo 1)"
rm -rf "$P" "$BINP" "$PATH_NONE"

########################################################################
echo "== summary: $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]
