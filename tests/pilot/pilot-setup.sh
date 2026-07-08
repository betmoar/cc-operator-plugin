#!/usr/bin/env bash
# pilot-setup.sh — prepare a scratch repo for an operator pilot (Phase 1 or 3).
#
# Modes:
#   --check                 doctor: verify tooling + both plugins reachable, exit
#   --phase <1|3> --dir <p> build a scratch repo at <p>, install plugins,
#                           materialize the charter, print next actions
#   --inline                (with --phase) inline the charter into CLAUDE.md
#                           instead of the OPERATOR.md pointer (U3 inline arm)
#
# This script does NOT choose your model. Set Opus 4.8 in the pilot session
# (/model or `claude --model claude-opus-4-8`) — model choice is what U1 measures.
#
# It is idempotent-ish: it refuses to clobber a non-empty --dir unless --force.
set -u

# --- locate this plugin (operator) and the harness skill ---------------------
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"       # tests/pilot
OP_REPO="$(cd "$SELF_DIR/../.." && pwd)"                         # operator repo root
OP_PLUGIN="$OP_REPO"                                             # plugin lives at repo root (flattened)
# harness skill: sibling checkout by default; override with $HARNESS_DIR
HARNESS_DIR="${HARNESS_DIR:-$(cd "$OP_REPO/.." && pwd)/cc-harness-plugin/unknowns-harness}"

say()  { printf '%s\n' "$*"; }
ok()   { printf '  \033[32mok\033[0m   %s\n' "$*"; }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$*"; }
warn() { printf '  \033[33mwarn\033[0m %s\n' "$*"; }

# --- arg parse ---------------------------------------------------------------
MODE=""; PHASE=""; DIR=""; INLINE=0; FORCE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --check)  MODE=check ;;
    --phase)  MODE=build; PHASE="${2:-}"; shift ;;
    --dir)    DIR="${2:-}"; shift ;;
    --inline) INLINE=1 ;;
    --force)  FORCE=1 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
  shift
done

# --- doctor ------------------------------------------------------------------
check_env() {
  local fail=0
  say "== tooling =="
  for t in claude jq git bash; do
    if command -v "$t" >/dev/null 2>&1; then ok "$t: $(command -v "$t")"
    else bad "$t: MISSING"; fail=1; fi
  done
  say "== plugins on disk =="
  if [ -f "$OP_PLUGIN/.claude-plugin/plugin.json" ]; then ok "operator plugin: $OP_PLUGIN"
  else bad "operator plugin.json not found at $OP_PLUGIN"; fail=1; fi
  if [ -f "$HARNESS_DIR/.claude-plugin/plugin.json" ]; then ok "unknowns-harness: $HARNESS_DIR"
  else bad "unknowns-harness plugin.json not found at $HARNESS_DIR (set HARNESS_DIR=...)"; fail=1; fi
  if [ -f "$HARNESS_DIR/skills/surfacing-unknowns/SKILL.md" ]; then ok "surfacing-unknowns skill present"
  else warn "surfacing-unknowns/SKILL.md not found under $HARNESS_DIR/skills/ — the skill composition (spec D1.2) won't be exercisable"; fi
  say "== model reminder =="
  warn "set the pilot session to Opus 4.8 yourself (/model). This script does not — U1 depends on a deliberate choice."
  return $fail
}

if [ "$MODE" = check ]; then
  check_env; rc=$?
  if [ $rc -eq 0 ]; then say "== READY =="; else say "== NOT READY (fix FAILs above) =="; fi
  exit $rc
fi

# --- build a scratch repo ----------------------------------------------------
[ "$MODE" = build ] || { echo "usage: --check | --phase <1|3> --dir <path> [--inline]" >&2; exit 2; }
case "$PHASE" in 1|3) ;; *) echo "--phase must be 1 or 3" >&2; exit 2 ;; esac
[ -n "$DIR" ] || { echo "--dir <path> required" >&2; exit 2; }

check_env || { echo "environment not ready — fix the FAILs above first" >&2; exit 1; }

if [ -e "$DIR" ] && [ -n "$(ls -A "$DIR" 2>/dev/null)" ] && [ "$FORCE" -ne 1 ]; then
  echo "refusing to use non-empty $DIR (pass --force to override)" >&2; exit 1
fi

mkdir -p "$DIR"
say "== scratch repo: $DIR =="
( cd "$DIR" && git init -q && git commit -q --allow-empty -m "init pilot scratch repo" ) && ok "git initialized"

# Materialize the operator charter the way /cc-operator:start does, using the
# plugin's own scripts so the pilot exercises the real artifact.
( cd "$DIR" && bash "$OP_PLUGIN/scripts/ops-init.sh" >/dev/null ) && ok ".operator/ ledgers created"
cp "$OP_PLUGIN/templates/OPERATOR.md" "$DIR/OPERATOR.md" && ok "OPERATOR.md materialized"

if [ "$INLINE" -eq 1 ]; then
  {
    printf '\n## Operator\n'
    cat "$OP_PLUGIN/templates/OPERATOR.md"
  } >> "$DIR/CLAUDE.md"
  ok "charter INLINED into CLAUDE.md (U3 inline arm)"
else
  {
    printf '\n## Operator\n'
    printf 'Read OPERATOR.md — it is this session'"'"'s operating charter.\n'
  } >> "$DIR/CLAUDE.md"
  ok "CLAUDE.md pointer stanza appended (U3 pointer arm — default)"
fi

# Install both plugins from local paths (absolute — bare '.' is rejected by the CLI).
say "== installing plugins (marketplace-from-local-path) =="
if claude plugin marketplace add "$OP_REPO" >/dev/null 2>&1; then ok "operator marketplace added"
else warn "operator marketplace add failed (maybe already added) — check 'claude plugin marketplace list'"; fi
if claude plugin install operator@operator >/dev/null 2>&1; then ok "operator installed"
else warn "operator install failed (maybe already installed)"; fi
# harness has no root marketplace.json; add its plugin dir's parent if present
if [ -f "$HARNESS_DIR/../.claude-plugin/marketplace.json" ]; then
  if claude plugin marketplace add "$(cd "$HARNESS_DIR/.." && pwd)" >/dev/null 2>&1; then ok "harness marketplace added"; else warn "harness marketplace add failed"; fi
  if claude plugin install unknowns-harness >/dev/null 2>&1; then ok "unknowns-harness installed"
  else warn "unknowns-harness install failed — install it manually so surfacing-unknowns is active"; fi
else
  warn "no harness marketplace.json found; install unknowns-harness manually so the skill composition works"
fi

say ""
say "== NEXT ACTIONS (human) =="
say "1. cd $DIR"
say "2. Start a FRESH Claude Code session here, model Opus 4.8 (/model)."
say "3. The charter is active. Give the operator a real task (see PILOT-RUNBOOK §6)."
if [ "$PHASE" = 1 ]; then
  say "   - E1 must be TRIVIAL and must NOT produce a BAR block."
  say "   - E2/E3 non-trivial: expect a BAR block before the first impl commit."
  say "   - U3: force a /compact, then ask the operator to recall a charter rule verbatim; save the answer."
  say "4. Score:  bash $SELF_DIR/score-phase1.sh $DIR"
else
  say "   - A genuine MULTI-TASK job so orchestrated mode triggers on first dispatch."
  say "4. Score:  bash $SELF_DIR/score-phase3.sh $DIR"
fi
say ""
say "Remember: the session that operates must not be the session that scores (RUNBOOK §0)."
