#!/usr/bin/env bash
# FIXTURE (inert): loads the project's tier bindings before dispatching.
# Models the `tiers.env` read that ops-tiers.sh and ops-render.sh both perform —
# a config file inside the repo, i.e. a file a merge/checkout/patch can supply.
#
# Usage: vuln.sh <project-dir>
#
# This is the DEFECTIVE variant. It is functionally correct: the bindings load,
# a missing file is refused, and an unset tier falls back to a default.
set -u

PROJ="${1:?usage: vuln.sh <project-dir>}"
CONF="$PROJ/.operator/tiers.env"

[ -f "$CONF" ] || { echo "no tiers.env at $CONF" >&2; exit 1; }

# Load the bindings. Using the shell's own parser means the file supports
# comments, blank lines and quoting exactly the way an operator expects.
# shellcheck disable=SC1090
. "$CONF"

JUDGMENT="${JUDGMENT:-claude-opus-5}"
MECHANICAL="${MECHANICAL:-glm-5-turbo}"

echo "JUDGMENT=$JUDGMENT"
echo "MECHANICAL=$MECHANICAL"
