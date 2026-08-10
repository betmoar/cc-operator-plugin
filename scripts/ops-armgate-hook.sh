#!/usr/bin/env bash
# ops-armgate-hook.sh — PreToolUse arm gate (G2, opt-in).
#
# Contract (exit codes are the interface — Claude Code reads them):
#   exit 0  — allow. Cases: no .operator/ above the payload cwd; the gate is
#             not enabled (.operator/armgate.on absent); this session is armed
#             (.operator/.armed/<sid> or .armed/<sid>.exempt present); no JSON
#             parser on PATH; unreadable/unusable state.
#   exit 2  — deny. The gate is enabled, this session holds NO open task, and it
#             is about to mutate a file. stderr names the exact command to arm
#             and the exemption path (Claude Code feeds stderr back as guidance).
#
# POLARITY — deliberately the OPPOSITE of ops-stop-hook.sh's, and both are right.
# The Stop gate fails CLOSED on a degenerate sentinel, because an unparseable
# sentinel is a real open task. This gate fails OPEN on every infrastructure
# failure — no parser, no .operator/, an unreadable or unusable marker — because
# a PreToolUse hook that fails closed makes the project UNWRITABLE, and an
# unwritable project cannot even be repaired (the repair is itself an edit).
# The failure mode you cannot recover from is the one to avoid.
#
# SCOPE — structured file-mutation tools only (`Write|Edit|MultiEdit|
# NotebookEdit`, pinned in hooks/hooks.json and asserted by
# validate_plugin.check_armgate). `Bash` is deliberately NOT gated: deciding
# whether an arbitrary shell command writes is an unwinnable classification
# problem with a large false-positive surface on a hook that BLOCKS, and gating
# Bash risks deadlocking the repair path (ops-task.sh is itself a Bash call).
# Stated honestly rather than papered over: this gate is an honesty rail against
# forgetting, not a sandbox against a hostile agent. A session that wants to
# evade it can `bash -c 'cat > f'`. The threat model is drift, which is the
# observed failure — not evasion, which is not.
#
# HOW IT ASKS "am I armed?" WITHOUT A FOURTH PARSER (G2.1). The scoped question
# ("does THIS session hold a task open?") would otherwise mean parsing
# `session_id:` out of a sentinel body, which in this repo is sixty lines of
# LC_ALL=C / -L rejection / NUL probe / bounded read — a FOURTH copy of the
# partition, on a hook that fires before every edit. Instead the writers answer
# it (ops-task.sh, ops-adopt.sh create the marker; ops-verdict.sh recomputes it
# under the lock) and this hook does one or two stats. No parsing, no byte
# bounds, no partition, builtins only by construction.
set -u

# --- read the whole payload from stdin (builtin; no external command) --------
# Same slurp as ops-stop-hook.sh: read to a NUL that never comes, so a payload
# with or without a trailing newline is captured whole.
input=""
IFS= read -r -d '' input || true

# --- pick a JSON parser once; fail OPEN (silently) if none -------------------
# Silent, unlike the Stop hook's warning: this runs before EVERY edit, so a
# warning here would prepend noise to every tool call in a PATH-less session.
if command -v jq >/dev/null 2>&1; then
  PARSER=jq
elif command -v python3 >/dev/null 2>&1; then
  PARSER=python3
else
  exit 0
fi

json_get() { # json_get <field> → value on stdout ("" if absent)
  case "$PARSER" in
    jq)
      printf '%s' "$input" | jq -r --arg k "$1" '.[$k] // empty' 2>/dev/null
      ;;
    python3)
      printf '%s' "$input" | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
k = sys.argv[1]
v = d.get(k, "")
if isinstance(v, bool):
    print("true" if v else "false")
elif v is None:
    print("")
else:
    print(v)
' "$1" 2>/dev/null
      ;;
  esac
}

cwd="$(json_get cwd)"
session="$(json_get session_id)"

# No cwd (absent or unparseable payload) → fail open. Unlike the Stop hook we do
# not even warn: see the silence rationale above.
[ -n "$cwd" ] || exit 0

# Resolve the project by WALKING UP from the payload cwd to the nearest ancestor
# holding .operator/ — identical to ops-stop-hook.sh, and for the same reason:
# a task can only be opened at the root, so an exact-match lookup one directory
# deeper finds nothing. Bounded at a .git boundary and at / so it can never
# adopt an unrelated ancestor's state. Here the disagreement fails OPEN rather
# than open-the-gate, but a wrong root would still block a session whose markers
# live elsewhere — the stale-false direction G2.1 exists to prevent.
opdir=""
walk="$(cd -P "$cwd" 2>/dev/null && pwd)" || walk=""
while [ -n "$walk" ]; do
  if [ -d "$walk/.operator" ]; then opdir="$walk/.operator"; break; fi
  [ -e "$walk/.git" ] && break
  [ "$walk" = "/" ] && break
  walk="${walk%/*}"; [ -n "$walk" ] || walk="/"
done
[ -n "$opdir" ] || exit 0

# --- opt-in: absent switch → the gate does not exist for this project --------
# 0.7.x ships this OFF. A false block can only reach a project that asked for
# it. `-f`, not `-e`: a directory or a device named armgate.on is not a switch
# our scaffold wrote, and the fail-open direction is the one we want anyway.
[ -f "$opdir/armgate.on" ] || exit 0

# A session id we could not use as a filename cannot be checked against the
# marker directory — fail OPEN rather than deny on a name we cannot form. The
# reject set mirrors check_bare_name/check_owner_name in the three CLIs: an
# owner our writers could never have stamped can have no marker, so denying on
# it would block every session in a project with a malformed payload.
case "$session" in
  "" | */* | .* | *"|"* | *[[:space:]]*) exit 0 ;;
esac

# --- the entire check: one or two stats --------------------------------------
# .armed/<sid>        — DERIVED from pending/ by the writers; recomputed under
#                       the ledger lock on every ops-verdict.sh run.
# .armed/<sid>.exempt — GRANTED by ops-task.sh --exempt (G3); the recompute
#                       never touches it. Two marker kinds, two lifetimes.
[ -e "$opdir/.armed/$session" ] && exit 0
[ -e "$opdir/.armed/$session.exempt" ] && exit 0

# `.armed` EXISTS but is not a usable directory (a regular file, a bad restore,
# a chmod/umask accident) → INFRASTRUCTURE FAILURE → fail OPEN. The header's
# contract already promised this ("an unreadable or unusable marker"); it was
# documented and not implemented (PR-review finding, 2026-08-07).
#
# THE TWO HALVES ARE NOT EQUALLY LOAD-BEARING (issue #19, measured 2026-08-08).
# `[ ! -d ]` is the half that works, on every uid: a regular file or a bad
# restore is caught and fails open (cases below). `[ ! -x ]` is BEST-EFFORT and
# is INERT for uid 0 — root's `[ -x ]` on a `chmod 000` directory returns TRUE,
# so this branch cannot fire for a root session: `docker run` without `--user`,
# or a devcontainer left at the default root user. NOT this project's CI, which
# was checked rather than assumed — GitHub Actions `ubuntu-latest` runs as the
# `runner` user (uid 1000, `/home/runner/...`), so the branch fires normally
# there. That is stated rather than papered over, and it is acceptable for a
# reason that had to be measured rather than assumed: root is not blocked by
# mode bits either. On a `chmod 000` .armed as uid 0, `ls`/`cd`/`touch` all
# succeed, and — the decisive test — the marker lookup stays ACCURATE:
# `[ -e .armed/<present> ]` is TRUE and `[ -e .armed/<absent> ]` is FALSE, read
# straight through the unreadable directory. So for the permission case root
# never reaches a wrong verdict, the marker writes still work, and the three
# repairs this deny message prints are all alive. The failure the fail-open
# exists to prevent does not occur for the uid whose guard is inert.
# Do NOT "fix" this by probing the capability (ls/cd/touch): measured, every
# such probe SUCCEEDS under root, so it distinguishes nothing. There is no test
# that fails, because nothing fails.
#
# A BROKEN SYMLINK named .armed is absence, not unusability: `[ -e ]` is false
# on a dangling link, so it falls through to the deny below — which is the
# documented never-armed answer, and correct.
#
# Why this is the critical direction and not a nicety: with `.armed` unusable,
# every marker write in the repo fails, and the three repairs this deny message
# prints are ALL dead — `ops-task.sh` and `ops-adopt.sh` swallow their marker
# write by design (a failed marker is meant to degrade to stale-false), so they
# report success and change nothing; `--exempt` dies AFTER its ledger row lands,
# leaving the operator owing a handoff for an exemption they never received.
# Measured: a legitimately-armed session with an open task, denied on every
# Write/Edit/MultiEdit/NotebookEdit, with no in-band way out. That is the
# unwritable-and-unrepairable project this hook's whole polarity exists to avoid.
#
# ABSENCE of `.armed` must still DENY — that is the honest never-armed case, and
# it is the common one. Only an existing-but-unusable `.armed` fails open.
if [ -e "$opdir/.armed" ] && { [ ! -d "$opdir/.armed" ] || [ ! -x "$opdir/.armed" ]; }; then
  exit 0
fi

# --- deny --------------------------------------------------------------------
# Name the recovery verbatim (stale-false mitigation 1): ops-adopt.sh re-stamps
# ownership AND re-creates the marker, so a session whose marker desynced from a
# sentinel it really owns has a one-command repair that already exists.
cat >&2 <<EOF
operator: the arm gate is on (.operator/armgate.on) and session $session holds no open task —
refusing this file mutation. Open one first:
  .operator/bin/ops-task.sh <task-id> --owner $session
If this session already owns an open task, re-stamp it (this also restores the marker):
  .operator/bin/ops-adopt.sh --owner $session <task-id>
To proceed without a task, take the audited exemption (it owes a handoff presentation):
  .operator/bin/ops-task.sh --exempt "<reason>" --owner $session
EOF
exit 2
