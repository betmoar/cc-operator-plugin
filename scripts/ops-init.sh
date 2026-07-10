#!/usr/bin/env bash
# ops-init.sh — initialize the per-project operator ledger scaffold.
# Idempotent: creates .operator/{VERDICTS.md,DECISIONS.md,pending/} from the
# plugin templates; never clobbers existing ledger content on re-run.
#
# Usage: run from the project root (cwd):  ops-init.sh
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATES="$SCRIPT_DIR/../templates"
OPDIR=".operator"

mkdir -p "$OPDIR/pending"

if [ ! -f "$OPDIR/VERDICTS.md" ]; then
  cp "$TEMPLATES/VERDICTS-header.md" "$OPDIR/VERDICTS.md"
  echo "created $OPDIR/VERDICTS.md"
else
  echo "kept $OPDIR/VERDICTS.md (exists)"
fi

if [ ! -f "$OPDIR/DECISIONS.md" ]; then
  cp "$TEMPLATES/DECISIONS-header.md" "$OPDIR/DECISIONS.md"
  echo "created $OPDIR/DECISIONS.md"
else
  echo "kept $OPDIR/DECISIONS.md (exists)"
fi

# Install the gate CLIs into the project so the charter's `.operator/bin/...`
# paths resolve in any project, not only the plugin repo (the model's shell has
# no ${CLAUDE_PLUGIN_ROOT}). Unlike the ledgers these are always refreshed:
# they are generated artifacts tracking the installed plugin version.
mkdir -p "$OPDIR/bin"
for tool in ops-verdict.sh ops-task.sh; do
  cp "$SCRIPT_DIR/$tool" "$OPDIR/bin/$tool"
  chmod +x "$OPDIR/bin/$tool"
done
echo "installed $OPDIR/bin/ops-verdict.sh and $OPDIR/bin/ops-task.sh"

echo "operator ledger ready at $OPDIR/"
