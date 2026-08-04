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
CLAIMS="$SCRIPTS/ops-claims.sh"
SSHOOK="$SCRIPTS/ops-sessionstart-hook.sh"

# Absolute bash so a restricted PATH (case 5) governs only the hook's INTERNAL
# command lookups (jq/python3), not the launch of bash itself.
BASH_ABS="$(command -v bash)"
# The OLDEST bash on the box, for cases whose bug only exists there. This suite
# otherwise runs whatever `command -v bash` finds — on macOS a Homebrew 5.x —
# while the shipped scripts use `#!/usr/bin/env bash` and this repo explicitly
# targets bash 3.2 (ops-tiers.sh, ops-render.sh, ops-adopt.sh all say so). That
# gap is not hypothetical: F46 (a NUL-padded sentinel/config smuggling an owner
# past the length guard) is EXPLOITABLE on 3.2 and IMPOSSIBLE on 5.3, so the
# whole suite was green while system bash was vulnerable. Cases marked with
# BASH_OLD run against /bin/bash when it is older, and fall back otherwise.
BASH_OLD="$BASH_ABS"
if [ -x /bin/bash ]; then
  # shellcheck disable=SC2016  # ${BASH_VERSINFO} must be expanded by the CHILD
  # bash being probed, not by this one — that is the entire point of the probe.
  _obv="$(/bin/bash -c 'echo ${BASH_VERSINFO[0]}' 2>/dev/null || echo 9)"
  # shellcheck disable=SC2016
  _nbv="$("$BASH_ABS" -c 'echo ${BASH_VERSINFO[0]}' 2>/dev/null || echo 9)"
  [ "$_obv" -lt "$_nbv" ] && BASH_OLD=/bin/bash
fi

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

echo "-- Case: ops-task does not claim a non-regular entry in pending/ is 'already open'"
# A directory or dangling symlink in pending/ is not a task sentinel. The
# opener's `>` redirection fails on it for a reason OTHER than O_EXCL/EEXIST,
# but the old else-branch conflated every failure with "already open" and
# exited 0 — while the Stop hook's `-f` guard refuses to count the entry, so
# the session stopped with a task the operator believed was tracked. Two
# components disagreeing about what counts as a task, failing OPEN: the
# whole gate silently off (P1, found by the review-panel pilot 2026-07-29).
# The fix distinguishes "a regular file already exists" (legit already-open,
# ownership unchanged) from "the target is non-regular or unwritable" (a
# fault: refuse, exit non-zero, and do NOT claim ownership is unchanged).
P2="$(newproj)"; ( cd "$P2" && bash "$INIT" >/dev/null 2>&1 )
# directory: the open must fail, not silently report "already open"
mkdir -p "$P2/.operator/pending/T-DIR"
( cd "$P2" && ./.operator/bin/ops-task.sh T-DIR --owner SESS-A >/dev/null 2>&1 ); DRC=$?
check "ops-task refuses to open over a directory (non-zero exit)" "$([ "$DRC" -ne 0 ] && echo 0 || echo 1)"
( cd "$P2" && ./.operator/bin/ops-task.sh T-DIR --owner SESS-A 2>&1 ) | grep -qi "already open" && echo "FAIL: ops-task falsely reports a directory as already open" >&2
check "ops-task does not claim a directory is 'already open'" "$([ "$DRC" -ne 0 ] && echo 0 || echo 1)"
# dangling symlink: same — the redirection fails (cannot overwrite existing
# file, because the symlink target exists nowhere to write through), and the
# old code reported it as already-open + exit 0
ln -s /nonexistent "$P2/.operator/pending/T-DEAD"
( cd "$P2" && ./.operator/bin/ops-task.sh T-DEAD --owner SESS-A >/dev/null 2>&1 ); LRC=$?
check "ops-task refuses to open over a dangling symlink (non-zero exit)" "$([ "$LRC" -ne 0 ] && echo 0 || echo 1)"
# symlink TO A REGULAR FILE (Copilot 2026-08-03, final review): unlike the
# dangling case, `-f` FOLLOWS this symlink and reads TRUE, so the old guard
# reported it as "already open" and exited 0 — presenting a planted entry as
# live tracked work. (mv/rename(2) replaces a destination symlink itself and
# never touches its target — measured 2026-08-04 — so the exposure is the
# laundering, not a data overwrite.) A symlink is never a sentinel we wrote;
# `-L` must reject it.
_TGT="$(mktemp "${TMPDIR:-/tmp}/opstest-symlink.XXXXXX")"
printf 'session_id: attacker\n' > "$_TGT"
ln -s "$_TGT" "$P2/.operator/pending/T-LIVE"
( cd "$P2" && ./.operator/bin/ops-task.sh T-LIVE --owner SESS-A >/dev/null 2>&1 ); SLRC=$?
( cd "$P2" && ./.operator/bin/ops-task.sh T-LIVE --owner SESS-A 2>&1 ) | grep -qi "already open" && echo "FAIL: ops-task falsely reports a symlink-to-regular as already open" >&2
check "ops-task refuses a symlink-to-regular as 'already open' (non-zero exit, -L guard)" \
  "$([ "$SLRC" -ne 0 ] && echo 0 || echo 1)"
# and the link target must be UNTOUCHED — no write leaked through the symlink
check "the symlink's outside target was not overwritten by the refusal" \
  "$([ "$(cat "$_TGT")" = "session_id: attacker" ] && echo 0 || echo 1)"
rm -f "$_TGT"
# a legit already-open task (a real sentinel file) must STILL report already
# open and exit 0 — the fix must not break the genuine O_EXCL path
( cd "$P2" && ./.operator/bin/ops-task.sh T-REAL --owner SESS-A >/dev/null 2>&1 )
( cd "$P2" && ./.operator/bin/ops-task.sh T-REAL --owner SESS-B 2>&1 ); RRC=$?; ROUT=$?
check "ops-task still reports a real sentinel as already open (exit 0)" "$([ "$RRC" -eq 0 ] && echo 0 || echo 1)"
rm -rf "$P2"

# pre-0.3 project (no bin/): block message falls back to the plugin's absolute copy
rm -rf "$P/.operator/bin"
: > "$P/.operator/pending/T-8"
run_hook stop-basic.json "$P"
check "no bin/: block message falls back to plugin-root absolute path" "$(printf '%s' "$HERR" | grep -q "$SCRIPTS/ops-verdict.sh" && echo 0 || echo 1)"
rm -rf "$P"

########################################################################
echo "-- Case: a planted symlink sentinel is rejected by every reader"
# The F65 -L guard first landed in ops-task.sh's opener only — the write site.
# Every READ site kept plain `-f`, which FOLLOWS symlinks, so a symlink planted
# in pending/ (malicious checkout, hostile merge) was accepted as a real
# sentinel everywhere downstream: ops-adopt.sh adopted it and its rewrite
# LAUNDERED it into a genuine regular-file sentinel the whole gate then
# trusts; ops-verdict.sh closed it into VERDICTS.md as if the task had gone
# through the O_EXCL create; the Stop hook and statusline read its target's
# `session_id:` and, on a foreign id, waved the stop through / rendered it
# foreign (code-review of f4cae1a, 2026-08-04). The rule, applied per
# PLAYBOOK: a symlink is never a sentinel our CLIs wrote. Parsers degrade it
# to "" = unowned = BLOCKS (fail closed); mutating CLIs refuse loudly.
P="$(newproj)"; ( cd "$P" && bash "$INIT" >/dev/null 2>&1 )
_SYT="$(mktemp "${TMPDIR:-/tmp}/opstest-symtgt.XXXXXX")"
printf 'session_id: SESS-A\nopened_at: 2026-08-04T00:00:00Z\n' > "$_SYT"
ln -s "$_SYT" "$P/.operator/pending/T-SYM"
# adopt: must refuse, leave the symlink a symlink, and not touch the target
( cd "$P" && bash "$ADOPT" --owner SESS-NEW T-SYM >/dev/null 2>&1 ); SYARC=$?
check "adopt refuses a symlink sentinel (non-zero exit)" "$([ "$SYARC" -ne 0 ] && echo 0 || echo 1)"
check "adopt did not launder the symlink into a regular sentinel" "$([ -L "$P/.operator/pending/T-SYM" ] && echo 0 || echo 1)"
check "adopt left the symlink's target untouched" "$([ "$(head -1 "$_SYT")" = "session_id: SESS-A" ] && echo 0 || echo 1)"
# verdict: must refuse — no ledger row, sentinel not cleared
SYROWS0="$(wc -l < "$P/.operator/VERDICTS.md")"
( cd "$P" && bash "$VERDICT" T-SYM crit ev PASS --owner SESS-A >/dev/null 2>&1 ); SYVRC=$?
check "verdict refuses to close a symlink sentinel (non-zero exit)" "$([ "$SYVRC" -ne 0 ] && echo 0 || echo 1)"
check "no ledger row was written for the symlink sentinel" "$([ "$(wc -l < "$P/.operator/VERDICTS.md")" -eq "$SYROWS0" ] && echo 0 || echo 1)"
check "verdict did not clear the symlink sentinel" "$([ -L "$P/.operator/pending/T-SYM" ] && echo 0 || echo 1)"
# defer: same refusal — it also clears sentinels
( cd "$P" && bash "$VERDICT" T-SYM --defer "why" --owner SESS-A >/dev/null 2>&1 ); SYDRC=$?
check "defer refuses a symlink sentinel (non-zero exit)" "$([ "$SYDRC" -ne 0 ] && echo 0 || echo 1)"
# Stop hook: the target says SESS-A, but a symlink is not a claim of ownership
# — it must read as UNOWNED, which blocks EVERY session (the same fail-closed
# direction as a malformed body), never as SESS-A's foreign task.
run_hook stop-session-b.json "$P"
check "Stop hook blocks a bystander on a symlink sentinel (unowned, exit 2)" "$([ "$HRC" -eq 2 ] && echo 0 || echo 1)"
check "Stop hook does not attribute the symlink to the target's owner" "$(printf '%s' "$HERR" | grep -q 'owned by SESS-A' && echo 1 || echo 0)"
# statusline: same partition — unowned counts as MINE-blocking, never foreign
SYSL="$(printf '{"session_id":"SESS-B","cwd":"%s","workspace":{"project_dir":"%s"}}' "$P" "$P" \
  | "$BASH_ABS" "$SCRIPTS/statusline.sh" 2>/dev/null | LC_ALL=C tr -d '\033' | LC_ALL=C sed 's/\[[0-9]*m//g')"
check "statusline counts a symlink sentinel as blocking, not foreign" "$([ "$SYSL" = "op[1]" ] && echo 0 || echo 1)"
rm -f "$_SYT"; rm -rf "$P"

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
# SessionStart ensures the compressor ephemera are git-ignored: a target project
# whose .operator/.gitignore predates the compressor would otherwise show
# .compress-spill/ as dirty state the moment the PostToolUse compressor fires
# (user-reported 2026-08-04). The hook appends the lines idempotently.
GIP="$(newproj)"; ( cd "$GIP" && bash "$INIT" >/dev/null 2>&1 )
# Strip the compressor lines to simulate a pre-compressor gitignore.
printf '# legacy\n.lock/\n' > "$GIP/.operator/.gitignore"
sed "s|<tmp>|$GIP|" "$FIXTURES/sessionstart.json" | "$BASH_ABS" "$SSHOOK" >/dev/null 2>&1
check "sessionstart ensures .compress-spill/ is git-ignored" \
  "$(grep -q '^\.compress-spill/$' "$GIP/.operator/.gitignore" && echo 0 || echo 1)"
check "sessionstart ensures .compress-state/ is git-ignored" \
  "$(grep -q '^\.compress-state/$' "$GIP/.operator/.gitignore" && echo 0 || echo 1)"
# Idempotent: a second fire does not duplicate the block.
sed "s|<tmp>|$GIP|" "$FIXTURES/sessionstart.json" | "$BASH_ABS" "$SSHOOK" >/dev/null 2>&1
check "sessionstart gitignore-ensure is idempotent (no duplicate block)" \
  "$( [ "$(grep -c '^\.compress-spill/$' "$GIP/.operator/.gitignore")" = 1 ] && echo 0 || echo 1)"
rm -rf "$Q" "$P" "$GIP"

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
# TRUNCATION-RECLASSIFICATION: a sentinel body is ONE physical line of padding
# followed by `session_id: EVIL`. `read -n 512` truncates mid-line and the tail
# arrives next iteration as a fresh "line", matched on its own — so an unowned
# sentinel (blocks) reads as FOREIGN (waves the stop through). That is the
# fail-OPEN inversion PLAYBOOK step 2 forbids, reached without our CLIs ever
# writing the file. Two vectors: filling the 512 cap, and a NUL (bash 3.2's
# `read -n` stops AT one, so the padding need not reach 512 — and ${#line}
# cannot see it, because bash drops NULs from variables entirely).
for vec in pad512 nulpad latenul; do
  rm -f "$P"/.operator/pending/*
  if [ "$vec" = pad512 ]; then
    python3 -c "import sys; open(sys.argv[1],'wb').write(b'x'*512+b'session_id: EVIL\\n')" "$P/.operator/pending/T-SMUG"
  elif [ "$vec" = nulpad ]; then
    python3 -c "import sys; open(sys.argv[1],'wb').write(b'x'+b'\\0'*100+b'x'*411+b'session_id: EVIL\\n')" "$P/.operator/pending/T-SMUG"
  else
    # latenul: the NUL sits PAST byte 512 with every physical line under the cap,
    # so the single-shot 512-byte probe missed it and the sub-cap lines slipped
    # the pad512 guard too — the full-PR panel's score-92 exploit (owner=EVIL,
    # exit 0 on bash 3.2). The fix loops the probe over the whole file.
    python3 -c "import sys; open(sys.argv[1],'wb').write(b'\\n'.join(b'p'*100 for _ in range(6))+b'\\n'+b'q'*50+b'\\0'+b'r'*50+b'\\nsession_id: EVIL\\n')" "$P/.operator/pending/T-SMUG"
  fi
  # Under the OLDEST bash: the nul vectors only exist there (F46).
  printf '{"session_id":"SESS-B","cwd":"%s"}' "$P" | "$BASH_OLD" "$HOOK" >/dev/null 2>&1; SMRC=$?
  check "a one-line [$vec] sentinel cannot smuggle an owner — fails CLOSED (exit 2)" \
    "$([ "$SMRC" -eq 2 ] && echo 0 || echo 1)"

  # NOTE on the writer parsers (ops-verdict, ops-adopt): they carry the same
  # F45/F46 guard, but it is BELT-AND-BRACES there, not load-bearing. A smuggled
  # `session_id: ../../PWNED` parsed from the body reaches FRAG_OWNER only when
  # no --owner is given — but check_bare_name (run on every owner before it
  # becomes a fragment FILENAME) already refuses '/', so the traversal is
  # blocked by an existing, proven guard regardless of F45/F46. Disabling the
  # verdict F45 guard leaves the smuggle blocked (verified 2026-08-03), so a
  # case asserting it would be vacuous — it passes with the guard off. The
  # stop-hook reader above is where the guard IS load-bearing: it has no
  # downstream bare-name check, so the smuggle reaches the mine/foreign
  # partition directly. (pr-review test-coverage finding #3.)
done
# The guard must not break the path it sits on: a GENUINE foreign sentinel is
# still reported and still non-blocking.
rm -f "$P"/.operator/pending/*
printf 'session_id: OTHER\ncwd: /x\nopened_at: 2026-08-02T00:00:00Z\n' > "$P/.operator/pending/T-FGN"
run_hook stop-session-a.json "$P"
check "a genuine foreign sentinel still does NOT block (guard did not overreach)" \
  "$([ "$HRC" -eq 0 ] && echo 0 || echo 1)"

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
#
# Tiny budget via the env seam (audit F08): the abandoned-claim path pays
# LOCK_SPINS + the defers. on the real 30s/5s budgets this case alone ran >60s.
# The OUTCOME under test (recovers, does not wedge; verdict recorded; nothing
# left behind) is unchanged at a tiny budget.
#
# RECLAIM_WAIT must be set < LOCK_SPINS — the backoff `i=$((LOCK_SPINS-RECLAIM_WAIT))`
# goes non-positive otherwise and each defer pays the full RECLAIM_WAIT (review
# F-C: LOCK_SPINS=10 with the default RECLAIM_WAIT=50 took ~20s, not ~1s, and the
# validator now rejects that combo anyway). Both set tiny; the guard requires
# RECLAIM_WAIT < LOCK_SPINS.
LOCK_SPINS=10 RECLAIM_WAIT=2 \
  bash -c 'cd "$0" && bash "$1" T-AB crit ev PASS --owner SESS-A >/dev/null 2>&1' \
  "$P" "$VERDICT" &
ABPID=$!
ABRC=1; waited=0
while [ "$waited" -lt 20 ]; do
  if ! kill -0 "$ABPID" 2>/dev/null; then wait "$ABPID" 2>/dev/null; ABRC=$?; break; fi
  sleep 1; waited=$((waited + 1))
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
echo "-- Case 17: the gate applies from anywhere inside the project [F01]"
# INVARIANT: a session cannot escape the gate by being somewhere else in its own
# project. ops-task.sh refuses to open a task anywhere but the directory holding
# .operator/, so a task can ONLY be armed at the root — but the Stop hook used to
# resolve "$cwd/.operator" with no upward walk, so a payload cwd one directory
# deeper found nothing and allowed the stop with tasks still open. Two components
# disagreeing about where the project is, failing OPEN. (Audit F01, P0.)
P="$(newproj)"; ( cd "$P" && bash "$INIT" >/dev/null 2>&1 )
( cd "$P" && bash "$TASK" T-ROOT --owner SESS-A >/dev/null 2>&1 )
mkdir -p "$P/src/deep/nested"
for sub in "" "/src" "/src/deep" "/src/deep/nested"; do
  json="$(sed "s|<tmp>|$P$sub|" "$FIXTURES/stop-session-a.json")"
  errf="$(mktemp)"; printf '%s' "$json" | "$BASH_ABS" "$HOOK" 2>"$errf"; rc=$?
  rm -f "$errf"
  check "gate blocks from cwd=<root>${sub:-/} (no escape by cd)" "$([ "$rc" -eq 2 ] && echo 0 || echo 1)"
done
# ...but the walk must NOT escape the project: a sibling directory outside it,
# and a parent above it, must stay no-op (exit 0) rather than adopting some
# unrelated ancestor's ledger.
OUTSIDE="$(newproj)"
json="$(sed "s|<tmp>|$OUTSIDE|" "$FIXTURES/stop-session-a.json")"
printf '%s' "$json" | "$BASH_ABS" "$HOOK" >/dev/null 2>&1; orc=$?
check "unrelated directory is still a no-op (walk does not over-reach)" "$([ "$orc" -eq 0 ] && echo 0 || echo 1)"
rm -rf "$OUTSIDE"
# a .git boundary halts the walk: a nested repo must not inherit the outer ledger
mkdir -p "$P/vendor/inner/.git"
json="$(sed "s|<tmp>|$P/vendor/inner|" "$FIXTURES/stop-session-a.json")"
printf '%s' "$json" | "$BASH_ABS" "$HOOK" >/dev/null 2>&1; nrc=$?
check "nested repo (.git boundary) does not inherit the outer ledger" "$([ "$nrc" -eq 0 ] && echo 0 || echo 1)"
rm -rf "$P"

########################################################################
echo "-- Case 18: every sentinel/fragment reader is byte-bounded [F02/F03]"
# INVARIANT: `read -r` is bounded by LINES, not bytes — one newline-less line is
# a single "line" and gets slurped whole. The 0.4.0 fix applied `read -r -n 512`
# to the Stop hook only; ops-verdict.sh, ops-adopt.sh and the --reconcile
# fragment reader kept plain `read -r`. Measured on one 256MB line: hook 0.17s
# vs verdict 13.51s, adopt 16.77s, reconcile 32.56s. (Audit F02, P2.)
#
# The 32.56s number is why this is not merely slow: --reconcile holds the lock
# across that read, and the budget presuming a crashed holder is 30s — so a
# concurrent writer RECLAIMED a live reconcile's lock and both entered the
# critical section. (Audit F03, P1.) Bounding the read removes the trigger.
#
# Sized at 64MB: enough to separate bounded (<2s) from unbounded (seconds) without
# putting a quarter-gig of writes in CI. Unlike the 32MB case above, this DOES
# discriminate — verified against the pre-fix scripts.
P="$(newproj)"; ( cd "$P" && bash "$INIT" >/dev/null 2>&1 )
bigline() { # bigline <path>  — 64MB on a single line, no trailing newline
  { i=0; while [ "$i" -lt 64 ]; do printf '%1048576s' '' | tr ' ' 'x'; i=$((i+1)); done; } > "$1"
}
( cd "$P" && bash "$TASK" T-HUGE --owner SESS-A >/dev/null 2>&1 )
bigline "$P/.operator/pending/T-HUGE"
S0=$(date +%s); ( cd "$P" && bash "$VERDICT" T-HUGE crit ev PASS --owner SESS-A >/dev/null 2>&1 ); S1=$(date +%s)
check "ops-verdict reads a huge-line sentinel in bounded time (<3s)" "$([ "$((S1 - S0))" -lt 3 ] && echo 0 || echo 1)"
( cd "$P" && bash "$TASK" T-HUGE2 --owner SESS-A >/dev/null 2>&1 )
bigline "$P/.operator/pending/T-HUGE2"
S0=$(date +%s); ( cd "$P" && bash "$ADOPT" --owner SESS-B T-HUGE2 >/dev/null 2>&1 ); S1=$(date +%s)
check "ops-adopt reads a huge-line sentinel in bounded time (<3s)" "$([ "$((S1 - S0))" -lt 3 ] && echo 0 || echo 1)"
bigline "$P/.operator/verdicts.d/huge.md"
S0=$(date +%s); ( cd "$P" && bash "$VERDICT" --reconcile >/dev/null 2>&1 ); S1=$(date +%s)
check "--reconcile reads a huge-line fragment in bounded time (<3s)" "$([ "$((S1 - S0))" -lt 3 ] && echo 0 || echo 1)"
check "--reconcile did not admit the huge non-conformant line" "$(! grep -q 'xxxxxxxx' "$P/.operator/VERDICTS.md" && echo 0 || echo 1)"
rm -rf "$P"

########################################################################
echo "-- Case 19: adopt does not propagate CR into the operator's guidance [F04]"
# A CRLF sentinel (core.autocrlf checkout, Windows editor, merge artifact) gets
# its session_id regenerated clean by adopt, but cwd:/opened_at: were copied
# through verbatim — and opened_at is echoed into the Stop hook's foreign-task
# report, where a bare CR carriage-returns the terminal mid-line and visually
# eats the operator's guidance. Gating is unaffected; this is presentation.
# (Audit F04, P3.)
P="$(newproj)"; ( cd "$P" && bash "$INIT" >/dev/null 2>&1 )
printf 'session_id: SESS-A\r\ncwd: /x\r\nopened_at: 2026-01-01T00:00:00Z\r\n' > "$P/.operator/pending/T-CRLF"
( cd "$P" && bash "$ADOPT" --owner SESS-B T-CRLF >/dev/null 2>&1 )
check "adopt strips CR from the rewritten sentinel" "$(! od -c "$P/.operator/pending/T-CRLF" | grep -q '\\r' && echo 0 || echo 1)"
run_hook stop-session-b.json "$P"
check "adopted CRLF sentinel still gates its new owner" "$([ "$HRC" -eq 2 ] && echo 0 || echo 1)"
errf="$(mktemp)"
printf '%s' "$(sed "s|<tmp>|$P|" "$FIXTURES/stop-session-a.json")" | "$BASH_ABS" "$HOOK" 2>"$errf" >/dev/null
check "no CR reaches the foreign-task report line" "$(! od -c "$errf" | grep -q '\\r' && echo 0 || echo 1)"
rm -f "$errf"
rm -rf "$P"

########################################################################
echo "-- Case 20: ops-init tells you where the ledger landed [F05]"
# ops-init.sh scaffolds .operator/ anywhere, including a directory that is not a
# repository — so a mis-aimed /cc-operator:start writes the evidence of record
# somewhere nobody will merge or review, while reporting success. Warn, do not
# hard-fail: a non-git project is unusual but legitimate. (Audit F05, P3.)
Q="$(newproj)"
IOUT="$( cd "$Q" && bash "$INIT" 2>&1 )"
check "ops-init warns when the target is not a git repository" "$(printf '%s' "$IOUT" | grep -qi 'not a git repo' && echo 0 || echo 1)"
check "ops-init still scaffolds (warn, never hard-fail)" "$([ -d "$Q/.operator/pending" ] && echo 0 || echo 1)"
check "ops-init ignores its own lock ephemera" "$(grep -q '.lock' "$Q/.operator/.gitignore" 2>/dev/null && echo 0 || echo 1)"
rm -rf "$Q"

########################################################################
echo "-- Case 21: a crashed lock holder is identified, not inferred from time"
# Reclamation used to infer "crashed" from elapsed time, which cannot tell a
# slow holder from a dead one. That is the ROOT of F03: a --reconcile that ran
# longer than the budget had its lock reclaimed by a concurrent writer and both
# entered the critical section. F03 bounded the trigger (FRAG_MAX_BYTES); this
# removes the inference. The lock now records host/uid/pid and asks the kernel.
#
# Liveness is only judged on OUR host for OUR uid — `kill -0` on another user's
# process fails with EPERM and would mis-read a LIVE holder as dead, which is
# the fail-open direction. Anything unjudgeable falls back to the old
# time-based path, so pre-0.5 locks and network filesystems keep working.
P="$(newproj)"; ( cd "$P" && bash "$INIT" >/dev/null 2>&1 )
LK="$P/.operator/.lock"
TMPD="$(newproj)"

# A pid that is definitely dead: spawn, reap, reuse its number.
sleep 0.1 & DEADPID=$!; wait "$DEADPID" 2>/dev/null || true

# (a) A dead holder is reclaimed PROMPTLY. Under time-based inference every
# writer behind a crashed one paid the full 30s budget; the kernel answers in
# microseconds. The <10s bound is far looser than the real cost (~0.2s) and far
# tighter than the 30s budget, so it discriminates without being flaky.
( cd "$P" && bash "$TASK" T-DEAD --owner SESS-A >/dev/null 2>&1 )
mkdir -p "$LK"; printf '%s %s %s\n' "${HOSTNAME:-nohost}" "${UID:-0}" "$DEADPID" > "$LK/holder"
SEC0=$(date +%s)
( cd "$P" && bash "$VERDICT" T-DEAD crit ev PASS --owner SESS-A >/dev/null 2>&1 )
DRC=$?
SEC1=$(date +%s)
check "dead holder: writer succeeds" "$([ "$DRC" -eq 0 ] && echo 0 || echo 1)"
check "dead holder: reclaimed promptly, not after the full budget (<10s)" "$([ "$((SEC1 - SEC0))" -lt 10 ] && echo 0 || echo 1)"
check "dead holder: verdict actually recorded" "$(grep -Fq '| T-DEAD | crit | ev | PASS |' "$P/.operator/VERDICTS.md" && [ ! -e "$P/.operator/pending/T-DEAD" ] && echo 0 || echo 1)"
check "dead holder: no lock or claim marker left behind" "$([ ! -d "$LK" ] && [ ! -d "$LK.reclaim" ] && echo 0 || echo 1)"

# (b) A LIVE holder is never reclaimed, however far past the budget the waiter
# goes. This is F03's root: the old code rmdir'd the live holder's lock and
# created its own, so the holder's own release then removed the NEW holder's
# lock and a third writer walked in. Exceeding the budget must degrade to the
# milder failure — proceed unlocked — never to stealing a running writer's lock.
#
# The lock budgets are env-overridable (a test seam; defaults unchanged), so the
# case runs on a TINY budget — ~1s to degrade on a confirmed-live holder —
# instead of the real 60s. The invariant under test (never steal a live holder's
# lock; the waiter degrades rather than hangs) is unchanged; only the absolute
# duration shrinks. Audit F08/F09: the real budget made the case take ~160s and
# the "completed" assertion a flaky timing-race (spins≠0.1s wall-clock under
# load). Measuring the property, not a wall-clock coincidence, is the fix.
#
# Hardcode LOCK_LIVE_SPINS=10 (do not read the ambient value): the suite must be
# hermetic against the very variable it exists to control (review minor note).
# LOCK_SPINS/RECLAIM_WAIT stay default here — the live-degrade branch never
# reclaims, so only LOCK_LIVE_SPINS bounds this case.
( cd "$P" && bash "$TASK" T-LIVE --owner SESS-A >/dev/null 2>&1 )
sleep 300 & LIVEPID=$!   # stays "live" for the whole case; duration irrelevant
mkdir -p "$LK"; printf '%s %s %s\n' "${HOSTNAME:-nohost}" "${UID:-0}" "$LIVEPID" > "$LK/holder"
LOCK_LIVE_SPINS=10 \
  bash -c 'cd "$0" && bash "$1" T-LIVE crit ev PASS --owner SESS-A >/dev/null 2>&1' \
  "$P" "$VERDICT" &
LVWRITER=$!
LVRC=1; waited=0
# Poll up to 20s (generous vs the ~1s degrade) for the writer to finish.
while [ "$waited" -lt 20 ]; do
  if ! kill -0 "$LVWRITER" 2>/dev/null; then wait "$LVWRITER" 2>/dev/null; LVRC=$?; break; fi
  sleep 1; waited=$((waited + 1))
done
if kill -0 "$LVWRITER" 2>/dev/null; then kill -9 "$LVWRITER" 2>/dev/null; LVRC=99; fi
check "live holder: waiter still completes (bounded, never hangs)" "$([ "$LVRC" -eq 0 ] && echo 0 || echo 1)"
check "live holder: its lock was NOT removed out from under it" "$([ -d "$LK" ] && echo 0 || echo 1)"
LVHOLD="$(cat "$LK/holder" 2>/dev/null || true)"
LVOK=1; case "$LVHOLD" in *" $LIVEPID") LVOK=0 ;; esac
check "live holder: still owns the lock record after the waiter gave up" "$LVOK"
kill "$LIVEPID" 2>/dev/null || true; wait "$LIVEPID" 2>/dev/null || true
# The stamp makes the lock dir non-empty, so it outlives a plain `rm -rf` of the
# tree unless the stamp goes first — the same property assertion (f) relies on.
rm -f "$LK/holder" "$LK.reclaim/holder" 2>/dev/null || true
rm -rf "$LK" "$LK.reclaim"

# (c) RECLAIM EXCLUSIVITY. Backlog #2 asked for a test that DISCRIMINATES here,
# i.e. one that fails against the naive `rmdir + mkdir`. It was attempted and it
# is NOT what this is; recording the negative result so the next maintainer does
# not spend the same day on it:
#
#   Six approaches were measured against a deliberately naive copy (exclusive
#   claim removed, re-verify removed) — cold-start racing, a ~1s critical
#   section via --reconcile, killing a live holder while both waiters were
#   already spinning, and 0.4s of fault injection inside the reclaim path.
#   Every one read 0/N unsafe outcomes. The reason is arithmetic: the reclaim
#   sequence is microseconds against a 0.1s spin interval, so P(collision) is
#   ~1e-5 per trial. Black-box timing cannot reach it. Closing backlog #2 as
#   specified would need the injection point INSIDE lock_acquire, shipped, which
#   trades a real hazard for a test.
#
# What those attempts did surface is a stronger guarantee than the timing one,
# and this is the assertion that now carries the weight: THE STAMP MAKES THE
# LOCK DIRECTORY NON-EMPTY, AND `rmdir` REFUSES NON-EMPTY DIRECTORIES. A
# reclaimer therefore cannot remove a lock a healthy process has stamped — it
# must delete the stamp first, which it only does after judging the holder dead.
# Deterministic, not probabilistic. Case (f) below asserts that property
# directly; these three assert the end-to-end outcome around it.
DISPLACED=0
for _i in $(seq 1 25); do
  rm -rf "$LK" "$LK.reclaim" "$P/.operator/pending"/*
  ( cd "$P" && bash "$TASK" T-X1 --owner SESS-A >/dev/null 2>&1 )
  ( cd "$P" && bash "$TASK" T-X2 --owner SESS-A >/dev/null 2>&1 )
  sleep 0.1 & DP=$!; wait "$DP" 2>/dev/null || true
  mkdir -p "$LK"; printf '%s %s %s\n' "${HOSTNAME:-nohost}" "${UID:-0}" "$DP" > "$LK/holder"
  RCERR="$( { ( cd "$P" && bash "$VERDICT" T-X1 c e PASS --owner SESS-A >/dev/null ) & \
              ( cd "$P" && bash "$VERDICT" T-X2 c e PASS --owner SESS-A >/dev/null ) & wait; } 2>&1 )"
  case "$RCERR" in *"reclaimed while this process held it"*) DISPLACED=$((DISPLACED+1)) ;; esac
done
check "two simultaneous reclaimers: neither is displaced from the lock" "$([ "$DISPLACED" = "0" ] && echo 0 || echo 1)"
check "two simultaneous reclaimers: both verdicts recorded" "$(grep -Fq '| T-X1 | c | e | PASS |' "$P/.operator/VERDICTS.md" && grep -Fq '| T-X2 | c | e | PASS |' "$P/.operator/VERDICTS.md" && echo 0 || echo 1)"
check "two simultaneous reclaimers: nothing left behind" "$([ ! -d "$LK" ] && [ ! -d "$LK.reclaim" ] && echo 0 || echo 1)"

# (d) An unjudgeable holder record must fall back to the time-based path, never
# be treated as dead — that is the fail-open direction. A pre-0.5 lock (no
# holder file at all) is the migration case and must keep working.
rm -rf "$LK" "$LK.reclaim"
mkdir -p "$LK"; printf 'someoneelse.example 65534 %s\n' "$DEADPID" > "$LK/holder"
( cd "$P" && bash "$TASK" T-FH --owner SESS-A >/dev/null 2>&1 )
SEC0=$(date +%s)
( cd "$P" && bash "$VERDICT" T-FH c e PASS --owner SESS-A >/dev/null 2>&1 ) &
FHPID=$!
sleep 3
check "foreign-host holder is not judged dead (no instant reclaim)" "$([ -e "$P/.operator/pending/T-FH" ] && echo 0 || echo 1)"
kill -9 "$FHPID" 2>/dev/null || true; wait "$FHPID" 2>/dev/null || true
rm -rf "$LK" "$LK.reclaim"
# (e) The two lock implementations must not drift. They contend on the same
# .operator/.lock, so a divergence is not a style problem — it is two different
# ideas of mutual exclusion. Compare the CODE of lock_acquire/lock_release with
# the tool name in warnings normalized away; comments may differ, logic may not.
# (f) The structural guarantee behind (c), asserted directly on the real
# lock_acquire: a held lock is STAMPED, and a stamped directory cannot be
# rmdir'd. This is what actually prevents a second reclaimer from stepping onto
# a fresh lock, and unlike the timing race it is deterministic. It also fails
# immediately if anyone "simplifies" the stamp away — which would silently
# restore the 0.4.0 hazard while every timing assertion stayed green.
cat > "$TMPD/probe.sh" <<'PROBE'
set -eu
OPDIR=".operator"; LOCKDIR="$OPDIR/.lock"
eval "$(awk '/^# >>> LOCK BLOCK/,/^# <<< LOCK BLOCK/' "$1")"
lock_acquire
[ -s "$LOCKDIR/holder" ] || { echo "NO-STAMP"; exit 1; }
if rmdir "$LOCKDIR" 2>/dev/null; then echo "RMDIR-SUCCEEDED"; exit 1; fi
lock_release
[ -d "$LOCKDIR" ] && { echo "NOT-RELEASED"; exit 1; }
echo OK
PROBE
PROBEOUT="$( cd "$P" && bash "$TMPD/probe.sh" "$SCRIPTS/ops-verdict.sh" 2>&1 )"
check "a held lock is stamped, and a stamped lock cannot be rmdir'd" "$([ "$PROBEOUT" = "OK" ] && echo 0 || echo 1)"

awk '/^# >>> LOCK BLOCK/,/^# <<< LOCK BLOCK/' "$SCRIPTS/ops-verdict.sh" | sed 's/ops-verdict:/TOOL:/g' > "$TMPD/lkv"
awk '/^# >>> LOCK BLOCK/,/^# <<< LOCK BLOCK/' "$SCRIPTS/ops-adopt.sh"   | sed 's/ops-adopt:/TOOL:/g'   > "$TMPD/lka"
check "adopt and verdict carry identical lock logic (no drift)" "$([ -s "$TMPD/lkv" ] && cmp -s "$TMPD/lkv" "$TMPD/lka" && echo 0 || echo 1)"

# The env-overridable lock budgets must validate (review F-A/B/C of the F08 seam):
# a non-numeric or zero value used to either wedge forever (F-A: [ -ge ] errors
# inside the `if`, set -e doesn't fire, spin loop never exits) or collapse the
# unjudgeable-holder budget to zero (F-B: instant reclaim — the F03 class). Both
# now refuse at resolve time. RECLAIM_WAIT >= LOCK_SPINS is also refused (F-C: it
# makes the backoff `i=$((LOCK_SPINS-RECLAIM_WAIT))` non-positive).
ABORT_BUDGET() { # ABORT_BUDGET <var=val...> → exit code
  ( cd "$P" && env "$@" bash "$VERDICT" T-BUD crit ev PASS --owner SESS-A >/dev/null 2>&1; echo $? )
}
check "non-numeric LOCK_SPINS is refused (no infinite hang, F-A)" "$([ "$(ABORT_BUDGET LOCK_SPINS=abc)" -eq 2 ] && echo 0 || echo 1)"
check "zero LOCK_SPINS is refused (no budget collapse, F-B)" "$([ "$(ABORT_BUDGET LOCK_SPINS=0)" -eq 2 ] && echo 0 || echo 1)"
check "RECLAIM_WAIT >= LOCK_SPINS is refused (no broken backoff, F-C)" "$([ "$(ABORT_BUDGET LOCK_SPINS=10 RECLAIM_WAIT=50)" -eq 2 ] && echo 0 || echo 1)"
# Stamps first: a stamped lock dir is non-empty and survives `rm -rf` otherwise.
rm -f "$P/.operator/.lock/holder" "$P/.operator/.lock.reclaim/holder" 2>/dev/null || true
rm -rf "$P" "$TMPD"

########################################################################
echo "-- Case 22: the statusline segment reports the gate, not a file count"
# The bar's whole value is that it answers "will my stop be blocked?". A raw
# count of pending/ answers a DIFFERENT question and gets it wrong in both
# directions: it cries wolf when every open task belongs to another session,
# and it reads 0 when an unowned sentinel is silently gating you. So the
# segment runs the Stop hook's partition — MINE + UNOWNED block, FOREIGN does
# not — and these assertions are what stop it from decaying into `ls | wc -l`.
#
# Renders on a ~300ms timer, which makes it the hottest reader in the plugin by
# three orders of magnitude (the Stop hook fires once per turn-end). Its byte
# bound is therefore load-bearing in a way the others' are not; measured, a
# 64MB newline-less sentinel costs 6.20s per parse unbounded vs 0.014s bounded.
SL="$SCRIPTS/statusline.sh"
# Case 5's PATH_NOJQ/PATH_NONE dirs are deleted at the end of that case, so
# build fresh ones here rather than silently testing a nonexistent PATH (which
# would make the python3-fallback assertion pass against no parser at all).
# sys.executable, not `python3`: a pyenv/asdf shim cannot run under a minimal
# PATH — the same trap case 5 documents.
SLPY="$(newproj)"; SLNONE="$(newproj)"
SLPYBIN="$(python3 -c 'import sys; print(sys.executable)' 2>/dev/null || true)"
if [ -n "$SLPYBIN" ] && [ -x "$SLPYBIN" ]; then ln -s "$SLPYBIN" "$SLPY/python3"; fi
sljson() { # sljson <session-id> <cwd>
  printf '{"session_id":"%s","cwd":"%s","workspace":{"project_dir":"%s"}}' "$1" "$2" "$2"
}
render() { # render <session-id> <cwd> → segment text with ANSI stripped
  sljson "$1" "$2" | "$BASH_ABS" "$SL" 2>/dev/null \
    | LC_ALL=C tr -d '\033' | LC_ALL=C sed 's/\[[0-9]*m//g'
}

P="$(newproj)"; ( cd "$P" && bash "$INIT" >/dev/null 2>&1 )
check "no open tasks → renders nothing (the bar stays clean)" \
  "$([ -z "$(render SESS-A "$P")" ] && echo 0 || echo 1)"

# Exit status is part of the renderer contract, not just its stdout: cc-status
# may drop a renderer that fails. A trailing `[ -n "$WFSEG" ] && printf ...`
# made an EMPTY wf segment the script's failing last command, so the common
# case (tasks open, no workflow running) printed op[1] and exited 1 — main
# exits 0 on the same payload (review panel, 2026-08-02). No prior case
# asserted the exit code, which is why it regressed silently.
sljson SESS-A "$P" | "$BASH_ABS" "$SL" >/dev/null 2>&1
check "statusline exits 0 with nothing to render" "$?"
SLEXITP="$(newproj)"; ( cd "$SLEXITP" && bash "$INIT" >/dev/null 2>&1 )
printf 'session_id: SESS-A\n' > "$SLEXITP/.operator/pending/exit-probe"
SLEXITOUT="$(sljson SESS-A "$SLEXITP" | "$BASH_ABS" "$SL" 2>/dev/null)"; SLEXITRC=$?
check "statusline exits 0 when the op[ segment renders but no workflow is live" \
  "$([ "$SLEXITRC" -eq 0 ] && printf '%s' "$SLEXITOUT" | grep -q 'op\[' && echo 0 || echo 1)"

( cd "$P" && bash "$TASK" T-1 --owner SESS-A >/dev/null 2>&1 )
( cd "$P" && bash "$TASK" T-2 --owner SESS-B >/dev/null 2>&1 )
( cd "$P" && bash "$TASK" T-3 --owner SESS-B >/dev/null 2>&1 )
# THE ASSERTION A FILE COUNT FAILS: one directory, three sentinels, and the
# answer differs per viewer. A count would print "3" to all three.
check "owner's view: 1 blocking + 2 foreign" \
  "$([ "$(render SESS-A "$P")" = "op[1+2*]" ] && echo 0 || echo 1)"
check "other owner's view: 2 blocking + 1 foreign" \
  "$([ "$(render SESS-B "$P")" = "op[2+1*]" ] && echo 0 || echo 1)"
check "bystander's view: 0 blocking + 3 foreign (nothing gates them)" \
  "$([ "$(render SESS-C "$P")" = "op[0+3*]" ] && echo 0 || echo 1)"

# A pre-0.4 empty sentinel is unowned, and unowned blocks EVERYONE. This is the
# direction that must not regress: showing 0 while the hook blocks would send
# the operator hunting a phantom.
: > "$P/.operator/pending/T-LEGACY"
check "an unowned sentinel counts as blocking, for a bystander too" \
  "$([ "$(render SESS-C "$P")" = "op[1+3*]" ] && echo 0 || echo 1)"
rm -f "$P/.operator/pending/T-LEGACY"

# Same untrusted-body rules as every other reader (docs/PLAYBOOK.md). An owner
# our CLIs could never have written must degrade to unowned = blocking, never
# be believed as a foreign session's claim (which would wave the stop through).
printf 'session_id: ../../PWNED\n' > "$P/.operator/pending/T-EVIL"
check "a traversal-shaped owner degrades to unowned, not foreign" \
  "$([ "$(render SESS-C "$P")" = "op[1+3*]" ] && echo 0 || echo 1)"
rm -f "$P/.operator/pending/T-EVIL"

# A CRLF checkout must not make a session's OWN task look foreign — the same
# fail-OPEN that bit the Stop hook.
printf 'session_id: SESS-A\r\n' > "$P/.operator/pending/T-CRLF"
check "a CRLF sentinel still reads as MINE, not foreign" \
  "$([ "$(render SESS-A "$P")" = "op[2+2*]" ] && echo 0 || echo 1)"
rm -f "$P/.operator/pending/T-CRLF"

# The segment resolves the project by the same upward walk as the Stop hook. If
# they disagreed, the bar would describe a different gate than the one that
# runs — which is exactly audit F01, in the hook itself.
mkdir -p "$P/sub/deeper"
check "a subdirectory cwd finds the same gate (F01 shape)" \
  "$([ "$(render SESS-A "$P/sub/deeper")" = "op[1+2*]" ] && echo 0 || echo 1)"

# --- dev[N] mirror: the bar renders the deviation gate's partition (stage 2) ---
# Same coupling rule as op[ — a bar describing a different gate than the one that
# runs is worse than no bar. dev[N] counts mine+unowned DEVIATIONs after the last
# mine/unowned HANDOFF-MARK; foreign excluded; renders nothing when N=0. Dim, not
# red (an unpresented decision blocks stop, not current work). Uses a fresh
# project so DECISIONS.md state does not collide with the op[ cases above.
DEVPROJ="$(newproj)"; ( cd "$DEVPROJ" && bash "$INIT" >/dev/null 2>&1 )
DEVDEC="$DEVPROJ/.operator/DECISIONS.md"
check "no deviations → no dev[ segment" \
  "$([ -z "$(render SESS-A "$DEVPROJ")" ] && echo 0 || echo 1)"
printf '2026-08-04 | e.t | DEVIATION | [sid:SESS-A] a decision | r\n' > "$DEVDEC"
check "1 mine deviation → dev[1] (dim)" \
  "$([ "$(render SESS-A "$DEVPROJ")" = "dev[1]" ] && echo 0 || echo 1)"
printf '2026-08-04 | e.t | DEVIATION | [sid:SESS-B] foreign | r\n' >> "$DEVDEC"
check "foreign deviation excluded → still dev[1]" \
  "$([ "$(render SESS-A "$DEVPROJ")" = "dev[1]" ] && echo 0 || echo 1)"
printf '2026-08-04 | e | HANDOFF-MARK | [sid:SESS-A] 2026-08-04T00:00:00Z | presented\n' >> "$DEVDEC"
check "mine mark clears → no dev[ segment" \
  "$([ -z "$(render SESS-A "$DEVPROJ")" ] && echo 0 || echo 1)"
# A deviation AFTER the mark re-shows it (position rule, mirrored from the hook).
printf '2026-08-04 | e.t | DEVIATION | [sid:SESS-A] post-mark | r\n' >> "$DEVDEC"
check "deviation after mark re-shows dev[1]" \
  "$([ "$(render SESS-A "$DEVPROJ")" = "dev[1]" ] && echo 0 || echo 1)"
# An untagged (legacy) deviation counts for any session.
printf '2026-08-04 | e.t | DEVIATION | untagged legacy | r\n' > "$DEVDEC"
check "untagged deviation → dev[1] for any session" \
  "$([ "$(render SESS-B "$DEVPROJ")" = "dev[1]" ] && echo 0 || echo 1)"

# Hostile/degenerate stdin must render nothing rather than spray errors onto
# the bar. Includes the no-parser case: unlike the Stop hook, which warns on
# stderr, a statusline has nowhere to warn — silence IS the correct behavior.
check "garbage payload renders nothing" \
  "$([ -z "$(printf 'NOT JSON{{' | "$BASH_ABS" "$SL" 2>&1)" ] && echo 0 || echo 1)"
check "empty payload renders nothing" \
  "$([ -z "$(printf '' | "$BASH_ABS" "$SL" 2>&1)" ] && echo 0 || echo 1)"
# No jq AND no python3: PATH_NONE is an empty dir, so even `cat` is gone. This
# is why the segment slurps stdin with the `read` builtin — an external command
# here printed a bash error INTO the statusline (caught in review, pre-release).
check "no parser and no external commands: silent, no stray output" \
  "$([ -z "$(sljson SESS-A "$P" | PATH="$SLNONE" "$BASH_ABS" "$SL" 2>&1)" ] && echo 0 || echo 1)"
# ...and it must TERMINATE, not merely stay quiet. Slurping stdin with `cat`
# under an empty PATH does not fail — it HANGS, waiting on a command that will
# never run, which freezes the whole bar rather than dropping one segment.
# (Found by mutation-testing this very case: the mutant ran until killed while
# every output assertion above sat there looking fine.) A silence assertion
# cannot see the difference; a deadline can.
SLS0=$(date +%s)
sljson SESS-A "$P" | PATH="$SLNONE" "$BASH_ABS" "$SL" >/dev/null 2>&1 &
SLPID=$!
SLHUNG=1
while [ "$(( $(date +%s) - SLS0 ))" -lt 5 ]; do
  kill -0 "$SLPID" 2>/dev/null || { SLHUNG=0; break; }
  sleep 0.2
done
[ "$SLHUNG" -eq 0 ] || kill -9 "$SLPID" 2>/dev/null
wait "$SLPID" 2>/dev/null
check "no parser and no external commands: terminates, does not hang the bar" "$SLHUNG"
# The python3 fallback must produce the SAME partition as jq, or the bar tells
# two different stories depending on which parser a machine happens to have.
if [ -n "$SLPYBIN" ] && [ -x "$SLPYBIN" ]; then
  check "python3 fallback agrees with jq" \
    "$([ "$(sljson SESS-A "$P" | PATH="$SLPY" "$BASH_ABS" "$SL" 2>/dev/null \
          | LC_ALL=C tr -d '\033' | LC_ALL=C sed 's/\[[0-9]*m//g')" = "op[1+2*]" ] && echo 0 || echo 1)"
else
  fail "python3 fallback agrees with jq (no python3 resolved — fallback untested)"
fi

# A directory in pending/ is not a task; the hook's `-f` guard exists because a
# bash error was once emitted AS operator guidance.
mkdir -p "$P/.operator/pending/T-DIR"
check "a directory in pending/ is not counted as a task" \
  "$([ "$(render SESS-A "$P")" = "op[1+2*]" ] && echo 0 || echo 1)"
rmdir "$P/.operator/pending/T-DIR"

# The byte bound, on the reader that renders every 300ms. Unbounded, this same
# file measured 6.20s PER PARSE — a permanently wedged bar, not a slow one.
bigline "$P/.operator/pending/T-HUGE"
S0=$(date +%s); OUT_HUGE="$(render SESS-A "$P")"; S1=$(date +%s)
check "a 64MB single-line sentinel renders in bounded time (<3s)" \
  "$([ "$((S1 - S0))" -lt 3 ] && echo 0 || echo 1)"
check "the huge sentinel is still counted (bounded, not skipped)" \
  "$([ "$OUT_HUGE" = "op[2+2*]" ] && echo 0 || echo 1)"
rm -f "$P/.operator/pending/T-HUGE"

# The manifest is how cc-status discovers the segment; a renderer path that does
# not resolve means the segment silently never appears.
MANIFEST="$REPO/.claude-plugin/statusline.json"
check "statusline.json manifest exists" "$([ -f "$MANIFEST" ] && echo 0 || echo 1)"
if [ -f "$MANIFEST" ]; then
  MREND="$(LC_ALL=C sed -n 's/.*"render"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$MANIFEST")"
  check "manifest render path resolves to a real file" \
    "$([ -n "$MREND" ] && [ -f "$REPO/$MREND" ] && echo 0 || echo 1)"
  check "manifest name matches the plugin name" \
    "$(grep -q '"name"[[:space:]]*:[[:space:]]*"cc-operator"' "$MANIFEST" && echo 0 || echo 1)"
fi
rm -rf "$P" "$SLPY" "$SLNONE"

########################################################################
echo "-- Case: /cc-operator:tiers command wraps the tier resolver"
# commands/tiers.md is a thin wrapper over ops-tiers.sh — it adds no logic, so
# the resolver's own guards (charset, cc-proxy routability) are the validation.
# What the command MUST guarantee: it exists, its allowed-tools grants the
# ops-tiers.sh invocation, and it uses ${CLAUDE_PLUGIN_ROOT} (a bare scripts/
# path resolves only inside this repo — the v0.2.0 blocked-start bug).
CMD="$REPO/commands/tiers.md"
check "commands/tiers.md exists" "$([ -f "$CMD" ] && echo 0 || echo 1)"
check "tiers.md grants ops-tiers.sh via CLAUDE_PLUGIN_ROOT" \
  "$(grep -q 'allowed-tools:.*CLAUDE_PLUGIN_ROOT.*scripts/ops-tiers.sh' "$CMD" && echo 0 || echo 1)"
# The resolver's behavior, invoked the way the command invokes it. Config env
# is isolated so a maintainer's real tiers.env cannot change the output, and
# CC_PROXY_PORT is pointed at a dead port so the advisory catalogue probe is
# instant rather than the ~5s curl timeout.
TIERSENV() {  # TIERSENV <args...> -> stdout, rc captured
  CC_OPERATOR_TIERS_USER=/nonexistent CC_OPERATOR_TIERS_PROJECT=/nonexistent \
  CC_PROXY_PORT=1 "$BASH_ABS" "$SCRIPTS/ops-tiers.sh" "$@"
}
SHOW="$(TIERSENV --show 2>/dev/null)"; SHOWRC=$?
check "ops-tiers --show prints the TIER/MODEL/SOURCE table" \
  "$([ "$SHOWRC" -eq 0 ] && printf '%s' "$SHOW" | grep -q '^TIER *MODEL *SOURCE' && echo 0 || echo 1)"
SETOUT="$(TIERSENV --set MECHANICAL=glm-4.7 --show 2>/dev/null)"
check "set NAME=id applies a one-off override (source shows --set)" \
  "$(printf '%s' "$SETOUT" | grep -q 'MECHANICAL.*glm-4.7.*--set' && echo 0 || echo 1)"
TIERSENV --set MECHANICAL=bogus-id >/dev/null 2>&1; BADRC=$?
check "an unroutable --set id is refused (non-zero exit)" \
  "$([ "$BADRC" -ne 0 ] && echo 0 || echo 1)"
# tiers.env carries TWO line kinds (the renderer's seat bindings share the
# file). The resolver must SKIP a seat line, not die on it — the scaffold's own
# documented example ('#op-scout=MECHANICAL', ops-init.sh) used to kill every
# resolver invocation once uncommented (audit F15). A seat line with a BOGUS
# tier value must still die: a typo is a mis-route, not a seat binding.
SEATENV="$(mktemp "${TMPDIR:-/tmp}/opstest-seat.XXXXXX")"
printf 'MECHANICAL=glm-4.7\nop-scout=MECHANICAL\n' > "$SEATENV"
SEATOUT="$(CC_OPERATOR_TIERS_USER=/nonexistent CC_OPERATOR_TIERS_PROJECT="$SEATENV" \
  CC_PROXY_PORT=1 "$BASH_ABS" "$SCRIPTS/ops-tiers.sh" --show 2>/dev/null)"; SEATRC=$?
check "a seat line in tiers.env is skipped by the resolver, tiers still resolve (F15)" \
  "$([ "$SEATRC" -eq 0 ] && printf '%s' "$SEATOUT" | grep -q 'MECHANICAL *glm-4.7' && echo 0 || echo 1)"
printf 'op-scout=MECHANICL\n' > "$SEATENV"
CC_OPERATOR_TIERS_USER=/nonexistent CC_OPERATOR_TIERS_PROJECT="$SEATENV" \
  CC_PROXY_PORT=1 "$BASH_ABS" "$SCRIPTS/ops-tiers.sh" --show >/dev/null 2>&1; SEATBADRC=$?
check "a seat line with an unknown tier VALUE still dies in the resolver" \
  "$([ "$SEATBADRC" -ne 0 ] && echo 0 || echo 1)"

# A COMMENT longer than the 512-char read cap used to smuggle a live tier
# binding past the comment check: `read -n 512` truncates mid-line and the
# remainder arrives next iteration as a fresh "line", classified on its own.
# Measured pre-fix: `#` + 511 x's + `MECHANICAL=glm-evil` resolved MECHANICAL
# to glm-evil at exit 0 — a silent mis-route from a line the author had
# commented OUT. Both readers of this file carry the guard.
LONGENV="$(mktemp "${TMPDIR:-/tmp}/opstest-long.XXXXXX")"
{ printf '#'; awk 'BEGIN{while(i++<511)printf "x"}'; printf 'MECHANICAL=glm-evil\n'; } > "$LONGENV"
LONGOUT="$(CC_OPERATOR_TIERS_USER=/nonexistent CC_OPERATOR_TIERS_PROJECT="$LONGENV" \
  CC_PROXY_PORT=1 "$BASH_ABS" "$SCRIPTS/ops-tiers.sh" 2>/dev/null)"; LONGRC=$?
check "an over-long comment cannot smuggle a tier binding past the resolver" \
  "$([ "$LONGRC" -ne 0 ] && ! printf '%s' "$LONGOUT" | grep -q 'glm-evil' && echo 0 || echo 1)"
CC_OPERATOR_TIERS_USER=/nonexistent CC_OPERATOR_TIERS_PROJECT="$LONGENV" \
  "$BASH_ABS" "$SCRIPTS/ops-render.sh" --show >/dev/null 2>&1; LONGRENDRC=$?
check "the renderer carries the same over-long-line guard as the resolver" \
  "$([ "$LONGRENDRC" -ne 0 ] && echo 0 || echo 1)"
# A NUL is the same smuggle by a shorter road, and only on the bash the repo
# TARGETS: bash 3.2's `read -n` stops AT a NUL, so `#` + 100 NULs + 411 x +
# `MECHANICAL=glm-evil` yields a 1-CHAR first chunk that sails past the length
# guard, and the tail parses as a live assignment. ${#line} cannot catch it
# (bash drops NULs from variables entirely), and it is invisible on bash 5.3 —
# which is why the suite was green while system bash was exploitable. The
# probe must also not misfire on a NUL-free file that merely fills the cap.
NULENV="$(mktemp "${TMPDIR:-/tmp}/opstest-nul.XXXXXX")"
python3 -c "import sys; open(sys.argv[1],'wb').write(b'#'+b'\\0'*100+b'x'*411+b'MECHANICAL=glm-evil\\n')" "$NULENV"
NULOUT="$(CC_OPERATOR_TIERS_USER=/nonexistent CC_OPERATOR_TIERS_PROJECT="$NULENV" \
  CC_PROXY_PORT=1 "$BASH_OLD" "$SCRIPTS/ops-tiers.sh" 2>/dev/null)"; NULRC=$?
check "a NUL-padded comment cannot smuggle a tier binding (resolver)" \
  "$([ "$NULRC" -ne 0 ] && ! printf '%s' "$NULOUT" | grep -q 'glm-evil' && echo 0 || echo 1)"
CC_OPERATOR_TIERS_USER=/nonexistent CC_OPERATOR_TIERS_PROJECT="$NULENV" \
  "$BASH_OLD" "$SCRIPTS/ops-render.sh" --show >/dev/null 2>&1; NULRENDRC=$?
check "the renderer carries the same NUL guard as the resolver" \
  "$([ "$NULRENDRC" -ne 0 ] && echo 0 || echo 1)"
# A single 512-byte probe closed the door only at the front of the file: a NUL
# at byte 829 (short comment lines, then `pad\0tail`, then the binding) passed
# the probe and resolved MECHANICAL=glm-evil with exit 0 (Copilot 2026-08-03,
# measured before the loop fix). The probe must walk the WHOLE file. Also on
# BASH_OLD: same char/byte read -n behavior the front-NUL case pins.
LATENULENV="$(mktemp "${TMPDIR:-/tmp}/opstest-latenul.XXXXXX")"
python3 -c "import sys; open(sys.argv[1],'wb').write(
  b'\\n'.join(b'# ' + b'x'*100 for _ in range(8)) + b'\\n# pad\\0tail\\nMECHANICAL=glm-evil\\n')" "$LATENULENV"
LATEOUT="$(CC_OPERATOR_TIERS_USER=/nonexistent CC_OPERATOR_TIERS_PROJECT="$LATENULENV" \
  CC_PROXY_PORT=1 "$BASH_OLD" "$SCRIPTS/ops-tiers.sh" 2>/dev/null)"; LATERC=$?
check "a NUL past the first 512 bytes is still fatal (resolver probe loops the whole file)" \
  "$([ "$LATERC" -ne 0 ] && ! printf '%s' "$LATEOUT" | grep -q 'glm-evil' && echo 0 || echo 1)"
CC_OPERATOR_TIERS_USER=/nonexistent CC_OPERATOR_TIERS_PROJECT="$LATENULENV" \
  "$BASH_OLD" "$SCRIPTS/ops-render.sh" --show >/dev/null 2>&1; LATERENDRC=$?
check "the renderer's NUL probe also loops the whole file" \
  "$([ "$LATERENDRC" -ne 0 ] && echo 0 || echo 1)"
rm -f "$LATENULENV"
# The probe is now BOUNDED at 200 chunks (100KB): a newline-less multi-MB
# tiers.env (no NUL) must die FAST, not loop the whole file. Before the cap
# this measured 66-70s on a 64MB file vs 0.11s capped (bash 3.2.57,
# 2026-08-04) — the probe defeated the bounded-reader guarantee
# check_reader_bounds enforces. (The 4.0s originally cited from the F64
# report is wrong by ~15x; it was copied into five files before anyone
# re-measured. A load-bearing number with no owner rots exactly this way.)
# The fixture must be 16MB, not 2MB: with the cap reverted, 2MB completed in
# 2.4s on bash 3.2 — UNDER the 5s budget, so both assertions passed against
# the broken code (code-review of f4cae1a, 2026-08-04; PLAYBOOK "prove it
# discriminates"). 16MB measures 15.8s uncapped vs 0.03s capped on the same
# bash — the budget now separates the two by three orders of magnitude.
BIGENV="$(mktemp "${TMPDIR:-/tmp}/opstest-big.XXXXXX")"
python3 -c "import sys; open(sys.argv[1],'wb').write(b'x'*(16*1024*1024)+b'\nMECHANICAL=glm-evil\n')" "$BIGENV"
_start=$(date +%s)
BIGOUT="$(CC_OPERATOR_TIERS_USER=/nonexistent CC_OPERATOR_TIERS_PROJECT="$BIGENV" \
  CC_PROXY_PORT=1 "$BASH_OLD" "$SCRIPTS/ops-tiers.sh" 2>/dev/null)"; BIGRC=$?
_elapsed=$(( $(date +%s) - _start ))
check "a newline-less multi-MB tiers.env dies (probe is bounded, not whole-file)" \
  "$([ "$BIGRC" -ne 0 ] && ! printf '%s' "$BIGOUT" | grep -q 'glm-evil' && echo 0 || echo 1)"
check "the bounded probe rejects a multi-MB file fast (<5s; 64MB uncapped is 66-70s)" \
  "$([ "$_elapsed" -lt 5 ] && echo 0 || echo 1)"
_start=$(date +%s)
CC_OPERATOR_TIERS_USER=/nonexistent CC_OPERATOR_TIERS_PROJECT="$BIGENV" \
  "$BASH_OLD" "$SCRIPTS/ops-render.sh" --show >/dev/null 2>&1; BIGRENDRC=$?
_elapsed=$(( $(date +%s) - _start ))
check "the renderer's probe is also bounded (rejects multi-MB fast, <5s)" \
  "$([ "$BIGRENDRC" -ne 0 ] && [ "$_elapsed" -lt 5 ] && echo 0 || echo 1)"
rm -f "$BIGENV"
# The probe cap must not narrow the accepted input below what the parse loop
# itself permits (200 lines × 511 chars ≈ 100KB): the first cap was 40 chunks
# (20KB), and a 24KB comment-heavy tiers.env that resolved fine at f4cae1a~1
# died with a NUL-implicating message (code-review of f4cae1a, 2026-08-04).
# 60 comment lines × 400 chars is legal under every parse-loop cap and must
# keep resolving.
FATENV="$(mktemp "${TMPDIR:-/tmp}/opstest-fat.XXXXXX")"
python3 -c "
import sys
lines = [b'# ' + b'c'*400 for _ in range(60)] + [b'MECHANICAL=claude-3-5-haiku-20241022']
open(sys.argv[1],'wb').write(b'\n'.join(lines) + b'\n')" "$FATENV"
FATOUT="$(CC_OPERATOR_TIERS_USER=/nonexistent CC_OPERATOR_TIERS_PROJECT="$FATENV" \
  CC_PROXY_PORT=1 "$BASH_OLD" "$SCRIPTS/ops-tiers.sh" 2>&1)"; FATRC=$?
check "a comment-heavy tiers.env within the parse-loop caps still resolves (probe cap covers legal max)" \
  "$([ "$FATRC" -eq 0 ] && printf '%s' "$FATOUT" | grep -q 'claude-3-5-haiku-20241022' && echo 0 || echo 1)"
rm -f "$FATENV"
# A MULTIBYTE comment smuggles the same way through the char/byte-mismatched
# LENGTH guard (not the NUL probe): on BASH_OLD `read -n 512` fills 512 BYTES
# while `${#line}` counts CHARACTERS under a UTF-8 locale, so `#`+'é'×255+`A`
# (512 bytes = 257 chars) passes `< 512` and its truncated tail parses as a
# live assignment. Full-PR panel, score 85. The parse loop now runs LC_ALL=C
# so both count bytes. Forced UTF-8 locale + BASH_OLD, where the mismatch lives.
UTF8ENV="$(mktemp "${TMPDIR:-/tmp}/opstest-utf8.XXXXXX")"
python3 -c "import sys; open(sys.argv[1],'wb').write(('#'+'é'*255+'A').encode()+b'\\nMECHANICAL=glm-evil\\n')" "$UTF8ENV"
UTF8OUT="$(CC_OPERATOR_TIERS_USER=/nonexistent CC_OPERATOR_TIERS_PROJECT="$UTF8ENV" \
  CC_PROXY_PORT=1 LC_ALL=en_US.UTF-8 "$BASH_OLD" "$SCRIPTS/ops-tiers.sh" 2>/dev/null)"; UTF8RC=$?
check "a multibyte comment cannot smuggle a tier binding past the length guard (resolver)" \
  "$([ "$UTF8RC" -ne 0 ] && ! printf '%s' "$UTF8OUT" | grep -q 'glm-evil' && echo 0 || echo 1)"
CC_OPERATOR_TIERS_USER=/nonexistent CC_OPERATOR_TIERS_PROJECT="$UTF8ENV" \
  LC_ALL=en_US.UTF-8 "$BASH_OLD" "$SCRIPTS/ops-render.sh" --show >/dev/null 2>&1; UTF8RENDRC=$?
check "the renderer carries the same multibyte length guard as the resolver" \
  "$([ "$UTF8RENDRC" -ne 0 ] && echo 0 || echo 1)"
# ...and a LEGITIMATE short UTF-8 comment still parses (guard did not overreach).
OKUTF8="$(mktemp "${TMPDIR:-/tmp}/opstest-okutf8.XXXXXX")"
printf '# \xc3\xa9clair config\nMECHANICAL=glm-4.7\n' > "$OKUTF8"
OKOUT="$(CC_OPERATOR_TIERS_USER=/nonexistent CC_OPERATOR_TIERS_PROJECT="$OKUTF8" \
  CC_PROXY_PORT=1 LC_ALL=en_US.UTF-8 "$BASH_OLD" "$SCRIPTS/ops-tiers.sh" 2>/dev/null)"; OKRC=$?
check "a short multibyte comment still resolves (length guard did not overreach)" \
  "$([ "$OKRC" -eq 0 ] && printf '%s' "$OKOUT" | grep -q 'glm-4.7' && echo 0 || echo 1)"
rm -f "$UTF8ENV" "$OKUTF8"
rm -f "$NULENV"
rm -f "$LONGENV"
rm -f "$SEATENV"

########################################################################
echo "-- Case: /cc-operator:tiers render branch + ops-render.sh behavior"
# ops-render.sh renders project-layer agents (.claude/agents/op-*.md) from the
# tier config so a PLAIN Agent dispatch can run on a cc-proxy model. The command
# (commands/tiers.md) is a thin wrapper; the renderer's guard chain
# (charset/routable/seat-name) + atomic write are the validation. These cases
# exercise the renderer's behavior, not just its validator-level shape.
RENDER="$SCRIPTS/ops-render.sh"
check "commands/tiers.md grants ops-render.sh via CLAUDE_PLUGIN_ROOT" \
  "$(grep -q 'allowed-tools:.*CLAUDE_PLUGIN_ROOT.*scripts/ops-render.sh' "$CMD" && echo 0 || echo 1)"
check "tiers.md documents the render branch" \
  "$(grep -q 'render' "$CMD" && echo 0 || echo 1)"

# A render fixture project, isolated from the maintainer's real tiers.env. The
# renderer reads .operator/tiers.env; CC_PROXY_PORT=1 makes the --check liveness
# probe instant (dead port) without hanging.
RENDERENV() { # RENDERENV <args...> -> runs in the fixture project
  CC_OPERATOR_TIERS_USER=/nonexistent CC_PROXY_PORT=1 \
  "$BASH_ABS" "$RENDER" "$@"
}
RP="$(newproj)"
# newproj does not init .operator; the renderer needs .operator/tiers.env + the
# _templates (resolved from the plugin install, not the fixture). Set both up.
( cd "$RP" && "$BASH_ABS" "$INIT" >/dev/null 2>&1 )

# --show: the resolved seat→model table, with a tier repoint applied.
printf 'MECHANICAL=glm-5-turbo\nop-scout=MECHANICAL\n' > "$RP/.operator/tiers.env"
SHOWR="$( cd "$RP" && RENDERENV --show 2>/dev/null )"; SHOWRRC=$?
check "ops-render --show prints the SEAT/TIER/MODEL/SOURCE table" \
  "$([ "$SHOWRRC" -eq 0 ] && printf '%s' "$SHOWR" | grep -q '^SEAT *TIER *MODEL' && echo 0 || echo 1)"
check "ops-render --show resolves a repointed tier (crawler: MECHANICAL→glm-5-turbo)" \
  "$(printf '%s' "$SHOWR" | grep -q 'crawler.*MECHANICAL.*glm-5-turbo' && echo 0 || echo 1)"
# F21: the implementer seats default to their ALIAS tiers (author=JUDGMENT,
# mechanic=IMPLEMENT) — a MECHANICAL repoint must NOT move them; down-tiering
# is a deliberate tiers.env act, never a default.
check "ops-render --show keeps mechanic on IMPLEMENT (alias-matched default, F21)" \
  "$(printf '%s' "$SHOWR" | grep -q 'mechanic.*IMPLEMENT' && echo 0 || echo 1)"
check "ops-render --show resolves a seat override (scout→MECHANICAL)" \
  "$(printf '%s' "$SHOWR" | grep -q 'scout.*MECHANICAL.*glm-5-turbo' && echo 0 || echo 1)"

# render: writes .claude/agents/op-*.md with the spliced model id.
( cd "$RP" && RENDERENV >/dev/null 2>&1 ); RENDRC=$?
check "ops-render render exits 0" "$([ "$RENDRC" -eq 0 ] && echo 0 || echo 1)"
check "render writes a project-layer op-mechanic.md" \
  "$([ -f "$RP/.claude/agents/op-mechanic.md" ] && echo 0 || echo 1)"
check "rendered op-crawler.md frontmatter has model: glm-5-turbo (spliced)" \
  "$(grep -q '^model: glm-5-turbo' "$RP/.claude/agents/op-crawler.md" && echo 0 || echo 1)"
check "rendered op-mechanic.md frontmatter has model: claude-sonnet-5 (IMPLEMENT, F21)" \
  "$(grep -q '^model: claude-sonnet-5' "$RP/.claude/agents/op-mechanic.md" && echo 0 || echo 1)"
check "rendered op-mechanic.md frontmatter has name: op-mechanic" \
  "$(grep -q '^name: op-mechanic' "$RP/.claude/agents/op-mechanic.md" && echo 0 || echo 1)"
# Single-source bodies (F14): the rendered implementer seats must keep the
# plugin-root agent's tools line — the template-era render built author and
# mechanic from default.tmpl, silently STRIPPING Write/Edit from both (a
# rendered "implementer" that cannot implement). The verifier must likewise
# keep its disallowedTools line.
check "rendered op-mechanic keeps Write/Edit (single-source body, F14)" \
  "$(grep -q '^tools:.*Write.*Edit' "$RP/.claude/agents/op-mechanic.md" && echo 0 || echo 1)"
check "rendered op-author keeps Write/Edit (F14)" \
  "$(grep -q '^tools:.*Write.*Edit' "$RP/.claude/agents/op-author.md" && echo 0 || echo 1)"
check "rendered op-verifier keeps disallowedTools (F14)" \
  "$(grep -q '^disallowedTools:' "$RP/.claude/agents/op-verifier.md" && echo 0 || echo 1)"
check "rendered op-crawler exists (plugin-root body, crawl workflow seat)" \
  "$(grep -q '^name: op-crawler' "$RP/.claude/agents/op-crawler.md" && echo 0 || echo 1)"
check "render states restart-to-apply (agent files read at session start)" \
  "$( cd "$RP" && RENDERENV 2>&1 | grep -qi 'restart' && echo 0 || echo 1)"

# revert: removes the project layer (fall back to plugin-root alias agents).
( cd "$RP" && RENDERENV --revert >/dev/null 2>&1 ); REVRC=$?
check "ops-render --revert exits 0" "$([ "$REVRC" -eq 0 ] && echo 0 || echo 1)"
check "revert removes the rendered op-mechanic.md" \
  "$([ ! -f "$RP/.claude/agents/op-mechanic.md" ] && echo 0 || echo 1)"

# guard chain: each rejection changes no file and exits non-zero.
gmkdir() { mkdir -p "$RP/.claude/agents"; }
printf 'MECHANICAL=not-a-model\n' > "$RP/.operator/tiers.env"
( cd "$RP" && RENDERENV --show >/dev/null 2>&1 ); G1=$?
check "guard: unroutable model id is refused (non-zero exit)" "$([ "$G1" -ne 0 ] && echo 0 || echo 1)"
printf 'op-scout=BOGUS\n' > "$RP/.operator/tiers.env"
( cd "$RP" && RENDERENV --show >/dev/null 2>&1 ); G2=$?
check "guard: seat bound to unknown tier is refused (non-zero exit)" "$([ "$G2" -ne 0 ] && echo 0 || echo 1)"
printf 'MECHANICAL=glm 5\n' > "$RP/.operator/tiers.env"
( cd "$RP" && RENDERENV --show >/dev/null 2>&1 ); G3=$?
check "guard: whitespace in model id is refused (non-zero exit)" "$([ "$G3" -ne 0 ] && echo 0 || echo 1)"

# M7: CLAUDE_CODE_SUBAGENT_MODEL set → warned (it overrides frontmatter at dispatch).
printf 'MECHANICAL=glm-5-turbo\n' > "$RP/.operator/tiers.env"
M7WARN="$( cd "$RP" && CC_OPERATOR_TIERS_USER=/nonexistent CC_PROXY_PORT=1 \
  CLAUDE_CODE_SUBAGENT_MODEL=glm-5.2 "$BASH_ABS" "$RENDER" --show 2>&1 )"
check "M7: warns when CLAUDE_CODE_SUBAGENT_MODEL is set (overrides frontmatter)" \
  "$(printf '%s' "$M7WARN" | grep -qi 'CLAUDE_CODE_SUBAGENT_MODEL' && echo 0 || echo 1)"

# Renderer ownership (F17): render/revert delete ONLY files stamped with the
# render mark. A hand-authored op-custom.md (plausible name — every shipped
# agent is op-*) must survive both; a hand-authored file at a SEAT's own name
# must block the render loudly rather than be overwritten.
printf 'MECHANICAL=glm-5-turbo\n' > "$RP/.operator/tiers.env"
mkdir -p "$RP/.claude/agents"
printf -- '---\nname: op-custom\nmodel: opus\n---\nhand-written\n' > "$RP/.claude/agents/op-custom.md"
( cd "$RP" && RENDERENV >/dev/null 2>&1 ); OWNRC=$?
check "render succeeds alongside a hand-authored op-custom.md" \
  "$([ "$OWNRC" -eq 0 ] && echo 0 || echo 1)"
check "render preserves the hand-authored op-custom.md (F17)" \
  "$([ -f "$RP/.claude/agents/op-custom.md" ] && grep -q 'hand-written' "$RP/.claude/agents/op-custom.md" && echo 0 || echo 1)"
check "rendered files carry the ownership mark" \
  "$(grep -q 'rendered-by: cc-operator ops-render' "$RP/.claude/agents/op-mechanic.md" && echo 0 || echo 1)"
( cd "$RP" && RENDERENV --revert >/dev/null 2>&1 )
check "revert preserves the hand-authored op-custom.md (F17)" \
  "$([ -f "$RP/.claude/agents/op-custom.md" ] && [ ! -f "$RP/.claude/agents/op-mechanic.md" ] && echo 0 || echo 1)"
# Collision: a hand-authored file at a seat's target name → die, nothing deleted.
printf -- '---\nname: op-scout\nmodel: opus\n---\nmine\n' > "$RP/.claude/agents/op-scout.md"
( cd "$RP" && RENDERENV >/dev/null 2>&1 ); COLRC=$?
check "render refuses to overwrite an unmarked op-<seat>.md (non-zero exit)" \
  "$([ "$COLRC" -ne 0 ] && grep -q 'mine' "$RP/.claude/agents/op-scout.md" && echo 0 || echo 1)"
rm -f "$RP/.claude/agents/op-scout.md" "$RP/.claude/agents/op-custom.md"

# Seat-name allowlist (F18): a metachar in a seat name used to be interpolated
# into a BRE ('s.out' silently DELETED the baked scout record via grep -v).
# Now anything outside [A-Za-z0-9_-] is refused loudly, and the override filter
# compares literally.
printf 'op-s.out=MECHANICAL\n' > "$RP/.operator/tiers.env"
BREOUT="$( cd "$RP" && RENDERENV --show 2>&1 )"; BRERC=$?
check "guard: seat name with a regex metachar is refused (F18)" \
  "$([ "$BRERC" -ne 0 ] && printf '%s' "$BREOUT" | grep -q 'outside \[A-Za-z0-9_-\]' && echo 0 || echo 1)"
printf 'op-x[y=MECHANICAL\n' > "$RP/.operator/tiers.env"
( cd "$RP" && RENDERENV --show >/dev/null 2>&1 ); BRE2RC=$?
check "guard: seat name with an unbalanced bracket is refused, no raw grep error" \
  "$([ "$BRE2RC" -ne 0 ] && ! ( cd "$RP" && RENDERENV --show 2>&1 | grep -q 'brackets' ) && echo 0 || echo 1)"
# A legitimate override still works: project seat line re-tiers scout, record intact.
printf 'op-scout=MECHANICAL\n' > "$RP/.operator/tiers.env"
OVR="$( cd "$RP" && RENDERENV --show 2>/dev/null )"
check "literal override: scout re-tiered, no other seat lost" \
  "$(printf '%s' "$OVR" | grep -q 'scout.*MECHANICAL.*project' && [ "$(printf '%s\n' "$OVR" | grep -c -E ' (default|project)$')" -eq 6 ] && echo 0 || echo 1)"

rm -rf "$RP"

########################################################################
echo "-- Case: ops-render --check probes without writing"
# --check is a documented user-facing branch (commands/tiers.md: "Use before
# render to catch a typo'd or dead id") that no test invoked. It renders to a
# temp dir, probes each distinct NON-claude id against cc-proxy, and refuses on
# a failed probe. claude-* ids are harness-served and skipped, so an all-claude
# config passes with no proxy running at all.
CKP="$(newproj)"; mkdir -p "$CKP/.operator"
printf 'MECHANICAL=glm-5-turbo\n' > "$CKP/.operator/tiers.env"
CKOUT="$( cd "$CKP" && RENDERENV --check 2>&1 )"; CKRC=$?
check "--check refuses when a model id fails the liveness probe" \
  "$([ "$CKRC" -ne 0 ] && printf '%s' "$CKOUT" | grep -q 'probe FAILED' && echo 0 || echo 1)"
check "--check writes nothing to .claude/agents/" \
  "$([ ! -d "$CKP/.claude" ] && echo 0 || echo 1)"
check "--check skips harness-served claude-* ids (no proxy needed for them)" \
  "$(printf '%s' "$CKOUT" | grep -q 'claude-opus-5: skipped' && echo 0 || echo 1)"
# All-claude config: nothing to probe, so it passes against a dead port.
printf 'MECHANICAL=claude-haiku-4-5-20251001\n' > "$CKP/.operator/tiers.env"
CKOUT2="$( cd "$CKP" && RENDERENV --check 2>&1 )"; CK2RC=$?
check "--check passes when every id is harness-served" \
  "$([ "$CK2RC" -eq 0 ] && printf '%s' "$CKOUT2" | grep -q 'check passed' && echo 0 || echo 1)"
rm -rf "$CKP"

########################################################################
echo "-- Case: ops-render splices into a CRLF template (F29)"
# The awk splice anchors its frontmatter delimiters on /^---$/, which `---\r`
# does NOT match. Pre-fix, a CRLF template made infm never set, so EVERY
# substitution branch was skipped and the file copied through verbatim: the
# rendered agent kept the template's literal `NAME` placeholder and its stale
# `model:` value, exit 0, "rendered N seat(s)". The old post-splice guard
# (`grep -q '^model:'`) could not see it — it matched the untouched line.
#
# Needs a CRLF template, and templates resolve from the PLUGIN root (not the
# fixture project), so mirror the two scripts + a CRLF default.tmpl into a
# throwaway plugin root and render a project against that.
CRP="$(newproj)"; CRM="$(newproj)"
mkdir -p "$CRM/scripts" "$CRM/agents/_templates" "$CRP/.operator"
cp "$SCRIPTS/ops-render.sh" "$SCRIPTS/ops-tiers.sh" "$CRM/scripts/"
printf -- '---\r\nname: NAME\r\nmodel: haiku\r\ndescription: d\r\n---\r\nbody\r\n' \
  > "$CRM/agents/_templates/default.tmpl"
printf 'op-widget=MECHANICAL\nMECHANICAL=glm-5-turbo\n' > "$CRP/.operator/tiers.env"
( cd "$CRP" && CC_OPERATOR_TIERS_USER=/nonexistent CC_PROXY_PORT=1 \
    "$BASH_ABS" "$CRM/scripts/ops-render.sh" >/dev/null 2>&1 ); CRRC=$?
check "CRLF template: render exits 0" "$([ "$CRRC" -eq 0 ] && echo 0 || echo 1)"
check "CRLF template: model: splice lands (not the template's stale value)" \
  "$(grep -q '^model: glm-5-turbo$' "$CRP/.claude/agents/op-widget.md" 2>/dev/null && echo 0 || echo 1)"
check "CRLF template: name: placeholder is replaced, not shipped literally" \
  "$(grep -q '^name: op-widget$' "$CRP/.claude/agents/op-widget.md" 2>/dev/null && echo 0 || echo 1)"
check "CRLF template: rendered agent carries no CR" \
  "$(! grep -q $'\r' "$CRP/.claude/agents/op-widget.md" 2>/dev/null && echo 0 || echo 1)"
# The post-splice guard must assert the VALUE. A template with no model: line
# renders an agent bound to the default backend; catch it loudly.
printf -- '---\nname: NAME\ndescription: d\n---\nbody\n' \
  > "$CRM/agents/_templates/default.tmpl"
find "$CRP/.claude" -type f -delete 2>/dev/null
( cd "$CRP" && CC_OPERATOR_TIERS_USER=/nonexistent CC_PROXY_PORT=1 \
    "$BASH_ABS" "$CRM/scripts/ops-render.sh" >/dev/null 2>&1 ); NMRC=$?
check "template with no model: line is refused (non-zero exit)" \
  "$([ "$NMRC" -ne 0 ] && echo 0 || echo 1)"
rm -rf "$CRP" "$CRM"

########################################################################
echo "-- Case: statusline shows workflow progress (journal-based ratio)"
# The wf segment reads the session's newest LIVE journal.jsonl (done/started
# ratio). It is NOT a % (total isn't known until the last dispatch — a % that
# lies is the failure the file header was written to avoid). Fails toward
# silence: absent/stale journal → no segment. Reuses the Case-22 `render` helper
# + project $P (an operator project).
# A FRESH operator project: Case 22's $P has open sentinels by now, which would
# prefix the bar with op[...] and mask the wf-only assertion.
WFPROJ="$(newproj)"; ( cd "$WFPROJ" && bash "$INIT" >/dev/null 2>&1 )
WFSESS="wf-sess-test"
WFDIR="$HOME/.claude/projects/wftestproj/$WFSESS/subagents/workflows/wf_abc"
mkdir -p "$WFDIR"
# Backdate a file past the liveness window. `date -v` is BSD-only and `date -d`
# is GNU-only: the BSD form silently produced an EMPTY string on the Linux CI
# runner, so `touch -t ""` failed and the "stale" cases never actually
# backdated anything (they passed for the wrong reason while the live cases
# failed). `touch -t` with an explicit past stamp works on both.
backdate() { # backdate <path>
  touch -t 202601010000 "$1"
}
mkjournal() { # mkjournal <started> <result>
  : > "$WFDIR/journal.jsonl"
  i=0; while [ "$i" -lt "$1" ]; do i=$((i+1)); printf '%s\n' '{"type":"started","key":"v2:k","agentId":"a'$i'"}' >> "$WFDIR/journal.jsonl"; done
  i=0; while [ "$i" -lt "$2" ]; do i=$((i+1)); printf '%s\n' '{"type":"result","key":"v2:k","agentId":"a'$i'","result":null}' >> "$WFDIR/journal.jsonl"; done
}
mkjournal 12 5
# No open tasks in $P, so the only segment is the wf ratio. Strip ANSI → "wf 5/12".
check "live journal → renders 'wf 5/12' (done/started, not a %)" \
  "$([ "$(render "$WFSESS" "$WFPROJ")" = "wf 5/12" ] && echo 0 || echo 1)"
check "wf segment is dim (not red — a running workflow is not actionable)" \
  "$(sljson "$WFSESS" "$WFPROJ" | "$BASH_ABS" "$SL" 2>/dev/null | grep -q $'\033\[2m' && echo 0 || echo 1)"
# Fresh run: started>0, done=0. `grep -c` prints "0" AND exits 1 on zero
# matches — a `|| echo 0` fallback captured "0\n0" and rendered a two-line
# segment that broke the composed bar (audit F12, hit on a live run's whole
# first phase). Assert one line AND the exact ratio.
mkjournal 3 0
WF0="$(render "$WFSESS" "$WFPROJ")"
check "fresh run (done=0) → renders 'wf 0/3' on ONE line (F12)" \
  "$([ "$WF0" = "wf 0/3" ] && echo 0 || echo 1)"
# Stale journal: backdate >90s → no wf segment (liveness fails → render nothing,
# since $P has no open tasks either).
mkjournal 12 5
backdate "$WFDIR/journal.jsonl"
check "stale journal (>90s) → no wf segment" \
  "$([ -z "$(render "$WFSESS" "$WFPROJ")" ] && echo 0 || echo 1)"
# Long dispatch: journal quiet >90s but an agent transcript in the same dir is
# fresh — the run is LIVE (journals are appended only on dispatch events, so a
# single long agent run legitimately silences the journal for minutes; audit
# F26). Liveness = newest of journal + agent-*.jsonl.
printf '%s\n' '{"x":1}' > "$WFDIR/agent-live.jsonl"
check "quiet journal + fresh agent transcript → still live (F26)" \
  "$([ "$(render "$WFSESS" "$WFPROJ")" = "wf 5/12" ] && echo 0 || echo 1)"
# ...and when the transcript is ALSO stale, the run is genuinely stopped.
backdate "$WFDIR/agent-live.jsonl"
check "quiet journal + stale agent transcript → no wf segment" \
  "$([ -z "$(render "$WFSESS" "$WFPROJ")" ] && echo 0 || echo 1)"
rm -f "$WFDIR/agent-live.jsonl"
# UNBALANCED journal (started>result) = a dispatch in flight; mtime silence
# proves nothing (a measured GLM run went >110s with the whole dir untouched —
# the 90s window declared it dead and the segment flapped off mid-run,
# 2026-08-03). Quiet-but-unbalanced stays live up to STALL_SEC (default 900).
agequiet() { # agequiet <path> <seconds-ago>
  python3 -c "import os,sys,time; t=time.time()-int(sys.argv[2]); os.utime(sys.argv[1],(t,t))" "$1" "$2"
}
mkjournal 12 5
agequiet "$WFDIR/journal.jsonl" 300
check "unbalanced journal quiet 300s → STILL live (dispatch in flight, no flap)" \
  "$([ "$(render "$WFSESS" "$WFPROJ")" = "wf 5/12" ] && echo 0 || echo 1)"
# ...but a BALANCED journal (started==result: run finished) keeps the tight
# 90s window — a completed run must clear the bar promptly, not linger 15min.
mkjournal 5 5
agequiet "$WFDIR/journal.jsonl" 300
check "balanced journal quiet 300s → no wf segment (finished runs clear fast)" \
  "$([ -z "$(render "$WFSESS" "$WFPROJ")" ] && echo 0 || echo 1)"
# ...and unbalanced past STALL_SEC is genuinely dead (errored agents never
# write a result line — observed same day: both shards died on a rate limit —
# so an unbalanced journal is ALSO the signature of a failed run; without this
# backstop it would render forever).
mkjournal 12 5
agequiet "$WFDIR/journal.jsonl" 1200
check "unbalanced journal quiet past STALL_SEC (1200s) → no wf segment (failed-run backstop)" \
  "$([ -z "$(render "$WFSESS" "$WFPROJ")" ] && echo 0 || echo 1)"
# Missing journal entirely → nothing (the fail-toward-silence default).
: > "$WFDIR/journal.jsonl"   # empty: zero started → no ratio
check "empty journal (0 started) → no wf segment" \
  "$([ -z "$(render "$WFSESS" "$WFPROJ")" ] && echo 0 || echo 1)"
rm -rf "$HOME/.claude/projects/wftestproj"

########################################################################
echo "-- Case: ops-claims verifies diff-matches-claims (C1/C2/C3) + expect-clean [F-A3/F-A2/F-A1]"
# A fresh project with a base commit, then staged/unstaged/untracked changes.
# ops-claims reads git state, so each sub-case mutates the tree and reads the
# exit code + stdout. Every sub-case here is revert-discriminating: the check
# it exercises is named in its fail message, and removing that check from
# ops-claims.sh flips the asserted exit code.
P="$(newproj)"
( cd "$P" && git init -q && git config user.email t@t && git config user.name t )
printf 'a\n' > "$P/a.txt"; printf 'b\n' > "$P/b.txt"
mkdir "$P/tests"; printf 'x\n' > "$P/tests/t.sh"
( cd "$P" && git add -A && git commit -qm base )
runclaims() { ( cd "$P" && bash "$CLAIMS" "$@" ); }   # → exit code, stdout on fd1
# clean_tree: revert ALL changes (staged + unstaged + untracked) to the current
# HEAD so each sub-case starts from a known-clean base. `git checkout .` alone
# misses STAGED changes (a `git rm`/`git mv` stages), so reset --hard + clean.
# State leaks between sub-cases are a real bug class — a case that passes
# against leftover state proves nothing.
clean_tree() { ( cd "$P" && git reset -q --hard HEAD >/dev/null 2>&1 && git clean -qfd ); }

# C1 green: claim exactly the one touched path.
printf 'a2\n' > "$P/a.txt"
runclaims --claimed "a.txt" >/dev/null 2>&1; C1G=$?
check "C1 green: claim matches the single touched path" "$([ "$C1G" = 0 ] && echo 0 || echo 1)"

# C1 fail: an unclaimed touched path (b.txt modified, not claimed). Capture the
# NAMING before reverting — the output line exists only while b.txt is dirty.
printf 'b2\n' > "$P/b.txt"
C1OUT="$(runclaims --claimed "a.txt" 2>/dev/null)"; C1F=$?
clean_tree
check "C1 fail: touched-but-unclaimed path → non-zero" "$([ "$C1F" != 0 ] && echo 0 || echo 1)"
check "C1 fail names 'unclaimed-change'" "$(printf '%s' "$C1OUT" | grep -q unclaimed-change && echo 0 || echo 1)"

# C2 fail: a claimed path with no actual change (phantom-claim). Clean tree,
# claim a.txt + c.txt — neither is changed → both phantom.
C2OUT="$(runclaims --claimed "a.txt c.txt" 2>/dev/null)"; C2F=$?
check "C2 fail: claimed-but-untouched path → non-zero" "$([ "$C2F" != 0 ] && echo 0 || echo 1)"
check "C2 fail names 'phantom-claim'" "$(printf '%s' "$C2OUT" | grep -q phantom-claim && echo 0 || echo 1)"

# C2 green with a directory-prefix claim: 'tests/' satisfied by tests/t.sh.
# tests/ is a PROTECTED path, so this needs --gate-task or C3 (rightly) fails it.
printf 'y\n' >> "$P/tests/t.sh"
runclaims --claimed "tests/" --gate-task >/dev/null 2>&1; C2D=$?
check "C2 green: dir-prefix claim 'tests/' satisfied by tests/t.sh" "$([ "$C2D" = 0 ] && echo 0 || echo 1)"

# C3 fail: a touched protected path (tests/) without --gate-task.
C3OUT="$(runclaims --claimed "tests/" 2>/dev/null)"; C3F=$?
check "C3 fail: protected path touched without --gate-task → non-zero" "$([ "$C3F" != 0 ] && echo 0 || echo 1)"
check "C3 fail names 'gate-trespass'" "$(printf '%s' "$C3OUT" | grep -q gate-trespass && echo 0 || echo 1)"

# C3 pass: same tree, --gate-task authorizes the gate edit.
runclaims --claimed "tests/" --gate-task >/dev/null 2>&1; C3P=$?
check "C3 pass: protected path allowed with --gate-task" "$([ "$C3P" = 0 ] && echo 0 || echo 1)"
clean_tree

# CHANGED: none — clean working tree, no claims, no trespass.
runclaims --claimed none >/dev/null 2>&1; CNG=$?
check "CHANGED none: clean tree, no claims → exit 0" "$([ "$CNG" = 0 ] && echo 0 || echo 1)"

# --expect-clean green: tree empty apart from .operator/ (none here).
runclaims --expect-clean >/dev/null 2>&1; ECG=$?
check "--expect-clean green on a clean tree" "$([ "$ECG" = 0 ] && echo 0 || echo 1)"

# --expect-clean fail: a stray file beyond .operator/.
printf 'z\n' > "$P/stray.txt"
runclaims --expect-clean >/dev/null 2>&1; ECF=$?
check "--expect-clean fail on a stray non-ledger file" "$([ "$ECF" != 0 ] && echo 0 || echo 1)"
clean_tree

# --expect-clean exempts .operator/ ledger paths: scaffold + a verdict row, then
# expect-clean must still pass (a verdict is a normal side-effect of a dispatch).
( cd "$P" && bash "$INIT" >/dev/null 2>&1 )
printf 'row\n' >> "$P/.operator/VERDICTS.md"
runclaims --expect-clean >/dev/null 2>&1; ECL=$?
check "--expect-clean exempts .operator/ ledger paths" "$([ "$ECL" = 0 ] && echo 0 || echo 1)"

# Untracked detection: an untracked file is an actual change caught by C1.
clean_tree
printf 'u\n' > "$P/untracked.txt"
runclaims --claimed "a.txt" >/dev/null 2>&1; UNC=$?
check "untracked file detected as an actual change (C1)" "$([ "$UNC" != 0 ] && echo 0 || echo 1)"

# Charset/traversal discipline on --claimed: '..' traversal is rejected.
runclaims --claimed "../etc" >/dev/null 2>&1; TRV=$?
check "claimed '..' traversal is rejected" "$([ "$TRV" != 0 ] && echo 0 || echo 1)"
# '|' in a claimed path is rejected (would break the list contract).
runclaims --claimed "a.txt|injected" >/dev/null 2>&1; PIP=$?
check "claimed '|' is rejected" "$([ "$PIP" != 0 ] && echo 0 || echo 1)"

# --since default is HEAD: a change present at HEAD but not in the working tree
# is NOT an actual change. Commit a.txt's modification, then claim only HEAD
# paths — clean working tree → CHANGED none is green. (Confirms --since=HEAD.)
( cd "$P" && git checkout -q . && git clean -qfd )
printf 'a2\n' > "$P/a.txt"
( cd "$P" && git add -A && git commit -qm second )
runclaims --claimed none >/dev/null 2>&1; SINCE=$?
check "--since defaults to HEAD: committed change is not a working-tree change" "$([ "$SINCE" = 0 ] && echo 0 || echo 1)"

# --- adversarial cases (REFUTED review 2026-08-04): the F-A2 attack surface ---
# These reproduce each must-resolve finding the review caught. Every one is the
# exact shape that evaded the first version; they MUST stay green or the parse
# has regressed back to word-split / pathname-expansion.
clean_tree

# C3 must fire on a DELETED gate CLI — the exact F-A2 attack. The first version's
# `for pat in $PROTECTED` pathname-expanded, so a deleted file matched nothing.
mkdir -p "$P/scripts"
printf 'stub\n' > "$P/scripts/ops-verdict.sh"
( cd "$P" && git add -A && git commit -qm gatefiles >/dev/null 2>&1 )
# Working-tree deletion: the file was committed, now rm it. git diff HEAD and
# porcelain both report the path as deleted/removed — the pattern must catch it.
rm -f "$P/scripts/ops-verdict.sh"
DELVIEW="$(cd "$P" && git status --porcelain --untracked-files=all scripts/ops-verdict.sh)"
DELOUT="$(runclaims --claimed 'scripts/ops-verdict.sh' 2>/dev/null)"; DEL=$?
check "F-A2 setup: the deleted gate CLI is in git's view" \
  "$([ -n "$DELVIEW" ] && echo 0 || echo 1)"
check "C3 fires on a DELETED gate CLI (F-A2 attack; pathname-expansion fix)" \
  "$([ "$DEL" != 0 ] && echo 0 || echo 1)"
check "deletion names 'gate-trespass'" \
  "$(printf '%s' "$DELOUT" | grep -q gate-trespass && echo 0 || echo 1)"
clean_tree

# A path WITH A SPACE is one item, not shredded. The first version word-split
# `my file.txt` into `my` + `file.txt`. Untracked (so porcelain -z must carry it).
printf 'x\n' > "$P/my file.txt"
SCOUT="$(runclaims --claimed none 2>/dev/null)"
check "path with a space is one unclaimed-change item (not shredded)" \
  "$(printf '%s' "$SCOUT" | grep -q '{item my file.txt}' && echo 0 || echo 1)"
clean_tree

# A bad --since ref is rejected, not silently degraded to "no changes" (which
# would false-green a committed gate-trespass). The first version swallowed it.
printf 'a2\n' > "$P/a.txt"
runclaims --claimed none --since not-a-real-ref-xyz >/dev/null 2>&1; BADS=$?
check "invalid --since ref is rejected (no silent false-green)" "$([ "$BADS" != 0 ] && echo 0 || echo 1)"
clean_tree

# A renamed file: git mv yields a rename entry. The first version parsed
# 'R old -> new' into a garbage '->' item. Both old and new must be seen as
# changes (a renamed gate CLI must not evade C3).
mkdir -p "$P/hooks"; printf 'orig\n' > "$P/hooks/h.sh"
( cd "$P" && git add -A && git commit -qm hookbase >/dev/null 2>&1 )
( cd "$P" && git mv hooks/h.sh hooks/renamed.sh >/dev/null 2>&1 )
MVVIEW="$(cd "$P" && git status --porcelain --untracked-files=all hooks/)"
MVOUT="$(runclaims --claimed 'hooks/' --gate-task 2>/dev/null)"; MV=$?
check "F-A2 rename setup: the rename is in git's view" \
  "$([ -n "$MVVIEW" ] && echo 0 || echo 1)"
check "rename: hooks/ claimed + --gate-task → green (both paths recognized)" "$([ "$MV" = 0 ] && echo 0 || echo 1)"
check "rename does not emit a garbage '->' item" \
  "$(printf '%s' "$MVOUT" | grep -qv '{item ->}' && echo 0 || echo 1)"
clean_tree

# Untracked file inside an UNTRACKED directory: --untracked-files=all must see
# the file, not just the dir. (No --untracked-files=all → only 'docs/'.)
mkdir -p "$P/docs/new"; printf 'm\n' > "$P/docs/new/a.md"
runclaims --claimed "docs/new/a.md" >/dev/null 2>&1; UTD=$?
check "untracked file in untracked dir is matched (--untracked-files=all)" "$([ "$UTD" = 0 ] && echo 0 || echo 1)"
clean_tree

# Leading-dot claimed path is rejected (the first version's comment promised it,
# the code did not implement it — review REFUTED, doc/code divergence).
runclaims --claimed ".hidden" >/dev/null 2>&1; DOT=$?
check "leading-dot claimed path rejected (doc/code divergence fix)" "$([ "$DOT" != 0 ] && echo 0 || echo 1)"

# Green run emits the SSSF 'what was verified' evidence line.
GE="$(runclaims --claimed none 2>/dev/null)"
check "green run emits a diff-matches-claims ok line" "$(printf '%s' "$GE" | grep -q 'diff-matches-claims} ok' && echo 0 || echo 1)"

# ops-claims does NOT read pending/ (not a sentinel reader): confirm it carries
# no sentinel-reader code path by checking it ignores a planted sentinel.
mkdir -p "$P/.operator/pending"; printf 'session_id: OTHER\n' > "$P/.operator/pending/planted"
runclaims --claimed none >/dev/null 2>&1; NPD=$?
check "ops-claims ignores .operator/pending (not a sentinel reader)" "$([ "$NPD" = 0 ] && echo 0 || echo 1)"
rm -rf "$P"

########################################################################
echo "-- Case: deviation-gate — unpresented decisions block Stop; --mark-handoff clears [stage 2]"
# The Stop hook's SECOND ledger: DECISIONS.md DEVIATION lines after the last
# mine/unowned HANDOFF-MARK block Stop. The 0.4.0 mine/unowned-vs-foreign
# partition applied to decisions. Every sub-case is revert-discriminating: the
# behavior it asserts is named, and removing that branch from scan_deviations
# flips the exit code. SESS-A is "this session"; SESS-B is foreign.
P="$(newproj)"
( cd "$P" && bash "$INIT" >/dev/null 2>&1 )
DEC="$P/.operator/DECISIONS.md"
SID="SESS-A-XYZ"
# A minimal Stop payload with session_id + cwd. The hook walks up from cwd to
# the nearest .operator/.
payload() { printf '{"session_id":"%s","stop_hook_active":false,"cwd":"%s"}' "$SID" "$P"; }

# Empty DECISIONS.md (just the header comments) → no deviations → exit 0.
printf '# Decisions\n# header only\n' > "$DEC"
payload | bash "$HOOK" >/dev/null 2>&1; D0=$?
check "empty DECISIONS.md → Stop allowed (no deviations)" "$([ "$D0" = 0 ] && echo 0 || echo 1)"

# A mine deviation (sid=SESS-A), no mark → blocks.
printf '2026-08-04 | eng.t | DEVIATION | [sid:%s] chose X over Y | reason\n' "$SID" > "$DEC"
payload | bash "$HOOK" >/dev/null 2>&1; D1=$?
check "mine deviation, no mark → Stop blocked" "$([ "$D1" = 2 ] && echo 0 || echo 1)"

# A foreign deviation (sid=SESS-B) → never blocks.
printf '2026-08-04 | eng.t | DEVIATION | [sid:SESS-B-OTHER] their call | reason\n' > "$DEC"
payload | bash "$HOOK" >/dev/null 2>&1; D2=$?
check "foreign deviation → Stop allowed (never blocks)" "$([ "$D2" = 0 ] && echo 0 || echo 1)"

# An untagged (legacy) deviation → blocks EVERY session (unowned = mine-class).
printf '2026-08-04 | eng.t | DEVIATION | pre-gate decision, no sid | reason\n' > "$DEC"
payload | bash "$HOOK" >/dev/null 2>&1; D3=$?
check "untagged (legacy) deviation → Stop blocked (unowned blocks all)" "$([ "$D3" = 2 ] && echo 0 || echo 1)"

# mine deviation, then a mine HANDOFF-MARK after it → cleared → exit 0.
{ printf '2026-08-04 | eng.t | DEVIATION | [sid:%s] chose X | r\n' "$SID"
  printf '2026-08-04 | eng | HANDOFF-MARK | [sid:%s] 2026-08-04T00:00:00Z | presented\n' "$SID"; } > "$DEC"
payload | bash "$HOOK" >/dev/null 2>&1; D4=$?
check "mine deviation + later mine mark → cleared (Stop allowed)" "$([ "$D4" = 0 ] && echo 0 || echo 1)"

# mark BEFORE the deviation does NOT clear it (file position, not timestamp).
{ printf '2026-08-04 | eng | HANDOFF-MARK | [sid:%s] 2026-08-04T00:00:00Z | presented\n' "$SID"
  printf '2026-08-04 | eng.t | DEVIATION | [sid:%s] new decision after mark | r\n' "$SID"; } > "$DEC"
payload | bash "$HOOK" >/dev/null 2>&1; D5=$?
check "mark BEFORE deviation does not clear it (position rule)" "$([ "$D5" = 2 ] && echo 0 || echo 1)"

# A foreign mark does not clear my deviation.
{ printf '2026-08-04 | eng.t | DEVIATION | [sid:%s] mine | r\n' "$SID"
  printf '2026-08-04 | eng | HANDOFF-MARK | [sid:SESS-B] their handoff | presented\n'; } > "$DEC"
payload | bash "$HOOK" >/dev/null 2>&1; D6=$?
check "foreign mark does not clear my deviation" "$([ "$D6" = 2 ] && echo 0 || echo 1)"

# ESCALATION and GATE-EXCEPTION are also decision kinds that block until marked.
printf '2026-08-04 | eng.t | ESCALATION | [sid:%s] escalated to human | r\n' "$SID" > "$DEC"
payload | bash "$HOOK" >/dev/null 2>&1; D7=$?
check "ESCALATION kind blocks like DEVIATION" "$([ "$D7" = 2 ] && echo 0 || echo 1)"

# A malformed line (CRLF) degrades to counted-as-unpresented → blocks. Write a
# mine deviation with a trailing \r on the kind, which breaks the kind parse so
# the line is not recognized as DEVIATION — but a degenerate line must fail
# toward blocking, not toward allowing. (The \r is stripped, so this IS parsed;
# the real malformed test is an over-long line — see the byte-cap case below.)
printf '2026-08-04 | eng.t | DEVIATION | [sid:%s] cr-test\r\n' "$SID" > "$DEC"
payload | bash "$HOOK" >/dev/null 2>&1; D8=$?
check "CRLF deviation still recognized (\\r stripped) → blocks" "$([ "$D8" = 2 ] && echo 0 || echo 1)"

# A NUL in the ledger → fail toward blocking (corrupt ledger counts as unpresented).
printf '2026-08-04 | eng.t | DEVIATION | [sid:%s] nul\000here | r\n' "$SID" > "$DEC"
payload | bash "$HOOK" >/dev/null 2>&1; D9=$?
check "NUL in DECISIONS.md → blocks (corrupt ledger fails toward blocking)" "$([ "$D9" = 2 ] && echo 0 || echo 1)"

# Absent DECISIONS.md → fail OPEN (missing ledger = scaffold problem, not a decision).
rm -f "$DEC"
payload | bash "$HOOK" >/dev/null 2>&1; D10=$?
check "absent DECISIONS.md → Stop allowed (fail OPEN)" "$([ "$D10" = 0 ] && echo 0 || echo 1)"

# A pending SENTINEL still blocks even with no deviations (the two gates compose).
printf '# Decisions\n' > "$DEC"
( cd "$P" && bash "$TASK" both-gate --owner "$SID" >/dev/null 2>&1 )
payload | bash "$HOOK" >/dev/null 2>&1; D11=$?
check "pending sentinel blocks even with no deviations (gates compose)" "$([ "$D11" = 2 ] && echo 0 || echo 1)"
( cd "$P" && bash "$VERDICT" both-gate c e PASS --owner "$SID" >/dev/null 2>&1 )

# --- ops-verdict.sh --mark-handoff ---
# Requires --owner (empty sid would clear every session = privilege inversion).
( cd "$P" && bash "$VERDICT" --mark-handoff >/dev/null 2>&1 ); MH0=$?
check "--mark-handoff without --owner → refused" "$([ "$MH0" != 0 ] && echo 0 || echo 1)"
# Writes a HANDOFF-MARK line under the lock, clearing my deviations.
printf '2026-08-04 | eng.t | DEVIATION | [sid:%s] pre-mark decision | r\n' "$SID" > "$DEC"
( cd "$P" && bash "$VERDICT" --mark-handoff --owner "$SID" >/dev/null 2>&1 ); MH1=$?
check "--mark-handoff --owner writes the mark (exit 0)" "$([ "$MH1" = 0 ] && echo 0 || echo 1)"
# After the mark, the same deviation no longer blocks.
payload | bash "$HOOK" >/dev/null 2>&1; MH2=$?
check "after --mark-handoff, the deviation is cleared" "$([ "$MH2" = 0 ] && echo 0 || echo 1)"
# The mark line is in the pipe schema with the [sid:] tag.
check "--mark-handoff line carries the [sid:] tag" "$(grep -q 'HANDOFF-MARK.*\[sid:' "$DEC" && echo 0 || echo 1)"
# A foreign owner cannot write a mark that would clear MY deviations (the mark's
# sid is foreign, so it never clears mine — verified by the partition above).

rm -rf "$P"

########################################################################
echo "== summary: $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]
