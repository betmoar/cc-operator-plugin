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

mkdir -p "$OPDIR/pending" "$OPDIR/verdicts.d"

# Per-session verdict fragments (verdicts.d/<owner>.md) exist so two branches
# append to two different files and git merges them cleanly. VERDICTS.md can
# still conflict — but `ops-verdict.sh --reconcile` restores every row from the
# fragments afterwards, so any resolution is safe.
#
# merge=union is a git built-in needing no user config, and it is exactly right
# for append-only ledgers. Scoped to .operator/ so we never touch the host
# repo's root .gitattributes.
if [ ! -f "$OPDIR/.gitattributes" ]; then
  cat > "$OPDIR/.gitattributes" <<'EOF'
# Append-only ledgers: take both sides on merge, never a conflict marker.
# Re-run `.operator/bin/ops-verdict.sh --reconcile` after any messy merge.
VERDICTS.md merge=union
DECISIONS.md merge=union
verdicts.d/*.md merge=union
EOF
  echo "created $OPDIR/.gitattributes (append-only merge=union)"
fi

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
for tool in ops-verdict.sh ops-task.sh ops-adopt.sh; do
  cp "$SCRIPT_DIR/$tool" "$OPDIR/bin/$tool"
  chmod +x "$OPDIR/bin/$tool"
done
echo "installed $OPDIR/bin/{ops-verdict.sh,ops-task.sh,ops-adopt.sh}"

echo "operator ledger ready at $OPDIR/"
