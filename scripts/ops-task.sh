#!/usr/bin/env bash
# ops-task.sh — open a tracked task: drop the sentinel .operator/pending/<id>.
# The Stop hook blocks session end until ops-verdict.sh clears the sentinel
# (verdict row or --defer). Idempotent: re-opening an open id is a no-op.
#
# Usage: run from the project root (cwd):  ops-task.sh <task-id>
set -eu

OPDIR=".operator"

die() { echo "ops-task: $1" >&2; exit 2; }

ID="${1:-}"
[ -n "$ID" ] || die "missing task-id (usage: ops-task.sh <task-id>)"
NL="$(printf '\nx')"; NL="${NL%x}"
case "$ID" in
  */* | . | ..) die "task-id must be a bare name (no '/', '.', '..')" ;;
  *"|"* | *"$NL"*) die "task-id must not contain '|' or newlines — it becomes a ledger cell" ;;
esac
[ -d "$OPDIR" ] || die "no $OPDIR/ in cwd — run ops-init.sh first"

mkdir -p "$OPDIR/pending"
: > "$OPDIR/pending/$ID"
echo "opened $ID (sentinel $OPDIR/pending/$ID — cleared only by ops-verdict.sh)"
