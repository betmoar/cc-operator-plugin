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

# Mis-aim warning (F05): warn, never hard-fail — a non-git project is legit.
# Compare PHYSICAL to PHYSICAL (#61: --show-toplevel resolves symlinks, $PWD
# does not — /tmp is a symlink on macOS, so logical-vs-physical cried wolf).
# Both substitutions guarded: under set -eu an unguarded failure would kill the
# scaffold; empty PHYS_PWD SKIPS the comparison rather than comparing "".
if command -v git >/dev/null 2>&1; then
  TOPLEVEL="$(git rev-parse --show-toplevel 2>/dev/null || true)"
  PHYS_PWD="$(pwd -P 2>/dev/null || true)"
  if [ -z "$TOPLEVEL" ]; then
    echo "ops-init: warning — $PWD is not a git repository; the ledger will not be tracked or reviewable" >&2
  elif [ -n "$PHYS_PWD" ] && [ "$TOPLEVEL" != "$PHYS_PWD" ]; then
    # both printed PHYSICALLY, or a symlink invites the #61 misreading again
    echo "ops-init: warning — scaffolding at $PHYS_PWD, which is NOT the repository root ($TOPLEVEL)" >&2
    echo "ops-init:           the Stop hook resolves the nearest .operator/ above its cwd, so a" >&2
    echo "ops-init:           second ledger here will shadow the root one for anything beneath it" >&2
  fi
fi

mkdir -p "$OPDIR/pending" "$OPDIR/verdicts.d"

# ALLOWLIST, not a blocklist (v2): a blocklist defaults new machine state to
# TRACKED, a silently recurring failure. Tracked = what a teammate needs
# (ledgers, verdicts.d/ fragments — merge=union operates on them — tiers.env);
# everything else the plugin recreates. OPERATOR.md goes to the project ROOT.
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
EOF
}
if [ ! -f "$OPDIR/.gitignore" ]; then
  _gi_write
  echo "created $OPDIR/.gitignore (allowlist: ledgers + fragments + tiers.env)"
elif ! grep -qF "$_GI_MARK" "$OPDIR/.gitignore" 2>/dev/null; then
  # MIGRATION: v1 and v2 contradict, so REPLACE, keeping a copy.
  # BACKUP FIRST, overwrite ONLY on backup success (a swallowed cp failure
  # once destroyed the user's rules while claiming recoverability). The backup
  # path must be a non-symlink regular file — `-f` follows symlinks, so cp
  # would overwrite the link's target instead of writing a backup.
  if [ -L "$OPDIR/.gitignore.v1.bak" ] || { [ -e "$OPDIR/.gitignore.v1.bak" ] && [ ! -f "$OPDIR/.gitignore.v1.bak" ]; }; then
    echo "cc-operator: $OPDIR/.gitignore.v1.bak exists and is not a regular file — refusing to migrate .gitignore (move it aside, then re-run)" >&2
  elif ! cp "$OPDIR/.gitignore" "$OPDIR/.gitignore.v1.bak" 2>/dev/null; then
    echo "cc-operator: could not write $OPDIR/.gitignore.v1.bak — refusing to migrate .gitignore without a backup (the v1 and v2 schemes contradict, so migration REPLACES the file)" >&2
  else
    _gi_write
    echo "migrated $OPDIR/.gitignore to the v2 allowlist (previous kept as .gitignore.v1.bak)"
  fi
fi

# A root .gitignore excluding /.operator/ beats the allowlist (git never
# descends into an excluded dir), silently shipping NO evidence (#25). Warn,
# never fail — the exclusion may be deliberate. ops-init only; the SessionStart
# refresh must stay quiet.
if command -v git >/dev/null 2>&1 && git rev-parse --git-dir >/dev/null 2>&1; then
  # TWO CALLS ON PURPOSE: `-q` answers ignored-or-not by EXIT STATUS; `-v`
  # prints a line for a `!` negation too (exit 0), so non-empty -v output is
  # NOT "ignored". Collapsing them inverts this warning on every v2 project —
  # tried and reverted twice.
  if git check-ignore -q "$OPDIR/VERDICTS.md" 2>/dev/null; then
    _gi_rule="$(git check-ignore -v "$OPDIR/VERDICTS.md" 2>/dev/null | head -n 1)"
    {
      echo "ops-init: WARNING — the evidence ledger is gitignored by a rule outside $OPDIR/.gitignore:"
      echo "ops-init:   ${_gi_rule:-<rule unresolvable>}"
      echo "ops-init:   committed evidence cannot leave this machine while that rule stands (issue #25)"
    } >&2
  fi
fi

# Per-session fragments (verdicts.d/<owner>.md) let two branches append to two
# files and merge cleanly; --reconcile restores rows after any messy merge.
# merge=union needs no user config; scoped to .operator/, never the host root.
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

# Tier config read by ops-tiers.sh + ops-render.sh. Commented defaults;
# project file overrides the user file; never clobbered once it exists.
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

# Install the gate CLIs so the charter's .operator/bin/ paths resolve in any
# project (the model's shell has no ${CLAUDE_PLUGIN_ROOT}); always refreshed.
# The set is ONE manifest (#76 step 3) shared with SessionStart; a missing
# manifest fails LOUD here — this writer runs interactively (CR4).
[ -f "$SCRIPT_DIR/ops-install-set.sh" ] || {
  echo "ops-init: $SCRIPT_DIR/ops-install-set.sh is missing — cannot install the gate CLIs (the install set is declared there; a partial install would break the charter's .operator/bin/ paths)" >&2
  exit 1
}
# shellcheck source=/dev/null
. "$SCRIPT_DIR/ops-install-set.sh"
mkdir -p "$OPDIR/bin"
for tool in $_OPS_TOOLS; do
  cp "$SCRIPT_DIR/$tool" "$OPDIR/bin/$tool"
  chmod +x "$OPDIR/bin/$tool"
done
echo "installed $OPDIR/bin/{$(printf '%s' "$_OPS_TOOLS" | tr ' ' ',')}"

# Version stamp: SessionStart compares and auto-refreshes bin/ on mismatch —
# the upgrade path for projects that never re-run /cc-operator:start.
_ver="$(grep -m1 '"version"' "$SCRIPT_DIR/../.claude-plugin/plugin.json" 2>/dev/null \
        | sed 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')"
if [ -n "$_ver" ]; then
  printf '%s\n' "$_ver" > "$OPDIR/.version"
fi

echo "operator ledger ready at $OPDIR/"
