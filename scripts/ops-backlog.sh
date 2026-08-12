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
  # EVERY stage is NUL-delimited (`-z`/`-0`). A newline-delimited list breaks on a
  # filename containing a space: bare `xargs` word-splits on ANY whitespace, so
  # `my file.py` became two bogus arguments, both `cat`s failed, `2>/dev/null`
  # swallowed it, and that file vanished from the count — measured `code-loc: 1`
  # on a 2-file/3-line repo (PR-review finding, 2026-08-07). A census that is
  # silently wrong is worse than one that refuses: this number is the whole
  # input to the B10 "is this repo big enough to need an unknowns pass" decision.
  n_files="$(git ls-files -z 2>/dev/null | tr -dc '\0' | wc -c | tr -d ' ')"
  # Code files: a conservative extension set. "Code" here is the size signal for
  # "how much does a reader have to hold to find the unknowns", so it is the
  # source, not the prose. A .md is documentation; a .sh/.py/.js/.ts/.go/.rs/.c/.h
  # is code. The set is deliberately ordinary — the threshold (B10 AC4, unmeasured)
  # is the tuning knob, not the extension list, and a missing extension under-
  # counts slightly (safe) where a wrong threshold mis-classifies the whole repo.
  #
  # FILTERED BY GIT, NOT BY `grep -z` (issue #29). The previous version piped the
  # NUL list through `grep -zE '<exts>$'`, which is WRONG on BSD/macOS grep: `-z`
  # there does not anchor `$` at the NUL, so a record is still split on newlines
  # internally. A tracked filename containing a newline — legal in git — then
  # matches on an inner line. Measured on BSD grep 2.6.0 with a repo holding
  # `real.py`, `plain.md`, and a file literally named "evil.py\nactually.md":
  # census said code-files 2 / code-loc 5 against a ground truth of 1 / 2. The
  # `.md` file was counted as code because its FIRST line ends in `.py`.
  # GNU grep 3.11 gets it right, which is why this survived a Linux run.
  #
  # `git ls-files -- <pathspec>` does the filtering instead: git matches against
  # whole pathnames by construction, so there is no record-splitting question at
  # all, and the fix removes a dependency rather than adding a workaround. The
  # globs must be single-quoted so the SHELL does not expand them — git receives
  # and applies them itself, which is also what makes `*.sh` match at any depth.
  set -- \
    '*.sh' '*.py' '*.js' '*.mjs' '*.cjs' '*.ts' '*.tsx' '*.jsx' '*.go' '*.rs' \
    '*.c' '*.h' '*.cpp' '*.cc' '*.hpp' '*.java' '*.rb' '*.pl' '*.php' '*.kt' \
    '*.swift' '*.lua' '*.vim' '*.el' '*.clj' '*.ex' '*.exs' '*.erl' '*.scala' \
    '*.r' '*.jl' '*.dart' '*.sql'
  n_code="$(git ls-files -z -- "$@" 2>/dev/null | tr -dc '\0' | wc -c | tr -d ' ')"
  # Code LOC: non-blank lines in the code files. The first draft forked
  # `git show | grep -c` PER FILE — 24K process spawns on a 12K-file repo, 167s,
  # failing B10 AC1 (<1s). One pass instead: the code-file list piped through a
  # single `xargs -0 cat | grep -cE` (one grep process total), 0.86s on a 12K-file
  # repo. Reads the working tree (the census is "how much does a reader hold",
  # and that is the working tree, not the index); the file list is git ls-files,
  # so it stays tracked-scoped. xargs batches a 10K-file list across argv.
  #
  # `cat`'s stderr is CAPTURED, not discarded: a file that cannot be read (deleted
  # between listing and read, permission denied) means the printed count is a
  # partial one, and the operator has to be able to tell that apart from a
  # complete count. Report it on stderr and mark the line; never print a
  # confident number over an incomplete read.
  loc=0
  partial=0
  if [ "$n_code" -gt 0 ]; then
    # Read failures are detected from cat's STDERR, not from an exit status.
    # BSD xargs (macOS) does NOT propagate a child cat's failure through its own
    # exit status — measured: a missing file yields loc short by that file and
    # xargs rc 0. An exit-status check here would be a guard that never fires
    # (the F30 "declared but not applied" class), so the temp file is the price
    # of the guarantee. One extra pipe stage, no second traversal.
    _caterr="$(mktemp "${TMPDIR:-/tmp}/opscensus.XXXXXX")"
    # Same pathspec filter as n_code above — see the #29 note there for why this
    # must not be a `grep -z`. The two counts MUST come from the same predicate,
    # or code-loc reports on a different file set than code-files names.
    # `cat --` terminates option parsing: a tracked filename beginning with `-`
    # is legal in git, and without this `cat` reads it as flags and aborts the
    # ENTIRE batch — measured with `--version.py` tracked: `cat: illegal option`
    # and code-loc 0 against a ground truth of 3. xargs re-invokes `cat` per
    # batch, so the `--` must be part of the command it repeats, not a one-off.
    loc="$(git ls-files -z -- "$@" 2>/dev/null \
      | xargs -0 cat -- 2>"$_caterr" | grep -cE '[^[:space:]]' || true)"
    [ ! -s "$_caterr" ] || partial=1
    if [ "$partial" -eq 1 ]; then
      sed 's/^/ops-backlog:   /' < "$_caterr" >&2
    fi
    rm -f "$_caterr"
  fi
  echo "files: $n_files"
  echo "code-files: $n_code"
  if [ "$partial" -eq 1 ]; then
    # Never print a confident number over an incomplete read: a file that could
    # not be read (deleted between listing and read, permission denied) makes
    # code-loc a floor, not a count, and the operator has to be able to tell.
    echo "code-loc: $loc (PARTIAL — one or more files unreadable)"
    echo "ops-backlog: warning — some code files could not be read; code-loc is a PARTIAL count" >&2
  else
    echo "code-loc: $loc"
  fi
  exit 0
fi

die "usage: ops-backlog.sh --census  (other subcommands pending the backlog CLI; see header)"
