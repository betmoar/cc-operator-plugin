#!/usr/bin/env bash
# score-phase3.sh — read-only scorer for a Phase-3 orchestrated-mode pilot.
# Usage: score-phase3.sh <scratch-repo-dir>
#
# Checks (spec §8, Phase 3 verification). Read-only. Orchestrated-mode evidence
# lives partly in the ledgers and partly in the session transcript; this scores
# the ledger-visible half and flags the transcript half for human review.
set -u

REPO="${1:-}"
[ -n "$REPO" ] && [ -d "$REPO/.operator" ] || {
  echo "usage: score-phase3.sh <scratch-repo-dir>  (must contain .operator/)" >&2; exit 2; }
V="$REPO/.operator/VERDICTS.md"; D="$REPO/.operator/DECISIONS.md"

hr() { printf -- '---- %s\n' "$*"; }
PASS=0; FAIL=0; FLAG=0
pass() { PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m %s\n' "$*"; }
fail() { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s\n' "$*"; }
flag() { FLAG=$((FLAG+1)); printf '  \033[33mMANUAL\033[0m %s\n' "$*"; }

echo "== Phase-3 scoring: $REPO =="

hr "1. probe rows present BEFORE the first real dispatch"
if grep -qiE 'probe|READY|preflight' "$V" 2>/dev/null; then
  pass "probe/READY marker found in VERDICTS.md"
else
  flag "no probe marker in VERDICTS.md — confirm agent probes ran before the first dispatch (spec O5)"
fi

hr "2. self-audit lines present at each verdict (relaxed-diet checkpoint, O1)"
# Charter O1: at each verdict, one line each — (a) ingested transcript/diff?
# (b) acted outside plumbing carve-out unlogged? Look for these in DECISIONS.
audit=$([ -f "$D" ] && grep -ciE 'self-audit|ingest|transcript|carve-out|carve out' "$D" 2>/dev/null || echo 0)
if [ "$audit" -gt 0 ]; then pass "$audit self-audit-shaped line(s) in DECISIONS.md"
else flag "no self-audit lines found — confirm the operator logged the two O1 questions at each verdict"; fi

hr "3. review-scope decision logged with its test named (D5)"
if [ -f "$D" ] && grep -qiE 'review|merged|published|depended|skip.*review|exploratory' "$D" 2>/dev/null; then
  pass "review-scope reasoning present in DECISIONS.md"
  grep -iE 'review|merged|published|depended|exploratory' "$D" | sed 's/^/     /' | head -5
else
  flag "no review-scope decision found — confirm the ≥1 skipped-review artifact was logged with the merged/published/depended test named"
fi

hr "4. NEEDS_CONTEXT fired on the synthetic underspecified packet"
if [ -f "$D" ] && grep -qiE 'NEEDS_CONTEXT|packet deficient|underspecified' "$D" 2>/dev/null; then
  pass "NEEDS_CONTEXT / packet-deficiency logged"
else
  flag "confirm from the transcript: the synthetic underspecified packet produced NEEDS_CONTEXT under the op-* agents (transcript is the evidence)"
fi

hr "5. dispatch count + report conformance (transcript-side)"
echo "     VERDICTS data rows: $(grep -cE '^\| ' "$V" 2>/dev/null)"
flag "confirm ≥4 dispatches across author+mechanic tiers, each with a packet-conformant record and a ≤30-line ACCOMPLISHED-with-evidence / UNVERIFIED report (transcript)"

echo ""
echo "== summary: $PASS ledger PASS, $FAIL FAIL, $FLAG items need human/transcript review =="
[ "$FAIL" -eq 0 ]
