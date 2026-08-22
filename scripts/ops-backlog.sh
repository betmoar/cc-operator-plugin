#!/usr/bin/env bash
# ops-backlog.sh — planning/reporting CLI (backlog-charter B-items), NOT a gate CLI.
# One subcommand: --census prints tracked-file count, code-file count, code LOC.
# Unimplemented B-items (--audit, --register) live in the backlog-charter spec.
# pipefail: a failing git ls-files must not be masked by wc as a confident 0.
set -euo pipefail

die() { echo "ops-backlog: $1" >&2; exit 2; }

if [ "${1:-}" = "--census" ]; then
  git rev-parse --git-dir >/dev/null 2>&1 || die "--census requires a git repository (git ls-files)"
  # NUL-delimited throughout: whitespace/newline filenames must not skew counts.
  n_files="$(git ls-files -z 2>/dev/null | tr -dc '\0' | wc -c | tr -d ' ')"
  # Filtered by git pathspec, not grep -z (BSD grep splits NUL records on inner
  # newlines — #29). Quoted so git, not the shell, expands the globs.
  set -- \
    '*.sh' '*.py' '*.js' '*.mjs' '*.cjs' '*.ts' '*.tsx' '*.jsx' '*.go' '*.rs' \
    '*.c' '*.h' '*.cpp' '*.cc' '*.hpp' '*.java' '*.rb' '*.pl' '*.php' '*.kt' \
    '*.swift' '*.lua' '*.vim' '*.el' '*.clj' '*.ex' '*.exs' '*.erl' '*.scala' \
    '*.r' '*.jl' '*.dart' '*.sql'
  n_code="$(git ls-files -z -- "$@" 2>/dev/null | tr -dc '\0' | wc -c | tr -d ' ')"
  loc=0
  partial=0
  if [ "$n_code" -gt 0 ]; then
    # Read failures are detected from cat's stderr — BSD xargs does not
    # propagate a child's exit status, so a status check would never fire.
    _caterr="$(mktemp "${TMPDIR:-/tmp}/opscensus.XXXXXX")"
    # `cat --`: a tracked filename starting with `-` must not abort the batch.
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
    # An unreadable file makes code-loc a floor, not a count — say so.
    echo "code-loc: $loc (PARTIAL — one or more files unreadable)"
    echo "ops-backlog: warning — some code files could not be read; code-loc is a PARTIAL count" >&2
  else
    echo "code-loc: $loc"
  fi
  exit 0
fi

die "usage: ops-backlog.sh --census  (other subcommands pending the backlog CLI; see header)"
