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

# ALLOWLIST, not a blocklist (v2). The original listed the ephemera to ignore —
# and every directory added since had to be remembered and appended, twice (F05
# for .lock/, then .compress-spill/ once a user's tree went dirty). A blocklist
# defaults new state to TRACKED, so the failure mode is silent and recurring: the
# entry ships, nobody notices, and it is committed by an over-broad `git add`.
# (A checked-out stale lock then makes every writer pay the crash-presumption
# budget.) Inverting the default costs one migration and ends the class.
#
# What stays tracked is exactly what a teammate needs to reconstruct the
# engagement: the two ledgers, their per-session fragments (verdicts.d/ is what
# `merge=union` in .gitattributes operates on — un-tracking it breaks the
# clean-merge property the fragment scheme exists for), and the tier config.
# Everything else — pending/, bin/, locks, compressor ephemera, whatever is added
# next — is machine state that the plugin recreates.
#
# OPERATOR.md is NOT here: /cc-operator:start writes it to the project ROOT.
_GI_MARK='# cc-operator gitignore v2 (allowlist)'
_gi_write() {
  cat > "$OPDIR/.gitignore" <<EOF
$_GI_MARK
# Ignore everything under .operator/ by default, then re-admit the evidence.
# New machine state is ignored automatically — that is the point of the
# inversion; do not add ignore lines here, add allow lines only when a NEW file
# is genuinely evidence a teammate must read.
*
!.gitignore
!.gitattributes
!VERDICTS.md
!DECISIONS.md
!tiers.env
!verdicts.d/
!verdicts.d/*.md
!handoff-*.md
!armgate.on
EOF
}
if [ ! -f "$OPDIR/.gitignore" ]; then
  _gi_write
  echo "created $OPDIR/.gitignore (allowlist: ledgers + fragments + tiers.env)"
elif ! grep -qF "$_GI_MARK" "$OPDIR/.gitignore" 2>/dev/null; then
  # MIGRATION. A v1 blocklist cannot be appended to — the two schemes contradict
  # (v1 tracks by default, v2 ignores by default), and appending `*` to a v1 file
  # would ignore the ledgers while the earlier lines say nothing about them.
  # Replace it, keeping a copy: this file is the user's, and a rewrite they did
  # not ask for must be recoverable.
  cp "$OPDIR/.gitignore" "$OPDIR/.gitignore.v1.bak" 2>/dev/null
  _gi_write
  echo "migrated $OPDIR/.gitignore to the v2 allowlist (previous kept as .gitignore.v1.bak)"
fi

# The allowlist above lives INSIDE .operator/ and cannot beat a rule that
# excludes the directory itself: git never descends into an excluded directory,
# so the negations have nothing to re-admit. A root .gitignore carrying
# `/.operator/` ships NO evidence — silently, with this scaffold reporting
# success (issue #25, measured 2026-08-09). Detect it and say so. Warn, never
# fail: the exclusion may be deliberate (this repo's own dogfooding does exactly
# that, which is why the failure was never seen here). This lives in ops-init
# only, NOT the SessionStart refresh — that hook runs on every session and must
# stay quiet.
if command -v git >/dev/null 2>&1 && git rev-parse --git-dir >/dev/null 2>&1; then
  if git check-ignore -q "$OPDIR/VERDICTS.md" 2>/dev/null; then
    _gi_rule="$(git check-ignore -v "$OPDIR/VERDICTS.md" 2>/dev/null | head -n 1)"
    {
      echo "ops-init: WARNING — the evidence ledger is gitignored by a rule outside $OPDIR/.gitignore:"
      echo "ops-init:   ${_gi_rule:-<rule unresolvable>}"
      echo "ops-init:   committed evidence cannot leave this machine while that rule stands (issue #25)"
    } >&2
  fi
fi

# (The compressor-ephemera append that used to live here is gone: under the v2
# allowlist `*` already covers .compress-spill/ and .compress-state/, and every
# future ephemera directory, without anyone having to remember them. The
# migration branch above is what carries a v1 project across. The compressor
# additionally writes its own `*` ignore inside each ephemera root, so a project
# that never ran this script at all still stays clean — see
# ops-compress.mjs:ephemeralRoot.)

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
for tool in ops-verdict.sh ops-task.sh ops-adopt.sh ops-claims.sh ops-backlog.sh; do
  cp "$SCRIPT_DIR/$tool" "$OPDIR/bin/$tool"
  chmod +x "$OPDIR/bin/$tool"
done
echo "installed $OPDIR/bin/{ops-verdict.sh,ops-task.sh,ops-adopt.sh,ops-claims.sh,ops-backlog.sh}"

# Stamp the installed plugin version. SessionStart compares this to the running
# plugin's version and auto-refreshes bin/ when it differs — the automated
# upgrade path for projects that don't re-run /cc-operator:start. ops-init writes
# the current version; SessionStart keeps it current. (User request 2026-08-04.)
_ver="$(grep -m1 '"version"' "$SCRIPT_DIR/../.claude-plugin/plugin.json" 2>/dev/null \
        | sed 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')"
if [ -n "$_ver" ]; then
  printf '%s\n' "$_ver" > "$OPDIR/.version"
fi

echo "operator ledger ready at $OPDIR/"
