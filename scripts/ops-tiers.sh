#!/usr/bin/env bash
# ops-tiers.sh — resolve the tier→model map and emit it as JSON for a workflow.
#
# WHY THIS EXISTS: a dynamic-workflow script is sandboxed — `process`, `require`,
# `fetch` and `fs` are all undefined (measured 2026-07-29), so a workflow cannot
# read a config file, an env var, or the proxy itself. Its ONLY input channel is
# the `args` value passed at invocation. This script is what fills that channel:
# the operator runs it, and hands the JSON to Workflow({args:{tiers:...}}).
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

# Baked defaults. These are the only ids the plugin ships; every one is
# cc-proxy-routable by shape. See the ADVERTISED-vs-ROUTABLE note below for why
# they are not required to appear in /v1/models.
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

# The routability guard. cc-proxy dispatches purely on id SHAPE: `glm-*` → Z.ai,
# `vendor/model` → OpenRouter, `claude-*` → Anthropic OAuth. Anything else falls
# through to the default backend, which is a silent mis-route rather than an
# error — so the shape is checked here, before the id can reach a dispatch.
check_routable() {
  case "$2" in
    "") die "$1 is empty" ;;
    *[!A-Za-z0-9._:/@[\]-]*)
      die "$1='$2' contains characters outside [A-Za-z0-9._:/@[]-] (whitespace and quotes are never valid in a model id)" ;;
  esac
  case "$2" in
    glm-*|claude-*) return 0 ;;
    */*) return 0 ;;
    *) die "$1='$2' is not cc-proxy-routable (need glm-*, vendor/model, or claude-*)" ;;
  esac
}

set_tier() { # set_tier NAME id source
  is_tier_name "$1" || die "unknown tier '$1' (known: $TIER_NAMES)"
  eval "$1=\$2"; eval "SRC_$1=\$3"
}

# Parse a NAME=value file without sourcing it.
load_file() { # load_file <path> <source-label>
  [ -f "$1" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in ''|'#'*) continue ;; esac
    name="${line%%=*}"; val="${line#*=}"
    [ "$name" != "$line" ] || die "$1: malformed line (want NAME=model-id): $line"
    # trim surrounding whitespace from the name only; a model id never has any
    name="$(printf '%s' "$name" | tr -d '[:space:]')"
    is_tier_name "$name" || die "$1: unknown tier '$name' (known: $TIER_NAMES)"
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

# --- proxy catalogue cross-check --------------------------------------------
#
# /v1/models describes the API-BACKED providers only. Anthropic ids are served
# through the harness's own OAuth path, so a `claude-*` id is out of the
# catalogue's scope by construction — its Claude section is a curated literal
# list (src/models.js: DEFAULT_CLAUDE_MODELS, three entries, claude-haiku-*
# deliberately omitted), not a live query. Measured 2026-07-29: `claude-opus-5`
# and `claude-haiku-4-5-20251001` are both ABSENT from /v1/models and both
# demonstrably served a live review panel.
#
# Hence: check membership for `glm-*` and `vendor/model` ids, where the
# catalogue is authoritative; skip `claude-*` entirely, where it is not. Even
# then membership is advisory, never a gate — an unlisted id is reported and
# still emitted, because the id may route while being unlisted. cc-agents
# 0.3.0's set-model.sh made non-membership a hard abort, which would refuse two
# of the four ids this plugin ships.
#
# Note also that upstream may ALIAS an id: `glm-4.5-air` is accepted and served
# as `glm-4.7` (measured directly against POST /v1/messages). Membership is
# therefore a spelling check, not a guarantee of which weights answer.
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
