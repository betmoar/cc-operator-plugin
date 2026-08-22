#!/usr/bin/env bash
# Operator plugin plain-bash test runner (T2 contract). bash tests/test-scripts.sh

set -u

# Suppresses __pycache__ from the ~43 python3 shellouts (gitignored, so a stale .pyc is invisible to git status).
# The #23 fixture opts out in its own subshell since its mechanism IS a written .pyc.
export PYTHONDONTWRITEBYTECODE=1

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

# Absolute bash so a restricted PATH (case 5) governs only the hook's internal jq/python3 lookups.
BASH_ABS="$(command -v bash)"
# Oldest available bash: F46 (NUL-padded sentinel smuggling an owner) is exploitable on 3.2, invisible on 5.x.
BASH_OLD="$BASH_ABS"
if [ -x /bin/bash ]; then
    # shellcheck disable=SC2016  # ${BASH_VERSINFO} must expand in the CHILD bash being probed.
  _obv="$(/bin/bash -c 'echo ${BASH_VERSINFO[0]}' 2>/dev/null || echo 9)"
  # shellcheck disable=SC2016
  _nbv="$("$BASH_ABS" -c 'echo ${BASH_VERSINFO[0]}' 2>/dev/null || echo 9)"
  [ "$_obv" -lt "$_nbv" ] && BASH_OLD=/bin/bash
fi

PASS=0
FAIL=0
pass() { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
# Names are accumulated, not just printed, so an intermittent failure can be identified after a re-run.
FAILED_NAMES=""
fail() { FAIL=$((FAIL+1)); FAILED_NAMES="$FAILED_NAMES
  $1"; printf '  FAIL %s\n' "$1"; }
check() { # check <desc> <0|1 condition-result>
  if [ "$2" -eq 0 ]; then pass "$1"; else fail "$1"; fi
}

# Fresh temp project; return its path.
newproj() { mktemp -d "${TMPDIR:-/tmp}/opstest.XXXXXX"; }

# Ownership lives in the sentinel's NAME (<owner>__<task>, or bare <task> when unowned); one helper for the convention.
sentinel_any() { # sentinel_any <proj> <task> → 0 when a sentinel exists under any owner
  local _f
  for _f in "$1/.operator/pending/$2" "$1"/.operator/pending/*__"$2"; do
    { [ -e "$_f" ] || [ -L "$_f" ]; } && return 0
  done
  return 1
}

sentinel() { # sentinel <proj> <task> [<owner>] → path
  if [ -n "${3:-}" ]; then printf '%s\n' "$1/.operator/pending/$3__$2"
  else printf '%s\n' "$1/.operator/pending/$2"; fi
}

# Kill a backgrounded job's children before the job (#68): `$!` misses the grandchild bash, which leaked processes.
# pgrep's status is checked (not swallowed) so a tool failure is reported rather than masquerading as a clean reap.
reap_kids() { # reap_kids <pid>
  local _pid="$1" _kids _rc _k
  _kids="$(pgrep -P "$_pid" 2>&1)"; _rc=$?
  if [ "$_rc" -gt 1 ]; then
    echo "  warning: pgrep -P $_pid failed (rc=$_rc: $_kids) — grandchild reap incomplete on this platform" >&2
    return 0
  fi
  for _k in $_kids; do kill -9 "$_k" 2>/dev/null || true; done
}

# Feed the hook a Stop payload from a fixture; captures exit code (HRC) and stderr (HERR).
run_hook() { # run_hook <fixture> <cwd> [restricted-PATH]
  local fixture="$1" cwd="$2" rpath="${3:-}"
  local json; json="$(sed "s|<tmp>|$cwd|" "$FIXTURES/$fixture")"
  local errf; errf="$(mktemp)"
  if [ -n "$rpath" ]; then
        # Restrict only the hook's PATH so PATH loss can't stop the hook launching at all.
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
# The stamp is matched as a token, not pinned to `no-vcs` — a TMPDIR inside a real repo legitimately stamps a sha.
ROW='^\| T-1 \| tests pass \| 42 passed, 0 failed @[^ |]+ \| PASS \|$'
if [ -f "$P/.operator/VERDICTS.md" ]; then
  N="$(grep -Ec "$ROW" "$P/.operator/VERDICTS.md" 2>/dev/null)"
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
check "empty-evidence leaves sentinel intact" "$(sentinel_any "$P" T-2 && echo 0 || echo 1)"
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
# Resolve the REAL python3 interpreter (sys.executable): a pyenv/asdf shim won't run under a minimal PATH.
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
# Re-run refreshes the bin copies (the upgrade path); ledgers are never clobbered.
printf '#!/usr/bin/env bash\necho stale\n' > "$P/.operator/bin/ops-verdict.sh"
( cd "$P" && bash "$INIT" >/dev/null 2>&1 )
check "second init refreshes bin copy to plugin version" "$(cmp -s "$P/.operator/bin/ops-verdict.sh" "$VERDICT" && echo 0 || echo 1)"
# ops-task opens the sentinel; the installed CLIs work from the project cwd
( cd "$P" && ./.operator/bin/ops-task.sh T-6 >/dev/null 2>&1 ); TRC=$?
check "ops-task exits 0 and drops sentinel" "$([ "$TRC" -eq 0 ] && sentinel_any "$P" T-6 && echo 0 || echo 1)"
run_hook stop-basic.json "$P"
check "hook blocks (exit 2) on ops-task-opened sentinel" "$([ "$HRC" -eq 2 ] && echo 0 || echo 1)"
check "block message names .operator/bin/ops-verdict.sh" "$(printf '%s' "$HERR" | grep -q '\.operator/bin/ops-verdict\.sh' && echo 0 || echo 1)"
( cd "$P" && ./.operator/bin/ops-verdict.sh T-6 "crit" "output" PASS >/dev/null 2>&1 )
check "installed verdict CLI appends row + clears sentinel" "$(grep -Eq '^\| T-6 \| crit \| output @[^ |]+ \| PASS \|$' "$P/.operator/VERDICTS.md" && [ ! -e "$P/.operator/pending/T-6" ] && echo 0 || echo 1)"
# ops-task refusals: no id; no .operator/
( cd "$P" && ./.operator/bin/ops-task.sh >/dev/null 2>&1 ); NRC=$?
check "ops-task refuses a missing task-id" "$([ "$NRC" -ne 0 ] && echo 0 || echo 1)"
Q="$(newproj)"
( cd "$Q" && bash "$TASK" T-1 >/dev/null 2>&1 ); QRC=$?
check "ops-task refuses without .operator/" "$([ "$QRC" -ne 0 ] && echo 0 || echo 1)"
rm -rf "$Q"

echo "-- Case: ops-task does not claim a non-regular entry in pending/ is 'already open'"
# A directory or dangling symlink in pending/ is not a task sentinel; the old else-branch conflated every open
# failure with "already open" and exited 0 while the hook's `-f` guard refused to count it (P1, review-panel 2026-07-29).
P2="$(newproj)"; ( cd "$P2" && bash "$INIT" >/dev/null 2>&1 )
# directory: the open must fail, not silently report "already open"
mkdir -p "$P2/.operator/pending/T-DIR"
( cd "$P2" && ./.operator/bin/ops-task.sh T-DIR --owner SESS-A >/dev/null 2>&1 ); DRC=$?
check "ops-task refuses to open over a directory (non-zero exit)" "$([ "$DRC" -ne 0 ] && echo 0 || echo 1)"
( cd "$P2" && ./.operator/bin/ops-task.sh T-DIR --owner SESS-A 2>&1 ) | grep -qi "already open" && echo "FAIL: ops-task falsely reports a directory as already open" >&2
check "ops-task does not claim a directory is 'already open'" "$([ "$DRC" -ne 0 ] && echo 0 || echo 1)"
# Dangling symlink: same failure mode — the redirection fails and old code reported it as already-open + exit 0.
ln -s /nonexistent "$P2/.operator/pending/T-DEAD"
( cd "$P2" && ./.operator/bin/ops-task.sh T-DEAD --owner SESS-A >/dev/null 2>&1 ); LRC=$?
check "ops-task refuses to open over a dangling symlink (non-zero exit)" "$([ "$LRC" -ne 0 ] && echo 0 || echo 1)"
# Symlink to a regular file: `-f` follows it and reads true, so the old guard misreported a planted entry as live
# tracked work (Copilot 2026-08-03). `-L` must reject it before the target is ever touched.
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
# A legit already-open task (a real sentinel file) must still report already-open and exit 0.
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
# The F65 -L guard landed only at the write site; every READ site kept plain `-f`, which follows symlinks — a
# planted symlink was laundered into a trusted sentinel by every downstream reader (code-review of f4cae1a, 2026-08-04).
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
# A symlink is not a claim of ownership; it must read as UNOWNED (blocks everyone), never as SESS-A's foreign task.
run_hook stop-session-b.json "$P"
check "Stop hook blocks a bystander on a symlink sentinel (unowned, exit 2)" "$([ "$HRC" -eq 2 ] && echo 0 || echo 1)"
check "Stop hook does not attribute the symlink to the target's owner" "$(printf '%s' "$HERR" | grep -q 'owned by SESS-A' && echo 1 || echo 0)"
# statusline: same partition — unowned counts as MINE-blocking, never foreign
SYSL="$(printf '{"session_id":"SESS-B","cwd":"%s","workspace":{"project_dir":"%s"}}' "$P" "$P" \
  | "$BASH_ABS" "$SCRIPTS/statusline.sh" 2>/dev/null | LC_ALL=C tr -d '\033' | LC_ALL=C sed 's/\[[0-9]*m//g')"
check "statusline counts a symlink sentinel as blocking, not foreign" "$([ "$SYSL" = "op[1]" ] && echo 0 || echo 1)"
rm -f "$_SYT"; rm -rf "$P"

########################################################################
echo "-- Case: a planted symlink FRAGMENT in verdicts.d/ is refused (F2/F65)"
# The F65 -L guard never reached verdicts.d/: a planted symlink fragment made every verdict row append THROUGH it,
# silently, at exit 0. Write must refuse and reads must skip it.
P="$(newproj)"; ( cd "$P" && bash "$INIT" >/dev/null 2>&1 )
( cd "$P" && bash "$TASK" T-FRAG --owner SESSX >/dev/null 2>&1 )
_FT="$(mktemp "${TMPDIR:-/tmp}/opstest-fragtgt.XXXXXX")"
mkdir -p "$P/.operator/verdicts.d"
ln -s "$_FT" "$P/.operator/verdicts.d/SESSX.md"
VB0="$(wc -l < "$P/.operator/VERDICTS.md")"
FOUT="$( cd "$P" && bash "$VERDICT" T-FRAG crit ev PASS --owner SESSX 2>&1 )"; FRC=$?
check "verdict refuses a symlink fragment (non-zero exit)" "$([ "$FRC" -ne 0 ] && echo 0 || echo 1)"
check "the refusal names the symlink fragment" "$(printf '%s' "$FOUT" | grep -qi 'symlink' && echo 0 || echo 1)"
check "no ledger row was written for the symlink fragment" "$([ "$(wc -l < "$P/.operator/VERDICTS.md")" -eq "$VB0" ] && echo 0 || echo 1)"
check "the symlink's outside target was not written through" "$([ ! -s "$_FT" ] && echo 0 || echo 1)"
# the symlink must survive (not be launder-converted), so repair is possible
check "the symlink fragment was not launder-converted" "$([ -L "$P/.operator/verdicts.d/SESSX.md" ] && echo 0 || echo 1)"
rm -f "$_FT"; rm -rf "$P"

########################################################################
echo "-- Case 7: ledger cell hygiene — refuse, never corrupt (single-writer schema)"
# INVARIANT: a VERDICTS row is exactly one line of 4 pipe-delimited cells; the writer refuses anything that breaks it.
P="$(newproj)"; ( cd "$P" && bash "$INIT" >/dev/null 2>&1 )
ROWS_BEFORE="$(wc -l < "$P/.operator/VERDICTS.md")"
: > "$P/.operator/pending/T-P"
( cd "$P" && bash "$VERDICT" T-P "crit" "out: 3 | 0 failed" PASS >/dev/null 2>&1 ); PRC=$?
check "pipe in evidence → refused (exit != 0)" "$([ "$PRC" -ne 0 ] && echo 0 || echo 1)"
check "pipe in evidence → no row, sentinel intact" "$([ "$(wc -l < "$P/.operator/VERDICTS.md")" = "$ROWS_BEFORE" ] && sentinel_any "$P" T-P && echo 0 || echo 1)"
( cd "$P" && bash "$VERDICT" T-P "crit" "$(printf 'l1\nl2')" PASS >/dev/null 2>&1 ); NRC=$?
check "newline in evidence → refused" "$([ "$NRC" -ne 0 ] && echo 0 || echo 1)"
( cd "$P" && bash "$VERDICT" T-P "crit" "evidence" MAYBE >/dev/null 2>&1 ); MRC=$?
check "verdict MAYBE → refused (PASS|FAIL only)" "$([ "$MRC" -ne 0 ] && echo 0 || echo 1)"
# INVARIANT: task-id is a bare filename, never a path (clear_sentinel's rm -f must not reach outside pending/).
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
# INVARIANT (spec §4.1 criteria 1+3): a session's Stop gate answers only for tasks it owns.
P="$(newproj)"; ( cd "$P" && bash "$INIT" >/dev/null 2>&1 )
( cd "$P" && bash "$TASK" T-A --owner SESS-A >/dev/null 2>&1 )
check "the sentinel NAME carries its owner" "$([ -f "$(sentinel "$P" T-A SESS-A)" ] && echo 0 || echo 1)"
check "…and no body field is required for that" "$(! grep -q 'session_id:' "$(sentinel "$P" T-A SESS-A)" && echo 0 || echo 1)"
# 8a: the owning session is blocked
run_hook stop-session-a.json "$P"
check "owner's Stop → exit 2 on its own task" "$([ "$HRC" -eq 2 ] && echo 0 || echo 1)"
check "owner's block message names T-A" "$(printf '%s' "$HERR" | grep -q 'T-A' && echo 0 || echo 1)"
# 8b: the bystander session is NOT blocked, but is told
run_hook stop-session-b.json "$P"
check "foreign session's Stop → exit 0 (not trapped)" "$([ "$HRC" -eq 0 ] && echo 0 || echo 1)"
check "foreign session is told, not blocked" "$(printf '%s' "$HERR" | grep -q 'owned by another session' && echo 0 || echo 1)"
# The report must name the OWNER, not just the task id, or a bystander cannot tell whom to chase.
check "foreign report names the owning session id" "$(printf '%s' "$HERR" | grep -q 'owned by SESS-A' && echo 0 || echo 1)"
# opened_at is gone with the body parser; task+owner is what makes the report actionable (trade recorded here).
check "foreign report names the task" "$(printf '%s' "$HERR" | grep -q 'T-A owned by' && echo 0 || echo 1)"
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
# F14: json_get()'s python3 branch must render true/false, not Python True/False (pinned by check_guard_parity).
# SessionStart migrates the v1 blocklist .operator/.gitignore to the v2 allowlist; the schemes contradict, so replace.
GIP="$(newproj)"; ( cd "$GIP" && bash "$INIT" >/dev/null 2>&1 )
printf '# legacy\n.lock/\n' > "$GIP/.operator/.gitignore"
sed "s|<tmp>|$GIP|" "$FIXTURES/sessionstart.json" | "$BASH_ABS" "$SSHOOK" >/dev/null 2>&1
check "sessionstart migrates a v1 gitignore to the v2 allowlist" \
  "$(grep -qF '# cc-operator gitignore v2 (allowlist)' "$GIP/.operator/.gitignore" && echo 0 || echo 1)"
check "the v2 migration keeps the user's v1 file as .v1.bak" \
  "$(grep -q '^# legacy$' "$GIP/.operator/.gitignore.v1.bak" 2>/dev/null && echo 0 || echo 1)"
# The load-bearing half: ledgers/fragments stay tracked, machine state does not.
check "v2 re-admits both ledgers, tiers.env and the merge=union fragments" \
  "$( for a in '!VERDICTS.md' '!DECISIONS.md' '!tiers.env' '!verdicts.d/*.md'; do
        grep -qF "$a" "$GIP/.operator/.gitignore" || exit 1
      done; echo 0 )"
check "v2 ignores everything else by default (bare '*')" \
  "$(grep -qxF '*' "$GIP/.operator/.gitignore" && echo 0 || echo 1)"
# Compressor ephemera are covered by '*' now — no per-directory line needed.
check "v2 needs no explicit .compress-spill/ line (covered by '*')" \
  "$(grep -q '^\.compress-spill/$' "$GIP/.operator/.gitignore" && echo 1 || echo 0)"
# Idempotent: a second fire re-detects the marker and does not rewrite.
cp "$GIP/.operator/.gitignore" "$GIP/gi.before"
sed "s|<tmp>|$GIP|" "$FIXTURES/sessionstart.json" | "$BASH_ABS" "$SSHOOK" >/dev/null 2>&1
check "the v2 migration is idempotent (a second fire is a no-op)" \
  "$(cmp -s "$GIP/gi.before" "$GIP/.operator/.gitignore" && echo 0 || echo 1)"
# Pre-0.9.0 sentinels carry `session_id:` in the body; SessionStart renames to `<sid>__<task>` and the EFFECT
# must be asserted, not just non-firing on already-migrated names (PR #77 review found this gap).
MIG="$(newproj)"; ( cd "$MIG" && bash "$INIT" >/dev/null 2>&1 )
mkdir -p "$MIG/.operator/pending"
printf 'cwd: %s\nsession_id: OLD-SESS\nopened_at: 2026-08-01T00:00:00Z\n' "$MIG" > "$MIG/.operator/pending/legacy-task"
printf 'cwd: %s\nopened_at: 2026-08-01T00:00:00Z\n' "$MIG"           > "$MIG/.operator/pending/unowned-task"
printf 'session_id: bad__sid\n'                                       > "$MIG/.operator/pending/badsep-task"
printf 'session_id: OLD-SESS\n'                                       > "$MIG/.operator/pending/deep-task"   # under the line bound
{ for _i in $(seq 1 30); do echo filler; done; echo 'session_id: OLD-SESS'; } > "$MIG/.operator/pending/long-task"
{ printf 'session_id: OLD-SESS\n'; head -c 8192 /dev/zero | tr '\0' 'x'; } > "$MIG/.operator/pending/fat-task"     # over the byte cap
ln -s "$MIG/.operator/pending/legacy-task" "$MIG/.operator/pending/link-task"
sed "s|<tmp>|$MIG|" "$FIXTURES/sessionstart.json" | "$BASH_ABS" "$SSHOOK" >/dev/null 2>&1
check "migration renames a body-stamped sentinel to <sid>__<task>" \
  "$([ -f "$MIG/.operator/pending/OLD-SESS__legacy-task" ] && [ ! -e "$MIG/.operator/pending/legacy-task" ] && echo 0 || echo 1)"
run_hook_session() { # <cwd> <session-id> → HRC/HSUM via a stop payload on stdin
  local _o; _o="$(mktemp)"
  printf '{"hook_event_name":"Stop","stop_hook_active":false,"cwd":"%s","session_id":"%s"}' "$1" "$2" \
    | "$BASH_ABS" "$HOOK" >"$_o" 2>&1; HRC=$?
  HSUM="$(cat "$_o")"; rm -f "$_o"
}
run_hook_session "$MIG" OLD-SESS
check "renamed sentinel blocks its original owner again (Stop hook rc=2 for OLD-SESS)" \
  "$([ "$HRC" -eq 2 ] && echo 0 || echo 1)"
run_hook_session "$MIG" OTHER
# rc is 2 either way; the discriminator is the REPORT — migrated sentinel reads as OLD-SESS's foreign task, not unowned.
check "renamed sentinel is reported as OLD-SESS's foreign task, not unowned" \
  "$(printf '%s' "$HSUM" | grep -q 'legacy-task owned by OLD-SESS' && printf '%s' "$HSUM" | grep -q 'not blocking' && echo 0 || echo 1)"
check "an unowned legacy sentinel is left in place (still blocks everyone)" \
  "$([ -f "$MIG/.operator/pending/unowned-task" ] && echo 0 || echo 1)"
check "a __-carrying stamped sid is NOT migrated (would build the ambiguous name)" \
  "$([ -f "$MIG/.operator/pending/badsep-task" ] && [ ! -e "$MIG/.operator/pending/bad__sid__badsep-task" ] && echo 0 || echo 1)"
check "a sid past the 20-line bound is not read (bound holds)" \
  "$([ -f "$MIG/.operator/pending/deep-task" ] || [ -f "$MIG/.operator/pending/OLD-SESS__deep-task" ] && echo 0 || echo 1)"
check "a 30-line body leaves its sid unmigrated (line cap fires)" \
  "$([ -f "$MIG/.operator/pending/long-task" ] && [ ! -e "$MIG/.operator/pending/OLD-SESS__long-task" ] && echo 0 || echo 1)"
check "an over-4KiB body is skipped by the byte cap (no unbounded read)" \
  "$([ -f "$MIG/.operator/pending/fat-task" ] && [ ! -e "$MIG/.operator/pending/OLD-SESS__fat-task" ] && echo 0 || echo 1)"
check "a symlink pending/ entry is never followed by the migration (F65)" \
  "$([ -L "$MIG/.operator/pending/link-task" ] && { [ -f "$MIG/.operator/pending/legacy-task" ] || [ -f "$MIG/.operator/pending/OLD-SESS__legacy-task" ]; } && echo 0 || echo 1)"
rm -rf "$MIG"
rm -rf "$Q" "$P" "$GIP"

# ops-init stamps the version; SessionStart refreshes bin/ when it differs, so intra-session upgrades land automatically.
UP="$(newproj)"; ( cd "$UP" && bash "$INIT" >/dev/null 2>&1 )
# The plugin's current version (single-read, avoids nested-quote escaping).
PLUGIN_VER="$(grep -m1 '"version"' "$REPO/.claude-plugin/plugin.json" \
             | sed 's/.*"version".*:.*"\([^"]*\)".*/\1/')"
# ops-init stamps the version from the plugin's plugin.json.
check "ops-init stamps .operator/.version from plugin.json" \
  "$([ -f "$UP/.operator/.version" ] && [ -n "$(cat "$UP/.operator/.version")" ] && echo 0 || echo 1)"
# Simulate an OLD project: stale stamp + a stale bin/ CLI marker.
printf '0.1.0-old\n' > "$UP/.operator/.version"
printf '#!/usr/bin/env bash\necho STALE\n' > "$UP/.operator/bin/ops-verdict.sh"
rm -f "$UP/.operator/bin/ops-claims.sh"   # old operator had no ops-claims.sh
sed "s|<tmp>|$UP|" "$FIXTURES/sessionstart.json" | "$BASH_ABS" "$SSHOOK" >/dev/null 2>&1
# After the upgrade fire, bin/ops-verdict.sh is refreshed from the plugin copy...
check "sessionstart refreshes a stale bin/ CLI on version change" \
  "$(cmp -s "$UP/.operator/bin/ops-verdict.sh" "$VERDICT" && echo 0 || echo 1)"
# ...and the stamp now matches the plugin version.
check "sessionstart re-stamps .version after upgrade" \
  "$([ "$(cat "$UP/.operator/.version")" = "$PLUGIN_VER" ] && echo 0 || echo 1)"
# ops-claims.sh now exists (it didn't on old operator) — the upgrade installs it.
check "sessionstart upgrade installs the new ops-claims.sh" \
  "$([ -f "$UP/.operator/bin/ops-claims.sh" ] && echo 0 || echo 1)"
# A second fire (version now matches) does NOT re-copy — steady-state is cheap.
_pre="$(wc -c < "$UP/.operator/bin/ops-verdict.sh")"
sed "s|<tmp>|$UP|" "$FIXTURES/sessionstart.json" | "$BASH_ABS" "$SSHOOK" >/dev/null 2>&1
check "sessionstart is a no-op when the version matches (steady-state)" \
  "$( [ "$(wc -c < "$UP/.operator/bin/ops-verdict.sh")" = "$_pre" ] && echo 0 || echo 1)"
# CR3: a failed copy must not advance the stamp (or a truncated CLI + "current" stamp would never retry). Induced by
# replacing bin/ with a regular file, not chmod 000 — root ignores mode bits, so that induces nothing under root (#20).
printf '0.1.0-old\n' > "$UP/.operator/.version"   # force an upgrade attempt
rm -rf "$UP/.operator/bin" && : > "$UP/.operator/bin"
sed "s|<tmp>|$UP|" "$FIXTURES/sessionstart.json" | "$BASH_ABS" "$SSHOOK" >/dev/null 2>&1
check "a failed upgrade copy does NOT advance the stamp (retry next session)" \
  "$([ "$(cat "$UP/.operator/.version")" = "0.1.0-old" ] && echo 0 || echo 1)"
rm -f "$UP/.operator/bin"          # the blocking regular file; restore a usable dir
mkdir -p "$UP/.operator/bin"
# CR3: bin/ is created if absent — a project with .operator/ but no bin/ must not stamp current while installing nothing.
UP2="$(newproj)"; ( cd "$UP2" && bash "$INIT" >/dev/null 2>&1 )
rm -rf "$UP2/.operator/bin"
printf '0.1.0-old\n' > "$UP2/.operator/.version"
sed "s|<tmp>|$UP2|" "$FIXTURES/sessionstart.json" | "$BASH_ABS" "$SSHOOK" >/dev/null 2>&1
check "upgrade creates .operator/bin/ if absent" \
  "$([ -d "$UP2/.operator/bin" ] && [ -f "$UP2/.operator/bin/ops-claims.sh" ] && echo 0 || echo 1)"
rm -rf "$UP" "$UP2"

########################################################################
echo "-- Case 9: migration safety — an unowned sentinel blocks EVERY session"
# INVARIANT (spec §4.1 criterion 2): unowned fails closed. Pre-0.4 empty sentinels must keep gating on upgrade.
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
# INVARIANT (spec §4.1 criterion 3): B never gains the ability to close A's row — refused, not merely discouraged.
P="$(newproj)"; ( cd "$P" && bash "$INIT" >/dev/null 2>&1 )
( cd "$P" && bash "$TASK" T-A --owner SESS-A >/dev/null 2>&1 )
ROWS_BEFORE="$(wc -l < "$P/.operator/VERDICTS.md")"
( cd "$P" && bash "$VERDICT" T-A "crit" "evidence" PASS --owner SESS-B >/dev/null 2>&1 ); XRC=$?
check "foreign --owner → verdict refused" "$([ "$XRC" -ne 0 ] && echo 0 || echo 1)"
check "foreign --owner → no row, sentinel intact" "$([ "$(wc -l < "$P/.operator/VERDICTS.md")" = "$ROWS_BEFORE" ] && sentinel_any "$P" T-A && echo 0 || echo 1)"
( cd "$P" && bash "$VERDICT" T-A --defer "not mine" --owner SESS-B >/dev/null 2>&1 ); DXRC=$?
check "foreign --owner → --defer also refused" "$([ "$DXRC" -ne 0 ] && sentinel_any "$P" T-A && echo 0 || echo 1)"
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
check "ops-adopt exits 0 and renames to the new owner" "$([ "$ARC" -eq 0 ] && [ -f "$(sentinel "$P" T-C SESS-B)" ] && echo 0 || echo 1)"
check "ops-adopt leaves no sentinel under the OLD owner" "$([ ! -e "$(sentinel "$P" T-C SESS-A)" ] && echo 0 || echo 1)"
# Adoption is a rename; the body it never touches is still the one ops-task wrote.
check "ops-adopt preserves the original body (opened_at intact)" "$(grep -q '^opened_at: ' "$(sentinel "$P" T-C SESS-B)" && echo 0 || echo 1)"
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
# F15: PREV (from the untrusted sentinel body) must sanitize to <invalid>, not echo verbatim (log-injection-adjacent).
# The hostile owner can only arrive via planting — check_bare_name refuses these shapes at construction.
printf 'cwd: /x\n' > "$P/.operator/pending/evil path|with pipe__T-PREV"
PREVOUT="$( cd "$P" && bash "$ADOPT" --owner SESS-B T-PREV 2>/dev/null )"; PREVRC=$?
check "F15 ops-adopt sanitizes a malicious PREV body to <invalid>" \
  "$(printf '%s' "$PREVOUT" | grep -q 'adopted T-PREV: <invalid> -> SESS-B' && echo 0 || echo 1)"
check "F15 ops-adopt still exits 0 (adoption succeeds; only the display is sanitized)" \
  "$([ "$PREVRC" -eq 0 ] && echo 0 || echo 1)"
check "F15 ops-adopt does not echo the raw malicious body" \
  "$(printf '%s' "$PREVOUT" | grep -q 'evil path|with pipe' && echo 1 || echo 0)"
# F15/#6: a PREV carrying an ANSI/OSC escape must be caught by [:cntrl:] -> <invalid> (final-review #6).
printf 'cwd: /x\n' > "$P/.operator/pending/$(printf '\033]0;PWNED\007FAKEOWNER')__T-PREV"
ESCOUT="$( cd "$P" && bash "$ADOPT" --owner SESS-B T-PREV 2>/dev/null )"
check "F15 ops-adopt sanitizes a PREV with an ANSI/OSC escape to <invalid>" \
  "$(printf '%s' "$ESCOUT" | grep -q 'adopted T-PREV: <invalid> -> SESS-B' && echo 0 || echo 1)"
check "F15 ops-adopt does not echo the raw escape sequence" \
  "$(printf '%s' "$ESCOUT" | grep -q 'PWNED' && echo 1 || echo 0)"
# F15 follow-up: an unowned sentinel (empty PREV, no --owner) must report <unowned>, not <invalid> (final-review finding).
( cd "$P" && bash "$TASK" T-UNOWNED >/dev/null 2>&1 )   # no --owner
UNOWNEDOUT="$( cd "$P" && bash "$ADOPT" --owner SESS-B T-UNOWNED 2>/dev/null )"
check "F15 ops-adopt reports <unowned> for an empty-PREV sentinel (not <invalid>)" \
  "$(printf '%s' "$UNOWNEDOUT" | grep -q 'adopted T-UNOWNED: <unowned> -> SESS-B' && echo 0 || echo 1)"
( cd "$P" && bash "$TASK" T-T --owner "a/b" >/dev/null 2>&1 ); OTRC=$?
check "ops-task refuses '/' in --owner" "$([ "$OTRC" -ne 0 ] && echo 0 || echo 1)"
# re-opening an open task never silently takes it over
( cd "$P" && bash "$TASK" T-R --owner SESS-A >/dev/null 2>&1 )
( cd "$P" && bash "$TASK" T-R --owner SESS-B >/dev/null 2>&1 )
check "re-open does not steal ownership" "$([ -f "$(sentinel "$P" T-R SESS-A)" ] && echo 0 || echo 1)"
rm -rf "$P"

########################################################################
echo "-- Case: a mistyped flag cannot degrade the ownership gate to a warning [#64]"
# Asymmetric on purpose: mismatched --owner is a hard refusal, missing one only warns (a /clear'd session must still
# close its work). `--ownr WRONG` (typo) used to fall through and let one session close another's task at rc 0.
P="$(newproj)"; ( cd "$P" && bash "$INIT" >/dev/null 2>&1 )
( cd "$P" && bash "$TASK" T-TYPO --owner SESS-A >/dev/null 2>&1 )
ROWS_BEFORE="$(wc -l < "$P/.operator/VERDICTS.md")"
( cd "$P" && bash "$VERDICT" T-TYPO "crit" "evid" PASS --ownr SESS-B junk >/dev/null 2>&1 ); TYRC=$?
check "typo'd --owner on a foreign task is refused, not warned" "$([ "$TYRC" -ne 0 ] && echo 0 || echo 1)"
check "typo'd --owner writes no row and leaves the sentinel" "$([ "$(wc -l < "$P/.operator/VERDICTS.md")" = "$ROWS_BEFORE" ] && sentinel_any "$P" T-TYPO && echo 0 || echo 1)"
# The worse half, measured: the typo'd flag was also written into the ledger as the evidence cell.
( cd "$P" && bash "$VERDICT" T-TYPO "crit" --ownr=SESS-B PASS >/dev/null 2>&1 ); TYRC2=$?
check "a typo'd flag never lands in the ledger as evidence" "$([ "$TYRC2" -ne 0 ] && ! grep -q -- '--ownr=' "$P/.operator/VERDICTS.md" && echo 0 || echo 1)"
# Surplus positional: the other half of the same slip — everything past $4 used to be silently discarded.
( cd "$P" && bash "$VERDICT" T-TYPO "crit" "evid" PASS surplus >/dev/null 2>&1 ); SPRC=$?
check "a surplus positional is refused" "$([ "$SPRC" -ne 0 ] && echo 0 || echo 1)"
# The ceiling is per-form: a single `-le 4` only bounded the verdict form; the defer form's arity left a free slot
# where `STRAY` silently dropped — the #64 class surviving in the other form.
( cd "$P" && bash "$TASK" T-DEFX --owner SESS-A >/dev/null 2>&1 )
DLBEFORE="$(wc -l < "$P/.operator/DECISIONS.md")"
( cd "$P" && bash "$VERDICT" T-DEFX --defer "a real reason" STRAY --owner SESS-A >/dev/null 2>&1 ); DFXRC=$?
check "a surplus positional on the DEFER form is refused too" "$([ "$DFXRC" -ne 0 ] && echo 0 || echo 1)"
check "the refused defer writes no DECISIONS line and leaves the sentinel" "$([ "$(wc -l < "$P/.operator/DECISIONS.md")" = "$DLBEFORE" ] && sentinel_any "$P" T-DEFX && echo 0 || echo 1)"
# CONTROL: the legitimate three-positional defer form still works.
( cd "$P" && bash "$VERDICT" T-DEFX --defer "a real reason" --owner SESS-A >/dev/null 2>&1 ); DFOKRC=$?
check "the legitimate defer form still works under the per-form ceiling" "$([ "$DFOKRC" -eq 0 ] && [ ! -e "$P/.operator/pending/T-DEFX" ] && echo 0 || echo 1)"
# NEGATIVE CONTROL: the reject arm is `--*` not `-*` because a single-dash evidence cell is legitimate and common.
( cd "$P" && bash "$VERDICT" T-TYPO "crit" "-v output: 3 passed" PASS --owner SESS-A >/dev/null 2>&1 ); DSRC=$?
check "single-dash evidence still records (the reject is --*, not -*)" "$([ "$DSRC" -eq 0 ] && grep -q -- '| -v output: 3 passed' "$P/.operator/VERDICTS.md" && echo 0 || echo 1)"
# …and the escape hatch for a cell that genuinely opens with `--`.
( cd "$P" && bash "$TASK" T-ESC --owner SESS-A >/dev/null 2>&1 )
( cd "$P" && bash "$VERDICT" -- T-ESC "crit" "--strict output ok" PASS >/dev/null 2>&1 ); ESRC=$?
check "-- passes a --dash cell through as a positional" "$([ "$ESRC" -eq 0 ] && grep -q -- '| --strict output ok' "$P/.operator/VERDICTS.md" && echo 0 || echo 1)"
# The three shapes the arm must NOT break: legit --owner, --defer, --reconcile.
( cd "$P" && bash "$TASK" T-OK --owner SESS-A >/dev/null 2>&1 )
( cd "$P" && bash "$VERDICT" T-OK "crit" "evid" PASS --owner SESS-A >/dev/null 2>&1 ); OKRC=$?
( cd "$P" && bash "$TASK" T-DEF --owner SESS-A >/dev/null 2>&1 )
( cd "$P" && bash "$VERDICT" T-DEF --defer "blocked" --owner SESS-A >/dev/null 2>&1 ); DFRC=$?
( cd "$P" && bash "$VERDICT" --reconcile >/dev/null 2>&1 ); RCRC=$?
check "the reject arm breaks neither --owner, --defer, nor --reconcile" "$([ "$OKRC" -eq 0 ] && [ "$DFRC" -eq 0 ] && [ "$RCRC" -eq 0 ] && echo 0 || echo 1)"
rm -rf "$P"

########################################################################
echo "-- Case 11: concurrent appends never interleave; --reconcile repairs a merge"
# INVARIANT (spec §4.3 criterion 4): append+clear is atomic, not merely a property of printf's buffer size pre-0.4.
P="$(newproj)"; ( cd "$P" && bash "$INIT" >/dev/null 2>&1 )
N=50
racer() { # racer <tag>
  local tag="$1" i
  for i in $(seq 1 "$N"); do
    ( cd "$P" && bash "$VERDICT" "T-$tag-$i" "criterion $tag $i" "evidence $tag $i" PASS --owner "SESS-$tag" >/dev/null 2>&1 )
  done
}
racer A & RA=$!
racer B & RB=$!
wait "$RA" "$RB"
TOTAL=$((N * 2))
GOOD="$(grep -cE '^\| T-[AB]-[0-9]+ \| criterion [AB] [0-9]+ \| evidence [AB] [0-9]+ @[^ |]+ \| PASS \|$' "$P/.operator/VERDICTS.md" || true)"
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
# All three append-only paths need this — a regression in any one silently reintroduces merge conflicts.
check "gitattributes covers DECISIONS.md" "$(grep -q 'DECISIONS.md merge=union' "$P/.operator/.gitattributes" && echo 0 || echo 1)"
check "gitattributes covers the fragments dir" "$(grep -q 'verdicts.d/\*.md merge=union' "$P/.operator/.gitattributes" && echo 0 || echo 1)"
# The schema check alone doesn't discriminate (short printfs land atomically unlocked too); prove the lock is held.
( cd "$P" && bash "$TASK" T-LOCK --owner SESS-A >/dev/null 2>&1 )
mkdir "$P/.operator/.lock"
( cd "$P" && bash "$VERDICT" T-LOCK "crit" "locked-out" PASS >/dev/null 2>&1 ) &
LOCKPID=$!
sleep 1
check "held lock blocks a concurrent writer" "$(! grep -q 'locked-out' "$P/.operator/VERDICTS.md" && sentinel_any "$P" T-LOCK && echo 0 || echo 1)"
rmdir "$P/.operator/.lock"
wait "$LOCKPID" 2>/dev/null || true
check "releasing the lock lets the waiter through" "$(grep -q 'locked-out' "$P/.operator/VERDICTS.md" && [ ! -e "$P/.operator/pending/T-LOCK" ] && echo 0 || echo 1)"
# A stale lock must never cost a real verdict: after the spin budget the writer proceeds with a warning.
( cd "$P" && bash "$TASK" T-STALE --owner SESS-A >/dev/null 2>&1 )
mkdir "$P/.operator/.lock"
SOUT="$( cd "$P" && bash "$VERDICT" T-STALE "crit" "stale-lock" PASS 2>&1 )"; SRC=$?
rmdir "$P/.operator/.lock" 2>/dev/null || true
check "stale lock → proceeds with a warning, verdict not lost" "$([ "$SRC" -eq 0 ] && printf '%s' "$SOUT" | grep -qi 'warning' && grep -q 'stale-lock' "$P/.operator/VERDICTS.md" && echo 0 || echo 1)"
rm -rf "$P"

########################################################################
echo "-- Case 12: name guards agree across all three CLIs; reconcile validates"
# INVARIANT: a sentinel the hook cannot see is worse than none — its plain glob misses dotfiles, so leading-dot
# must be refused at every entry point (the shape of the 2026-07-10 traversal bug).
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
# ops-adopt would also exit non-zero for the unrelated "no such open task"; assert on the MESSAGE, not just rc.
ADOUT="$( cd "$P" && bash "$ADOPT" --owner SESS-A ".hidden" 2>&1 )"; T3=$?
check "ops-adopt refuses a dot-prefixed task-id (by name, not by absence)" "$([ "$T3" -ne 0 ] && printf '%s' "$ADOUT" | grep -q "start with '\.'" && echo 0 || echo 1)"
check "no dotfile sentinel was created" "$([ ! -e "$P/.operator/pending/.hidden" ] && echo 0 || echo 1)"
# a dot-prefixed --owner would produce an invisible fragment file, same class
( cd "$P" && bash "$TASK" T-DOT --owner ".sneaky" >/dev/null 2>&1 ); T4=$?
check "ops-task refuses a dot-prefixed --owner" "$([ "$T4" -ne 0 ] && echo 0 || echo 1)"
# '.' and '..' stay refused — the leading-dot rule must subsume, not replace, the traversal guard.
echo victim > "$P/victim.txt"
( cd "$P" && bash "$VERDICT" ".." crit ev PASS >/dev/null 2>&1 ); DDRC=$?
check "'..' still refused (traversal guard intact)" "$([ "$DDRC" -ne 0 ] && [ -f "$P/victim.txt" ] && echo 0 || echo 1)"
# Duplicate --owner is refused, never silently last-wins — a repeated flag means the caller is confused.
( cd "$P" && bash "$TASK" T-DUP --owner SESS-A --owner SESS-B >/dev/null 2>&1 ); DUPRC=$?
check "ops-task refuses a repeated --owner" "$([ "$DUPRC" -ne 0 ] && [ ! -e "$P/.operator/pending/T-DUP" ] && echo 0 || echo 1)"
# same trap as above: assert the reason, not merely a non-zero exit
ADOUT2="$( cd "$P" && bash "$ADOPT" --owner SESS-A --owner SESS-B T-X 2>&1 )"; ADRC=$?
check "ops-adopt refuses a repeated --owner (by reason)" "$([ "$ADRC" -ne 0 ] && printf '%s' "$ADOUT2" | grep -q 'more than once' && echo 0 || echo 1)"
# `__` separates owner/task in the sentinel name; `__` inside either half builds an ambiguous filename every reader
# parses differently (PR #77 review: ops-task carried the guard alone, the other writers did not).
( cd "$P" && bash "$TASK" T-SEP --owner SESS-A >/dev/null 2>&1 )
TSEP1="$( cd "$P" && bash "$ADOPT" --owner "sessA__evilB" T-SEP 2>&1 )"; SEP1=$?
check "ops-adopt refuses a '__' owner (by reason)" "$([ "$SEP1" -ne 0 ] && printf '%s' "$TSEP1" | grep -q "must not contain '__'" && echo 0 || echo 1)"
check "no ambiguous sentinel was created" "$([ ! -e "$P/.operator/pending/sessA__evilB__T-SEP" ] && echo 0 || echo 1)"
TSEP2="$( cd "$P" && bash "$VERDICT" T-SEP c e PASS --owner "sessA__evilB" 2>&1 )"; SEP2=$?
check "ops-verdict refuses a '__' owner (by reason)" "$([ "$SEP2" -ne 0 ] && printf '%s' "$TSEP2" | grep -q "must not contain '__'" && echo 0 || echo 1)"
TSEP3="$( cd "$P" && bash "$TASK" "bad__id" --owner SESS-A 2>&1 )"; SEP3=$?
check "ops-task still refuses a '__' task-id (by reason)" "$([ "$SEP3" -ne 0 ] && printf '%s' "$TSEP3" | grep -q "must not contain '__'" && echo 0 || echo 1)"
# And the spoof fails end-to-end: bare sessA cannot close T-SEP because the ambiguous adoption never happened.
( cd "$P" && bash "$VERDICT" T-SEP c e PASS --owner SESS-A >/dev/null 2>&1 )
check "the pre-fix spoof path closes the task only via its REAL owner" "$(grep -q 'T-SEP' "$P/.operator/VERDICTS.md" && echo 0 || echo 1)"
( cd "$P" && bash "$TASK" T-SEP2 --owner SESS-A >/dev/null 2>&1 )
( cd "$P" && bash "$VERDICT" T-SEP2 c e PASS --owner SESS-A >/dev/null 2>&1 )
# --reconcile writes to the ledger of record: it must enforce the same 4-cell schema as the direct writer.
( cd "$P" && bash "$TASK" T-OK --owner SESS-A >/dev/null 2>&1 )
( cd "$P" && bash "$VERDICT" T-OK "crit" "evidence" PASS --owner SESS-A >/dev/null 2>&1 )
printf 'not a valid row\n| broken | only | three |\n| T-INJ | c | e | MAYBE |\n' >> "$P/.operator/verdicts.d/SESS-A.md"
RB="$(wc -l < "$P/.operator/VERDICTS.md")"
ROUT="$( cd "$P" && bash "$VERDICT" --reconcile 2>&1 )"; RRC2=$?
check "--reconcile exits 0 despite corrupt fragment lines" "$([ "$RRC2" -eq 0 ] && echo 0 || echo 1)"
check "--reconcile refuses non-conformant lines (ledger unchanged)" "$([ "$(wc -l < "$P/.operator/VERDICTS.md")" = "$RB" ] && echo 0 || echo 1)"
check "--reconcile reports what it skipped" "$(printf '%s' "$ROUT" | grep -qi 'non-conformant' && echo 0 || echo 1)"
check "--reconcile did not inject the MAYBE verdict" "$(! grep -q 'T-INJ' "$P/.operator/VERDICTS.md" && echo 0 || echo 1)"
# A row with EXTRA cells is what a glob-based check waves through (Codex review) — the check must COUNT.
RB2="$(wc -l < "$P/.operator/VERDICTS.md")"
printf '| a | b | c | injected | PASS |\n| a | b | c | d | e | f | FAIL |\n' >> "$P/.operator/verdicts.d/SESS-A.md"
( cd "$P" && bash "$VERDICT" --reconcile >/dev/null 2>&1 )
check "--reconcile refuses a 5-cell row (counts cells, not globs)" "$(! grep -q 'injected' "$P/.operator/VERDICTS.md" && echo 0 || echo 1)"
check "--reconcile refuses any over-celled row" "$([ "$(wc -l < "$P/.operator/VERDICTS.md")" = "$RB2" ] && echo 0 || echo 1)"
rm -rf "$P"

########################################################################
echo "-- Case 12b: --reconcile restores a long (>512B) conformant row"
# INVARIANT: a >512-byte evidence cell is legal; --reconcile's `read -r -n 512` split such a row into chunks, each
# independently failing the 4-cell check, so the row was never restored (issue-#9 long-row blindness, F17).
P="$(newproj)"; ( cd "$P" && bash "$INIT" >/dev/null 2>&1 )
# a ~560-byte evidence cell (no pipe, no newline — still exactly 4 cells)
LONG="$(printf 'e%.0s' $(seq 1 560))"
mkdir -p "$P/.operator/verdicts.d"
printf '| T-LONG | crit | %s @abc123 | PASS |\n' "$LONG" >> "$P/.operator/verdicts.d/SESS-LONG.md"
# Sanity: the planted row genuinely exceeds the 512B chunk bound.
check "premise: long row is >512B" "$([ "$(wc -c < "$P/.operator/verdicts.d/SESS-LONG.md")" -gt 512 ] && echo 0 || echo 1)"
ROUT="$( cd "$P" && bash "$VERDICT" --reconcile 2>&1 )"; RRC=$?
check "--reconcile exits 0 with a long row present" "$([ "$RRC" -eq 0 ] && echo 0 || echo 1)"
check "--reconcile does NOT skip the long row as non-conformant" "$(! printf '%s' "$ROUT" | grep -q 'non-conformant' && echo 0 || echo 1)"
check "--reconcile restores the long row to VERDICTS.md" "$(grep -q 'T-LONG' "$P/.operator/VERDICTS.md" && echo 0 || echo 1)"
rm -rf "$P"

########################################################################
echo "-- Case 12c: --reconcile aborts on an unreadable VERDICTS.md (F13)"
# INVARIANT: reconcile must abort on an unreadable ledger, not report a false '0 restored' (grep's rc 2 masked by || true, F13).
P="$(newproj)"; ( cd "$P" && bash "$INIT" >/dev/null 2>&1 )
mkdir -p "$P/.operator/verdicts.d"
printf '| T-F13 | crit | ev @abc123 | PASS |\n' >> "$P/.operator/verdicts.d/SESS-F13.md"
# sanity: the fragment row is present and would be restored were the ledger readable
check "premise: ledger exists" "$([ -f "$P/.operator/VERDICTS.md" ] && echo 0 || echo 1)"
# make the ledger unreadable, then reconcile MUST abort non-zero (no '0 restored')
chmod 000 "$P/.operator/VERDICTS.md"
ROUT="$( cd "$P" && bash "$VERDICT" --reconcile 2>&1 )"; RRC=$?
chmod 600 "$P/.operator/VERDICTS.md"
# Root reads 000 files, so this case's premise cannot hold there — announced (a skip, not a silent pass) since
# root is the normal way to reproduce CI locally.
if [ "$(id -u)" = "0" ]; then
  echo "  skip 12c: running as root, a 000 ledger is still readable"
else
  check "--reconcile exits NON-ZERO on an unreadable VERDICTS.md" "$([ "$RRC" -ne 0 ] && echo 0 || echo 1)"
  check "--reconcile does NOT report '0 restored' success on grep failure" "$(! printf '%s' "$ROUT" | grep -q '0 row(s) restored' && echo 0 || echo 1)"
fi
rm -rf "$P"

########################################################################
echo "-- Case 13: the sentinel BODY is untrusted input"
# INVARIANT: a sentinel's stamped owner becomes a fragment FILENAME, so an unvalidated one re-opens the
# 2026-07-10 traversal (found in 0.4.0 review: `../../../tmp/x` appended a real row to /tmp/x.md).
P="$(newproj)"; ( cd "$P" && bash "$INIT" >/dev/null 2>&1 )
# Escape exactly one level out of .operator/ (fragments live at .operator/verdicts.d/) — a deeper path would
# 'pass' for the wrong reason (nonexistent intermediate dirs).
printf 'session_id: ../../PWNED\n' > "$P/.operator/pending/T-EVIL"
( cd "$P" && bash "$VERDICT" T-EVIL "crit" "ev" PASS >/dev/null 2>&1 ) || true
check "traversal via sentinel body writes nothing outside .operator/" "$([ ! -e "$P/PWNED.md" ] && echo 0 || echo 1)"
check "traversal owner degrades to unowned (row still recorded inside)" "$([ -f "$P/.operator/verdicts.d/unowned.md" ] && echo 0 || echo 1)"
# CRLF: a trailing \r must not make a session's own task look foreign (fail-open in the core invariant).
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
# TRUNCATION-RECLASSIFICATION: `read -n 512` truncates mid-line so the tail arrives as a fresh line — an unowned
# sentinel can read as FOREIGN (fail-open). Two vectors: filling the 512 cap, and a NUL (bash 3.2's read -n stops at one).
for vec in pad512 nulpad latenul utf8pad; do
  rm -f "$P"/.operator/pending/*
  if [ "$vec" = pad512 ]; then
    python3 -c "import sys; open(sys.argv[1],'wb').write(b'x'*512+b'session_id: EVIL\\n')" "$P/.operator/pending/T-SMUG"
  elif [ "$vec" = nulpad ]; then
    python3 -c "import sys; open(sys.argv[1],'wb').write(b'x'+b'\\0'*100+b'x'*411+b'session_id: EVIL\\n')" "$P/.operator/pending/T-SMUG"
  elif [ "$vec" = utf8pad ]; then
        # In a UTF-8 locale read -n 512/${#line} count CHARS not bytes, so a 1024-byte line reads as one 512-char chunk
        # smuggling a foreign owner. Fix: LC_ALL=C in the parser (review finding 2026-08-04).
    python3 -c "import sys; open(sys.argv[1],'wb').write(('é'*512+'session_id: EVIL\\n').encode('utf-8'))" "$P/.operator/pending/T-SMUG"
  else
        # latenul: a NUL past byte 512 slips the single-shot probe even with every physical line under the cap
        # (full-PR panel score-92 exploit). Fix loops the probe over the whole file.
    python3 -c "import sys; open(sys.argv[1],'wb').write(b'\\n'.join(b'p'*100 for _ in range(6))+b'\\n'+b'q'*50+b'\\0'+b'r'*50+b'\\nsession_id: EVIL\\n')" "$P/.operator/pending/T-SMUG"
  fi
    # NUL vectors only exist under the oldest bash (F46); utf8pad needs a UTF-8 locale to prove the LC_ALL=C fix, not just run.
  _utfloc=""
  if [ "$vec" = utf8pad ]; then
    _utfloc="$(locale -a 2>/dev/null | grep -m1 'UTF-8' || true)"
  fi
  if [ -n "$_utfloc" ]; then
    printf '{"session_id":"SESS-B","cwd":"%s"}' "$P" | LC_ALL="$_utfloc" "$BASH_OLD" "$HOOK" >/dev/null 2>&1; SMRC=$?
  else
    printf '{"session_id":"SESS-B","cwd":"%s"}' "$P" | "$BASH_OLD" "$HOOK" >/dev/null 2>&1; SMRC=$?
  fi
  check "a one-line [$vec] sentinel cannot smuggle an owner — fails CLOSED (exit 2)" \
    "$([ "$SMRC" -eq 2 ] && echo 0 || echo 1)"

    # The writer parsers (verdict/adopt) carry the same F45/F46 guard belt-and-braces, not load-bearing: check_bare_name
    # already blocks the traversal via a different path (verified 2026-08-03). The stop-hook reader here is where it
    # IS load-bearing — no downstream bare-name check (pr-review test-coverage finding #3).
done
# The guard must not break the path it sits on: a genuine foreign sentinel is still reported, still non-blocking.
rm -f "$P"/.operator/pending/*
printf 'cwd: /x\n' > "$P/.operator/pending/OTHER__T-FGN"
run_hook stop-session-a.json "$P"
check "a genuine foreign sentinel still does NOT block (guard did not overreach)" \
  "$([ "$HRC" -eq 0 ] && echo 0 || echo 1)"

# WHITESPACE in an owner is the subtlest disarm: byte-for-byte comparison means " SESS-A" is foreign forever, and
# foreign never blocks. Refused at the CLIs; treated as unowned by the hook otherwise.
for o in " SESS-A" "SESS-A " "SE SS"; do
  ( cd "$P" && bash "$TASK" T-WS --owner "$o" >/dev/null 2>&1 ); WRC=$?
  check "ops-task refuses a whitespace --owner [$o]" "$([ "$WRC" -ne 0 ] && echo 0 || echo 1)"
done
( cd "$P" && bash "$ADOPT" --owner " X" T-WS >/dev/null 2>&1 ); AWRC=$?
check "ops-adopt refuses a whitespace --owner" "$([ "$AWRC" -ne 0 ] && echo 0 || echo 1)"
# The whitespace rule is owners ONLY, not task ids: 0.3.0 accepted `release candidate`, wedging a task no closing
# path could reach (Codex review).
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
# A payload that fails to parse must not fail open silently — json_get swallows parser errors.
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
# The temp file must live outside pending/: the hook globs that dir and treats every entry as a task id.
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
# INVARIANT: "re-open never takes over" and "B cannot close A's task" must hold under a RACE. Both were TOCTOU
# (ops-task test-then-truncate: 155/200 trials won by both openers; Codex review) — these loops are the only
# assertions that catch a regression.
P="$(newproj)"; ( cd "$P" && bash "$INIT" >/dev/null 2>&1 )
BOTH=0
for _i in $(seq 1 40); do
  rm -f "$P"/.operator/pending/*T-RACE "$P/.operator/pending/T-RACE"
  OUT="$( ( cd "$P" && bash "$TASK" T-RACE --owner SESS-A 2>&1 ) & \
          ( cd "$P" && bash "$TASK" T-RACE --owner SESS-B 2>&1 ) & wait )"
  [ "$(printf '%s\n' "$OUT" | grep -c '^opened ')" -gt 1 ] && BOTH=$((BOTH+1))
done
check "concurrent open: exactly one winner every time (no takeover)" "$([ "$BOTH" = "0" ] && echo 0 || echo 1)"
# The survivor is always a well-formed, owned sentinel — never truncated or interleaved.
rm -f "$P/.operator/pending/T-RACE"
( cd "$P" && bash "$TASK" T-RACE --owner SESS-A >/dev/null 2>&1 ) & \
( cd "$P" && bash "$TASK" T-RACE --owner SESS-B >/dev/null 2>&1 ) & wait
# Exactly ONE sentinel for the task, whichever session won — the no-takeover guarantee.
SENTN=0
for _s in "$P"/.operator/pending/*T-RACE "$P"/.operator/pending/T-RACE; do
  [ -e "$_s" ] && SENTN=$((SENTN + 1))
done
check "concurrent open: exactly one sentinel for the task (no second owner)" "$([ "$SENTN" = "1" ] && echo 0 || echo 1)"
# The post-rename re-check: mv re-opens the window the O_EXCL claim closed. Cannot force the interleave
# deterministically (PR #77 review needed an injected sleep), so this fires in the losing-leg posture — a second
# sentinel can never be created through ops-task while one exists under any owner.
rm -f "$P"/.operator/pending/*T-RACE "$P/.operator/pending/T-RACE"
( cd "$P" && bash "$TASK" T-RACE --owner SESS-A >/dev/null 2>&1 )
: > "$P/.operator/pending/SESS-X__T-RACE"
DUPMSG="$( cd "$P" && bash "$TASK" T-RACE --owner SESS-B 2>&1 )"; DUPRC=$?
SENTN2=0
for _s in "$P"/.operator/pending/*__T-RACE; do [ -e "$_s" ] && SENTN2=$((SENTN2+1)); done
check "open beside a foreign sentinel for the same id never adds a third" \
  "$([ "$SENTN2" = "2" ] && echo 0 || echo 1)"
check "the racing owner is refused or told already-open, never a silent win" \
  "$([ "$DUPRC" -ne 0 ] || printf '%s' "$DUPMSG" | grep -q 'already open' && echo 0 || echo 1)"
rm -f "$P/.operator/pending/SESS-X__T-RACE"

# adopt vs verdict: whoever wins the lock, the loser must not damage the ledger. HONESTY: unlike the open-race
# above, this does not reliably reproduce the unfixed race (microsecond window) — it's a regression guard, the
# evidence is the code path (owner read outside the lock, Codex review), not a green run here.
STOLEN=0
for _i in $(seq 1 25); do
  rm -f "$P/.operator/pending/T-AV"
  ( cd "$P" && bash "$TASK" T-AV --owner SESS-A >/dev/null 2>&1 )
  ( cd "$P" && bash "$VERDICT" T-AV crit ev PASS --owner SESS-A >/dev/null 2>&1 ) & \
  ( cd "$P" && bash "$ADOPT" --owner SESS-B T-AV >/dev/null 2>&1 ) & wait
    # Legal outcomes: verdict won (sentinel gone, row exists) or adopt won (sentinel present, owned by B).
  if [ ! -e "$P/.operator/pending/T-AV" ] && [ -f "$P/.operator/verdicts.d/SESS-B.md" ]; then
    STOLEN=$((STOLEN+1))
  fi
done
check "adopt vs verdict: no session clears another's adopted sentinel" "$([ "$STOLEN" = "0" ] && echo 0 || echo 1)"
check "adopt vs verdict: lock released after the race" "$([ ! -d "$P/.operator/.lock" ] && echo 0 || echo 1)"

# Stale-lock reclaim must itself be exclusive: naive rmdir+mkdir let a second waiter delete the first's fresh lock
# (Codex review). Guard is a `.lock.reclaim` claim marker; asserted directly, not via a 30s budget wait.
#
# HONESTY: these do not fail against the pre-fix code — they assert the claim marker is used and cleaned up, not
# that the two-waiter race is closed (evidence is the code path, not this test).
mkdir -p "$P/.operator/.lock" "$P/.operator/.lock.reclaim"
( cd "$P" && bash "$TASK" T-RC --owner SESS-A >/dev/null 2>&1 )
( cd "$P" && bash "$VERDICT" T-RC crit ev PASS --owner SESS-A >/dev/null 2>&1 ) &
RCPID=$!
sleep 2
check "a held reclaim-claim blocks another writer from reclaiming" "$([ -d "$P/.operator/.lock" ] && sentinel_any "$P" T-RC && echo 0 || echo 1)"
rmdir "$P/.operator/.lock.reclaim" "$P/.operator/.lock" 2>/dev/null || true
wait "$RCPID" 2>/dev/null || true
check "writer proceeds once the stale lock is gone" "$([ ! -e "$P/.operator/pending/T-RC" ] && echo 0 || echo 1)"
check "reclaim marker is not left behind" "$([ ! -d "$P/.operator/.lock.reclaim" ] && echo 0 || echo 1)"
rm -rf "$P"

########################################################################
echo "-- Case 16: bounded reads and an abandoned reclaim claim"
# A claim marker with no expiry is a deadlock with extra steps: the first reclaim fix wedged every later writer
# forever (measured: still running after 45s). Asserts the OUTCOME, not the timing — this case is slow by nature.
P="$(newproj)"; ( cd "$P" && bash "$INIT" >/dev/null 2>&1 )
mkdir -p "$P/.operator/.lock" "$P/.operator/.lock.reclaim"
( cd "$P" && bash "$TASK" T-AB --owner SESS-A >/dev/null 2>&1 )
# Run under a polled watchdog: unfixed code never returns, and macOS has no timeout(1). Tiny budget via the env
# seam (audit F08) — the real 30s/5s budgets made this case alone run >60s. RECLAIM_WAIT must be < LOCK_SPINS
# (review F-C: the backoff goes non-positive otherwise; validator now rejects that combo).
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
check "abandoned claim: verdict actually recorded" "$(grep -Eq '^\| T-AB \| crit \| ev @[^ |]+ \| PASS \|$' "$P/.operator/VERDICTS.md" && [ ! -e "$P/.operator/pending/T-AB" ] && echo 0 || echo 1)"
check "abandoned claim: no lock or marker left behind" "$([ ! -d "$P/.operator/.lock" ] && [ ! -d "$P/.operator/.lock.reclaim" ] && echo 0 || echo 1)"

# A LINE cap is not a BYTE cap: `read -r` slurps a whole newline-less line before any counter runs (256MB measured
# at 8.5s per Stop event). `read -r -n N` stops at N chars. Also guards a regression: switching to `read -N`
# (capital) returned empty and every session blocked on every task, with the whole suite green.
rm -f "$P"/.operator/pending/*
( cd "$P" && bash "$TASK" T-OWN --owner SESS-A >/dev/null 2>&1 )
run_hook stop-session-a.json "$P"
check "parser regression guard: owner still blocks its own task" "$([ "$HRC" -eq 2 ] && echo 0 || echo 1)"
run_hook stop-session-b.json "$P"
check "parser regression guard: foreign session still allowed" "$([ "$HRC" -eq 0 ] && echo 0 || echo 1)"
rm -f "$P"/.operator/pending/*
# HONESTY: at 32MB the unfixed hook still takes ~1s, so this does NOT discriminate (cost is linear, 256MB=8.5s
# unfixed vs 0.16s fixed); it guards the parse staying bounded and the bounded read returning the right verdict.
{ i=0; while [ "$i" -lt 32 ]; do printf '%1048576s' '' | tr ' ' 'x'; i=$((i+1)); done; } > "$P/.operator/pending/T-LONG"
SEC0=$(date +%s)
run_hook stop-session-a.json "$P"
SEC1=$(date +%s)
check "one-huge-line sentinel parsed in bounded time (<3s)" "$([ "$((SEC1 - SEC0))" -lt 3 ] && echo 0 || echo 1)"
check "one-huge-line sentinel is unowned → still BLOCKS" "$([ "$HRC" -eq 2 ] && echo 0 || echo 1)"
rm -rf "$P"

########################################################################
echo "-- Case 17: the gate applies from anywhere inside the project [F01]"
# INVARIANT: a session cannot escape the gate by cwd depth — the hook used to resolve "$cwd/.operator" with no
# upward walk, so a payload one directory deeper allowed the stop with tasks still open (Audit F01, P0).
P="$(newproj)"; ( cd "$P" && bash "$INIT" >/dev/null 2>&1 )
( cd "$P" && bash "$TASK" T-ROOT --owner SESS-A >/dev/null 2>&1 )
mkdir -p "$P/src/deep/nested"
for sub in "" "/src" "/src/deep" "/src/deep/nested"; do
  json="$(sed "s|<tmp>|$P$sub|" "$FIXTURES/stop-session-a.json")"
  errf="$(mktemp)"; printf '%s' "$json" | "$BASH_ABS" "$HOOK" 2>"$errf"; rc=$?
  rm -f "$errf"
  check "gate blocks from cwd=<root>${sub:-/} (no escape by cd)" "$([ "$rc" -eq 2 ] && echo 0 || echo 1)"
done
# The walk must not escape the project: a sibling or parent above it must stay no-op.
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
# INVARIANT: `read -r` is bounded by LINES not bytes. The 0.4.0 fix applied `read -r -n 512` to the hook only;
# verdict.sh/--reconcile kept plain `read -r` (measured 256MB: hook 0.17s vs verdict 13.51s, reconcile 32.56s —
# Audit F02/F03; the 32.56s let a concurrent writer reclaim reconcile's lock mid-read). Sized at 64MB to
# discriminate bounded (<2s) from unbounded without a quarter-gig of CI writes.
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
check "ops-adopt handles a huge-line sentinel in bounded time (<3s, mv-only since 0.9.0)" "$([ "$((S1 - S0))" -lt 3 ] && echo 0 || echo 1)"
bigline "$P/.operator/verdicts.d/huge.md"
S0=$(date +%s); ( cd "$P" && bash "$VERDICT" --reconcile >/dev/null 2>&1 ); S1=$(date +%s)
check "--reconcile reads a huge-line fragment in bounded time (<3s)" "$([ "$((S1 - S0))" -lt 3 ] && echo 0 || echo 1)"
check "--reconcile did not admit the huge non-conformant line" "$(! grep -q 'xxxxxxxx' "$P/.operator/VERDICTS.md" && echo 0 || echo 1)"
rm -rf "$P"

########################################################################
echo "-- Case 19: adopt does not propagate CR into the operator's guidance [F04]"
# A CRLF sentinel's opened_at is echoed verbatim into the hook's foreign-task report, where a bare CR eats the
# guidance mid-line. Gating unaffected; presentation only (Audit F04, P3).
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
# ops-init scaffolds .operator/ anywhere, including a non-repo dir, silently misplacing the evidence of record.
# Warn, don't hard-fail — a non-git project is unusual but legitimate (Audit F05, P3).
Q="$(newproj)"
IOUT="$( cd "$Q" && bash "$INIT" 2>&1 )"
check "ops-init warns when the target is not a git repository" "$(printf '%s' "$IOUT" | grep -qi 'not a git repo' && echo 0 || echo 1)"
check "ops-init still scaffolds (warn, never hard-fail)" "$([ -d "$Q/.operator/pending" ] && echo 0 || echo 1)"
# Under v2 there's no per-directory `.lock/` line; assert the BEHAVIOUR (git ignores it), not the literal.
check "ops-init ignores its own lock ephemera" \
  "$( cd "$Q" && git init -q . >/dev/null 2>&1; mkdir -p .operator/.lock; : > .operator/.lock/held
      git check-ignore -q .operator/.lock/held && echo 0 || echo 1 )"
rm -rf "$Q"

# F05's warning must not cry wolf (issue #61): it compared git's PHYSICAL toplevel against LOGICAL $PWD, so any
# symlinked ancestor differed by construction (/tmp on macOS). Symlink built here since Linux CI lacks it natively.
R="$(newproj)"; mkdir -p "$R/real"
( cd "$R/real" && git init -q . >/dev/null 2>&1 )
ln -s "$R/real" "$R/link"
SYMOUT="$( cd "$R/link" && bash "$INIT" 2>&1 )"
check "#61 repo root reached via a symlink does NOT warn" "$(printf '%s' "$SYMOUT" | grep -q 'NOT the repository root' && echo 1 || echo 0)"
# The control that keeps the fix from being a mute button: a genuine subdirectory scaffold still warns.
mkdir -p "$R/real/sub"
SUBOUT="$( cd "$R/real/sub" && bash "$INIT" 2>&1 )"
check "#61 a genuine subdirectory scaffold still warns" "$(printf '%s' "$SUBOUT" | grep -q 'NOT the repository root' && echo 0 || echo 1)"
# ...and reached through the symlink also still warns — the fix resolves both sides.
SUBLNK="$( cd "$R/link/sub" && bash "$INIT" 2>&1 )"
check "#61 a subdirectory reached via the symlink still warns" "$(printf '%s' "$SUBLNK" | grep -q 'NOT the repository root' && echo 0 || echo 1)"
# It names PHYSICAL paths on both sides — the message used to print the LOGICAL $PWD beside the physical
# toplevel, inviting the exact misreading #61 was.
check "#61 the warning names physical paths on both sides" "$(printf '%s' "$SUBLNK" | grep -q "scaffolding at $( cd "$R/real/sub" && pwd -P ), which is NOT" && echo 0 || echo 1)"
rm -rf "$R"

########################################################################
echo "-- Case 21: a crashed lock holder is identified, not inferred from time"
# Reclamation used to infer "crashed" from elapsed time (cannot tell slow from dead) — the root of F03. Now
# records host/uid/pid and asks the kernel. Only judged on OUR host/uid — kill -0 on another user's process
# fails EPERM, which would fail open, so anything unjudgeable falls back to the old time-based path.
P="$(newproj)"; ( cd "$P" && bash "$INIT" >/dev/null 2>&1 )
LK="$P/.operator/.lock"
TMPD="$(newproj)"

# A pid that is definitely dead: spawn, reap, reuse its number.
sleep 0.1 & DEADPID=$!; wait "$DEADPID" 2>/dev/null || true

# (a) A dead holder is reclaimed promptly — the kernel answers in microseconds vs the old 30s budget.
( cd "$P" && bash "$TASK" T-DEAD --owner SESS-A >/dev/null 2>&1 )
mkdir -p "$LK"; printf '%s %s %s\n' "${HOSTNAME:-nohost}" "${UID:-0}" "$DEADPID" > "$LK/holder"
SEC0=$(date +%s)
( cd "$P" && bash "$VERDICT" T-DEAD crit ev PASS --owner SESS-A >/dev/null 2>&1 )
DRC=$?
SEC1=$(date +%s)
check "dead holder: writer succeeds" "$([ "$DRC" -eq 0 ] && echo 0 || echo 1)"
check "dead holder: reclaimed promptly, not after the full budget (<10s)" "$([ "$((SEC1 - SEC0))" -lt 10 ] && echo 0 || echo 1)"
check "dead holder: verdict actually recorded" "$(grep -Eq '^\| T-DEAD \| crit \| ev @[^ |]+ \| PASS \|$' "$P/.operator/VERDICTS.md" && [ ! -e "$P/.operator/pending/T-DEAD" ] && echo 0 || echo 1)"
check "dead holder: no lock or claim marker left behind" "$([ ! -d "$LK" ] && [ ! -d "$LK.reclaim" ] && echo 0 || echo 1)"

# (b) A LIVE holder is never reclaimed however far past budget: F03's root was rmdir'ing the live holder's lock
# so its own release removed the NEW holder's lock too. Runs on a tiny env-overridable budget (audit F08/F09 — the
# real 160s budget made "completed" a flaky timing race). LOCK_LIVE_SPINS hardcoded, not read ambient (review note).
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
# The stamp makes the lock dir non-empty, so it outlives a plain rm -rf unless the stamp goes first.
rm -f "$LK/holder" "$LK.reclaim/holder" 2>/dev/null || true
rm -rf "$LK" "$LK.reclaim"

# (c) RECLAIM EXCLUSIVITY. Backlog #2 wanted a test discriminating against naive rmdir+mkdir; six timing
# approaches all read 0/N unsafe (P(collision)~1e-5 per trial — arithmetic, not achievable black-box). What survives:
# the stamp makes the lock dir non-empty and rmdir refuses non-empty dirs, so a reclaimer must delete the stamp
# first — deterministic, not probabilistic. Case (f) below asserts that directly.
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
check "two simultaneous reclaimers: both verdicts recorded" "$(grep -Eq '^\| T-X1 \| c \| e @[^ |]+ \| PASS \|$' "$P/.operator/VERDICTS.md" && grep -Eq '^\| T-X2 \| c \| e @[^ |]+ \| PASS \|$' "$P/.operator/VERDICTS.md" && echo 0 || echo 1)"
check "two simultaneous reclaimers: nothing left behind" "$([ ! -d "$LK" ] && [ ! -d "$LK.reclaim" ] && echo 0 || echo 1)"

# (d) An unjudgeable holder record must fall back to time-based, never be treated as dead (fail-open direction).
rm -rf "$LK" "$LK.reclaim"
mkdir -p "$LK"; printf 'someoneelse.example 65534 %s\n' "$DEADPID" > "$LK/holder"
( cd "$P" && bash "$TASK" T-FH --owner SESS-A >/dev/null 2>&1 )
SEC0=$(date +%s)
( cd "$P" && bash "$VERDICT" T-FH c e PASS --owner SESS-A >/dev/null 2>&1 ) &
FHPID=$!
sleep 3
check "foreign-host holder is not judged dead (no instant reclaim)" "$(sentinel_any "$P" T-FH && echo 0 || echo 1)"
# Kill the GRANDCHILD too (#68): `$!` names the subshell, killing it alone orphans the child bash — measured 54
# such orphans on a dev machine, ~1 core each, oldest ~17 days. Both backgrounding shapes in this suite orphan
# (a review round wrongly claimed one form was orphan-proof; measured false — exec only happens as the last command).
reap_kids "$FHPID"
kill -9 "$FHPID" 2>/dev/null || true; wait "$FHPID" 2>/dev/null || true
rm -rf "$LK" "$LK.reclaim"
# (e) The two lock implementations must not drift — they contend on the same .operator/.lock. Compare code with
# tool names normalized away. (f) The structural guarantee behind (c): a held lock is stamped, and a stamped
# directory cannot be rmdir'd — this is what actually prevents a reclaimer stepping onto a fresh lock.
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

# Env-overridable lock budgets must validate (review F-A/B/C): a non-numeric/zero value used to wedge forever
# (F-A) or collapse the reclaim budget to zero (F-B, the F03 class). RECLAIM_WAIT >= LOCK_SPINS also refused (F-C).
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
echo "-- Case 21b: the give-up path is serialized by the fallback lock [F6]"
# lock_acquire has two "proceed unlocked" exits (confirmed-live holder, failed reclaim) that used to return 0
# having acquired nothing — every timed-out waiter entered the critical section together, N-wide. They now queue
# on $LOCKDIR.fallback. HONESTY: this does not make give-up safe against the live holder (accepted liveness trade,
# reduces N to 1 not 0); the overlap assertion below is a real detector via an atomic mkdir witness dir.
P="$(newproj)"; ( cd "$P" && bash "$INIT" >/dev/null 2>&1 )
LK="$P/.operator/.lock"
TMPD="$(newproj)"

# The unit probe evals the real LOCK BLOCK, like case 21(f) — no reimplementation.
cat > "$TMPD/fb.sh" <<'FBPROBE'
set -eu
OPDIR=".operator"; LOCKDIR="$OPDIR/.lock"
eval "$(awk '/^# >>> LOCK BLOCK/,/^# <<< LOCK BLOCK/' "$1")"
case "$2" in
  cycle)   # a plain acquire/release leaves nothing behind
    fallback_acquire
    [ "$FALLBACK_HELD" = "1" ] || { echo "NOT-HELD"; exit 1; }
    [ -s "$FALLBACK_DIR/holder" ] || { echo "NO-STAMP"; exit 1; }
        # A non-empty stamp is not enough: it must name US — `-s` alone passes on a reclaim that recreates the dir
        # without restoring ownership, misleading every later liveness judgement. Checked here because only this
        # seat can observe mid-hold.
    case "$(cat "$FALLBACK_DIR/holder")" in *" $$") ;; *) echo "STAMP-NOT-MINE"; exit 1 ;; esac
    fallback_release
    [ -d "$FALLBACK_DIR" ] && { echo "NOT-RELEASED"; exit 1; }
    echo OK ;;
  reclaim) # a CRASHED giver-up's dir is reclaimed — staleness-free
    fallback_acquire
    [ "$FALLBACK_HELD" = "1" ] || { echo "NOT-RECLAIMED"; exit 1; }
    fallback_release
    echo OK ;;
  live)    # a LIVE giver-up's dir is never stolen, and the wait is bounded
        # Giving up on the fallback warns on stderr; the harness folds stderr into the probe's output.
    fallback_acquire 2>/dev/null
    [ "$FALLBACK_HELD" = "0" ] || { echo "STOLE-LIVE"; exit 1; }
    echo OK ;;
  witness) # hold the fallback, then prove no one else is inside it
    fallback_acquire
    mkdir "$OPDIR/.witness" 2>/dev/null || { echo OVERLAP; exit 1; }
    sleep 0.4
    rmdir "$OPDIR/.witness"
    fallback_release
    echo OK ;;
esac
FBPROBE

FBOUT="$( cd "$P" && bash "$TMPD/fb.sh" "$SCRIPTS/ops-verdict.sh" cycle 2>&1 )"
check "fallback lock: acquire stamps, release leaves no dir" "$([ "$FBOUT" = "OK" ] && echo 0 || echo 1)"

# A dead holder: a one-shot claim dir with no reclaim would dangle forever, the mistake already made once (.lock.reclaim, case 16).
sleep 0.1 & FBDEAD=$!; wait "$FBDEAD" 2>/dev/null || true
mkdir -p "$LK.fallback"; printf '%s %s %s\n' "${HOSTNAME:-nohost}" "${UID:-0}" "$FBDEAD" > "$LK.fallback/holder"
FBOUT="$( cd "$P" && bash "$TMPD/fb.sh" "$SCRIPTS/ops-verdict.sh" reclaim 2>&1 )"
check "fallback lock: a crashed giver-up's dir is reclaimed (staleness-free)" "$([ "$FBOUT" = "OK" ] && echo 0 || echo 1)"
check "fallback lock: reclaimed and then released — nothing left behind" "$([ ! -d "$LK.fallback" ] && echo 0 || echo 1)"

# A LIVE holder is waited on, never stolen, and the wait EXPIRES — unbounded here would deadlock the degrade path.
sleep 300 & FBLIVE=$!
mkdir -p "$LK.fallback"; printf '%s %s %s\n' "${HOSTNAME:-nohost}" "${UID:-0}" "$FBLIVE" > "$LK.fallback/holder"
SEC0=$(date +%s)
FBOUT="$( cd "$P" && FALLBACK_SPINS=10 bash "$TMPD/fb.sh" "$SCRIPTS/ops-verdict.sh" live 2>&1 )"
SEC1=$(date +%s)
check "fallback lock: a LIVE giver-up's dir is not stolen" "$([ "$FBOUT" = "OK" ] && echo 0 || echo 1)"
check "fallback lock: waiting on a live holder is bounded (<10s at spins=10)" "$([ "$((SEC1 - SEC0))" -lt 10 ] && echo 0 || echo 1)"
FBHOLD="$(cat "$LK.fallback/holder" 2>/dev/null || true)"
FBOK=1; case "$FBHOLD" in *" $FBLIVE") FBOK=0 ;; esac
check "fallback lock: live holder still owns it after the waiter gave up" "$FBOK"
kill "$FBLIVE" 2>/dev/null || true; wait "$FBLIVE" 2>/dev/null || true
rm -f "$LK.fallback/holder"; rm -rf "$LK.fallback"

# Three concurrent givers-up; overlap is caught by the witness mkdir, not by reading a clock.
OVERLAP=0
for _i in 1 2 3; do
  ( cd "$P" && bash "$TMPD/fb.sh" "$SCRIPTS/ops-verdict.sh" witness > "$TMPD/w$_i" 2>&1 ) &
done
wait
for _i in 1 2 3; do
  [ "$(cat "$TMPD/w$_i" 2>/dev/null)" = "OK" ] || OVERLAP=$((OVERLAP + 1))
done
check "fallback lock: 3 concurrent givers-up never overlap (witness mkdir)" "$([ "$OVERLAP" -eq 0 ] && echo 0 || echo 1)"
check "fallback lock: nothing left behind after the 3-way run" "$([ ! -d "$LK.fallback" ] && [ ! -d "$P/.operator/.witness" ] && echo 0 || echo 1)"

# END-TO-END, and the constraint that matters most: a giver-up must never set LOCK_HELD or touch $LOCKDIR — that
# would rm the LIVE holder's dir, exactly the F03 displacement the confirmed-alive branch forbids.
sleep 300 & FBLIVE2=$!
mkdir -p "$LK"; printf '%s %s %s\n' "${HOSTNAME:-nohost}" "${UID:-0}" "$FBLIVE2" > "$LK/holder"
( cd "$P" && bash "$TASK" T-FB --owner SESS-A >/dev/null 2>&1 )
( cd "$P" && LOCK_LIVE_SPINS=5 FALLBACK_SPINS=10 bash "$VERDICT" T-FB crit ev PASS --owner SESS-A >/dev/null 2>&1 )
FBRC=$?
check "give-up path: the writer still completes (degrade, never hang)" "$([ "$FBRC" -eq 0 ] && echo 0 || echo 1)"
check "give-up path: verdict actually recorded" "$(grep -Eq '^\| T-FB \| crit \| ev @[^ |]+ \| PASS \|$' "$P/.operator/VERDICTS.md" && echo 0 || echo 1)"
FBHOLD="$(cat "$LK/holder" 2>/dev/null || true)"
FBOK=1; case "$FBHOLD" in *" $FBLIVE2") FBOK=0 ;; esac
check "give-up path: the LIVE holder's real lock is untouched (not displaced)" "$([ -d "$LK" ] && [ "$FBOK" = "0" ] && echo 0 || echo 1)"
check "give-up path: its fallback lock was released on exit" "$([ ! -d "$LK.fallback" ] && echo 0 || echo 1)"

# Every assertion above holds regardless of whether lock_acquire ever calls fallback_acquire (measured: deleting
# all four call sites left the suite at 588/0 — the mechanism was only tested via the fb.sh probe, nothing
# exercised the wiring). Pre-plant a fallback dir stamped with a DEAD pid: wired, it's reclaimed and gone;
# unwired, it survives — the two worlds differ in end state, not elapsed time.
sleep 300 & FBDEAD=$!
kill "$FBDEAD" 2>/dev/null || true; wait "$FBDEAD" 2>/dev/null || true   # now a confirmed-dead pid
mkdir -p "$LK" "$LK.fallback"
printf '%s %s %s\n' "${HOSTNAME:-nohost}" "${UID:-0}" "$FBLIVE2" > "$LK/holder"
printf '%s %s %s\n' "${HOSTNAME:-nohost}" "${UID:-0}" "$FBDEAD" > "$LK.fallback/holder"
( cd "$P" && bash "$TASK" T-FB2 --owner SESS-A >/dev/null 2>&1 )
( cd "$P" && LOCK_LIVE_SPINS=5 FALLBACK_SPINS=30 bash "$VERDICT" T-FB2 crit ev PASS --owner SESS-A >/dev/null 2>&1 )
check "give-up path: the fallback lock is actually TAKEN (dead holder reclaimed, not ignored)" \
  "$([ ! -d "$LK.fallback" ] && echo 0 || echo 1)"
check "give-up path: the writer still records while reclaiming the fallback" \
  "$(grep -Eq '^\| T-FB2 \| crit \| ev @[^ |]+ \| PASS \|$' "$P/.operator/VERDICTS.md" && echo 0 || echo 1)"

kill "$FBLIVE2" 2>/dev/null || true; wait "$FBLIVE2" 2>/dev/null || true
rm -f "$LK/holder" "$LK.fallback/holder" 2>/dev/null || true

# --- the SAME guarantee on the --reconcile path ---
# `trap` REPLACES a handler; it doesn't stack. --reconcile's own tempfile trap silently dropped fallback_release
# for the rest of the process, leaking $LOCKDIR.fallback on every contended reconcile. Asserted on the real
# script against a real live holder, since a source-grep for the handler string would pass on a trap that never runs.
sleep 300 & FBLIVE3=$!
mkdir -p "$LK"; printf '%s %s %s\n' "${HOSTNAME:-nohost}" "${UID:-0}" "$FBLIVE3" > "$LK/holder"
( cd "$P" && LOCK_LIVE_SPINS=3 bash "$VERDICT" --reconcile >/dev/null 2>&1 )
RECRC=$?
check "--reconcile under contention: still completes (degrade, never hang)" \
  "$([ "$RECRC" -eq 0 ] && echo 0 || echo 1)"
check "--reconcile under contention: its fallback lock is released on exit" \
  "$([ ! -d "$LK.fallback" ] && echo 0 || echo 1)"
FBHOLD="$(cat "$LK/holder" 2>/dev/null || true)"
FBOK=1; case "$FBHOLD" in *" $FBLIVE3") FBOK=0 ;; esac
check "--reconcile under contention: the LIVE holder's real lock is untouched" \
  "$([ -d "$LK" ] && [ "$FBOK" = "0" ] && echo 0 || echo 1)"
kill "$FBLIVE3" 2>/dev/null || true; wait "$FBLIVE3" 2>/dev/null || true
rm -f "$LK/holder" "$LK.fallback/holder" 2>/dev/null || true
rm -rf "$P" "$TMPD"

########################################################################
echo "-- Case 22: the statusline segment reports the gate, not a file count"
# The bar's value is answering "will my stop be blocked?" — a raw pending/ count answers a different question
# wrongly both ways. The segment runs the hook's own MINE+UNOWNED-block/FOREIGN-doesn't partition. Renders on a
# ~300ms timer (the hottest reader by 3 orders of magnitude), so its byte bound is load-bearing.
SL="$SCRIPTS/statusline.sh"
# Case 5's PATH_NOJQ/PATH_NONE dirs are deleted at its end; build fresh ones here rather than test a nonexistent PATH.
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

# Exit status is part of the renderer contract: a trailing `[ -n ] && printf` made an empty wf segment the
# script's failing last command, so the common case exited 1 while main exited 0 on the same payload (review
# panel, 2026-08-02) — no prior case asserted the exit code, which is why it regressed silently.
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
# THE ASSERTION A FILE COUNT FAILS: one directory, three sentinels, and the answer differs per viewer.
check "owner's view: 1 blocking + 2 foreign" \
  "$([ "$(render SESS-A "$P")" = "op[1+2*]" ] && echo 0 || echo 1)"
check "other owner's view: 2 blocking + 1 foreign" \
  "$([ "$(render SESS-B "$P")" = "op[2+1*]" ] && echo 0 || echo 1)"
check "bystander's view: 0 blocking + 3 foreign (nothing gates them)" \
  "$([ "$(render SESS-C "$P")" = "op[0+3*]" ] && echo 0 || echo 1)"

# A pre-0.4 empty sentinel is unowned, and unowned blocks EVERYONE — showing 0 while the hook blocks is the regression.
: > "$P/.operator/pending/T-LEGACY"
check "an unowned sentinel counts as blocking, for a bystander too" \
  "$([ "$(render SESS-C "$P")" = "op[1+3*]" ] && echo 0 || echo 1)"
rm -f "$P/.operator/pending/T-LEGACY"

# Same untrusted-body rules as every other reader (docs/PLAYBOOK.md) — degrade to unowned=blocking, never believed as foreign.
printf 'session_id: ../../PWNED\n' > "$P/.operator/pending/T-EVIL"
check "a traversal-shaped owner degrades to unowned, not foreign" \
  "$([ "$(render SESS-C "$P")" = "op[1+3*]" ] && echo 0 || echo 1)"
rm -f "$P/.operator/pending/T-EVIL"

# A CRLF checkout must not make a session's own task look foreign — the same fail-open that bit the hook.
printf 'session_id: SESS-A\r\n' > "$P/.operator/pending/T-CRLF"
check "a CRLF sentinel still reads as MINE, not foreign" \
  "$([ "$(render SESS-A "$P")" = "op[2+2*]" ] && echo 0 || echo 1)"
rm -f "$P/.operator/pending/T-CRLF"

# The segment resolves the project by the same upward walk as the hook, or the bar describes a different gate (audit F01).
mkdir -p "$P/sub/deeper"
check "a subdirectory cwd finds the same gate (F01 shape)" \
  "$([ "$(render SESS-A "$P/sub/deeper")" = "op[1+2*]" ] && echo 0 || echo 1)"

# --- dev[N] mirror: the bar renders the deviation gate's partition (stage 2) ---
# Same coupling rule as op[ ]. Counts mine+unowned DEVIATIONs after the last mine/unowned HANDOFF-MARK; foreign
# excluded; dim not red (an unpresented decision blocks stop, not current work).
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

# Hostile/degenerate stdin must render nothing, including the no-parser case (a statusline has nowhere to warn).
# Run from SLBARE, a temp dir with no .operator/ at or above it — statusline.sh:84 falls back to $PWD when it
# cannot parse cwd. These used to run with cwd=this repo, which vacuously passed because it has never been
# scaffolded (#21's class) — the positive control below keeps it non-vacuous.
SLBARE="$(newproj)"
# `.git` bounds the upward walk (statusline.sh:86-95); "a temp dir with no .operator/" was true only by luck —
# TMPDIR inside a scaffolded project finds an ancestor ledger. The fixture is now hermetic by construction.
mkdir -p "$SLBARE/.git"
# CLAUDE_PROJECT_DIR is unset at each invocation: the harness exports it, and statusline.sh:84's
# ${CLAUDE_PROJECT_DIR:-$PWD} would override the fixture's cwd otherwise (measured both false-positive directions).
# The setup must be verified BEFORE reliance: `cd "$SLBARE" && …` inside `$( )` also yields empty on a failed cd,
# which would report ok for a run that never invoked the renderer (#21's class, one layer under the rewrite).
check "control: the statusline fixture dirs exist before the silence cases run" \
  "$([ -d "$SLBARE" ] && echo 0 || echo 1)"
check "control: the silence fixture bounds the upward .operator walk (hermetic under any TMPDIR)" \
  "$([ -d "$SLBARE/.git" ] && echo 0 || echo 1)"
check "garbage payload renders nothing" \
  "$([ -z "$(cd "$SLBARE" && printf 'NOT JSON{{' | env -u CLAUDE_PROJECT_DIR "$BASH_ABS" "$SL" 2>&1)" ] && echo 0 || echo 1)"
check "empty payload renders nothing" \
  "$([ -z "$(cd "$SLBARE" && printf '' | env -u CLAUDE_PROJECT_DIR "$BASH_ABS" "$SL" 2>&1)" ] && echo 0 || echo 1)"
# No jq and no python3: even `cat` is gone, which is why the segment slurps stdin with the `read` builtin.
check "no parser and no external commands: silent, no stray output" \
  "$([ -z "$(cd "$SLBARE" && sljson SESS-A "$P" | env -u CLAUDE_PROJECT_DIR PATH="$SLNONE" "$BASH_ABS" "$SL" 2>&1)" ] && echo 0 || echo 1)"
# The positive control for all three: silence above must come from an empty ledger, not from giving up on garbage
# stdin. Same garbage stdin, cwd switched to a project with a pending sentinel — the segment must still appear.
# The sentinel's session_id stamp is decorative here: on unparseable payload SESSION is empty, so every sentinel
# falls to mine/unowned regardless of the stamp (measured — a foreign stamp renders identically).
SLFB="$(newproj)"; ( cd "$SLFB" && bash "$INIT" >/dev/null 2>&1 )
printf 'session_id: SESS-A\n' > "$SLFB/.operator/pending/fallback-probe"
check "control: the fallback fixture has a sentinel to render" \
  "$([ -f "$SLFB/.operator/pending/fallback-probe" ] && echo 0 || echo 1)"
check "unparseable payload falls back to \$PWD, not to silence (statusline.sh:84)" \
  "$(cd "$SLFB" && printf 'NOT JSON{{' | env -u CLAUDE_PROJECT_DIR "$BASH_ABS" "$SL" 2>/dev/null \
     | LC_ALL=C tr -d '\033' | LC_ALL=C sed 's/\[[0-9]*m//g' \
     | grep -q 'op\[1\]' && echo 0 || echo 1)"
# Removed like every other project dir here — SLFB carries a pending sentinel and would seed $TMPDIR ambient state.
rm -rf "$SLBARE" "$SLFB"
# ...and it must TERMINATE, not just stay quiet: `cat` under an empty PATH hangs rather than fails (found by
# mutation-testing this case — the mutant ran until killed while output assertions looked fine). A deadline catches it.
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
# The python3 fallback must produce the SAME partition as jq, or the bar tells two stories depending on the machine.
if [ -n "$SLPYBIN" ] && [ -x "$SLPYBIN" ]; then
  check "python3 fallback agrees with jq" \
    "$([ "$(sljson SESS-A "$P" | PATH="$SLPY" "$BASH_ABS" "$SL" 2>/dev/null \
          | LC_ALL=C tr -d '\033' | LC_ALL=C sed 's/\[[0-9]*m//g')" = "op[1+2*]" ] && echo 0 || echo 1)"
else
  fail "python3 fallback agrees with jq (no python3 resolved — fallback untested)"
fi

# A directory in pending/ is not a task; the `-f` guard exists because a bash error was once emitted as operator guidance.
mkdir -p "$P/.operator/pending/T-DIR"
check "a directory in pending/ is not counted as a task" \
  "$([ "$(render SESS-A "$P")" = "op[1+2*]" ] && echo 0 || echo 1)"
rmdir "$P/.operator/pending/T-DIR"

# The byte bound, on the reader that renders every 300ms — unbounded, this file measured 6.20s per parse.
bigline "$P/.operator/pending/T-HUGE"
S0=$(date +%s); OUT_HUGE="$(render SESS-A "$P")"; S1=$(date +%s)
check "a 64MB single-line sentinel renders in bounded time (<3s)" \
  "$([ "$((S1 - S0))" -lt 3 ] && echo 0 || echo 1)"
check "the huge sentinel is still counted (bounded, not skipped)" \
  "$([ "$OUT_HUGE" = "op[2+2*]" ] && echo 0 || echo 1)"
rm -f "$P/.operator/pending/T-HUGE"

# The manifest is how cc-status discovers the segment; an unresolvable renderer path means it silently never appears.
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
# commands/tiers.md is a thin wrapper over ops-tiers.sh; what it must guarantee: it exists, its allowed-tools grants
# the invocation, and it uses ${CLAUDE_PLUGIN_ROOT} (a bare scripts/ path only resolves inside this repo — v0.2.0 bug).
CMD="$REPO/commands/tiers.md"
check "commands/tiers.md exists" "$([ -f "$CMD" ] && echo 0 || echo 1)"
check "tiers.md grants ops-tiers.sh via CLAUDE_PLUGIN_ROOT" \
  "$(grep -q 'allowed-tools:.*CLAUDE_PLUGIN_ROOT.*scripts/ops-tiers.sh' "$CMD" && echo 0 || echo 1)"
# The resolver's behavior, invoked as the command invokes it. Env isolated so a maintainer's real tiers.env can't
# leak in; CC_PROXY_PORT points at a dead port so the liveness probe is instant.
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
# WHAT THE GUARD NO LONGER DOES (0.8.3). Until 0.8.2 this asserted an id-shape/provider-lens catalogue mirroring
# cc-proxy's PROVIDER_IDS — measured 2026-08-15 against a live cc-proxy serving 409 ids, it refused 8 that route
# fine. The user picks the model, cc-proxy routes it, operator decides neither. These cases now assert ACCEPTANCE.
for _id in bogus-id deepseek-v4-flash qwen3.8-max bogus:some-model \
           bogus:vendor/model x-ai/grok-4.6 glm-5.3 qwen:; do
  TIERSENV --set "MECHANICAL=$_id" >/dev/null 2>&1; _rc=$?
  check "an id operator does not recognise is accepted ($_id) — the user chooses, cc-proxy routes" \
    "$([ "$_rc" -eq 0 ] && echo 0 || echo 1)"
done
# The negative control and the whole remaining guard: a MALFORMED field (whitespace/quote) is still refused —
# about the string, not which models exist, so it cannot go stale.
TIERSENV --set 'MECHANICAL=claude opus' >/dev/null 2>&1; BADCHAR=$?
check "a whitespace-bearing id is still refused (the field is malformed, F01)" \
  "$([ "$BADCHAR" -ne 0 ] && echo 0 || echo 1)"
BADCHARMSG="$(TIERSENV --set 'MECHANICAL=glm-5"q' 2>&1)"
check "the charset refusal names the charset, not a catalogue of known ids" \
  "$(printf '%s' "$BADCHARMSG" | grep -q 'outside \[A-Za-z0-9._:/@\[\]-\]' && echo 0 || echo 1)"
# Ids legal before AND after: the change only widens, so nothing that used to route may have stopped.
for _id in qwen:deepseek-v4-pro openrouter:qwen/x openai/gpt-5 \
           deepseek/deepseek-r1:free qwen/qwen3-max:nitro qwen:a:b 'glm-5.2[1m]'; do
  TIERSENV --set "MECHANICAL=$_id" >/dev/null 2>&1; _rc=$?
  check "a previously-legal id still resolves ($_id) — 0.8.3 only widens" \
    "$([ "$_rc" -eq 0 ] && echo 0 || echo 1)"
done
# tiers.env carries two line kinds; the resolver must SKIP a seat line, not die on it — the scaffold's own
# documented example used to kill every resolver invocation once uncommented (audit F15).
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

# A comment longer than the 512-char read cap used to smuggle a live tier binding past the check (`read -n 512`
# truncates mid-line, the remainder arrives as a fresh line). Measured pre-fix: resolved MECHANICAL=glm-evil at exit 0.
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
# A NUL is the same smuggle by a shorter road, only on the bash the repo targets: bash 3.2's `read -n` stops at
# a NUL, and ${#line} can't catch it (bash drops NULs from variables) — invisible on bash 5.3, which is why the
# suite was green while system bash was exploitable.
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
# A single 512-byte probe only closed the door at the front of the file; a NUL later in the file still resolved
# a live assignment (Copilot 2026-08-03) — the probe must walk the WHOLE file.
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
# The probe is bounded at 200 chunks (100KB): a newline-less multi-MB tiers.env must die fast, not loop the whole
# file (66-70s uncapped vs 0.11s capped, bash 3.2.57, 2026-08-04). Fixture must be 16MB — 2MB stayed under budget
# on both the broken and fixed code (code-review of f4cae1a, PLAYBOOK "prove it discriminates").
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
# The probe cap must not narrow accepted input below the parse loop's own limit (~100KB): the first cap (20KB)
# broke a legitimate 24KB comment-heavy tiers.env that had resolved fine (code-review of f4cae1a, 2026-08-04).
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
# A MULTIBYTE comment smuggles through the char/byte-mismatched length guard on BASH_OLD (read -n counts bytes,
# ${#line} counts chars under UTF-8, full-PR panel score 85) — LC_ALL=C in the parse loop fixes it.
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
# ops-render.sh renders project-layer agents (.claude/agents/op-*.md) so a plain Agent dispatch can run on a
# cc-proxy model; these cases exercise the renderer's behavior, not just its validator-level shape.
RENDER="$SCRIPTS/ops-render.sh"
check "commands/tiers.md grants ops-render.sh via CLAUDE_PLUGIN_ROOT" \
  "$(grep -q 'allowed-tools:.*CLAUDE_PLUGIN_ROOT.*scripts/ops-render.sh' "$CMD" && echo 0 || echo 1)"
check "tiers.md documents the render branch" \
  "$(grep -q 'render' "$CMD" && echo 0 || echo 1)"

# A render fixture project, isolated from the maintainer's real tiers.env; CC_PROXY_PORT=1 makes --check instant.
RENDERENV() { # RENDERENV <args...> -> runs in the fixture project
  CC_OPERATOR_TIERS_USER=/nonexistent CC_PROXY_PORT=1 \
  "$BASH_ABS" "$RENDER" "$@"
}
RP="$(newproj)"
# newproj does not init .operator; the renderer needs .operator/tiers.env + templates (from the plugin install).
( cd "$RP" && "$BASH_ABS" "$INIT" >/dev/null 2>&1 )

# --show: the resolved seat→model table, with a tier repoint applied.
printf 'MECHANICAL=glm-5-turbo\nop-scout=MECHANICAL\n' > "$RP/.operator/tiers.env"
SHOWR="$( cd "$RP" && RENDERENV --show 2>/dev/null )"; SHOWRRC=$?
check "ops-render --show prints the SEAT/TIER/MODEL/SOURCE table" \
  "$([ "$SHOWRRC" -eq 0 ] && printf '%s' "$SHOWR" | grep -q '^SEAT *TIER *MODEL' && echo 0 || echo 1)"
check "ops-render --show resolves a repointed tier (crawler: MECHANICAL→glm-5-turbo)" \
  "$(printf '%s' "$SHOWR" | grep -q 'crawler.*MECHANICAL.*glm-5-turbo' && echo 0 || echo 1)"
# F21: implementer seats default to their ALIAS tiers; a MECHANICAL repoint must not move them (down-tiering is a
# deliberate tiers.env act, never a default).
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
# Single-source bodies (F14): the rendered implementer seats must keep the plugin-root agent's tools line — the
# template-era render silently stripped Write/Edit from author/mechanic (a rendered implementer that can't implement).
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
printf 'op-scout=BOGUS\n' > "$RP/.operator/tiers.env"
( cd "$RP" && RENDERENV --show >/dev/null 2>&1 ); G2=$?
check "guard: seat bound to unknown tier is refused (non-zero exit)" "$([ "$G2" -ne 0 ] && echo 0 || echo 1)"
# The renderer carries its own copy of check_routable (parity pinned by check_resolver_renderer_parity); parity
# proves sameness, not correctness, so both halves are asserted here too.
for _id in not-a-model deepseek-v4-flash qwen3.8-max bogus:some-model \
           qwen:deepseek-v4-pro; do
  printf 'MECHANICAL=%s\n' "$_id" > "$RP/.operator/tiers.env"
  ( cd "$RP" && RENDERENV --show >/dev/null 2>&1 ); _rc=$?
  check "guard: the renderer accepts an id it does not recognise ($_id)" \
    "$([ "$_rc" -eq 0 ] && echo 0 || echo 1)"
done
printf 'MECHANICAL=glm 5\n' > "$RP/.operator/tiers.env"
( cd "$RP" && RENDERENV --show >/dev/null 2>&1 ); G3=$?
check "guard: whitespace in model id is refused (non-zero exit)" "$([ "$G3" -ne 0 ] && echo 0 || echo 1)"

# M7: CLAUDE_CODE_SUBAGENT_MODEL set → warned (it overrides frontmatter at dispatch).
printf 'MECHANICAL=glm-5-turbo\n' > "$RP/.operator/tiers.env"
M7WARN="$( cd "$RP" && CC_OPERATOR_TIERS_USER=/nonexistent CC_PROXY_PORT=1 \
  CLAUDE_CODE_SUBAGENT_MODEL=glm-5.2 "$BASH_ABS" "$RENDER" --show 2>&1 )"
check "M7: warns when CLAUDE_CODE_SUBAGENT_MODEL is set (overrides frontmatter)" \
  "$(printf '%s' "$M7WARN" | grep -qi 'CLAUDE_CODE_SUBAGENT_MODEL' && echo 0 || echo 1)"

# Renderer ownership (F17): render/revert delete ONLY render-mark-stamped files; a hand-authored file at a
# seat's own name must block loudly rather than be overwritten.
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

# Seat-name allowlist (F18): a metachar used to be interpolated into a BRE ('s.out' deleted the scout record via
# grep -v); now anything outside [A-Za-z0-9_-] is refused loudly.
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
# --check is a documented user-facing branch (commands/tiers.md) that no test invoked; probes each distinct
# non-claude id against cc-proxy — claude-* ids are harness-served and skipped.
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
# The awk splice anchors on /^---$/, which `---\r` does not match — a CRLF template left every substitution
# skipped and the file copied through with the literal placeholder still in place, exit 0 (old post-splice
# guard couldn't see it, matching the untouched line). Templates resolve from the PLUGIN root, so mirror both
# scripts + a CRLF default.tmpl into a throwaway plugin root.
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
# The post-splice guard must assert the VALUE — a template with no model: line renders bound to the default backend.
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
# The wf segment reads the newest LIVE journal.jsonl (done/started ratio), never a %. Fails toward silence on an
# absent/stale journal. Fresh project since Case 22's $P has open sentinels that would mask the wf-only assertion.
WFPROJ="$(newproj)"; ( cd "$WFPROJ" && bash "$INIT" >/dev/null 2>&1 )
WFSESS="wf-sess-test"
WFDIR="$HOME/.claude/projects/wftestproj/$WFSESS/subagents/workflows/wf_abc"
mkdir -p "$WFDIR"
# Backdate with `touch -t`, not `date -v`/`date -d` (BSD/GNU split — the BSD form silently emptied on Linux CI,
# so the "stale" cases never actually backdated anything).
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
# Fresh run: started>0, done=0. `grep -c` prints "0" AND exits 1 on zero matches — an `|| echo 0` fallback used to
# render a two-line segment (audit F12, hit on a live run's first phase).
mkjournal 3 0
WF0="$(render "$WFSESS" "$WFPROJ")"
check "fresh run (done=0) → renders 'wf 0/3' on ONE line (F12)" \
  "$([ "$WF0" = "wf 0/3" ] && echo 0 || echo 1)"
# Stale journal: backdate >90s → no wf segment (liveness fails, and $P has no open tasks either).
mkjournal 12 5
backdate "$WFDIR/journal.jsonl"
check "stale journal (>90s) → no wf segment" \
  "$([ -z "$(render "$WFSESS" "$WFPROJ")" ] && echo 0 || echo 1)"
# Long dispatch: journal quiet >90s but a fresh agent transcript makes the run LIVE (journals append only on
# dispatch events; audit F26). Liveness = newest of journal + agent-*.jsonl.
printf '%s\n' '{"x":1}' > "$WFDIR/agent-live.jsonl"
check "quiet journal + fresh agent transcript → still live (F26)" \
  "$([ "$(render "$WFSESS" "$WFPROJ")" = "wf 5/12" ] && echo 0 || echo 1)"
# ...and when the transcript is ALSO stale, the run is genuinely stopped.
backdate "$WFDIR/agent-live.jsonl"
check "quiet journal + stale agent transcript → no wf segment" \
  "$([ -z "$(render "$WFSESS" "$WFPROJ")" ] && echo 0 || echo 1)"
rm -f "$WFDIR/agent-live.jsonl"
# UNBALANCED journal (started>result) = a dispatch in flight; mtime silence proves nothing (a measured GLM run
# went >110s untouched — the old 90s window flapped the segment off mid-run, 2026-08-03).
agequiet() { # agequiet <path> <seconds-ago>
  python3 -c "import os,sys,time; t=time.time()-int(sys.argv[2]); os.utime(sys.argv[1],(t,t))" "$1" "$2"
}
mkjournal 12 5
agequiet "$WFDIR/journal.jsonl" 300
check "unbalanced journal quiet 300s → STILL live (dispatch in flight, no flap)" \
  "$([ "$(render "$WFSESS" "$WFPROJ")" = "wf 5/12" ] && echo 0 || echo 1)"
# ...but a BALANCED journal (finished run) keeps the tight 90s window — must clear the bar promptly, not linger 15min.
mkjournal 5 5
agequiet "$WFDIR/journal.jsonl" 300
check "balanced journal quiet 300s → no wf segment (finished runs clear fast)" \
  "$([ -z "$(render "$WFSESS" "$WFPROJ")" ] && echo 0 || echo 1)"
# ...and unbalanced past STALL_SEC is genuinely dead (errored agents never write a result line — observed same
# day: both shards died on a rate limit); without this backstop it would render forever.
mkjournal 12 5
agequiet "$WFDIR/journal.jsonl" 1200
check "unbalanced journal quiet past STALL_SEC (1200s) → no wf segment (failed-run backstop)" \
  "$([ -z "$(render "$WFSESS" "$WFPROJ")" ] && echo 0 || echo 1)"
# --- F12: STALL_SEC is validated, so a typo cannot silently kill the window ---
# Unvalidated, STALL_SEC=abc made the comparison ERROR under 2>/dev/null, short-circuiting the window and
# flapping a live segment OFF mid-run (measured). Now: warn on stderr, use 900.
mkjournal 12 5
agequiet "$WFDIR/journal.jsonl" 300
STALLBAD="$(STALL_SEC=abc sljson "$WFSESS" "$WFPROJ" | STALL_SEC=abc "$BASH_ABS" "$SL" 2>/dev/null \
  | LC_ALL=C tr -d '\033' | LC_ALL=C sed 's/\[[0-9]*m//g')"
check "STALL_SEC=abc → the stall window still applies (no silent mid-run flap, F12)" \
  "$([ "$STALLBAD" = "wf 5/12" ] && echo 0 || echo 1)"
# ...and it says so, LOUD, on stderr. Validated at FILE scope because the wf caller wraps the function in 2>/dev/null.
STALLERR="$(sljson "$WFSESS" "$WFPROJ" | STALL_SEC=abc "$BASH_ABS" "$SL" 2>&1 >/dev/null)"
check "STALL_SEC=abc warns on stderr (fail loud, like the lock budgets) (F12)" \
  "$(printf '%s' "$STALLERR" | grep -q 'STALL_SEC is not a positive integer' && echo 0 || echo 1)"
# A zero/negative-shaped value is refused too (it would collapse the window, the opposite of the knob's job).
STALLZERO="$(sljson "$WFSESS" "$WFPROJ" | STALL_SEC=0 "$BASH_ABS" "$SL" 2>/dev/null \
  | LC_ALL=C tr -d '\033' | LC_ALL=C sed 's/\[[0-9]*m//g')"
check "STALL_SEC=0 → refused, falls back to 900 (F12)" \
  "$([ "$STALLZERO" = "wf 5/12" ] && echo 0 || echo 1)"
# A VALID override still wins: 100 < the 300s quiet period → the run reads dead.
STALLOK="$(sljson "$WFSESS" "$WFPROJ" | STALL_SEC=100 "$BASH_ABS" "$SL" 2>/dev/null \
  | LC_ALL=C tr -d '\033' | LC_ALL=C sed 's/\[[0-9]*m//g')"
check "a VALID STALL_SEC override is still honored (100 → no wf segment) (F12)" \
  "$([ -z "$STALLOK" ] && echo 0 || echo 1)"

# --- F11: the started/result greps run ONCE per render, not twice ---
# The stall decision and the wf segment needed the identical grep pair; computing them twice doubled the
# render's external-process cost. Structural: reverting re-adds a second grep call site.
SLSTARTED="$(grep -c "grep -c '\"type\":\"started\"'" "$SL")"
check "statusline greps the journal's started lines from ONE site (F11)" \
  "$([ "$SLSTARTED" -eq 1 ] && echo 0 || echo 1)"
# ...and the ratio itself is unchanged by the refactor (the counts still arrive).
mkjournal 7 3
check "the returned counts still render the same ratio 'wf 3/7' (F11)" \
  "$([ "$(render "$WFSESS" "$WFPROJ")" = "wf 3/7" ] && echo 0 || echo 1)"

# --- F9: the stat-flavor probe runs ONCE per render, not once per mtime call ---
# Every call site is a subshell $(mtime …), so the flavor detection died with it and re-ran ~3x per journal.
# Measured: 9 stat invocations before, 5 after. Now its own function, called from the caller's own scope.
check "the stat-flavor probe is a separate function, not inside mtime (F9)" \
  "$(awk '/^mtime\(\)/{inm=1} inm && /_STAT_KIND=(gnu|bsd|none)/{bad=1} /^}/{inm=0} END{exit bad?1:0}' "$SL" \
     && echo 0 || echo 1)"
check "glob_newest_live_journal probes the stat flavor once per render (F9)" \
  "$(awk '/^glob_newest_live_journal\(\)/{ing=1} ing && /^ *stat_probe/{ok=1} END{exit ok?0:1}' "$SL" \
     && echo 0 || echo 1)"
mkjournal 12 5
check "mtime still resolves after the probe split (live run renders) (F9)" \
  "$([ "$(render "$WFSESS" "$WFPROJ")" = "wf 5/12" ] && echo 0 || echo 1)"

# Missing journal entirely → nothing (the fail-toward-silence default).
: > "$WFDIR/journal.jsonl"   # empty: zero started → no ratio
check "empty journal (0 started) → no wf segment" \
  "$([ -z "$(render "$WFSESS" "$WFPROJ")" ] && echo 0 || echo 1)"
rm -rf "$HOME/.claude/projects/wftestproj"

########################################################################
echo "-- Case: ops-claims verifies diff-matches-claims (C1/C2/C3) + expect-clean [F-A3/F-A2/F-A1]"
# ops-claims reads git state; each sub-case mutates the tree and reads exit code + stdout. Every sub-case is
# revert-discriminating: removing the check it names flips the asserted exit code.
P="$(newproj)"
( cd "$P" && git init -q && git config user.email t@t && git config user.name t )
printf 'a\n' > "$P/a.txt"; printf 'b\n' > "$P/b.txt"
mkdir "$P/tests"; printf 'x\n' > "$P/tests/t.sh"
( cd "$P" && git add -A && git commit -qm base )
# The base sha is the dispatch anchor: --since is mandatory (CR2), captured once here.
BASE_SHA="$(cd "$P" && git rev-parse HEAD)"
runclaims() { ( cd "$P" && bash "$CLAIMS" "$@" ); }   # → exit code, stdout on fd1
# clean_tree: reset --hard + clean (git checkout . alone misses staged changes). State leaks between sub-cases
# are a real bug class — a case that passes against leftover state proves nothing.
clean_tree() {
  ( cd "$P" && git reset -q --hard HEAD >/dev/null 2>&1 && git clean -qfd )
  SINCE_SHA="$(cd "$P" && git rev-parse HEAD)"
}

# C1 green: claim exactly the one touched path.
printf 'a2\n' > "$P/a.txt"
runclaims --since "$BASE_SHA" --claimed "a.txt" >/dev/null 2>&1; C1G=$?
check "C1 green: claim matches the single touched path" "$([ "$C1G" = 0 ] && echo 0 || echo 1)"

# C1 fail: an unclaimed touched path. Capture the naming before reverting — the line exists only while dirty.
printf 'b2\n' > "$P/b.txt"
C1OUT="$(runclaims --since "$BASE_SHA" --claimed "a.txt" 2>/dev/null)"; C1F=$?
clean_tree
check "C1 fail: touched-but-unclaimed path → non-zero" "$([ "$C1F" != 0 ] && echo 0 || echo 1)"
check "C1 fail names 'unclaimed-change'" "$(printf '%s' "$C1OUT" | grep -q unclaimed-change && echo 0 || echo 1)"

# C2 fail: a claimed path with no actual change (phantom-claim).
C2OUT="$(runclaims --since "$BASE_SHA" --claimed "a.txt c.txt" 2>/dev/null)"; C2F=$?
check "C2 fail: claimed-but-untouched path → non-zero" "$([ "$C2F" != 0 ] && echo 0 || echo 1)"
check "C2 fail names 'phantom-claim'" "$(printf '%s' "$C2OUT" | grep -q phantom-claim && echo 0 || echo 1)"

# C2 green with a directory-prefix claim; tests/ is PROTECTED, so this needs --gate-task or C3 rightly fails it.
printf 'y\n' >> "$P/tests/t.sh"
runclaims --since "$BASE_SHA" --claimed "tests/" --gate-task >/dev/null 2>&1; C2D=$?
check "C2 green: dir-prefix claim 'tests/' satisfied by tests/t.sh" "$([ "$C2D" = 0 ] && echo 0 || echo 1)"

# C3 fail: a touched protected path (tests/) without --gate-task.
C3OUT="$(runclaims --since "$BASE_SHA" --claimed "tests/" 2>/dev/null)"; C3F=$?
check "C3 fail: protected path touched without --gate-task → non-zero" "$([ "$C3F" != 0 ] && echo 0 || echo 1)"
check "C3 fail names 'gate-trespass'" "$(printf '%s' "$C3OUT" | grep -q gate-trespass && echo 0 || echo 1)"

# C3 pass: same tree, --gate-task authorizes the gate edit.
runclaims --since "$BASE_SHA" --claimed "tests/" --gate-task >/dev/null 2>&1; C3P=$?
check "C3 pass: protected path allowed with --gate-task" "$([ "$C3P" = 0 ] && echo 0 || echo 1)"
clean_tree

# B7.1 — backlog/ is PROTECTED (B7): a worker editing backlog/tasks/*.md can edit the criteria it's judged
# against (F48 vacuous-guard class relocated to the plan layer). The claim does not authorize the trespass.
mkdir -p "$P/backlog/tasks"; printf 'x\n' > "$P/backlog/tasks/x.md"
B7OUT="$(runclaims --since "$BASE_SHA" --claimed "backlog/tasks/x.md" 2>/dev/null)"; B7RC=$?
clean_tree
check "B7.1 backlog/tasks/*.md touched without --gate-task → non-zero" "$([ "$B7RC" != 0 ] && echo 0 || echo 1)"
check "B7.1 names 'gate-trespass'" "$(printf '%s' "$B7OUT" | grep -q gate-trespass && echo 0 || echo 1)"
# B7.1b: a notes file under backlog/ is equally off-limits (Q4 — whole dir).
mkdir -p "$P/backlog"; printf 'n\n' > "$P/backlog/notes.md"
runclaims --since "$BASE_SHA" --claimed "backlog/notes.md" >/dev/null 2>&1; B7BRC=$?
clean_tree
check "B7.1b backlog/notes.md (not a task) is equally protected (whole dir, Q4)" "$([ "$B7BRC" != 0 ] && echo 0 || echo 1)"
# B7.1c: --gate-task authorizes the backlog edit (the task IS the gate).
mkdir -p "$P/backlog/tasks"; printf 'y\n' > "$P/backlog/tasks/y.md"
runclaims --since "$BASE_SHA" --claimed "backlog/tasks/y.md" --gate-task >/dev/null 2>&1; B7CRC=$?
clean_tree
check "B7.1c backlog/ edit allowed with --gate-task" "$([ "$B7CRC" = 0 ] && echo 0 || echo 1)"

# B10.1 — ops-backlog.sh --census: file/code/code-loc counts, exit 0. The <1s-on-10K bound is verified out-of-suite.
B10P="$(newproj)"
( cd "$B10P" && git init -q && git config user.email t@t && git config user.name t )
# 2 code files (1 with a blank line), 1 doc file, 1 code-ext-less file.
printf 'a = 1\n\nb = 2\n' > "$B10P/x.py"
printf 'echo hi\n' > "$B10P/y.sh"
printf '# readme\n' > "$B10P/README.md"
printf 'data\n' > "$B10P/notes"
( cd "$B10P" && git add -A && git commit -qm base >/dev/null 2>&1 )
B10OUT="$(cd "$B10P" && bash "$SCRIPTS/ops-backlog.sh" --census 2>/dev/null)"; B10RC=$?
check "B10.1 --census exits 0" "$([ "$B10RC" = 0 ] && echo 0 || echo 1)"
# 4 tracked files; 2 code files; 3 non-blank code lines (x.py has 2, y.sh has 1).
check "B10.1 --census counts files=4" "$(printf '%s' "$B10OUT" | grep -q '^files: 4$' && echo 0 || echo 1)"
check "B10.1 --census counts code-files=2" "$(printf '%s' "$B10OUT" | grep -q '^code-files: 2$' && echo 0 || echo 1)"
check "B10.1 --census counts code-loc=3 (non-blank lines only)" "$(printf '%s' "$B10OUT" | grep -q '^code-loc: 3$' && echo 0 || echo 1)"
# --census needs a git repo: refuse cleanly, not a raw git error.
B10NG="$(mktemp -d "${TMPDIR:-/tmp}/opstest.XXXXXX")"
(cd "$B10NG" && bash "$SCRIPTS/ops-backlog.sh" --census 2>/dev/null); B10NGRC=$?
check "B10.1 --census on a non-git dir → non-zero" "$([ "$B10NGRC" != 0 ] && echo 0 || echo 1)"

# B10.1f (F7) — a corrupted git index must make --census REFUSE, not print a confident 'files: 0'. `set -eu`
# without pipefail masked ls-files' fatal via the trailing tr/wc pipeline into a silent 0.
B10FI="$(newproj)"
( cd "$B10FI" && git init -q && git config user.email t@t && git config user.name t )
printf 'a = 1\n' > "$B10FI/x.py"
( cd "$B10FI" && git add -A && git commit -qm base >/dev/null 2>&1 )
# corrupt the index: git rev-parse still passes, git ls-files fatals (rc 128)
printf 'garbage-not-an-index' > "$B10FI/.git/index"
( cd "$B10FI" && bash "$SCRIPTS/ops-backlog.sh" --census 2>/dev/null ); B10FIRC=$?
check "B10.1f (F7) --census on a corrupted index → non-zero (not 'files: 0')" \
  "$([ "$B10FIRC" != 0 ] && echo 0 || echo 1)"
# restore a real index so the temp repo is not left in a broken state
( cd "$B10FI" && git read-tree HEAD 2>/dev/null ) || true

# B10.2 — a filename with a SPACE must not vanish: bare xargs word-splits, dropping the file silently under
# 2>/dev/null (measured code-loc 1 on a 2-file/3-line repo). Every stage is NUL-delimited now.
B10SP="$(newproj)"
( cd "$B10SP" && git init -q -b work && git config user.email t@t && git config user.name t )
printf 'a = 1\nb = 2\n' > "$B10SP/my file.py"     # 2 non-blank lines, spaced name
printf 'c = 3\n'        > "$B10SP/plain.py"       # 1 non-blank line
( cd "$B10SP" && git add -A && git commit -qm base >/dev/null 2>&1 )
B10SPOUT="$(cd "$B10SP" && bash "$SCRIPTS/ops-backlog.sh" --census 2>/dev/null)"
check "B10.2 --census counts a file whose name contains a space (code-loc: 3)" \
  "$(printf '%s' "$B10SPOUT" | grep -q '^code-loc: 3$' && echo 0 || echo 1)"

# B10.4 — a tracked filename with a NEWLINE must not be miscounted (#29): BSD grep -zE doesn't anchor $ at the
# NUL, so a name whose FIRST line matched miscounted (measured BSD 2.6.0 vs GNU 3.11 — needs macOS to catch).
# Filtered with `git ls-files -- <pathspec>` instead, which removes the record-splitting question entirely.
B10NL="$(newproj)"
( cd "$B10NL" && git init -q -b work && git config user.email t@t && git config user.name t )
printf 'a = 1\nb = 2\n' > "$B10NL/real.py"                     # 2 non-blank lines
printf 'q\n'            > "$B10NL/plain.md"                    # doc, not counted
printf 'x\ny\nz\n'      > "$B10NL/$(printf 'evil.py\nactually.md')"  # doc, newline in NAME
( cd "$B10NL" && git add -A && git commit -qm base >/dev/null 2>&1 )
B10NLOUT="$(cd "$B10NL" && bash "$SCRIPTS/ops-backlog.sh" --census 2>/dev/null)"
check "B10.4 --census does not count a .md whose name contains a newline as code (code-files: 1)" \
  "$(printf '%s' "$B10NLOUT" | grep -q '^code-files: 1$' && echo 0 || echo 1)"
check "B10.4 --census code-loc ignores the newline-named .md (code-loc: 2)" \
  "$(printf '%s' "$B10NLOUT" | grep -q '^code-loc: 2$' && echo 0 || echo 1)"

# B10.3 — an unreadable code file must be REPORTED, never silently undercounted (chmod isn't portable everywhere,
# so simulated by deleting the tracked file).
rm -f "$B10SP/plain.py"
B10PART="$(cd "$B10SP" && bash "$SCRIPTS/ops-backlog.sh" --census 2>/dev/null)"
check "B10.3 --census marks an incomplete read PARTIAL rather than printing a confident count" \
  "$(printf '%s' "$B10PART" | grep -q '^code-loc: .*PARTIAL' && echo 0 || echo 1)"

# CHANGED: none — clean working tree, no claims, no trespass.
runclaims --since "$BASE_SHA" --claimed none >/dev/null 2>&1; CNG=$?
check "CHANGED none: clean tree, no claims → exit 0" "$([ "$CNG" = 0 ] && echo 0 || echo 1)"

# T3: --expect-clean + --claimed combined, the real dispatch shape. A PHANTOM claim must still fire C2 even on a
# clean tree (a reviewer once mutated the fall-through exit 0 and the suite stayed green).
runclaims --since "$BASE_SHA" --expect-clean --claimed "nonexistent.txt" >/dev/null 2>&1; ECPC=$?
check "--expect-clean + --claimed: phantom claim still fires C2 on a clean tree" \
  "$([ "$ECPC" != 0 ] && echo 0 || echo 1)"

# --expect-clean green: tree empty apart from .operator/ (none here).
runclaims --expect-clean >/dev/null 2>&1; ECG=$?
check "--expect-clean green on a clean tree" "$([ "$ECG" = 0 ] && echo 0 || echo 1)"

# --expect-clean fail: a stray file beyond .operator/.
printf 'z\n' > "$P/stray.txt"
runclaims --expect-clean >/dev/null 2>&1; ECF=$?
check "--expect-clean fail on a stray non-ledger file" "$([ "$ECF" != 0 ] && echo 0 || echo 1)"
clean_tree

# --expect-clean REPORTS ignored state (#23 scope line) since the tracked-tree check can't see gitignored
# artifacts (the exact mechanism a stale __pycache__ uses to verify green in-tree, fail in a clean checkout).
runclaims --expect-clean 2>/dev/null | grep -q '{item ignored-state} report: 0 ' && ECI0=0 || ECI0=1
check "--expect-clean reports 0 ignored entries on a tree with none" "$ECI0"
printf '__pycache__/\n' > "$P/.gitignore"
( cd "$P" && git add .gitignore && git commit -qm ignore )
mkdir -p "$P/__pycache__"; printf 'stale\n' > "$P/__pycache__/a.cpython-311.pyc"
runclaims --expect-clean 2>/dev/null | grep -q '{item ignored-state} report: 1 ' && ECI1=0 || ECI1=1
check "--expect-clean counts a gitignored __pycache__ the tracked check cannot see" "$ECI1"
# THREE, NOT ONE: a 0-vs-1 pair is satisfied by a counter stuck at 1 — `-z` output through command substitution
# loses NUL separators, so `grep -c '^!!'` answers 1 for any non-zero count (measured: 3-entry tree reported 1).
printf '__pycache__/\nbuild/\ndist/\n' > "$P/.gitignore"
( cd "$P" && git add .gitignore && git commit -qm ignore3 )
mkdir -p "$P/build" "$P/dist"; : > "$P/build/x"; : > "$P/dist/x"
runclaims --expect-clean 2>/dev/null | grep -q '{item ignored-state} report: 3 ' && ECI3=0 || ECI3=1
check "--expect-clean counts THREE ignored entries as 3 (not a stuck 1)" "$ECI3"
runclaims --expect-clean >/dev/null 2>&1; ECI2=$?
check "--expect-clean stays green on ignored state (report, never fail)" \
  "$([ "$ECI2" = 0 ] && echo 0 || echo 1)"
# A FAILED GIT READ MUST READ `unknown`, NOT `0`: `grep -c` on empty input prints 0 and exits 1, so a git that
# died at 128 used to be indistinguishable from a clean tree. Exit status now captured before any counting.
ECIUERR="$( cd "$P" && GIT_INDEX_FILE=/dev/null/nope bash "$CLAIMS" --expect-clean 2>&1 )"; ECIURC=$?
check "a failed git status REFUSES --expect-clean rather than reporting clean" \
  "$(printf '%s' "$ECIUERR" | grep -q 'must not read as a clean tree' && echo 0 || echo 1)"
check "the refusal exits non-zero (the gate must not pass on an unreadable tree)" \
  "$([ "$ECIURC" != 0 ] && echo 0 || echo 1)"
# And it must not have claimed the tree was clean on the way out — pinning a green verdict, not just a missing error.
check "the refusal prints no 'ok: clean' verdict" \
  "$(printf '%s' "$ECIUERR" | grep -q '{item working-tree} ok' && echo 1 || echo 0)"
clean_tree

# --expect-clean exempts .operator/ ledger paths — a verdict is a normal side-effect of a dispatch.
( cd "$P" && bash "$INIT" >/dev/null 2>&1 )
printf 'row\n' >> "$P/.operator/VERDICTS.md"
runclaims --expect-clean >/dev/null 2>&1; ECL=$?
check "--expect-clean exempts .operator/ ledger paths" "$([ "$ECL" = 0 ] && echo 0 || echo 1)"

# Untracked detection: an untracked file is an actual change caught by C1.
clean_tree
printf 'u\n' > "$P/untracked.txt"
runclaims --since "$BASE_SHA" --claimed "a.txt" >/dev/null 2>&1; UNC=$?
check "untracked file detected as an actual change (C1)" "$([ "$UNC" != 0 ] && echo 0 || echo 1)"

# Charset/traversal discipline on --claimed: '..' traversal is rejected.
runclaims --since "$BASE_SHA" --claimed "../etc" >/dev/null 2>&1; TRV=$?
check "claimed '..' traversal is rejected" "$([ "$TRV" != 0 ] && echo 0 || echo 1)"
# '|' in a claimed path is rejected (would break the list contract).
runclaims --since "$BASE_SHA" --claimed "a.txt|injected" >/dev/null 2>&1; PIP=$?
check "claimed '|' is rejected" "$([ "$PIP" != 0 ] && echo 0 || echo 1)"
# A DOT-DIRECTORY PATH IS CLAIMABLE (#37): the old blanket `.*` reject was a task-id rule wrongly applied to
# paths, so a worker touching a dotfile had no green path.
clean_tree
mkdir -p "$P/.github/workflows"; printf 'name: v\n' > "$P/.github/workflows/w.yml"
( cd "$P" && git add -A && git commit -qm dotdir )
DOTSHA="$(cd "$P" && git rev-parse HEAD)"
printf 'name: v2\n' > "$P/.github/workflows/w.yml"
runclaims --since "$DOTSHA" --claimed ".github/workflows/w.yml" >/dev/null 2>&1; DOTC=$?
check "#37 a claimed dot-directory path is accepted (.github/…)" \
  "$([ "$DOTC" = 0 ] && echo 0 || echo 1)"
# Negative control: not claiming it must still fire C1, or the case above passes against a gate that stopped checking.
runclaims --since "$DOTSHA" --claimed "none" >/dev/null 2>&1; DOTN=$?
check "#37 the same path unclaimed still fires C1" \
  "$([ "$DOTN" != 0 ] && echo 0 || echo 1)"
# And the rule that survives: the ledger, an expected side-effect of every dispatch, stays a refusal to claim as your own.
DOTLED="$(runclaims --since "$DOTSHA" --claimed ".operator/VERDICTS.md" 2>&1)"; DOTL=$?
check "#37 a claimed .operator/ path is still refused" \
  "$([ "$DOTL" != 0 ] && echo 0 || echo 1)"
check "#37 the refusal names the ledger, not a dot" \
  "$(printf '%s' "$DOTLED" | grep -q 'under .operator/' && echo 0 || echo 1)"
clean_tree

# CR2: --since is MANDATORY — a HEAD default made a committed gate-trespass invisible.
runclaims --claimed none >/dev/null 2>&1; NOSINCE=$?
check "--since is mandatory (absent → die, no HEAD default)" "$([ "$NOSINCE" != 0 ] && echo 0 || echo 1)"
# And the reason it's mandatory: a worker that COMMITS its change must not evade the diff.
clean_tree
printf 'a2\n' > "$P/a.txt"
( cd "$P" && git add -A && git commit -qm second )
runclaims --since "$BASE_SHA" --claimed none >/dev/null 2>&1; COMMIT=$?
check "a COMMITTED change since base is caught (--since <base>, not HEAD)" "$([ "$COMMIT" != 0 ] && echo 0 || echo 1)"
clean_tree

# --- adversarial cases (REFUTED review 2026-08-04): the F-A2 attack surface ---
# Each reproduces a must-resolve finding — every one is the exact shape that evaded the first version.
clean_tree

# C3 must fire on a DELETED gate CLI: the first version's `for pat in $PROTECTED` pathname-expanded, matching nothing.
mkdir -p "$P/scripts"
printf 'stub\n' > "$P/scripts/ops-verdict.sh"
( cd "$P" && git add -A && git commit -qm gatefiles >/dev/null 2>&1 )
# Working-tree deletion: git diff HEAD and porcelain both report deleted/removed — the pattern must catch it.
rm -f "$P/scripts/ops-verdict.sh"
DELVIEW="$(cd "$P" && git status --porcelain --untracked-files=all scripts/ops-verdict.sh)"
DELOUT="$(runclaims --since "$BASE_SHA" --claimed 'scripts/ops-verdict.sh' 2>/dev/null)"; DEL=$?
check "F-A2 setup: the deleted gate CLI is in git's view" \
  "$([ -n "$DELVIEW" ] && echo 0 || echo 1)"
check "C3 fires on a DELETED gate CLI (F-A2 attack; pathname-expansion fix)" \
  "$([ "$DEL" != 0 ] && echo 0 || echo 1)"
check "deletion names 'gate-trespass'" \
  "$(printf '%s' "$DELOUT" | grep -q gate-trespass && echo 0 || echo 1)"
clean_tree

# Combined status codes must not glue the XY chars to the path (REFUTED #2): an earlier allowlist missed
# AM/AD/MD/RD/T/etc., defeating C1/C3 and the ledger exemption.
printf 'a\n' > "$P/feature.txt"; ( cd "$P" && git add feature.txt >/dev/null 2>&1 )
printf 'b\n' >> "$P/feature.txt"
AMOUT="$(runclaims --since "$SINCE_SHA" --claimed 'feature.txt' 2>/dev/null)"; AM=$?
check "AM (added+modified) claimed → green, not a glued 'AM feature.txt' item" \
  "$([ "$AM" = 0 ] && printf '%s' "$AMOUT" | grep -qv '{item AM' && echo 0 || echo 1)"
clean_tree

# AD: staged-add then working-DELETE of a gate CLI, the C3-evasion repro — index-only, porcelain is the only source.
printf 'evil\n' > "$P/scripts/ops-verdict.sh"
( cd "$P" && git add scripts/ops-verdict.sh >/dev/null 2>&1 )
rm -f "$P/scripts/ops-verdict.sh"
ADOUT="$(runclaims --since "$SINCE_SHA" --claimed 'scripts/ops-verdict.sh' 2>/dev/null)"; AD=$?
check "AD (added+deleted gate CLI) fires C3 gate-trespass" \
  "$([ "$AD" != 0 ] && printf '%s' "$ADOUT" | grep -q gate-trespass && echo 0 || echo 1)"
clean_tree

# A STAGED ledger write must stay exempt — the glued-prefix bug made 'AM .operator/...' fail the exemption.
( cd "$P" && bash "$INIT" >/dev/null 2>&1 )
printf 'row\n' >> "$P/.operator/DECISIONS.md"; ( cd "$P" && git add .operator/DECISIONS.md >/dev/null 2>&1 )
printf 'more\n' >> "$P/.operator/DECISIONS.md"
runclaims --expect-clean >/dev/null 2>&1; STEC=$?
check "staged ledger write stays exempt from --expect-clean (no glued AM)" \
  "$([ "$STEC" = 0 ] && echo 0 || echo 1)"
clean_tree

# A path WITH A SPACE is one item, not shredded — the first version word-split it into two.
printf 'x\n' > "$P/my file.txt"
SCOUT="$(runclaims --since "$SINCE_SHA" --claimed none 2>/dev/null)"
check "path with a space is one unclaimed-change item (not shredded)" \
  "$(printf '%s' "$SCOUT" | grep -q '{item my file.txt}' && echo 0 || echo 1)"
clean_tree

# A bad --since ref is rejected, not silently degraded to "no changes" (would false-green a committed trespass).
printf 'a2\n' > "$P/a.txt"
runclaims --claimed none --since not-a-real-ref-xyz >/dev/null 2>&1; BADS=$?
check "invalid --since ref is rejected (no silent false-green)" "$([ "$BADS" != 0 ] && echo 0 || echo 1)"
clean_tree

# A renamed file: git mv yields 'R old -> new', which the first version parsed into a garbage '->' item.
mkdir -p "$P/hooks"; printf 'orig\n' > "$P/hooks/h.sh"
( cd "$P" && git add -A && git commit -qm hookbase >/dev/null 2>&1 )
( cd "$P" && git mv hooks/h.sh hooks/renamed.sh >/dev/null 2>&1 )
MVVIEW="$(cd "$P" && git status --porcelain --untracked-files=all hooks/)"
MVOUT="$(runclaims --since "$SINCE_SHA" --claimed 'hooks/' --gate-task 2>/dev/null)"; MV=$?
check "F-A2 rename setup: the rename is in git's view" \
  "$([ -n "$MVVIEW" ] && echo 0 || echo 1)"
check "rename: hooks/ claimed + --gate-task → green (both paths recognized)" "$([ "$MV" = 0 ] && echo 0 || echo 1)"
check "rename does not emit a garbage '->' item" \
  "$(printf '%s' "$MVOUT" | grep -qv '{item ->}' && echo 0 || echo 1)"
clean_tree

# Untracked file inside an UNTRACKED directory: --untracked-files=all must see the file, not just the dir.
mkdir -p "$P/docs/new"; printf 'm\n' > "$P/docs/new/a.md"
runclaims --since "$SINCE_SHA" --claimed "docs/new/a.md" >/dev/null 2>&1; UTD=$?
check "untracked file in untracked dir is matched (--untracked-files=all)" "$([ "$UTD" = 0 ] && echo 0 || echo 1)"
clean_tree

# Leading-dot claimed path is rejected (the first version's comment promised it, the code did not — REFUTED).
runclaims --since "$SINCE_SHA" --claimed ".hidden" >/dev/null 2>&1; DOT=$?
check "leading-dot claimed path rejected (doc/code divergence fix)" "$([ "$DOT" != 0 ] && echo 0 || echo 1)"

# Green run emits the SSSF 'what was verified' evidence line.
GE="$(runclaims --since "$SINCE_SHA" --claimed none 2>/dev/null)"
check "green run emits a diff-matches-claims ok line" "$(printf '%s' "$GE" | grep -q 'diff-matches-claims} ok' && echo 0 || echo 1)"

# ops-claims does NOT read pending/ — confirm no sentinel-reader code path by checking it ignores a planted sentinel.
mkdir -p "$P/.operator/pending"; printf 'session_id: OTHER\n' > "$P/.operator/pending/planted"
runclaims --since "$SINCE_SHA" --claimed none >/dev/null 2>&1; NPD=$?
check "ops-claims ignores .operator/pending (not a sentinel reader)" "$([ "$NPD" = 0 ] && echo 0 || echo 1)"

# The green line's COUNT must count what C1 adjudicated, not what C1 exempted (issue #63): the bug reported
# '7 changed path(s)' for one claimed path, growing with every verdicts.d/ fragment.
clean_tree
mkdir -p "$P/.operator/verdicts.d"
printf '| x | c | e | PASS |\n' > "$P/.operator/VERDICTS.md"
printf '| x | c | e | PASS |\n' > "$P/.operator/verdicts.d/S1.md"
printf '| y | c | e | PASS |\n' > "$P/.operator/verdicts.d/S2.md"
printf 'w\n' > "$P/worker.txt"
CNTOUT="$(runclaims --since "$SINCE_SHA" --claimed "worker.txt" 2>/dev/null)"; CNTRC=$?
check "green count excludes exempted ledger paths (#63)" "$([ "$CNTRC" = 0 ] && printf '%s' "$CNTOUT" | grep -q 'ok: 1 changed path(s) all claimed' && echo 0 || echo 1)"
check "the exempted ledger paths are reported, not dropped (#63)" "$(printf '%s' "$CNTOUT" | grep -q '3 .operator/ ledger path(s) exempt' && echo 0 || echo 1)"
# NEGATIVE CONTROL: the count must not become a mute button — no dirty ledger path means no parenthetical at all.
clean_tree
printf 'w2\n' > "$P/worker.txt"
NOLED="$(runclaims --since "$SINCE_SHA" --claimed "worker.txt" 2>/dev/null)"
check "no ledger change → no exempt note at all (not '0 exempt')" "$(printf '%s' "$NOLED" | grep -q 'all claimed; no phantom claims$' && echo 0 || echo 1)"
# ...and the GATE itself is untouched: an unclaimed real path still fails while ledger paths stay exempt.
printf 'u\n' > "$P/unclaimed.txt"
printf '| z | c | e | PASS |\n' > "$P/.operator/verdicts.d/S3.md"
runclaims --since "$SINCE_SHA" --claimed "worker.txt" >/dev/null 2>&1; GRC=$?
check "counting change does not weaken C1 (unclaimed path still fails)" "$([ "$GRC" != 0 ] && echo 0 || echo 1)"
clean_tree
rm -rf "$P"

########################################################################
echo "-- Case: deviation-gate — unpresented decisions block Stop; --mark-handoff clears [stage 2]"
# The Stop hook's SECOND ledger: DECISIONS.md DEVIATION lines after the last mine/unowned HANDOFF-MARK block Stop.
# Every sub-case is revert-discriminating: removing the branch from scan_deviations flips the exit code.
P="$(newproj)"
( cd "$P" && bash "$INIT" >/dev/null 2>&1 )
DEC="$P/.operator/DECISIONS.md"
SID="SESS-A-XYZ"
# A minimal Stop payload with session_id + cwd; the hook walks up to the nearest .operator/.
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

# A malformed line (CRLF on the kind) breaks the kind parse, so the line isn't recognized as DEVIATION — but a
# degenerate line must fail toward blocking, not allowing.
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
# Requires --owner (an empty sid would clear every session = privilege inversion).
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
# A foreign owner cannot write a mark that clears MY deviations (verified by the partition above).

# --- T2: an UNOWNED HANDOFF-MARK clears every session (the third partition arm) ---
# A reviewer mutated this branch to a no-op and the suite stayed green — it is now asserted.
printf '2026-08-04 | e.t | DEVIATION | [sid:%s] mine | r\n' "$SID" > "$DEC"
printf '2026-08-04 | e | HANDOFF-MARK | 2026-08-04T00:00:00Z | presented (no sid)\n' >> "$DEC"
payload | bash "$HOOK" >/dev/null 2>&1; UM=$?
check "an untagged HANDOFF-MARK clears every session (third partition arm)" "$([ "$UM" = 0 ] && echo 0 || echo 1)"
# And a DIFFERENT session is also cleared by the untagged mark.
printf '{"session_id":"OTHER-SESS","stop_hook_active":false,"cwd":"%s"}' "$P" | bash "$HOOK" >/dev/null 2>&1; UM2=$?
check "untagged mark clears a DIFFERENT session too (unowned = clears all)" "$([ "$UM2" = 0 ] && echo 0 || echo 1)"

# --- T1: a SYMLINKED DECISIONS.md is not scanned (F65 class, both readers) ---
# A planted symlink to a forged DEVIATION must not feed the scan; the hook fails open, the bar renders nothing.
ATT="$(newproj)"; printf 'forged\n2026-08-04 | e.t | DEVIATION | [sid:%s] forged | r\n' "$SID" > "$ATT/forged-decisions"
ln -s "$ATT/forged-decisions" "$DEC"
payload | bash "$HOOK" >/dev/null 2>&1; SYM=$?
check "hook fails OPEN on a symlinked DECISIONS.md (not scanned)" "$([ "$SYM" = 0 ] && echo 0 || echo 1)"
# The statusline mirror: a symlinked ledger renders no dev[N] segment.
SYMSEG="$(printf '{"session_id":"%s","cwd":"%s","workspace":{"project_dir":"%s"}}' "$SID" "$P" "$P" \
  | "$BASH_ABS" "$SCRIPTS/statusline.sh" 2>/dev/null | LC_ALL=C tr -d '\033' | LC_ALL=C sed 's/\[[0-9]*m//g')"
check "statusline renders no dev[ on a symlinked DECISIONS.md" \
  "$(printf '%s' "$SYMSEG" | grep -q 'dev\[' || echo 0)"
rm -f "$DEC" "$ATT"; rmdir "$ATT" 2>/dev/null || true

# --- issue #9: a ledger row LONGER than the 512-byte read cap (continuation) ---
# DECISIONS.md is append-forever with multi-KB rows expected; `read -n 512` fills on such a row. The old
# per-chunk guard hardcoded the count to 1 and returned, phantom-blocking a clean ledger and blinding the gate
# to a real deviation after the long row, with --mark-handoff unreachable past it too.
LONG="$(python3 -c 'print("x"*1200)')"
# ARM A — a long DEFERRED-VERDICT (record kind, not gated) and no gated deviation. Pre-fix: phantom block.
{ printf '# Decisions\n'
  printf '2026-08-05 | e.t | DEFERRED-VERDICT | %s | r\n' "$LONG"; } > "$DEC"
payload | bash "$HOOK" >/dev/null 2>&1; LR0=$?
check "long record row, no gated deviation → Stop allowed (no phantom block, #9)" \
  "$([ "$LR0" = 0 ] && echo 0 || echo 1)"
# ARM B — a long record row, then a genuine mine DEVIATION after it. Pre-fix counted it only by accident of the hardcoded 1.
{ printf '# Decisions\n'
  printf '2026-08-05 | e.t | DEFERRED-VERDICT | %s | r\n' "$LONG"
  printf '2026-08-05 | e.t | DEVIATION | [sid:%s] real unpresented | r\n' "$SID"; } > "$DEC"
payload | bash "$HOOK" >/dev/null 2>&1; LR1=$?
check "long record row then mine DEVIATION after it → DEVIATION counted (#9)" \
  "$([ "$LR1" = 2 ] && echo 0 || echo 1)"
# ARM C — a long record row, then a mine DEVIATION, then a mine HANDOFF-MARK past it. Pre-fix the mark was unreachable.
{ printf '# Decisions\n'
  printf '2026-08-05 | e.t | DEFERRED-VERDICT | %s | r\n' "$LONG"
  printf '2026-08-05 | e.t | DEVIATION | [sid:%s] chose X | r\n' "$SID"
  printf '2026-08-05 | e | HANDOFF-MARK | [sid:%s] 2026-08-05T00:00:00Z | presented\n' "$SID"; } > "$DEC"
payload | bash "$HOOK" >/dev/null 2>&1; LR2=$?
check "mine DEVIATION + mine mark, both past a long row → mark clears (#9)" \
  "$([ "$LR2" = 0 ] && echo 0 || echo 1)"
# ARM D — the DEVIATION ITSELF is the long row (>512 bytes). Pre-fix the kind parse ran on only the first chunk.
{ printf '# Decisions\n'
  printf '2026-08-05 | e.t | DEVIATION | [sid:%s] %s | r\n' "$SID" "$LONG"; } > "$DEC"
payload | bash "$HOOK" >/dev/null 2>&1; LR3=$?
check "a DEVIATION whose what-cell exceeds 512 bytes still blocks (#9)" \
  "$([ "$LR3" = 2 ] && echo 0 || echo 1)"
# ARM E — foreign DEVIATION in a long row never blocks (continuation can't smuggle the foreign tag countable).
{ printf '# Decisions\n'
  printf '2026-08-05 | e.t | DEVIATION | [sid:SESS-B-OTHER] %s | r\n' "$LONG"; } > "$DEC"
payload | bash "$HOOK" >/dev/null 2>&1; LR4=$?
check "long foreign DEVIATION → never blocks (#9)" \
  "$([ "$LR4" = 0 ] && echo 0 || echo 1)"
# Continuation cannot forge a kind: a chunk boundary landing mid-token must not synthesize DEVIATION.
{ printf '# Decisions\n'
  printf '2026-08-05 | e.t | DEVIATION | [sid:%s] chose X | r\n' "$SID"
  printf '2026-08-05 | e.t | DEFERRED-VERDICT | %s | r\n' "$LONG"
  printf '2026-08-05 | e | HANDOFF-MARK | [sid:%s] 2026-08-05T00:00:00Z | presented\n' "$SID"; } > "$DEC"
payload | bash "$HOOK" >/dev/null 2>&1; LR5=$?
check "kind not forgeable across a continuation boundary (#9)" \
  "$([ "$LR5" = 0 ] && echo 0 || echo 1)"

# --- the bar mirror of #9: a long mine DEVIATION is counted, not skipped ---
# Pre-fix the statusline's array read split a long row across entries, and the continuation chunks were skipped.
DEVDEC2="$DEVPROJ/.operator/DECISIONS.md"
{ printf '# Decisions\n'
  printf '2026-08-05 | e.t | DEVIATION | [sid:SESS-A] %s | r\n' "$LONG"; } > "$DEVDEC2"
LRBAR="$(printf '{"session_id":"SESS-A","cwd":"%s","workspace":{"project_dir":"%s"}}' "$DEVPROJ" "$DEVPROJ" \
  | "$BASH_ABS" "$SCRIPTS/statusline.sh" 2>/dev/null | LC_ALL=C tr -d '\033' | LC_ALL=C sed 's/\[[0-9]*m//g')"
check "statusline counts a long (>512B) mine DEVIATION as dev[1] (#9)" \
  "$(printf '%s' "$LRBAR" | grep -q 'dev\[1\]' && echo 0 || echo 1)"
# A long row with NO trailing newline: `read` returns non-zero on EOF but still holds the final chunk, which the
# bar used to drop without `|| [ -n "$line" ]` (Copilot review on #10).
printf '# Decisions\n2026-08-05 | e.t | DEVIATION | [sid:SESS-A] %s | r' "$LONG" > "$DEVDEC2"
LRBAR2="$(printf '{"session_id":"SESS-A","cwd":"%s","workspace":{"project_dir":"%s"}}' "$DEVPROJ" "$DEVPROJ" \
  | "$BASH_ABS" "$SCRIPTS/statusline.sh" 2>/dev/null | LC_ALL=C tr -d '\033' | LC_ALL=C sed 's/\[[0-9]*m//g')"
check "statusline counts a long mine DEVIATION with no trailing newline (#10 review)" \
  "$(printf '%s' "$LRBAR2" | grep -q 'dev\[1\]' && echo 0 || echo 1)"

# --- F10: the bar's NUL probe reads the TAIL WINDOW, never the whole ledger ---
# The probe sat before the O(tail) reverse scan and read the whole file, re-introducing the O(n) cost the tail
# scan exists to avoid — measured ~200x the tail's own cost on a 658KB ledger, on a ~300ms timer.
# shellcheck disable=SC2016  # the path is the LITERAL text grepped for in the renderer's source; expanding it
# here would search for this suite's own var.
check "no whole-file read survives in the bar's deviation scan (F10)" \
  "$(grep -q 'done < "$OPDIR/DECISIONS.md"' "$SCRIPTS/statusline.sh" && echo 1 || echo 0)"
# shellcheck disable=SC2016  # same reason as above — literal grep target, not this suite's variable.
check "the bar's NUL probe is fed by tail -n 256, like the scan (F10)" \
  "$([ "$(grep -c 'done < <(tail -n 256 "$OPDIR/DECISIONS.md" 2>/dev/null)' "$SCRIPTS/statusline.sh")" -eq 2 ] && echo 0 || echo 1)"
# SEMANTIC: a NUL inside the tail window still classifies the ledger as corrupt, so no dev[ renders.
F10DEC="$DEVPROJ/.operator/DECISIONS.md"
{ printf '# Decisions\n'
  printf '2026-08-05 | e.t | DEVIATION | [sid:SESS-A] mine | r\n'
  printf '2026-08-05 | e.t | DEVIATION | [sid:SESS-A] nul\000here | r\n'; } > "$F10DEC"
F10NUL="$(printf '{"session_id":"SESS-A","cwd":"%s","workspace":{"project_dir":"%s"}}' "$DEVPROJ" "$DEVPROJ" \
  | "$BASH_ABS" "$SCRIPTS/statusline.sh" 2>/dev/null | LC_ALL=C tr -d '\033' | LC_ALL=C sed 's/\[[0-9]*m//g')"
check "a NUL inside the tail window still renders no dev[ (F10 semantics kept)" \
  "$(printf '%s' "$F10NUL" | grep -q 'dev\[' || echo 0)"
# ...and a LARGE clean ledger still counts exactly the in-window deviations (dev[1], same as pre-fix).
{ printf '# Decisions\n'
  i=0; while [ "$i" -lt 4000 ]; do i=$((i+1))
    printf '2026-08-05 | e.t | NOTE | filler %s | r\n' "$i"
  done
  printf '2026-08-05 | e.t | DEVIATION | [sid:SESS-A] mine-late | r\n'; } > "$F10DEC"
F10BIG="$(printf '{"session_id":"SESS-A","cwd":"%s","workspace":{"project_dir":"%s"}}' "$DEVPROJ" "$DEVPROJ" \
  | "$BASH_ABS" "$SCRIPTS/statusline.sh" 2>/dev/null | LC_ALL=C tr -d '\033' | LC_ALL=C sed 's/\[[0-9]*m//g')"
check "a large clean ledger still counts its in-window deviation as dev[1] (F10)" \
  "$(printf '%s' "$F10BIG" | grep -q 'dev\[1\]' && echo 0 || echo 1)"
rm -f "$F10DEC"

rm -f "$DEC" "$ATT"; rmdir "$ATT" 2>/dev/null || true
# Restore a real (empty) DECISIONS.md for any later use.
printf '# Decisions\n' > "$DEC"

rm -rf "$P"

########################################################################
echo "-- Case: G1 retro-gate — three-state arm check (never-armed → GATE-EXCEPTION)"
# A verdict with no open sentinel is either never-armed (→ GATE-EXCEPTION) or a duplicate/amending row (→ warning).
# A never-armed verdict with no --owner is refused: the exception must carry a [sid:] tag.
P="$(newproj)"; ( cd "$P" && bash "$INIT" >/dev/null 2>&1 )
S="SESS-G1"

# G1.1 — armed verdict: sentinel present, no GATE-EXCEPTION (regression).
( cd "$P" && bash "$TASK" g1t1 --owner "$S" >/dev/null 2>&1 )
DEC_BEFORE="$(wc -c < "$P/.operator/DECISIONS.md" | tr -d ' ')"
( cd "$P" && bash "$VERDICT" g1t1 crit ev PASS --owner "$S" >/dev/null 2>&1 ); G11=$?
check "G1.1 armed verdict exits 0" "$([ "$G11" -eq 0 ] && echo 0 || echo 1)"
check "G1.1 armed verdict writes zero GATE-EXCEPTION lines" \
  "$([ "$(wc -c < "$P/.operator/DECISIONS.md" | tr -d ' ')" = "$DEC_BEFORE" ] && echo 0 || echo 1)"

# G1.2 — never-armed verdict with --owner: row appended, one GATE-EXCEPTION tagged [sid:$S].
DEC_BEFORE="$(grep -c 'GATE-EXCEPTION' "$P/.operator/DECISIONS.md" 2>/dev/null || echo 0)"
( cd "$P" && bash "$VERDICT" na-g12 crit ev PASS --owner "$S" >/dev/null 2>&1 ); G12=$?
check "G1.2 never-armed with --owner exits 0" "$([ "$G12" -eq 0 ] && echo 0 || echo 1)"
DEC_AFTER="$(grep -c 'GATE-EXCEPTION' "$P/.operator/DECISIONS.md" 2>/dev/null || echo 0)"
check "G1.2 writes exactly one GATE-EXCEPTION" \
  "$([ $((DEC_AFTER - DEC_BEFORE)) -eq 1 ] && echo 0 || echo 1)"
check "G1.2 GATE-EXCEPTION what-cell carries [sid:$S]" \
  "$(grep 'GATE-EXCEPTION' "$P/.operator/DECISIONS.md" | tail -1 | grep -q "\[sid:$S\]" && echo 0 || echo 1)"

# G1.3 — repeat the never-armed verdict: duplicate/amending, no second GATE-EXCEPTION.
DEC_BEFORE="$(grep -c 'GATE-EXCEPTION' "$P/.operator/DECISIONS.md" 2>/dev/null || echo 0)"
G13OUT="$( cd "$P" && bash "$VERDICT" na-g12 crit2 ev2 PASS --owner "$S" 2>&1 )"; G13=$?
check "G1.3 duplicate verdict exits 0" "$([ "$G13" -eq 0 ] && echo 0 || echo 1)"
check "G1.3 stderr names duplicate/amending" \
  "$(printf '%s' "$G13OUT" | grep -qi 'duplicate\|amending' && echo 0 || echo 1)"
DEC_AFTER="$(grep -c 'GATE-EXCEPTION' "$P/.operator/DECISIONS.md" 2>/dev/null || echo 0)"
check "G1.3 writes no second GATE-EXCEPTION" \
  "$([ $((DEC_AFTER - DEC_BEFORE)) -eq 0 ] && echo 0 || echo 1)"

# G1.4 — never-armed verdict with no --owner: refused, VERDICTS.md unchanged.
V_BEFORE="$(wc -c < "$P/.operator/VERDICTS.md" | tr -d ' ')"
( cd "$P" && bash "$VERDICT" na-g14 crit ev PASS 2>/dev/null ); G14=$?
check "G1.4 never-armed without --owner exits non-zero" "$([ "$G14" -ne 0 ] && echo 0 || echo 1)"
check "G1.4 VERDICTS.md unchanged (byte-compare)" \
  "$([ "$(wc -c < "$P/.operator/VERDICTS.md" | tr -d ' ')" = "$V_BEFORE" ] && echo 0 || echo 1)"

# G1.5 — armed verdict with no --owner: still exits 0 (sentinel supplies owner).
( cd "$P" && bash "$TASK" g1t5 --owner "$S" >/dev/null 2>&1 )
( cd "$P" && bash "$VERDICT" g1t5 crit ev PASS >/dev/null 2>&1 ); G15=$?
check "G1.5 armed verdict without --owner exits 0" "$([ "$G15" -eq 0 ] && echo 0 || echo 1)"

# G1.6 — a fragment padded past FRAG_MAX_BYTES: the scan is refused, not slurped.
( cd "$P" && bash "$VERDICT" na-g16a crit ev PASS --owner "$S" >/dev/null 2>&1 )
FRAG="$P/.operator/verdicts.d/$S.md"
# Pad the fragment past FRAG_MAX_BYTES (8 MiB) with a single long non-row line.
{ cat "$FRAG"; printf '%s' "$(printf 'x%.0s' $(seq 1 9000000))"; } > "$FRAG.pad" && mv "$FRAG.pad" "$FRAG"
( cd "$P" && bash "$VERDICT" na-g16b crit ev PASS --owner "$S" 2>/dev/null ); G16=$?
check "G1.6 oversized-fragment verdict exits 0 (not wedged)" "$([ "$G16" -eq 0 ] && echo 0 || echo 1)"

# G1.7 — long-evidence duplicate must not be misfiled as never-armed (issue-#9 class): a 700-byte evidence cell
# splits the fragment row across chunks; the chunk carrying `| <id> |` must be matched, not skipped.
P="$(newproj)"; ( cd "$P" && bash "$INIT" >/dev/null 2>&1 )
S7="SESS-G17"
LONGEV="$(printf 'x%.0s' $(seq 1 700))"
( cd "$P" && bash "$TASK" g1t7 --owner "$S7" >/dev/null 2>&1 )
( cd "$P" && bash "$VERDICT" g1t7 crit "$LONGEV" PASS --owner "$S7" >/dev/null 2>&1 )
DEC_BEFORE="$(grep -cE '^[0-9]{4}.*GATE-EXCEPTION' "$P/.operator/DECISIONS.md" || true)"
( cd "$P" && bash "$VERDICT" g1t7 crit2 short PASS --owner "$S7" 2>&1 ) | grep -qi 'duplicate\|amending' && DUP17=0 || DUP17=1
DEC_AFTER="$(grep -cE '^[0-9]{4}.*GATE-EXCEPTION' "$P/.operator/DECISIONS.md" || true)"
check "G1.7 long-evidence duplicate is duplicate, not never-armed (no spurious GATE-EXCEPTION)" \
  "$([ "${DEC_AFTER:-0}" = "${DEC_BEFORE:-0}" ] && [ "$DUP17" -eq 0 ] && echo 0 || echo 1)"

# G1.8 — a never-armed verdict writes EXACTLY ONE GATE-EXCEPTION however many times it's amended, or the gate
# cries wolf and gets waved through (issue #9's failure mode again). The crash-window residual is closed by
# WRITE ORDER (#14/0.8.4): the exception is appended before the row — G1.10 pins the order itself.
P="$(newproj)"; ( cd "$P" && bash "$INIT" >/dev/null 2>&1 )
S8="SESS-G18"
( cd "$P" && bash "$VERDICT" g1t8 crit ev PASS --owner "$S8" >/dev/null 2>&1 )
G18_FIRST="$(grep -cE '^[0-9]{4}.*GATE-EXCEPTION' "$P/.operator/DECISIONS.md" || true)"
( cd "$P" && bash "$VERDICT" g1t8 crit2 ev2 PASS --owner "$S8" >/dev/null 2>&1 )
( cd "$P" && bash "$VERDICT" g1t8 crit3 ev3 PASS --owner "$S8" >/dev/null 2>&1 )
G18_AFTER="$(grep -cE '^[0-9]{4}.*GATE-EXCEPTION' "$P/.operator/DECISIONS.md" || true)"
check "G1.8 never-armed verdict writes exactly one GATE-EXCEPTION across amendments" \
  "$([ "${G18_FIRST:-0}" = "1" ] && [ "${G18_AFTER:-0}" = "1" ] && echo 0 || echo 1)"

# G1.10 (#14/U2) — the GATE-EXCEPTION is written BEFORE the row; this case pins the ORDER, not just presence.
# A crash between the two appends decides which half survives: row-first leaves a row with no exception (the
# retry misreads it as a duplicate, losing the audit line); exception-first leaves an exception with no row
# (harmless duplicate on retry). Both under one lock, so it's a crash window, not a race. Mutation-checked:
# swap the two writes and this case goes red.
P="$(newproj)"; ( cd "$P" && bash "$INIT" >/dev/null 2>&1 )
S10="SESS-G110"
( cd "$P" && bash "$VERDICT" g1t10 crit ev PASS --owner "$S10" >/dev/null 2>&1 )
# The exception must exist AND the row must exist — order alone would pass on a run that wrote neither.
G110_X="$(grep -cE 'GATE-EXCEPTION.*g1t10' "$P/.operator/DECISIONS.md" 2>/dev/null || true)"
G110_R="$(grep -cE '^\| g1t10 \|' "$P/.operator/VERDICTS.md" 2>/dev/null || true)"
check "G1.10 a never-armed verdict writes both the exception and the row" \
  "$([ "${G110_X:-0}" = "1" ] && [ "${G110_R:-0}" = "1" ] && echo 0 || echo 1)"
# Order is read off the source, not the filesystem: mtime granularity can make microseconds-apart appends compare
# equal, passing on BOTH orders (a vacuous guard, #21).
G110_XL="$(grep -nF 'sid:%s] verdict %s recorded without an open sentinel' "$SCRIPTS/ops-verdict.sh" | tail -1 | cut -d: -f1)"
# shellcheck disable=SC2016  # the single quotes are the point — grep -F searches for the LITERAL
# `"$ROW" >> "$VERDICTS"` text in ops-verdict.sh's source, not this suite's own (empty) $ROW.
G110_RL="$(grep -nF '"$ROW" >> "$VERDICTS"' "$SCRIPTS/ops-verdict.sh" | tail -1 | cut -d: -f1)"
check "G1.10 control: both write sites are locatable in ops-verdict.sh" \
  "$([ -n "$G110_XL" ] && [ -n "$G110_RL" ] && echo 0 || echo 1)"
check "G1.10 the GATE-EXCEPTION append precedes the ledger-row append (#14)" \
  "$([ -n "$G110_XL" ] && [ -n "$G110_RL" ] && [ "$G110_XL" -lt "$G110_RL" ] && echo 0 || echo 1)"

# G1.9 — the retro-gate covers BOTH closing paths: --defer retires a task exactly as a verdict does, so an
# unarmed defer earns the same GATE-EXCEPTION (PR-review finding, 2026-08-07).
P="$(newproj)"; ( cd "$P" && bash "$INIT" >/dev/null 2>&1 )
S9="SESS-G19"
( cd "$P" && bash "$VERDICT" g1t9 --defer "blocked" --owner "$S9" >/dev/null 2>&1 )
G19_NA="$(grep -cE '^[0-9]{4}.*GATE-EXCEPTION' "$P/.operator/DECISIONS.md" || true)"
check "G1.9 --defer of a never-opened task writes a GATE-EXCEPTION" \
  "$([ "${G19_NA:-0}" = "1" ] && echo 0 || echo 1)"
# Regression: deferring a properly ARMED task is unchanged and needs no --owner (the sentinel supplies it).
( cd "$P" && bash "$TASK" g1t9b --owner "$S9" >/dev/null 2>&1 )
( cd "$P" && bash "$VERDICT" g1t9b --defer "reason" >/dev/null 2>&1 ); G19ARC=$?
G19_ARMED="$(grep -cE '^[0-9]{4}.*GATE-EXCEPTION' "$P/.operator/DECISIONS.md" || true)"
check "G1.9 --defer of an armed task exits 0 and writes no GATE-EXCEPTION" \
  "$([ "$G19ARC" -eq 0 ] && [ "${G19_ARMED:-0}" = "1" ] && echo 0 || echo 1)"
# A never-armed defer with no --owner is REFUSED: an untagged exception is unowned, and unowned blocks everyone.
( cd "$P" && bash "$VERDICT" g1t9c --defer "x" >/dev/null 2>&1 ); G19NRC=$?
check "G1.9 --defer never-armed without --owner is refused" \
  "$([ "$G19NRC" -ne 0 ] && echo 0 || echo 1)"

rm -rf "$P"

########################################################################
echo "-- Case: S1 source-state stamp — a verdict row names the tree it came from"
# U10 (issue #22). A PASS used to survive unstaged/staged/committed/untracked source mutation, because the row
# named no source state at all. These pin the attribution stamp, which is NOT proof the tree still passes (S1.9).
# Every project here is a real git repo — the ordinary path, not the bare mktemp dirs most other cases use.
gitproj() { # gitproj -> path of a fresh git project with .operator scaffolded
  local p; p="$(newproj)"
  (
    cd "$p" || exit 1
    git init -q .
    git config user.email t@example.com
    git config user.name t
    printf 'def add(a,b):\n    return a+b\n' > src.py
    git add -A
    git commit -qm init
    bash "$INIT" >/dev/null 2>&1
  ) >/dev/null 2>&1
  printf '%s' "$p"
}
# The stamp cell, extracted from the ledger's last row: cell 3, trailing token.
stamp_of() { # stamp_of <project> -> the @-token of the last VERDICTS row
  awk -F' *\\| *' 'END{n=split($4,a," "); print a[n]}' "$1/.operator/VERDICTS.md"
}

if ! command -v git >/dev/null 2>&1; then
  echo "  SKIP S1 (no git on PATH — the stamp's own no-vcs branch is all that is testable here)"
else
P="$(gitproj)"
SHA="$(cd "$P" && git rev-parse --verify --short=12 HEAD)"
( cd "$P" && bash "$TASK" S1-a --owner SESS-S1 >/dev/null 2>&1 )
( cd "$P" && bash "$VERDICT" S1-a "src.py imports" "python3 -c 'import src' -> ok" PASS --owner SESS-S1 >/dev/null 2>&1 )
check "S1.1 clean tree → evidence cell carries @<sha>" \
  "$([ "$(stamp_of "$P")" = "@$SHA" ] && echo 0 || echo 1)"
# The 4-cell schema is what every grep consumer depends on; a stamp that split a row is the 5-cell injection guarded elsewhere.
NC="$(awk -F'|' 'END{print NF}' "$P/.operator/VERDICTS.md")"
check "S1.2 stamped row is still exactly 4 cells" \
  "$([ "$NC" = "6" ] && echo 0 || echo 1)"
# The fragment and the ledger must carry the SAME bytes, or --reconcile's dedup re-appends every stamped row.
LROW="$(tail -1 "$P/.operator/VERDICTS.md")"
FROW="$(tail -1 "$P/.operator/verdicts.d/SESS-S1.md")"
check "S1.3 fragment row and ledger row are byte-identical" \
  "$([ "$LROW" = "$FROW" ] && echo 0 || echo 1)"

# Dirty source → the stamp says so. This is the U10 experiment's first class.
printf 'def add(a,b):\n    return a*b\n' > "$P/src.py"
( cd "$P" && bash "$TASK" S1-b --owner SESS-S1 >/dev/null 2>&1 )
( cd "$P" && bash "$VERDICT" S1-b "crit" "ev" PASS --owner SESS-S1 >/dev/null 2>&1 )
check "S1.4 modified tracked file → @<sha>+dirty" \
  "$([ "$(stamp_of "$P")" = "@$SHA+dirty" ] && echo 0 || echo 1)"
# Untracked source counts too — the fourth class in the U10 table, one a naive `git diff` would miss.
( cd "$P" && git checkout -q -- src.py )
printf 'x\n' > "$P/new_source.py"
( cd "$P" && bash "$TASK" S1-c --owner SESS-S1 >/dev/null 2>&1 )
( cd "$P" && bash "$VERDICT" S1-c "crit" "ev" PASS --owner SESS-S1 >/dev/null 2>&1 )
check "S1.5 untracked source file → @<sha>+dirty" \
  "$([ "$(stamp_of "$P")" = "@$SHA+dirty" ] && echo 0 || echo 1)"
rm -f "$P/new_source.py"

# THE DISCRIMINATING CASE for the exclusion rule: .operator/ is untracked in almost every project (including
# this fixture). Counting it as dirt makes +dirty a marker that cannot be off (the vacuous-guard class, #21).
( cd "$P" && bash "$TASK" S1-d --owner SESS-S1 >/dev/null 2>&1 )
( cd "$P" && bash "$VERDICT" S1-d "crit" "ev" PASS --owner SESS-S1 >/dev/null 2>&1 )
check "S1.6 .operator/ churn alone does NOT read as dirty" \
  "$([ "$(stamp_of "$P")" = "@$SHA" ] && echo 0 || echo 1)"
rm -rf "$P"

# A repo with no commits: there's a tree, but no name to bind to — recorded, never refused.
P="$(newproj)"
( cd "$P" && git init -q . && git config user.email t@example.com && git config user.name t && bash "$INIT" ) >/dev/null 2>&1
( cd "$P" && bash "$TASK" S1-e --owner SESS-S1 >/dev/null 2>&1 )
( cd "$P" && bash "$VERDICT" S1-e "crit" "ev" PASS --owner SESS-S1 >/dev/null 2>&1 ); S1E=$?
check "S1.7 unborn HEAD → @no-commit, row still recorded" \
  "$([ "$S1E" = 0 ] && [ "$(stamp_of "$P")" = "@no-commit" ] && echo 0 || echo 1)"
rm -rf "$P"
fi

# No git repository at all — an explicit @no-vcs marker, not silence: an unstamped row means "written before this existed".
P="$(newproj)"; ( cd "$P" && bash "$INIT" >/dev/null 2>&1 )
( cd "$P" && bash "$TASK" S1-f --owner SESS-S1 >/dev/null 2>&1 )
( cd "$P" && bash "$VERDICT" S1-f "crit" "ev" PASS --owner SESS-S1 >/dev/null 2>&1 ); S1F=$?
check "S1.8 no git repo → @no-vcs, row still recorded (never refuses evidence)" \
  "$([ "$S1F" = 0 ] && [ "$(stamp_of "$P")" = "@no-vcs" ] && echo 0 || echo 1)"
# --defer is deliberately NOT stamped: it records that no verdict was reached, so there's no evidence to bind to a tree.
( cd "$P" && bash "$TASK" S1-g --owner SESS-S1 >/dev/null 2>&1 )
( cd "$P" && bash "$VERDICT" S1-g --defer "blocked upstream" --owner SESS-S1 >/dev/null 2>&1 )
check "S1.9 --defer line carries no stamp (nothing was verified)" \
  "$(grep -q 'DEFERRED-VERDICT' "$P/.operator/DECISIONS.md" && ! grep -q '@no-vcs' "$P/.operator/DECISIONS.md" && echo 0 || echo 1)"
rm -rf "$P"

# STRUCTURAL: the stamp is computed BEFORE lock_acquire, since `git status` is unbounded work and the PLAYBOOK
# rule is never lengthen the critical section. Comment lines dropped AFTER locating the section, since the
# marker is itself a comment but the prose inside also names source_stamp.
VSEC="$(awk '/^# --- Verdict path ---/{f=1} f' "$VERDICT" | grep -v '^[[:space:]]*#')"
SL="$(printf '%s\n' "$VSEC" | grep -n 'source_stamp' | head -1 | cut -d: -f1)"
LL="$(printf '%s\n' "$VSEC" | grep -n 'lock_acquire' | head -1 | cut -d: -f1)"
check "S1.10 stamp is resolved before lock_acquire (critical section unchanged)" \
  "$([ -n "$SL" ] && [ -n "$LL" ] && [ "$SL" -lt "$LL" ] && echo 0 || echo 1)"

# HONESTY NOTE: S1 proves ATTRIBUTION, not that the tree still passes — the stamp is provenance, not attestation.
# A lying operator can still record a PASS it never ran with a correctly-stamped tree.

########################################################################
echo "-- Case: init warns when a parent gitignore defeats the v2 allowlist (#25)"
# F67. The v2 allowlist lives INSIDE .operator/ and cannot beat a rule excluding the directory itself — git
# never descends into an excluded dir. The warning must NAME the defeating rule via check-ignore -v.
if command -v git >/dev/null 2>&1; then
P="$(newproj)"
( cd "$P" && git init -q . && git config user.email t@example.com && git config user.name t ) >/dev/null 2>&1
printf '/.operator/\n' > "$P/.gitignore"
W1ERR="$(cd "$P" && bash "$INIT" 2>&1 >/dev/null)"; W1RC=$?
check "defeated project: init still exits 0 (warn, never fail)" \
  "$([ "$W1RC" = 0 ] && echo 0 || echo 1)"
check "defeated project: warning fires" \
  "$(printf '%s' "$W1ERR" | grep -q 'gitignored by a rule outside' && echo 0 || echo 1)"
check "defeated project: warning names the defeating rule" \
  "$(printf '%s' "$W1ERR" | grep -q '/.operator/' && echo 0 || echo 1)"
rm -rf "$P"
P="$(newproj)"
( cd "$P" && git init -q . && git config user.email t@example.com && git config user.name t ) >/dev/null 2>&1
W2ERR="$(cd "$P" && bash "$INIT" 2>&1 >/dev/null)"
check "healthy git project: no warning" \
  "$(printf '%s' "$W2ERR" | grep -q 'gitignored by a rule outside' && echo 1 || echo 0)"
rm -rf "$P"
else
  echo "  SKIP init-warning cases (no git on PATH)"
fi
# Outside git the check must not run at all (and must not break the scaffold).
P="$(newproj)"
W3ERR="$(cd "$P" && bash "$INIT" 2>&1 >/dev/null)"; W3RC=$?
check "non-git project: init exits 0, no warning" \
  "$([ "$W3RC" = 0 ] && ! printf '%s' "$W3ERR" | grep -q 'gitignored by a rule outside' && echo 0 || echo 1)"
rm -rf "$P"

echo "-- Case: the v2 allowlist admits the handoff artifact (#28)"
# BEHAVIOURAL, not textual: the validator pins the allow LINES, this pins what git does with them. #28 —
# .operator/handoff-<date>.md was ignored by the bare `*` (a regression from v1's blocklist), shipping the
# handoff artifact untracked. (#31's armgate.on line went with the arm gate in 0.10.)
if command -v git >/dev/null 2>&1; then
P="$(newproj)"
( cd "$P" && git init -q . && git config user.email t@example.com && git config user.name t ) >/dev/null 2>&1
( cd "$P" && bash "$INIT" >/dev/null 2>&1 )
: > "$P/.operator/handoff-2026-08-11.md"
: > "$P/.operator/some-new-ephemera.tmp"
# `git check-ignore -q` EXIT STATUS is the truth — `-v` prints the last matching rule even for a `!` negation.
( cd "$P" && git check-ignore -q .operator/handoff-2026-08-11.md ) && GIH=1 || GIH=0
check "#28 the handoff file is TRACKED (not ignored by the v2 allowlist)" \
  "$([ "$GIH" = 0 ] && echo 0 || echo 1)"
( cd "$P" && git check-ignore -q .operator/some-new-ephemera.tmp ) && GIE=1 || GIE=0
check "the allowlist still IGNORES a new ephemera file (it is not a blocklist)" \
  "$([ "$GIE" = 1 ] && echo 0 || echo 1)"
# End to end: does `git add -A` actually stage them?
( cd "$P" && git add -A >/dev/null 2>&1 )
GIST="$(cd "$P" && git status --porcelain)"
check "#28 git add -A stages the handoff artifact" \
  "$(printf '%s' "$GIST" | grep -q 'handoff-2026-08-11.md' && echo 0 || echo 1)"
check "git add -A does NOT stage the new ephemera file" \
  "$(printf '%s' "$GIST" | grep -q 'some-new-ephemera.tmp' && echo 1 || echo 0)"
rm -rf "$P"
else
  echo "  SKIP allowlist-content cases (no git on PATH)"
fi

echo "-- Case: SessionStart refreshes a STALE bin/ even when the version has not moved (#34)"
# The upgrade used to fire only on a version-string change, so intra-version fixes never reached .operator/bin/
# even though the charter points the model at that copy (found by the replay charter 2026-08-12, #34).
STALEP="$(newproj)"
( cd "$STALEP" && git init -q . 2>/dev/null && "$BASH_ABS" "$SCRIPTS/ops-init.sh" >/dev/null 2>&1 )
STALEV="$(cat "$STALEP/.operator/.version" 2>/dev/null)"
# Plant a stale CLI: wrong content, mtime OLDER than the plugin's copy, while the version stamp reads current.
printf '#!/usr/bin/env bash\n# STALE COPY\n' > "$STALEP/.operator/bin/ops-verdict.sh"
touch -t 200001010000 "$STALEP/.operator/bin/ops-verdict.sh"
sed "s|<tmp>|$STALEP|" "$FIXTURES/sessionstart.json" | "$BASH_ABS" "$SSHOOK" >/dev/null 2>&1
check "#34 a stale bin/ CLI is refreshed with the version unchanged" \
  "$(grep -q 'STALE COPY' "$STALEP/.operator/bin/ops-verdict.sh" && echo 1 || echo 0)"
check "#34 the refreshed CLI is byte-identical to the plugin's copy" \
  "$(cmp -s "$STALEP/.operator/bin/ops-verdict.sh" "$SCRIPTS/ops-verdict.sh" && echo 0 || echo 1)"
check "#34 the version stamp is unchanged (this was never a version event)" \
  "$([ "$(cat "$STALEP/.operator/.version" 2>/dev/null)" = "$STALEV" ] && echo 0 || echo 1)"
# Negative control: nothing stale means no rewrite.
STALE_MTIME_BEFORE="$(ls -l "$STALEP/.operator/bin/ops-task.sh" 2>/dev/null)"
sed "s|<tmp>|$STALEP|" "$FIXTURES/sessionstart.json" | "$BASH_ABS" "$SSHOOK" >/dev/null 2>&1
check "#34 a current bin/ is NOT rewritten (the probe is staleness, not a timer)" \
  "$([ "$STALE_MTIME_BEFORE" = "$(ls -l "$STALEP/.operator/bin/ops-task.sh" 2>/dev/null)" ] && echo 0 || echo 1)"
rm -rf "$STALEP"

echo "-- Case: SessionStart replaces bin/ CLIs ATOMICALLY — the inode changes (F5)"
# The upgrade used to write each CLI in place with cp (O_TRUNC, same inode), so a concurrently-executing bash
# could be truncated mid-run (F5). Fix writes a temp file then mv's it over the target, swapping the inode.
INOP="$(newproj)"
( cd "$INOP" && git init -q . 2>/dev/null && "$BASH_ABS" "$SCRIPTS/ops-init.sh" >/dev/null 2>&1 )
# Plant an OLD copy, note its inode, and force an upgrade via a stale stamp.
printf '#!/usr/bin/env bash\n# STALE COPY\n' > "$INOP/.operator/bin/ops-verdict.sh"
printf '0.1.0-old\n' > "$INOP/.operator/.version"
_old_ino="$(stat -f '%i' "$INOP/.operator/bin/ops-verdict.sh" 2>/dev/null)"
sed "s|<tmp>|$INOP|" "$FIXTURES/sessionstart.json" | "$BASH_ABS" "$SSHOOK" >/dev/null 2>&1
_new_ino="$(stat -f '%i' "$INOP/.operator/bin/ops-verdict.sh" 2>/dev/null)"
check "F5 the upgraded bin/ CLI has a NEW inode (atomic replace, not in-place truncation)" \
  "$([ -n "$_old_ino" ] && [ -n "$_new_ino" ] && [ "$_old_ino" != "$_new_ino" ] && echo 0 || echo 1)"
check "F5 the upgraded bin/ CLI is byte-identical to the plugin's copy" \
  "$(cmp -s "$INOP/.operator/bin/ops-verdict.sh" "$SCRIPTS/ops-verdict.sh" && echo 0 || echo 1)"
# Steady state (nothing stale): no rewrite, so the inode is stable — proving the inode change above was a real upgrade.
_cur_ino="$(stat -f '%i' "$INOP/.operator/bin/ops-verdict.sh" 2>/dev/null)"
sed "s|<tmp>|$INOP|" "$FIXTURES/sessionstart.json" | "$BASH_ABS" "$SSHOOK" >/dev/null 2>&1
check "F5 steady-state (version matches) does NOT rewrite, so the inode is stable" \
  "$([ -n "$_cur_ino" ] && [ "$_cur_ino" = "$(stat -f '%i' "$INOP/.operator/bin/ops-verdict.sh" 2>/dev/null)" ] && echo 0 || echo 1)"
rm -rf "$INOP"

echo "-- Case: the SessionStart v1→v2 migration announces itself (#32)"
# The migration REPLACES a file the user may have edited; before this, the notice was silent — stdout carried
# only the SessionStart JSON and `git status` showed no trace of the backup. Rides additionalContext.
MIGP="$(newproj)"
mkdir -p "$MIGP/.operator"
printf '# cc-operator gitignore (v1)\nbin/\npending/\n!my-own-rule.md\n' > "$MIGP/.operator/.gitignore"
MIGOUT="$(sed "s|<tmp>|$MIGP|" "$FIXTURES/sessionstart.json" | "$BASH_ABS" "$SSHOOK" 2>/dev/null)"
check "#32 the migration notice reaches the model via additionalContext" \
  "$(printf '%s' "$MIGOUT" | grep -q 'MIGRATED' && echo 0 || echo 1)"
check "#32 the notice names the .v1.bak recovery path" \
  "$(printf '%s' "$MIGOUT" | grep -q 'gitignore.v1.bak' && echo 0 || echo 1)"
check "#32 the notice says the backup is itself ignored (git status --ignored)" \
  "$(printf '%s' "$MIGOUT" | grep -q '\-\-ignored' && echo 0 || echo 1)"
check "#32 the migration really did replace the user's rule (so the notice is earned)" \
  "$(grep -q 'my-own-rule' "$MIGP/.operator/.gitignore" && echo 1 || echo 0)"
# Second fire: already v2, nothing to migrate — the banner must stay clean.
MIGOUT2="$(sed "s|<tmp>|$MIGP|" "$FIXTURES/sessionstart.json" | "$BASH_ABS" "$SSHOOK" 2>/dev/null)"
check "#32 a second session (already v2) does NOT repeat the notice" \
  "$(printf '%s' "$MIGOUT2" | grep -q 'MIGRATED' && echo 1 || echo 0)"
rm -rf "$MIGP"

echo "-- Case: the migration REFUSES rather than destroying rules it cannot back up"
# The #32 notice promised a recoverable .v1.bak, but the backup was `cp … 2>/dev/null` followed by an
# UNCONDITIONAL write with the flag set first — unwritable .operator/ destroyed the rules with no backup
# and a claimed success (Copilot review of PR #12, 2026-08-12).
MIGF="$(newproj)"
mkdir -p "$MIGF/.operator"
printf '# cc-operator gitignore (v1)\nbin/\n!my-own-rule.md\n' > "$MIGF/.operator/.gitignore"
mkdir -p "$MIGF/.operator/.gitignore.v1.bak"          # a DIRECTORY at the backup path
MIGFOUT="$(sed "s|<tmp>|$MIGF|" "$FIXTURES/sessionstart.json" | "$BASH_ABS" "$SSHOOK" 2>/dev/null)"
check "backup blocked: the user's v1 rule survives" \
  "$(grep -q 'my-own-rule' "$MIGF/.operator/.gitignore" && echo 0 || echo 1)"
check "backup blocked: the hook does NOT claim a migration happened" \
  "$(printf '%s' "$MIGFOUT" | grep -q 'MIGRATED' && echo 1 || echo 0)"
check "backup blocked: the refusal is reported, not silent" \
  "$(printf '%s' "$MIGFOUT" | grep -q 'REFUSED' && echo 0 || echo 1)"
check "backup blocked: the session id is still injected (a hook must never die)" \
  "$(printf '%s' "$MIGFOUT" | grep -q "this session's id is" && echo 0 || echo 1)"
rm -rf "$MIGF"

# The OTHER trigger: the copy itself fails (unwritable dir), distinct from the non-regular .v1.bak case above.
MIGW="$(newproj)"
mkdir -p "$MIGW/.operator"
printf '# cc-operator gitignore (v1)\nbin/\n!my-own-rule.md\n' > "$MIGW/.operator/.gitignore"
chmod 500 "$MIGW/.operator"
MIGWOUT="$(sed "s|<tmp>|$MIGW|" "$FIXTURES/sessionstart.json" | "$BASH_ABS" "$SSHOOK" 2>/dev/null)"
chmod 700 "$MIGW/.operator"
# Same root caveat: chmod 500 doesn't stop root writing, so the copy this case needs to FAIL succeeds under root.
if [ "$(id -u)" = "0" ]; then
  echo "  skip unwritable-dir migration: running as root, chmod 500 does not refuse a write"
else
  check "unwritable dir: the v1 rule survives (cp failed, so no overwrite)" \
    "$(grep -q 'my-own-rule' "$MIGW/.operator/.gitignore" && echo 0 || echo 1)"
  check "unwritable dir: no MIGRATED claim over a backup that does not exist" \
    "$(printf '%s' "$MIGWOUT" | grep -q 'MIGRATED' && echo 1 || echo 0)"
  check "unwritable dir: no .v1.bak was left behind" \
    "$([ -e "$MIGW/.operator/.gitignore.v1.bak" ] && echo 1 || echo 0)"
fi
rm -rf "$MIGW"

echo "-- Case: ops-init refuses the same migration it cannot back up"
# Same defect, same fix, in the other writer — Copilot flagged only the hook.
INITF="$(newproj)"
mkdir -p "$INITF/.operator"
printf '# cc-operator gitignore (v1)\nbin/\n!my-own-rule.md\n' > "$INITF/.operator/.gitignore"
mkdir -p "$INITF/.operator/.gitignore.v1.bak"
INITFOUT="$( ( cd "$INITF" || exit 1; "$BASH_ABS" "$SCRIPTS/ops-init.sh" ) 2>&1 || true )"
check "init backup blocked: the user's v1 rule survives" \
  "$(grep -q 'my-own-rule' "$INITF/.operator/.gitignore" && echo 0 || echo 1)"
check "init backup blocked: it does NOT claim it migrated" \
  "$(printf '%s' "$INITFOUT" | grep -q 'migrated ' && echo 1 || echo 0)"
check "init backup blocked: the refusal names the path to fix" \
  "$(printf '%s' "$INITFOUT" | grep -q 'gitignore.v1.bak' && echo 0 || echo 1)"
rm -rf "$INITF"

echo "-- Case: the migration REFUSES a .v1.bak that is a symlink to a regular file (F4)"
# `-f` FOLLOWS symlinks, so a symlink-to-regular passed the old "refuse if non-regular" guard and cp overwrote
# the LINK'S TARGET. Guard must refuse on -L before falling back to -f.
MIGL="$(newproj)"
mkdir -p "$MIGL/.operator"
printf 'sensitive target contents\n' > "$MIGL/sensitive-target.txt"
printf '# cc-operator gitignore (v1)\nbin/\n!my-own-rule.md\n' > "$MIGL/.operator/.gitignore"
ln -s "$MIGL/sensitive-target.txt" "$MIGL/.operator/.gitignore.v1.bak"
MIGLOUT="$(sed "s|<tmp>|$MIGL|" "$FIXTURES/sessionstart.json" | "$BASH_ABS" "$SSHOOK" 2>/dev/null)"
check "symlink backup blocked: the sensitive target is untouched" \
  "$(grep -q 'sensitive target contents' "$MIGL/sensitive-target.txt" && echo 0 || echo 1)"
check "symlink backup blocked: the user's v1 rule survives" \
  "$(grep -q 'my-own-rule' "$MIGL/.operator/.gitignore" && echo 0 || echo 1)"
check "symlink backup blocked: the hook does NOT claim a migration happened" \
  "$(printf '%s' "$MIGLOUT" | grep -q 'MIGRATED' && echo 1 || echo 0)"
check "symlink backup blocked: the refusal is reported, not silent" \
  "$(printf '%s' "$MIGLOUT" | grep -q 'REFUSED' && echo 0 || echo 1)"
rm -rf "$MIGL"

echo "-- Case: ops-init also refuses a .v1.bak symlink to a regular file (F4)"
INITL="$(newproj)"
mkdir -p "$INITL/.operator"
printf 'sensitive target contents\n' > "$INITL/sensitive-target.txt"
printf '# cc-operator gitignore (v1)\nbin/\n!my-own-rule.md\n' > "$INITL/.operator/.gitignore"
ln -s "$INITL/sensitive-target.txt" "$INITL/.operator/.gitignore.v1.bak"
INITLOUT="$( ( cd "$INITL" || exit 1; "$BASH_ABS" "$SCRIPTS/ops-init.sh" ) 2>&1 || true )"
check "init symlink backup blocked: the sensitive target is untouched" \
  "$(grep -q 'sensitive target contents' "$INITL/sensitive-target.txt" && echo 0 || echo 1)"
check "init symlink backup blocked: the user's v1 rule survives" \
  "$(grep -q 'my-own-rule' "$INITL/.operator/.gitignore" && echo 0 || echo 1)"
check "init symlink backup blocked: it does NOT claim it migrated" \
  "$(printf '%s' "$INITLOUT" | grep -q 'migrated ' && echo 1 || echo 0)"
rm -rf "$INITL"

echo "-- Case: ops-verdict refuses a non-regular entry BEFORE writing a row"
# `retro_gate` tested `-e`, so a directory at pending/<id> read as armed: the exception was suppressed, the row
# appended anyway, and the later rm -f failed on the directory (Copilot review of PR #12, 2026-08-12).
NRP="$(newproj)"
(cd "$NRP" && "$BASH_ABS" "$SCRIPTS/ops-init.sh" >/dev/null 2>&1)
mkdir -p "$NRP/.operator/pending/dircase"
NROUT="$( ( cd "$NRP" || exit 1; "$BASH_ABS" "$SCRIPTS/ops-verdict.sh" dircase crit ev PASS --owner sid-x ) 2>&1 || true )"
check "non-regular sentinel: ops-verdict refuses" \
  "$(printf '%s' "$NROUT" | grep -q 'not a regular file' && echo 0 || echo 1)"
check "non-regular sentinel: NO row was written" \
  "$(grep -q '| dircase |' "$NRP/.operator/VERDICTS.md" && echo 1 || echo 0)"
check "non-regular sentinel: no GATE-EXCEPTION was written either" \
  "$(grep -v '^#' "$NRP/.operator/DECISIONS.md" | grep -q 'GATE-EXCEPTION' && echo 1 || echo 0)"
# The control: a real never-armed verdict still records BOTH row and exception.
( cd "$NRP" || exit 1; "$BASH_ABS" "$SCRIPTS/ops-verdict.sh" realcase crit ev PASS --owner sid-x >/dev/null 2>&1 ) || true
check "control: a never-armed verdict still records its row" \
  "$(grep -q '| realcase |' "$NRP/.operator/VERDICTS.md" && echo 0 || echo 1)"
check "control: …and its GATE-EXCEPTION" \
  "$(grep -v '^#' "$NRP/.operator/DECISIONS.md" | grep -q 'GATE-EXCEPTION' && echo 0 || echo 1)"
rm -rf "$NRP"

echo "-- Case: census counts a tracked file whose name begins with a dash"
# A leading-dash filename is legal in git; bare `xargs -0 cat` read it as options and aborted the whole batch.
DASHP="$(newproj)"
(cd "$DASHP" && git init -q . 2>/dev/null)
printf 'print(1)\nprint(2)\n' > "$DASHP/normal.py"
printf 'x=1\n' > "$DASHP/--version.py"
# `--` terminates git's option parsing so the dash-named path follows as a pathspec — the fix, one layer up.
(cd "$DASHP" && git add -- normal.py './--version.py' >/dev/null 2>&1)
DASHOUT="$( ( cd "$DASHP" || exit 1; "$BASH_ABS" "$SCRIPTS/ops-backlog.sh" --census ) 2>&1 || true )"
check "dash-named file: code-loc counts it (3, not 0)" \
  "$(printf '%s' "$DASHOUT" | grep -q 'code-loc: 3' && echo 0 || echo 1)"
check "dash-named file: the count is not PARTIAL" \
  "$(printf '%s' "$DASHOUT" | grep -q 'PARTIAL' && echo 1 || echo 0)"
rm -rf "$DASHP"

########################################################################
echo "-- Case: the suites do not contaminate the tree with bytecode"
# THE HYGIENE BEHAVIOUR HAD NO TEST AT ALL. Measured: reverting conftest.py to a no-op leaves 2 __pycache__ dirs
# with pytest still 178 passed; deleting norecursedirs reproduces the collection errors while both suites stay
# green (review panel's test lens, PR #36). Asserted against a COPY, not this tree, since a maintainer's earlier
# hand-run may have left a real __pycache__ here. Gated on pytest, not python3 — ubuntu-latest has python3 and
# no pytest, and gating on python3 alone made a missing-pytest rc read as a genuine collection error.
if ! python3 -c "import pytest" >/dev/null 2>&1; then
  echo "  skip bytecode hygiene: pytest not importable (the mechanisms under test are pytest's)"
else
  HYG="$(newproj)"
  mkdir -p "$HYG/scripts" "$HYG/tests"
  cp "$REPO/pyproject.toml" "$HYG/" 2>/dev/null
  cp "$REPO/tests/conftest.py" "$HYG/tests/" 2>/dev/null
    # A module to import and a test that imports it — produces a __pycache__ in BOTH directories.
  printf 'def f():\n    return 1\n' > "$HYG/scripts/mod_under_test.py"
  cat > "$HYG/tests/test_hyg.py" <<'PYEOF'
import pathlib, sys
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent.parent / "scripts"))
from mod_under_test import f
def test_f():
    assert f() == 1
PYEOF
    # THE SUITE-WIDE EXPORT MUST BE UNSET HERE, or this proves nothing about conftest.py: with it inherited, a
    # neutered conftest still leaves scripts/__pycache__ absent (M3 discrimination sweep: 526/0, no flip).
    # pyproject's testpaths names the plugin's own modules, which don't exist here; point pytest at the local file.
  ( unset PYTHONDONTWRITEBYTECODE; cd "$HYG" && python3 -m pytest tests/test_hyg.py -q >/dev/null 2>&1 )
    # conftest.py's OWN .pyc is documented residue (compiled before bytecode is disabled); what must NOT appear is
    # a cache for the imported module, i.e. scripts/__pycache__.
  check "pytest writes no __pycache__ for imported modules (conftest suppression works)" \
    "$([ ! -d "$HYG/scripts/__pycache__" ] && echo 0 || echo 1)"
    # And the seed-dir prune: a directory named like the pilot seeds, holding an unimportable test_*, must not break collection.
  mkdir -p "$HYG/tests/pilot-seeds/E9"
  printf 'import nonexistent_module_xyz\n' > "$HYG/tests/pilot-seeds/E9/test_broken.py"
  ( cd "$HYG" && python3 -m pytest tests/ -q >/dev/null 2>&1 ); HYGRC=$?
  check "norecursedirs keeps an unimportable seed dir out of collection" \
    "$([ "$HYGRC" = 0 ] && echo 0 || echo 1)"
  rm -rf "$HYG"
fi

########################################################################
echo "-- Case: gitignored build state diverges in-tree from a clean checkout (#23)"
# THE FIXTURE FOR #23, in-tree at last. The issue states the mechanism (a stale bytecode cache serving a builder-
# tree pass while a clean checkout of the same commit fails, git status empty throughout). MEASURED CORRECTION
# to the issue's recipe: same byte length is insufficient — CPython validates by mtime+size, and an edit moves
# the mtime, invalidating and recompiling both sides (measured, no divergence). Fixture puts the mtime back from
# the .pyc's own header (offset 8, PEP 552), not a pre-edit stat — a timing-derived stamp passed only 4/12.
# Skipped without python3 (the mechanism is CPython's cache); a printed skip, not a silent no-run.
if ! command -v python3 >/dev/null 2>&1; then
  echo "  skip #23 fixture: python3 not available (the mechanism is CPython's .pyc cache)"
else
  I23="$(newproj)"
  (
        # THE ONE OPT-OUT from this file's PYTHONDONTWRITEBYTECODE export: the mechanism under test IS a written
        # .pyc (measured: inherited, 505/2, both write-path halves red).
    unset PYTHONDONTWRITEBYTECODE
    cd "$I23" || exit 1
    git init -q -b work . && git config user.email t@t && git config user.name t
    printf '__pycache__/\n' > .gitignore
    printf 'def add(a, b):\n    return a + b\n' > calc.py
    printf 'from calc import add\nassert add(2, 3) == 5, add(2, 3)\n' > test_calc.py
    git add -A && git commit -qm correct
    python3 test_calc.py >/dev/null 2>&1        # builder run: writes the .pyc
    printf 'def add(a, b):\n    return a * b\n' > calc.py   # the defect
        # Stamp calc.py with the mtime the .pyc header itself records; os.utime takes the epoch directly, avoiding
        # the BSD/GNU date flavor split check_portability rejects.
    python3 -c "
import glob, os, struct, sys
f = glob.glob('__pycache__/calc.*.pyc')
if not f: sys.exit(0)
mt = struct.unpack('<I', open(f[0], 'rb').read(12)[8:12])[0]
os.utime('calc.py', (mt, mt))
" 2>/dev/null
    git add -A && git commit -qm defect
  ) >/dev/null 2>&1
    # The tracked tree is clean — the control that makes this a trap rather than an oversight.
  I23PORC="$( cd "$I23" && git status --porcelain 2>/dev/null )"
  check "#23 the builder's tree reports clean (the contaminant is gitignored)" \
    "$([ -z "$I23PORC" ] && echo 0 || echo 1)"
    # Same opt-out as the builder subshell: this run must be allowed to CONSULT the cache (PYTHONDONTWRITEBYTECODE
    # only suppresses writing).
  ( unset PYTHONDONTWRITEBYTECODE; cd "$I23" && python3 test_calc.py >/dev/null 2>&1 ); I23IN=$?
  check "#23 the defect verifies GREEN in the builder's tree (stale .pyc served)" \
    "$([ "$I23IN" = 0 ] && echo 0 || echo 1)"
  I23C="$(newproj)"; rm -rf "$I23C"
  git clone -q "$I23" "$I23C" >/dev/null 2>&1
  ( cd "$I23C" && git checkout -q work >/dev/null 2>&1 )
    # A clone carries tracked files only, so the whole gitignored family evaporates.
  check "#23 a clean checkout of that commit has no __pycache__" \
    "$([ ! -d "$I23C/__pycache__" ] && echo 0 || echo 1)"
  ( unset PYTHONDONTWRITEBYTECODE; cd "$I23C" && python3 test_calc.py >/dev/null 2>&1 ); I23CL=$?
  check "#23 the SAME commit FAILS in a clean checkout (verdict is tree-dependent)" \
    "$([ "$I23CL" != 0 ] && echo 0 || echo 1)"
    # And the scope line from --expect-clean is what an operator would have to notice: green tree, non-zero ignored count.
  I23OUT="$( cd "$I23" && bash "$CLAIMS" --expect-clean 2>/dev/null )"
  check "#23 --expect-clean is green here yet reports the ignored entry" \
    "$(printf '%s' "$I23OUT" | grep -q '{item working-tree} ok' \
       && printf '%s' "$I23OUT" | grep -q '{item ignored-state} report: 1 ' \
       && echo 0 || echo 1)"
  rm -rf "$I23" "$I23C"
fi

########################################################################
echo "-- Case: ops-render --model is the resolver made scriptable (#55)"
# `--show` is a table for a human; a caller wanting ONE id would have to parse it (risking a header row as a
# model id). `--model <seat>` prints the id alone. A warning captured into `M="$(...)"` becomes an unconfigured
# model id, and an empty line at rc 0 dispatches silently to the harness default.
P="$(newproj)"
mkdir -p "$P/.operator"
cat > "$P/.operator/tiers.env" <<'TIERSENV'
JUDGMENT=claude-opus-5
IMPLEMENT=deepseek:deepseek-v4-flash
MECHANICAL=glm-5-turbo
RECON=claude-haiku-4-5-20251001
TIERSENV
runmodel() { ( cd "$P" && "$BASH_ABS" "$SCRIPTS/ops-render.sh" --model "$1" ); }

MDL="$(runmodel mechanic 2>/dev/null)"; MRC=$?
check "#55 --model resolves a seat through its tier (mechanic → IMPLEMENT)" \
  "$([ "$MRC" = 0 ] && [ "$MDL" = "deepseek:deepseek-v4-flash" ] && echo 0 || echo 1)"
# Not a hardcoded map: a DIFFERENT seat on a DIFFERENT tier must follow its own binding.
check "#55 a second seat follows its own tier (crawler → MECHANICAL)" \
  "$([ "$(runmodel crawler 2>/dev/null)" = "glm-5-turbo" ] && echo 0 || echo 1)"
check "#55 the 'op-' prefix is optional, as everywhere else" \
  "$([ "$(runmodel op-mechanic 2>/dev/null)" = "$(runmodel mechanic 2>/dev/null)" ] && echo 0 || echo 1)"
# STDOUT IS THE CONTRACT: exactly one line — a leaking diagnostic would still contain the id, so line-count is asserted.
check "#55 stdout carries exactly one line (safe to command-substitute)" \
  "$([ "$(runmodel mechanic 2>/dev/null | wc -l | tr -d ' ')" = "1" ] && echo 0 || echo 1)"
# An unknown seat REFUSES; an empty line at rc 0 would let the caller silently take the harness default.
UNK="$(runmodel nosuchseat 2>/dev/null)"; URC=$?
check "#55 an unknown seat exits non-zero" "$([ "$URC" != 0 ] && echo 0 || echo 1)"
check "#55 an unknown seat prints NOTHING on stdout (never an empty-string id)" \
  "$([ -z "$UNK" ] && echo 0 || echo 1)"
UNKERR="$( ( cd "$P" && "$BASH_ABS" "$SCRIPTS/ops-render.sh" --model nosuchseat ) 2>&1 >/dev/null )"
# The likeliest cause is a typo, so the message names the seats that do exist.
check "#55 the refusal names the known seats" \
  "$(printf '%s' "$UNKERR" | grep -q 'known:.*mechanic' && echo 0 || echo 1)"
# The seat name reaches a comparison and an eval; same allowlist as everywhere.
( cd "$P" && "$BASH_ABS" "$SCRIPTS/ops-render.sh" --model '.*' >/dev/null 2>&1 ); DOTRC=$?
check "#55 a charset-illegal seat name is refused (F18 allowlist)" \
  "$([ "$DOTRC" != 0 ] && echo 0 || echo 1)"
( cd "$P" && "$BASH_ABS" "$SCRIPTS/ops-render.sh" --model >/dev/null 2>&1 ); NOARGRC=$?
check "#55 --model with no seat argument is refused" \
  "$([ "$NOARGRC" != 0 ] && echo 0 || echo 1)"
# It is the SAME resolver, not a second one: --model must apply exactly the guard --show applies, or it's a bypass.
printf 'IMPLEMENT=claude sonnet\n' > "$P/.operator/tiers.env"
( cd "$P" && "$BASH_ABS" "$SCRIPTS/ops-render.sh" --model mechanic >/dev/null 2>&1 ); BADRC=$?
check "#55 a malformed binding is refused through the same check_routable" \
  "$([ "$BADRC" != 0 ] && echo 0 || echo 1)"
printf 'IMPLEMENT=deepseek-v4-flash\n' > "$P/.operator/tiers.env"
MODELOUT="$( cd "$P" && "$BASH_ABS" "$SCRIPTS/ops-render.sh" --model mechanic 2>/dev/null )"
check "#55 --model resolves an id operator does not recognise (0.8.3)" \
  "$([ "$MODELOUT" = "deepseek-v4-flash" ] && echo 0 || echo 1)"
rm -rf "$P"

########################################################################
echo "-- Case: a vanishing holder file never prints a raw bash error"
# `lock_holder_read` tests `[ -f ]` then reads the file; the releasing writer can remove it between the two, and
# `2>/dev/null` on the read doesn't cover a failed INPUT redirection, so a raw `No such file` reached the operator.
# Structural assertion (not timing): drives lock_holder_read directly with the holder file replaced by an
# unopenable path, reproducing every run vs a natural race needing ~40 concurrent writers.
P="$(newproj)"
( cd "$P" && bash "$INIT" >/dev/null 2>&1 )
mkdir -p "$P/.operator/.lock"
cat > "$P/probe.sh" <<'HOLDPROBE'
set -u
LOCKDIR="$1"
# Take lock_holder_read verbatim from the CLI under test so this cannot drift from the implementation.
eval "$(sed -n '/^lock_holder_read() {$/,/^}$/p' "$2")"
# The file exists for `[ -f ]` and is unopenable for the read — a permission-denied file, not a directory.
printf 'someone 1 2\n' > "$LOCKDIR/holder"
chmod 000 "$LOCKDIR/holder" 2>/dev/null || true
lock_holder_read
# Report the record on STDOUT so the control attests to THIS run; used to re-extract the function separately,
# which could exercise different code (or none, on bash 3.2 — see the caller).
printf 'REC=[%s]\n' "$LOCK_HOLDER_REC"
chmod 644 "$LOCKDIR/holder" 2>/dev/null || true
HOLDPROBE
# Separate files rather than 2>&1 >/dev/null: two different questions from the SAME run.
bash "$P/probe.sh" "$P/.operator/.lock" "$VERDICT" >"$P/holder.out" 2>"$P/holder.err" || true
HOLDERR="$(cat "$P/holder.err")"
HOLDREC="$(cat "$P/holder.out")"
# root can read a 000 file, so the redirection never fails there — skip rather than assert an unexhibitable property.
if [ "$(id -u)" = "0" ]; then
  echo "  skip holder-read case: running as root, a 000 file is still readable"
else
  check "a failed holder read prints no raw bash error to the operator" \
    "$(printf '%s' "$HOLDERR" | grep -qE 'No such file|Permission denied' && echo 1 || echo 0)"
    # The control: the guard is only meaningful if the probe REACHED the read. Reads its own stdout — the earlier
    # form re-extracted the function via nested double quotes that don't survive bash 3.2 (the {…,…} sed address
    # became a brace expansion, mangling the script) while ubuntu's bash 5 stayed green. check_platform_idioms bans the shape.
  check "control: the probe's read actually failed (guard was exercised)" \
    "$([ "$HOLDREC" = "REC=[]" ] && echo 0 || echo 1)"
fi
rm -rf "$P"

########################################################################
echo "-- Case: the lock spin has an absolute ceiling (#68)"
# The bug: lock_acquire treated EVERY mkdir failure as contention. Only EEXIST means contention; ENOENT (the
# ledger dir removed mid-run) is permanent, and every escape hatch opened another mkdir in the same vanished
# parent. Measured on a dev machine before the fix: 54 leaked ops-verdict.sh processes, oldest ~17 days, ~1
# core burned continuously. Timing is used here (elapsed < watchdog) since there's no structural proxy for termination.
P="$(newproj)"
( cd "$P" && bash "$INIT" >/dev/null 2>&1 )
mkdir -p "$P/.operator/.lock"
# A foreign host + foreign uid + a pid that is not ours: holder_state can't judge it, so the time-based path applies.
printf 'someoneelse.example 65534 999999\n' > "$P/.operator/.lock/holder"
( cd "$P" && bash "$TASK" T-CEIL --owner SESS-A >/dev/null 2>&1 )
CEILERR="$P.ceil.err"
# All four budgets scale together and the spin budgets must outlast the 1s delete below (measured: LOCK_SPINS=6
# made the reclaim succeed inside the first second, proving nothing).
(
  cd "$P" && LOCK_SPINS=25 LOCK_LIVE_SPINS=25 RECLAIM_WAIT=5 LOCK_MAX_SPINS=30 \
    bash "$VERDICT" T-CEIL c e PASS --owner SESS-A >/dev/null 2>"$CEILERR"
) &
CEILPID=$!
# Remove the ledger AFTER the run is past its own no-.operator/ check and inside the spin loop.
sleep 1 & wait $! 2>/dev/null || true
rm -rf "$P/.operator"
# Watchdog: a still-spinning build must not hang the suite; its own kill distinguishes ceiling-terminated from us.
( sleep 20; kill -9 "$CEILPID" 2>/dev/null ) & CEILWD=$!
wait "$CEILPID" 2>/dev/null; CEILRC=$?
# The watchdog is itself a `( … ) &` subshell, so `kill $CEILWD` alone orphans its sleep — the same mechanism
# this case proves fixed, in its own scaffolding (measured before fixing: sleep survivors=[49573]).
reap_kids "$CEILWD"
kill "$CEILWD" 2>/dev/null || true; wait "$CEILWD" 2>/dev/null || true
# Reap any orphaned grandchild before asserting. Descendant-scoped via pgrep -P, not pkill -f, so a maintainer's
# concurrent checkout's suite run is never reached.
reap_kids "$CEILPID"
# rc 137 is the watchdog's SIGKILL — i.e. still spinning. Any other exit means the loop ended on its own.
check "#68 the spin loop terminates on its own (not by the watchdog's kill)" \
  "$([ "$CEILRC" != 137 ] && echo 0 || echo 1)"
check "#68 it refuses rather than proceeding unlocked (rc 2)" \
  "$([ "$CEILRC" = 2 ] && echo 0 || echo 1)"
check "#68 the ceiling message names the timeout" \
  "$(grep -q 'refusing to spin further' "$CEILERR" 2>/dev/null && echo 0 || echo 1)"
# The diagnosis half: a generic timeout sends a maintainer hunting a contention problem that doesn't exist.
check "#68 it names the vanished ledger directory as the cause" \
  "$(grep -q 'removed while this run was in flight' "$CEILERR" 2>/dev/null && echo 0 || echo 1)"
rm -f "$CEILERR"; rm -rf "$P"

# The SIBLING CLI's copy of the ceiling, executed rather than assumed: check_lock_parity pins byte-for-byte
# sameness, but two identically-correct-looking copies in different surroundings is the F30 shape (LOCK_MAX_SPINS
# executed at exactly one site, review panel finding).
P="$(newproj)"
( cd "$P" && bash "$INIT" >/dev/null 2>&1 )
mkdir -p "$P/.operator/.lock"
printf 'someoneelse.example 65534 999999\n' > "$P/.operator/.lock/holder"
( cd "$P" && bash "$TASK" T-ADCEIL --owner SESS-A >/dev/null 2>&1 )
ADERR="$P.aderr"
(
  cd "$P" && LOCK_SPINS=25 LOCK_LIVE_SPINS=25 RECLAIM_WAIT=5 LOCK_MAX_SPINS=30 \
    bash "$ADOPT" --owner SESS-B T-ADCEIL >/dev/null 2>"$ADERR"
) &
ADPID=$!
sleep 1 & wait $! 2>/dev/null || true
rm -rf "$P/.operator"
( sleep 20; kill -9 "$ADPID" 2>/dev/null ) & ADWD=$!
wait "$ADPID" 2>/dev/null; ADRC=$?
reap_kids "$ADWD"
kill "$ADWD" 2>/dev/null || true; wait "$ADWD" 2>/dev/null || true
reap_kids "$ADPID"
check "#68 ops-adopt's copy of the ceiling also terminates (parity is not proof)" \
  "$([ "$ADRC" != 137 ] && echo 0 || echo 1)"
# The message must carry the SIBLING's tool name, or a copy announcing itself as ops-verdict would mislead the operator.
check "#68 ops-adopt names ITSELF in the ceiling message, not its sibling" \
  "$(grep -q '^ops-adopt: could not acquire' "$ADERR" 2>/dev/null && echo 0 || echo 1)"
rm -f "$ADERR"; rm -rf "$P"

########################################################################
# The measurement corpora (#24 security, #70 drift, #58 plan-align) were removed in 0.10 (docs/DEBLOAT-0.10.md
# step 5); they live in git history (tree <= 0.9.0) and the maintainer's local .archive/dev/. ops-corpus.sh
# followed in step 6 (decision: DELETE).
########################################################################
if [ "$FAIL" -ne 0 ]; then
  echo "== failed cases =="
  printf '%s\n' "$FAILED_NAMES" | sed '/^$/d'
fi
echo "== summary: $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]
