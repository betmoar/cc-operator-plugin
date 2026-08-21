#!/usr/bin/env bash
# Operator plugin — plain-bash test runner (no bats dependency).
# Covers T2 contract cases 1–5. Run from anywhere:
#   bash tests/test-scripts.sh
# Exit 0 iff every assertion passes. In RED phase (scripts absent) it fails,
# naming each missing-script failure — that failing output is the T2 evidence.

set -u

# This suite shells out to python3 ~43 times. Every one of those would leave a
# __pycache__ next to whatever it imported — gitignored, so `git status` stays
# clean while the tree is not. Stale bytecode is the canonical example of build
# state a tracked-tree check cannot see (the class the #23 case at the bottom of
# this file demonstrates), and a test suite has no business generating it.
# Exported, so it reaches the subshells and the scripts under test too.
#
# ONE CASE MUST OPT OUT, and it is the #23 fixture at the bottom: its whole
# mechanism IS a written .pyc, so inheriting this turns it into a case that
# cannot demonstrate what it asserts. It unsets the variable in its own
# subshell. Found the direct way — setting this here took the suite to 505/2
# with both #23 write-path cases red.
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
ARMHOOK="$SCRIPTS/ops-armgate-hook.sh"
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
# Names are ACCUMULATED, not just printed. A failure scrolls past 5000 lines of
# ok, and the summary line is what anyone actually reads — so on 2026-08-19 a run
# reported 3 of 714 failed, did not reproduce in five re-runs, and the three case
# names were gone because nobody had captured them before re-running. An
# intermittent failure you cannot name is one you cannot fix; repeating it at the
# end costs one variable.
FAILED_NAMES=""
fail() { FAIL=$((FAIL+1)); FAILED_NAMES="$FAILED_NAMES
  $1"; printf '  FAIL %s\n' "$1"; }
check() { # check <desc> <0|1 condition-result>
  if [ "$2" -eq 0 ]; then pass "$1"; else fail "$1"; fi
}

# Fresh temp project; return its path.
newproj() { mktemp -d "${TMPDIR:-/tmp}/opstest.XXXXXX"; }

# Ownership lives in the sentinel's NAME (<owner>__<task>, or bare <task> when
# unowned), so the on-disk path is derived, never spelled out at 125 call sites.
# One helper means the convention can change again without a sweep.
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

# Kill a backgrounded job's CHILDREN, then the job itself (#68).
#
# `$!` names the subshell in `( cd … && bash "$X" … ) &`; the bash inside it is a
# grandchild that SURVIVES a kill on `$!`. That is how this suite leaked 54
# ops-verdict.sh processes, the oldest ~17 days, each burning ~1 core.
#
# pgrep's status is CHECKED rather than swallowed, and the distinction is real:
# rc 1 is "no children" (nothing to do), rc >= 2 is "pgrep itself failed" —
# measured as 2 for a bad invocation and 127 for a missing binary. Blanket
# `2>/dev/null` makes those indistinguishable from success, and the failure they
# hide is a silently unreaped grandchild: the exact leak class this helper
# exists to end, reappearing inside the suite that proves it fixed. So a tool
# failure is REPORTED. It is not a `fail` — the reap is cleanup, not an
# assertion, and turning a platform quirk into a red suite is how a maintainer
# learns to ignore the suite.
reap_kids() { # reap_kids <pid>
  local _pid="$1" _kids _rc _k
  _kids="$(pgrep -P "$_pid" 2>&1)"; _rc=$?
  if [ "$_rc" -gt 1 ]; then
    echo "  warning: pgrep -P $_pid failed (rc=$_rc: $_kids) — grandchild reap incomplete on this platform" >&2
    return 0
  fi
  for _k in $_kids; do kill -9 "$_k" 2>/dev/null || true; done
}

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
# The evidence cell ends with the source-state stamp (S1). It is matched as a
# token rather than pinned to `no-vcs`, because a suite run with TMPDIR inside
# someone's git repo legitimately stamps a sha here — pinning the value would
# make these cases fail on a correct build, for a reason nobody would guess.
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
echo "-- Case: a planted symlink FRAGMENT in verdicts.d/ is refused (F2/F65)"
# The F65 -L guard landed at the five pending/ sites but never in the
# evidence-fragment directory. append_fragment() and its reads used plain `-f`,
# which FOLLOWS a symlink: a planted/merge-corrupted symlink at
# .operator/verdicts.d/<owner>.md -> arbitrary-file made every verdict row for
# that owner append THROUGH the link into the target, exit 0, silent. A symlink
# is never a fragment our CLIs wrote. The write must refuse and the reads must
# skip it, and the outside target must stay untouched.
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
# INVARIANT: a VERDICTS row is exactly one line of exactly 4 pipe-delimited
# cells; the single writer refuses anything that would break that schema.
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
# The report must name the OWNER, not just the task id: with three or more
# sessions a bystander otherwise cannot tell whom to chase.
check "foreign report names the owning session id" "$(printf '%s' "$HERR" | grep -q 'owned by SESS-A' && echo 0 || echo 1)"
# The opened-at stamp is gone with the body parser. It was the only field that
# required opening a file, and task+owner is what makes the report actionable —
# the trade is recorded here rather than left as a silently dropped assertion.
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
# F14: the three hooks' json_get() python3 branch must render a JSON boolean
# as true/false (not Python True/False). The runtime path is exercised by the
# stop_hook_active boolean cases above ("stop_hook_active true -> exit 0");
# the DRIFT guarantee (all three hooks carry the isinstance(v, bool) coercion)
# is pinned by validate_plugin's check_guard_parity F14 pin against the real
# hook files, and its non-vacuity is proven by test_validate_plugin.py's good-
# tree fixtures (which must carry the marker or the pin fires on them).
# SessionStart migrates a v1 (blocklist) .operator/.gitignore to the v2
# allowlist. The v1 scheme tracked by default, so every ephemera directory added
# since had to be remembered and appended — twice (.lock/ for F05, then
# .compress-spill/ once a user's tree went dirty, 2026-08-04). v2 inverts the
# default: `*` covers everything new, and only evidence is re-admitted. The two
# schemes CONTRADICT, so this replaces rather than appends.
GIP="$(newproj)"; ( cd "$GIP" && bash "$INIT" >/dev/null 2>&1 )
printf '# legacy\n.lock/\n' > "$GIP/.operator/.gitignore"
sed "s|<tmp>|$GIP|" "$FIXTURES/sessionstart.json" | "$BASH_ABS" "$SSHOOK" >/dev/null 2>&1
check "sessionstart migrates a v1 gitignore to the v2 allowlist" \
  "$(grep -qF '# cc-operator gitignore v2 (allowlist)' "$GIP/.operator/.gitignore" && echo 0 || echo 1)"
check "the v2 migration keeps the user's v1 file as .v1.bak" \
  "$(grep -q '^# legacy$' "$GIP/.operator/.gitignore.v1.bak" 2>/dev/null && echo 0 || echo 1)"
# The load-bearing half: ledgers and fragments stay TRACKED, machine state does
# not. A migration that ignores a ledger loses evidence silently.
check "v2 re-admits both ledgers, tiers.env and the merge=union fragments" \
  "$( for a in '!VERDICTS.md' '!DECISIONS.md' '!tiers.env' '!verdicts.d/*.md'; do
        grep -qF "$a" "$GIP/.operator/.gitignore" || exit 1
      done; echo 0 )"
check "v2 ignores everything else by default (bare '*')" \
  "$(grep -qxF '*' "$GIP/.operator/.gitignore" && echo 0 || echo 1)"
# The compressor ephemera are now covered by '*' — no per-directory line, which
# is the whole point of the inversion.
check "v2 needs no explicit .compress-spill/ line (covered by '*')" \
  "$(grep -q '^\.compress-spill/$' "$GIP/.operator/.gitignore" && echo 1 || echo 0)"
# Idempotent: a second fire re-detects the marker and does not rewrite.
cp "$GIP/.operator/.gitignore" "$GIP/gi.before"
sed "s|<tmp>|$GIP|" "$FIXTURES/sessionstart.json" | "$BASH_ABS" "$SSHOOK" >/dev/null 2>&1
check "the v2 migration is idempotent (a second fire is a no-op)" \
  "$(cmp -s "$GIP/gi.before" "$GIP/.operator/.gitignore" && echo 0 || echo 1)"
# --- legacy sentinel migration (0.9.0: ownership moved into the filename) ----
# A pre-0.9.0 sentinel carries `session_id: <id>` in its BODY under a bare
# task-id name. SessionStart renames it to `<sid>__<task>` — and the EFFECT
# must be asserted, not just the non-firing on already-migrated names (PR #77
# review: only the empty-body case was tested; a regression that silently
# drops the mv shipped green). The renamed sentinel must re-block exactly its
# original owner and stay foreign-but-visible to everyone else.
MIG="$(newproj)"; ( cd "$MIG" && bash "$INIT" >/dev/null 2>&1 )
mkdir -p "$MIG/.operator/pending"
printf 'cwd: %s\nsession_id: OLD-SESS\nopened_at: 2026-08-01T00:00:00Z\n' > "$MIG/.operator/pending/legacy-task"
printf 'cwd: %s\nopened_at: 2026-08-01T00:00:00Z\n'                  > "$MIG/.operator/pending/unowned-task"
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
# rc is 2 either way here — the unowned-task sentinel blocks EVERY session by
# design — so the discriminator is the REPORT: the migrated sentinel must read
# as OLD-SESS's (foreign, "not blocking"), never as a second unowned blocker.
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

# --- automated upgrade path (version-gated bin/ refresh, 2026-08-04) ----------
# ops-init stamps the installed version; SessionStart refreshes bin/ when the
# running plugin's version differs. A project on an OLD operator keeps its old
# bin/ CLIs until /cc-operator:start re-runs — but SessionStart fires every
# session, so the new ops-claims.sh / --mark-handoff land automatically.
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
# CR3: a FAILED copy must NOT advance the stamp (a truncated CLI + "current"
# stamp would never retry). The old stamp stays, so the next session retries.
#
# The failure is induced by REPLACING bin/ with a regular file, not by
# `chmod 000` (#20). uid 0 ignores mode bits — `cp` into a chmod-000 directory
# SUCCEEDS as root, the stamp advanced, and this case failed for a reason that
# had nothing to do with the invariant: the suite was 441/1 as root and 442/0
# otherwise. A copy into a path that is a regular file fails for EVERY uid,
# root included, because it is a type error rather than a permission one.
# tests/test-scripts.sh already uses this class of trick for B10.3 ("chmod is
# not portable under every test runner"); CR3 had not been given it.
printf '0.1.0-old\n' > "$UP/.operator/.version"   # force an upgrade attempt
rm -rf "$UP/.operator/bin" && : > "$UP/.operator/bin"
sed "s|<tmp>|$UP|" "$FIXTURES/sessionstart.json" | "$BASH_ABS" "$SSHOOK" >/dev/null 2>&1
check "a failed upgrade copy does NOT advance the stamp (retry next session)" \
  "$([ "$(cat "$UP/.operator/.version")" = "0.1.0-old" ] && echo 0 || echo 1)"
rm -f "$UP/.operator/bin"          # the blocking regular file; restore a usable dir
mkdir -p "$UP/.operator/bin"
# CR3: bin/ is CREATED if absent (a project with .operator/ but no bin/ must not
# stamp itself current while installing nothing).
UP2="$(newproj)"; ( cd "$UP2" && bash "$INIT" >/dev/null 2>&1 )
rm -rf "$UP2/.operator/bin"
printf '0.1.0-old\n' > "$UP2/.operator/.version"
sed "s|<tmp>|$UP2|" "$FIXTURES/sessionstart.json" | "$BASH_ABS" "$SSHOOK" >/dev/null 2>&1
check "upgrade creates .operator/bin/ if absent" \
  "$([ -d "$UP2/.operator/bin" ] && [ -f "$UP2/.operator/bin/ops-claims.sh" ] && echo 0 || echo 1)"
rm -rf "$UP" "$UP2"

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
# Adoption is a rename, so the body it never touches is still the one ops-task
# wrote — opened_at survives because nothing rewrites the file at all.
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
# F15: PREV is captured from the untrusted sentinel body and echoed to stdout.
# A malicious body (traversal/pipe/whitespace/.exempt) must be sanitized to
# <invalid>, not echoed verbatim — stdout/log-injection-adjacent. The NEW
# owner is guarded by check_owner_name and is unaffected.
# The hostile owner arrives in the NAME, and PLANTING is the only way it can:
# check_bare_name refuses these shapes at construction, so ops-task can never
# produce one. Do NOT open the task first — that would leave two sentinels for
# one id, and which one a glob finds is collation-dependent (measured: macOS
# picked the planted one, Linux the real one, from the same suite).
printf 'cwd: /x\n' > "$P/.operator/pending/evil path|with pipe__T-PREV"
PREVOUT="$( cd "$P" && bash "$ADOPT" --owner SESS-B T-PREV 2>/dev/null )"; PREVRC=$?
check "F15 ops-adopt sanitizes a malicious PREV body to <invalid>" \
  "$(printf '%s' "$PREVOUT" | grep -q 'adopted T-PREV: <invalid> -> SESS-B' && echo 0 || echo 1)"
check "F15 ops-adopt still exits 0 (adoption succeeds; only the display is sanitized)" \
  "$([ "$PREVRC" -eq 0 ] && echo 0 || echo 1)"
check "F15 ops-adopt does not echo the raw malicious body" \
  "$(printf '%s' "$PREVOUT" | grep -q 'evil path|with pipe' && echo 1 || echo 0)"
# F15/#6: a PREV carrying an ANSI/OSC terminal-control escape (ESC ]0; ...)
# passes the owner-shape reject-set but would rewrite the terminal title when
# echoed. The [:cntrl:] arm must catch it -> <invalid>. (final-review #6.)
printf 'cwd: /x\n' > "$P/.operator/pending/$(printf '\033]0;PWNED\007FAKEOWNER')__T-PREV"
ESCOUT="$( cd "$P" && bash "$ADOPT" --owner SESS-B T-PREV 2>/dev/null )"
check "F15 ops-adopt sanitizes a PREV with an ANSI/OSC escape to <invalid>" \
  "$(printf '%s' "$ESCOUT" | grep -q 'adopted T-PREV: <invalid> -> SESS-B' && echo 0 || echo 1)"
check "F15 ops-adopt does not echo the raw escape sequence" \
  "$(printf '%s' "$ESCOUT" | grep -q 'PWNED' && echo 1 || echo 0)"
# F15 follow-up: an UNOWNED sentinel (opened with no --owner, so no session_id:
# line) must report <unowned>, NOT <invalid>. Empty PREV is the normal state of
# a legitimately unowned sentinel, not tampering — conflating them reads as a
# regression. (Final-review finding on the initial F15.)
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
# The gate's design is asymmetric ON PURPOSE: a MISMATCHED --owner is a hard
# refusal, a MISSING one only warns (a /clear'd session must still close its
# work). A typo'd flag converted the first into the second — `--ownr WRONG` fell
# through to the positional bucket, was dropped past $4, and one session closed
# another's task at rc 0 with a warning that reads as the routine post-/clear
# case. Measured against 0.8.0 before the fix, all three shapes below returned 0.
P="$(newproj)"; ( cd "$P" && bash "$INIT" >/dev/null 2>&1 )
( cd "$P" && bash "$TASK" T-TYPO --owner SESS-A >/dev/null 2>&1 )
ROWS_BEFORE="$(wc -l < "$P/.operator/VERDICTS.md")"
( cd "$P" && bash "$VERDICT" T-TYPO "crit" "evid" PASS --ownr SESS-B junk >/dev/null 2>&1 ); TYRC=$?
check "typo'd --owner on a foreign task is refused, not warned" "$([ "$TYRC" -ne 0 ] && echo 0 || echo 1)"
check "typo'd --owner writes no row and leaves the sentinel" "$([ "$(wc -l < "$P/.operator/VERDICTS.md")" = "$ROWS_BEFORE" ] && sentinel_any "$P" T-TYPO && echo 0 || echo 1)"
# The worse half, also measured: in the EVIDENCE slot the typo'd flag was not
# merely dropped, it was written into the ledger as the evidence cell.
( cd "$P" && bash "$VERDICT" T-TYPO "crit" --ownr=SESS-B PASS >/dev/null 2>&1 ); TYRC2=$?
check "a typo'd flag never lands in the ledger as evidence" "$([ "$TYRC2" -ne 0 ] && ! grep -q -- '--ownr=' "$P/.operator/VERDICTS.md" && echo 0 || echo 1)"
# Surplus positional: the other half of the same slip (`--ownr WRONG` split into
# two extras). Everything past $4 used to be discarded in silence.
( cd "$P" && bash "$VERDICT" T-TYPO "crit" "evid" PASS surplus >/dev/null 2>&1 ); SPRC=$?
check "a surplus positional is refused" "$([ "$SPRC" -ne 0 ] && echo 0 || echo 1)"
# The ceiling is PER FORM. A single `-le 4` bounds only the verdict form; the
# defer form's arity is three, so it kept one free slot and
# `<id> --defer "reason" STRAY --owner <sid>` deferred at rc 0 with STRAY
# silently dropped — the #64 class surviving in the other form (found by the
# silent-failure review, reproduced before fixing).
( cd "$P" && bash "$TASK" T-DEFX --owner SESS-A >/dev/null 2>&1 )
DLBEFORE="$(wc -l < "$P/.operator/DECISIONS.md")"
( cd "$P" && bash "$VERDICT" T-DEFX --defer "a real reason" STRAY --owner SESS-A >/dev/null 2>&1 ); DFXRC=$?
check "a surplus positional on the DEFER form is refused too" "$([ "$DFXRC" -ne 0 ] && echo 0 || echo 1)"
check "the refused defer writes no DECISIONS line and leaves the sentinel" "$([ "$(wc -l < "$P/.operator/DECISIONS.md")" = "$DLBEFORE" ] && sentinel_any "$P" T-DEFX && echo 0 || echo 1)"
# CONTROL: the legitimate three-positional defer form still works, or the
# per-form ceiling has simply broken defer.
( cd "$P" && bash "$VERDICT" T-DEFX --defer "a real reason" --owner SESS-A >/dev/null 2>&1 ); DFOKRC=$?
check "the legitimate defer form still works under the per-form ceiling" "$([ "$DFOKRC" -eq 0 ] && [ ! -e "$P/.operator/pending/T-DEFX" ] && echo 0 || echo 1)"
# NEGATIVE CONTROL, and the reason the reject arm is `--*` and not `-*`: a
# single-dash EVIDENCE cell is legitimate and common. It records correctly on
# 0.8.0; a blind dash reject would break real usage, which is how a guard gets
# deleted rather than fixed.
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
# INVARIANT (spec §4.3 criterion 4): the file header claims append+clear is one
# atomic action. Before 0.4 that was a property of printf's buffer size, not a
# guarantee. Drive it: two shells racing, then assert the schema held for EVERY
# line — an interleaved write shows up as a row that fails the 4-cell match.
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
check "held lock blocks a concurrent writer" "$(! grep -q 'locked-out' "$P/.operator/VERDICTS.md" && sentinel_any "$P" T-LOCK && echo 0 || echo 1)"
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
# `__` separates owner from task in the sentinel NAME (0.9.0). A `__` inside
# either half builds a filename every reader's first-`__` split parses as a
# DIFFERENT (owner, task) pair than the writer intended — ops-task.sh carried
# this arm alone through 0.9.0 and the other two writers did not (PR #77
# review, reproduced): adopting as `sessA__evilB` created
# `sessA__evilB__T1`, readers parsed owner `sessA`, the real adopter was
# locked out and bare `sessA` — which adopted nothing — CLOSED the task.
# Assert the REASON (the adopt refusal would otherwise fire for the unrelated
# "no such open task"; the verdict one for "task not open").
( cd "$P" && bash "$TASK" T-SEP --owner SESS-A >/dev/null 2>&1 )
TSEP1="$( cd "$P" && bash "$ADOPT" --owner "sessA__evilB" T-SEP 2>&1 )"; SEP1=$?
check "ops-adopt refuses a '__' owner (by reason)" "$([ "$SEP1" -ne 0 ] && printf '%s' "$TSEP1" | grep -q "must not contain '__'" && echo 0 || echo 1)"
check "no ambiguous sentinel was created" "$([ ! -e "$P/.operator/pending/sessA__evilB__T-SEP" ] && echo 0 || echo 1)"
TSEP2="$( cd "$P" && bash "$VERDICT" T-SEP c e PASS --owner "sessA__evilB" 2>&1 )"; SEP2=$?
check "ops-verdict refuses a '__' owner (by reason)" "$([ "$SEP2" -ne 0 ] && printf '%s' "$TSEP2" | grep -q "must not contain '__'" && echo 0 || echo 1)"
TSEP3="$( cd "$P" && bash "$TASK" "bad__id" --owner SESS-A 2>&1 )"; SEP3=$?
check "ops-task still refuses a '__' task-id (by reason)" "$([ "$SEP3" -ne 0 ] && printf '%s' "$TSEP3" | grep -q "must not contain '__'" && echo 0 || echo 1)"
# and the spoof itself must now fail end-to-end: bare sessA cannot close T-SEP
# because the ambiguous adoption never happened
( cd "$P" && bash "$VERDICT" T-SEP c e PASS --owner SESS-A >/dev/null 2>&1 )
check "the pre-fix spoof path closes the task only via its REAL owner" "$(grep -q 'T-SEP' "$P/.operator/VERDICTS.md" && echo 0 || echo 1)"
( cd "$P" && bash "$TASK" T-SEP2 --owner SESS-A >/dev/null 2>&1 )
( cd "$P" && bash "$VERDICT" T-SEP2 c e PASS --owner SESS-A >/dev/null 2>&1 )
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
echo "-- Case 12b: --reconcile restores a long (>512B) conformant row"
# INVARIANT: a verdict row whose evidence cell exceeds 512 bytes is legal and
# conformant — the 4-cell schema counts cells, not bytes. But --reconcile read
# the fragment with `read -r -n 512`, splitting such a row into chunks; each
# chunk independently failed the 4-cell check and was silently skipped, so the
# row was NEVER restored to the ledger. This is the issue-#9 long-row blindness
# class at the reconcile site (retro_gate already used a 1MiB bound). F17.
P="$(newproj)"; ( cd "$P" && bash "$INIT" >/dev/null 2>&1 )
# a ~560-byte evidence cell (no pipe, no newline — still exactly 4 cells)
LONG="$(printf 'e%.0s' $(seq 1 560))"
mkdir -p "$P/.operator/verdicts.d"
printf '| T-LONG | crit | %s @abc123 | PASS |\n' "$LONG" >> "$P/.operator/verdicts.d/SESS-LONG.md"
# sanity: the planted row genuinely exceeds the 512B chunk bound (this is the
# whole point of the case — a sub-512B row would pass even with the old bound)
check "premise: long row is >512B" "$([ "$(wc -c < "$P/.operator/verdicts.d/SESS-LONG.md")" -gt 512 ] && echo 0 || echo 1)"
ROUT="$( cd "$P" && bash "$VERDICT" --reconcile 2>&1 )"; RRC=$?
check "--reconcile exits 0 with a long row present" "$([ "$RRC" -eq 0 ] && echo 0 || echo 1)"
check "--reconcile does NOT skip the long row as non-conformant" "$(! printf '%s' "$ROUT" | grep -q 'non-conformant' && echo 0 || echo 1)"
check "--reconcile restores the long row to VERDICTS.md" "$(grep -q 'T-LONG' "$P/.operator/VERDICTS.md" && echo 0 || echo 1)"
rm -rf "$P"

########################################################################
echo "-- Case 12c: --reconcile aborts on an unreadable VERDICTS.md (F13)"
# INVARIANT: reconcile is a WRITE to the ledger of record; a ledger that became
# unreadable mid-reconcile (concurrent access, dropped perms) must ABORT, not
# report a false '0 restored'. grep's exit 2 was masked by `|| true`, so a
# readability failure silently restored nothing and still exited 0. F13.
P="$(newproj)"; ( cd "$P" && bash "$INIT" >/dev/null 2>&1 )
mkdir -p "$P/.operator/verdicts.d"
printf '| T-F13 | crit | ev @abc123 | PASS |\n' >> "$P/.operator/verdicts.d/SESS-F13.md"
# sanity: the fragment row is present and would be restored were the ledger readable
check "premise: ledger exists" "$([ -f "$P/.operator/VERDICTS.md" ] && echo 0 || echo 1)"
# make the ledger unreadable, then reconcile MUST abort non-zero (no '0 restored')
chmod 000 "$P/.operator/VERDICTS.md"
ROUT="$( cd "$P" && bash "$VERDICT" --reconcile 2>&1 )"; RRC=$?
chmod 600 "$P/.operator/VERDICTS.md"
# root reads a 000 file, so the premise of this case cannot hold there — the same
# reason the holder-read control is skipped for root. ANNOUNCED, because a
# container running as root is the normal way to reproduce CI locally, and four
# silent passes would be worse than four honest skips.
if [ "$(id -u)" = "0" ]; then
  echo "  skip 12c: running as root, a 000 ledger is still readable"
else
  check "--reconcile exits NON-ZERO on an unreadable VERDICTS.md" "$([ "$RRC" -ne 0 ] && echo 0 || echo 1)"
  check "--reconcile does NOT report '0 restored' success on grep failure" "$(! printf '%s' "$ROUT" | grep -q '0 row(s) restored' && echo 0 || echo 1)"
fi
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
for vec in pad512 nulpad latenul utf8pad; do
  rm -f "$P"/.operator/pending/*
  if [ "$vec" = pad512 ]; then
    python3 -c "import sys; open(sys.argv[1],'wb').write(b'x'*512+b'session_id: EVIL\\n')" "$P/.operator/pending/T-SMUG"
  elif [ "$vec" = nulpad ]; then
    python3 -c "import sys; open(sys.argv[1],'wb').write(b'x'+b'\\0'*100+b'x'*411+b'session_id: EVIL\\n')" "$P/.operator/pending/T-SMUG"
  elif [ "$vec" = utf8pad ]; then
    # 512 multibyte chars (é = 2 bytes) = 1024 bytes. In a UTF-8 locale `read -n
    # 512` and ${#line} count CHARACTERS, so this 1024-byte line reads as ONE
    # 512-char chunk that never trips the <512 cap guard — and `session_id: EVIL`
    # on the next line smuggles a foreign owner (unowned→foreign, fail-OPEN).
    # The fix sets LC_ALL=C in the parser so both count BYTES (review finding
    # 2026-08-04). Reproducible on bash 3.2 with a UTF-8 locale.
    python3 -c "import sys; open(sys.argv[1],'wb').write(('é'*512+'session_id: EVIL\\n').encode('utf-8'))" "$P/.operator/pending/T-SMUG"
  else
    # latenul: the NUL sits PAST byte 512 with every physical line under the cap,
    # so the single-shot 512-byte probe missed it and the sub-cap lines slipped
    # the pad512 guard too — the full-PR panel's score-92 exploit (owner=EVIL,
    # exit 0 on bash 3.2). The fix loops the probe over the whole file.
    python3 -c "import sys; open(sys.argv[1],'wb').write(b'\\n'.join(b'p'*100 for _ in range(6))+b'\\n'+b'q'*50+b'\\0'+b'r'*50+b'\\nsession_id: EVIL\\n')" "$P/.operator/pending/T-SMUG"
  fi
  # Under the OLDEST bash: the nul vectors only exist there (F46).
  # The utf8pad vector only exercises the multibyte-counting path under a UTF-8
  # locale; find one, else run default (the LC_ALL=C fix makes the parser
  # locale-independent, so it blocks either way, but only a UTF-8 locale proves
  # the fix is what's blocking).
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
printf 'cwd: /x\n' > "$P/.operator/pending/OTHER__T-FGN"
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
  rm -f "$P"/.operator/pending/*T-RACE "$P/.operator/pending/T-RACE"
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
# Exactly ONE sentinel for the task, whichever session won — the no-takeover
# guarantee. Ownership is the name now, so "one owner line" became "one file".
SENTN=0
for _s in "$P"/.operator/pending/*T-RACE "$P"/.operator/pending/T-RACE; do
  [ -e "$_s" ] && SENTN=$((SENTN + 1))
done
check "concurrent open: exactly one sentinel for the task (no second owner)" "$([ "$SENTN" = "1" ] && echo 0 || echo 1)"
# The post-rename re-check: the mv re-opens the window the O_EXCL claim closed
# (the bare claim path is free again the instant the winner's rename lands), so
# a second opener interleaving across it mints a SECOND sentinel. We cannot
# force that interleave deterministically at real speed (a 6-way stress, 10
# rounds, hit it 0 times — PR #77 review needed an injected sleep), so the
# re-check fires in the LOSING-leg posture: our sentinel already exists, a
# foreign one lands beside it. sentinel_for's scan sees EITHER sentinel (glob
# order) and returns "already open" — so the load-bearing property at this
# site is not the die; it is that a second, foreign sentinel for the id can
# never be created THROUGH ops-task while one exists under any owner: the
# bare claim path stays occupied (EEXIST) or the scan finds the id first.
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
check "a held reclaim-claim blocks another writer from reclaiming" "$([ -d "$P/.operator/.lock" ] && sentinel_any "$P" T-RC && echo 0 || echo 1)"
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
check "abandoned claim: verdict actually recorded" "$(grep -Eq '^\| T-AB \| crit \| ev @[^ |]+ \| PASS \|$' "$P/.operator/VERDICTS.md" && [ ! -e "$P/.operator/pending/T-AB" ] && echo 0 || echo 1)"
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
# to the Stop hook only; ops-verdict.sh and the --reconcile
# fragment reader kept plain `read -r`. Measured on one 256MB line: hook 0.17s
# vs verdict 13.51s, reconcile 32.56s. (Audit F02, P2.) 0.9.0 note: ops-adopt.sh
# no longer reads sentinel CONTENT at all (adoption is a rename; only the
# filename is inspected), so its sub-assertion below now measures the wall
# clock of an `mv` — kept as a tripwire against a reintroduced unbounded read
# in any adopt code path, not as proof one is absent; that proof is
# check_reader_bounds, which asserts "ops-adopt no longer reads a sentinel".
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
check "ops-adopt handles a huge-line sentinel in bounded time (<3s, mv-only since 0.9.0)" "$([ "$((S1 - S0))" -lt 3 ] && echo 0 || echo 1)"
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
# Under the v2 allowlist there is no per-directory `.lock/` line — `*` covers it
# and every ephemera directory added later. Assert the BEHAVIOUR (git ignores a
# lock) rather than the literal, so this case cannot pass a file that merely
# mentions the word.
check "ops-init ignores its own lock ephemera" \
  "$( cd "$Q" && git init -q . >/dev/null 2>&1; mkdir -p .operator/.lock; : > .operator/.lock/held
      git check-ignore -q .operator/.lock/held && echo 0 || echo 1 )"
rm -rf "$Q"

# F05's warning must not cry wolf (issue #61). It compared git's PHYSICAL
# toplevel against the LOGICAL $PWD, so any symlinked ancestor made the two
# differ by construction — and /tmp is a symlink to private/tmp on every macOS
# install, so every scratch project under /tmp fired the warning at the repo
# root. A warning that is always wrong is how the real signal gets trained out.
# The symlink is BUILT here rather than assumed: Linux CI has no /tmp symlink,
# and a case that silently no-ops on the build machine proves nothing.
R="$(newproj)"; mkdir -p "$R/real"
( cd "$R/real" && git init -q . >/dev/null 2>&1 )
ln -s "$R/real" "$R/link"
SYMOUT="$( cd "$R/link" && bash "$INIT" 2>&1 )"
check "#61 repo root reached via a symlink does NOT warn" "$(printf '%s' "$SYMOUT" | grep -q 'NOT the repository root' && echo 1 || echo 0)"
# The control that keeps the fix from being a mute button: a GENUINE
# subdirectory scaffold still warns, because that difference survives resolution.
mkdir -p "$R/real/sub"
SUBOUT="$( cd "$R/real/sub" && bash "$INIT" 2>&1 )"
check "#61 a genuine subdirectory scaffold still warns" "$(printf '%s' "$SUBOUT" | grep -q 'NOT the repository root' && echo 0 || echo 1)"
# …and the same subdirectory reached THROUGH the symlink also still warns —
# the fix resolves both sides, so the mis-aim is caught by either route.
SUBLNK="$( cd "$R/link/sub" && bash "$INIT" 2>&1 )"
check "#61 a subdirectory reached via the symlink still warns" "$(printf '%s' "$SUBLNK" | grep -q 'NOT the repository root' && echo 0 || echo 1)"
# …and it names PHYSICAL paths on BOTH sides. The message used to print the
# LOGICAL $PWD beside the physical toplevel, so reached through the symlink the
# two paths differed by resolution as well as by directory — inviting the exact
# misreading #61 was. Asserted here, where the logical and physical paths
# genuinely differ, so a message that reverted to $PWD would fail.
check "#61 the warning names physical paths on both sides" "$(printf '%s' "$SUBLNK" | grep -q "scaffolding at $( cd "$R/real/sub" && pwd -P ), which is NOT" && echo 0 || echo 1)"
rm -rf "$R"

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
check "dead holder: verdict actually recorded" "$(grep -Eq '^\| T-DEAD \| crit \| ev @[^ |]+ \| PASS \|$' "$P/.operator/VERDICTS.md" && [ ! -e "$P/.operator/pending/T-DEAD" ] && echo 0 || echo 1)"
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
check "two simultaneous reclaimers: both verdicts recorded" "$(grep -Eq '^\| T-X1 \| c \| e @[^ |]+ \| PASS \|$' "$P/.operator/VERDICTS.md" && grep -Eq '^\| T-X2 \| c \| e @[^ |]+ \| PASS \|$' "$P/.operator/VERDICTS.md" && echo 0 || echo 1)"
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
check "foreign-host holder is not judged dead (no instant reclaim)" "$(sentinel_any "$P" T-FH && echo 0 || echo 1)"
# Kill the GRANDCHILD too, not just the subshell (#68). `$!` names the subshell;
# the `bash "$VERDICT"` inside it is its child, and killing the subshell alone
# ORPHANS that child — it keeps spinning on a lock in a directory this suite is
# about to delete. Measured on a dev machine: 54 such orphans, the oldest ~17
# days, ~1 core burned continuously, warnings written into a closed stdout. The
# lock ceiling added for #68 now bounds them at 120s, but a test must not leak
# for 120s either, and a suite that reaps its own children would have contained
# this even with the bug present.
#
# BOTH backgrounding shapes in this suite orphan, so the rule is about the KILL,
# not about the shape. Measured directly, killing only the parent:
#   ( cd "$P" && bash "$X" … ) &        -> child survives
#   bash -c 'cd "$0" && bash "$1" …' &  -> child survives too
# (A review round asserted the second form was orphan-proof. It is not: that
# only holds when the inner command is the subshell's LAST simple command, so
# bash execs instead of forking — which is never true here, because every site
# redirects and chains.)
#
# The ABPID and LVWRITER sites are not leaking TODAY for a different reason:
# they poll for a clean exit and only `kill -9` on a 20s timeout that does not
# fire in practice. Their kill path would orphan if it ever did. So: any site
# that can reach a bare `kill` on a backgrounded writer wants this reap.
reap_kids "$FHPID"
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
echo "-- Case 21b: the give-up path is serialized by the fallback lock [F6]"
# lock_acquire has two "proceed unlocked" exits — a CONFIRMED-LIVE holder that
# outlasts LOCK_LIVE_SPINS, and a reclaim we could not win. Both used to return
# 0 having acquired NOTHING, so every waiter that timed out in the same window
# entered the critical section together: the unarbitrated multi-writer pile-up
# the lock exists to prevent, N-wide. They now queue on $LOCKDIR.fallback.
#
# HONESTY, twice over:
#  · This does NOT make the give-up safe against the live holder. One giver-up
#    still runs beside it — the accepted liveness trade ("never block the
#    operator forever"). The fallback reduces N to 1; it does not reach 0.
#  · The overlap assertion below is a real detector, not a timing coincidence:
#    each giver-up does an atomic `mkdir` of a WITNESS dir inside its fallback
#    critical section and holds it for 0.4s. Two overlapping sections mean one
#    of those mkdirs fails, deterministically, regardless of scheduling. What it
#    cannot prove is the converse at every skew — it proves the mutex holds for
#    the overlaps this suite actually produces.
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
    # A non-empty stamp is not enough: it must name US. `-s` alone passes on a
    # reclaim that removes the dead holder's dir and recreates it WITHOUT
    # restoring ownership — the dir would be held, stamped, and owned by nobody,
    # and every later reclaim-vs-live judgement would read the wrong record.
    # Checked here rather than in the end-to-end cases: the stamp exists only
    # while the lock is HELD, and those observe the process from outside, after
    # it exits. This is the one seat that can see mid-hold.
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
    # Giving up on the fallback WARNS on stderr, and the harness folds stderr
    # into the probe's output — keep the channel clean so "OK" means OK.
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

# A dead holder. A one-shot claim dir with no reclaim would dangle here forever
# and wedge every later giver-up — the unexpirable-claim mistake this block has
# already made once (.lock.reclaim, case 16).
sleep 0.1 & FBDEAD=$!; wait "$FBDEAD" 2>/dev/null || true
mkdir -p "$LK.fallback"; printf '%s %s %s\n' "${HOSTNAME:-nohost}" "${UID:-0}" "$FBDEAD" > "$LK.fallback/holder"
FBOUT="$( cd "$P" && bash "$TMPD/fb.sh" "$SCRIPTS/ops-verdict.sh" reclaim 2>&1 )"
check "fallback lock: a crashed giver-up's dir is reclaimed (staleness-free)" "$([ "$FBOUT" = "OK" ] && echo 0 || echo 1)"
check "fallback lock: reclaimed and then released — nothing left behind" "$([ ! -d "$LK.fallback" ] && echo 0 || echo 1)"

# A LIVE holder is waited on, never stolen, and the wait EXPIRES: an unbounded
# one here would be a deadlock inside the code whose whole job is to degrade.
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

# Three concurrent givers-up. Overlap is caught by the witness mkdir, not by
# reading a clock.
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

# END-TO-END, and this is the constraint that matters most: a giver-up must
# never set LOCK_HELD or touch $LOCKDIR. lock_release would then rm the LIVE
# holder's dir on exit — precisely the F03 displacement the confirmed-alive
# branch was written to forbid. Real ops-verdict.sh, real live holder.
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

# Every assertion above holds whether or not lock_acquire ever CALLS
# fallback_acquire: one giver-up against one live holder completes, records, and
# leaves nothing behind in both worlds. Measured — deleting all four call sites
# (2 per CLI, in parity so the drift check stays silent) left the suite at
# 588/0. The mechanism was tested only through the fb.sh probe, which evals the
# LOCK BLOCK and calls fallback_acquire DIRECTLY; nothing exercised the wiring.
#
# So observe the TAKE, not the release. Pre-plant a fallback dir stamped with a
# DEAD pid: wired, the giver-up judges it dead, reclaims it, takes it, and
# releases on exit — the dir is GONE. Unwired, nobody looks at it — it SURVIVES.
# A dead stamp rather than a live one on purpose: the two worlds must differ in
# the END STATE, not in elapsed time, or the case is a load-flaky timing assert.
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

# --- the SAME guarantee on the --reconcile path -----------------------------
# `trap` REPLACES a handler for its signal; it does not stack. --reconcile calls
# lock_acquire (which may install `lock_release; fallback_release`) and THEN
# installs its own tempfile-cleanup trap. Naming only lock_release there silently
# dropped fallback_release for the rest of the process, leaking $LOCKDIR.fallback
# on every reconcile that ran under contention — the exact leak the two acquire
# sites carry a comment against. The end-to-end case above could not see it: it
# exercises the ordinary write path, which installs no trap of its own.
# Asserted on the REAL script against a REAL live holder, because the defect is
# in trap composition and a source-grep for the handler string would pass on a
# trap that never runs.
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
#
# Run from SLBARE — a temp dir with no `.operator/` at or above it. When the
# payload cannot be parsed there is no cwd to read, so statusline.sh:84 falls
# back to $PWD — an explicit `${CLAUDE_PROJECT_DIR:-$PWD}` default, so it is
# intended, though the file states no rationale for it (:49-50 documents the
# preference ORDER — payload first — which is a different claim; a review caught
# this comment citing those lines as if they justified the fallback).
# These three used to run with cwd = THIS REPO, where the fallback
# found no ledger only because the repo has never had `.operator/` scaffolded in
# it — so "renders nothing" was really asserting "the maintainer never dogfooded
# the gate here". Opening one real task turned all three red at once, with the
# renderer behaving exactly as designed. Vacuous-guard class (#21), reached
# through ambient state instead of a missing call site; the positive control
# below is what keeps it non-vacuous.
SLBARE="$(newproj)"
# `.git` bounds the upward walk. statusline.sh:86-95 climbs from $PWD looking for
# .operator/, stopping only at a .git boundary or /, so "a temp dir with no
# .operator/" was asserted in a comment and true only by luck: with TMPDIR set
# inside a scaffolded project — TMPDIR=$GITHUB_WORKSPACE/tmp is a common CI
# pattern — the walk finds an ancestor ledger and all three silence cases go red.
# The fixture is now hermetic by construction rather than by where $TMPDIR
# happens to point.
mkdir -p "$SLBARE/.git"
# CLAUDE_PROJECT_DIR is unset at each invocation below. statusline.sh:84 resolves
# `${CLAUDE_PROJECT_DIR:-$PWD}`, so when the harness exports it — Claude Code
# does — it OVERRIDES the cwd these cases carefully set, and they measure the
# ambient project instead of the fixture. Measured both ways: bare cwd with the
# var pointing at a scaffolded project renders op[1] (turning the three silence
# cases red), and a scaffolded cwd with the var pointing at a bare dir renders
# nothing (turning the positive control red). The `.git` bound above fixes the
# upward walk; this fixes the entry point.
# The setup must be verified BEFORE it is relied on. These three cases assert on
# an EMPTY substitution, and `cd "$SLBARE" && …` inside `$( )` yields exactly
# that when the cd fails — so a missing or unwritable dir reported ok, for a run
# in which the renderer was never invoked at all. #21's class, reintroduced one
# layer under the rewrite whose own comment says it was removing it.
check "control: the statusline fixture dirs exist before the silence cases run" \
  "$([ -d "$SLBARE" ] && echo 0 || echo 1)"
check "control: the silence fixture bounds the upward .operator walk (hermetic under any TMPDIR)" \
  "$([ -d "$SLBARE/.git" ] && echo 0 || echo 1)"
check "garbage payload renders nothing" \
  "$([ -z "$(cd "$SLBARE" && printf 'NOT JSON{{' | env -u CLAUDE_PROJECT_DIR "$BASH_ABS" "$SL" 2>&1)" ] && echo 0 || echo 1)"
check "empty payload renders nothing" \
  "$([ -z "$(cd "$SLBARE" && printf '' | env -u CLAUDE_PROJECT_DIR "$BASH_ABS" "$SL" 2>&1)" ] && echo 0 || echo 1)"
# No jq AND no python3: PATH_NONE is an empty dir, so even `cat` is gone. This
# is why the segment slurps stdin with the `read` builtin — an external command
# here printed a bash error INTO the statusline (caught in review, pre-release).
check "no parser and no external commands: silent, no stray output" \
  "$([ -z "$(cd "$SLBARE" && sljson SESS-A "$P" | env -u CLAUDE_PROJECT_DIR PATH="$SLNONE" "$BASH_ABS" "$SL" 2>&1)" ] && echo 0 || echo 1)"
# The positive control for all three: silence above must come from an empty
# ledger, NOT from the renderer giving up on an unparseable payload. Same
# garbage stdin, cwd switched to a project that HAS a pending sentinel — the
# segment must appear. Without this, deleting the $PWD fallback entirely would
# leave the three assertions above green.
#
# The sentinel's `session_id:` stamp is decorative HERE and the comment used to
# claim otherwise: on an unparseable payload SESSION is empty, and
# statusline.sh's FOREIGN branch needs a non-empty SESSION, so every sentinel
# falls to the mine/unowned side. Measured — a `session_id: TOTALLY-FOREIGN`
# stamp renders identically. This case validates the $PWD fallback only; the
# ownership partition is exercised by the dev[N] cases above, which supply a
# parseable payload.
SLFB="$(newproj)"; ( cd "$SLFB" && bash "$INIT" >/dev/null 2>&1 )
printf 'session_id: SESS-A\n' > "$SLFB/.operator/pending/fallback-probe"
check "control: the fallback fixture has a sentinel to render" \
  "$([ -f "$SLFB/.operator/pending/fallback-probe" ] && echo 0 || echo 1)"
check "unparseable payload falls back to \$PWD, not to silence (statusline.sh:84)" \
  "$(cd "$SLFB" && printf 'NOT JSON{{' | env -u CLAUDE_PROJECT_DIR "$BASH_ABS" "$SL" 2>/dev/null \
     | LC_ALL=C tr -d '\033' | LC_ALL=C sed 's/\[[0-9]*m//g' \
     | grep -q 'op\[1\]' && echo 0 || echo 1)"
# Removed like every other project dir in this suite. SLFB in particular carries
# a scaffolded .operator/ with a PENDING sentinel, so leaving it behind seeds
# $TMPDIR with exactly the ambient state these three cases were rewritten to
# escape — one run's litter becoming the next run's environment.
rm -rf "$SLBARE" "$SLFB"
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
# the resolver's own charset guard is the validation.
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
# WHAT THE GUARD NO LONGER DOES (0.8.3). Until 0.8.2 this block asserted a
# catalogue: three id SHAPES plus an allowlist of five provider lenses mirroring
# cc-proxy's PROVIDER_IDS. Every one of those cases passed, and the catalogue
# was wrong anyway — measured 2026-08-15 against a live cc-proxy serving 409
# ids, check_routable refused 8 that route fine (`deepseek-v4-flash`,
# `qwen3.8-max`, the bare vendor ids carrying neither a known prefix nor a
# slash). A user who binds one in tiers.env got a refusal naming a shape list
# they never asked about.
#
# The division of labour now: the USER picks the model (tiers.env is their
# file), cc-proxy decides what it routes and what an unknown id does, and
# operator decides neither. A wrong id surfaces at dispatch, from the system
# that actually knows. So these cases assert ACCEPTANCE — each id below is one
# the old guard refused.
for _id in bogus-id deepseek-v4-flash qwen3.8-max bogus:some-model \
           bogus:vendor/model x-ai/grok-4.6 glm-5.3 qwen:; do
  TIERSENV --set "MECHANICAL=$_id" >/dev/null 2>&1; _rc=$?
  check "an id operator does not recognise is accepted ($_id) — the user chooses, cc-proxy routes" \
    "$([ "$_rc" -eq 0 ] && echo 0 || echo 1)"
done
# The negative control, and the whole remaining guard: a MALFORMED field is
# still refused. Whitespace or a quote means the tiers.env line does not parse
# as a model id (an unquoted `MECHANICAL=claude opus` splits) — that is about
# the string, not about which models exist, so it cannot go stale.
TIERSENV --set 'MECHANICAL=claude opus' >/dev/null 2>&1; BADCHAR=$?
check "a whitespace-bearing id is still refused (the field is malformed, F01)" \
  "$([ "$BADCHAR" -ne 0 ] && echo 0 || echo 1)"
BADCHARMSG="$(TIERSENV --set 'MECHANICAL=glm-5"q' 2>&1)"
check "the charset refusal names the charset, not a catalogue of known ids" \
  "$(printf '%s' "$BADCHARMSG" | grep -q 'outside \[A-Za-z0-9._:/@\[\]-\]' && echo 0 || echo 1)"
# Ids that were legal before AND after: the change is one-directional (it only
# widens), so nothing that used to route may have stopped.
for _id in qwen:deepseek-v4-pro openrouter:qwen/x openai/gpt-5 \
           deepseek/deepseek-r1:free qwen/qwen3-max:nitro qwen:a:b 'glm-5.2[1m]'; do
  TIERSENV --set "MECHANICAL=$_id" >/dev/null 2>&1; _rc=$?
  check "a previously-legal id still resolves ($_id) — 0.8.3 only widens" \
    "$([ "$_rc" -eq 0 ] && echo 0 || echo 1)"
done
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
printf 'op-scout=BOGUS\n' > "$RP/.operator/tiers.env"
( cd "$RP" && RENDERENV --show >/dev/null 2>&1 ); G2=$?
check "guard: seat bound to unknown tier is refused (non-zero exit)" "$([ "$G2" -ne 0 ] && echo 0 || echo 1)"
# The renderer carries its own copy of check_routable (validate_plugin's
# check_resolver_renderer_parity pins the two equal). Both halves are asserted
# HERE too: parity proves they are the same, not that either works. Since 0.8.3
# the guard judges WELL-FORMEDNESS only — an id it does not recognise is the
# user's choice and cc-proxy's routing decision, so it renders.
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
# --- F12: STALL_SEC is validated, so a typo cannot silently kill the window ---
# STALL_SEC is env-overridable and lands in `[ "$stall" -gt "$live" ]`. Unvalidated,
# STALL_SEC=abc made that test ERROR (status 2) under the caller's 2>/dev/null, the
# && chain short-circuited, the window never extended, and the segment of a live
# unbalanced run flapped OFF mid-run — measured: the same payload rendered '' with
# STALL_SEC=abc and 'wf 5/12' with STALL_SEC=900. Now: warn on stderr, use 900.
mkjournal 12 5
agequiet "$WFDIR/journal.jsonl" 300
STALLBAD="$(STALL_SEC=abc sljson "$WFSESS" "$WFPROJ" | STALL_SEC=abc "$BASH_ABS" "$SL" 2>/dev/null \
  | LC_ALL=C tr -d '\033' | LC_ALL=C sed 's/\[[0-9]*m//g')"
check "STALL_SEC=abc → the stall window still applies (no silent mid-run flap, F12)" \
  "$([ "$STALLBAD" = "wf 5/12" ] && echo 0 || echo 1)"
# ...and it says so, LOUD, on stderr — the knob is mistyped, not merely defaulted.
# Validated at FILE scope on purpose: the wf caller wraps the function in
# 2>/dev/null, so a warning raised inside it is swallowed and fails silent again.
STALLERR="$(sljson "$WFSESS" "$WFPROJ" | STALL_SEC=abc "$BASH_ABS" "$SL" 2>&1 >/dev/null)"
check "STALL_SEC=abc warns on stderr (fail loud, like the lock budgets) (F12)" \
  "$(printf '%s' "$STALLERR" | grep -q 'STALL_SEC is not a positive integer' && echo 0 || echo 1)"
# A zero/negative-shaped value is refused the same way (0 would collapse the
# window, which is the knob doing the opposite of its job).
STALLZERO="$(sljson "$WFSESS" "$WFPROJ" | STALL_SEC=0 "$BASH_ABS" "$SL" 2>/dev/null \
  | LC_ALL=C tr -d '\033' | LC_ALL=C sed 's/\[[0-9]*m//g')"
check "STALL_SEC=0 → refused, falls back to 900 (F12)" \
  "$([ "$STALLZERO" = "wf 5/12" ] && echo 0 || echo 1)"
# A VALID override still wins: 100 < the 300s quiet period → the run reads dead.
STALLOK="$(sljson "$WFSESS" "$WFPROJ" | STALL_SEC=100 "$BASH_ABS" "$SL" 2>/dev/null \
  | LC_ALL=C tr -d '\033' | LC_ALL=C sed 's/\[[0-9]*m//g')"
check "a VALID STALL_SEC override is still honored (100 → no wf segment) (F12)" \
  "$([ -z "$STALLOK" ] && echo 0 || echo 1)"

# --- F11: the started/result greps run ONCE per render, not twice -------------
# The stall decision and the wf segment needed the identical grep pair over the
# identical file; computing them twice doubled the render's external-process cost
# for no new information. The counts now come back from the liveness check.
# Structural, because the observable output is identical either way: reverting the
# fix re-adds a second `grep -c '"type":"started"'` call site.
SLSTARTED="$(grep -c "grep -c '\"type\":\"started\"'" "$SL")"
check "statusline greps the journal's started lines from ONE site (F11)" \
  "$([ "$SLSTARTED" -eq 1 ] && echo 0 || echo 1)"
# ...and the ratio itself is unchanged by the refactor (the counts still arrive).
mkjournal 7 3
check "the returned counts still render the same ratio 'wf 3/7' (F11)" \
  "$([ "$(render "$WFSESS" "$WFPROJ")" = "wf 3/7" ] && echo 0 || echo 1)"

# --- F9: the stat-flavor probe runs ONCE per render, not once per mtime call --
# Every call site is `$(mtime …)` — a SUBSHELL — so the `_STAT_KIND` assignment
# inside mtime died with it and the flavor was re-detected on every call (~3
# stats each). Measured on a 3-journal session: 9 stat invocations before, 5
# after. The probe is now its own function, called from glob_newest_live_journal's
# own scope. Structural + behavioral: mtime must not contain the probe, and the
# ratio must still render (a broken probe reads every mtime as 0 → nothing live).
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
# The base sha is the dispatch anchor: --since is mandatory (CR2), so every
# --claimed call passes it. Capture once.
BASE_SHA="$(cd "$P" && git rev-parse HEAD)"
runclaims() { ( cd "$P" && bash "$CLAIMS" "$@" ); }   # → exit code, stdout on fd1
# clean_tree: revert ALL changes (staged + unstaged + untracked) to the current
# HEAD so each sub-case starts from a known-clean base. `git checkout .` alone
# misses STAGED changes (a `git rm`/`git mv` stages), so reset --hard + clean.
# State leaks between sub-cases are a real bug class — a case that passes
# against leftover state proves nothing. Also refreshes SINCE_SHA to the current
# HEAD (the --since anchor for working-tree cases); committed cases re-capture.
clean_tree() {
  ( cd "$P" && git reset -q --hard HEAD >/dev/null 2>&1 && git clean -qfd )
  SINCE_SHA="$(cd "$P" && git rev-parse HEAD)"
}

# C1 green: claim exactly the one touched path.
printf 'a2\n' > "$P/a.txt"
runclaims --since "$BASE_SHA" --claimed "a.txt" >/dev/null 2>&1; C1G=$?
check "C1 green: claim matches the single touched path" "$([ "$C1G" = 0 ] && echo 0 || echo 1)"

# C1 fail: an unclaimed touched path (b.txt modified, not claimed). Capture the
# NAMING before reverting — the output line exists only while b.txt is dirty.
printf 'b2\n' > "$P/b.txt"
C1OUT="$(runclaims --since "$BASE_SHA" --claimed "a.txt" 2>/dev/null)"; C1F=$?
clean_tree
check "C1 fail: touched-but-unclaimed path → non-zero" "$([ "$C1F" != 0 ] && echo 0 || echo 1)"
check "C1 fail names 'unclaimed-change'" "$(printf '%s' "$C1OUT" | grep -q unclaimed-change && echo 0 || echo 1)"

# C2 fail: a claimed path with no actual change (phantom-claim). Clean tree,
# claim a.txt + c.txt — neither is changed → both phantom.
C2OUT="$(runclaims --since "$BASE_SHA" --claimed "a.txt c.txt" 2>/dev/null)"; C2F=$?
check "C2 fail: claimed-but-untouched path → non-zero" "$([ "$C2F" != 0 ] && echo 0 || echo 1)"
check "C2 fail names 'phantom-claim'" "$(printf '%s' "$C2OUT" | grep -q phantom-claim && echo 0 || echo 1)"

# C2 green with a directory-prefix claim: 'tests/' satisfied by tests/t.sh.
# tests/ is a PROTECTED path, so this needs --gate-task or C3 (rightly) fails it.
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

# B7.1 — backlog/ is PROTECTED (B7): a worker that edits backlog/tasks/*.md can
# edit the acceptance criteria it is judged against — the F48 vacuous-guard class
# relocated to the plan layer. The WHOLE directory (Q4): a notes file under
# backlog/ is equally off-limits. Touch a path under it, claim it honestly, and
# C3 must still fire gate-trespass (the claim does not authorize the trespass).
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

# B10.1 — ops-backlog.sh --census: prints file/code/code-loc counts, exit 0, and
# counts code files/lines correctly. The <1s-on-10K-files bound (B10 AC1) is
# verified out-of-suite on a synthetic large repo (too big for a unit case);
# this case pins correctness on a small known corpus.
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

# B10.1f (F7) — a CORRUPTED git index must make --census REFUSE, not print a
# confident 'files: 0'. git rev-parse --git-dir passes on a corrupt index (the
# repo exists), but `git ls-files -z` fatals — and under `set -eu` without
# pipefail that fatal was masked by the trailing tr/wc into a silent 0, the
# "silently wrong is worse than refusing" failure the file's own header names.
# pipefail makes the pipeline inherit ls-files' non-zero, and `set -e` aborts.
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

# B10.2 — a filename containing a SPACE must not vanish from the count. Bare
# `xargs` word-splits on any whitespace, so `my file.py` became two bogus args,
# both cats failed, 2>/dev/null swallowed it, and the file dropped out silently:
# measured code-loc 1 on a 2-file/3-line repo. Every stage is NUL-delimited now.
# (PR-review finding, 2026-08-07.)
B10SP="$(newproj)"
( cd "$B10SP" && git init -q -b work && git config user.email t@t && git config user.name t )
printf 'a = 1\nb = 2\n' > "$B10SP/my file.py"     # 2 non-blank lines, spaced name
printf 'c = 3\n'        > "$B10SP/plain.py"       # 1 non-blank line
( cd "$B10SP" && git add -A && git commit -qm base >/dev/null 2>&1 )
B10SPOUT="$(cd "$B10SP" && bash "$SCRIPTS/ops-backlog.sh" --census 2>/dev/null)"
check "B10.2 --census counts a file whose name contains a space (code-loc: 3)" \
  "$(printf '%s' "$B10SPOUT" | grep -q '^code-loc: 3$' && echo 0 || echo 1)"

# B10.4 — a tracked filename containing a NEWLINE must not be miscounted (#29).
# This is the case that `grep -zE` got wrong on BSD/macOS: `-z` there does not
# anchor `$` at the NUL, so the record is still split on newlines internally and
# a name whose FIRST line ends in `.py` matched even though the name ends `.md`.
# Measured before the fix on BSD grep 2.6.0: code-files 2 / code-loc 5 against a
# ground truth of 1 / 2. GNU grep 3.11 answered correctly, which is exactly why
# a Linux-only run could not have caught it — the case must run on macOS.
# Filtering with `git ls-files -- <pathspec>` removes the question entirely:
# git matches whole pathnames, so there is no record-splitting to get wrong.
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

# B10.3 — an unreadable code file must be REPORTED, never silently undercounted.
# A census that prints a confident number over a partial read misinforms exactly
# the B10 decision it exists to inform. Simulated by deleting a tracked file so
# `cat` fails (chmod is not portable under every test runner).
rm -f "$B10SP/plain.py"
B10PART="$(cd "$B10SP" && bash "$SCRIPTS/ops-backlog.sh" --census 2>/dev/null)"
check "B10.3 --census marks an incomplete read PARTIAL rather than printing a confident count" \
  "$(printf '%s' "$B10PART" | grep -q '^code-loc: .*PARTIAL' && echo 0 || echo 1)"

# CHANGED: none — clean working tree, no claims, no trespass.
runclaims --since "$BASE_SHA" --claimed none >/dev/null 2>&1; CNG=$?
check "CHANGED none: clean tree, no claims → exit 0" "$([ "$CNG" = 0 ] && echo 0 || echo 1)"

# T3: --expect-clean + --claimed combined — the real dispatch shape (a clean
# read-only seat, operator still verifies claims). --expect-clean passes, then
# the script falls through to C1/C2/C3. A PHANTOM claim must still fire C2 even
# on a clean tree (the reviewer mutated the fall-through exit 0 and the suite
# stayed green). Clean tree + a claimed-but-untouched path → C2 phantom.
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

# --expect-clean REPORTS ignored state (#23 scope line). The tracked-tree check
# above cannot see a gitignored artifact, which is the exact mechanism by which
# a stale __pycache__ makes a broken commit verify green in-tree and fail in a
# clean checkout of the same commit. The line is report-only: the count moves,
# the exit code does not. Both halves are asserted because a report that cannot
# say 0 is not a count — it is a constant, and a constant guard pins nothing.
# Discriminating: deleting the --ignored=matching read flips both counts to
# empty and the first check fails; making it FAIL instead of report flips ECI2.
runclaims --expect-clean 2>/dev/null | grep -q '{item ignored-state} report: 0 ' && ECI0=0 || ECI0=1
check "--expect-clean reports 0 ignored entries on a tree with none" "$ECI0"
printf '__pycache__/\n' > "$P/.gitignore"
( cd "$P" && git add .gitignore && git commit -qm ignore )
mkdir -p "$P/__pycache__"; printf 'stale\n' > "$P/__pycache__/a.cpython-311.pyc"
runclaims --expect-clean 2>/dev/null | grep -q '{item ignored-state} report: 1 ' && ECI1=0 || ECI1=1
check "--expect-clean counts a gitignored __pycache__ the tracked check cannot see" "$ECI1"
# THREE, NOT ONE. A 0-vs-1 pair is satisfied by a counter stuck at 1, which is
# exactly what shipped in the first draft: `-z` output captured through command
# substitution loses its NUL separators, every record joins onto one line, and
# `grep -c '^!!'` answers 1 for any non-zero count (measured: a 3-entry tree
# reported 1, this repo's 34 reported 0). The fixtures could not see it because
# neither held more than one entry. Any future case here needs >= 2.
printf '__pycache__/\nbuild/\ndist/\n' > "$P/.gitignore"
( cd "$P" && git add .gitignore && git commit -qm ignore3 )
mkdir -p "$P/build" "$P/dist"; : > "$P/build/x"; : > "$P/dist/x"
runclaims --expect-clean 2>/dev/null | grep -q '{item ignored-state} report: 3 ' && ECI3=0 || ECI3=1
check "--expect-clean counts THREE ignored entries as 3 (not a stuck 1)" "$ECI3"
runclaims --expect-clean >/dev/null 2>&1; ECI2=$?
check "--expect-clean stays green on ignored state (report, never fail)" \
  "$([ "$ECI2" = 0 ] && echo 0 || echo 1)"
# A FAILED GIT READ MUST READ `unknown`, NOT `0`. The first draft ran the whole
# pipeline in one substitution and tested the captured string for non-digits —
# unreachable, because `grep -c` on empty input prints "0" and exits 1, so a git
# that died at 128 was indistinguishable from a clean tree. The exit status is
# now captured before any counting. GIT_INDEX_FILE pointing at a non-directory
# is the cheapest reproducible failure; the script must still exit 0 (this is a
# report line, not a gate) and must still print the tracked-tree verdict.
ECIUERR="$( cd "$P" && GIT_INDEX_FILE=/dev/null/nope bash "$CLAIMS" --expect-clean 2>&1 )"; ECIURC=$?
check "a failed git status REFUSES --expect-clean rather than reporting clean" \
  "$(printf '%s' "$ECIUERR" | grep -q 'must not read as a clean tree' && echo 0 || echo 1)"
check "the refusal exits non-zero (the gate must not pass on an unreadable tree)" \
  "$([ "$ECIURC" != 0 ] && echo 0 || echo 1)"
# And it must NOT have claimed the tree was clean on its way out — the failure
# mode being pinned is a green verdict, not merely a missing error.
check "the refusal prints no 'ok: clean' verdict" \
  "$(printf '%s' "$ECIUERR" | grep -q '{item working-tree} ok' && echo 1 || echo 0)"
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
runclaims --since "$BASE_SHA" --claimed "a.txt" >/dev/null 2>&1; UNC=$?
check "untracked file detected as an actual change (C1)" "$([ "$UNC" != 0 ] && echo 0 || echo 1)"

# Charset/traversal discipline on --claimed: '..' traversal is rejected.
runclaims --since "$BASE_SHA" --claimed "../etc" >/dev/null 2>&1; TRV=$?
check "claimed '..' traversal is rejected" "$([ "$TRV" != 0 ] && echo 0 || echo 1)"
# '|' in a claimed path is rejected (would break the list contract).
runclaims --since "$BASE_SHA" --claimed "a.txt|injected" >/dev/null 2>&1; PIP=$?
check "claimed '|' is rejected" "$([ "$PIP" != 0 ] && echo 0 || echo 1)"
# A DOT-DIRECTORY PATH IS CLAIMABLE (#37). The old blanket `.*` reject was a
# TASK-ID rule applied to paths: a task id becomes a filename in pending/ where
# a leading dot hides it from a glob, but a claimed path is only ever compared
# against git's output. Six tracked files here start with a dot, and a worker
# that touched one had no green path — claiming it died at exit 2, omitting it
# fired C1 on the same path. Both halves are pinned: the claim must PASS, and
# the ledger claim it was conflated with must still be refused.
clean_tree
mkdir -p "$P/.github/workflows"; printf 'name: v\n' > "$P/.github/workflows/w.yml"
( cd "$P" && git add -A && git commit -qm dotdir )
DOTSHA="$(cd "$P" && git rev-parse HEAD)"
printf 'name: v2\n' > "$P/.github/workflows/w.yml"
runclaims --since "$DOTSHA" --claimed ".github/workflows/w.yml" >/dev/null 2>&1; DOTC=$?
check "#37 a claimed dot-directory path is accepted (.github/…)" \
  "$([ "$DOTC" = 0 ] && echo 0 || echo 1)"
# The negative control: not claiming it must still fire C1, or the case above
# would pass against a gate that simply stopped checking.
runclaims --since "$DOTSHA" --claimed "none" >/dev/null 2>&1; DOTN=$?
check "#37 the same path unclaimed still fires C1" \
  "$([ "$DOTN" != 0 ] && echo 0 || echo 1)"
# And the rule that survives: the ledger is an expected side-effect of every
# dispatch, so claiming it as your own work stays a refusal.
DOTLED="$(runclaims --since "$DOTSHA" --claimed ".operator/VERDICTS.md" 2>&1)"; DOTL=$?
check "#37 a claimed .operator/ path is still refused" \
  "$([ "$DOTL" != 0 ] && echo 0 || echo 1)"
check "#37 the refusal names the ledger, not a dot" \
  "$(printf '%s' "$DOTLED" | grep -q 'under .operator/' && echo 0 || echo 1)"
clean_tree

# CR2: --since is MANDATORY (a HEAD default made a committed gate-trespass
# invisible). Without --since, the gate must die loud, not default to HEAD.
runclaims --claimed none >/dev/null 2>&1; NOSINCE=$?
check "--since is mandatory (absent → die, no HEAD default)" "$([ "$NOSINCE" != 0 ] && echo 0 || echo 1)"
# And the reason it's mandatory: a worker that COMMITS its change must NOT evade
# the diff. Commit a.txt's modification since base, claim none → C1 catches it.
clean_tree
printf 'a2\n' > "$P/a.txt"
( cd "$P" && git add -A && git commit -qm second )
runclaims --since "$BASE_SHA" --claimed none >/dev/null 2>&1; COMMIT=$?
check "a COMMITTED change since base is caught (--since <base>, not HEAD)" "$([ "$COMMIT" != 0 ] && echo 0 || echo 1)"
clean_tree

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
DELOUT="$(runclaims --since "$BASE_SHA" --claimed 'scripts/ops-verdict.sh' 2>/dev/null)"; DEL=$?
check "F-A2 setup: the deleted gate CLI is in git's view" \
  "$([ -n "$DELVIEW" ] && echo 0 || echo 1)"
check "C3 fires on a DELETED gate CLI (F-A2 attack; pathname-expansion fix)" \
  "$([ "$DEL" != 0 ] && echo 0 || echo 1)"
check "deletion names 'gate-trespass'" \
  "$(printf '%s' "$DELOUT" | grep -q gate-trespass && echo 0 || echo 1)"
clean_tree

# Combined status codes must not glue the XY chars to the path (REFUTED #2). An
# earlier allowlist missed AM/AD/MD/RD/T/etc., so "{item AM feature.txt}" — a
# garbage item that defeats C1/C3 and the ledger exemption. These reproduce the
# exact shapes the verifier caught.
# AM: staged-add then working-modify. Claim it → must be green (one real path).
printf 'a\n' > "$P/feature.txt"; ( cd "$P" && git add feature.txt >/dev/null 2>&1 )
printf 'b\n' >> "$P/feature.txt"
AMOUT="$(runclaims --since "$SINCE_SHA" --claimed 'feature.txt' 2>/dev/null)"; AM=$?
check "AM (added+modified) claimed → green, not a glued 'AM feature.txt' item" \
  "$([ "$AM" = 0 ] && printf '%s' "$AMOUT" | grep -qv '{item AM' && echo 0 || echo 1)"
clean_tree

# AD: staged-add then working-DELETE of a gate CLI — the C3-evasion repro. The
# status is 'AD scripts/ops-verdict.sh' (index-only; not in git diff HEAD), so
# porcelain is the only source, and the glued 'AD ' must be stripped for C3.
printf 'evil\n' > "$P/scripts/ops-verdict.sh"
( cd "$P" && git add scripts/ops-verdict.sh >/dev/null 2>&1 )
rm -f "$P/scripts/ops-verdict.sh"
ADOUT="$(runclaims --since "$SINCE_SHA" --claimed 'scripts/ops-verdict.sh' 2>/dev/null)"; AD=$?
check "AD (added+deleted gate CLI) fires C3 gate-trespass" \
  "$([ "$AD" != 0 ] && printf '%s' "$ADOUT" | grep -q gate-trespass && echo 0 || echo 1)"
clean_tree

# A STAGED ledger write must stay exempt from --expect-clean. The glued-prefix
# bug made '{item AM .operator/...}' fail the ledger-path exemption.
( cd "$P" && bash "$INIT" >/dev/null 2>&1 )
printf 'row\n' >> "$P/.operator/DECISIONS.md"; ( cd "$P" && git add .operator/DECISIONS.md >/dev/null 2>&1 )
printf 'more\n' >> "$P/.operator/DECISIONS.md"
runclaims --expect-clean >/dev/null 2>&1; STEC=$?
check "staged ledger write stays exempt from --expect-clean (no glued AM)" \
  "$([ "$STEC" = 0 ] && echo 0 || echo 1)"
clean_tree

# A path WITH A SPACE is one item, not shredded. The first version word-split
# `my file.txt` into `my` + `file.txt`. Untracked (so porcelain -z must carry it).
printf 'x\n' > "$P/my file.txt"
SCOUT="$(runclaims --since "$SINCE_SHA" --claimed none 2>/dev/null)"
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
MVOUT="$(runclaims --since "$SINCE_SHA" --claimed 'hooks/' --gate-task 2>/dev/null)"; MV=$?
check "F-A2 rename setup: the rename is in git's view" \
  "$([ -n "$MVVIEW" ] && echo 0 || echo 1)"
check "rename: hooks/ claimed + --gate-task → green (both paths recognized)" "$([ "$MV" = 0 ] && echo 0 || echo 1)"
check "rename does not emit a garbage '->' item" \
  "$(printf '%s' "$MVOUT" | grep -qv '{item ->}' && echo 0 || echo 1)"
clean_tree

# Untracked file inside an UNTRACKED directory: --untracked-files=all must see
# the file, not just the dir. (No --untracked-files=all → only 'docs/'.)
mkdir -p "$P/docs/new"; printf 'm\n' > "$P/docs/new/a.md"
runclaims --since "$SINCE_SHA" --claimed "docs/new/a.md" >/dev/null 2>&1; UTD=$?
check "untracked file in untracked dir is matched (--untracked-files=all)" "$([ "$UTD" = 0 ] && echo 0 || echo 1)"
clean_tree

# Leading-dot claimed path is rejected (the first version's comment promised it,
# the code did not implement it — review REFUTED, doc/code divergence).
runclaims --since "$SINCE_SHA" --claimed ".hidden" >/dev/null 2>&1; DOT=$?
check "leading-dot claimed path rejected (doc/code divergence fix)" "$([ "$DOT" != 0 ] && echo 0 || echo 1)"

# Green run emits the SSSF 'what was verified' evidence line.
GE="$(runclaims --since "$SINCE_SHA" --claimed none 2>/dev/null)"
check "green run emits a diff-matches-claims ok line" "$(printf '%s' "$GE" | grep -q 'diff-matches-claims} ok' && echo 0 || echo 1)"

# ops-claims does NOT read pending/ (not a sentinel reader): confirm it carries
# no sentinel-reader code path by checking it ignores a planted sentinel.
mkdir -p "$P/.operator/pending"; printf 'session_id: OTHER\n' > "$P/.operator/pending/planted"
runclaims --since "$SINCE_SHA" --claimed none >/dev/null 2>&1; NPD=$?
check "ops-claims ignores .operator/pending (not a sentinel reader)" "$([ "$NPD" = 0 ] && echo 0 || echo 1)"

# The green line's COUNT is what an operator cites into a verdict row, so it
# must count what C1 adjudicated — not the ledger paths C1 exempted (issue #63).
# The bug reported "7 changed path(s) all claimed" for ONE claimed path and grew
# with every verdicts.d/ fragment: an inflated number, banked as evidence.
# THREE ledger paths here on purpose — with one, an off-by-N is indistinguishable
# from an off-by-one, and the count could still be wrong in a way this case
# cannot see.
clean_tree
mkdir -p "$P/.operator/verdicts.d"
printf '| x | c | e | PASS |\n' > "$P/.operator/VERDICTS.md"
printf '| x | c | e | PASS |\n' > "$P/.operator/verdicts.d/S1.md"
printf '| y | c | e | PASS |\n' > "$P/.operator/verdicts.d/S2.md"
printf 'w\n' > "$P/worker.txt"
CNTOUT="$(runclaims --since "$SINCE_SHA" --claimed "worker.txt" 2>/dev/null)"; CNTRC=$?
check "green count excludes exempted ledger paths (#63)" "$([ "$CNTRC" = 0 ] && printf '%s' "$CNTOUT" | grep -q 'ok: 1 changed path(s) all claimed' && echo 0 || echo 1)"
check "the exempted ledger paths are reported, not dropped (#63)" "$(printf '%s' "$CNTOUT" | grep -q '3 .operator/ ledger path(s) exempt' && echo 0 || echo 1)"
# NEGATIVE CONTROL — the count must not become a mute button: with no ledger
# path dirty, the parenthetical is absent entirely rather than reading "0".
clean_tree
printf 'w2\n' > "$P/worker.txt"
NOLED="$(runclaims --since "$SINCE_SHA" --claimed "worker.txt" 2>/dev/null)"
check "no ledger change → no exempt note at all (not '0 exempt')" "$(printf '%s' "$NOLED" | grep -q 'all claimed; no phantom claims$' && echo 0 || echo 1)"
# …and the GATE itself is untouched by the counting change: an unclaimed real
# path still fails while the ledger paths stay exempt.
printf 'u\n' > "$P/unclaimed.txt"
printf '| z | c | e | PASS |\n' > "$P/.operator/verdicts.d/S3.md"
runclaims --since "$SINCE_SHA" --claimed "worker.txt" >/dev/null 2>&1; GRC=$?
check "counting change does not weaken C1 (unclaimed path still fails)" "$([ "$GRC" != 0 ] && echo 0 || echo 1)"
clean_tree
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

# --- T2: an UNOWNED HANDOFF-MARK clears every session (the third partition arm) ---
# A mark with NO [sid:] tag is "unowned" and clears every session's deviations
# (mirrors the unowned-sentinel rule). The reviewer mutated this branch to a no-op
# and the suite stayed green — it is now asserted. Set up a mine deviation, clear
# with an UNTAGGED mark, confirm Stop allowed.
printf '2026-08-04 | e.t | DEVIATION | [sid:%s] mine | r\n' "$SID" > "$DEC"
printf '2026-08-04 | e | HANDOFF-MARK | 2026-08-04T00:00:00Z | presented (no sid)\n' >> "$DEC"
payload | bash "$HOOK" >/dev/null 2>&1; UM=$?
check "an untagged HANDOFF-MARK clears every session (third partition arm)" "$([ "$UM" = 0 ] && echo 0 || echo 1)"
# And a DIFFERENT session is also cleared by the untagged mark.
printf '{"session_id":"OTHER-SESS","stop_hook_active":false,"cwd":"%s"}' "$P" | bash "$HOOK" >/dev/null 2>&1; UM2=$?
check "untagged mark clears a DIFFERENT session too (unowned = clears all)" "$([ "$UM2" = 0 ] && echo 0 || echo 1)"

# --- T1: a SYMLINKED DECISIONS.md is not scanned (F65 class, both readers) -----
# A planted symlink to an attacker file with a forged DEVIATION must NOT feed the
# scan. The hook fails OPEN (absent-ledger class); the bar renders nothing.
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
# DECISIONS.md is append-forever and the charter asks for measurements/baselines
# in the what-cell, so multi-KB rows are the EXPECTED shape of an honest ledger.
# read -n 512 FILLS on such a row. The old per-chunk guard hard-coded the count
# to 1 and RETURNED, which (a) blocked Stop on a ledger with NO deviation at all
# (phantom block) and (b) left the gate BLIND to a real deviation after the long
# row, the failure presenting as a false positive. Worse, any HANDOFF-MARK past
# the first long row was unreachable, so --mark-handoff could never clear it.
# Fix: accumulate cap-filling chunks into one logical row before classifying.
# LONG = 1200-byte what-cell (3 read chunks: 512+512+176).
LONG="$(python3 -c 'print("x"*1200)')"
# ARM A — a long DEFERRED-VERDICT (record kind, not gated) and NO gated deviation.
# Pre-fix: phantom block (exit 2). Post-fix: no gated deviation → exit 0.
{ printf '# Decisions\n'
  printf '2026-08-05 | e.t | DEFERRED-VERDICT | %s | r\n' "$LONG"; } > "$DEC"
payload | bash "$HOOK" >/dev/null 2>&1; LR0=$?
check "long record row, no gated deviation → Stop allowed (no phantom block, #9)" \
  "$([ "$LR0" = 0 ] && echo 0 || echo 1)"
# ARM B — a long record row, THEN a genuine mine DEVIATION after it. Pre-fix the
# scan aborted at the long row and counted the DEVIATION only by accident of the
# hardcoded 1; post-fix the DEVIATION is genuinely counted → blocks.
{ printf '# Decisions\n'
  printf '2026-08-05 | e.t | DEFERRED-VERDICT | %s | r\n' "$LONG"
  printf '2026-08-05 | e.t | DEVIATION | [sid:%s] real unpresented | r\n' "$SID"; } > "$DEC"
payload | bash "$HOOK" >/dev/null 2>&1; LR1=$?
check "long record row then mine DEVIATION after it → DEVIATION counted (#9)" \
  "$([ "$LR1" = 2 ] && echo 0 || echo 1)"
# ARM C — a long record row, then a mine DEVIATION, then a mine HANDOFF-MARK past
# the long row. Pre-fix the mark was unreachable → stuck block forever (unkillable
# phantom). Post-fix the mark is reached and clears → exit 0.
{ printf '# Decisions\n'
  printf '2026-08-05 | e.t | DEFERRED-VERDICT | %s | r\n' "$LONG"
  printf '2026-08-05 | e.t | DEVIATION | [sid:%s] chose X | r\n' "$SID"
  printf '2026-08-05 | e | HANDOFF-MARK | [sid:%s] 2026-08-05T00:00:00Z | presented\n' "$SID"; } > "$DEC"
payload | bash "$HOOK" >/dev/null 2>&1; LR2=$?
check "mine DEVIATION + mine mark, both past a long row → mark clears (#9)" \
  "$([ "$LR2" = 0 ] && echo 0 || echo 1)"
# ARM D — the DEVIATION ITSELF is the long row (>512 bytes in the what-cell).
# Pre-fix: the kind parse ran on the first 512-byte chunk; the chunk held the
# date+task+kind, so it was parsed, but a continuation could forge a kind. Post-fix
# the whole row accumulates and is classified once. A long mine DEVIATION blocks.
{ printf '# Decisions\n'
  printf '2026-08-05 | e.t | DEVIATION | [sid:%s] %s | r\n' "$SID" "$LONG"; } > "$DEC"
payload | bash "$HOOK" >/dev/null 2>&1; LR3=$?
check "a DEVIATION whose what-cell exceeds 512 bytes still blocks (#9)" \
  "$([ "$LR3" = 2 ] && echo 0 || echo 1)"
# ARM E — foreign DEVIATION in a long row → never blocks (continuation does not
# smuggle the foreign tag into a countable position).
{ printf '# Decisions\n'
  printf '2026-08-05 | e.t | DEVIATION | [sid:SESS-B-OTHER] %s | r\n' "$LONG"; } > "$DEC"
payload | bash "$HOOK" >/dev/null 2>&1; LR4=$?
check "long foreign DEVIATION → never blocks (#9)" \
  "$([ "$LR4" = 0 ] && echo 0 || echo 1)"
# Continuation cannot forge a kind: a chunk boundary landing mid-token must not
# synthesize DEVIATION. Pad the what-cell so the KIND cell of a HANDOFF-MARK's
# continuation lands across a 512 boundary — it must still classify correctly.
{ printf '# Decisions\n'
  printf '2026-08-05 | e.t | DEVIATION | [sid:%s] chose X | r\n' "$SID"
  printf '2026-08-05 | e.t | DEFERRED-VERDICT | %s | r\n' "$LONG"
  printf '2026-08-05 | e | HANDOFF-MARK | [sid:%s] 2026-08-05T00:00:00Z | presented\n' "$SID"; } > "$DEC"
payload | bash "$HOOK" >/dev/null 2>&1; LR5=$?
check "kind not forgeable across a continuation boundary (#9)" \
  "$([ "$LR5" = 0 ] && echo 0 || echo 1)"

# --- the bar mirror of #9: a long mine DEVIATION is counted, not skipped ----
# Pre-fix the statusline's array read split a long row across entries; the
# continuation chunks failed the " | " row test and were skipped → under-count.
DEVDEC2="$DEVPROJ/.operator/DECISIONS.md"
{ printf '# Decisions\n'
  printf '2026-08-05 | e.t | DEVIATION | [sid:SESS-A] %s | r\n' "$LONG"; } > "$DEVDEC2"
LRBAR="$(printf '{"session_id":"SESS-A","cwd":"%s","workspace":{"project_dir":"%s"}}' "$DEVPROJ" "$DEVPROJ" \
  | "$BASH_ABS" "$SCRIPTS/statusline.sh" 2>/dev/null | LC_ALL=C tr -d '\033' | LC_ALL=C sed 's/\[[0-9]*m//g')"
check "statusline counts a long (>512B) mine DEVIATION as dev[1] (#9)" \
  "$(printf '%s' "$LRBAR" | grep -q 'dev\[1\]' && echo 0 || echo 1)"
# A long row with NO trailing newline: read returns non-zero on EOF but still
# holds the final chunk. Without `|| [ -n "$line" ]` the bar dropped that chunk
# and under-counted — the mirror parity the hook's own flush guard enforces
# (Copilot review on #10). printf '%s' writes no trailing newline.
printf '# Decisions\n2026-08-05 | e.t | DEVIATION | [sid:SESS-A] %s | r' "$LONG" > "$DEVDEC2"
LRBAR2="$(printf '{"session_id":"SESS-A","cwd":"%s","workspace":{"project_dir":"%s"}}' "$DEVPROJ" "$DEVPROJ" \
  | "$BASH_ABS" "$SCRIPTS/statusline.sh" 2>/dev/null | LC_ALL=C tr -d '\033' | LC_ALL=C sed 's/\[[0-9]*m//g')"
check "statusline counts a long mine DEVIATION with no trailing newline (#10 review)" \
  "$(printf '%s' "$LRBAR2" | grep -q 'dev\[1\]' && echo 0 || echo 1)"

# --- F10: the bar's NUL probe reads the TAIL WINDOW, never the whole ledger ---
# The probe sat BEFORE the O(tail) reverse scan and read the whole file (capped
# 4096x512B = 2MB), which re-introduced exactly the O(n) cost the tail scan
# exists to avoid — measured ~200x the tail's own cost on a 658KB ledger, on a
# ~300ms timer. Only rows inside the window can change the count, so probing the
# window is equivalent for everything the bar reports.
# STRUCTURAL first: a timing assertion is flaky under load, but re-adding the
# whole-file redirect is a textual regression. Both probe/scan reads must be fed
# by `tail`; no `done < "$f"` remains in scan_deviations_bar.
check "no whole-file read survives in scan_deviations_bar (F10)" \
  "$(awk '/^scan_deviations_bar\(\)/{ins=1} ins && /done < "\$f"/{bad=1} /^}$/{ins=0} END{exit bad?1:0}' \
     "$SCRIPTS/statusline.sh" && echo 0 || echo 1)"
# shellcheck disable=SC2016  # `\$f` is the LITERAL text being grepped for in the
# renderer's source; expanding it here would search for this suite's own $f.
check "the bar's NUL probe is fed by tail -n 256, like the scan (F10)" \
  "$([ "$(grep -c 'done < <(tail -n 256 "\$f" 2>/dev/null)' "$SCRIPTS/statusline.sh")" -eq 2 ] && echo 0 || echo 1)"
# SEMANTIC: a NUL inside the tail window still classifies the ledger as corrupt,
# so no dev[ renders — the fail-toward-silence rule is unchanged where observable.
F10DEC="$DEVPROJ/.operator/DECISIONS.md"
{ printf '# Decisions\n'
  printf '2026-08-05 | e.t | DEVIATION | [sid:SESS-A] mine | r\n'
  printf '2026-08-05 | e.t | DEVIATION | [sid:SESS-A] nul\000here | r\n'; } > "$F10DEC"
F10NUL="$(printf '{"session_id":"SESS-A","cwd":"%s","workspace":{"project_dir":"%s"}}' "$DEVPROJ" "$DEVPROJ" \
  | "$BASH_ABS" "$SCRIPTS/statusline.sh" 2>/dev/null | LC_ALL=C tr -d '\033' | LC_ALL=C sed 's/\[[0-9]*m//g')"
check "a NUL inside the tail window still renders no dev[ (F10 semantics kept)" \
  "$(printf '%s' "$F10NUL" | grep -q 'dev\[' || echo 0)"
# ...and a LARGE clean ledger still counts exactly the in-window deviations: the
# count is the same one the pre-fix whole-file probe produced (measured: dev[1]).
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
# A verdict with no open sentinel is either never-armed (→ GATE-EXCEPTION) or
# a duplicate/amending row (→ warning). A never-armed verdict with no --owner is
# refused: the GATE-EXCEPTION must carry a [sid:] tag. The prior-row scan reads
# the session fragment, bounded by FRAG_MAX_BYTES. See backlog-charter.md §8c.
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
# Set up a session with a fragment, then pad it past the cap and verdict again.
( cd "$P" && bash "$VERDICT" na-g16a crit ev PASS --owner "$S" >/dev/null 2>&1 )
FRAG="$P/.operator/verdicts.d/$S.md"
# Pad the fragment past FRAG_MAX_BYTES (8 MiB) with a single long non-row line.
{ cat "$FRAG"; printf '%s' "$(printf 'x%.0s' $(seq 1 9000000))"; } > "$FRAG.pad" && mv "$FRAG.pad" "$FRAG"
( cd "$P" && bash "$VERDICT" na-g16b crit ev PASS --owner "$S" 2>/dev/null ); G16=$?
check "G1.6 oversized-fragment verdict exits 0 (not wedged)" "$([ "$G16" -eq 0 ] && echo 0 || echo 1)"

# G1.7 — long-evidence duplicate must not be misfiled as never-armed (issue-#9
# class: the prior-row scan skips a chunk that starts the row). A 700-byte
# evidence cell splits the fragment row across read chunks; the chunk carrying
# the `| <id> |` prefix must be matched, not skipped. Repro from the G3 review.
# Fresh project + session: G1.6 above left SESS-G1's fragment padded to 9MB
# (past FRAG_MAX_BYTES), which would make THIS scan refuse and false-positive —
# so this case must not inherit that state.
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

# G1.8 — a never-armed verdict writes EXACTLY ONE GATE-EXCEPTION however many
# times it is amended. The exception is the bypass record; a second one on every
# amendment would make the deviation gate cry wolf, and the operator would learn
# to wave it through — the failure mode issue #9 already taught this repo once.
#
#
# The crash-window residual this case used to disclaim is CLOSED (#14, 0.8.4) —
# by write ORDER, not by a guard: the exception is appended before the row, so
# the crash-interrupted state is an exception with no row (a retry completes it)
# instead of a row with no exception (a retry misreads it as an amendment). The
# reverted guard stays reverted for the reason G1.7 pins: "row without exception"
# cannot distinguish crash-interrupted from ordinary-amended. G1.10 below pins
# the order itself.
P="$(newproj)"; ( cd "$P" && bash "$INIT" >/dev/null 2>&1 )
S8="SESS-G18"
( cd "$P" && bash "$VERDICT" g1t8 crit ev PASS --owner "$S8" >/dev/null 2>&1 )
G18_FIRST="$(grep -cE '^[0-9]{4}.*GATE-EXCEPTION' "$P/.operator/DECISIONS.md" || true)"
( cd "$P" && bash "$VERDICT" g1t8 crit2 ev2 PASS --owner "$S8" >/dev/null 2>&1 )
( cd "$P" && bash "$VERDICT" g1t8 crit3 ev3 PASS --owner "$S8" >/dev/null 2>&1 )
G18_AFTER="$(grep -cE '^[0-9]{4}.*GATE-EXCEPTION' "$P/.operator/DECISIONS.md" || true)"
check "G1.8 never-armed verdict writes exactly one GATE-EXCEPTION across amendments" \
  "$([ "${G18_FIRST:-0}" = "1" ] && [ "${G18_AFTER:-0}" = "1" ] && echo 0 || echo 1)"

# G1.10 (#14 / U2) — the GATE-EXCEPTION is written BEFORE the row, and this case
# pins the ORDER rather than the presence. Presence was already covered by G1.2;
# what U2 measured is that the order decides which half survives a crash landing
# between the two appends:
#
#   row first  → a row with no exception. The retry sees a prior row for an id
#                with no sentinel, calls it `duplicate`, and the bypass keeps its
#                PASS row while LOSING its audit line. Exactly what G1 exists to
#                prevent, via a crash instead of a swallowed error.
#   exception first → an exception with no row. The retry appends the row; worst
#                case the exception is duplicated, which is legible.
#
# Both appends sit under one lock, so this is a crash window, not a race — which
# is why the assertion is about ORDER and not about any concurrency behaviour.
# How that order is asserted is decided below; the short version is that it is
# read off the source, because the two files carry no usable ordering evidence.
#
# Mutation-checked: swap the two writes in ops-verdict.sh and this case goes red.
P="$(newproj)"; ( cd "$P" && bash "$INIT" >/dev/null 2>&1 )
S10="SESS-G110"
( cd "$P" && bash "$VERDICT" g1t10 crit ev PASS --owner "$S10" >/dev/null 2>&1 )
# The exception must exist AND the ledger row must exist — asserting order alone
# would pass on a run that wrote neither.
G110_X="$(grep -cE 'GATE-EXCEPTION.*g1t10' "$P/.operator/DECISIONS.md" 2>/dev/null || true)"
G110_R="$(grep -cE '^\| g1t10 \|' "$P/.operator/VERDICTS.md" 2>/dev/null || true)"
check "G1.10 a never-armed verdict writes both the exception and the row" \
  "$([ "${G110_X:-0}" = "1" ] && [ "${G110_R:-0}" = "1" ] && echo 0 || echo 1)"
# The order, read off the source rather than the filesystem: mtime granularity on
# some filesystems is coarse enough that two appends microseconds apart compare
# equal, which would make an mtime assertion pass on BOTH orders — a vacuous
# guard (#21). The write block is the artifact; assert on it.
G110_XL="$(grep -nF 'sid:%s] verdict %s recorded without an open sentinel' "$SCRIPTS/ops-verdict.sh" | tail -1 | cut -d: -f1)"
# shellcheck disable=SC2016  # the single quotes are the point: grep -F searches
# for the LITERAL text `"$ROW" >> "$VERDICTS"` in ops-verdict.sh's source. Expanding
# it here would search for this suite's own (empty) $ROW and find nothing, and the
# `-n` presence guard below would then fail the case rather than the file.
G110_RL="$(grep -nF '"$ROW" >> "$VERDICTS"' "$SCRIPTS/ops-verdict.sh" | tail -1 | cut -d: -f1)"
check "G1.10 control: both write sites are locatable in ops-verdict.sh" \
  "$([ -n "$G110_XL" ] && [ -n "$G110_RL" ] && echo 0 || echo 1)"
check "G1.10 the GATE-EXCEPTION append precedes the ledger-row append (#14)" \
  "$([ -n "$G110_XL" ] && [ -n "$G110_RL" ] && [ "$G110_XL" -lt "$G110_RL" ] && echo 0 || echo 1)"

# G1.9 — the retro-gate covers BOTH closing paths. --defer retires a task exactly
# as a verdict does, so deferring an id that was never opened is an unarmed close
# and earns the same GATE-EXCEPTION. Before this, a session could retire
# arbitrary ids via --defer with no trace while the identical act through the
# PASS/FAIL path was recorded — an asymmetry a bypass would find.
# (PR-review finding, 2026-08-07.)
P="$(newproj)"; ( cd "$P" && bash "$INIT" >/dev/null 2>&1 )
S9="SESS-G19"
( cd "$P" && bash "$VERDICT" g1t9 --defer "blocked" --owner "$S9" >/dev/null 2>&1 )
G19_NA="$(grep -cE '^[0-9]{4}.*GATE-EXCEPTION' "$P/.operator/DECISIONS.md" || true)"
check "G1.9 --defer of a never-opened task writes a GATE-EXCEPTION" \
  "$([ "${G19_NA:-0}" = "1" ] && echo 0 || echo 1)"
# Regression: deferring a properly ARMED task is unchanged, and needs no --owner
# (the sentinel supplies it) — the narrow scope of the refusal above is asserted.
( cd "$P" && bash "$TASK" g1t9b --owner "$S9" >/dev/null 2>&1 )
( cd "$P" && bash "$VERDICT" g1t9b --defer "reason" >/dev/null 2>&1 ); G19ARC=$?
G19_ARMED="$(grep -cE '^[0-9]{4}.*GATE-EXCEPTION' "$P/.operator/DECISIONS.md" || true)"
check "G1.9 --defer of an armed task exits 0 and writes no GATE-EXCEPTION" \
  "$([ "$G19ARC" -eq 0 ] && [ "${G19_ARMED:-0}" = "1" ] && echo 0 || echo 1)"
# A never-armed defer with no --owner is REFUSED: an untagged GATE-EXCEPTION is
# unowned, and unowned blocks every session (the cross-session wedge 0.4.0 removed).
( cd "$P" && bash "$VERDICT" g1t9c --defer "x" >/dev/null 2>&1 ); G19NRC=$?
check "G1.9 --defer never-armed without --owner is refused" \
  "$([ "$G19NRC" -ne 0 ] && echo 0 || echo 1)"

rm -rf "$P"

########################################################################
echo "-- Case: G2 arm gate — PreToolUse blocks the first unarmed write (opt-in)"
# The gate is one or two stats on .operator/.armed/<sid>, and its polarity is
# the OPPOSITE of the Stop hook's: every infrastructure failure fails OPEN,
# because an unwritable project cannot repair itself. See backlog-charter.md §8c.

# Feed the arm hook a PreToolUse payload; captures exit code (ARC) and stderr (AERR).
run_armhook() { # run_armhook <cwd> <session-id> [restricted-PATH]
  local cwd="$1" sid="$2" rpath="${3:-}" json errf
  json="$(sed -e "s|<tmp>|$cwd|g" -e "s|<sid>|$sid|g" "$FIXTURES/pretooluse-write.json")"
  errf="$(mktemp)"
  if [ -n "$rpath" ]; then
    printf '%s' "$json" | PATH="$rpath" "$BASH_ABS" "$ARMHOOK" 2>"$errf"
  else
    printf '%s' "$json" | "$BASH_ABS" "$ARMHOOK" 2>"$errf"
  fi
  ARC=$?
  AERR="$(cat "$errf")"; rm -f "$errf"
}

P="$(newproj)"; ( cd "$P" && bash "$INIT" >/dev/null 2>&1 )
S="SESS-G2"

# G2.1 — armgate.on absent: the gate does not exist for this project.
run_armhook "$P" "$S"
check "G2.1 armgate.on absent → exit 0 (opt-in default)" "$([ "$ARC" -eq 0 ] && echo 0 || echo 1)"
check "G2.1 armgate.on absent → no stderr" "$([ -z "$AERR" ] && echo 0 || echo 1)"

# G2.2 — gate on, no marker: deny, and the message names both recovery commands.
: > "$P/.operator/armgate.on"
run_armhook "$P" "$S"
check "G2.2 gate on + unarmed → exit 2" "$([ "$ARC" -eq 2 ] && echo 0 || echo 1)"
check "G2.2 stderr names ops-task.sh … --owner $S" \
  "$(printf '%s' "$AERR" | grep -q "ops-task.sh <task-id> --owner $S" && echo 0 || echo 1)"
check "G2.2 stderr names the --exempt path" \
  "$(printf '%s' "$AERR" | grep -q -- '--exempt' && echo 0 || echo 1)"

# G2.3 — the derived marker arms the session.
mkdir -p "$P/.operator/.armed"; : > "$P/.operator/.armed/$S"
run_armhook "$P" "$S"
check "G2.3 .armed/\$S present → exit 0" "$([ "$ARC" -eq 0 ] && echo 0 || echo 1)"
rm -f "$P/.operator/.armed/$S"

# G2.4 — the granted (exempt) marker arms independently of the derived one.
: > "$P/.operator/.armed/$S.exempt"
run_armhook "$P" "$S"
check "G2.4 only .armed/\$S.exempt present → exit 0" "$([ "$ARC" -eq 0 ] && echo 0 || echo 1)"
rm -f "$P/.operator/.armed/$S.exempt"

# G2.5 — no .operator/ above the payload cwd: fail OPEN on missing state.
Q="$(newproj)"
run_armhook "$Q" "$S"
check "G2.5 no .operator/ above cwd → exit 0 (fails open)" "$([ "$ARC" -eq 0 ] && echo 0 || echo 1)"
rm -rf "$Q"

# G2.6 — no JSON parser on PATH: fail OPEN, silently. The gate is still ON and
# the session is still unarmed, so a fail-CLOSED hook would exit 2 here.
run_armhook "$P" "$S" "/nonexistent"
check "G2.6 no JSON parser → exit 0 (fails open)" "$([ "$ARC" -eq 0 ] && echo 0 || echo 1)"
check "G2.6 no JSON parser → silent (no stderr before every edit)" \
  "$([ -z "$AERR" ] && echo 0 || echo 1)"

# G2.11 — `.armed` EXISTS but is not a usable directory → fail OPEN. This is the
# unwritable-and-UNREPAIRABLE case: with .armed unusable every marker write in
# the repo fails, so all three repairs the deny message prints are dead
# (ops-task.sh/ops-adopt.sh swallow their marker write and report success while
# changing nothing; --exempt dies after its ledger row lands). A legitimately
# armed session was denied every file mutation with no in-band way out.
# Measured before the fix: rc=2. (PR-review finding, 2026-08-07.)
#
# Polarity matters in BOTH directions, so both are asserted: an unusable .armed
# fails OPEN, an ABSENT .armed still DENIES (the honest never-armed case).
( cd "$P/.operator" && rm -rf .armed && : > .armed )      # regular file, not a dir
run_armhook "$P" "$S"
check "G2.11 .armed exists but is not a usable directory → exit 0 (fails open)" \
  "$([ "$ARC" -eq 0 ] && echo 0 || echo 1)"
( cd "$P/.operator" && rm -f .armed )                      # absent again
run_armhook "$P" "$S"
check "G2.11 .armed absent + unarmed session → still exit 2 (absence is not an infra fault)" \
  "$([ "$ARC" -eq 2 ] && echo 0 || echo 1)"

# G2.12 — the OTHER unusable modes, and the property the guard's inertness rests
# on (issue #19). The `[ ! -x ]` half of the guard is INERT for uid 0 (root's
# `[ -x ]` on a chmod 000 dir is TRUE), so these cases pin the half that does
# work on every uid — `[ ! -d ]` — plus the reason the inert half is tolerable.
#
# A DANGLING SYMLINK is absence, not unusability: `[ -e ]` is false on a broken
# link, so it must reach the ordinary never-armed DENY. Asserting it stops a
# future reader from "fixing" the guard with `[ -L ]` and silently converting a
# real never-armed session into a fail-open.
( cd "$P/.operator" && rm -rf .armed && ln -s ./nowhere-at-all .armed )
run_armhook "$P" "$S"
check "G2.12 .armed is a DANGLING symlink → exit 2 (a broken link is absence, not an infra fault)" \
  "$([ "$ARC" -eq 2 ] && echo 0 || echo 1)"

# THE LOAD-BEARING ONE. The fail-open for a chmod-000 .armed cannot fire under
# uid 0, and that is only acceptable because root's marker LOOKUP stays accurate
# through the unreadable directory — present reads TRUE, absent reads FALSE — so
# root never reaches a wrong verdict. If that ever stopped holding, the inert
# guard would become a real defect. This case is the tripwire for that.
# Skipped for a non-root runner, where the chmod genuinely denies and the
# question does not arise (see #20: chmod-based cases are uid-dependent).
( cd "$P/.operator" && rm -rf .armed && mkdir .armed && : > ".armed/$S" && chmod 000 .armed )
if [ "$(id -u)" = 0 ]; then
  ARMED_PRESENT=$([ -e "$P/.operator/.armed/$S" ] && echo yes || echo no)
  ARMED_ABSENT=$([ -e "$P/.operator/.armed/NO-SUCH-SESSION" ] && echo yes || echo no)
  check "G2.12 as uid 0, the marker lookup stays accurate through a chmod-000 .armed" \
    "$([ "$ARMED_PRESENT" = yes ] && [ "$ARMED_ABSENT" = no ] && echo 0 || echo 1)"
  run_armhook "$P" "$S"
  check "G2.12 as uid 0, an armed session is ALLOWED even with .armed chmod 000" \
    "$([ "$ARC" -eq 0 ] && echo 0 || echo 1)"
else
  run_armhook "$P" "$S"
  check "G2.12 as non-root, a chmod-000 .armed fails OPEN (the -x half fires)" \
    "$([ "$ARC" -eq 0 ] && echo 0 || echo 1)"
fi
( cd "$P/.operator" && chmod 755 .armed 2>/dev/null; rm -rf .armed )

# G2.13 — a NON-WRITABLE .armed (mode 555) must fail OPEN (issue #27). Mode 555
# passes both `-d` and `-x`, so before the `-w` half existed the guard stayed
# silent while the project wedged: a new session denied, ops-task.sh reporting
# success while writing no marker (it swallows the write by design), its sentinel
# landing anyway so Stop blocked too, and all three advertised repairs writing
# into that same unwritable directory. Measured end to end off-root — which is
# what makes this the real unwritable-and-unrepairable case (#19 examined
# chmod 000, concluded root is never blocked by mode bits, and stopped there).
#
# UID-CONDITIONAL, and the asymmetry is the point rather than an inconvenience.
# `-w` is inert for uid 0 exactly as `-x` is: root's `[ -w ]` on a 555 directory
# is TRUE, so the guard does not fire and an unarmed root session gets the
# ordinary never-armed DENY. That is CORRECT, not a gap — root's writes into 555
# genuinely succeed, so ops-task.sh really does arm it and the repair path is
# alive. The wedge only exists for a uid whose writes actually fail.
# (An earlier draft of this case asserted exit 0 unconditionally and failed under
# root for exactly this reason; the hook was right and the assertion was wrong.)
( cd "$P/.operator" && rm -rf .armed && mkdir .armed && chmod 555 .armed )
run_armhook "$P" "$S"
if [ "$(id -u)" = 0 ]; then
  check "G2.13 as uid 0, a mode-555 .armed still DENIES (the -w half is inert, and root is not wedged)" \
    "$([ "$ARC" -eq 2 ] && echo 0 || echo 1)"
  # The property that makes the inertness safe, asserted rather than assumed:
  # root can actually write the marker into a 555 directory, so the repair works.
  ( : > "$P/.operator/.armed/root-write-probe" ) 2>/dev/null
  check "G2.13 as uid 0, a marker write into a mode-555 .armed SUCCEEDS (repair path alive)" \
    "$([ -e "$P/.operator/.armed/root-write-probe" ] && echo 0 || echo 1)"
  rm -f "$P/.operator/.armed/root-write-probe" 2>/dev/null
else
  check "G2.13 .armed exists but is NOT WRITABLE (mode 555) → exit 0 (fails open)" \
    "$([ "$ARC" -eq 0 ] && echo 0 || echo 1)"
fi
( cd "$P/.operator" && chmod 755 .armed 2>/dev/null; rm -rf .armed )

# G2.7 — `Bash` is never in the PreToolUse matcher. Asserted against hooks.json
# itself (check_armgate pins the same property in the build gate).
G27="$(python3 - "$REPO/hooks/hooks.json" <<'PY'
import json, sys
h = json.load(open(sys.argv[1]))["hooks"]["PreToolUse"][0]["matcher"]
print(sum(1 for t in h.split("|") if t == "Bash"))
PY
)"
check "G2.7 PreToolUse matcher contains zero Bash entries" \
  "$([ "$G27" = "0" ] && echo 0 || echo 1)"

# --- the recompute: remove → rescan → restore, under the ledger lock ----------

# G2.8 — one task open, verdicted: the marker is removed.
( cd "$P" && bash "$TASK" g2t8 --owner "$S" >/dev/null 2>&1 )
check "G2.8 ops-task.sh creates .armed/\$S" \
  "$([ -e "$P/.operator/.armed/$S" ] && echo 0 || echo 1)"
( cd "$P" && bash "$VERDICT" g2t8 crit ev PASS --owner "$S" >/dev/null 2>&1 )
check "G2.8 verdict on the only task removes .armed/\$S" \
  "$([ ! -e "$P/.operator/.armed/$S" ] && echo 0 || echo 1)"
run_armhook "$P" "$S"
check "G2.8 the disarmed session is denied again" "$([ "$ARC" -eq 2 ] && echo 0 || echo 1)"

# G2.9 — TWO tasks open, one verdicted: remove-then-rescan-then-RESTORE puts the
# marker back. A clear→rescan→conditionally-remove implementation passes G2.8 and
# fails here; this is the case that catches the wrong order.
( cd "$P" && bash "$TASK" g2t9a --owner "$S" >/dev/null 2>&1 )
( cd "$P" && bash "$TASK" g2t9b --owner "$S" >/dev/null 2>&1 )
( cd "$P" && bash "$VERDICT" g2t9a crit ev PASS --owner "$S" >/dev/null 2>&1 )
check "G2.9 verdict with a second task still open restores .armed/\$S" \
  "$([ -e "$P/.operator/.armed/$S" ] && echo 0 || echo 1)"
run_armhook "$P" "$S"
check "G2.9 the still-armed session is allowed" "$([ "$ARC" -eq 0 ] && echo 0 || echo 1)"

# G2.10 — marker deleted by hand (the stale-FALSE desync), then a verdict on
# another open task of the same session: the recompute is self-healing.
( cd "$P" && bash "$TASK" g2t10 --owner "$S" >/dev/null 2>&1 )
rm -f "$P/.operator/.armed/$S"
( cd "$P" && bash "$VERDICT" g2t10 crit ev PASS --owner "$S" >/dev/null 2>&1 )
check "G2.10 hand-deleted marker is restored by the recompute" \
  "$([ -e "$P/.operator/.armed/$S" ] && echo 0 || echo 1)"

# The --defer path recomputes too — same lock, same order. g2t9b is still open,
# so deferring it must leave no marker; and the exempt grant must survive a
# recompute (G3.5: two marker kinds, two lifetimes).
: > "$P/.operator/.armed/$S.exempt"
( cd "$P" && bash "$VERDICT" g2t9b --defer "blocked upstream" >/dev/null 2>&1 )
check "G2 --defer recomputes: no owned sentinel left → marker removed" \
  "$([ ! -e "$P/.operator/.armed/$S" ] && echo 0 || echo 1)"
check "G2 the recompute never touches .armed/\$S.exempt (G3 grant)" \
  "$([ -e "$P/.operator/.armed/$S.exempt" ] && echo 0 || echo 1)"
rm -f "$P/.operator/.armed/$S.exempt"

# F1 — a CORRUPTED sentinel body naming a G3 grant ("session_id: victim.exempt")
# must not parse as a valid owner: check_owner_name (the writer) already rejects
# *.exempt, but sentinel_owner() (the untrusted-body parser) did not mirror it,
# so the smuggled name reached recompute_arm_marker and `rm -f
# .armed/victim.exempt` deleted another session's real G3 exemption grant
# (issue #30). Plant the victim's grant, then run a verdict on a task whose
# body claims that reserved name and carries NO --owner (forcing the parser's
# reject-set to be what's tested).
: > "$P/.operator/.armed/victim.exempt"
( cd "$P" && bash "$TASK" g2f1 --owner "$S" >/dev/null 2>&1 )
printf 'session_id: victim.exempt\n' > "$P/.operator/pending/g2f1"
( cd "$P" && bash "$VERDICT" g2f1 crit ev PASS >/dev/null 2>&1 )
check "F1 a sentinel body naming a G3 grant is rejected as unowned" \
  "$([ -e "$P/.operator/.armed/victim.exempt" ] && echo 0 || echo 1)"
rm -f "$P/.operator/.armed/victim.exempt" "$P/.operator/pending/g2f1"

# ops-adopt.sh re-creates the marker for the NEW owner — the recovery the deny
# message names verbatim (stale-false mitigation 1).
S2="SESS-G2-ROT"
( cd "$P" && bash "$TASK" g2adopt --owner "$S" >/dev/null 2>&1 )
rm -f "$P/.operator/.armed/$S2"
( cd "$P" && bash "$ADOPT" --owner "$S2" g2adopt >/dev/null 2>&1 )
check "G2 ops-adopt.sh creates .armed/ for the adopting session" \
  "$([ -e "$P/.operator/.armed/$S2" ] && echo 0 || echo 1)"
run_armhook "$P" "$S2"
check "G2 the adopting session is allowed" "$([ "$ARC" -eq 0 ] && echo 0 || echo 1)"
# Ownership-scoping: a BYSTANDER session is not armed by $S2's open task. The
# marker is keyed by session id precisely so an unscoped "is pending/ non-empty?"
# cannot let session B write because session A holds work open — the cross-
# session fail-open 0.4.0 exists to close. Uses a session that has never opened
# anything: $S still carries an ACCEPTED stale-true marker here (adopt re-keys
# the sentinel to $S2 but does not recompute the previous owner), which is the
# documented harmless direction, not a property to assert against.
S3="SESS-G2-BYSTANDER"
run_armhook "$P" "$S3"
check "G2 another session's open task does not arm a bystander" \
  "$([ "$ARC" -eq 2 ] && echo 0 || echo 1)"
( cd "$P" && bash "$VERDICT" g2adopt crit ev PASS --owner "$S2" >/dev/null 2>&1 )

# An UNOWNED task arms nobody: there is no session to key a marker to. Counted
# as a DELTA, not as an empty directory — $S's accepted stale-true marker lives
# there (see above), so "no markers at all" is the wrong assertion.
count_markers() { local n=0 m; shopt -s nullglob; for m in "$P/.operator/.armed"/*; do [ -e "$m" ] && n=$((n+1)); done; shopt -u nullglob; echo "$n"; }
ARM_BEFORE="$(count_markers)"
( cd "$P" && bash "$TASK" g2unowned >/dev/null 2>&1 )
ARM_AFTER="$(count_markers)"
check "G2 an unowned open task writes no new marker" \
  "$([ "$ARM_BEFORE" = "$ARM_AFTER" ] && echo 0 || echo 1)"
run_armhook "$P" "$S3"
check "G2 an unowned open task arms no session" "$([ "$ARC" -eq 2 ] && echo 0 || echo 1)"

rm -rf "$P"

########################################################################
echo "-- Case: G3 exemption — the audited escape hatch the arm gate advertises"
# A blocking gate with no override is how a session wedges. The hatch is one
# command and it is NOT free: it writes a GATE-EXCEPTION, a kind the stage-2
# deviation gate already blocks Stop on until a HANDOFF-MARK presents it. So
# bypassing the arm gate owes a handoff presentation. See backlog-charter.md §G3.
P="$(newproj)"; ( cd "$P" && bash "$INIT" >/dev/null 2>&1 )
S="SESS-G3"
DEC3="$P/.operator/DECISIONS.md"
payload3() { printf '{"session_id":"%s","stop_hook_active":false,"cwd":"%s"}' "$S" "$P"; }

# G3.2 FIRST (it must leave DECISIONS.md untouched, which is only checkable
# against a ledger the grant has not yet written to).
DEC3_BEFORE="$(cat "$DEC3")"
( cd "$P" && bash "$TASK" --exempt >/dev/null 2>&1 ); X2=$?
check "G3.2 --exempt with no reason → exit non-zero" "$([ "$X2" -ne 0 ] && echo 0 || echo 1)"
# A FORGOTTEN reason: `--exempt --owner $S` must not swallow the next flag as
# the reason text — that grants an exemption whose audit line reads "--owner",
# and drops the ownership tag that scopes the debt.
( cd "$P" && bash "$TASK" --exempt --owner "$S" >/dev/null 2>&1 ); X2F=$?
check "G3.2 --exempt --owner \$S (reason forgotten) → exit non-zero" \
  "$([ "$X2F" -ne 0 ] && echo 0 || echo 1)"
( cd "$P" && bash "$TASK" --exempt "" --owner "$S" >/dev/null 2>&1 ); X2E=$?
check "G3.2 --exempt with an EMPTY reason → exit non-zero" "$([ "$X2E" -ne 0 ] && echo 0 || echo 1)"
( cd "$P" && bash "$TASK" --exempt "no owner given" >/dev/null 2>&1 ); X2O=$?
check "G3.2 --exempt without --owner → exit non-zero (no untagged GATE-EXCEPTION)" \
  "$([ "$X2O" -ne 0 ] && echo 0 || echo 1)"
check "G3.2 a refused --exempt leaves DECISIONS.md unchanged" \
  "$([ "$(cat "$DEC3")" = "$DEC3_BEFORE" ] && echo 0 || echo 1)"
check "G3.2 a refused --exempt writes no marker" \
  "$([ ! -e "$P/.operator/.armed/$S.exempt" ] && echo 0 || echo 1)"
# An exemption is the NO-open-task path: taking a task id too is contradictory.
( cd "$P" && bash "$TASK" t-x --exempt "both" --owner "$S" >/dev/null 2>&1 ); X2B=$?
check "G3.2 --exempt with a task-id → exit non-zero (mutually exclusive)" \
  "$([ "$X2B" -ne 0 ] && echo 0 || echo 1)"

# G3.1 — the grant itself.
( cd "$P" && bash "$TASK" --exempt "upstream API is down, documenting the workaround" --owner "$S" >/dev/null 2>&1 ); X1=$?
check "G3.1 --exempt \"reason\" --owner \$S → exit 0" "$([ "$X1" -eq 0 ] && echo 0 || echo 1)"
# Count ROWS, not mentions: the scaffolded header carries the kind enum as a
# comment (`# gated ...: DEVIATION | ESCALATION | GATE-EXCEPTION`), which a bare
# grep counts — the same false positive the Stop hook's `#`-skip exists for.
GX="$(grep -c '^[^#].* | GATE-EXCEPTION | ' "$DEC3" || true)"
check "G3.1 exactly one GATE-EXCEPTION row written" "$([ "$GX" = "1" ] && echo 0 || echo 1)"
check "G3.1 the GATE-EXCEPTION is tagged [sid:\$S] and carries the reason" \
  "$(grep '^[^#].* | GATE-EXCEPTION | ' "$DEC3" | grep -q "\[sid:$S\].*upstream API is down" && echo 0 || echo 1)"
check "G3.1 .armed/\$S.exempt exists" \
  "$([ -e "$P/.operator/.armed/$S.exempt" ] && echo 0 || echo 1)"
# The grant does NOT fabricate the derived marker: two kinds, two lifetimes.
check "G3.1 the grant writes no DERIVED .armed/\$S" \
  "$([ ! -e "$P/.operator/.armed/$S" ] && echo 0 || echo 1)"
# ...and the gate now lets this session write (the hatch actually opens).
run_armhook "$P" "$S"
check "G3.1 armgate.on absent → allowed anyway (control for the next assert)" \
  "$([ "$ARC" -eq 0 ] && echo 0 || echo 1)"
: > "$P/.operator/armgate.on"
run_armhook "$P" "$S"
check "G3.1 gate ON + exemption granted → the write is allowed" \
  "$([ "$ARC" -eq 0 ] && echo 0 || echo 1)"
rm -f "$P/.operator/armgate.on"

# G3.3 — the debt: the exemption owes a presentation, so Stop is blocked.
payload3 | bash "$HOOK" >/dev/null 2>&1; X3=$?
check "G3.3 after the grant, Stop is BLOCKED (the exemption owes a presentation)" \
  "$([ "$X3" = 2 ] && echo 0 || echo 1)"

# G3.5 BEFORE G3.4: the mark would clear the deviation gate and make the
# ordering of the remaining asserts less discriminating. Verdicting an
# UNRELATED open task runs recompute_arm_marker, which must never touch a
# GRANTED marker — an exempt session has nothing in pending/, so a recompute
# that owned both kinds would revoke the grant on the next verdict.
( cd "$P" && bash "$TASK" g3unrelated --owner "$S" >/dev/null 2>&1 )
( cd "$P" && bash "$VERDICT" g3unrelated crit ev PASS --owner "$S" >/dev/null 2>&1 )
check "G3.5 the recompute leaves .armed/\$S.exempt present" \
  "$([ -e "$P/.operator/.armed/$S.exempt" ] && echo 0 || echo 1)"
check "G3.5 the same recompute DID remove the derived .armed/\$S (recompute ran)" \
  "$([ ! -e "$P/.operator/.armed/$S" ] && echo 0 || echo 1)"

# G3.4 — presenting the debt clears it.
( cd "$P" && bash "$VERDICT" --mark-handoff --owner "$S" >/dev/null 2>&1 )
payload3 | bash "$HOOK" >/dev/null 2>&1; X4=$?
check "G3.4 after --mark-handoff, Stop is allowed" "$([ "$X4" = 0 ] && echo 0 || echo 1)"

# The debt is SESSION-SCOPED: a foreign session never inherits it. (A grant that
# blocked everyone would be the wedge this feature exists to prevent.)
printf '{"session_id":"SESS-G3-OTHER","stop_hook_active":false,"cwd":"%s"}' "$P" \
  | bash "$HOOK" >/dev/null 2>&1; X4F=$?
check "G3 a foreign session is not blocked by \$S's exemption" \
  "$([ "$X4F" = 0 ] && echo 0 || echo 1)"

# G3.6 — the opener stays LOCK-FREE. The ledger write is delegated to
# ops-verdict.sh, which already holds the lock; a lock here would copy the LOCK
# BLOCK to a third file (and check_lock_parity to a third site) for one rare flag.
X6="$(grep -c 'lock_acquire' "$TASK" || true)"
check "G3.6 grep -c 'lock_acquire' ops-task.sh = 0 (the write is delegated)" \
  "$([ "$X6" = "0" ] && echo 0 || echo 1)"

# G3.7 — an owner ending in `.exempt` is REFUSED by all three writers (#30).
# `.armed/` carries two marker kinds in one flat namespace, so that suffix is
# forgeable in both directions. Measured before the fix, on a real project:
#   grant   — `ops-task.sh <ordinary-task> --owner foo.exempt` wrote
#             `.armed/foo.exempt`; session `foo` went from arm-gate exit 2 to
#             exit 0 with ZERO GATE-EXCEPTION rows. G3's whole premise is that
#             bypassing the gate costs a handoff presentation; this cost nothing
#             and left no trace.
#   destroy — a session named `foo.exempt` closing an ordinary task ran
#             `recompute_arm_marker foo.exempt`, deleting foo's REAL exemption
#             while the GATE-EXCEPTION row still asserted it held.
# Refused at the WRITERS, deliberately not in the hook's reject set: that set
# fails OPEN, so rejecting there would ALLOW such a session rather than deny it.
X7P="$(newproj)"; ( cd "$X7P" && bash "$INIT" >/dev/null 2>&1 )
( cd "$X7P" && bash "$TASK" ordinary --owner "victim.exempt" >/dev/null 2>&1 ); X7T=$?
check "G3.7 ops-task.sh refuses an owner ending in .exempt (would forge a G3 grant)" \
  "$([ "$X7T" != 0 ] && echo 0 || echo 1)"
check "G3.7 the refused open wrote no .armed marker" \
  "$([ ! -e "$X7P/.operator/.armed/victim.exempt" ] && echo 0 || echo 1)"
# The adopt case needs a REAL open sentinel first. Without one, ops-adopt.sh
# fails with "no open task" whatever the owner is, and the assertion passes for
# the wrong reason — mutation-verified: removing the guard from ops-adopt.sh
# still gave a green suite until this line existed. That is the repo's own
# vacuous-guard class (F48) reproduced inside its own test.
( cd "$X7P" && bash "$TASK" adoptable --owner legit-sid >/dev/null 2>&1 )
( cd "$X7P" && bash "$ADOPT" --owner "victim.exempt" adoptable >/dev/null 2>&1 ); X7A=$?
check "G3.7 ops-adopt.sh refuses the same owner (second, independent grant path)" \
  "$([ "$X7A" != 0 ] && echo 0 || echo 1)"
check "G3.7 the refused adopt wrote no .armed marker either" \
  "$([ ! -e "$X7P/.operator/.armed/victim.exempt" ] && echo 0 || echo 1)"
( cd "$X7P" && bash "$VERDICT" ordinary crit ev PASS --owner "victim.exempt" >/dev/null 2>&1 ); X7V=$?
check "G3.7 ops-verdict.sh refuses it too (the recompute would delete a real grant)" \
  "$([ "$X7V" != 0 ] && echo 0 || echo 1)"
# A REAL exemption still works — the guard must reject the owner, not the feature.
( cd "$X7P" && bash "$TASK" --exempt "genuine reason" --owner victim >/dev/null 2>&1 )
check "G3.7 a genuine --exempt for the same base session still lands" \
  "$([ -e "$X7P/.operator/.armed/victim.exempt" ] && echo 0 || echo 1)"
rm -rf "$X7P"

rm -rf "$P"

########################################################################
echo "-- Case: S1 source-state stamp — a verdict row names the tree it came from"
# U10 (issue #22). A PASS survived unstaged, staged, committed and untracked
# mutation of the source it verified, because the row named no source state at
# all: four cells, no sha, and ops-verdict.sh never called git. These cases pin
# the stamp that closes the attribution half — the row is now attributable to
# one tree, which is NOT the same as that tree still passing (see S1.9).
#
# Every project here is a REAL git repo, because the ordinary path is the one
# that must be exercised end-to-end: the suite's other cases run in bare
# mktemp dirs, which take the no-vcs branch. That asymmetry is the whole reason
# the PLAYBOOK says to verify the normal path through the real parser.
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
# The 4-cell schema is what every grep consumer depends on; a stamp that split a
# row would be the 5-cell injection this suite already guards against elsewhere.
NC="$(awk -F'|' 'END{print NF}' "$P/.operator/VERDICTS.md")"
check "S1.2 stamped row is still exactly 4 cells" \
  "$([ "$NC" = "6" ] && echo 0 || echo 1)"
# The fragment and the ledger must carry the SAME bytes, or --reconcile's
# verbatim dedup re-appends every stamped row on the next repair.
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
# Untracked source counts too — the fourth class in the U10 table, and the one
# a naive `git diff` check would miss.
( cd "$P" && git checkout -q -- src.py )
printf 'x\n' > "$P/new_source.py"
( cd "$P" && bash "$TASK" S1-c --owner SESS-S1 >/dev/null 2>&1 )
( cd "$P" && bash "$VERDICT" S1-c "crit" "ev" PASS --owner SESS-S1 >/dev/null 2>&1 )
check "S1.5 untracked source file → @<sha>+dirty" \
  "$([ "$(stamp_of "$P")" = "@$SHA+dirty" ] && echo 0 || echo 1)"
rm -f "$P/new_source.py"

# THE DISCRIMINATING CASE for the exclusion rule. .operator/ is the gate's own
# bookkeeping and is untracked in a project that has not committed its ledger —
# i.e. almost every project, including this fixture. Count it as dirt and every
# row everywhere reads +dirty, which is a marker that cannot be off: the
# vacuous-guard class (#21) shipped as a feature. Same boundary ops-claims.sh
# --expect-clean already draws.
( cd "$P" && bash "$TASK" S1-d --owner SESS-S1 >/dev/null 2>&1 )
( cd "$P" && bash "$VERDICT" S1-d "crit" "ev" PASS --owner SESS-S1 >/dev/null 2>&1 )
check "S1.6 .operator/ churn alone does NOT read as dirty" \
  "$([ "$(stamp_of "$P")" = "@$SHA" ] && echo 0 || echo 1)"
rm -rf "$P"

# A repo with no commits: there is a tree, but no name to bind to. Recorded,
# never refused — the charter's rule is that the gate never refuses real
# evidence, and an unnameable tree is not the operator's fault.
P="$(newproj)"
( cd "$P" && git init -q . && git config user.email t@example.com && git config user.name t && bash "$INIT" ) >/dev/null 2>&1
( cd "$P" && bash "$TASK" S1-e --owner SESS-S1 >/dev/null 2>&1 )
( cd "$P" && bash "$VERDICT" S1-e "crit" "ev" PASS --owner SESS-S1 >/dev/null 2>&1 ); S1E=$?
check "S1.7 unborn HEAD → @no-commit, row still recorded" \
  "$([ "$S1E" = 0 ] && [ "$(stamp_of "$P")" = "@no-commit" ] && echo 0 || echo 1)"
rm -rf "$P"
fi

# No git repository at all (the bare mktemp project every other case uses).
# Explicit marker, not silence: an UNSTAMPED row means "written before this
# existed", and an audit that cannot tell the two apart cannot start.
P="$(newproj)"; ( cd "$P" && bash "$INIT" >/dev/null 2>&1 )
( cd "$P" && bash "$TASK" S1-f --owner SESS-S1 >/dev/null 2>&1 )
( cd "$P" && bash "$VERDICT" S1-f "crit" "ev" PASS --owner SESS-S1 >/dev/null 2>&1 ); S1F=$?
check "S1.8 no git repo → @no-vcs, row still recorded (never refuses evidence)" \
  "$([ "$S1F" = 0 ] && [ "$(stamp_of "$P")" = "@no-vcs" ] && echo 0 || echo 1)"
# --defer is deliberately NOT stamped: it records that no verdict was reached,
# so there is no evidence to bind to a tree. Pinned so the asymmetry is a
# decision a later reader can find, not an omission they re-add by accident.
( cd "$P" && bash "$TASK" S1-g --owner SESS-S1 >/dev/null 2>&1 )
( cd "$P" && bash "$VERDICT" S1-g --defer "blocked upstream" --owner SESS-S1 >/dev/null 2>&1 )
check "S1.9 --defer line carries no stamp (nothing was verified)" \
  "$(grep -q 'DEFERRED-VERDICT' "$P/.operator/DECISIONS.md" && ! grep -q '@no-vcs' "$P/.operator/DECISIONS.md" && echo 0 || echo 1)"
rm -rf "$P"

# STRUCTURAL: the stamp is computed BEFORE lock_acquire. `git status` is
# unbounded work on a large repo, and the PLAYBOOK's "never lengthen the
# critical section" rule is what keeps a waiter from giving up and proceeding
# UNLOCKED. Asserted on the verdict path's own section of the file.
# Comment lines are dropped AFTER the section is found: the marker is a comment
# (so the section must be located in the raw file), but the prose inside the
# section also names source_stamp — matching it made the first draft of this
# case pass against a build with the stamp moved inside the lock. The validator's
# twin check had the same hole, found by the same mutation.
VSEC="$(awk '/^# --- Verdict path ---/{f=1} f' "$VERDICT" | grep -v '^[[:space:]]*#')"
SL="$(printf '%s\n' "$VSEC" | grep -n 'source_stamp' | head -1 | cut -d: -f1)"
LL="$(printf '%s\n' "$VSEC" | grep -n 'lock_acquire' | head -1 | cut -d: -f1)"
check "S1.10 stamp is resolved before lock_acquire (critical section unchanged)" \
  "$([ -n "$SL" ] && [ -n "$LL" ] && [ "$SL" -lt "$LL" ] && echo 0 || echo 1)"

# HONESTY NOTE. What S1 proves is ATTRIBUTION: a row names one tree. It does
# NOT prove that tree still passes, and nothing here re-runs anything. The
# stamp is written by the same process that writes the row, so it is provenance,
# not attestation — a lying operator can still record a PASS it never ran, and
# the tree it names will be stamped correctly. The staleness reader (#22 step 2)
# and independent execution (#23) are separate, still open, and this case exists
# so the next reader does not mistake a green S1 for either of them.

########################################################################
echo "-- Case: init warns when a parent gitignore defeats the v2 allowlist (#25)"
# F67. The v2 allowlist lives INSIDE .operator/ and cannot beat a rule that
# excludes the directory itself — git never descends into an excluded dir, so
# the negations have nothing to re-admit. Before this warning, ops-init reported
# success while every ledger stayed silently untracked. The warning must NAME
# the defeating rule (file:line via check-ignore -v), never fail the init, and
# never fire on a healthy project or outside git.
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

echo "-- Case: the v2 allowlist admits the handoff and the gate switch (#28, #31)"
# BEHAVIOURAL, not textual: the validator pins the allow LINES, this pins what
# git actually does with them. Two findings, both measured on the real scaffold:
#   #28 — `.operator/handoff-<date>.md` (commands/handoff.md:9 writes exactly
#         this) was ignored by the bare `*`, so the operator→human handoff — the
#         artifact the charter's HANDOFF section exists to produce — shipped
#         untracked. A REGRESSION: v1's blocklist tracked it (verified by running
#         main's ops-init.sh in a fresh repo).
#   #31 — `.operator/armgate.on` is the project's opt-in DECISION, not machine
#         state. Ignored, a team could not commit it and every fresh clone got
#         the gate silently OFF. tiers.env is allow-listed for the same reason.
# The negative control matters as much: a NEW ephemera file must still be
# ignored, or the allowlist has quietly become a blocklist again.
if command -v git >/dev/null 2>&1; then
P="$(newproj)"
( cd "$P" && git init -q . && git config user.email t@example.com && git config user.name t ) >/dev/null 2>&1
( cd "$P" && bash "$INIT" >/dev/null 2>&1 )
: > "$P/.operator/handoff-2026-08-11.md"
: > "$P/.operator/armgate.on"
: > "$P/.operator/some-new-ephemera.tmp"
# `git check-ignore -q` EXIT STATUS is the truth — `-v` prints the last matching
# rule even when that rule is a `!` negation, which reads as "ignored" and is not.
( cd "$P" && git check-ignore -q .operator/handoff-2026-08-11.md ) && GIH=1 || GIH=0
check "#28 the handoff file is TRACKED (not ignored by the v2 allowlist)" \
  "$([ "$GIH" = 0 ] && echo 0 || echo 1)"
( cd "$P" && git check-ignore -q .operator/armgate.on ) && GIA=1 || GIA=0
check "#31 armgate.on is TRACKED (a team can commit its own opt-in)" \
  "$([ "$GIA" = 0 ] && echo 0 || echo 1)"
( cd "$P" && git check-ignore -q .operator/some-new-ephemera.tmp ) && GIE=1 || GIE=0
check "the allowlist still IGNORES a new ephemera file (it is not a blocklist)" \
  "$([ "$GIE" = 1 ] && echo 0 || echo 1)"
# End to end: does `git add -A` actually stage them?
( cd "$P" && git add -A >/dev/null 2>&1 )
GIST="$(cd "$P" && git status --porcelain)"
check "#28/#31 git add -A stages both the handoff and armgate.on" \
  "$(printf '%s' "$GIST" | grep -q 'handoff-2026-08-11.md' \
     && printf '%s' "$GIST" | grep -q 'armgate.on' && echo 0 || echo 1)"
check "git add -A does NOT stage the new ephemera file" \
  "$(printf '%s' "$GIST" | grep -q 'some-new-ephemera.tmp' && echo 1 || echo 0)"
rm -rf "$P"
else
  echo "  SKIP allowlist-content cases (no git on PATH)"
fi

echo "-- Case: SessionStart refreshes a STALE bin/ even when the version has not moved (#34)"
# The upgrade used to fire only on a version-string change. Every intra-version
# fix to a gate CLI therefore never reached .operator/bin/ — and the charter
# points the model at THAT copy, so the project keeps running the broken
# predecessor of a fix while the plugin tree's own tests pass. Found by the
# replay charter on 2026-08-12: bin/ops-verdict.sh was byte-identical to a
# commit two behind HEAD, with .version already reading the current version.
STALEP="$(newproj)"
( cd "$STALEP" && git init -q . 2>/dev/null && "$BASH_ABS" "$SCRIPTS/ops-init.sh" >/dev/null 2>&1 )
STALEV="$(cat "$STALEP/.operator/.version" 2>/dev/null)"
# Plant a stale CLI: wrong content, mtime OLDER than the plugin's copy, while
# the version stamp already reads current (the exact #34 condition).
printf '#!/usr/bin/env bash\n# STALE COPY\n' > "$STALEP/.operator/bin/ops-verdict.sh"
touch -t 200001010000 "$STALEP/.operator/bin/ops-verdict.sh"
sed "s|<tmp>|$STALEP|" "$FIXTURES/sessionstart.json" | "$BASH_ABS" "$SSHOOK" >/dev/null 2>&1
check "#34 a stale bin/ CLI is refreshed with the version unchanged" \
  "$(grep -q 'STALE COPY' "$STALEP/.operator/bin/ops-verdict.sh" && echo 1 || echo 0)"
check "#34 the refreshed CLI is byte-identical to the plugin's copy" \
  "$(cmp -s "$STALEP/.operator/bin/ops-verdict.sh" "$SCRIPTS/ops-verdict.sh" && echo 0 || echo 1)"
check "#34 the version stamp is unchanged (this was never a version event)" \
  "$([ "$(cat "$STALEP/.operator/.version" 2>/dev/null)" = "$STALEV" ] && echo 0 || echo 1)"
# Negative control: nothing stale ⇒ no rewrite. Without this the case would pass
# against a hook that copies unconditionally on every session start.
STALE_MTIME_BEFORE="$(ls -l "$STALEP/.operator/bin/ops-task.sh" 2>/dev/null)"
sed "s|<tmp>|$STALEP|" "$FIXTURES/sessionstart.json" | "$BASH_ABS" "$SSHOOK" >/dev/null 2>&1
check "#34 a current bin/ is NOT rewritten (the probe is staleness, not a timer)" \
  "$([ "$STALE_MTIME_BEFORE" = "$(ls -l "$STALEP/.operator/bin/ops-task.sh" 2>/dev/null)" ] && echo 0 || echo 1)"
rm -rf "$STALEP"

echo "-- Case: SessionStart replaces bin/ CLIs ATOMICALLY — the inode changes (F5)"
# The upgrade used to write each CLI in place with `cp` (O_TRUNC, SAME inode), so
# a bash concurrently mid-execution of the OLD file could be truncated (the F5
# defect: truncation between LOCK_HELD=1 and the EXIT trap in ops-verdict.sh
# leaves the lock held with no cleanup). The fix writes a temp file then `mv`s it
# over the target — `mv` swaps the inode, so a concurrent reader keeps its old
# inode. A changed inode across an upgrade is therefore the direct evidence of
# atomic replace rather than in-place truncation.
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
# Steady state (version now matches, nothing stale): no rewrite, so the inode is
# stable — proving the inode-change above was earned by a real upgrade, not by a
# rewrite-on-every-session.
_cur_ino="$(stat -f '%i' "$INOP/.operator/bin/ops-verdict.sh" 2>/dev/null)"
sed "s|<tmp>|$INOP|" "$FIXTURES/sessionstart.json" | "$BASH_ABS" "$SSHOOK" >/dev/null 2>&1
check "F5 steady-state (version matches) does NOT rewrite, so the inode is stable" \
  "$([ -n "$_cur_ino" ] && [ "$_cur_ino" = "$(stat -f '%i' "$INOP/.operator/bin/ops-verdict.sh" 2>/dev/null)" ] && echo 0 || echo 1)"
rm -rf "$INOP"

echo "-- Case: the SessionStart v1→v2 migration announces itself (#32)"
# The migration REPLACES a file the user may have edited, and the .v1.bak it
# leaves is itself hidden by the new bare `*` — so before this, a project with a
# hand-added rule lost it with no message anywhere: stdout carried only the
# SessionStart JSON and `git status` showed no trace of the backup. ops-init.sh
# echoes a notice for the identical destructive write; this path — the one that
# exists precisely to carry projects that never re-run /cc-operator:start — was
# silent by construction. The notice rides additionalContext, the hook's only
# channel to the model. It must NOT fire when there is nothing to migrate.
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
# The #32 notice promised a recoverable .v1.bak, but the backup was `cp … 2>/dev/null`
# followed by an UNCONDITIONAL write, and the flag was set before either. With
# `.operator/` unwritable and `.gitignore` still writable, the user's rules were
# destroyed, no backup existed, and the context claimed both had succeeded —
# #32's own failure one layer down (Copilot review of PR #12, 2026-08-12).
# Two ways the backup fails; both must leave the v1 file untouched.
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

# The OTHER trigger, and the one Copilot described: the copy itself fails. The
# directory is unwritable so `.v1.bak` cannot be created, while `.gitignore`
# stays writable — which is exactly why the old unconditional `cat >` still
# succeeded and ate the rules. Distinct from the case above (a non-regular
# `.v1.bak`), and each must fail on its own guard, or one branch rides on the
# other's test.
MIGW="$(newproj)"
mkdir -p "$MIGW/.operator"
printf '# cc-operator gitignore (v1)\nbin/\n!my-own-rule.md\n' > "$MIGW/.operator/.gitignore"
chmod 500 "$MIGW/.operator"
MIGWOUT="$(sed "s|<tmp>|$MIGW|" "$FIXTURES/sessionstart.json" | "$BASH_ABS" "$SSHOOK" 2>/dev/null)"
chmod 700 "$MIGW/.operator"
# Same root caveat: chmod 500 does not stop root writing, so the copy this case
# needs to FAIL succeeds and the migration proceeds correctly — a pass would be
# measuring the wrong thing.
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
# `-f` FOLLOWS symlinks, so a symlink-to-regular passed the old "refuse if
# non-regular" guard and `cp` then overwrote the LINK'S TARGET instead of
# writing a real backup — silently clobbering whatever the symlink pointed at.
# The guard must refuse on `-L` before falling back to the `-f` check.
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
# `retro_gate` tested `-e`, so a directory at pending/<id> read as an armed
# sentinel: the GATE-EXCEPTION was suppressed, the row was appended anyway, and
# the later `rm -f` failed on the directory — a non-zero exit with the ledger
# already mutated and no audit line (Copilot review of PR #12, 2026-08-12).
# Every other sentinel reader (ops-task.sh, the Stop hook, the statusline)
# already required a non-symlink REGULAR file.
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
# A leading-dash filename is legal in git; `xargs -0 cat` read it as options and
# aborted the ENTIRE batch, so code-loc reported 0 against a truth of 3 (the
# PARTIAL flag fired, so the number was honest — and useless).
DASHP="$(newproj)"
(cd "$DASHP" && git init -q . 2>/dev/null)
printf 'print(1)\nprint(2)\n' > "$DASHP/normal.py"
printf 'x=1\n' > "$DASHP/--version.py"
# `--` terminates git's own option parsing; the dash-named path follows it as a
# pathspec. This is the very hazard under test, one layer up.
(cd "$DASHP" && git add -- normal.py './--version.py' >/dev/null 2>&1)
DASHOUT="$( ( cd "$DASHP" || exit 1; "$BASH_ABS" "$SCRIPTS/ops-backlog.sh" --census ) 2>&1 || true )"
check "dash-named file: code-loc counts it (3, not 0)" \
  "$(printf '%s' "$DASHOUT" | grep -q 'code-loc: 3' && echo 0 || echo 1)"
check "dash-named file: the count is not PARTIAL" \
  "$(printf '%s' "$DASHOUT" | grep -q 'PARTIAL' && echo 1 || echo 0)"
rm -rf "$DASHP"

########################################################################
echo "-- Case: the suites do not contaminate the tree with bytecode"
# THE HYGIENE BEHAVIOUR HAD NO TEST AT ALL. Measured: reverting conftest.py to
# a no-op leaves 2 __pycache__ dirs and pytest still reports 178 passed;
# deleting `norecursedirs` reproduces the 4 collection errors while both suites
# stay green. Prose in three files asserted this and nothing checked it — which
# is the same "a claim with no gate" shape the #23 case below exists to expose.
# Found by the review panel's test lens, PR #36.
#
# Asserted against a COPY, not this tree: the real scripts/ and tests/ may
# legitimately hold a __pycache__ from a maintainer's earlier hand-run, so
# asserting on them would be a test of the developer's shell history.
# GATED ON PYTEST, NOT PYTHON3. Both mechanisms under test are pytest's —
# conftest.py's bootstrap and pyproject's norecursedirs — and a missing pytest
# exits non-zero, which is INDISTINGUISHABLE from the collection error the
# second assertion exists to prove absent. Gating on python3 alone shipped a
# red CI: ubuntu-latest has python3 and no pytest (validate.yml installs
# nothing and runs `unittest discover`), so the case ran, `python3 -m pytest`
# failed to start, and the assertion read that as "the seed dir broke
# collection" — a false failure on the one platform that had never run it.
# Measured locally: with the module absent the invocation returns rc 1, the
# same rc a genuine collection error returns.
if ! python3 -c "import pytest" >/dev/null 2>&1; then
  echo "  skip bytecode hygiene: pytest not importable (the mechanisms under test are pytest's)"
else
  HYG="$(newproj)"
  mkdir -p "$HYG/scripts" "$HYG/tests"
  cp "$REPO/pyproject.toml" "$HYG/" 2>/dev/null
  cp "$REPO/tests/conftest.py" "$HYG/tests/" 2>/dev/null
  # A module to import and a test that imports it — the shape that produces a
  # __pycache__ in BOTH directories.
  printf 'def f():\n    return 1\n' > "$HYG/scripts/mod_under_test.py"
  cat > "$HYG/tests/test_hyg.py" <<'PYEOF'
import pathlib, sys
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent.parent / "scripts"))
from mod_under_test import f
def test_f():
    assert f() == 1
PYEOF
  # THE SUITE-WIDE EXPORT MUST BE UNSET HERE, or this case proves nothing about
  # conftest.py. Measured: with PYTHONDONTWRITEBYTECODE inherited, neutering
  # conftest to a no-op still leaves scripts/__pycache__ absent — the env var
  # already did the work, so the case passed against the mutation (M3 of the
  # round-2 discrimination sweep: 526/0, no flip). Unset, it discriminates
  # cleanly: real conftest -> no scripts/__pycache__, no-op conftest -> one
  # appears. Same opt-out the #23 fixture takes, for the same reason: a case
  # about a mechanism must not inherit a second mechanism that hides it.
  #
  # pyproject's testpaths names the plugin's own modules, which do not exist
  # here; point pytest at the local file explicitly.
  ( unset PYTHONDONTWRITEBYTECODE; cd "$HYG" && python3 -m pytest tests/test_hyg.py -q >/dev/null 2>&1 )
  # conftest.py's OWN .pyc is the documented residue — it is compiled before the
  # line that disables bytecode runs — so tests/__pycache__ may exist. What must
  # NOT appear is a cache for the imported module, i.e. scripts/__pycache__.
  check "pytest writes no __pycache__ for imported modules (conftest suppression works)" \
    "$([ ! -d "$HYG/scripts/__pycache__" ] && echo 0 || echo 1)"
  # And the seed-dir prune: a directory named like the pilot seeds, holding an
  # unimportable test_*, must not break collection.
  mkdir -p "$HYG/tests/pilot-seeds/E9"
  printf 'import nonexistent_module_xyz\n' > "$HYG/tests/pilot-seeds/E9/test_broken.py"
  ( cd "$HYG" && python3 -m pytest tests/ -q >/dev/null 2>&1 ); HYGRC=$?
  check "norecursedirs keeps an unimportable seed dir out of collection" \
    "$([ "$HYGRC" = 0 ] && echo 0 || echo 1)"
  rm -rf "$HYG"
fi

########################################################################
echo "-- Case: gitignored build state diverges in-tree from a clean checkout (#23)"
# THE FIXTURE FOR #23, in-tree at last. The issue states the mechanism; nothing
# in this repo reproduced it, so the class had no tripwire and the eventual
# worktree fix would have had nothing to prove itself against.
#
# What it demonstrates: the SAME commit verifies PASS in the builder's tree and
# FAIL in a clean checkout of that commit, with `git status --porcelain` empty
# throughout — because the contaminant is gitignored, which is exactly why the
# tracked-tree check cannot see it.
#
# MEASURED CORRECTION to the issue's recipe. It says the two source lines being
# "the same byte length" suffices, because CPython validates a .pyc by source
# mtime + size. Size is the SECOND field: an edit moves the mtime, CPython
# invalidates, recompiles, and BOTH sides FAIL — measured, no divergence at all.
# The fixture must put the mtime back after the edit; only then does the header
# still match and the stale bytecode get served.
#
# The mtime is stamped from the .pyc's own header, not from a `stat` taken
# before the edit, and not left to timing. Measured: with the stamp removed,
# the in-tree run passes 4 of 12 iterations — the builder run and the edit fall
# on the same clock second often enough to look fixed and rarely enough to be
# useless, so a timing-derived fixture is green or red by machine speed rather
# than by the property under test. Reading the header makes them agree BY
# CONSTRUCTION: 12/12. Format: 4-byte magic, 4-byte flags, then the source
# mtime as a little-endian uint32 at offset 8 (PEP 552; flags bit 0 clear =
# timestamp invalidation, the default py_compile writes).
#
# Consequence for anyone re-running discrimination on this case: deleting the
# stamp does NOT reliably flip it — one run in three still passes by luck.
# That is a property of the mechanism, not a weak assertion. The mutations that
# DO discriminate every time are removing the builder warm-up (no .pyc exists:
# 506/1) and un-ignoring __pycache__ (porcelain sees it: 505/2).
#
# Skipped without python3 — the mechanism IS CPython's cache. A skip is honest;
# a case that silently does not run is the vacuous-guard class this repo keeps
# catching, so the skip prints.
if ! command -v python3 >/dev/null 2>&1; then
  echo "  skip #23 fixture: python3 not available (the mechanism is CPython's .pyc cache)"
else
  I23="$(newproj)"
  (
    # THE ONE OPT-OUT from this file's PYTHONDONTWRITEBYTECODE export: the
    # mechanism under test IS a written .pyc. Inheriting the suite-wide setting
    # leaves __pycache__ empty, the in-tree run recompiles from source and
    # FAILs, and the case asserts nothing (measured: 505/2, both write-path
    # halves red). Unset in this subshell only — every other python3 call in
    # the file keeps the suppression.
    unset PYTHONDONTWRITEBYTECODE
    cd "$I23" || exit 1
    git init -q -b work . && git config user.email t@t && git config user.name t
    printf '__pycache__/\n' > .gitignore
    printf 'def add(a, b):\n    return a + b\n' > calc.py
    printf 'from calc import add\nassert add(2, 3) == 5, add(2, 3)\n' > test_calc.py
    git add -A && git commit -qm correct
    python3 test_calc.py >/dev/null 2>&1        # builder run: writes the .pyc
    printf 'def add(a, b):\n    return a * b\n' > calc.py   # the defect
    # Stamp calc.py with the mtime the .pyc header ITSELF records, so the two
    # agree no matter how long the steps above took. Read AND applied in the
    # same python3 call: `date`'s epoch flag is a flavor split (BSD `-r`, GNU
    # `-d @`) and the `||` fallback shape between them is exactly what
    # check_portability rejects — os.utime takes the epoch directly and is the
    # same on every platform. python3 is already required by this case.
    python3 -c "
import glob, os, struct, sys
f = glob.glob('__pycache__/calc.*.pyc')
if not f: sys.exit(0)
mt = struct.unpack('<I', open(f[0], 'rb').read(12)[8:12])[0]
os.utime('calc.py', (mt, mt))
" 2>/dev/null
    git add -A && git commit -qm defect
  ) >/dev/null 2>&1
  # The tracked tree is clean — the control that makes this a trap rather than
  # an oversight. If this ever fails the fixture leaked a tracked change and
  # the two verdicts below prove nothing.
  I23PORC="$( cd "$I23" && git status --porcelain 2>/dev/null )"
  check "#23 the builder's tree reports clean (the contaminant is gitignored)" \
    "$([ -z "$I23PORC" ] && echo 0 || echo 1)"
  # Same opt-out as the builder subshell: this run must be allowed to CONSULT
  # the cache. PYTHONDONTWRITEBYTECODE suppresses writing, and reading a
  # already-written .pyc is unaffected — but keeping the two symmetrical is
  # what stops the next edit from re-introducing the asymmetry that broke this.
  ( unset PYTHONDONTWRITEBYTECODE; cd "$I23" && python3 test_calc.py >/dev/null 2>&1 ); I23IN=$?
  check "#23 the defect verifies GREEN in the builder's tree (stale .pyc served)" \
    "$([ "$I23IN" = 0 ] && echo 0 || echo 1)"
  I23C="$(newproj)"; rm -rf "$I23C"
  git clone -q "$I23" "$I23C" >/dev/null 2>&1
  ( cd "$I23C" && git checkout -q work >/dev/null 2>&1 )
  # A clone carries tracked files only, so the whole gitignored family evaporates
  # — the same property `agent(..., {isolation:'worktree'})` would buy the seat.
  check "#23 a clean checkout of that commit has no __pycache__" \
    "$([ ! -d "$I23C/__pycache__" ] && echo 0 || echo 1)"
  ( unset PYTHONDONTWRITEBYTECODE; cd "$I23C" && python3 test_calc.py >/dev/null 2>&1 ); I23CL=$?
  check "#23 the SAME commit FAILS in a clean checkout (verdict is tree-dependent)" \
    "$([ "$I23CL" != 0 ] && echo 0 || echo 1)"
  # And the scope line from --expect-clean is what an operator would have to
  # notice: green tree, non-zero ignored count.
  I23OUT="$( cd "$I23" && bash "$CLAIMS" --expect-clean 2>/dev/null )"
  check "#23 --expect-clean is green here yet reports the ignored entry" \
    "$(printf '%s' "$I23OUT" | grep -q '{item working-tree} ok' \
       && printf '%s' "$I23OUT" | grep -q '{item ignored-state} report: 1 ' \
       && echo 0 || echo 1)"
  rm -rf "$I23" "$I23C"
fi

########################################################################
echo "-- Case: ops-render --model is the resolver made scriptable (#55)"
# `--show` is a table for a human: aligned columns, a header, a trailing note.
# A caller that wants ONE id has to parse it, and parsing a display format is
# how a caller ends up with a header row as a model id. `--model <seat>` prints
# the id alone so a dispatch site can substitute it directly.
#
# The properties that matter are about the CHANNEL as much as the value: a
# warning captured into `M="$(... --model mechanic)"` becomes a model id nobody
# configured, and an unknown seat printing an empty line dispatches to the
# harness default — the silent mis-route the whole guard family exists to stop.
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
# Not a hardcoded map: a DIFFERENT seat on a DIFFERENT tier must follow its own
# binding, or the case would pass against a script that always printed one id.
check "#55 a second seat follows its own tier (crawler → MECHANICAL)" \
  "$([ "$(runmodel crawler 2>/dev/null)" = "glm-5-turbo" ] && echo 0 || echo 1)"
check "#55 the 'op-' prefix is optional, as everywhere else" \
  "$([ "$(runmodel op-mechanic 2>/dev/null)" = "$(runmodel mechanic 2>/dev/null)" ] && echo 0 || echo 1)"
# STDOUT IS THE CONTRACT: exactly one line, nothing else. Asserted by counting
# lines rather than by matching the id, because a diagnostic leaking onto stdout
# is the failure this guarantees against and it would still contain the id.
check "#55 stdout carries exactly one line (safe to command-substitute)" \
  "$([ "$(runmodel mechanic 2>/dev/null | wc -l | tr -d ' ')" = "1" ] && echo 0 || echo 1)"
# An unknown seat REFUSES. An empty line at rc 0 is the dangerous shape: the
# caller substitutes "" and the dispatch silently takes the harness default.
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
# It is the SAME resolver, not a second one: --model must apply exactly the
# guard --show applies, or it becomes a bypass. Both halves are pinned, because
# the guard's polarity changed in 0.8.3 and only the pair proves it moved as a
# unit — a MALFORMED field is refused, an UNRECOGNISED one resolves.
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
# `lock_holder_read` tests `[ -f "$LOCKDIR/holder" ]` and then reads the file.
# Between those two the releasing writer can remove it — and `2>/dev/null` on
# the `read` does NOT cover that, because the shell reports a failed INPUT
# redirection before the command's own redirections apply. The result was a raw
# `No such file or directory` at the operator, which this project treats as a
# defect class of its own ("raw bash error as operator guidance").
#
# Structural assertion, not a timing one: rather than racing real writers and
# hoping, this drives lock_holder_read directly with the holder file replaced by
# a path that cannot be opened. That reproduces the redirection failure on every
# run, where the natural race needed ~40 concurrent writers to show up once in
# three runs (measured, on this code and its 0.4.0 predecessor alike).
P="$(newproj)"
( cd "$P" && bash "$INIT" >/dev/null 2>&1 )
mkdir -p "$P/.operator/.lock"
cat > "$P/probe.sh" <<'HOLDPROBE'
set -u
LOCKDIR="$1"
# Take lock_holder_read verbatim from the CLI under test, so this cannot drift
# from the implementation: extract the function and eval it.
eval "$(sed -n '/^lock_holder_read() {$/,/^}$/p' "$2")"
# The file exists for the `[ -f ]` test and is unopenable for the read: a
# directory named `holder` passes -f? No — so use a file whose read fails by
# permission instead, which is the same redirection failure the race produces.
printf 'someone 1 2\n' > "$LOCKDIR/holder"
chmod 000 "$LOCKDIR/holder" 2>/dev/null || true
lock_holder_read
# Report the record on STDOUT so the control below attests to THIS run — the run
# whose stderr the first assertion reads. It used to re-extract the function in a
# separate one-liner, which meant the two assertions could exercise different
# code and, on bash 3.2, one of them exercised none at all (see the caller).
printf 'REC=[%s]\n' "$LOCK_HOLDER_REC"
chmod 644 "$LOCKDIR/holder" 2>/dev/null || true
HOLDPROBE
# Separate files rather than `2>&1 >/dev/null`: the two streams answer two
# different questions (did a raw bash error reach the operator; did the read
# actually fail) and both come from the SAME run.
bash "$P/probe.sh" "$P/.operator/.lock" "$VERDICT" >"$P/holder.out" 2>"$P/holder.err" || true
HOLDERR="$(cat "$P/holder.err")"
HOLDREC="$(cat "$P/holder.out")"
# root can read a 000 file, so the redirection never fails there — skip rather
# than assert a property the environment cannot exhibit.
if [ "$(id -u)" = "0" ]; then
  echo "  skip holder-read case: running as root, a 000 file is still readable"
else
  check "a failed holder read prints no raw bash error to the operator" \
    "$(printf '%s' "$HOLDERR" | grep -qE 'No such file|Permission denied' && echo 1 || echo 0)"
  # The control: the guard is only meaningful if the probe REACHED the read.
  # An empty record is what a failed read must leave behind — the documented
  # "cannot judge this holder" input the caller already handles.
  #
  # This reads the probe's own stdout. The earlier form re-extracted the function
  # inside `bash -c '… eval "$(sed -n "/^…{\$/,/^}\$/p" …)" …'`, and under bash 3.2
  # the nested double quotes inside `"$( … )"` do not survive: the `{…,…}` in the
  # sed address became a BRACE EXPANSION, sed got a mangled script ("invalid
  # command code $"), the function was never defined, and the assertion failed on
  # every darwin run while ubuntu's bash 5 parsed it correctly and stayed green.
  # A control that cannot pass is worse than no control — it is #21's class with
  # the polarity inverted. check_platform_idioms now bans the shape.
  check "control: the probe's read actually failed (guard was exercised)" \
    "$([ "$HOLDREC" = "REC=[]" ] && echo 0 || echo 1)"
fi
rm -rf "$P"

########################################################################
echo "-- Case: the lock spin has an absolute ceiling (#68)"
# The bug: lock_acquire treated EVERY mkdir failure as contention. Only EEXIST
# means contention; ENOENT — the ledger directory removed while a run is in
# flight — is permanent, and every escape hatch opened with another mkdir in the
# same vanished parent, so none of them completed. Both existing budgets count
# ITERATIONS and both `continue` past their own limit in that state, and the
# deferral path actively REWINDS `i`, so neither bounds the loop.
#
# Measured on a dev machine before the fix: 54 leaked ops-verdict.sh processes,
# the oldest ~17 days, ~1 core burned continuously, 2.7MB of warnings written
# into a closed stdout. The load made an unrelated project's timing-sensitive
# gates read 2.5x their baseline.
#
# The ceiling is tested rather than the ENOENT special-case because the ceiling
# is what bounds EVERY cause, including ones not yet met. Timing is used as an
# assertion here (elapsed < the watchdog), which this suite otherwise avoids —
# but the property under test IS "does it terminate", and there is no structural
# proxy for that. It is made safe by a wide margin: a 3s ceiling against a 20s
# watchdog, so only a genuinely unbounded loop fails it. Measured under load:
# loadavg 63 on 20 cores moved the elapsed time by 0.2s, because the loop is
# dominated by `sleep 0.1`, not by CPU.
P="$(newproj)"
( cd "$P" && bash "$INIT" >/dev/null 2>&1 )
mkdir -p "$P/.operator/.lock"
# A foreign host + foreign uid + a pid that is not ours: holder_state cannot
# judge it, so lock_acquire takes the time-based path rather than reclaiming.
printf 'someoneelse.example 65534 999999\n' > "$P/.operator/.lock/holder"
( cd "$P" && bash "$TASK" T-CEIL --owner SESS-A >/dev/null 2>&1 )
CEILERR="$P.ceil.err"
# All four budgets scale together, and the spin budgets must outlast the 1s
# delete below. Measured while writing this: with LOCK_SPINS=6 the reclaim path
# SUCCEEDS inside that first second, the run records normally, and the case
# proves nothing — a green assertion against a state never entered. The ceiling
# must also exceed both spin budgets or the script refuses at budget validation
# (its own guard), which is a different rc 2 than the one under test.
(
  cd "$P" && LOCK_SPINS=25 LOCK_LIVE_SPINS=25 RECLAIM_WAIT=5 LOCK_MAX_SPINS=30 \
    bash "$VERDICT" T-CEIL c e PASS --owner SESS-A >/dev/null 2>"$CEILERR"
) &
CEILPID=$!
# Remove the ledger AFTER the run is past its own "no .operator/ in cwd" check
# and inside the spin loop. Deleting it beforehand tests a different guard.
sleep 1 & wait $! 2>/dev/null || true
rm -rf "$P/.operator"
# Watchdog: a still-spinning build must not hang the suite. Its own kill is what
# distinguishes "terminated by the ceiling" from "terminated by us".
( sleep 20; kill -9 "$CEILPID" 2>/dev/null ) & CEILWD=$!
wait "$CEILPID" 2>/dev/null; CEILRC=$?
# The watchdog is a `( … ) &` subshell too, so `kill $CEILWD` alone orphans the
# `sleep` inside it — the identical mechanism this case exists to prove fixed,
# in the case's own scaffolding. Smaller blast radius (a bare sleep, no CPU,
# gone in <=20s) but the standard is the same: reap the child first. Measured
# before fixing: `after kill+wait, sleep survivors=[49573]`.
reap_kids "$CEILWD"
kill "$CEILWD" 2>/dev/null || true; wait "$CEILWD" 2>/dev/null || true
# Reap any orphaned grandchild before asserting, so a failure here cannot leave
# the very process class this case exists to prevent. Descendant-scoped via
# `pgrep -P`, NOT `pkill -f`: this project's lock exists to support concurrent
# checkouts, and a machine-wide pattern kill reaches into another checkout's
# suite run — which is exactly what a maintainer does during a review round.
reap_kids "$CEILPID"
# rc 137 is the watchdog's SIGKILL — i.e. it was STILL SPINNING. Any other exit
# means the loop ended on its own, which is the property under test.
check "#68 the spin loop terminates on its own (not by the watchdog's kill)" \
  "$([ "$CEILRC" != 137 ] && echo 0 || echo 1)"
check "#68 it refuses rather than proceeding unlocked (rc 2)" \
  "$([ "$CEILRC" = 2 ] && echo 0 || echo 1)"
check "#68 the ceiling message names the timeout" \
  "$(grep -q 'refusing to spin further' "$CEILERR" 2>/dev/null && echo 0 || echo 1)"
# The diagnosis half: a generic timeout sends a maintainer hunting a contention
# problem that does not exist. When the cause is knowable, it must be named.
check "#68 it names the vanished ledger directory as the cause" \
  "$(grep -q 'removed while this run was in flight' "$CEILERR" 2>/dev/null && echo 0 || echo 1)"
rm -f "$CEILERR"; rm -rf "$P"

# The SIBLING CLI's copy of the ceiling, executed rather than assumed.
# check_lock_parity pins the two blocks byte-for-byte, and the bash suite has
# its own parity case — but parity proves SAMENESS, not correctness-in-context.
# Two identically-correct-looking copies in different surroundings is the F30
# shape this repo has already been bitten by: ops-adopt.sh derives its own
# LOCKDIR, has its own call site and its own argument handling, and none of that
# is covered by comparing the block to its twin. Reported by the review panel on
# this very commit, which found LOCK_MAX_SPINS executed at exactly one site.
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
# The message must carry the SIBLING's tool name. check_lock_parity normalizes
# `ops-tool:` prefixes away before comparing, so a copy that announced itself as
# ops-verdict would pass parity and mislead every operator reading the output.
check "#68 ops-adopt names ITSELF in the ceiling message, not its sibling" \
  "$(grep -q '^ops-adopt: could not acquire' "$ADERR" 2>/dev/null && echo 0 || echo 1)"
rm -f "$ADERR"; rm -rf "$P"

########################################################################
echo "-- Case: the security fixture corpus is a working instrument (#24 step 1)"
# The corpus under tests/fixtures/security/ exists to measure the review panel:
# each fixture is a functionally-correct file with a real security defect, paired
# with a corrected variant. That pairing is the whole design, and it is only a
# measurement instrument if all four cells hold:
#
#   vuln  FUNCTIONAL: ok  — else the defect is caught by machinery that already
#                           exists (a failing test), and the panel is not what
#                           is being measured
#   vuln  EXPLOIT: fired  — else the "vulnerable" file is not vulnerable and a
#                           lens that stays silent is CORRECT to. This is the
#                           cell that caught a miscalibrated probe during the
#                           corpus's own construction: guard-two-of-three's
#                           traversal assertion was one directory level too high
#                           and read "blocked" against the defective script.
#   fixed FUNCTIONAL: ok  — else the fix traded the feature away, and "the panel
#                           flags vuln but not fixed" measures nothing
#   fixed EXPLOIT: blocked— the false-positive control. A lens that flags both
#                           columns has pattern-matched on the topic, not
#                           detected a defect.
#
# So this case does NOT test the plugin. It tests the ruler, and it fails the
# build when the ruler bends — which is the only reason a later detection-rate
# claim drawn from this corpus means anything.
SECDIR="$REPO/tests/fixtures/security"
if [ -d "$SECDIR" ]; then
  SEC_FIXTURES="frag-traversal sweep-rm guard-two-of-three ext-source secret-in-error"
  # Pinned by name rather than globbed: a fixture directory that silently
  # disappears would otherwise shrink the corpus with the suite still green,
  # and "the panel detected 3/3" reads identically to "3 of 5 fixtures were
  # deleted". The count is asserted for the same reason.
  SEC_FOUND=0
  for _f in $SEC_FIXTURES; do
    [ -d "$SECDIR/$_f" ] && SEC_FOUND=$((SEC_FOUND + 1))
  done
  check "#24 all 5 named security fixtures are present" \
    "$([ "$SEC_FOUND" = 5 ] && echo 0 || echo 1)"

  for _f in $SEC_FIXTURES; do
    if [ ! -f "$SECDIR/$_f/probe.sh" ]; then
      fail "#24 $_f: probe.sh missing"
      continue
    fi
    # Both targets must EXIST before the probe runs. `EXPLOIT: blocked` is the
    # verdict a probe returns when the script it was pointed at never ran at
    # all — so a deleted or renamed fixed.sh reads as "the fix works". The
    # adjacent FUNCTIONAL cell would still catch it, but an assertion that
    # carries no information on its own is the one that gets trusted later.
    if [ ! -f "$SECDIR/$_f/vuln.sh" ] || [ ! -f "$SECDIR/$_f/fixed.sh" ]; then
      fail "#24 $_f: vuln.sh and fixed.sh both present (a missing target reads as 'blocked')"
      continue
    fi
    _V="$(bash "$SECDIR/$_f/probe.sh" "$SECDIR/$_f/vuln.sh" 2>/dev/null)"
    _X="$(bash "$SECDIR/$_f/probe.sh" "$SECDIR/$_f/fixed.sh" 2>/dev/null)"
    check "#24 $_f: vuln is FUNCTIONALLY CORRECT (no existing gate catches it)" \
      "$(printf '%s' "$_V" | grep -q '^FUNCTIONAL: ok$' && echo 0 || echo 1)"
    check "#24 $_f: vuln's EXPLOIT FIRES (the defect is real, not described)" \
      "$(printf '%s' "$_V" | grep -q '^EXPLOIT: fired$' && echo 0 || echo 1)"
    check "#24 $_f: fixed keeps the feature working (the fix is not a deletion)" \
      "$(printf '%s' "$_X" | grep -q '^FUNCTIONAL: ok$' && echo 0 || echo 1)"
    check "#24 $_f: fixed BLOCKS the exploit (the false-positive control)" \
      "$(printf '%s' "$_X" | grep -q '^EXPLOIT: blocked$' && echo 0 || echo 1)"
    # Every fixture must carry the analysis that says what a DETECTION is. A
    # corpus of vulnerable files without it invites "the lens mentioned input
    # validation" to be scored as a hit — the vacuity class (#21) applied to a
    # measurement rather than a guard.
    check "#24 $_f: NOTES.md states what a detection must say" \
      "$([ -f "$SECDIR/$_f/NOTES.md" ] \
         && grep -q 'A detection must say' "$SECDIR/$_f/NOTES.md" && echo 0 || echo 1)"
  done

  # The corpus must stay INERT. It is vulnerable code living in the repo, and
  # the one thing that must never happen is a shipped script sourcing or
  # executing it. Checked against scripts/ and hooks/ rather than assumed from
  # the directory it sits in.
  # BOTH structural probes below assert on an EMPTY result, and both silence
  # their own errors — so a broken command produces exactly the output that
  # means "clean". Measured directly: point either at a nonexistent tree and it
  # reports ok. That is the vacuous-guard class (#21) inside the very case that
  # exists to keep the corpus honest.
  #
  # So each is paired with a POSITIVE CONTROL: the same command, same flags,
  # aimed at a place where the answer is known to be non-empty. If the control
  # comes back empty the tool is not working, and the adjacent "clean" verdict
  # is worth nothing — which the control's own failure now says out loud.
  # EVERY shipped directory, not just scripts/ and hooks/. The first draft
  # checked those two and called it "no shipped script or hook" — but the plugin
  # also ships workflows/ (executable JS the validator parses), agents/,
  # commands/, skills/ and templates/. A workflow referencing the corpus would
  # have passed a check whose name promised otherwise.
  #
  # ONE EXEMPTION, and it is narrow enough to name rather than describe:
  # scripts/ops-corpus.sh (#69). It is the maintainer's corpus builder — its
  # entire job is to take a corpus path as an ARGUMENT and produce a stamped,
  # neutralized tree from it, and its header explains which measurement failure
  # made it necessary. That header is where the string appears. What this case
  # actually protects is that no shipped code READS the corpus at runtime: a
  # hook sourcing a fixture, a workflow pointing a lens at one, a CLI with a
  # hardcoded fixture path it opens. So the exemption is by FILENAME, not by a
  # loosened pattern — a second file gaining the string still fails, and if
  # ops-corpus.sh ever grows a default that opens the corpus without being told
  # to, the #69 cases below are where that shows up.
  #
  # The alternative was rewording the header to dodge the grep. That trades a
  # true sentence for a green check, which is the drift class #70 measures.
  SEC_REF="$(grep -rl 'fixtures/security' \
    "$REPO/scripts" "$REPO/hooks" "$REPO/workflows" "$REPO/agents" \
    "$REPO/commands" "$REPO/skills" "$REPO/templates" 2>/dev/null \
    | grep -v '/scripts/ops-corpus\.sh$' | head -1)"
  # This suite file references the corpus by that exact string, so grep must
  # find it here. A grep that cannot find a string that IS present is broken.
  SEC_REF_CTL="$(grep -rl 'fixtures/security' "$REPO/tests/test-scripts.sh" 2>/dev/null | head -1)"
  check "#24 control: the inert probe's grep actually finds a known reference" \
    "$([ -n "$SEC_REF_CTL" ] && echo 0 || echo 1)"
  check "#24 no shipped script or hook references the fixture corpus (inert)" \
    "$([ -z "$SEC_REF" ] && echo 0 || echo 1)"
  # The exemption's own control: an exemption nobody tests is a hole nobody
  # sees. Re-run the identical grep WITHOUT the filter — it must find exactly
  # ops-corpus.sh and nothing else. If the header is ever reworded away, this
  # goes red and the filter above becomes dead weight the next reader can drop.
  SEC_REF_ALL="$(grep -rl 'fixtures/security' \
    "$REPO/scripts" "$REPO/hooks" "$REPO/workflows" "$REPO/agents" \
    "$REPO/commands" "$REPO/skills" "$REPO/templates" 2>/dev/null | LC_ALL=C sort)"
  check "#24 the ops-corpus.sh exemption is exactly one file, and it is that file" \
    "$([ "$SEC_REF_ALL" = "$REPO/scripts/ops-corpus.sh" ] && echo 0 || echo 1)"
  # No mode bits: fixtures are invoked as `bash <path>`, and a vulnerable file
  # that is directly executable is one PATH mistake away from being run.
  # ANY of user/group/other, not just the owner bit. The stated hazard is "one
  # PATH mistake away from being run", and that is not confined to the owner — a
  # 0645 fixture is executable by everyone EXCEPT its owner, and `-perm -u+x`
  # does not match it.
  #
  # Spelled as an explicit OR rather than `-perm /111`: BSD find (macOS) does
  # not accept the `/` form and exits non-zero, which — with the 2>/dev/null
  # below — produces empty output, i.e. exactly the result that means "clean".
  # Caught by the control immediately below, on its first run, which is the
  # entire reason the control exists (validate_plugin.check_platform_idioms
  # bans the try-BSD-then-GNU fallback for the same reason).
  SEC_EXEC="$(find "$SECDIR" -name '*.sh' \
    \( -perm -u+x -o -perm -g+x -o -perm -o+x \) 2>/dev/null | head -1)"
  # The whole probe rests on that flag behaving. `.operator/bin/` CLIs are
  # installed 0755 by ops-init, so this is a tree where a working find MUST
  # return something. Skipped, not failed, when the project has no
  # .operator/bin — the control's precondition, not the project's.
  if [ -d "$REPO/.operator/bin" ]; then
    SEC_EXEC_CTL="$(find "$REPO/.operator/bin" -name '*.sh' \
      \( -perm -u+x -o -perm -g+x -o -perm -o+x \) 2>/dev/null | head -1)"
    check "#24 control: the exec-bit probe's find actually finds a known 0755 file" \
      "$([ -n "$SEC_EXEC_CTL" ] && echo 0 || echo 1)"
  else
    # ANNOUNCED, not silent — and this skip is the CI path, not an edge case:
    # `.operator/` is gitignored, so a bare actions/checkout runner never has
    # one, and the control that backs the exec-bit probe would be absent in the
    # one environment that gates merges. A case that silently does not run is
    # the vacuous-guard class this repo keeps catching, so say it out loud
    # (same idiom as the #23 fixture's skip line).
    echo "  skip #24 exec-bit control: no .operator/bin in this tree (gitignored; expected in CI)"
  fi
  check "#24 no fixture carries an execute bit" \
    "$([ -z "$SEC_EXEC" ] && echo 0 || echo 1)"
else
  fail "#24 the security fixture corpus is present at tests/fixtures/security"
fi

########################################################################
echo "-- Case: #69 the derived corpus tree is a stamped artifact (ops-corpus.sh)"
# MEASURED (#69): during #24 step 3 a scratch tree built in step 2 was reused
# after the source fixtures had been fixed. The panel correctly reported defects
# in code that no longer shipped, and the number read as a mass false-positive
# — which would have invalidated the tier result had it been believed. Nothing
# noticed, because every assertion above is about tests/fixtures/security/ and
# none is about the DERIVED copy that is the panel's actual input.
#
# What is pinned here is the property that makes staleness an ERROR rather than
# a plausible number, plus the two neutralization properties whose absence would
# make a measurement built with this tool worthless:
#   1. a fresh tree verifies; a corpus that moved under it does NOT
#   2. an unstamped tree is refused with its OWN exit code (3, not 2) — a
#      partial tree from an aborted build is exactly this shape, so the two are
#      reachable in one session and a caller must tell them apart without
#      parsing English
#   3. the derived tree carries NO corpus vocabulary — no README/NOTES/
#      MEASUREMENT, no vuln*/fixed* filename. A lens shown any of those is not
#      being measured on detection, it is being asked to agree.
CORPUS="$SCRIPTS/ops-corpus.sh"
_MAPN=".ops-corpus-map"   # the map filename, as ops-corpus.sh defines it
if [ ! -x "$CORPUS" ] && [ ! -f "$CORPUS" ]; then
  fail "#69 scripts/ops-corpus.sh is present"
elif [ ! -d "$SECDIR" ]; then
  fail "#69 the security corpus is present (ops-corpus cases need a corpus to build from)"
else
  _CTMP="$(newproj)"
  _COUT="$_CTMP/derived"
  # --out lives OUTSIDE the repo by construction here (mktemp -d), which is also
  # what ops-corpus itself refuses to violate.
  if bash "$CORPUS" build --corpus "$SECDIR" --out "$_COUT" >/dev/null 2>&1; then
    check "#69 build produces a tree" "$([ -d "$_COUT" ] && echo 0 || echo 1)"
    bash "$CORPUS" verify --corpus "$SECDIR" --tree "$_COUT" >/dev/null 2>&1
    check "#69 a freshly built tree verifies against its corpus" "$?"

    # STALE: the corpus moves, the tree does not. Simulated on a COPY of the
    # corpus, never on the repo's own fixtures — a suite that mutates tracked
    # files and restores them is one interrupted run away from a dirty tree.
    _CSRC="$_CTMP/corpus"
    cp -R "$SECDIR" "$_CSRC"
    _COUT2="$_CTMP/derived2"
    bash "$CORPUS" build --corpus "$_CSRC" --out "$_COUT2" >/dev/null 2>&1
    printf '\n# drift\n' >> "$_CSRC/README.md"
    bash "$CORPUS" verify --corpus "$_CSRC" --tree "$_COUT2" >/dev/null 2>&1
    _RC=$?
    check "#69 a corpus that changed under the tree is REFUSED (stale, exit 2)" \
      "$([ "$_RC" -eq 2 ] && echo 0 || echo 1)"

    # UNSTAMPED: distinct exit code, because an aborted build leaves precisely
    # this and "rebuild me" is a different instruction from "I don't know what
    # this directory is".
    rm -f "$_COUT2/.ops-corpus-stamp"
    bash "$CORPUS" verify --corpus "$_CSRC" --tree "$_COUT2" >/dev/null 2>&1
    _RC=$?
    check "#69 an unstamped tree is refused with its OWN code (3, not the stale 2)" \
      "$([ "$_RC" -eq 3 ] && echo 0 || echo 1)"

    # NEUTRALIZATION. The `head -1` output is quoted in the failure the same way
    # the #24 probes do it — an assertion that just says "leaked" sends the next
    # reader hunting.
    _LEAK="$(find "$_COUT" -type f \( -name 'NOTES.md' -o -name 'README.md' \
      -o -name 'MEASUREMENT.md' -o -name 'vuln*' -o -name 'fixed*' \) 2>/dev/null | head -1)"
    check "#69 the derived tree carries no corpus-vocabulary file (${_LEAK:-none})" \
      "$([ -z "$_LEAK" ] && echo 0 || echo 1)"
    # Positive control, the #24 idiom: the same find, aimed where the answer is
    # known non-empty. A find that cannot locate a file that IS there makes the
    # clean verdict above worthless — and says so itself.
    _LEAK_CTL="$(find "$SECDIR" -type f -name 'README.md' 2>/dev/null | head -1)"
    check "#69 control: the leak probe's find actually finds a known README.md" \
      "$([ -n "$_LEAK_CTL" ] && echo 0 || echo 1)"

    # A rebuild must not leave a previous build's files behind: a fixture
    # renamed or dropped upstream would otherwise haunt every later measurement,
    # which is #69's own failure with extra steps.
    : > "$_COUT/ORPHAN-from-a-previous-build.md"
    bash "$CORPUS" build --corpus "$SECDIR" --out "$_COUT" --force >/dev/null 2>&1
    check "#69 --force rebuild EMPTIES the tree (no orphan from a prior build)" \
      "$([ ! -f "$_COUT/ORPHAN-from-a-previous-build.md" ] && echo 0 || echo 1)"

    # An unmapped fixture directory must be refused, not silently omitted:
    # building 5 of 6 and printing "built" is the #69 shape exactly.
    mkdir -p "$_CSRC/an-unmapped-fixture"
    : > "$_CSRC/an-unmapped-fixture/vuln.sh"
    bash "$CORPUS" build --corpus "$_CSRC" --out "$_CTMP/derived3" >/dev/null 2>&1
    _RC=$?
    check "#69 a corpus dir the map does not name is REFUSED, not silently omitted" \
      "$([ "$_RC" -ne 0 ] && echo 0 || echo 1)"

    # EVERY map field is parsed input reaching a path, and every one is guarded.
    # The first shape guarded only the write side (`dest`) while `dir`/`src`
    # flowed unchecked into the read — measured: a `../..` fixture path copies a
    # file from OUTSIDE the corpus into the derived tree, and because
    # corpus_hash walks the corpus, that content is in no stamp and `verify`
    # reports ok. The staleness guarantee #69 exists for is only as strong as
    # the guarantee that every byte in the tree came from the corpus, so these
    # are #69 cases, not merely hardening.
    _EVIL="$_CTMP/evil"; mkdir -p "$_EVIL/f1"
    : > "$_EVIL/f1/src.sh"
    printf 'outside-the-corpus\n' > "$_CTMP/OUTSIDE.txt"
    # 1. traversal on the FIXTURE PATH (which legitimately may contain `/`, so
    #    it is checked for `..`, not for being a bare name).
    printf 'f1/../.. OUTSIDE.txt leaked.txt\n' > "$_EVIL/$_MAPN"
    bash "$CORPUS" build --corpus "$_EVIL" --out "$_CTMP/evilout" >/dev/null 2>&1
    _RC=$?
    check "#69 a map fixture-path containing '..' is refused (reads outside the corpus)" \
      "$([ "$_RC" -ne 0 ] && echo 0 || echo 1)"
    check "#69 control: the refused traversal build left no leaked file behind" \
      "$([ ! -f "$_CTMP/evilout/leaked.txt" ] && echo 0 || echo 1)"
    # 2. traversal on the SOURCE name, which is a bare filename.
    printf 'f1 ../../OUTSIDE.txt leaked.txt\n' > "$_EVIL/$_MAPN"
    bash "$CORPUS" build --corpus "$_EVIL" --out "$_CTMP/evilout2" >/dev/null 2>&1
    _RC=$?
    check "#69 a map source-name containing a path separator is refused" \
      "$([ "$_RC" -ne 0 ] && echo 0 || echo 1)"
    # 3. the same reach wearing a different hat: `-f` follows a symlink and `cp`
    #    (no -P) copies the TARGET's content, so a link planted in the corpus
    #    reaches the tree with bytes from anywhere on disk — equally invisible to
    #    the stamp. Same non-symlink-regular-file contract as every other file
    #    this repo's CLIs trust.
    ln -sf "$_CTMP/OUTSIDE.txt" "$_EVIL/f1/link.sh"
    printf 'f1 link.sh leaked.txt\n' > "$_EVIL/$_MAPN"
    bash "$CORPUS" build --corpus "$_EVIL" --out "$_CTMP/evilout3" >/dev/null 2>&1
    _RC=$?
    check "#69 a map source that is a SYMLINK is refused (its target is in no stamp)" \
      "$([ "$_RC" -ne 0 ] && echo 0 || echo 1)"
    check "#69 control: the refused symlink build copied no outside content" \
      "$([ ! -f "$_CTMP/evilout3/leaked.txt" ] && echo 0 || echo 1)"
    # Positive control for all five above: the SAME corpus with a legitimate map
    # line builds. Without it, a script that refused everything unconditionally
    # would score five passes here.
    printf 'f1 src.sh ok.sh\n' > "$_EVIL/$_MAPN"
    bash "$CORPUS" build --corpus "$_EVIL" --out "$_CTMP/evilout4" >/dev/null 2>&1
    _RC=$?
    check "#69 control: a legitimate map line on the same corpus still builds" \
      "$([ "$_RC" -eq 0 ] && [ -f "$_CTMP/evilout4/ok.sh" ] && echo 0 || echo 1)"

    # 4. A SYMLINKED DIRECTORY, which is the case the first two rounds of guards
    #    both missed. `..` in the string and a symlinked LEAF file were both
    #    refused, and `ln -s /outside <corpus>/d` with a map line `d f out` still
    #    walked straight through: `[ -f ]` and `cp` follow the link, while
    #    corpus_hash's `find` (no -L) does NOT descend it — so the content lands
    #    in the tree, is in no stamp, and `verify` prints ok. Measured. The guard
    #    is now a RESOLVED-path containment check, not a string check, which is
    #    why this case tests the resolved property rather than the spelling.
    #
    #    ITS OWN CORPUS, not $_EVIL, and that is the case's whole validity: the
    #    first draft reused $_EVIL, which still holds an `f1/` the one-line map
    #    does not name — so the unmapped-directory check refused the build FIRST
    #    and the case passed green with the containment guard neutered. Caught by
    #    mutation, which is the only thing that could have caught it: every
    #    assertion read exactly as intended, on a refusal from the wrong guard.
    _SLINK="$_CTMP/slinkcorpus"; mkdir -p "$_SLINK"
    mkdir -p "$_CTMP/outside"
    printf 'outside-content\n' > "$_CTMP/outside/secret.txt"
    ln -s "$_CTMP/outside" "$_SLINK/evildir"
    printf 'evildir secret.txt leaked.txt\n' > "$_SLINK/$_MAPN"
    bash "$CORPUS" build --corpus "$_SLINK" --out "$_CTMP/evilout5" >/dev/null 2>&1
    _RC=$?
    check "#69 a map fixture-path that RESOLVES outside the corpus is refused (symlinked dir)" \
      "$([ "$_RC" -ne 0 ] && echo 0 || echo 1)"
    check "#69 control: the refused symlinked-dir build copied no outside content" \
      "$([ ! -f "$_CTMP/evilout5/leaked.txt" ] && echo 0 || echo 1)"
    # Control: the SAME corpus with the symlink replaced by a real directory
    # builds. Without it the two cases above pass on any refusal, including the
    # wrong-guard refusal that is exactly how the first draft went green.
    rm -f "$_SLINK/evildir"
    mkdir -p "$_SLINK/evildir"
    printf 'inside-content\n' > "$_SLINK/evildir/secret.txt"
    bash "$CORPUS" build --corpus "$_SLINK" --out "$_CTMP/evilout5b" >/dev/null 2>&1
    _RC=$?
    check "#69 control: the same corpus with a REAL directory builds (the refusal was the symlink)" \
      "$([ "$_RC" -eq 0 ] && [ -f "$_CTMP/evilout5b/leaked.txt" ] && echo 0 || echo 1)"

    # 5. corpus_hash must FAIL LOUDLY rather than hash a short corpus. `set -e`
    #    does not see a failure inside a non-final pipeline stage and the final
    #    stage exits 0 whatever bytes reached it, so an unreadable file produced a
    #    plausible hash and exit 0 — and because it is deterministic, `verify`
    #    recomputed the same wrong value and printed ok. A plausible number inside
    #    the mechanism whose whole purpose is to replace plausible numbers with
    #    errors. Skipped as root, which can read anything.
    if [ "$(id -u)" -ne 0 ]; then
      _NOREAD="$_CTMP/noread"; mkdir -p "$_NOREAD/f1"
      printf 'readable\n' > "$_NOREAD/f1/a.sh"
      printf 'unreadable\n' > "$_NOREAD/f1/b.sh"
      printf 'f1 a.sh ok.sh\n' > "$_NOREAD/$_MAPN"
      chmod 000 "$_NOREAD/f1/b.sh"
      bash "$CORPUS" build --corpus "$_NOREAD" --out "$_CTMP/noreadout" >/dev/null 2>&1
      _RC=$?
      chmod 644 "$_NOREAD/f1/b.sh"
      check "#69 an unreadable file in the corpus fails the build, not the hash silently" \
        "$([ "$_RC" -ne 0 ] && echo 0 || echo 1)"
      # Control: the SAME corpus, all files readable, builds — otherwise a script
      # that refused every corpus would pass the case above.
      bash "$CORPUS" build --corpus "$_NOREAD" --out "$_CTMP/noreadout2" >/dev/null 2>&1
      _RC=$?
      check "#69 control: the same corpus with every file readable builds" \
        "$([ "$_RC" -eq 0 ] && echo 0 || echo 1)"

      # 5b. A find that fails MID-WALK. Both of these were live defects found by
      #     the REPLAY-CHARTER R7 adversarial seat (2026-08-16) in the very fix
      #     written to close the short-hash class — the guard's own comment
      #     claimed the failure was checkable while the code checked the wrong
      #     thing. `if ! find … | sort > list` tests SORT, which succeeds on a
      #     partial stream, so an undescendable subdirectory produced a green
      #     build AND a green verify over a corpus missing files.
      _UNWALK="$_CTMP/unwalkable"; mkdir -p "$_UNWALK/f1/deep"
      printf 'code\n' > "$_UNWALK/f1/prod.sh"
      printf 'x\n' > "$_UNWALK/f1/deep/hidden.sh"
      printf 'f1 prod.sh runner.sh\n' > "$_UNWALK/$_MAPN"
      chmod 000 "$_UNWALK/f1/deep"
      bash "$CORPUS" build --corpus "$_UNWALK" --out "$_CTMP/unwalkout" >/dev/null 2>&1
      _RC=$?
      chmod 755 "$_UNWALK/f1/deep"
      check "#69 a corpus find cannot fully walk is REFUSED, not stamped short" \
        "$([ "$_RC" -ne 0 ] && echo 0 || echo 1)"
      bash "$CORPUS" build --corpus "$_UNWALK" --out "$_CTMP/unwalkout2" >/dev/null 2>&1
      _RC=$?
      check "#69 control: the same corpus with every directory readable builds" \
        "$([ "$_RC" -eq 0 ] && echo 0 || echo 1)"
    else
      echo "  skip #69 unreadable-file case: running as root, which can read anything"
    fi

    # 5c. A filename containing a NEWLINE. The first guard for this was vacuous —
    #     it compared `grep -c ''` of the listing against `grep -c ''` of the same
    #     `find -print` output, and a newline splits BOTH sides identically, so
    #     the counts always matched (measured: lines=3 files=3 on a 2-file corpus).
    #     Counting NULs from `-print0` is what makes the two numbers differ.
    #     Not inside the non-root branch: this needs no permission trick.
    _NLC="$_CTMP/newlinecorpus"; mkdir -p "$_NLC/f1"
    printf 'code\n' > "$_NLC/f1/prod.sh"
    printf 'f1 prod.sh runner.sh\n' > "$_NLC/$_MAPN"
    # The literal newline in the name is the whole point; build it with printf so
    # the intent is visible rather than hidden in an escaped string.
    _NLNAME="$(printf 'a\nb.txt')"
    printf 'y\n' > "$_NLC/f1/$_NLNAME"
    bash "$CORPUS" build --corpus "$_NLC" --out "$_CTMP/nlout" >/dev/null 2>&1
    _RC=$?
    check "#69 a filename with a newline is REFUSED (its stamp would be unreproducible)" \
      "$([ "$_RC" -ne 0 ] && echo 0 || echo 1)"
    rm -f "$_NLC/f1/$_NLNAME"
    bash "$CORPUS" build --corpus "$_NLC" --out "$_CTMP/nlout2" >/dev/null 2>&1
    _RC=$?
    check "#69 control: the same corpus without the newline name builds" \
      "$([ "$_RC" -eq 0 ] && echo 0 || echo 1)"

    # 5d. The STAMP FILENAME is reserved as a production name. Measured (Copilot,
    #     PR #72): a map line mapping a fixture to `.ops-corpus-stamp` copies the
    #     source successfully, then the stamp write at the end of build overwrites
    #     it with the hash — so build announced "2 file(s)", the tree held one,
    #     and `verify` reported ok because the stamp it read was exactly the one
    #     it expected. #69's own shape, inside #69's own tool: a plausible number
    #     where an error belongs.
    _STAMPC="$_CTMP/stampcollide"; mkdir -p "$_STAMPC/f1"
    printf 'A\n' > "$_STAMPC/f1/a.sh"
    printf 'B\n' > "$_STAMPC/f1/b.sh"
    printf 'f1 a.sh ok.sh\nf1 b.sh .ops-corpus-stamp\n' > "$_STAMPC/$_MAPN"
    bash "$CORPUS" build --corpus "$_STAMPC" --out "$_CTMP/stampout" >/dev/null 2>&1
    _RC=$?
    check "#69 a map claiming the stamp filename is REFUSED (it would be overwritten, one file short, verify green)" \
      "$([ "$_RC" -ne 0 ] && echo 0 || echo 1)"
    # ...and CASE-INSENSITIVELY. `case` compares bytes; APFS (stock macOS) does
    # not. Measured: `.OPS-CORPUS-STAMP` sailed past the byte-exact guard, cp and
    # the stamp write hit the SAME directory entry, and the build printed
    # "2 file(s)" over a one-file tree that verified green — the guard's own
    # target, reached through case (silent-failure review, PR #72). The case runs
    # on every platform: on a case-SENSITIVE filesystem the refusal is still
    # correct behaviour, just not load-bearing, and asserting it there keeps the
    # guard from being quietly dropped by someone testing on Linux only.
    printf 'f1 a.sh ok.sh\nf1 b.sh .OPS-CORPUS-STAMP\n' > "$_STAMPC/$_MAPN"
    bash "$CORPUS" build --corpus "$_STAMPC" --out "$_CTMP/stampout_case" >/dev/null 2>&1
    _RC=$?
    check "#69 a map claiming the stamp filename in another CASE is REFUSED too" \
      "$([ "$_RC" -ne 0 ] && echo 0 || echo 1)"

    # Control: the SAME corpus with a normal second name builds, and the tree
    # actually holds BOTH files — the count and the contents agreeing is the
    # property the collision broke.
    printf 'f1 a.sh ok.sh\nf1 b.sh also.sh\n' > "$_STAMPC/$_MAPN"
    bash "$CORPUS" build --corpus "$_STAMPC" --out "$_CTMP/stampout2" >/dev/null 2>&1
    _RC=$?
    check "#69 control: the same corpus with a non-reserved name builds BOTH files" \
      "$([ "$_RC" -eq 0 ] && [ -f "$_CTMP/stampout2/ok.sh" ] && [ -f "$_CTMP/stampout2/also.sh" ] && echo 0 || echo 1)"

    # 5e. TEMP-FILE HYGIENE. corpus_hash makes three temp files and runs inside a
    #     command substitution, so `die` ends that subshell and no cleanup after
    #     the substitution can ever run — the explicit `rm -f` lines covered the
    #     guards that had them and nothing else. Measured: 83 opscorp.* left in
    #     TMPDIR by one afternoon of runs. Now a trap in the same subshell, which
    #     is the only construct that covers every exit including a `die` inside
    #     the read loop.
    #
    #     Counted with `find | grep -c ''` rather than `ls | wc -l`: `ls` on a
    #     no-match glob prints an error and a count of 1, which would read as a
    #     leak that is not there — a probe whose failure mode is a false alarm
    #     teaches the next maintainer to ignore it.
    _tmpd="${TMPDIR:-/tmp}"
    _leak_count() { find "$_tmpd" -maxdepth 1 -name 'opscorp.*' 2>/dev/null | grep -c '' ; }
    _LEAK_BEFORE="$(_leak_count)"
    bash "$CORPUS" build --corpus "$SECDIR" --out "$_CTMP/leakout" >/dev/null 2>&1
    bash "$CORPUS" verify --corpus "$SECDIR" --tree "$_CTMP/leakout" >/dev/null 2>&1
    check "#69 a successful build+verify leaves no temp file behind" \
      "$([ "$(_leak_count)" = "$_LEAK_BEFORE" ] && echo 0 || echo 1)"
    # The path that leaked worst: `die` from INSIDE the read loop, which reaches
    # none of the explicit cleanup lines. Skipped as root (reads anything).
    if [ "$(id -u)" -ne 0 ]; then
      _LEAKC="$_CTMP/leakcorpus"; mkdir -p "$_LEAKC/f1"
      printf 'a\n' > "$_LEAKC/f1/a.sh"
      printf 'b\n' > "$_LEAKC/f1/b.sh"
      printf 'f1 a.sh ok.sh\n' > "$_LEAKC/$_MAPN"
      chmod 000 "$_LEAKC/f1/b.sh"
      _LEAK_BEFORE="$(_leak_count)"
      bash "$CORPUS" build --corpus "$_LEAKC" --out "$_CTMP/leakout2" >/dev/null 2>&1
      _RC=$?
      chmod 644 "$_LEAKC/f1/b.sh"
      # Both halves: it must still REFUSE (the guard) and still clean up (the trap).
      # Asserting only the cleanup would pass on a build that stopped refusing.
      check "#69 a die inside the read loop still refuses AND leaves no temp file" \
        "$([ "$_RC" -ne 0 ] && [ "$(_leak_count)" = "$_LEAK_BEFORE" ] && echo 0 || echo 1)"
    else
      echo "  skip #69 temp-file-on-die case: running as root, which can read anything"
    fi

    # 5f. BOUNDARY: a one-file corpus. The suite's other corpora are all 2+ files,
    #     so the smallest non-empty listing — one record, one trailing NUL — was
    #     only ever exercised incidentally. It is the shape most likely to break
    #     under a NUL-framing change: an off-by-one in the count comparison, or a
    #     `read -r -d ''` that drops a final record, both show up here first and
    #     nowhere else. Asserted through build AND verify, because a hash that is
    #     wrong but stable would pass build alone.
    #
    #     The 0-FILE case is deliberately not tested through the CLI: read_map
    #     refuses an empty map before corpus_hash is ever called, so a test would
    #     be asserting the map guard while appearing to assert the hash. Naming
    #     that here is the honest alternative to a case that measures the wrong
    #     thing (#21's class, reached by testing an unreachable path).
    _ONEF="$_CTMP/onefile"; mkdir -p "$_ONEF/f1"
    printf 'only\n' > "$_ONEF/f1/a.sh"
    printf 'f1 a.sh ok.sh\n' > "$_ONEF/$_MAPN"
    bash "$CORPUS" build --corpus "$_ONEF" --out "$_CTMP/onefileout" >/dev/null 2>&1
    _RC=$?
    bash "$CORPUS" verify --corpus "$_ONEF" --tree "$_CTMP/onefileout" >/dev/null 2>&1
    _RC2=$?
    check "#69 a one-file corpus builds AND verifies (smallest NUL-framed listing)" \
      "$([ "$_RC" -eq 0 ] && [ "$_RC2" -eq 0 ] && [ -f "$_CTMP/onefileout/ok.sh" ] && echo 0 || echo 1)"

    # 6. The map FILE's own guards (missing / symlinked), as distinct from the
    #    guards on the fields inside it. Every field-level vector above is
    #    covered; the file that carries them was not, which is the same
    #    "surrounded by thoroughness, therefore assumed covered" shape as the
    #    symlinked directory two cases up.
    mkdir -p "$_CTMP/nomap/f1"
    : > "$_CTMP/nomap/f1/x.sh"
    bash "$CORPUS" build --corpus "$_CTMP/nomap" --out "$_CTMP/nomapout" >/dev/null 2>&1
    _RC=$?
    check "#69 a corpus with no map is refused (it declares what gets copied out)" \
      "$([ "$_RC" -ne 0 ] && echo 0 || echo 1)"
    printf 'f1 x.sh ok.sh\n' > "$_CTMP/realmap"
    ln -s "$_CTMP/realmap" "$_CTMP/nomap/$_MAPN"
    bash "$CORPUS" build --corpus "$_CTMP/nomap" --out "$_CTMP/nomapout2" >/dev/null 2>&1
    _RC=$?
    check "#69 a SYMLINKED map is refused (never a map our tooling wrote)" \
      "$([ "$_RC" -ne 0 ] && echo 0 || echo 1)"
    rm -f "$_CTMP/nomap/$_MAPN"
    cp "$_CTMP/realmap" "$_CTMP/nomap/$_MAPN"
    bash "$CORPUS" build --corpus "$_CTMP/nomap" --out "$_CTMP/nomapout3" >/dev/null 2>&1
    _RC=$?
    check "#69 control: the same map as a REGULAR file is accepted" \
      "$([ "$_RC" -eq 0 ] && echo 0 || echo 1)"

    # 7. --out safety. The inside-the-repo refusal is the one standing between
    #    "the corpus is neutralized" and "the panel is shown the repo it is
    #    supposed to be blind to", and it had no case at all. Its sibling-prefix
    #    behaviour is pinned too: `<repo>-2` must NOT be refused by a check meant
    #    for `<repo>`, which is the classic prefix off-by-one.
    bash "$CORPUS" build --corpus "$SECDIR" --out "$REPO/derived-in-repo" >/dev/null 2>&1
    _RC=$?
    check "#69 --out inside the repo worktree is refused (the panel would review the repo)" \
      "$([ "$_RC" -ne 0 ] && echo 0 || echo 1)"
    check "#69 control: the refused in-repo build left nothing in the worktree" \
      "$([ ! -d "$REPO/derived-in-repo" ] && echo 0 || echo 1)"
    # …and the refusal must survive git being unavailable. repo_toplevel used to
    # return git's answer or NOTHING, and the caller guarded the whole check with
    # `[ -n "$toplevel" ]` — so with no git on PATH the containment check did not
    # fail, it vanished, and the build wrote the corpus into the repo. Found in a
    # bare ubuntu container (5 files, no refusal), which is the normal way to
    # reproduce CI and therefore exactly where the guard was absent.
    #
    # A git STUB that fails, not an emptied PATH. Emptying PATH also removes find
    # and shasum, so the build refuses for an unrelated reason and the case
    # measures nothing — which the third assertion below caught on its first run.
    # repo_toplevel swallows git's failure with `2>/dev/null || true`, so a git
    # that exits non-zero reproduces the empty-toplevel path exactly while the
    # rest of the script keeps working.
    _NOGIT="$(newproj)"
    printf '#!/bin/sh\nexit 1\n' > "$_NOGIT/git"
    chmod 755 "$_NOGIT/git"
    _NGOUT="$( cd "$REPO" && PATH="$_NOGIT:$PATH" "$BASH_ABS" "$CORPUS" build \
                 --corpus "$SECDIR" --out "$REPO/derived-nogit" 2>&1 )"
    _NGRC=$?
    check "#69 the in-repo refusal survives git being unavailable (guard fails CLOSED)" \
      "$([ "$_NGRC" -ne 0 ] && echo 0 || echo 1)"
    check "#69 control: no git, no build — nothing was written into the worktree" \
      "$([ ! -d "$REPO/derived-nogit" ] && echo 0 || echo 1)"
    check "#69 control: the no-git refusal is the CONTAINMENT one, not an unrelated error" \
      "$(printf '%s' "$_NGOUT" | grep -q "resolves inside this repo's worktree" && echo 0 || echo 1)"
    rm -rf "$_NOGIT" "$REPO/derived-nogit"
    bash "$CORPUS" build --corpus "$SECDIR" --out "$_CTMP/probe1-nonempty" >/dev/null 2>&1
    bash "$CORPUS" build --corpus "$SECDIR" --out "$_CTMP/probe1-nonempty" >/dev/null 2>&1
    _RC=$?
    check "#69 a non-empty --out without --force is refused" \
      "$([ "$_RC" -ne 0 ] && echo 0 || echo 1)"
    : > "$_CTMP/afile"
    bash "$CORPUS" build --corpus "$SECDIR" --out "$_CTMP/afile" >/dev/null 2>&1
    _RC=$?
    check "#69 an --out that exists and is not a directory is refused" \
      "$([ "$_RC" -ne 0 ] && echo 0 || echo 1)"
  else
    fail "#69 ops-corpus.sh build succeeds against the shipped security corpus"
  fi
  rm -rf "$_CTMP"
fi

echo "-- Case: #70 the drift fixture corpus is present and inert"
# The measurement instrument for #70's sixth-lens question. Same inertness
# discipline as the #24 corpus, same reason: a fixture that is reachable from
# shipped code is not a fixture, and an executable one is a script the plugin
# could run. Both probes carry the #24 positive control.
DRIFTDIR="$REPO/tests/fixtures/drift"
if [ -d "$DRIFTDIR" ]; then
  _DRIFT_FOUND=0
  for _d in errno-claim lock-ceiling stdout-copies tier-split-meta agenttype-anchor doc-regex-table; do
    # Each fixture is a 2x2 like the security corpus, restated for prose:
    # drifted/ and true/ are functionally identical and only the claim differs.
    # A fixture missing either column is not a measurement, it is an example.
    if [ -d "$DRIFTDIR/$_d/drifted" ] && [ -d "$DRIFTDIR/$_d/true" ] && [ -f "$DRIFTDIR/$_d/NOTES.md" ]; then
      _DRIFT_FOUND=$((_DRIFT_FOUND+1))
    else
      fail "#70 $_d: needs drifted/, true/ and NOTES.md (a one-column fixture measures nothing)"
    fi
  done
  check "#70 all 6 named drift fixtures are present with both columns" \
    "$([ "$_DRIFT_FOUND" = 6 ] && echo 0 || echo 1)"

  # THE DISCRIMINATING PROPERTY, pinned rather than asserted in prose. The
  # security corpus earns its four cells per fixture (functional ok / exploit
  # fires, both columns); this corpus's equivalent claim is "drifted/ and true/
  # differ ONLY in prose" — and until now that lived in README.md and six
  # NOTES.md files with nothing checking it. A drift fixture whose two columns
  # differ in CODE is not measuring drift, it is measuring a bug, and the
  # measurement built on it would be describing something other than what it
  # claims. That is #69's lesson pointed at #70's instrument.
  #
  # Method: strip whole-line comments from both columns and compare what is
  # left. Whole-line only, because the drift IS in the comments and a
  # comment-blind diff is the entire point; a trailing `# …` on a code line
  # would make the two files differ in a "code" line, which is why no fixture
  # uses one (and if one ever does, this case says so instead of passing).
  #
  # Two fixtures legitimately differ outside comments and are named here rather
  # than excluded by a pattern: `tier-split-meta` carries its claim in a
  # meta.description STRING (that is the shape it models — metadata describing
  # its own table), and the doc/changelog members of `doc-regex-table` and
  # `stdout-copies` are markdown, where every line is prose. Naming them keeps
  # the exemption auditable; a pattern would silently grow.
  _drift_code_only() {  # _drift_code_only <file> — the file minus whole-line comments
    grep -vE '^[[:space:]]*(#|//|\*|/\*)' "$1" 2>/dev/null || true
  }
  _DRIFT_CODE_DIFF=""
  for _d in errno-claim lock-ceiling stdout-copies tier-split-meta agenttype-anchor doc-regex-table; do
    for _f in "$DRIFTDIR/$_d/drifted"/*; do
      [ -f "$_f" ] || continue
      _b="$(basename "$_f")"
      _t="$DRIFTDIR/$_d/true/$_b"
      if [ ! -f "$_t" ]; then
        _DRIFT_CODE_DIFF="$_DRIFT_CODE_DIFF $_d/$_b(no-true-counterpart)"
        continue
      fi
      # Prose-only members: the claim IS the content, so a code-diff of 0 is
      # impossible and meaningless. Everything else must be code-identical.
      case "$_d/$_b" in
        */*.md|tier-split-meta/review.mjs) continue ;;
      esac
      if ! diff <(_drift_code_only "$_f") <(_drift_code_only "$_t") >/dev/null 2>&1; then
        _DRIFT_CODE_DIFF="$_DRIFT_CODE_DIFF $_d/$_b"
      fi
    done
    # THE REVERSE PASS, and its absence was a real hole: the loop above walks
    # drifted/ and looks each member up in true/, so a file present ONLY in
    # true/ was never visited and the suite certified the columns identical
    # anyway. Measured (Copilot, PR #72) — a ghost.sh dropped into true/ alone
    # left the case green. A one-way scan cannot answer a two-way question.
    for _f in "$DRIFTDIR/$_d/true"/*; do
      [ -f "$_f" ] || continue
      _b="$(basename "$_f")"
      [ -f "$DRIFTDIR/$_d/drifted/$_b" ] || \
        _DRIFT_CODE_DIFF="$_DRIFT_CODE_DIFF $_d/$_b(no-drifted-counterpart)"
    done
  done
  check "#70 drifted/ and true/ differ ONLY in prose (${_DRIFT_CODE_DIFF:-none differ in code})" \
    "$([ -z "$_DRIFT_CODE_DIFF" ] && echo 0 || echo 1)"
  # Positive control: the comparison must be able to SEE a code difference.
  # Without it, a broken `_drift_code_only` (wrong regex, unreadable file →
  # empty both sides) reports every fixture identical, which is exactly the
  # value that means "clean" — #24's own control idiom.
  _CTL_A="$(newproj)/a"; _CTL_B="$(dirname "$_CTL_A")/b"
  printf '# a comment\nX=1\n' > "$_CTL_A"
  printf '# a different comment\nX=2\n' > "$_CTL_B"
  diff <(_drift_code_only "$_CTL_A") <(_drift_code_only "$_CTL_B") >/dev/null 2>&1
  _RC=$?
  check "#70 control: the prose-only comparison still detects a real CODE difference" \
    "$([ "$_RC" -ne 0 ] && echo 0 || echo 1)"
  # And the converse: two files differing ONLY in a whole-line comment must
  # compare equal, or the case above would fire on every fixture and its
  # "none differ in code" verdict would be luck.
  printf '# a comment\nX=1\n' > "$_CTL_B"
  printf '# a DIFFERENT comment\nX=1\n' > "$_CTL_A"
  diff <(_drift_code_only "$_CTL_A") <(_drift_code_only "$_CTL_B") >/dev/null 2>&1
  check "#70 control: a comment-only difference compares EQUAL (the drift is invisible to it)" \
    "$?"

  # Same single exemption as #24's probe, for the same reason and with the same
  # control: ops-corpus.sh's header names both corpora because explaining why a
  # per-corpus map exists requires naming the two corpora whose shapes differ.
  # It still opens neither on its own — it is handed a path.
  DRIFT_REF="$(grep -rl 'fixtures/drift' \
    "$REPO/scripts" "$REPO/hooks" "$REPO/workflows" "$REPO/agents" \
    "$REPO/commands" "$REPO/skills" "$REPO/templates" 2>/dev/null \
    | grep -v '/scripts/ops-corpus\.sh$' | head -1)"
  DRIFT_REF_CTL="$(grep -rl 'fixtures/drift' "$REPO/tests/test-scripts.sh" 2>/dev/null | head -1)"
  check "#70 control: the inert probe's grep actually finds a known reference" \
    "$([ -n "$DRIFT_REF_CTL" ] && echo 0 || echo 1)"
  check "#70 no shipped script or hook references the drift corpus (inert)" \
    "$([ -z "$DRIFT_REF" ] && echo 0 || echo 1)"
  DRIFT_REF_ALL="$(grep -rl 'fixtures/drift' \
    "$REPO/scripts" "$REPO/hooks" "$REPO/workflows" "$REPO/agents" \
    "$REPO/commands" "$REPO/skills" "$REPO/templates" 2>/dev/null | LC_ALL=C sort)"
  check "#70 the ops-corpus.sh exemption is exactly one file, and it is that file" \
    "$([ "$DRIFT_REF_ALL" = "$REPO/scripts/ops-corpus.sh" ] && echo 0 || echo 1)"

  DRIFT_EXEC="$(find "$DRIFTDIR" -type f \
    \( -perm -u+x -o -perm -g+x -o -perm -o+x \) 2>/dev/null | head -1)"
  check "#70 no drift fixture carries an execute bit (${DRIFT_EXEC:-none})" \
    "$([ -z "$DRIFT_EXEC" ] && echo 0 || echo 1)"
else
  fail "#70 the drift fixture corpus is present at tests/fixtures/drift"
fi

########################################################################
if [ "$FAIL" -ne 0 ]; then
  echo "== failed cases =="
  printf '%s\n' "$FAILED_NAMES" | sed '/^$/d'
fi
echo "== summary: $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]
