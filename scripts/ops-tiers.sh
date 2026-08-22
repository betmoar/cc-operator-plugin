#!/usr/bin/env bash
# ops-tiers.sh — resolve the tier→model map and emit it as JSON for a workflow.
#
# A workflow script is sandboxed (no fs/env/net); its only input is `args`.
# The operator runs this and hands the JSON to Workflow({args:{tiers:...}}).
#
# Layering, later wins:
#   1. baked defaults below
#   2. ~/.claude/cc-operator/tiers.env      (user)
#   3. ./.operator/tiers.env                (project)
#   4. --set NAME=id                        (one-off, this invocation)
#
# A tiers.env line is `NAME=model-id`; `#` comments and blank lines ignored.
# Parsed, never sourced — a config file is data, not code.
#
# Usage:
#   ops-tiers.sh                      → JSON to stdout
#   ops-tiers.sh --set MECHANICAL=glm-4.7
#   ops-tiers.sh --check              → also verify against the proxy catalogue
#   ops-tiers.sh --show               → human-readable table + provenance
# Tier values and their SRC_* provenance twins are set and read through `eval`
# (bash 3.2 on macOS has no associative arrays), so shellcheck cannot see either
# side of the use. File-scoped because the pattern recurs throughout.
# shellcheck disable=SC2034,SC2154
set -eu

PORT="${CC_PROXY_PORT:-4000}"
USER_FILE="${CC_OPERATOR_TIERS_USER:-$HOME/.claude/cc-operator/tiers.env}"
PROJ_FILE="${CC_OPERATOR_TIERS_PROJECT:-.operator/tiers.env}"

# Baked defaults — a starting point, not a catalogue claim (see check_routable).
TIER_NAMES="JUDGMENT IMPLEMENT MECHANICAL RECON"
JUDGMENT="claude-opus-5"
IMPLEMENT="claude-sonnet-5"
MECHANICAL="glm-5-turbo"
RECON="claude-haiku-4-5-20251001"

# provenance, parallel to TIER_NAMES
SRC_JUDGMENT="default"; SRC_IMPLEMENT="default"
SRC_MECHANICAL="default"; SRC_RECON="default"

die() { echo "ops-tiers: $*" >&2; exit 2; }

is_tier_name() {
  case " $TIER_NAMES " in *" $1 "*) return 0 ;; *) return 1 ;; esac
}

# The model-id guard: well-formedness ONLY, by design (0.8.3). The user picks
# the model, cc-proxy routes it, operator decides neither — an id-shape
# catalogue here rots and refuses ids the proxy routes fine. What survives
# cannot rot: whitespace or a quote means the LINE is malformed (F01).
check_routable() {
  case "$2" in
    "") die "$1 is empty" ;;
    *[!A-Za-z0-9._:/@[\]-]*)
      die "$1='$2' contains characters outside [A-Za-z0-9._:/@[]-] (whitespace and quotes are never valid in a model id)" ;;
  esac
  return 0
}

set_tier() { # set_tier NAME id source
  is_tier_name "$1" || die "unknown tier '$1' (known: $TIER_NAMES)"
  eval "$1=\$2"; eval "SRC_$1=\$3"
}

# Parse a NAME=value file without sourcing it — a config file is untrusted
# input, so the read is bounded (512-byte lines, 200-line cap).
load_file() { # load_file <path> <source-label>
  [ -f "$1" ] || return 0
  # NUL probe, BEFORE the parse loop: bash drops NULs from variables, so no
  # test on $line can see one — `read -d ''` returning 0 is the one builtin
  # way (F46: a NUL-split chunk otherwise smuggles a live assignment past the
  # length guard on bash 3.2). Bounded at 200 chunks = the parse loop's own
  # legal max; unbounded, a newline-less 64MB file stalls ~66s (F64). The
  # whole probe runs LC_ALL=C so -n and ${#} both count BYTES — in a multibyte
  # locale a full chunk measures <512 chars and false-positives.
  if ! (LC_ALL=C _np=0
        while IFS= read -r -d '' -n 512 _nulprobe; do
          _np=$((_np + 1)); [ "$_np" -le 200 ] || exit 1
          [ "${#_nulprobe}" -eq 512 ] || exit 1
        done < "$1") 2>/dev/null; then
    die "$1: contains a NUL byte or exceeds 100KB — refusing (tiers.env is text, not a binary blob)"
  fi
  # LC_ALL=C on the loop too: `read -n` caps BYTES, `${#line}` counts CHARS in
  # the parent locale — a multibyte comment otherwise defeats the cap-fill
  # guard below (same F42/F46 class). All legitimate content is ASCII.
  local lc=0 LC_ALL=C
  while IFS= read -r -n 512 line || [ -n "$line" ]; do
    lc=$((lc + 1)); [ "$lc" -le 200 ] || die "$1: more than 200 lines — refusing"
    # A cap-FILLING chunk was truncated mid-line and its remainder would parse
    # as a fresh line next iteration — die, don't parse a fragment. A real
    # tier line is well under 80 chars; ops-render.sh carries the same guard.
    [ "${#line}" -lt 512 ] || die "$1: line $lc exceeds 512 chars — refusing (a tier line is well under 80)"
    case "$line" in ''|'#'*) continue ;; esac
    name="${line%%=*}"; val="${line#*=}"
    [ "$name" != "$line" ] || die "$1: malformed line (want NAME=model-id): $line"
    # Trim only leading/trailing whitespace; embedded whitespace is rejected
    # below, never coerced — silent coercion is a silent mis-route.
    name="${name#"${name%%[![:space:]]*}"}"   # strip leading
    name="${name%"${name##*[![:space:]]}"}"   # strip trailing
    val="${val#"${val%%[![:space:]]*}"}"      # a model id never carries
    val="${val%"${val##*[![:space:]]}"}"      # surrounding whitespace
    case "$name" in
      *[[:space:]]*) die "$1: whitespace inside tier name '$name' (known: $TIER_NAMES)" ;;
    esac
    # tiers.env carries TWO line kinds: TIER=model-id (ours) and
    # [op-]seat=TIER (the renderer's — skip, but validate the VALUE so a
    # typo'd tier name dies here instead of resolving to defaults; F15).
    if ! is_tier_name "$name"; then
      is_tier_name "$val" || die "$1: unknown tier '$name' (known: $TIER_NAMES; a seat line needs a tier VALUE, e.g. op-scout=MECHANICAL)"
      continue   # a valid seat binding — the renderer's business, not ours
    fi
    check_routable "$name" "$val"
    set_tier "$name" "$val" "$2"
  done < "$1"
}

MODE=json
load_file "$USER_FILE" "user"
load_file "$PROJ_FILE" "project"

while [ $# -gt 0 ]; do
  case "$1" in
    --set)
      [ $# -ge 2 ] || die "--set requires NAME=model-id"
      n="${2%%=*}"; v="${2#*=}"
      [ "$n" != "$2" ] || die "--set wants NAME=model-id, got '$2'"
      check_routable "$n" "$v"; set_tier "$n" "$v" "--set"; shift 2 ;;
    --check) MODE=check; shift ;;
    --show)  MODE=show;  shift ;;
    --json)  MODE=json;  shift ;;
    *) die "unknown argument '$1'" ;;
  esac
done

# Proxy catalogue cross-check — ADVISORY, never a gate: /v1/models covers only
# API-backed providers (claude-* is harness-served and absent by construction),
# an unlisted id may still route, and upstream may alias ids. Report and emit.
catalogue_note() {
  body="$(curl -sS -m 5 "http://127.0.0.1:${PORT}/v1/models" 2>/dev/null || true)"
  if [ -z "$body" ]; then
    echo "note: proxy at :$PORT did not answer /v1/models — membership unchecked" >&2
    return 0
  fi
  case "$body" in
    *'"data"'*'['*) : ;;
    *) echo "note: unexpected /v1/models body (no data[]) — membership unchecked" >&2; return 0 ;;
  esac
  listed="$(printf '%s' "$body" \
    | grep -oE '"id"[[:space:]]*:[[:space:]]*"[^"]+"' \
    | sed -E 's/.*"([^"]+)"$/\1/')"
  for n in $TIER_NAMES; do
    eval "id=\$$n"
    # claude-* is harness-served, not API-served: out of this catalogue's scope.
    case "$id" in claude-*) continue ;; esac
    base="${id%%[[]*}"   # strip a [1m]-style context-variant marker
    if ! printf '%s\n' "$listed" | grep -qxF -- "$base"; then
      echo "note: $n='$id' is not advertised by /v1/models — routable by shape, unverified by catalogue" >&2
    fi
  done
}

[ "$MODE" = check ] && catalogue_note

case "$MODE" in
  show)
    printf '%-11s %-30s %s\n' TIER MODEL SOURCE
    for n in $TIER_NAMES; do
      eval "id=\$$n"; eval "src=\$SRC_$n"
      printf '%-11s %-30s %s\n' "$n" "$id" "$src"
    done
    echo
    echo "user:    $USER_FILE"
    echo "project: $PROJ_FILE"
    catalogue_note
    ;;
  *)
    # JSON for Workflow({args:{tiers:...}}). Ids are charset-guarded above, so
    # no value here can contain a quote or backslash needing escape.
    out='{'
    sep=''
    for n in $TIER_NAMES; do
      eval "id=\$$n"
      out="$out$sep\"$n\":\"$id\""
      sep=','
    done
    printf '%s}\n' "$out"
    ;;
esac
