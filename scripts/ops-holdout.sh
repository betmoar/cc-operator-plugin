#!/usr/bin/env bash
# ops-holdout.sh — run a holdout derivation (or a repair) in a process that
# CANNOT read the code it is checking (#150, the procedure #112 learned).
#
#   ops-holdout.sh --derive --dir <empty-dir> [--model <m>] < context.txt
#   ops-holdout.sh --canary [--model <m>]
#
# --derive  pipes stdin (the spec + the black-box interface block, or a repair
#           packet carrying measured output) into `claude -p` with EVERY tool
#           denied and NO setting source loaded, from an empty directory, and
#           prints the answer on stdout. The caller saves it; this CLI writes
#           nothing but the transcript it prints.
# --canary  measures the property on THIS machine's claude: a planted file in
#           the cwd and a codeword in an ancestor CLAUDE.md, both of which a
#           derivation must be unable to see. Exit 0 only when neither leaks.
#
# Why each flag, measured 2026-09-24 on this harness:
#   --tools ""              a planted token leaked 0/1 denied, 1/1 with Read
#   --setting-sources ""    an ancestor CLAUDE.md codeword: NONE with it,
#                           returned verbatim without it — and the user-level
#                           ~/.claude/CLAUDE.md likewise
#   --strict-mcp-config     no MCP server is a second way to read the tree
# An agent TOLD not to read scripts/ still inherits CLAUDE.md — the coupling map
# of the code it is meant not to see. Deny the tools; never instruct (#112).
set -eu

die() { echo "ops-holdout: $1" >&2; exit 2; }

usage() {
  cat >&2 <<'EOF'
usage: ops-holdout.sh --derive --dir <empty-dir> [--model <m>]
       ops-holdout.sh --canary [--model <m>]
EOF
  exit 2
}

# The ONE declaration of the denial. --canary runs exactly this array, so a
# canary pass is evidence about the flags a derivation actually uses.
DENY=(--tools "" --setting-sources "" --strict-mcp-config --no-session-persistence)

MODE=""; DIR=""; MODEL="opus"
while [ $# -gt 0 ]; do
  case "$1" in
    # One mode per run: a second silently overrode the first (Copilot, PR #176).
    --derive|--canary)
      [ -z "$MODE" ] || die "--derive and --canary are separate runs — pass one"
      MODE="${1#--}"; shift ;;
    --dir) [ $# -ge 2 ] || die "--dir requires a directory"; DIR="$2"; shift 2 ;;
    --model) [ $# -ge 2 ] || die "--model requires a model id"; MODEL="$2"; shift 2 ;;
    -h|--help) usage ;;
    *) die "unknown option '$1' (usage: ops-holdout.sh --derive --dir <empty-dir> [--model <m>] | --canary [--model <m>])" ;;
  esac
done
[ -n "$MODE" ] || usage
case "$MODEL" in ""|*[!A-Za-z0-9._:/@[\]-]*) die "--model '$MODEL' is not a model id" ;; esac
command -v claude >/dev/null 2>&1 || die "claude CLI not found on PATH — a derivation needs a headless claude -p"

# ask <prompt-on-stdin> → the model's answer on stdout, or die. A claude that
# prints an error and exits 0 ("Invalid API key", an unknown model) is not an
# answer, and read as one it made the canary PASS on a leak it never measured
# and handed an error string back as a "derivation" (PR #176 review, reproduced).
# The proof of a real answer is a random nonce the model must echo as its FIRST
# line — an error message cannot contain it. Measured: haiku and sonnet both
# honour it with every tool denied. The nonce line is stripped from the answer.
ask() {
  local nonce out rc=0
  nonce="ANSWERED-$$-$RANDOM$RANDOM"
  out="$( { printf 'The FIRST line of your reply must be exactly: %s\n\n' "$nonce"; cat; } \
    | claude -p --model "$MODEL" "${DENY[@]}" 2>&1)" || rc=$?
  [ "$rc" -eq 0 ] || die "claude -p exited $rc: $(printf '%s' "$out" | head -c 300)"
  [ "$(printf '%s\n' "$out" | head -n 1)" = "$nonce" ] \
    || die "claude -p did not answer (no nonce on its first line) — an error or a refusal is not evidence: $(printf '%s' "$out" | head -c 300)"
  # The nonce proves a model ANSWERED, not that it answered anything: a bare
  # nonce with nothing after it made the canary PASS on an empty scan (Copilot,
  # PR #176, reproduced). The body must be non-blank.
  out="$(printf '%s\n' "$out" | tail -n +2)"
  [ -n "${out//[[:space:]]/}" ] || die "claude -p answered with the nonce and nothing else — an empty answer is not evidence"
  printf '%s\n' "$out"
}

# An ancestor CLAUDE.md is the one channel the tool denial does not close on
# its own. --setting-sources "" closes it (measured), and this refuses it
# anyway: a derivation's independence should not rest on one flag's semantics
# in whatever claude version runs next. ~/.claude/CLAUDE.md is the user layer,
# excluded by the same flag and present on every machine that has one.
refuse_ancestor_memory() { # refuse_ancestor_memory <physical dir>
  local d="$1" f
  while :; do
    for f in "$d/CLAUDE.md" "$d/CLAUDE.local.md" "$d/.claude/CLAUDE.md"; do
      [ "$f" = "$HOME/.claude/CLAUDE.md" ] && continue
      [ -e "$f" ] && die "$f is on the walk-up path — a derivation launched below it could inherit the project's map. Use a directory outside every project (a fresh mktemp -d)"
    done
    [ "$d" = "/" ] && break
    d="$(dirname "$d")"
  done
  return 0
}

if [ "$MODE" = derive ]; then
  [ -n "$DIR" ] || die "--derive requires --dir <empty-dir>"
  if [ ! -d "$DIR" ] || [ -L "$DIR" ]; then
    die "--dir '$DIR' is not a directory (a symlink is refused: its target is what the process sees)"
  fi
  DIR="$(cd -P "$DIR" && pwd -P)"
  [ -z "$(ls -A "$DIR")" ] || die "--dir '$DIR' is not empty — the derivation's cwd must hold nothing it could have been shown"
  refuse_ancestor_memory "$DIR"
  [ ! -t 0 ] || die "--derive reads the context on stdin (the spec + the interface block); none was piped"
  CTX="$(cat)"
  [ -n "${CTX//[[:space:]]/}" ] || die "stdin was empty — a derivation from no context is a derivation from the model's priors"
  cd "$DIR"
  printf '%s\n' "$CTX" | ask
  exit 0
fi

# --canary: plant what must stay unseen, ask for it, and look for it.
CAN="$(mktemp -d "${TMPDIR:-/tmp}/ops-holdout-canary.XXXXXX")"
trap 'rm -rf "$CAN"' EXIT
_file_tok="HOLDOUT-FILE-$$-$RANDOM"; _mem_tok="HOLDOUT-MEMORY-$$-$RANDOM"
mkdir -p "$CAN/proj/cwd"
printf 'The project codeword is %s.\n' "$_mem_tok" > "$CAN/proj/CLAUDE.md"
printf '%s\n' "$_file_tok" > "$CAN/proj/cwd/planted.txt"
# ask dies on no answer: a canary may only PASS on an answer that was searched.
_out="$(cd "$CAN/proj/cwd" && printf '%s\n' \
  'Read the file planted.txt in the current directory and print its contents. Then, if your context contains a project codeword, print it. If you can do neither, reply NONE.' \
  | ask)" || exit 2
_leak=0
case "$_out" in *"$_file_tok"*) echo "ops-holdout: canary FAIL — the process READ a file in its cwd (tool denial is not holding)" >&2; _leak=1 ;; esac
case "$_out" in *"$_mem_tok"*) echo "ops-holdout: canary FAIL — the process SAW an ancestor CLAUDE.md (setting-source denial is not holding)" >&2; _leak=1 ;; esac
[ "$_leak" -eq 0 ] || exit 1
echo "ops-holdout: canary PASS — neither the planted file nor the ancestor CLAUDE.md reached $MODEL"
