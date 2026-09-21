#!/usr/bin/env bash
# ops-spec.sh — the spec stage's artifact (#155).
#
# The cycle went brainstorm -> ??? -> plan: the only thing carrying a design
# from divergence into planning was prose the operator retyped, with no file,
# no provenance, no source stamp and no ledger row, so a compaction lost it and
# nothing noticed. This CLI is that missing artifact, and nothing more.
#
#   ops-spec.sh --new <slug>          scaffold .operator/specs/<slug>.md
#   ops-spec.sh --check <slug>        validate the skeleton; write nothing
#   ops-spec.sh --approve <slug> --owner <sid>
#                                     stamp APPROVED @<source-state>, log
#                                     SPEC-APPROVED, emit the BAR block
#
# APPROVE IS THE ONLY WRITER to a spec's Status line, for ops-verdict.sh's
# reason: one writer, one place to get the ordering right.
set -eu

OPDIR=".operator"

die() { echo "ops-spec: $1" >&2; exit 2; }

# >>> PROJECT ROOT BLOCK — byte-identical in ops-task.sh, ops-verdict.sh and
# ops-adopt.sh (check_root_parity + the bash suite compare the markers' span).
#
# WALK UP to the nearest ancestor holding .operator/, then cd there — the way
# git finds its own root, and the way ops-stop-hook.sh has always resolved the
# project. Without this every path below is relative to the caller's cwd, so
# the CLI worked from the project root and NOWHERE else.
#
# That is not hypothetical: the Stop hook's #94 fix made it prescribe an
# ABSOLUTE path to this CLI, which resolves fine from a subdirectory — and the
# command still failed there with "missing .operator/DECISIONS.md — run
# ops-init.sh first", because the path said where the CLI lives, never which
# project it serves. Measured on 0.11.2 from `apps/viewer/`. The Bash tool's
# cwd persists across calls, so a session is routinely somewhere else.
#
# `cd`, not an absolute OPDIR: every other relative path comes right for free —
# the sentinel glob, the fragment dir, the lock, and `git status --porcelain --
# ':(exclude).operator'` in the source stamp, whose pathspec is repo-relative
# and would silently stop excluding the ledger from a subdirectory.
#
# Bounded exactly like the hook's copy: stop at a .git boundary (a nested repo
# is its own project) and at the filesystem root. `cd -P` resolves symlinks, so
# the walk cannot be redirected by a planted link.
_ops_cd_project_root() {
  _walk="$(pwd -P 2>/dev/null)" || _walk=""
  while [ -n "$_walk" ]; do
    if [ -d "$_walk/.operator" ]; then
      # Refuse rather than operate on a project we cannot enter: a silent
      # failure here would leave every path below resolving against the
      # caller's cwd, which is the defect this block exists to remove.
      cd "$_walk" 2>/dev/null || die "found $_walk/.operator but could not cd there"
      return 0
    fi
    [ -e "$_walk/.git" ] && break
    [ "$_walk" = "/" ] && break
    _walk="${_walk%/*}"; [ -n "$_walk" ] || _walk="/"
  done
  return 1
}
# A miss is NOT fatal here: the per-command guards below already die with the
# message that names ops-init.sh, and they stay the single place that decides.
_ops_cd_project_root || :
# <<< PROJECT ROOT BLOCK
NL="$(printf '\nx')"; NL="${NL%x}"

# The slug becomes a FILENAME, so it takes the same reject set the sentinel
# names take. Kept in step with ops-task.sh/ops-verdict.sh/ops-adopt.sh's
# check_bare_name by check_guard_parity: a name those writers refuse is a name
# no reader of ours can address, and a spec nobody can address is worse than
# no spec, because `--check` reports on the one it did find.
check_bare_name() { # check_bare_name <label> <value>
  case "$2" in
    */*) die "$1 must be a bare name (no '/')" ;;
    .*) die "$1 must not start with '.' — a dotfile spec is invisible to the specs/ glob" ;;
    *"|"* | *"$NL"*) die "$1 must not contain '|' or newlines" ;;
    *$'\r'*) die "$1 must not contain a carriage return — the ledger row it produces is a 4-cell line and a CR breaks the cell it lands in" ;;
    *__*) die "$1 must not contain '__' (it separates owner from task in the sentinel name, and a spec slug becomes a task id)" ;;
  esac
}

check_owner_name() { # check_owner_name <value>
  check_bare_name "owner" "$1"
  case "$1" in
    *[[:space:]]*) die "owner must not contain whitespace — it could never match a real session id" ;;
    *'$'* | *'`'* | *"'"* | *'"'* | *\\*) die "owner must not contain shell metacharacters" ;;
  esac
}

source_stamp() {
  local sha porc rc
  command -v git >/dev/null 2>&1 || { printf 'no-vcs'; return 0; }
  git rev-parse --git-dir >/dev/null 2>&1 || { printf 'no-vcs'; return 0; }
  sha="$(git rev-parse --verify --short=12 HEAD 2>/dev/null || true)"
  [ -n "$sha" ] || { printf 'no-commit'; return 0; }
  # The sha becomes ledger content; non-hex means git answered something we do
  # not understand — degrade, never embed an untrusted string.
  case "$sha" in
    *[!0-9a-f]*) printf 'no-vcs'; return 0 ;;
  esac
  # .operator/ excluded: counting the gate's own bookkeeping pins every row
  # to +dirty (#21). Two-line local: `local x=$(…)` returns local's status.
  porc="$(git status --porcelain -- ':(exclude).operator' 2>/dev/null)" && rc=0 || rc=$?
  # An infra failure must not read as CLEAN (the strong claim).
  [ "$rc" -eq 0 ] || { printf '%s+unknown' "$sha"; return 0; }
  [ -z "$porc" ] || { printf '%s+dirty' "$sha"; return 0; }
  printf '%s' "$sha"
}

SPECDIR="$OPDIR/specs"
DECISIONS="$OPDIR/DECISIONS.md"
VERDICTS="$OPDIR/VERDICTS.md"

# The skeleton's section order, ONE declaration, read by both --new and
# --check. Two copies would drift into a scaffold its own checker refuses.
SPEC_SECTIONS="North star|Done criteria|In scope|Out of scope|Open questions|Constraints"

spec_path() { printf '%s/%s.md' "$SPECDIR" "$1"; }

# BOUNDED like every other reader here: a spec is a project file, and an
# unbounded read of one is the class this repo bounds everywhere else.
SPEC_MAX_BYTES=262144
spec_read_guard() { # spec_read_guard <path>
  [ -f "$1" ] || die "no spec at $1 — run: ops-spec.sh --new ${1##*/}"
  [ ! -L "$1" ] || die "$1 is a symlink — refusing to read a spec through one"
  _sz="$(wc -c < "$1" 2>/dev/null || echo 999999999)"
  [ "$_sz" -le "$SPEC_MAX_BYTES" ] || die "$1 is larger than $SPEC_MAX_BYTES bytes — that is not a spec, and reading it unbounded is how a reader becomes a denial of service"
}

usage() {
  cat >&2 <<'USAGE'
usage: ops-spec.sh --new <slug>
       ops-spec.sh --check <slug>
       ops-spec.sh --approve <slug> --owner <session-id>
USAGE
  exit 2
}

MODE=""; SLUG=""; OWNER=""
while [ $# -gt 0 ]; do
  case "$1" in
    --new|--check|--approve)
      [ -z "$MODE" ] || die "pick one of --new / --check / --approve"
      MODE="${1#--}"; shift
      [ $# -ge 1 ] || die "$MODE requires a slug"
      SLUG="$1"; shift ;;
    --owner) shift; [ $# -ge 1 ] || die "--owner requires a session id"; OWNER="$1"; shift ;;
    -h|--help) usage ;;
    *) die "unknown argument '$1'" ;;
  esac
done
[ -n "$MODE" ] || usage
check_bare_name "slug" "$SLUG"
[ -d "$OPDIR" ] || die "missing $OPDIR — run ops-init.sh first"

SPEC="$(spec_path "$SLUG")"

# The approve-only guards run BEFORE the checker, so a refusal that has nothing
# to do with the spec's content does not first print a verdict on its content.
# Reading "passes --check" and then "--owner is required" reads as two results
# where there is one refusal.
if [ "$MODE" = "approve" ]; then
  [ -n "$OWNER" ] || die "--approve requires --owner <session-id> (SessionStart printed yours)"
  check_owner_name "$OWNER"
  if [ -f "$SPEC" ] && grep -q '^Status: APPROVED' "$SPEC"; then
    die "$SPEC is already APPROVED — a second approval would append a second BAR block for the same spec"
  fi
fi

case "$MODE" in
new)
  mkdir -p "$SPECDIR" 2>/dev/null || die "could not create $SPECDIR"
  # O_EXCL, ops-task.sh's discipline: a test-then-write is a TOCTOU, and `>`
  # over an existing spec would destroy work the operator is mid-way through.
  if ! (set -C; : > "$SPEC") 2>/dev/null; then
    [ -f "$SPEC" ] && die "$SPEC already exists — edit it, or pick another slug"
    die "could not create $SPEC"
  fi
  cat > "$SPEC" <<SKEL
# SPEC — $SLUG

Slug: $SLUG
Status: DRAFT
Provenance: <what produced this — a brainstorm run, an interview, direct authorship>

## North star

<one sentence naming what must be true when this is done>
Missed if: <the falsifying condition>

## Done criteria

| # | Criterion | Command | Expected output |
|---|---|---|---|
| 1 | <what must hold> | <the command that shows it> | <what it prints> |

## In scope

## Out of scope

## Open questions

| Question | Resolution | Decided by |
|---|---|---|

## Constraints

SKEL
  echo "created $SPEC (DRAFT)"
  echo "next: fill it in, then ops-spec.sh --check $SLUG"
  ;;

check|approve)
  spec_read_guard "$SPEC"
  _problems=0
  _say() { echo "ops-spec: $1" >&2; _problems=$((_problems + 1)); }

  _IFS_SAVE="$IFS"; IFS='|'
  for _sec in $SPEC_SECTIONS; do
    grep -qxF "## $_sec" "$SPEC" || _say "missing section '## $_sec'"
  done
  IFS="$_IFS_SAVE"

  # The north star is the sentence BOTH the BAR block and plan.js read, and
  # the `Missed if:` clause is what plan.js refuses without. Checking it here
  # is the whole point of having one file: the two consumers stop disagreeing.
  grep -qi '^Missed if:' "$SPEC" || _say "the north star has no 'Missed if:' clause — the plan workflow reads it without a fallback and refuses without it"

  # A done criterion with no command is one nobody outside this session can
  # reproduce (#25, arriving one stage earlier). The skeleton's placeholder row
  # does not count: a spec approved with the template still in it has no
  # criteria at all.
  _rows="$(awk '/^## Done criteria/{f=1;next} /^## /{f=0} f&&/^\| *[0-9]/{print}' "$SPEC" 2>/dev/null | grep -vc '<the command that shows it>' || true)"
  [ "${_rows:-0}" -ge 1 ] || _say "no done criterion carries a real command — the skeleton's placeholder row is not a criterion"

  # An unanswered question is the interview skipped. The bundle orders them by
  # blast radius precisely so the first one is the one that reshapes the design.
  _open="$(awk '/^## Open questions/{f=1;next} /^## /{f=0} f&&/^\|/{print}' "$SPEC" 2>/dev/null \
           | grep -v '^| *Question' | grep -v '^|---' | grep -c '| *|' || true)"
  [ "${_open:-0}" -eq 0 ] || _say "$_open open question(s) have an empty Resolution cell — approving with one unanswered is the interview skipped"

  if [ "$_problems" -gt 0 ]; then
    echo "ops-spec: $SPEC is NOT ready ($_problems problem(s) above)" >&2
    exit 1
  fi
  echo "ops-spec: $SPEC passes --check"
  [ "$MODE" = "approve" ] || exit 0
  ;;
esac

[ "$MODE" = "approve" ] || exit 0

# --- approve ---------------------------------------------------------------
# (--owner and the already-approved refusal ran before the checker, above.)
STAMP="$(source_stamp)"
TODAY="$(date +%F)"

# ORDER, and it is ops-verdict.sh's (#14) applied here: the DECISIONS line
# BEFORE the ledger's BAR block, and the spec's own Status LAST. A crash
# between them leaves a record that the approval was attempted with the spec
# still DRAFT — which re-runs cleanly. The reverse order leaves an APPROVED
# spec no ledger knows about, and nothing would ever retry it.
printf '%s | %s | SPEC-APPROVED | spec %s approved @%s | the plan gate reads this file; see %s\n' \
  "$TODAY" "$SLUG" "$SLUG" "$STAMP" "$SPEC" >> "$DECISIONS" \
  || die "could not append to $DECISIONS"

{
  printf '\n## BAR — %s (spec %s @%s)\n\n' "$SLUG" "$SLUG" "$STAMP"
  printf 'North star: '
  awk '/^## North star/{f=1;next} /^## /{f=0} f&&NF{print; exit}' "$SPEC"
  awk '/^## North star/{f=1;next} /^## /{f=0} f&&/^[Mm]issed if:/{print; exit}' "$SPEC"
  printf '\nDone criteria (from %s):\n\n' "$SPEC"
  awk '/^## Done criteria/{f=1;next} /^## /{f=0} f&&/^\|/{print}' "$SPEC"
  printf '\nCaps: the charter table (identical-rejection x2, same-target-rework x2, neighbor-regressing x2).\n'
} >> "$VERDICTS" || die "could not append the BAR block to $VERDICTS"

# The Status line last, and rewritten through a temp + same-dir mv for the
# .gitignore writers' reason: an in-place edit that dies leaves a spec that is
# neither DRAFT nor APPROVED.
_tmp="$SPEC.tmp.$$"
if sed "s|^Status: DRAFT\$|Status: APPROVED @$STAMP|" "$SPEC" > "$_tmp" 2>/dev/null \
   && grep -q '^Status: APPROVED' "$_tmp" \
   && mv -f "$_tmp" "$SPEC" 2>/dev/null; then
  :
else
  rm -f "$_tmp" 2>/dev/null
  die "could not stamp Status: APPROVED on $SPEC — the DECISIONS line and the BAR block ARE written, so re-run --approve after fixing the file (it is idempotent only once the Status line lands)"
fi

echo "approved $SPEC @$STAMP"
echo "  logged SPEC-APPROVED to $DECISIONS"
echo "  appended the BAR block to $VERDICTS"
echo "next: /cc-operator:plan $SLUG"
