#!/usr/bin/env bash
# ops-backlog.sh — the backlog-as-charter CLI surface (B-items).
#
# This is the PLANNING/REPORTING CLI, not a gate CLI. It does not write ledgers,
# does not read sentinels, and is not part of the Stop evidence gate. It joins
# .operator/bin/ so its subcommands resolve in any project, but it is NOT in
# CHARTER_REQUIRED_CLIS, GATE_CLIS, or the charter's EVIDENCE GATE prose — the
# same "reporting tool, not gate tool" distinction ops-render.sh draws.
#
# Implemented subcommands (CLI-independent cherry-picks of the backlog-charter
# spec; the neighbour `backlog` CLI is not required for these):
#
#   --census   B10.1. Print tracked-file count, code-file count, and code LOC.
#              The size signal that decides (B10) whether a repo is large enough
#              that naming the unknowns is task #1. Cheap by requirement: exit 0
#              in under 1s on a repo of ≥10K files (git ls-files is ~10ms here).
#
# Subcommands NOT yet implemented (blocked on the neighbour `backlog` CLI, which
# is not installed and has no backlog/ dir — a plan-level issue for the human):
#   --audit            B9  phantom-done (checked AC vs VERDICTS rows) — needs AC state
#   --audit --register B11 register-vs-ledger drift — CLI-free core, but its
#                      "open vs closed section" convention is an unpinned design
#                      decision, deferred to its own BAR rather than buried here.
#
# Usage: run from the project root (cwd):
#   ops-backlog.sh --census
set -eu

die() { echo "ops-backlog: $1" >&2; exit 2; }

if [ "${1:-}" = "--census" ]; then
  git rev-parse --git-dir >/dev/null 2>&1 || die "--census requires a git repository (git ls-files)"
  # Tracked files only — untracked noise would make the size signal lie about the
  # repo's real weight. git ls-files is the census the spec names (~10ms here,
  # B10 AC1); wc -l counts them without holding the list in a shell variable
  # (a 10K-file repo would otherwise hit ARG_MAX in a for-loop).
  n_files="$(git ls-files 2>/dev/null | grep -c '' || true)"
  # Code files: a conservative extension set. "Code" here is the size signal for
  # "how much does a reader have to hold to find the unknowns", so it is the
  # source, not the prose. A .md is documentation; a .sh/.py/.js/.ts/.go/.rs/.c/.h
  # is code. The set is deliberately ordinary — the threshold (B10 AC4, unmeasured)
  # is the tuning knob, not the extension list, and a missing extension under-
  # counts slightly (safe) where a wrong threshold mis-classifies the whole repo.
  n_code="$(git ls-files 2>/dev/null \
    | grep -E '\.(sh|py|js|mjs|cjs|ts|tsx|jsx|go|rs|c|h|cpp|cc|hpp|java|rb|pl|php|kt|swift|lua|vim|el|clj|ex|exs|erl|scala|r|jl|dart|sql)$' \
    | grep -c '' || true)"
  # Code LOC: non-blank lines in the code files. The earlier draft forked
  # `git show | grep -c` PER FILE — 24K process spawns on a 12K-file repo, 167s,
  # failing B10 AC1 (<1s). One pass instead: the code-file list piped through a
  # single `xargs cat | grep -cE` (one grep process total). Measured 0.86s on a
  # 12K-file repo — under the 1s bound. Reads the working tree (the census is
  # "how much does a reader hold", and that is the working tree, not the index);
  # the file list is git ls-files, so it stays tracked-scoped. xargs handles a
  # 10K-file list across argv batches; `grep -c` over the stream sums them.
  if [ "$n_code" -gt 0 ]; then
    loc="$(git ls-files 2>/dev/null \
      | grep -E '\.(sh|py|js|mjs|cjs|ts|tsx|jsx|go|rs|c|h|cpp|cc|hpp|java|rb|pl|php|kt|swift|lua|vim|el|clj|ex|exs|erl|scala|r|jl|dart|sql)$' \
      | xargs cat 2>/dev/null | grep -cE '[^[:space:]]' || true)"
  else
    loc=0
  fi
  echo "files: $n_files"
  echo "code-files: $n_code"
  echo "code-loc: $loc"
  exit 0
fi

die "usage: ops-backlog.sh --census  (other subcommands pending the backlog CLI; see header)"
