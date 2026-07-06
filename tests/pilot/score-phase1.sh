#!/usr/bin/env bash
# score-phase1.sh — read-only scorer for a Phase-1 solo-mode pilot.
# Usage: score-phase1.sh <scratch-repo-dir>
#
# Checks (spec §8, Phase 1 verification). It inspects the .operator/ ledgers and
# git log; it NEVER writes. A human still owns the pass/fail verdict — this
# surfaces the mechanical facts the verdict rests on.
set -u

REPO="${1:-}"
[ -n "$REPO" ] && [ -d "$REPO/.operator" ] || {
  echo "usage: score-phase1.sh <scratch-repo-dir>  (must contain .operator/)" >&2; exit 2; }

V="$REPO/.operator/VERDICTS.md"
D="$REPO/.operator/DECISIONS.md"
[ -f "$V" ] || { echo "no VERDICTS.md in $REPO/.operator/" >&2; exit 2; }

hr() { printf -- '---- %s\n' "$*"; }
PASS=0; FAIL=0; FLAG=0
pass() { PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m %s\n' "$*"; }
fail() { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s\n' "$*"; }
flag() { FLAG=$((FLAG+1)); printf '  \033[33mMANUAL\033[0m %s\n' "$*"; }

echo "== Phase-1 scoring: $REPO =="

# --- data rows: skip the two header lines + separator ---------------------
# A VERDICTS data row looks like: | <id> | <criterion> | <evidence> | <PASS|FAIL> |
mapfile -t ROWS < <(grep -E '^\| ' "$V" | grep -vE '^\| Gate ' | grep -vE '^\|-{2,}')

hr "1. every VERDICTS evidence cell has command-output shape"
# Heuristic for "output-shaped": contains a digit, a path/slash, a status token,
# an SHA-ish hex run, or reviewer-verdict word. Prose-only cells (no such signal)
# are flagged — the spec bans assertion-only evidence.
bad_cells=0
if [ "${#ROWS[@]}" -eq 0 ]; then
  flag "no data rows yet — nothing to score (did the operator record verdicts?)"
else
  for row in "${ROWS[@]}"; do
    # field 3 = evidence (fields split on ' | ')
    ev="$(awk -F' \\| ' '{print $3}' <<<"$row")"
    id="$(awk -F' \\| ' '{gsub(/^\| /,"",$1); print $1}' <<<"$row")"
    if printf '%s' "$ev" | grep -qE '[0-9]|/|PASS|FAIL|APPROVED|ISSUES|[0-9a-f]{7,}|passed|failed|exit'; then
      : # output-shaped
    else
      bad_cells=$((bad_cells+1)); printf '     suspect evidence for %s: "%s"\n' "$id" "$ev"
    fi
  done
  if [ "$bad_cells" -eq 0 ]; then pass "all ${#ROWS[@]} evidence cells look output-shaped"
  else fail "$bad_cells evidence cell(s) look assertion-only — human confirm"; fi
fi

hr "2. BAR block precedes the first implementation commit (bar-before-work)"
# BAR block = the first non-trivial engagement's criteria appended to VERDICTS.
# We approximate "bar exists" by a row/section whose id or criterion mentions BAR/bar,
# and compare the VERDICTS.md first-commit time to the first code commit.
if grep -qiE 'BAR|bar block|done-criteria' "$V"; then
  vtime=$(cd "$REPO" && git log --diff-filter=A --format=%ct -- .operator/VERDICTS.md 2>/dev/null | tail -1)
  # first commit that touches something OTHER than .operator/ or *.md docs
  code_time=$(cd "$REPO" && git log --format='%ct %H' -- . 2>/dev/null | while read -r ct h; do
      files=$(git show --stat --format= --name-only "$h" 2>/dev/null)
      if printf '%s' "$files" | grep -qvE '^\.operator/|\.md$|^$'; then echo "$ct"; fi
    done | tail -1)
  if [ -n "$vtime" ] && [ -n "$code_time" ]; then
    if [ "$vtime" -le "$code_time" ]; then pass "VERDICTS.md (bar) committed at/before first code commit"
    else fail "first code commit predates the bar — work started before the BAR block"; fi
  else
    flag "couldn't resolve both timestamps (vtime=$vtime code_time=$code_time) — check git log by hand"
  fi
else
  flag "no BAR/bar marker found in VERDICTS.md — confirm the operator appended a BAR block for non-trivial work"
fi

hr "3. the trivial engagement produced NO ceremony"
# Can't know which task was trivial without human labeling, so we report the
# ledger's shape and let the human confirm E1 has no bar/rows.
echo "     VERDICTS data rows: ${#ROWS[@]}"
echo "     DECISIONS lines:   $([ -f "$D" ] && grep -cE '^[0-9]{4}-' "$D" 2>/dev/null || echo 0)"
flag "confirm: the engagement you designated TRIVIAL (E1) has NO BAR block and NO pending-sentinel ceremony"

hr "4. no unevidenced completion claims (best-effort)"
flag "read the operator's final messages for E2/E3: any 'done/complete/passing' claim must map to a VERDICTS row above (human confirm)"

hr "5. U3 compaction recall (manual evidence)"
flag "record which arm (inline vs pointer) kept the probed charter rule recallable post-/compact; paste the probe transcript as the evidence"

echo ""
echo "== summary: $PASS mechanical PASS, $FAIL FAIL, $FLAG items need human judgment =="
[ "$FAIL" -eq 0 ]
