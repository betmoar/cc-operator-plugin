# shellcheck shell=bash
# scripts/lib/stage.sh — the DERIVED engagement stage (#157).
#
# WHY. Seven stages, one command (`/cc-operator:handoff`) until #75, and every
# transition between them was the operator remembering to make it. After a
# compaction the RECOVERY PROTOCOL's seven steps are the only path back, and
# they are prose the operator must CHOOSE to follow. A cycle that can name its
# own stage can propose the next move; one that cannot needs a human holding
# the sequence in their head.
#
# DERIVED, NEVER STORED. docs/UNKNOWNS.md states the rule this repo applies to
# itself: the moment status lives in two places, one of them is wrong and
# nothing says which. There is no engagement.json and there must not be one.
#
# PURE. This lib opens NO file. It is a function of facts the caller has
# already computed — scan_pending's counts and scan_deviations' verdict — so
# it adds no reader, no byte cap, no NUL probe, and no second copy of the
# partition rule. That is the whole reason it can be shared by the Stop hook
# (which has run every scan) and the SessionStart hook (which runs only the
# pending one) without the two disagreeing: they differ in what they KNOW, not
# in how the stage is decided, and the unknown input has its own answer.
#
# REPORT-ONLY, like the cap detector: nothing here exits, writes, or changes a
# gate's verdict. A stage that could block would be a second gate keyed on
# derived state, which is exactly what this is not.

# stage_derive <malformed> <mine> <mine-ids> <foreign> <unpresented|->
#
# Sets STAGE and STAGE_NEXT. `unpresented` is "-" when the caller did not scan
# DECISIONS.md; the stage then never claims HANDOFF, because "no unpresented
# deviations" is a fact that caller does not have. An UNKNOWN input produces a
# narrower answer, never a guessed one.
stage_derive() {
  local _malformed="${1:-0}" _mine="${2:-0}" _mine_ids="${3:-}" \
        _foreign="${4:-0}" _unpres="${5:--}"
  STAGE=""
  STAGE_NEXT=""

  # PRECEDENCE, and it is not arbitrary: each rung is a thing that makes the
  # rung below it unreachable. You cannot hand off while a task of yours is
  # open, and you cannot close that task while the sentinel naming it is one
  # no CLI can address.
  if [ "$_malformed" -gt 0 ]; then
    STAGE="BLOCKED"
    STAGE_NEXT="$_malformed sentinel(s) in .operator/pending/ carry a name no CLI can close — remove them by hand; the Stop hook's own message names each path"
    return 0
  fi

  if [ "$_mine" -gt 0 ]; then
    STAGE="IMPLEMENT"
    STAGE_NEXT="record a verdict for each open task (ops-verdict.sh <id> <criterion> <evidence> PASS|FAIL --owner <sid>), or end it honestly with --defer \"<reason>\"${_mine_ids:+ — open: $_mine_ids}"
    return 0
  fi

  # Only reachable with nothing of mine open, which is why the handoff rung
  # sits here rather than first: an unpresented deviation is the LAST thing
  # between a finished engagement and a clean stop.
  if [ "$_unpres" != "-" ] && [ "$_unpres" -gt 0 ]; then
    STAGE="HANDOFF"
    STAGE_NEXT="$_unpres unpresented decision(s) block the stop — run /cc-operator:handoff, then ops-verdict.sh --mark-handoff --owner <sid>"
    return 0
  fi

  STAGE="CLEAR"
  if [ "$_unpres" = "-" ]; then
    # Said out loud rather than folded into the same sentence as a full scan's
    # CLEAR: the two are different claims, and a bar that renders them
    # identically is a bar that overstates what it checked.
    STAGE_NEXT="nothing of yours is open (deviations not scanned here — the Stop hook checks those). Open a task with ops-task.sh <id> --owner <sid> before your first implementation action; a 2+ file change without one arms the gate for you"
  else
    STAGE_NEXT="nothing of yours is open and nothing is unpresented. Open a task with ops-task.sh <id> --owner <sid> before your first implementation action; a 2+ file change without one arms the gate for you"
  fi
  # Reported, never a stage of its own: another session's open task changes
  # nothing about what THIS session should do next, and a stage that moved on
  # someone else's work would be the mine/foreign confusion the partition
  # rule exists to prevent.
  if [ "$_foreign" -gt 0 ]; then
    STAGE_NEXT="$STAGE_NEXT. $_foreign task(s) here belong to other sessions — informational, never yours to close"
  fi
  return 0
}
