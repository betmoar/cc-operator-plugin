#!/usr/bin/env bash
# gate-suite.sh — run ONE test rung and hold it to two claims it cannot fake.
#
#   bash scripts/gate-suite.sh <rung>              run the rung, then check it
#   bash scripts/gate-suite.sh --check <rung> LOG  check a log already captured
#
# Rungs: validator | python | shell | workflows | compress
#
# TWO CLAIMS, and they fail differently on purpose:
#
#   1. THE MARKER. The rung's own completion line must appear in the output. A
#      suite that exits 0 having run nothing prints no summary, and `echo $?`
#      cannot tell that apart from a clean run. This is the half that catches a
#      step whose command silently no-opped, a runner that skipped it, or a
#      harness that died after its last `ok` line.
#   2. THE FLOOR. The case count must be >= tests/floors.env. This is the half
#      that catches deletion — see that file for why a number in a comment was
#      not a floor, and for the slack this design knowingly carries.
#
# A suite exiting non-zero fails first and on its own; the two claims above are
# about the case where it exits ZERO. All three failures print
# `GATE_FAILED: <rung>` so a CI log can be grepped for the rung that broke.
#
# The floors are NOT duplicated here. tests/floors.env is the one declaration
# (check_suite_floors pins that this file sources it and holds no floor literal
# of its own): a floor in two places is a floor in neither the moment they drift.
#
# --check exists so the marker/floor logic can be tested against crafted logs
# without running a real suite. It is not a CI path — check_suite_floors pins
# that every CI file reaches its rung through the plain `gate-suite.sh <rung>`
# form, so a captured log cannot be substituted for a run.
set -uo pipefail

ROOT="$(cd -P "$(dirname "$0")/.." && pwd -P)"
FLOORS="$ROOT/tests/floors.env"

die() { printf 'gate-suite: %s\n' "$1" >&2; exit 2; }
fail() { printf 'GATE_FAILED: %s — %s\n' "$RUNG" "$1" >&2; exit 1; }

CHECK_ONLY=0
if [ "${1:-}" = "--check" ]; then
  CHECK_ONLY=1
  shift
fi
RUNG="${1:-}"
[ -n "$RUNG" ] || die "usage: gate-suite.sh [--check] <rung> [log]"

# Allowlist BEFORE anything reads it: the rung names a command and an env var,
# so an unrecognised value must stop here rather than resolve to an empty one.
case "$RUNG" in
  validator | python | shell | workflows | compress) : ;;
  *) die "unknown rung '$RUNG' (validator|python|shell|workflows|compress)" ;;
esac

# `-f` not `-r` (#21): a permission test is INERT for uid 0, so readability is
# established by the source ITSELF failing — a behavioural check that holds on
# every uid, paired with a type test that refuses a directory or a device.
[ -f "$FLOORS" ] || die "missing $FLOORS — the floors are the gate"
# shellcheck source=/dev/null
. "$FLOORS" || die "could not read $FLOORS — the floors are the gate"

if [ "$CHECK_ONLY" -eq 1 ]; then
  LOG="${2:-}"
  # Type test only, for the #21 reason above; an unreadable log then reaches the
  # marker grep, which finds nothing and fails CLOSED as a missing marker.
  # `A && B || C` reads as if-then-else and is not one (SC2015, which the
  # PINNED 0.10.0 fails on and a local 0.11 does not — the drift this repo
  # already paid for once).
  if [ -z "$LOG" ] || [ ! -f "$LOG" ]; then die "--check needs a log file"; fi
  RC=0
else
  LOG="$(mktemp "${TMPDIR:-/tmp}/gate-suite.XXXXXX")"
  trap 'rm -f "$LOG"' EXIT
  case "$RUNG" in
    validator) CMD=(python3 "$ROOT/scripts/validate_plugin.py") ;;
    python)    CMD=(python3 -m unittest discover -s "$ROOT/tests" -v) ;;
    shell)     CMD=(bash "$ROOT/tests/test-scripts.sh") ;;
    workflows) CMD=(node "$ROOT/tests/test_workflows.mjs") ;;
    compress)  CMD=(node "$ROOT/tests/test_compress.mjs") ;;
  esac
  printf '== rung: %s ==\n' "$RUNG"
  # tee so a long suite still streams into the CI log; PIPESTATUS[0] carries the
  # suite's own status, which `pipefail` alone would conflate with tee's.
  "${CMD[@]}" 2>&1 | tee "$LOG"
  RC="${PIPESTATUS[0]}"
fi

[ "$RC" -eq 0 ] || fail "the suite itself exited $RC"

# --- claim 1: the marker -----------------------------------------------------
# Each rung's marker is the line its harness prints LAST, after the work. Fixed
# strings, matched with grep -F where the marker carries no metacharacter.
case "$RUNG" in
  validator)
    grep -qF 'validate_plugin: all contracts hold.' "$LOG" \
      || fail "no completion marker ('validate_plugin: all contracts hold.') — the validator exited 0 without reporting"
    exit 0 ;;
  python)
    # unittest prints bare `OK` or `OK (skipped=N)`; anchor so an `OK` inside a
    # test name cannot satisfy it.
    grep -qE '^OK( \(.*\))?$' "$LOG" \
      || fail "no completion marker ('OK') — unittest exited 0 without reporting"
    OBSERVED="$(grep -oE '^Ran [0-9]+ tests?' "$LOG" | grep -oE '[0-9]+' | tail -1)"
    ;;
  shell | workflows | compress)
    # Two marker shapes (#109): the shell suite reports its skip count since
    # the counted-skip change; the node suites never skip and keep the old
    # shape. The skip group is optional so the old marker still matches.
    SUMMARY="$(grep -oE '^== summary: [0-9]+ passed, [0-9]+ failed(, [0-9]+ skipped)? ==$' "$LOG" | tail -1)"
    [ -n "$SUMMARY" ] \
      || fail "no completion marker ('== summary: N passed, M failed[, K skipped] ==') — the suite exited 0 without reporting"
    OBSERVED="$(printf '%s' "$SUMMARY" | grep -oE '[0-9]+ passed' | grep -oE '[0-9]+')"
    FAILED="$(printf '%s' "$SUMMARY" | grep -oE '[0-9]+ failed' | grep -oE '[0-9]+')"
    # The floor is taken against passed+skipped (#109): executor-invariant, so
    # the floor can sit at the TRUE total and the root/macOS spread (15
    # per-case skips on a git-less executor, 2 as root) stops being slack a
    # deletion can hide in.
    SKIPPED="$(printf '%s' "$SUMMARY" | grep -oE '[0-9]+ skipped' | grep -oE '[0-9]+' || true)"
    OBSERVED=$((OBSERVED + ${SKIPPED:-0}))
    # Belt and braces: a harness that reports failures but exits 0 is exactly
    # the shape this file exists to refuse.
    [ "$FAILED" -eq 0 ] || fail "the summary reports $FAILED failed case(s) while exiting 0"
    ;;
esac

# --- claim 2: the floor ------------------------------------------------------
[ -n "${OBSERVED:-}" ] || fail "the marker was present but no case count could be read from it"

eval "FLOOR=\${FLOOR_$RUNG:-}"
[ -n "$FLOOR" ] \
  || die "no FLOOR_$RUNG in $FLOORS — a rung with no floor is a rung with no ratchet"

if [ "$OBSERVED" -lt "$FLOOR" ]; then
  fail "$OBSERVED cases, floor is $FLOOR — $((FLOOR - OBSERVED)) case(s) went missing"
fi

printf 'GATE_OK: %s — %s cases (floor %s, slack %s)\n' \
  "$RUNG" "$OBSERVED" "$FLOOR" "$((OBSERVED - FLOOR))"
