#!/usr/bin/env bash
# Operator plugin — plain-bash test runner (no bats dependency).
# Covers T2 contract cases 1–5. Run from anywhere:
#   bash tests/test-scripts.sh
# Exit 0 iff every assertion passes. In RED phase (scripts absent) it fails,
# naming each missing-script failure — that failing output is the T2 evidence.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(dirname "$SCRIPT_DIR")"
SCRIPTS="$REPO/scripts"
FIXTURES="$SCRIPT_DIR/fixtures"

INIT="$SCRIPTS/ops-init.sh"
VERDICT="$SCRIPTS/ops-verdict.sh"
HOOK="$SCRIPTS/ops-stop-hook.sh"
TASK="$SCRIPTS/ops-task.sh"
ADOPT="$SCRIPTS/ops-adopt.sh"
SSHOOK="$SCRIPTS/ops-sessionstart-hook.sh"

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
for s in "$INIT" "$VERDICT" "$HOOK" "$TASK" "$ADOPT" "$SSHOOK"; do
  [ -f "$s" ] && echo "  present: ${s##*/}" || echo "  MISSING: ${s##*/} (expected to fail in RED)"
done

########################################################################
echo "-- Case 1: ops-init idempotent scaffold"
P="$(newproj)"; ( cd "$P" && bash "$INIT" >/dev/null 2>&1 )
check "init creates .operator/VERDICTS.md" "$([ -f "$P/.operator/VERDICTS.md" ] && echo 0 || echo 1)"
check "init creates .operator/DECISIONS.md" "$([ -f "$P/.operator/DECISIONS.md" ] && echo 0 || echo 1)"
check "init creates .operator/pending/ dir" "$([ -d "$P/.operator/pending" ] && echo 0 || echo 1)"
if [ -f "$P/.operator/VERDICTS.md" ]; then
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
echo "-- Case 6: project-installed gate CLIs (.operator/bin) + ops-task opener"
P="$(newproj)"; ( cd "$P" && bash "$INIT" >/dev/null 2>&1 )
check "init installs .operator/bin/ops-verdict.sh (executable)" "$([ -x "$P/.operator/bin/ops-verdict.sh" ] && echo 0 || echo 1)"
check "init installs .operator/bin/ops-task.sh (executable)" "$([ -x "$P/.operator/bin/ops-task.sh" ] && echo 0 || echo 1)"
check "init installs .operator/bin/ops-adopt.sh (executable)" "$([ -x "$P/.operator/bin/ops-adopt.sh" ] && echo 0 || echo 1)"
# re-run refreshes the bin copies (the upgrade path) — unlike the ledgers,
# which are never clobbered
printf '#!/usr/bin/env bash\necho stale\n' > "$P/.operator/bin/ops-verdict.sh"
( cd "$P" && bash "$INIT" >/dev/null 2>&1 )
check "second init refreshes bin copy to plugin version" "$(cmp -s "$P/.operator/bin/ops-verdict.sh" "$VERDICT" && echo 0 || echo 1)"
# ops-task opens the sentinel; the installed CLIs work from the project cwd
( cd "$P" && ./.operator/bin/ops-task.sh T-6 >/dev/null 2>&1 ); TRC=$?
check "ops-task exits 0 and drops sentinel" "$([ "$TRC" -eq 0 ] && [ -e "$P/.operator/pending/T-6" ] && echo 0 || echo 1)"
run_hook stop-basic.json "$P"
check "hook blocks (exit 2) on ops-task-opened sentinel" "$([ "$HRC" -eq 2 ] && echo 0 || echo 1)"
check "block message names .operator/bin/ops-verdict.sh" "$(printf '%s' "$HERR" | grep -q '\.operator/bin/ops-verdict\.sh' && echo 0 || echo 1)"
( cd "$P" && ./.operator/bin/ops-verdict.sh T-6 "crit" "output" PASS >/dev/null 2>&1 )
check "installed verdict CLI appends row + clears sentinel" "$(grep -Fq '| T-6 | crit | output | PASS |' "$P/.operator/VERDICTS.md" && [ ! -e "$P/.operator/pending/T-6" ] && echo 0 || echo 1)"
# ops-task refusals: no id; no .operator/
( cd "$P" && ./.operator/bin/ops-task.sh >/dev/null 2>&1 ); NRC=$?
check "ops-task refuses a missing task-id" "$([ "$NRC" -ne 0 ] && echo 0 || echo 1)"
Q="$(newproj)"
( cd "$Q" && bash "$TASK" T-1 >/dev/null 2>&1 ); QRC=$?
check "ops-task refuses without .operator/" "$([ "$QRC" -ne 0 ] && echo 0 || echo 1)"
rm -rf "$Q"
# pre-0.3 project (no bin/): block message falls back to the plugin's absolute copy
rm -rf "$P/.operator/bin"
: > "$P/.operator/pending/T-8"
run_hook stop-basic.json "$P"
check "no bin/: block message falls back to plugin-root absolute path" "$(printf '%s' "$HERR" | grep -q "$SCRIPTS/ops-verdict.sh" && echo 0 || echo 1)"
rm -rf "$P"

########################################################################
echo "-- Case 7: ledger cell hygiene — refuse, never corrupt (single-writer schema)"
# INVARIANT: a VERDICTS row is exactly one line of exactly 4 pipe-delimited
# cells; the single writer refuses anything that would break that schema.
P="$(newproj)"; ( cd "$P" && bash "$INIT" >/dev/null 2>&1 )
ROWS_BEFORE="$(wc -l < "$P/.operator/VERDICTS.md")"
: > "$P/.operator/pending/T-P"
( cd "$P" && bash "$VERDICT" T-P "crit" "out: 3 | 0 failed" PASS >/dev/null 2>&1 ); PRC=$?
check "pipe in evidence → refused (exit != 0)" "$([ "$PRC" -ne 0 ] && echo 0 || echo 1)"
check "pipe in evidence → no row, sentinel intact" "$([ "$(wc -l < "$P/.operator/VERDICTS.md")" = "$ROWS_BEFORE" ] && [ -e "$P/.operator/pending/T-P" ] && echo 0 || echo 1)"
( cd "$P" && bash "$VERDICT" T-P "crit" "$(printf 'l1\nl2')" PASS >/dev/null 2>&1 ); NRC=$?
check "newline in evidence → refused" "$([ "$NRC" -ne 0 ] && echo 0 || echo 1)"
( cd "$P" && bash "$VERDICT" T-P "crit" "evidence" MAYBE >/dev/null 2>&1 ); MRC=$?
check "verdict MAYBE → refused (PASS|FAIL only)" "$([ "$MRC" -ne 0 ] && echo 0 || echo 1)"
# INVARIANT: task-id is a bare filename — never a path (clear_sentinel rm -f
# must not be able to reach outside .operator/pending/).
echo victim > "$P/victim.txt"
( cd "$P" && bash "$VERDICT" "../../victim.txt" "crit" "evidence" PASS >/dev/null 2>&1 ); XRC=$?
check "traversal task-id → refused" "$([ "$XRC" -ne 0 ] && echo 0 || echo 1)"
check "traversal task-id → victim file survives" "$([ -f "$P/victim.txt" ] && echo 0 || echo 1)"
( cd "$P" && bash "$TASK" "a|b" >/dev/null 2>&1 ); TRC2=$?
check "ops-task refuses '|' in task-id" "$([ "$TRC2" -ne 0 ] && echo 0 || echo 1)"
( cd "$P" && bash "$VERDICT" T-P --defer "$(printf 'blocked\nfake | row')" >/dev/null 2>&1 ); DRC2=$?
check "newline/pipe in defer reason → refused" "$([ "$DRC2" -ne 0 ] && echo 0 || echo 1)"
# clean inputs still pass end-to-end after the hygiene guards
( cd "$P" && bash "$VERDICT" T-P "crit" "42 passed, 0 failed" PASS >/dev/null 2>&1 ); CRC=$?
check "clean row still accepted after guards" "$([ "$CRC" -eq 0 ] && [ ! -e "$P/.operator/pending/T-P" ] && echo 0 || echo 1)"
rm -rf "$P"

########################################################################
echo "-- Case 8: sentinel ownership — block your own, report the other session's"
# INVARIANT (spec §4.1 criteria 1+3): a session's Stop gate answers only for the
# tasks it owns. The field failure was the inverse: session A was trapped by
# session B's task, and its only escapes both disarmed B's gate.
P="$(newproj)"; ( cd "$P" && bash "$INIT" >/dev/null 2>&1 )
( cd "$P" && bash "$TASK" T-A --owner SESS-A >/dev/null 2>&1 )
check "sentinel stamps its owner" "$(grep -q '^session_id: SESS-A$' "$P/.operator/pending/T-A" && echo 0 || echo 1)"
# 8a: the owning session is blocked
run_hook stop-session-a.json "$P"
check "owner's Stop → exit 2 on its own task" "$([ "$HRC" -eq 2 ] && echo 0 || echo 1)"
check "owner's block message names T-A" "$(printf '%s' "$HERR" | grep -q 'T-A' && echo 0 || echo 1)"
# 8b: the bystander session is NOT blocked, but is told
run_hook stop-session-b.json "$P"
check "foreign session's Stop → exit 0 (not trapped)" "$([ "$HRC" -eq 0 ] && echo 0 || echo 1)"
check "foreign session is told, not blocked" "$(printf '%s' "$HERR" | grep -q 'owned by another session' && echo 0 || echo 1)"
# The report must name the OWNER and when it was opened, not just the task id:
# with three or more sessions a bystander otherwise cannot tell whom to chase.
# The doc's §4.1 example always showed this; the code did not until 0.4.0.
check "foreign report names the owning session id" "$(printf '%s' "$HERR" | grep -q 'owned by SESS-A' && echo 0 || echo 1)"
check "foreign report carries opened_at" "$(printf '%s' "$HERR" | grep -q 'opened 20' && echo 0 || echo 1)"
# 8c: mixed — block, and name ONLY the caller's own task
( cd "$P" && bash "$TASK" T-B --owner SESS-B >/dev/null 2>&1 )
run_hook stop-session-a.json "$P"
check "mixed pending → owner still blocked (exit 2)" "$([ "$HRC" -eq 2 ] && echo 0 || echo 1)"
BLOCKLINE="$(printf '%s' "$HERR" | grep 'pending verdict(s):' || true)"
check "block line names T-A only, never T-B" "$(printf '%s' "$BLOCKLINE" | grep -q 'T-A' && ! printf '%s' "$BLOCKLINE" | grep -q 'T-B' && echo 0 || echo 1)"
# 8d: SessionStart hook injects the id (the only channel that carries it)
SSOUT="$(sed "s|<tmp>|$P|" "$FIXTURES/sessionstart.json" | "$BASH_ABS" "$SSHOOK" 2>/dev/null)"
check "sessionstart hook emits additionalContext with the id" "$(printf '%s' "$SSOUT" | grep -q 'additionalContext' && printf '%s' "$SSOUT" | grep -q 'SESS-A' && echo 0 || echo 1)"
# outside an operator project it must stay completely silent
Q="$(newproj)"
SSQ="$(sed "s|<tmp>|$Q|" "$FIXTURES/sessionstart.json" | "$BASH_ABS" "$SSHOOK" 2>/dev/null)"; SSQRC=$?
check "sessionstart hook silent outside operator projects" "$([ "$SSQRC" -eq 0 ] && [ -z "$SSQ" ] && echo 0 || echo 1)"
rm -rf "$Q" "$P"

########################################################################
echo "-- Case 9: migration safety — an unowned sentinel blocks EVERY session"
# INVARIANT (spec §4.1 criterion 2): unowned fails CLOSED. Pre-0.4 sentinels are
# empty files; they must keep gating, or upgrading the plugin would silently
# disarm every in-flight task. Deliberately the opposite default from case 5's
# fail-open — a broken plugin must not brick a session, but an unowned sentinel
# is a real open task.
P="$(newproj)"; ( cd "$P" && bash "$INIT" >/dev/null 2>&1 )
: > "$P/.operator/pending/T-OLD"          # exactly the pre-0.4 format
run_hook stop-session-a.json "$P"
check "pre-0.4 empty sentinel blocks session A" "$([ "$HRC" -eq 2 ] && echo 0 || echo 1)"
run_hook stop-session-b.json "$P"
check "pre-0.4 empty sentinel blocks session B too" "$([ "$HRC" -eq 2 ] && echo 0 || echo 1)"
run_hook stop-basic.json "$P"
check "payload without session_id → pre-0.4 behavior (exit 2)" "$([ "$HRC" -eq 2 ] && echo 0 || echo 1)"
# an owned sentinel + a payload carrying no session_id also blocks (fail closed)
rm -f "$P/.operator/pending/T-OLD"
( cd "$P" && bash "$TASK" T-A --owner SESS-A >/dev/null 2>&1 )
run_hook stop-basic.json "$P"
check "no session_id in payload → owned sentinel still blocks" "$([ "$HRC" -eq 2 ] && echo 0 || echo 1)"
# ops-task without --owner produces an unowned sentinel and says so
rm -f "$P/.operator/pending/T-A"
TOUT="$( cd "$P" && bash "$TASK" T-N 2>&1 )"
check "ops-task without --owner warns it is unowned" "$(printf '%s' "$TOUT" | grep -qi 'UNOWNED' && echo 0 || echo 1)"
run_hook stop-session-b.json "$P"
check "unowned sentinel from ops-task blocks a foreign session" "$([ "$HRC" -eq 2 ] && echo 0 || echo 1)"
rm -rf "$P"

########################################################################
echo "-- Case 10: writer ownership gate + ops-adopt"
# INVARIANT (spec §4.1 criterion 3): B never gains the ability to close A's row.
# Closing a row you did not perform is the exact failure the evidence gate
# exists to prevent — so the writer refuses it, it is not merely discouraged.
P="$(newproj)"; ( cd "$P" && bash "$INIT" >/dev/null 2>&1 )
( cd "$P" && bash "$TASK" T-A --owner SESS-A >/dev/null 2>&1 )
ROWS_BEFORE="$(wc -l < "$P/.operator/VERDICTS.md")"
( cd "$P" && bash "$VERDICT" T-A "crit" "evidence" PASS --owner SESS-B >/dev/null 2>&1 ); XRC=$?
check "foreign --owner → verdict refused" "$([ "$XRC" -ne 0 ] && echo 0 || echo 1)"
check "foreign --owner → no row, sentinel intact" "$([ "$(wc -l < "$P/.operator/VERDICTS.md")" = "$ROWS_BEFORE" ] && [ -e "$P/.operator/pending/T-A" ] && echo 0 || echo 1)"
( cd "$P" && bash "$VERDICT" T-A --defer "not mine" --owner SESS-B >/dev/null 2>&1 ); DXRC=$?
check "foreign --owner → --defer also refused" "$([ "$DXRC" -ne 0 ] && [ -e "$P/.operator/pending/T-A" ] && echo 0 || echo 1)"
# the owner itself closes fine
( cd "$P" && bash "$VERDICT" T-A "crit" "evidence" PASS --owner SESS-A >/dev/null 2>&1 ); ORC=$?
check "matching --owner → verdict accepted" "$([ "$ORC" -eq 0 ] && [ ! -e "$P/.operator/pending/T-A" ] && echo 0 || echo 1)"
# missing --owner warns but proceeds (a /clear'd session must still close its work)
( cd "$P" && bash "$TASK" T-W --owner SESS-A >/dev/null 2>&1 )
WOUT="$( cd "$P" && bash "$VERDICT" T-W "crit" "evidence" PASS 2>&1 )"; WRC=$?
check "missing --owner → warns but proceeds" "$([ "$WRC" -eq 0 ] && printf '%s' "$WOUT" | grep -qi 'warning' && echo 0 || echo 1)"
# adopt: the /clear recovery path
( cd "$P" && bash "$TASK" T-C --owner SESS-A >/dev/null 2>&1 )
( cd "$P" && bash "$ADOPT" --owner SESS-B T-C >/dev/null 2>&1 ); ARC=$?
check "ops-adopt exits 0 and re-stamps the owner" "$([ "$ARC" -eq 0 ] && grep -q '^session_id: SESS-B$' "$P/.operator/pending/T-C" && echo 0 || echo 1)"
check "ops-adopt preserves opened_at" "$(grep -q '^opened_at: ' "$P/.operator/pending/T-C" && echo 0 || echo 1)"
run_hook stop-session-b.json "$P"
check "after adopt, the new owner is blocked" "$([ "$HRC" -eq 2 ] && echo 0 || echo 1)"
( cd "$P" && bash "$VERDICT" T-C "crit" "evidence" PASS --owner SESS-B >/dev/null 2>&1 ); CRC=$?
check "after adopt, the new owner can close" "$([ "$CRC" -eq 0 ] && echo 0 || echo 1)"
# adopt guards: traversal / pipe / bulk / unknown id
echo victim > "$P/victim.txt"
( cd "$P" && bash "$ADOPT" --owner SESS-B "../../victim.txt" >/dev/null 2>&1 ); TVRC=$?
check "ops-adopt refuses a traversal task-id" "$([ "$TVRC" -ne 0 ] && [ -f "$P/victim.txt" ] && echo 0 || echo 1)"
( cd "$P" && bash "$ADOPT" --owner "a|b" T-C >/dev/null 2>&1 ); PVRC=$?
check "ops-adopt refuses '|' in --owner" "$([ "$PVRC" -ne 0 ] && echo 0 || echo 1)"
( cd "$P" && bash "$ADOPT" --owner SESS-B >/dev/null 2>&1 ); BLRC=$?
check "ops-adopt refuses a bulk adopt (no ids)" "$([ "$BLRC" -ne 0 ] && echo 0 || echo 1)"
( cd "$P" && bash "$ADOPT" --owner SESS-B T-NOPE >/dev/null 2>&1 ); NORC=$?
check "ops-adopt refuses an id with no open sentinel" "$([ "$NORC" -ne 0 ] && echo 0 || echo 1)"
( cd "$P" && bash "$TASK" T-T --owner "a/b" >/dev/null 2>&1 ); OTRC=$?
check "ops-task refuses '/' in --owner" "$([ "$OTRC" -ne 0 ] && echo 0 || echo 1)"
# re-opening an open task never silently takes it over
( cd "$P" && bash "$TASK" T-R --owner SESS-A >/dev/null 2>&1 )
( cd "$P" && bash "$TASK" T-R --owner SESS-B >/dev/null 2>&1 )
check "re-open does not steal ownership" "$(grep -q '^session_id: SESS-A$' "$P/.operator/pending/T-R" && echo 0 || echo 1)"
rm -rf "$P"

########################################################################
echo "-- Case 11: concurrent appends never interleave; --reconcile repairs a merge"
# INVARIANT (spec §4.3 criterion 4): the file header claims append+clear is one
# atomic action. Before 0.4 that was a property of printf's buffer size, not a
# guarantee. Drive it: two shells racing, then assert the schema held for EVERY
# line — an interleaved write shows up as a row that fails the 4-cell match.
P="$(newproj)"; ( cd "$P" && bash "$INIT" >/dev/null 2>&1 )
N=50
racer() { # racer <tag>
  local tag="$1" i
  for i in $(seq 1 "$N"); do
    ( cd "$P" && bash "$VERDICT" "T-$tag-$i" "criterion $tag $i" "evidence $tag $i" PASS >/dev/null 2>&1 )
  done
}
racer A & RA=$!
racer B & RB=$!
wait "$RA" "$RB"
TOTAL=$((N * 2))
GOOD="$(grep -cE '^\| T-[AB]-[0-9]+ \| criterion [AB] [0-9]+ \| evidence [AB] [0-9]+ \| PASS \|$' "$P/.operator/VERDICTS.md" || true)"
ANYROW="$(grep -cE '^\| T-' "$P/.operator/VERDICTS.md" || true)"
check "concurrent: all $TOTAL rows present" "$([ "$ANYROW" = "$TOTAL" ] && echo 0 || echo 1)"
check "concurrent: every row matches the 4-cell schema (zero interleaving)" "$([ "$GOOD" = "$TOTAL" ] && echo 0 || echo 1)"
check "concurrent: lock dir released" "$([ ! -d "$P/.operator/.lock" ] && echo 0 || echo 1)"
# fragments mirror every row, so a mangled VERDICTS.md merge is recoverable
FRAG="$(cat "$P"/.operator/verdicts.d/*.md 2>/dev/null | grep -cE '^\| T-' || true)"
check "concurrent: fragments hold all $TOTAL rows" "$([ "$FRAG" = "$TOTAL" ] && echo 0 || echo 1)"
# simulate a botched merge: half the rows lost
grep -vE '^\| T-A-' "$P/.operator/VERDICTS.md" > "$P/v.tmp" && mv "$P/v.tmp" "$P/.operator/VERDICTS.md"
LOST="$(grep -cE '^\| T-' "$P/.operator/VERDICTS.md" || true)"
check "merge simulation: rows actually lost" "$([ "$LOST" = "$N" ] && echo 0 || echo 1)"
( cd "$P" && bash "$VERDICT" --reconcile >/dev/null 2>&1 ); RRC=$?
RESTORED="$(grep -cE '^\| T-' "$P/.operator/VERDICTS.md" || true)"
check "--reconcile exits 0 and restores every row" "$([ "$RRC" -eq 0 ] && [ "$RESTORED" = "$TOTAL" ] && echo 0 || echo 1)"
( cd "$P" && bash "$VERDICT" --reconcile >/dev/null 2>&1 )
AGAIN="$(grep -cE '^\| T-' "$P/.operator/VERDICTS.md" || true)"
check "--reconcile is idempotent (no duplicate rows)" "$([ "$AGAIN" = "$TOTAL" ] && echo 0 || echo 1)"
# --reconcile must REPAIR, never regenerate: hand-written BAR blocks survive
printf '\n### BAR: hand-written block\n- criterion: must survive reconcile\n' >> "$P/.operator/VERDICTS.md"
( cd "$P" && bash "$VERDICT" --reconcile >/dev/null 2>&1 )
check "--reconcile preserves hand-written BAR blocks" "$(grep -q 'BAR: hand-written block' "$P/.operator/VERDICTS.md" && echo 0 || echo 1)"
check "init writes .operator/.gitattributes (merge=union)" "$(grep -q 'VERDICTS.md merge=union' "$P/.operator/.gitattributes" && echo 0 || echo 1)"
# All THREE append-only paths need it, not just VERDICTS.md — a regression that
# dropped either of the others would silently reintroduce merge conflicts in the
# exact files this design makes conflict-free.
check "gitattributes covers DECISIONS.md" "$(grep -q 'DECISIONS.md merge=union' "$P/.operator/.gitattributes" && echo 0 || echo 1)"
check "gitattributes covers the fragments dir" "$(grep -q 'verdicts.d/\*.md merge=union' "$P/.operator/.gitattributes" && echo 0 || echo 1)"
# The schema assertions above are NOT discriminating on their own: a short
# printf usually lands atomically on a local FS even unlocked (that is the
# spec's point — it is a buffer-size property, not a guarantee). So prove the
# lock is genuinely held: take it by hand, and assert a writer waits for it.
( cd "$P" && bash "$TASK" T-LOCK --owner SESS-A >/dev/null 2>&1 )
mkdir "$P/.operator/.lock"
( cd "$P" && bash "$VERDICT" T-LOCK "crit" "locked-out" PASS >/dev/null 2>&1 ) &
LOCKPID=$!
sleep 1
check "held lock blocks a concurrent writer" "$(! grep -q 'locked-out' "$P/.operator/VERDICTS.md" && [ -e "$P/.operator/pending/T-LOCK" ] && echo 0 || echo 1)"
rmdir "$P/.operator/.lock"
wait "$LOCKPID" 2>/dev/null || true
check "releasing the lock lets the waiter through" "$(grep -q 'locked-out' "$P/.operator/VERDICTS.md" && [ ! -e "$P/.operator/pending/T-LOCK" ] && echo 0 || echo 1)"
# A stale lock must never cost a real verdict: after the spin budget the writer
# proceeds with a warning rather than failing.
( cd "$P" && bash "$TASK" T-STALE --owner SESS-A >/dev/null 2>&1 )
mkdir "$P/.operator/.lock"
SOUT="$( cd "$P" && bash "$VERDICT" T-STALE "crit" "stale-lock" PASS 2>&1 )"; SRC=$?
rmdir "$P/.operator/.lock" 2>/dev/null || true
check "stale lock → proceeds with a warning, verdict not lost" "$([ "$SRC" -eq 0 ] && printf '%s' "$SOUT" | grep -qi 'warning' && grep -q 'stale-lock' "$P/.operator/VERDICTS.md" && echo 0 || echo 1)"
rm -rf "$P"

########################################################################
echo "-- Case 12: name guards agree across all three CLIs; reconcile validates"
# INVARIANT: a sentinel the Stop hook cannot SEE is worse than no sentinel — it
# is an open task that never blocks. The hook enumerates pending/ with a plain
# glob, which does not match dotfiles, so a leading dot must be refused at every
# entry point. All three CLIs must agree: a guard enforced in one place only is
# the shape of the 2026-07-10 traversal bug.
P="$(newproj)"; ( cd "$P" && bash "$INIT" >/dev/null 2>&1 )
# the underlying fact this guard exists for
DOTDIR="$(newproj)"; : > "$DOTDIR/.hidden"; : > "$DOTDIR/visible"
# shellcheck disable=SC2034  # the loop var is unused on purpose: we count matches
shopt -s nullglob; GLOBN=0; for _f in "$DOTDIR"/*; do GLOBN=$((GLOBN+1)); done; shopt -u nullglob
check "premise: a plain glob does NOT see dotfiles" "$([ "$GLOBN" = "1" ] && echo 0 || echo 1)"
rm -rf "$DOTDIR"
( cd "$P" && bash "$TASK" ".hidden" --owner SESS-A >/dev/null 2>&1 ); T1=$?
check "ops-task refuses a dot-prefixed task-id" "$([ "$T1" -ne 0 ] && echo 0 || echo 1)"
( cd "$P" && bash "$VERDICT" ".hidden" crit ev PASS --owner SESS-A >/dev/null 2>&1 ); T2=$?
check "ops-verdict refuses a dot-prefixed task-id" "$([ "$T2" -ne 0 ] && echo 0 || echo 1)"
# NOTE: ops-adopt would also exit non-zero here for the unrelated reason "no
# such open task", so assert on the MESSAGE, not just the exit code — otherwise
# this passes against a build with no dot guard at all.
ADOUT="$( cd "$P" && bash "$ADOPT" --owner SESS-A ".hidden" 2>&1 )"; T3=$?
check "ops-adopt refuses a dot-prefixed task-id (by name, not by absence)" "$([ "$T3" -ne 0 ] && printf '%s' "$ADOUT" | grep -q "start with '\.'" && echo 0 || echo 1)"
check "no dotfile sentinel was created" "$([ ! -e "$P/.operator/pending/.hidden" ] && echo 0 || echo 1)"
# a dot-prefixed --owner would produce an invisible fragment file, same class
( cd "$P" && bash "$TASK" T-DOT --owner ".sneaky" >/dev/null 2>&1 ); T4=$?
check "ops-task refuses a dot-prefixed --owner" "$([ "$T4" -ne 0 ] && echo 0 || echo 1)"
# '.' and '..' stay refused — the leading-dot rule must SUBSUME the traversal
# guard, not replace it
echo victim > "$P/victim.txt"
( cd "$P" && bash "$VERDICT" ".." crit ev PASS >/dev/null 2>&1 ); DDRC=$?
check "'..' still refused (traversal guard intact)" "$([ "$DDRC" -ne 0 ] && [ -f "$P/victim.txt" ] && echo 0 || echo 1)"
# duplicate --owner is refused, never silently last-wins: a repeated flag means
# the caller is confused about ownership, the one thing this must not guess
( cd "$P" && bash "$TASK" T-DUP --owner SESS-A --owner SESS-B >/dev/null 2>&1 ); DUPRC=$?
check "ops-task refuses a repeated --owner" "$([ "$DUPRC" -ne 0 ] && [ ! -e "$P/.operator/pending/T-DUP" ] && echo 0 || echo 1)"
# same trap as above: assert the reason, not merely a non-zero exit
ADOUT2="$( cd "$P" && bash "$ADOPT" --owner SESS-A --owner SESS-B T-X 2>&1 )"; ADRC=$?
check "ops-adopt refuses a repeated --owner (by reason)" "$([ "$ADRC" -ne 0 ] && printf '%s' "$ADOUT2" | grep -q 'more than once' && echo 0 || echo 1)"
# --reconcile is a WRITE to the ledger of record: it must enforce the same
# 4-cell schema as the direct writer. A fragment is an ordinary file that a
# merge or hand-edit can corrupt.
( cd "$P" && bash "$TASK" T-OK --owner SESS-A >/dev/null 2>&1 )
( cd "$P" && bash "$VERDICT" T-OK "crit" "evidence" PASS --owner SESS-A >/dev/null 2>&1 )
printf 'not a valid row\n| broken | only | three |\n| T-INJ | c | e | MAYBE |\n' >> "$P/.operator/verdicts.d/SESS-A.md"
RB="$(wc -l < "$P/.operator/VERDICTS.md")"
ROUT="$( cd "$P" && bash "$VERDICT" --reconcile 2>&1 )"; RRC2=$?
check "--reconcile exits 0 despite corrupt fragment lines" "$([ "$RRC2" -eq 0 ] && echo 0 || echo 1)"
check "--reconcile refuses non-conformant lines (ledger unchanged)" "$([ "$(wc -l < "$P/.operator/VERDICTS.md")" = "$RB" ] && echo 0 || echo 1)"
check "--reconcile reports what it skipped" "$(printf '%s' "$ROUT" | grep -qi 'non-conformant' && echo 0 || echo 1)"
check "--reconcile did not inject the MAYBE verdict" "$(! grep -q 'T-INJ' "$P/.operator/VERDICTS.md" && echo 0 || echo 1)"
# A row with EXTRA cells is the case a glob-based check waves through: each `*`
# in '| '*' | '*' | '*' | PASS |' happily consumes ' | ' too, so a 5-cell row
# matched a "4-cell" pattern (found by Codex review). The check must COUNT.
RB2="$(wc -l < "$P/.operator/VERDICTS.md")"
printf '| a | b | c | injected | PASS |\n| a | b | c | d | e | f | FAIL |\n' >> "$P/.operator/verdicts.d/SESS-A.md"
( cd "$P" && bash "$VERDICT" --reconcile >/dev/null 2>&1 )
check "--reconcile refuses a 5-cell row (counts cells, not globs)" "$(! grep -q 'injected' "$P/.operator/VERDICTS.md" && echo 0 || echo 1)"
check "--reconcile refuses any over-celled row" "$([ "$(wc -l < "$P/.operator/VERDICTS.md")" = "$RB2" ] && echo 0 || echo 1)"
rm -rf "$P"

########################################################################
echo "-- Case 13: the sentinel BODY is untrusted input"
# INVARIANT: a sentinel is an ordinary file — a merge, a checkout, or a patch
# can supply its contents. The stamped owner becomes a fragment FILENAME, so an
# unvalidated one re-opens the 2026-07-10 traversal through a new door. Found in
# review of 0.4.0: `session_id: ../../../tmp/x` appended a real ledger row to
# /tmp/x.md. Every degenerate body must degrade to unowned, which fails CLOSED.
P="$(newproj)"; ( cd "$P" && bash "$INIT" >/dev/null 2>&1 )
# Escape exactly one level out of .operator/ — the invariant CLAUDE.md states
# ("must not reach outside .operator/"). Fragments are written to
# .operator/verdicts.d/, so '../../PWNED' lands in the project root. A deeper
# absolute-ish path would "pass" for the wrong reason (nonexistent intermediate
# dirs), which is exactly how a non-discriminating test looks.
printf 'session_id: ../../PWNED\n' > "$P/.operator/pending/T-EVIL"
( cd "$P" && bash "$VERDICT" T-EVIL "crit" "ev" PASS >/dev/null 2>&1 ) || true
check "traversal via sentinel body writes nothing outside .operator/" "$([ ! -e "$P/PWNED.md" ] && echo 0 || echo 1)"
check "traversal owner degrades to unowned (row still recorded inside)" "$([ -f "$P/.operator/verdicts.d/unowned.md" ] && echo 0 || echo 1)"
# CRLF: a checkout could normalize line endings. A trailing \r must NOT make a
# session's own task look foreign — that is a fail-OPEN in the core invariant.
rm -f "$P"/.operator/pending/*
printf 'session_id: SESS-A\r\ncwd: /x\n' > "$P/.operator/pending/T-CR"
run_hook stop-session-a.json "$P"
check "CRLF sentinel still blocks its OWN session (no fail-open)" "$([ "$HRC" -eq 2 ] && echo 0 || echo 1)"
( cd "$P" && bash "$VERDICT" T-CR "crit" "ev" PASS --owner SESS-A >/dev/null 2>&1 ); CRRC=$?
check "CRLF sentinel: the true owner can still close it" "$([ "$CRRC" -eq 0 ] && echo 0 || echo 1)"
# degenerate bodies → unowned → blocks everyone (fail closed)
for body in 'session_id: ' 'session_id: a|b' 'session_id: .hidden' 'garbage'; do
  rm -f "$P"/.operator/pending/*
  printf '%s\n' "$body" > "$P/.operator/pending/T-DEG"
  run_hook stop-session-b.json "$P"
  check "degenerate body [$body] fails CLOSED (exit 2)" "$([ "$HRC" -eq 2 ] && echo 0 || echo 1)"
done
# WHITESPACE in an owner is the subtlest disarm: the hook compares the stamped
# owner byte-for-byte against the payload session id, so " SESS-A" can never
# equal any real session — the task is FOREIGN forever, and foreign never
# blocks. Refused at the CLIs, and treated as unowned by the hook for sentinels
# that never went through them.
for o in " SESS-A" "SESS-A " "SE SS"; do
  ( cd "$P" && bash "$TASK" T-WS --owner "$o" >/dev/null 2>&1 ); WRC=$?
  check "ops-task refuses a whitespace --owner [$o]" "$([ "$WRC" -ne 0 ] && echo 0 || echo 1)"
done
( cd "$P" && bash "$ADOPT" --owner " X" T-WS >/dev/null 2>&1 ); AWRC=$?
check "ops-adopt refuses a whitespace --owner" "$([ "$AWRC" -ne 0 ] && echo 0 || echo 1)"
# ...but the whitespace rule is about OWNERS ONLY. It must NOT reach task ids:
# 0.3.0 accepted `release candidate`, so applying the owner rule to ids wedged
# such a task completely — the hook still blocked on the sentinel while every
# closing path refused the id, leaving the session unable to stop at all. That
# is the exact trap this release exists to remove. (Caught by Codex review.)
rm -f "$P"/.operator/pending/*
: > "$P/.operator/pending/release candidate"
run_hook stop-session-a.json "$P"
check "legacy spaced task-id still blocks (migration safety)" "$([ "$HRC" -eq 2 ] && echo 0 || echo 1)"
( cd "$P" && bash "$VERDICT" "release candidate" "crit" "ev" PASS >/dev/null 2>&1 ); LRC=$?
check "legacy spaced task-id can be CLOSED (not wedged)" "$([ "$LRC" -eq 0 ] && [ ! -e "$P/.operator/pending/release candidate" ] && echo 0 || echo 1)"
: > "$P/.operator/pending/legacy id 2"
( cd "$P" && bash "$ADOPT" --owner SESS-A "legacy id 2" >/dev/null 2>&1 ); LARC=$?
check "legacy spaced task-id can be ADOPTED" "$([ "$LARC" -eq 0 ] && echo 0 || echo 1)"
( cd "$P" && bash "$VERDICT" "legacy id 2" --defer "blocked" --owner SESS-A >/dev/null 2>&1 ); LDRC=$?
check "legacy spaced task-id can be DEFERRED" "$([ "$LDRC" -eq 0 ] && [ ! -e "$P/.operator/pending/legacy id 2" ] && echo 0 || echo 1)"
rm -f "$P"/.operator/pending/*
printf 'session_id:  SESS-A\ncwd: /x\n' > "$P/.operator/pending/T-WS2"
run_hook stop-session-a.json "$P"
check "hand-written whitespace owner is unowned → BLOCKS" "$([ "$HRC" -eq 2 ] && echo 0 || echo 1)"
# A payload that fails to parse must not fail open SILENTLY — json_get swallows
# parser errors, so every field reads empty and looks like "no cwd".
rm -f "$P"/.operator/pending/*; : > "$P/.operator/pending/T-J"
errf="$(mktemp)"; printf '{"cwd": broken json' | "$BASH_ABS" "$HOOK" 2>"$errf"; JRC=$?
JERR="$(cat "$errf")"; rm -f "$errf"
check "corrupt payload still exits 0 (fail-open preserved)" "$([ "$JRC" -eq 0 ] && echo 0 || echo 1)"
check "corrupt payload warns instead of failing open silently" "$(printf '%s' "$JERR" | grep -qi 'unparseable' && echo 0 || echo 1)"
# an empty payload is NOT corrupt — it must stay silent
errf="$(mktemp)"; printf '' | "$BASH_ABS" "$HOOK" 2>"$errf"; ERC=$?
EERR="$(cat "$errf")"; rm -f "$errf"
check "empty payload stays silent (no false warning)" "$([ "$ERC" -eq 0 ] && [ -z "$EERR" ] && echo 0 || echo 1)"
# a directory in pending/ must not be read as a sentinel nor emit a raw error
rm -rf "$P"/.operator/pending/*
mkdir -p "$P/.operator/pending/T-DIR"
run_hook stop-session-a.json "$P"
check "a directory in pending/ emits no raw bash read error" "$(! printf '%s' "$HERR" | grep -qi 'read error' && echo 0 || echo 1)"
rm -rf "$P/.operator/pending/T-DIR"
# an unbounded sentinel must not stall every session's turn-end
rm -f "$P"/.operator/pending/*
{ i=0; while [ "$i" -lt 60000 ]; do printf 'filler line\n'; i=$((i+1)); done; } > "$P/.operator/pending/T-BIG"
SECS_START=$(date +%s)
run_hook stop-session-a.json "$P"
SECS_END=$(date +%s)
check "huge sentinel parsed in bounded time (<5s)" "$([ "$((SECS_END - SECS_START))" -lt 5 ] && echo 0 || echo 1)"
check "huge sentinel (no owner line) still blocks" "$([ "$HRC" -eq 2 ] && echo 0 || echo 1)"
rm -rf "$P"

########################################################################
echo "-- Case 14: adopt is crash-safe and cannot resurrect a closed task"
# The temp file must live OUTSIDE pending/: the Stop hook globs that directory
# and treats every entry as a task id, so a crashed adopt would leave a phantom
# pending task that blocks the session and can be closed as a garbage row.
P="$(newproj)"; ( cd "$P" && bash "$INIT" >/dev/null 2>&1 )
( cd "$P" && bash "$TASK" T-A --owner SESS-A >/dev/null 2>&1 )
( cd "$P" && bash "$ADOPT" --owner SESS-B T-A >/dev/null 2>&1 )
PENDN=0
shopt -s nullglob; for _f in "$P"/.operator/pending/*; do PENDN=$((PENDN+1)); done; shopt -u nullglob
check "adopt leaves exactly one file in pending/ (no temp residue)" "$([ "$PENDN" = "1" ] && echo 0 || echo 1)"
ADOPT_RESIDUE=0
shopt -s nullglob; for _f in "$P"/.operator/pending/*adopt*; do ADOPT_RESIDUE=1; done; shopt -u nullglob
check "adopt leaves no .adopt temp inside pending/" "$([ "$ADOPT_RESIDUE" = "0" ] && echo 0 || echo 1)"
# a stale temp from a crashed adopt must not read as a pending task
: > "$P/.operator/.adopt.9999.T-A"
run_hook stop-session-b.json "$P"
check "a crashed adopt's temp is not a phantom pending task" "$(! printf '%s' "$HERR" | grep -q 'adopt' && echo 0 || echo 1)"
rm -f "$P/.operator/.adopt.9999.T-A"
rm -rf "$P"

########################################################################
echo "-- Case 15: ownership transitions are atomic under concurrency"
# INVARIANT: "re-open never takes over" and "B cannot close A's task" must hold
# under a RACE, not just sequentially. Both were TOCTOU before this: ops-task
# did test-then-truncate (two openers both won: 155/200 trials), and
# ops-verdict read the owner BEFORE taking the lock, so an adopt landing in
# between let the former owner delete the new owner's sentinel. Found by Codex
# review. These loops are the only assertions that would catch a regression —
# a sequential test passes on the racy code.
P="$(newproj)"; ( cd "$P" && bash "$INIT" >/dev/null 2>&1 )
BOTH=0
for _i in $(seq 1 40); do
  rm -f "$P/.operator/pending/T-RACE"
  OUT="$( ( cd "$P" && bash "$TASK" T-RACE --owner SESS-A 2>&1 ) & \
          ( cd "$P" && bash "$TASK" T-RACE --owner SESS-B 2>&1 ) & wait )"
  [ "$(printf '%s\n' "$OUT" | grep -c '^opened ')" -gt 1 ] && BOTH=$((BOTH+1))
done
check "concurrent open: exactly one winner every time (no takeover)" "$([ "$BOTH" = "0" ] && echo 0 || echo 1)"
# and the survivor is always a well-formed, owned sentinel — never a truncated
# or interleaved one from two writers hitting the same file
rm -f "$P/.operator/pending/T-RACE"
( cd "$P" && bash "$TASK" T-RACE --owner SESS-A >/dev/null 2>&1 ) & \
( cd "$P" && bash "$TASK" T-RACE --owner SESS-B >/dev/null 2>&1 ) & wait
OWNLINES="$(grep -c '^session_id: ' "$P/.operator/pending/T-RACE" 2>/dev/null || true)"
check "concurrent open: sentinel has exactly one owner line" "$([ "$OWNLINES" = "1" ] && echo 0 || echo 1)"

# adopt vs verdict: whoever wins the lock, the loser must not damage the ledger.
# HONESTY NOTE: unlike the open-race above (which fails ~155/200 on the unfixed
# code), this assertion does NOT reliably reproduce the unfixed race — the
# window between reading the owner and clearing the sentinel is microseconds, so
# it passes on the racy code too. It is a regression GUARD, not evidence the
# race existed; the evidence is the code path (owner read outside the lock,
# Codex review). Do not read a green here as proof of serialization.
STOLEN=0
for _i in $(seq 1 25); do
  rm -f "$P/.operator/pending/T-AV"
  ( cd "$P" && bash "$TASK" T-AV --owner SESS-A >/dev/null 2>&1 )
  ( cd "$P" && bash "$VERDICT" T-AV crit ev PASS --owner SESS-A >/dev/null 2>&1 ) & \
  ( cd "$P" && bash "$ADOPT" --owner SESS-B T-AV >/dev/null 2>&1 ) & wait
  # Legal outcomes: verdict won (sentinel gone, row exists) OR adopt won
  # (sentinel present, owned by B). Illegal: sentinel gone AND owned by B —
  # A deleted the sentinel B had just taken.
  if [ ! -e "$P/.operator/pending/T-AV" ] && [ -f "$P/.operator/verdicts.d/SESS-B.md" ]; then
    STOLEN=$((STOLEN+1))
  fi
done
check "adopt vs verdict: no session clears another's adopted sentinel" "$([ "$STOLEN" = "0" ] && echo 0 || echo 1)"
check "adopt vs verdict: lock released after the race" "$([ ! -d "$P/.operator/.lock" ] && echo 0 || echo 1)"

# Stale-lock RECLAIM must itself be exclusive. The naive `rmdir + mkdir` lets a
# second waiter delete the first waiter's FRESH lock and enter alongside it —
# two writers in the critical section, neither over budget (found by Codex
# review). The guard is a `.lock.reclaim` claim marker: only its creator may
# touch the stale lock. Assert the protocol directly rather than waiting out a
# 30s budget: with the claim already held, a writer must NOT reclaim.
#
# HONESTY NOTE: these three do NOT fail against the pre-fix code — the naive
# reclaim also waits here, because the stale .lock still blocks its mkdir. They
# assert the claim marker is used and cleaned up, not that the two-waiter race
# is closed; reproducing that needs two writers both timing out at 30s. The
# evidence for the race is the code path, not this test.
mkdir -p "$P/.operator/.lock" "$P/.operator/.lock.reclaim"
( cd "$P" && bash "$TASK" T-RC --owner SESS-A >/dev/null 2>&1 )
( cd "$P" && bash "$VERDICT" T-RC crit ev PASS --owner SESS-A >/dev/null 2>&1 ) &
RCPID=$!
sleep 2
check "a held reclaim-claim blocks another writer from reclaiming" "$([ -d "$P/.operator/.lock" ] && [ -e "$P/.operator/pending/T-RC" ] && echo 0 || echo 1)"
rmdir "$P/.operator/.lock.reclaim" "$P/.operator/.lock" 2>/dev/null || true
wait "$RCPID" 2>/dev/null || true
check "writer proceeds once the stale lock is gone" "$([ ! -e "$P/.operator/pending/T-RC" ] && echo 0 || echo 1)"
check "reclaim marker is not left behind" "$([ ! -d "$P/.operator/.lock.reclaim" ] && echo 0 || echo 1)"
rm -rf "$P"

########################################################################
echo "-- Case 16: bounded reads and an abandoned reclaim claim"
# A claim marker with no expiry is a deadlock with extra steps: the first
# version of the reclaim fix deferred to `.lock.reclaim` indefinitely, so a
# process killed between creating and removing it wedged every later writer
# FOREVER — strictly worse than the stale lock it replaced, which at least
# proceeded after one budget. (Found by Codex review; measured: still running
# after 45s, now bounded.) This test is slow by nature — it must outlast a real
# budget — so it asserts the OUTCOME, not the timing.
P="$(newproj)"; ( cd "$P" && bash "$INIT" >/dev/null 2>&1 )
mkdir -p "$P/.operator/.lock" "$P/.operator/.lock.reclaim"
( cd "$P" && bash "$TASK" T-AB --owner SESS-A >/dev/null 2>&1 )
# Run under a polled watchdog: against the UNFIXED code this never returns, and
# an unbounded wait here would hang CI instead of reporting a failure. No
# `timeout(1)` — macOS does not ship one.
( cd "$P" && bash "$VERDICT" T-AB crit ev PASS --owner SESS-A >/dev/null 2>&1 ) &
ABPID=$!
ABRC=1; waited=0
while [ "$waited" -lt 120 ]; do
  if ! kill -0 "$ABPID" 2>/dev/null; then wait "$ABPID" 2>/dev/null; ABRC=$?; break; fi
  sleep 2; waited=$((waited + 2))
done
if kill -0 "$ABPID" 2>/dev/null; then kill -9 "$ABPID" 2>/dev/null; ABRC=99; fi
check "abandoned reclaim claim recovers (does not wedge forever)" "$([ "$ABRC" -eq 0 ] && echo 0 || echo 1)"
check "abandoned claim: verdict actually recorded" "$(grep -Fq '| T-AB | crit | ev | PASS |' "$P/.operator/VERDICTS.md" && [ ! -e "$P/.operator/pending/T-AB" ] && echo 0 || echo 1)"
check "abandoned claim: no lock or marker left behind" "$([ ! -d "$P/.operator/.lock" ] && [ ! -d "$P/.operator/.lock.reclaim" ] && echo 0 || echo 1)"

# A LINE cap is not a BYTE cap: one newline-less line is a single "line" and
# `read -r` slurps all of it before any counter runs (256 MB measured at 8.5s,
# on EVERY session's Stop event). `read -r -n N` stops at N chars or the
# newline, whichever comes first.
#
# This also guards a regression I caused while fixing it: switching to `read -N`
# (capital) returned an empty chunk, so EVERY sentinel parsed as unowned and
# every session blocked on every task. The whole suite stayed green — nothing
# asserted the partition on a NORMAL sentinel via the real parser. It does now.
rm -f "$P"/.operator/pending/*
( cd "$P" && bash "$TASK" T-OWN --owner SESS-A >/dev/null 2>&1 )
run_hook stop-session-a.json "$P"
check "parser regression guard: owner still blocks its own task" "$([ "$HRC" -eq 2 ] && echo 0 || echo 1)"
run_hook stop-session-b.json "$P"
check "parser regression guard: foreign session still allowed" "$([ "$HRC" -eq 0 ] && echo 0 || echo 1)"
rm -f "$P"/.operator/pending/*
# 32 MB on one line. HONESTY NOTE: at this size the unfixed hook takes ~1s, so
# this assertion does NOT discriminate — the cost is linear (256 MB measured at
# 8.5s unfixed vs 0.16s fixed) and a test big enough to separate them would put
# a quarter-gig of writes in CI. It guards the parse staying bounded and, more
# importantly, that the bounded read still returns the right verdict.
{ i=0; while [ "$i" -lt 32 ]; do printf '%1048576s' '' | tr ' ' 'x'; i=$((i+1)); done; } > "$P/.operator/pending/T-LONG"
SEC0=$(date +%s)
run_hook stop-session-a.json "$P"
SEC1=$(date +%s)
check "one-huge-line sentinel parsed in bounded time (<3s)" "$([ "$((SEC1 - SEC0))" -lt 3 ] && echo 0 || echo 1)"
check "one-huge-line sentinel is unowned → still BLOCKS" "$([ "$HRC" -eq 2 ] && echo 0 || echo 1)"
rm -rf "$P"

########################################################################
echo "== summary: $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]
