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
_GI_MARK='# cc-operator gitignore v3 (allowlist)'
# The PREVIOUS scheme's marker. v2 -> v3 is ADDITIVE (v3 is v2 plus the two
# specs/ allow lines), and that is the whole reason this arm exists: the v1 ->
# v2 migration REPLACES because a blocklist and an allowlist contradict, but
# replacing a v2 file would silently delete every allow line the user added by
# hand. An additive scheme change must not use a destructive migration (#156).
_GI_MARK_V2='# cc-operator gitignore v2 (allowlist)'
# The lines v3 adds. Appended AFTER the existing body, which is where a
# negation has to sit to override the `*` above it, and the marker goes LAST
# so a partial append leaves the file unmarked and the next run retries.
_GI_V3_ADDS='!specs/
!specs/*.md'
# ATOMIC: heredoc into a temp, same-dir mv (Copilot review on PR #97, the
# SessionStart writer's lesson applied to this one): a cat dying mid-write
# under set -e left a truncated marker-less .gitignore, and the RE-RUN's
# migration then copied that truncated file over the good .v1.bak. With the
# temp+mv the live file is always the old content or the complete v2.
_gi_write() {
  if [ -L "$OPDIR/.gitignore.v3.tmp" ] || { [ -e "$OPDIR/.gitignore.v3.tmp" ] && [ ! -f "$OPDIR/.gitignore.v3.tmp" ]; }; then
    echo "ops-init: $OPDIR/.gitignore.v3.tmp exists and is not a regular file — refusing to write the allowlist through it (move it aside, then re-run)" >&2
    return 1
  fi
  cat > "$OPDIR/.gitignore.v3.tmp" <<EOF
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
!specs/
!specs/*.md
EOF
  mv -f "$OPDIR/.gitignore.v3.tmp" "$OPDIR/.gitignore"
}
if [ ! -f "$OPDIR/.gitignore" ]; then
  _gi_write
  echo "created $OPDIR/.gitignore (allowlist: ledgers + fragments + tiers.env + specs)"
elif ! grep -qF "$_GI_MARK" "$OPDIR/.gitignore" 2>/dev/null \
     && grep -qF "$_GI_MARK_V2" "$OPDIR/.gitignore" 2>/dev/null; then
  # v2 -> v3: ADDITIVE, so APPEND rather than replace. Every line the user
  # added to their allowlist survives by construction, which a rewrite cannot
  # promise. No backup is taken and none is needed: nothing is removed.
  # The marker is written LAST — a die mid-append leaves the file unmarked, so
  # the next run retries rather than leaving a half-upgraded file that reads
  # as done.
  # TERMINATE THE LAST LINE FIRST, exactly as the .gitattributes arm below
  # does and for the identical reason: `>>` appends at the byte offset the file
  # ends at, so a v2 allowlist whose last line has no trailing newline FUSES
  # that line with the first appended one. Measured: a file ending
  # `!my-hand-added.md` (no newline) became `!my-hand-added.md!specs/` — the
  # user's own allow rule DESTROYED, `!specs/` never in effect, and the v3
  # marker landing anyway so nothing ever retries. That is precisely the
  # outcome this additive arm exists to prevent, reintroduced by the append's
  # own mechanics. An editor that strips the final newline is ordinary.
  if [ -s "$OPDIR/.gitignore" ] && [ -n "$(tail -c 1 "$OPDIR/.gitignore")" ]; then
    # `$( )` strips trailing newlines, so non-empty output means the last byte
    # is NOT one — the portable spelling of "does this file end in a newline".
    printf '\n' >> "$OPDIR/.gitignore" || true
  fi
  if printf '%s\n%s\n' "$_GI_V3_ADDS" "$_GI_MARK" >> "$OPDIR/.gitignore" 2>/dev/null; then
    echo "upgraded $OPDIR/.gitignore to the v3 allowlist (added specs/; your own allow lines were kept)"
  else
    echo "ops-init: could not append the v3 allow lines to $OPDIR/.gitignore — it stays v2, so .operator/specs/ is ignored until this is fixed" >&2
  fi
elif ! grep -qF "$_GI_MARK" "$OPDIR/.gitignore" 2>/dev/null; then
  # MIGRATION: v1 and the allowlist contradict, so REPLACE, keeping a copy.
  # BACKUP FIRST, overwrite ONLY on backup success (a swallowed cp failure
  # once destroyed the user's rules while claiming recoverability). The backup
  # path must be a non-symlink regular file — `-f` follows symlinks, so cp
  # would overwrite the link's target instead of writing a backup.
  if [ -L "$OPDIR/.gitignore.v1.bak" ] || { [ -e "$OPDIR/.gitignore.v1.bak" ] && [ ! -f "$OPDIR/.gitignore.v1.bak" ]; }; then
    echo "cc-operator: $OPDIR/.gitignore.v1.bak exists and is not a regular file — refusing to migrate .gitignore (move it aside, then re-run)" >&2
  elif ! cp "$OPDIR/.gitignore" "$OPDIR/.gitignore.v1.bak" 2>/dev/null; then
    echo "cc-operator: could not write $OPDIR/.gitignore.v1.bak — refusing to migrate .gitignore without a backup (the v1 blocklist and the allowlist contradict, so migration REPLACES the file)" >&2
  else
    _gi_write
    echo "migrated $OPDIR/.gitignore to the v3 allowlist (previous kept as .gitignore.v1.bak)"
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
#
# `text eol=lf` is #138's complement to #136's reader guards, and the ORDER of
# that sentence matters: it is an ADDITION, never a replacement. Measured on a
# scratch repo with core.autocrlf=true — the setting every Windows clone gets:
#   without it, a fresh checkout of a committed ledger yields `| … | PASS |\r\n`
#   with it,    the same checkout yields `| … | PASS |\n`
# and, in the same repo, a ledger written CRLF by an EDITOR in the worktree
# stays CRLF regardless, because gitattributes normalize on checkout and commit,
# not on third-party writes. So this closes git as a PRODUCER of CRLF ledgers
# and leaves every reader guard load-bearing.
#
# Written per-file rather than as a `*` rule: .operator/ also holds bin/ (the
# installed CLIs) and pending/ sentinels, and declaring those `text` would
# invite git to rewrite bytes in files whose whole point is byte-fidelity.
if [ ! -f "$OPDIR/.gitattributes" ]; then
  cat > "$OPDIR/.gitattributes" <<'EOF'
# Append-only ledgers: take both sides on merge, never a conflict marker.
# Re-run `.operator/bin/ops-verdict.sh --reconcile` after any messy merge.
#
# eol=lf: git must never hand a reader a CRLF ledger (#138). The readers strip
# a trailing CR anyway (#136) — this stops the file from arriving that way.
VERDICTS.md merge=union
VERDICTS.md text eol=lf
DECISIONS.md merge=union
DECISIONS.md text eol=lf
verdicts.d/*.md merge=union
verdicts.d/*.md text eol=lf
EOF
  echo "created $OPDIR/.gitattributes (append-only merge=union, eol=lf)"
else
  # THE UPGRADE PATH. The write above is guarded by `[ ! -f ]`, so without this
  # branch every project scaffolded before #138 keeps its existing file and
  # NEVER gains the rule — measured on this plugin's own repo, whose
  # `.operator/.gitattributes` returned `grep -c 'eol=lf'` -> 0. A fix that
  # reaches only new projects is not the fix #138 asked for.
  #
  # APPEND-ONLY, one line at a time, and never a rewrite: the file may carry
  # attributes the project added by hand, and clobbering those to deliver an
  # eol rule trades one silent loss for another. ops-init.sh re-runs on every
  # /cc-operator:start, which is what carries this to existing projects with no
  # migration step — and is also why it must be IDEMPOTENT: an unconditional
  # append grows the file on every session, and a rule repeated forty times
  # still works, so nothing would ever report it.
  # TERMINATE THE LAST LINE FIRST. `>>` appends at the byte offset the file
  # ends at, so an existing .gitattributes with no trailing newline FUSES its
  # last rule with the first appended one: measured, a file containing exactly
  # `VERDICTS.md merge=union` (no newline) became
  # `VERDICTS.md merge=unionVERDICTS.md text eol=lf`. git accepts that silently
  # as an attribute nobody wrote, and the ORIGINAL merge=union rule is gone —
  # so the upgrade would destroy the very rule it was meant to sit beside.
  # An editor that strips the final newline is ordinary, not exotic.
  if [ -s "$OPDIR/.gitattributes" ] \
     && [ -n "$(tail -c 1 "$OPDIR/.gitattributes")" ]; then
    # `$( )` strips trailing newlines, so non-empty output means the last byte
    # is NOT one — the portable spelling of "does this file end in a newline".
    printf '\n' >> "$OPDIR/.gitattributes" || true
  fi
  _ga_added=0
  _ga_failed=0
  for _ga_path in 'VERDICTS.md' 'DECISIONS.md' 'verdicts.d/*.md'; do
    # LINE-ANCHORED, not a bare substring. `grep -qF "<path> text eol=lf"` also
    # matches the rule inside a COMMENT or as the tail of a longer path, and
    # either one suppresses the append forever: measured, a file carrying
    # `# VERDICTS.md text eol=lf disabled by the project` kept
    # `git check-attr text eol -- .operator/VERDICTS.md` at `unspecified` while
    # ops-init reported success, and `sub/VERDICTS.md text eol=lf` did the same.
    # -x with the exact line is what "is this rule present" actually means.
    # -F still, because `verdicts.d/*.md` is a literal here, not a pattern.
    grep -qxF "${_ga_path} text eol=lf" "$OPDIR/.gitattributes" && continue
    # REDIRECT SUPPRESSED, then reported in our own words. A bare `>>` on an
    # unwritable file prints bash's own `line 168: …: Permission denied`
    # BEFORE the warning below — the "raw bash error as operator guidance"
    # landmine this file already observes everywhere else (see _gi_write).
    { printf '%s text eol=lf\n' "$_ga_path" >> "$OPDIR/.gitattributes"; } 2>/dev/null || {
      _ga_failed=$((_ga_failed + 1))
      continue   # NOT break: each path is independent, and stopping at the
                 # first failure hid the other two while still printing a
                 # success line for whatever had already landed.
    }
    _ga_added=$((_ga_added + 1))
  done
  if [ "$_ga_failed" -gt 0 ]; then
    echo "ops-init: WARNING — could not append ${_ga_failed} eol=lf rule(s) to $OPDIR/.gitattributes (read-only file or directory?). Ledgers may still be checked out CRLF on a core.autocrlf=true clone; the readers strip a trailing CR either way (#136), so this degrades rather than breaks." >&2
  fi
  [ "$_ga_added" -eq 0 ] \
    || echo "updated $OPDIR/.gitattributes (+${_ga_added} eol=lf rule(s); existing lines untouched)"
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
# claude-*). Uncomment and edit to repoint a tier, e.g. MECHANICAL=glm-4.7.
#JUDGMENT=claude-opus-5
#IMPLEMENT=claude-sonnet-5
#MECHANICAL=glm-5.3-flash
#RECON=claude-haiku-4-5-20251001
#
# Seat → tier overrides (optional; 'op-' prefix optional). Default seats:
#   author=JUDGMENT  mechanic=IMPLEMENT  scout=RECON  verifier=JUDGMENT
#   crawler=MECHANICAL  brainstorm=MECHANICAL
# Example: run scout on the cheap tier too.
#op-scout=MECHANICAL
#
# Debate panel (ops-tiers.sh --panel, #172): one seat per id, fallback in order
# when one is unroutable; persona:<id> re-seats <id> under another temperament.
#PANEL=claude-opus-5,glm-5.3,deepseek-flash
#PANEL_FALLBACK=qwen3.8-max,persona:claude-opus-5
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
