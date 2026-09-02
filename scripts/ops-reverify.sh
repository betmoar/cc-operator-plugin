#!/usr/bin/env bash
# ops-reverify.sh — which VERDICTS.md rows were written while HEAD sat inside
# a date window, and therefore deserve re-verification (issue #103).
#
# WHY. 0.10.0 through 0.11.3 shipped a compressor whose "lossless" scrub tier
# destroyed any `]`-bearing tool output over 1KB before the model read it
# (audit F120, P0). Evidence quoted from such output is evidence quoted from
# garbage, and nothing in the row says so. The code fix cannot undo that; the
# only honest remedy is to find the rows that MAY have been written under the
# defect and re-run their criteria. This tool does the finding. It never
# writes: the ledger is append-only and has one writer, ops-verdict.sh.
#
# HOW A ROW IS DATED. Every row carries its source stamp inside the evidence
# cell — `@<sha>`, `@<sha>+dirty`, `@no-vcs`, `@no-commit`. A row is written
# while HEAD == <sha>, so its write time lies in [commit date of <sha>, commit
# date of the FIRST descendant of <sha> on the way to today's HEAD] — the
# second bound is "still HEAD" when there is no such descendant, and unknown
# when <sha> is not an ancestor of HEAD (a rebased or deleted branch). A row
# is AFFECTED when that interval overlaps the window. `+dirty` widens nothing:
# the tree was ahead of <sha>, the row was still written while HEAD was <sha>.
# `@no-vcs` / `@no-commit` rows cannot be dated at all and are listed as such.
#
# The window defaults to the PLUGIN's tag dates for v0.10.0 (2026-08-22) and
# v0.11.4 (2026-08-31). Those are the OUTER bounds: a project that upgraded
# late entered the defect late, one that upgraded early left it early. Narrow
# them with --from/--to if you know when this project's plugin moved.
#
# Usage: bash scripts/ops-reverify.sh [--from YYYY-MM-DD] [--to YYYY-MM-DD]
#                                     [--ledger <path>] [--quiet]
#   --ledger  defaults to ./.operator/VERDICTS.md — this tool does NOT walk up
#             (it is a maintainer tool run from the project root, not a gate
#             CLI the model pastes; the #94/#95 walk-up lives in those).
#   --quiet   rows only, no procedure footer.
# Exit: 0 = nothing to re-verify, 1 = at least one AFFECTED or undatable row,
#       2 = usage / unreadable ledger.
#
# Not in the .operator/bin install set and not charter-referenced: it reads
# the ledger and git, changes nothing, and belongs to the maintainer, like
# ops-backlog.sh. Adding it to the manifest would drag in the charter/compressor
# couplings CLAUDE.md lists for a gate CLI, for a tool the gate never calls.
set -u

FROM="2026-08-22"
TO="2026-08-31"
LEDGER=".operator/VERDICTS.md"
QUIET=0
usage() { echo "usage: ops-reverify.sh [--from YYYY-MM-DD] [--to YYYY-MM-DD] [--ledger <path>] [--quiet]" >&2; exit 2; }
is_date() { case "$1" in [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) return 0 ;; *) return 1 ;; esac; }
while [ $# -gt 0 ]; do
  case "$1" in
    --from)   if [ $# -lt 2 ] || ! is_date "$2"; then usage; fi; FROM="$2"; shift 2 ;;
    --to)     if [ $# -lt 2 ] || ! is_date "$2"; then usage; fi; TO="$2"; shift 2 ;;
    --ledger) [ $# -ge 2 ] || usage; LEDGER="$2"; shift 2 ;;
    --quiet)  QUIET=1; shift ;;
    *) usage ;;
  esac
done
[ "$FROM" \> "$TO" ] && { echo "ops-reverify: --from $FROM is after --to $TO" >&2; exit 2; }

# The ledger is UNTRUSTED input (hand-editable; a checkout can plant anything):
# a regular non-symlink file, read in bounded chunks (the repo's reader rule —
# one newline-less multi-MB line is one "line" to an unbounded read).
if [ -L "$LEDGER" ] || [ ! -f "$LEDGER" ]; then
  echo "ops-reverify: $LEDGER is not a regular file — run from the project root (the directory holding .operator/), or pass --ledger <path>" >&2
  exit 2
fi
PROJ="$(cd -P "$(dirname "$LEDGER")/.." 2>/dev/null && pwd)" || PROJ="$PWD"

HAVE_GIT=0
if command -v git >/dev/null 2>&1 && git -C "$PROJ" rev-parse --git-dir >/dev/null 2>&1; then HAVE_GIT=1; fi

# date_of <sha> → YYYY-MM-DD or "" (unknown to this repo)
date_of() { git -C "$PROJ" show -s --format=%cs "$1^{commit}" 2>/dev/null || true; }
# next_of <sha> → the first descendant on the ancestry path to HEAD, or "" (still
# HEAD, or not an ancestor — the caller tells the two apart with is_ancestor)
next_of() { git -C "$PROJ" rev-list --reverse --ancestry-path "$1..HEAD" 2>/dev/null | head -n 1; }
is_ancestor() { git -C "$PROJ" merge-base --is-ancestor "$1" HEAD 2>/dev/null; }

AFFECTED=0; CLEAR=0; UNDATABLE=0; SKIPPED=0; n=0
# The row loop lives in a function so `local LC_ALL=C` scopes the C locale to
# the reads (the idiom scripts/lib/partition.sh uses): `read -n N` counts
# CHARACTERS outside it, so on multibyte rows the byte cap was up to 4x
# looser than it read (Copilot review on PR #105). The criterion truncation
# inside counts bytes for the same reason and may cut a multibyte character —
# display only; the row itself is never rewritten.
scan_ledger() {
  local LC_ALL=C
  printf '%s\n' "# ops-reverify — rows whose HEAD window overlaps [$FROM, $TO] — ledger: $LEDGER"
  printf '%s\n' "| # | gate | verdict | stamp | HEAD window | status | criterion |"
  printf '%s\n' "|---|---|---|---|---|---|---|"
  while IFS= read -r -n 1048576 row || [ -n "$row" ]; do
    n=$((n+1)); [ "$n" -le 200000 ] || { echo "ops-reverify: ledger exceeds 200000 lines — stopping" >&2; break; }
    case "$row" in "| "*) ;; *) continue ;; esac
    case "$row" in "| Gate | Criterion |"* | "|---"*) continue ;; esac
    # EXACTLY four cells — `| gate | criterion | evidence @stamp | verdict |` —
    # the same schema ops-verdict.sh --reconcile enforces; anything else is
    # counted as skipped, never silently dropped (a row you cannot see is a row
    # you will not re-verify).
    body="${row#| }"; body="${body% |}"
    gate="${body%% | *}";  r1="${body#* | }"
    crit="${r1%% | *}";    r2="${r1#* | }"
    ev="${r2%% | *}";      verdict="${r2#* | }"
    if [ "$r1" = "$body" ] || [ "$r2" = "$r1" ] || [ "$verdict" = "$r2" ]; then
      SKIPPED=$((SKIPPED+1)); continue
    fi
    case "$verdict" in *" | "*) SKIPPED=$((SKIPPED+1)); continue ;; esac
    stamp="${ev##* @}"
    [ "$stamp" != "$ev" ] || stamp="(none)"
    sha="${stamp%%+*}"
    status="" ; window=""
    case "$sha" in
      "(none)" | no-vcs | no-commit)
        status="UNDATABLE"; window="—" ;;
      *)
        if [ "$HAVE_GIT" = 0 ]; then
          status="UNDATABLE (no git)"; window="—"
        else
          lo="$(date_of "$sha")"
          if [ -z "$lo" ]; then
            status="UNDATABLE (sha not in this repo)"; window="—"
          else
            nxt="$(next_of "$sha")"
            if [ -n "$nxt" ]; then hi="$(date_of "$nxt")"
            elif is_ancestor "$sha"; then hi="today"
            else hi="unknown (not an ancestor of HEAD)"; fi
            window="$lo .. $hi"
            # overlap: lo <= TO and (hi unknown/today or hi >= FROM)
            if [ "$lo" \> "$TO" ]; then status="clear (after window)"
            elif is_date "$hi" && [ "$hi" \< "$FROM" ]; then status="clear (before window)"
            else status="AFFECTED"; fi
          fi
        fi ;;
    esac
    case "$status" in
      AFFECTED) AFFECTED=$((AFFECTED+1)) ;;
      UNDATABLE*) UNDATABLE=$((UNDATABLE+1)) ;;
      *) CLEAR=$((CLEAR+1)) ;;
    esac
    # criterion LAST and truncated: it is what the maintainer re-runs, but a
    # long one must not push the status off the screen.
    [ "${#crit}" -le 60 ] || crit="${crit:0:60}…"
    printf '| %s | %s | %s | %s | %s | %s | %s |\n' "$n" "$gate" "$verdict" "$stamp" "$window" "$status" "$crit"
  done < "$LEDGER"
}
scan_ledger

printf '\n%s\n' "affected: $AFFECTED · undatable: $UNDATABLE · clear: $CLEAR · skipped (not a 4-cell row): $SKIPPED"
if [ "$QUIET" = 0 ] && [ $((AFFECTED + UNDATABLE)) -gt 0 ]; then
  cat <<'FOOT'

Re-verification procedure (#103) — per AFFECTED or UNDATABLE row:
  1. Re-run the row's criterion yourself, on the tree the stamp names
     (`git checkout <sha>` in a worktree when it matters; otherwise HEAD, and
     say so). Read the FULL output — never the compressed view alone.
  2. Record the outcome as a NEW row through the single writer; never edit
     the old one (the ledger is append-only, and the old row is the record of
     what was believed at the time):
       .operator/bin/ops-verdict.sh <gate> "re-verify(#103): <criterion>" "<evidence>" <PASS|FAIL> --owner <sid>
     A verdict with no open sentinel writes a GATE-EXCEPTION beside the row —
     that is correct here: nothing was open, and the exception is the audit
     line that says this row is a retro-check.
  3. A row whose criterion cannot be re-run (the artifact is gone, the command
     no longer exists) gets a DECISION line in DECISIONS.md saying so, not a
     PASS.
  UNDATABLE rows (@no-vcs, a sha this repo does not know) cannot be placed in
  or out of the window; treat them as affected unless you know otherwise.
FOOT
fi
[ $((AFFECTED + UNDATABLE)) -eq 0 ]
