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

# The ledger is the evidence of record, so where it lands matters. This script
# will scaffold anywhere — including a home directory or a scratch dir reached by
# a mis-aimed /cc-operator:start — and used to report success either way, writing
# the evidence somewhere nobody will merge or review. Warn, never hard-fail: a
# non-git project is unusual but legitimate. (Audit F05.)
if command -v git >/dev/null 2>&1; then
  TOPLEVEL="$(git rev-parse --show-toplevel 2>/dev/null || true)"
  if [ -z "$TOPLEVEL" ]; then
    echo "ops-init: warning — $PWD is not a git repository; the ledger will not be tracked or reviewable" >&2
  elif [ "$TOPLEVEL" != "$PWD" ]; then
    echo "ops-init: warning — scaffolding at $PWD, which is NOT the repository root ($TOPLEVEL)" >&2
    echo "ops-init:           the Stop hook resolves the nearest .operator/ above its cwd, so a" >&2
    echo "ops-init:           second ledger here will shadow the root one for anything beneath it" >&2
  fi
fi

mkdir -p "$OPDIR/pending" "$OPDIR/verdicts.d"

# Lock ephemera are transient mutual-exclusion markers, not evidence. Without
# this they show up as untracked noise inside a tracked tree and can be committed
# by an over-broad `git add`, at which point a checked-out stale lock makes every
# writer pay the full crash-presumption budget. (Audit F05.)
if [ ! -f "$OPDIR/.gitignore" ]; then
  cat > "$OPDIR/.gitignore" <<'EOF'
# Transient lock markers — never evidence, never committed.
.lock/
.lock.reclaim/
.adopt.*
EOF
  echo "created $OPDIR/.gitignore (lock ephemera)"
fi

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

# The tier config: tier→model (and optional seat→tier) bindings the renderer
# (ops-render.sh) and the resolver (ops-tiers.sh) read. Commented defaults only —
# uncomment/override to repoint a tier to a cc-proxy model id or bind a seat.
# Layered: this project file overrides ~/.claude/cc-operator/tiers.env. Never
# clobbered once it exists (the operator's bindings are source-of-truth here).
if [ ! -f "$OPDIR/tiers.env" ]; then
  cat > "$OPDIR/tiers.env" <<'EOF'
# Tier → model-id bindings (cc-proxy routes by id shape: glm-*, vendor/model,
# claude-*). Uncomment and edit to repoint a tier, e.g. MECHANICAL=glm-5-turbo.
#JUDGMENT=claude-opus-5
#IMPLEMENT=claude-sonnet-5
#MECHANICAL=glm-5-turbo
#RECON=claude-haiku-4-5-20251001
#
# Seat → tier overrides (optional; 'op-' prefix optional). Default seats:
#   author=JUDGMENT  mechanic=IMPLEMENT  scout=RECON  verifier=JUDGMENT
#   crawler=MECHANICAL  brainstorm=MECHANICAL
# Example: run scout on the cheap tier too.
#op-scout=MECHANICAL
EOF
  echo "created $OPDIR/tiers.env (commented defaults)"
else
  echo "kept $OPDIR/tiers.env (exists)"
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
