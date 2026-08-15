#!/usr/bin/env bash
# FIXTURE (inert): the CORRECTED variant of ext-source/vuln.sh.
# Identical CLI and identical output for every legitimate tiers.env.
#
# Usage: fixed.sh <project-dir>
set -u

PROJ="${1:?usage: fixed.sh <project-dir>}"
CONF="$PROJ/.operator/tiers.env"

[ -f "$CONF" ] || { echo "no tiers.env at $CONF" >&2; exit 1; }

# THE FIX. Parse the file instead of executing it. A config format needs
# NAME=value, comments and blank lines — none of which requires handing the
# shell a file that anything with write access to the repo can replace.
JUDGMENT=""
MECHANICAL=""
while IFS= read -r line; do
  case "$line" in
    ''|'#'*) continue ;;
    # A line with no `=` is not a binding. Without this arm both `${line%%=*}`
    # and `${line#*=}` are the identity, so a stray `MECHANICAL` line sets
    # MECHANICAL=MECHANICAL and that non-id is reported as a resolved binding
    # (measured). Found by the review panel's own control run over this file.
    *=*) ;;
    *) continue ;;
  esac
  key="${line%%=*}"
  val="${line#*=}"
  # Only bindings this script consumes, and only a value inside the model-id
  # charset — a value is data, never something to evaluate.
  case "$val" in
    *[!A-Za-z0-9._:/@-]*) continue ;;
  esac
  case "$key" in
    JUDGMENT)   JUDGMENT="$val" ;;
    MECHANICAL) MECHANICAL="$val" ;;
  esac
done < "$CONF"

JUDGMENT="${JUDGMENT:-claude-opus-5}"
MECHANICAL="${MECHANICAL:-glm-5-turbo}"

echo "JUDGMENT=$JUDGMENT"
echo "MECHANICAL=$MECHANICAL"
