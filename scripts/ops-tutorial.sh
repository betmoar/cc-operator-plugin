#!/usr/bin/env bash
# ops-tutorial.sh — the evidence gate, watched rather than read about (#75).
#
#   ops-tutorial.sh [--keep]
#
# Scaffolds a throwaway git project, opens a tracked task, feeds the REAL Stop
# hook a Stop payload for it, and shows the block; then records the verdict and
# shows the same hook letting the stop through. Every step is the shipped code:
# ops-init.sh's install, the .operator/bin/ CLIs it copies, ops-stop-hook.sh.
#
# Self-checking: exit 0 only when the hook BLOCKED (rc 2) while the task was
# open AND ALLOWED (rc 0) after the verdict. A tutorial whose block never
# happens is the reading-about-it experience #75 exists to replace, so it
# fails rather than narrating a block it did not observe.
set -eu
# pipefail: every CLI below is piped through sed for indentation, and without it a
# failing ops-task.sh or ops-verdict.sh was masked by sed's 0 (PR #176 review).
set -o pipefail

die() { echo "ops-tutorial: $1" >&2; exit 2; }

KEEP=0
while [ $# -gt 0 ]; do
  case "$1" in
    --keep) KEEP=1; shift ;;
    -h|--help) echo "usage: ops-tutorial.sh [--keep]" >&2; exit 2 ;;
    *) die "unknown option '$1' (usage: ops-tutorial.sh [--keep])" ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOK="$SCRIPT_DIR/ops-stop-hook.sh"
if [ ! -f "$HOOK" ] || [ ! -f "$SCRIPT_DIR/ops-init.sh" ]; then
  die "run from the plugin's scripts/ (no ops-stop-hook.sh / ops-init.sh beside $0)"
fi
command -v git >/dev/null 2>&1 || die "git not found — the tutorial project is a git repo, as the gate's source stamp expects"

T="$(mktemp -d "${TMPDIR:-/tmp}/ops-tutorial.XXXXXX")"
T="$(cd -P "$T" && pwd -P)"
# ONE exit trap: cleanup, and the failure marker for every path that is not
# the OK ending — a die or a set -e abort mid-step used to exit with no marker
# at all, while commands/tutorial.md promises TUTORIAL_FAILED (Copilot, PR #176).
DONE_OK=0
# shellcheck disable=SC2317,SC2329  # invoked by the EXIT trap below (0.10 and 0.11 name it differently)
on_exit() {
  local rc=$?
  [ "$DONE_OK" -eq 1 ] || [ "$rc" -eq 1 ] \
    || echo "TUTORIAL_FAILED: aborted mid-step (exit $rc) — the output above names the step that failed" >&2
  [ "$KEEP" -eq 1 ] || rm -rf "$T"
}
trap on_exit EXIT
[ "$KEEP" -eq 0 ] || echo "tutorial project kept at: $T"
SID="tutorial-session"
step() { printf '\n== %s\n' "$*"; }
stop_hook() { # stop_hook → sets HRC, prints the hook's stderr indented
  local err
  HOOK_ERR=""
  err="$(printf '{"hook_event_name":"Stop","stop_hook_active":false,"cwd":"%s","session_id":"%s"}' "$T" "$SID" \
    | bash "$HOOK" 2>&1 >/dev/null)" && HRC=0 || HRC=$?
  HOOK_ERR="$err"
  [ -z "$err" ] || printf '%s\n' "$err" | sed 's/^/   | /'
  echo "   Stop hook exit code: $HRC ($( [ "$HRC" -eq 2 ] && echo 'BLOCKED — the session cannot end' || echo 'allowed'))"
}

step "1. A project under the charter: git repo + /cc-operator:start's init step"
( cd "$T" && git init -q . && git -c user.email=t@t -c user.name=tutorial commit -q --allow-empty -m init )
( cd "$T" && bash "$SCRIPT_DIR/ops-init.sh" >/dev/null )
echo "   $T/.operator/ holds the ledgers; the gate CLIs are installed in .operator/bin/"

step "2. Open a tracked task — this drops a sentinel the Stop hook will see"
( cd "$T" && bash .operator/bin/ops-task.sh tutorial-demo --owner "$SID" | sed 's/^/   /' )
[ -f "$T/.operator/pending/${SID}__tutorial-demo" ] || die "ops-task.sh reported success but no sentinel exists — the gate has nothing to block on"

step "3. Try to stop with the task still open"
stop_hook; BLOCK_RC=$HRC
# The block must be for THIS task. Another gate (the auto-arm, #85) also exits 2,
# and a tutorial that credits its block to the task demonstrates the wrong rule.
BLOCK_MINE=0; case "$HOOK_ERR" in *"pending verdict(s): tutorial-demo"*) BLOCK_MINE=1 ;; esac

step "4. Close it the only way the gate accepts: a verdict row WITH evidence"
# ONE changed path on purpose: two would trip the auto-arm (#85) — see the
# closing note — and this step is about the verdict, not about that rule.
printf 'echo hello\n' > "$T/hello.sh"
OUT="$(cd "$T" && bash hello.sh 2>&1)"
echo "   ran: bash hello.sh -> $OUT"
( cd "$T" && bash .operator/bin/ops-verdict.sh tutorial-demo "hello.sh prints hello" "bash hello.sh -> $OUT" PASS --owner "$SID" | sed 's/^/   /' )
echo "   the row, auto-stamped with the source state that produced it:"
ROW="$(grep -F '| tutorial-demo |' "$T/.operator/VERDICTS.md" | tail -n 1)" || die "ops-verdict.sh reported success but VERDICTS.md holds no tutorial-demo row"
printf '   %s\n' "$ROW"

step "5. Try to stop again"
stop_hook; ALLOW_RC=$HRC

echo
if [ "$BLOCK_RC" -eq 2 ] && [ "$BLOCK_MINE" -eq 1 ] && [ "$ALLOW_RC" -eq 0 ]; then
  echo "TUTORIAL_OK: the Stop hook blocked on an open task (2) and allowed after its verdict (0)"
  echo "Not shown: change 2+ files with NO task open and the hook opens one for you ('autobar', #85) — the"
  echo "charter's ENGAGEMENT CONTRACT clause 1, enforced. Next: /cc-operator:start in your own project."
  DONE_OK=1
  exit 0
fi
echo "TUTORIAL_FAILED: expected block=2 (on tutorial-demo) then allow=0, observed block=$BLOCK_RC (on tutorial-demo: $([ "$BLOCK_MINE" -eq 1 ] && echo yes || echo no)) allow=$ALLOW_RC — the gate did not behave as the charter says" >&2
exit 1
