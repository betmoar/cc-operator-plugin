#!/usr/bin/env bash
# Run the CI job locally in a container, on the platform CI actually uses.
#
# WHY THIS EXISTS: every "clean lint" claim made during 0.9.0 came from a local
# linter at v0.11.0, while .github/workflows/validate.yml pins v0.10.0 — and that
# workflow's own comment records five commits reporting clean from a 0.11
# workstation while every CI run went red on the same bytes. The bash suite has
# likewise never run here under bash 5 or GNU coreutils, and the harness fix at
# the head of this release is entirely about bash 3.2 behaving differently from
# bash 5. So the one platform this release most needs to be checked on is the one
# it has never run on.
#
# Not part of the evidence gate: not installed into .operator/bin/, referenced by
# no hook, and it runs nothing the CI workflow does not already run. It exists so
# the ubuntu half can be verified without waiting for a push.
#
# Usage:  bash scripts/ci-local.sh          # needs a running engine
#         RUNNER=podman bash scripts/ci-local.sh
set -euo pipefail
cd "$(dirname "$0")/.."

RUNNER="${RUNNER:-docker}"
command -v "$RUNNER" >/dev/null 2>&1 || { echo "no '$RUNNER' on PATH" >&2; exit 2; }
if ! "$RUNNER" info >/dev/null 2>&1; then
  echo "'$RUNNER' is installed but no engine is running." >&2
  echo "  Docker Desktop:  open -a Docker" >&2
  echo "  colima:          colima start" >&2
  echo "  podman:          podman machine init && podman machine start" >&2
  exit 2
fi

echo "== shellcheck 0.10.0 — the PINNED CI version, not the local one =="
"$RUNNER" run --rm -v "$PWD":/w -w /w koalaman/shellcheck-alpine:v0.10.0 \
  sh -c 'shellcheck --version | grep version:; shellcheck scripts/*.sh scripts/lib/*.sh tests/test-scripts.sh'

echo
echo "== the suites on ubuntu: bash 5, GNU coreutils, no .operator/ =="
# SC2016: the single quotes are the point — $BASH_VERSION must expand INSIDE the
# container, which is the version this script exists to report.
# shellcheck disable=SC2016
"$RUNNER" run --rm -v "$PWD":/w -w /w -e PYTHONDONTWRITEBYTECODE=1 ubuntu:24.04 bash -c '
  set -e
  apt-get update -qq >/dev/null 2>&1
  apt-get install -y -qq python3 nodejs git jq >/dev/null 2>&1
  echo "-- bash $BASH_VERSION, $(uname -s)"
  git config --global --add safe.directory /w
  python3 scripts/validate_plugin.py
  python3 -m unittest discover -s tests 2>&1 | tail -3
  bash tests/test-scripts.sh 2>&1 | tail -5
  node tests/test_workflows.mjs 2>&1 | tail -1
  node tests/test_compress.mjs 2>&1 | tail -1
'
