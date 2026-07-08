#!/usr/bin/env bash
# score-phase4.sh — read-only aggregator for the Phase-4 failure-log prune.
# Usage: score-phase4.sh <scratch-dir-1> [<scratch-dir-2> ...]
#        score-phase4.sh ~/operator-pilot-*      (glob expands to the 5+ runs)
#
# Phase 4 (spec §8) audits .operator/DECISIONS.md across ≥5 real engagements and
# scores every charter rule exercised / violated / inert. This script does the
# mechanical part: pull every DECISIONS line across runs, tally by type, and
# cross-reference charter citation tags so you can see which rules the ledgers
# actually touched. The keep/delete call is human. Read-only.
set -u

[ $# -ge 1 ] || { echo "usage: score-phase4.sh <scratch-dir>...  (or a glob)" >&2; exit 2; }

# Resolve the operator charter to enumerate its rules/tags. Prefer the committed
# template in this repo; the pilot charters are copies of it.
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHARTER="$(cd "$SELF_DIR/../.." && pwd)/templates/OPERATOR.md"

hr() { printf -- '---- %s\n' "$*"; }
echo "== Phase-4 aggregation across $# run(s) =="

# --- 1. collect all DECISIONS lines ------------------------------------------
tmp="$(mktemp)"; total_runs=0; missing=0
for dir in "$@"; do
  d="$dir/.operator/DECISIONS.md"
  if [ -f "$d" ]; then
    total_runs=$((total_runs+1))
    grep -E '^[0-9]{4}-' "$d" >> "$tmp" 2>/dev/null
  else
    missing=$((missing+1)); printf '  (no DECISIONS.md in %s)\n' "$dir"
  fi
done
lines=$(wc -l < "$tmp" | tr -d ' ')
echo "runs with a ledger: $total_runs   missing: $missing   total DECISIONS lines: $lines"
if [ "$total_runs" -lt 5 ]; then
  printf '  \033[33mNOTE\033[0m Phase 4 requires >=5 real engagements; you have %d. Trigger is not met yet (spec §8).\n' "$total_runs"
fi

hr "2. DECISIONS by type (the incident distribution)"
if [ "$lines" -gt 0 ]; then
  awk -F' \\| ' '{print $3}' "$tmp" | sort | uniq -c | sort -rn | sed 's/^/  /'
else
  echo "  (no DECISIONS lines collected)"
fi

hr "3. charter rules vs. ledger mentions (exercised/inert hint)"
# Enumerate the charter's citation tags; report whether the aggregated DECISIONS
# happen to mention each tag's core string. IMPORTANT: this is a WEAK signal by
# design. Operators do NOT write tag strings into their ledgers, so most tags
# will read 'no ledger mention' even when the rule was heavily exercised — a rule
# is 'exercised' when the BEHAVIOR it governs happened, not when its tag appears.
# Use this only as a checklist of rules-to-score-by-hand, never as a delete list.
# (This deliberately does not auto-classify: spec §8 makes the prune a human call,
# and D1.5's principle-over-checklist stance warns against a checklist masquerading
# as a verdict.)
if [ -f "$CHARTER" ]; then
  echo "  charter: $CHARTER"
  echo "  (weak signal only — 'no mention' does NOT mean inert; score each rule by the behavior it governs)"
  # distinct tags
  grep -oE '\[D:[^]]+\]|\[DOC:[^]]+\]' "$CHARTER" | sort -u | while read -r tag; do
    core="$(printf '%s' "$tag" | sed -E 's/\[(D|DOC):([^]]+)\]/\2/')"
    if grep -qiF "$core" "$tmp" 2>/dev/null; then
      printf '    %-22s referenced\n' "$tag"
    else
      printf '    %-22s (no ledger mention — inert-candidate, confirm by hand)\n' "$tag"
    fi
  done
else
  echo "  charter template not found at $CHARTER"
fi

hr "4. prune done-condition reminders"
cat <<'EOF'
  - Delete only INERT rules (exercised-nowhere AND not a silent invariant).
  - Admit new rules only against a logged incident, one per incident class.
  - Charter must stay <=150 lines: `wc -l templates/OPERATOR.md`.
  - Re-run the B2 citation-tag gate after editing (every rule line keeps a tag).
  - The prune commit body must carry per-rule keep/delete evidence (spec §8).
EOF

rm -f "$tmp"
echo ""
echo "== aggregation complete — the keep/delete verdict is yours =="
